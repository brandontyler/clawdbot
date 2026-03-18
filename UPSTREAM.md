# Upstream Sync Guide

**Last synced:** `upstream/main` @ `198de10523` — 2026-03-18

This repo is a fork of [OpenClaw](https://github.com/openclaw/openclaw) customized
to work with `kiro-cli`. The goal is to keep the delta against upstream as small
as possible so that pulling new releases (security, performance, features) stays
painless.

## Principles

1. **Kiro-specific logic lives in separate files** — never weave custom behavior
   into upstream code when a subclass or new file will do.
2. **Upstream file edits must be surgical** — a few lines max, easy to re-apply
   after a conflict.
3. **Rebase regularly** — small frequent syncs beat big infrequent ones.
4. **Generated files are disposable** — re-run the bundler after sync, don't
   try to merge them.

## Kiro-Only Files (zero conflict risk)

These files don't exist upstream. They'll never cause merge conflicts.

| File                                                    | Purpose                                                                                                                             |
| ------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| `src/kiro-proxy/`                                       | Kiro proxy session management, context usage events, ACP bridge                                                                     |
| `src/kiro-proxy/index.ts`                               | Proxy entry point — wires server, session manager, and cleanup                                                                      |
| `src/kiro-proxy/server.ts`                              | HTTP server (OpenAI-compatible /v1/chat/completions, /sessions, /hibernate, /cancel)                                                |
| `src/kiro-proxy/session-manager.ts`                     | Session lifecycle: create, reuse, hibernate, GC, and diagnostics                                                                    |
| `src/kiro-proxy/kiro-session.ts`                        | Single ACP session wrapper — spawn, load, prompt, cancel                                                                            |
| `src/kiro-proxy/types.ts`                               | Shared TypeScript types for proxy internals                                                                                         |
| `src/kiro-proxy/alerts.ts`                              | Context threshold alerts (60%/80%/90%) posted to Discord                                                                            |
| `src/kiro-proxy/discord-api.ts`                         | Shared Discord REST helpers (post, edit, delete) with retry-after handling                                                          |
| `src/kiro-proxy/progress.ts`                            | ProgressReporter — incremental Discord updates during long ACP tool runs                                                            |
| `src/kiro-proxy/cleanup.ts`                             | Startup sweep: kills orphaned `kiro-cli acp` processes from previous proxy runs                                                     |
| `src/kiro-proxy/diag-command.ts`                        | `/diag` command handler — ACP session diagnostics and system health                                                                 |
| `src/kiro-proxy/server.test.ts`                         | Tests for proxy server                                                                                                              |
| `src/kiro-proxy/session-manager.test.ts`                | Tests for session manager                                                                                                           |
| `src/cli/kiro-proxy-cli.ts`                             | CLI wiring for the `openclaw kiro-proxy` subcommand                                                                                 |
| `extensions/discord/src/monitor/gateway-plugin-kiro.ts` | Flap detection, exponential backoff, resume logging — subclasses our `ResilientGatewayPlugin`                                       |
| `scripts/spinup`                                        | tmux session manager: start/reset sessions, hibernate/wake ACP sessions, status, logs, restart-pane (symlinked from `~/bin/spinup`) |
| `scripts/add-channel.sh`                                | Create Discord channel + proxy route + tmux session for a new project                                                               |
| `scripts/remove-channel.sh`                             | Tear down a project channel (route + tmux session, not the Discord channel)                                                         |
| `scripts/upstream-sync-check.sh`                        | Daily cron: posts upstream sync reminder to #openclaw if behind                                                                     |
| `kiro-proxy-routes.json`                                | Discord channel ID → project cwd mapping for per-channel routing                                                                    |
| `docs/kiro-proxy-plan.md`                               | Kiro proxy design doc                                                                                                               |
| `docs/kiro-known-issues.md`                             | Known kiro-cli bugs and workarounds (session corruption, etc.)                                                                      |
| `.kiro/`                                                | Kiro agent config (gitignored)                                                                                                      |
| `UPSTREAM.md`                                           | This file                                                                                                                           |

## Upstream Files We Patch (review on every sync)

These files have small, intentional edits. Check them after every rebase.

| File                                                          | What we changed                                                                                                                                                                                                                   | Why                                                                                                                                                                                               |
| ------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `extensions/discord/src/monitor/gateway-plugin.ts`            | Exported `fetchDiscordGatewayInfo` (1 line); replaced `SafeGatewayPlugin` closure with exported `ResilientGatewayPlugin` class + `SafeResilientGatewayPlugin` subclass (~80 LOC); `private` → `protected` on `_reconnectAttempts` | `ResilientGatewayPlugin` fixes @buape/carbon reconnect-counter and zombie-heartbeat bugs; exported so `gateway-plugin-kiro.ts` can extend it; `fetchDiscordGatewayInfo` exported for kiro factory |
| `extensions/discord/src/monitor/provider.ts`                  | Import `createKiroGatewayPlugin` instead of `createDiscordGatewayPlugin` (3 lines)                                                                                                                                                | Routes through Kiro hardened plugin with flap detection and backoff                                                                                                                               |
| `extensions/discord/src/gateway-logging.ts`                   | Added `"Resumed successfully"` to `INFO_DEBUG_MARKERS` array (1 line)                                                                                                                                                             | Promotes resume debug messages to info level for visibility                                                                                                                                       |
| `src/index.ts`                                                | Suppress `"zombie connection"` uncaught exceptions instead of crashing (~8 lines)                                                                                                                                                 | @buape/carbon heartbeat race is non-fatal; gateway reconnects fine                                                                                                                                |
| `src/auto-reply/reply/queue/settings.ts`                      | Default queue mode `"collect"` → `"steer-backlog"` (1 line)                                                                                                                                                                       | Better behavior for long-running Discord tasks                                                                                                                                                    |
| `src/auto-reply/reply/typing.ts`                              | Default `typingTtlMs` `2 * 60_000` → `15 * 60_000` (1 line)                                                                                                                                                                       | 2-min TTL too short for long-running agent sessions                                                                                                                                               |
| `src/auto-reply/commands-registry.data.ts`                    | Added `/diag` command entry (6 lines)                                                                                                                                                                                             | Registers the `/diag` text command in the status category                                                                                                                                         |
| `src/auto-reply/reply/commands-core.ts`                       | Added lazy-loaded `/diag` handler in HANDLERS array (5 lines)                                                                                                                                                                     | Wires `/diag` to `kiro-proxy/diag-command.ts` via dynamic import                                                                                                                                  |
| `src/cli/program/register.subclis.ts`                         | Register `kiro-proxy` subcli entry (~9 lines)                                                                                                                                                                                     | Wires `openclaw kiro-proxy` command                                                                                                                                                               |
| `src/agents/pi-embedded-runner/run/attempt.ts`                | Inject `x-openclaw-session-key` header for kiro provider (~5 lines after `applyExtraParamsToAgent`)                                                                                                                               | Lets kiro-proxy route sessions to per-channel cwd                                                                                                                                                 |
| `src/agents/pi-embedded-runner/run/attempt.ts`                | Removed orphan trailing-user-message removal block (~15 lines → 2-line comment)                                                                                                                                                   | Let `validateAnthropicTurns` merge consecutive user turns instead of dropping them (rapid-fire Discord messages)                                                                                  |
| `src/agents/pi-embedded-runner/run/attempt.ts`                | Pass `params.timeoutMs` to `ensureGlobalUndiciStreamTimeouts()` (1 line)                                                                                                                                                          | Default 30min undici body timeout kills long-running kiro-proxy streams before the configured 60min agent timeout                                                                                 |
| `package.json`                                                | Added `kiro-proxy` and `kiro-proxy:dev` scripts (2 lines)                                                                                                                                                                         | Dev convenience scripts                                                                                                                                                                           |
| `.gitignore`                                                  | Added `.beads/` (3 lines appended)                                                                                                                                                                                                | Local issue tracker data                                                                                                                                                                          |
| `src/logging/console.ts`                                      | Suppress `[EventQueue] Listener…timed out` for DiscordMessageListener (1 line widened)                                                                                                                                            | Carbon 30s timeout is cosmetic noise for long-running ACP sessions                                                                                                                                |
| `src/gateway/channel-health-monitor.ts`                       | Added verbose health-check log line with all status fields (3 lines)                                                                                                                                                              | Visibility into health monitor decisions for debugging restart loops                                                                                                                              |
| `extensions/discord/src/monitor/provider.lifecycle.ts`        | Handle `"Resumed successfully"` debug event as connection signal in `onGatewayDebug` (~10 lines)                                                                                                                                  | After health-monitor restart, lifecycle misses `"WebSocket connection opened"` → `connected` never becomes `true` → 10-min restart loop                                                           |
| `src/auto-reply/command-detection.ts`                         | Added `isTextOnlyCommand()` export (~10 lines)                                                                                                                                                                                    | Lets channel monitors distinguish text-only commands from those with native slash equivalents                                                                                                     |
| `extensions/discord/src/monitor/message-handler.preflight.ts` | Import `isTextOnlyCommand`; skip drop for text-only commands (2 lines changed)                                                                                                                                                    | Text-only commands (e.g. `/diag`) were silently dropped in guild channels because the preflight assumed all control commands had native slash equivalents                                         |

## Generated Files

None currently — upstream removed the a2ui bundle files.

## Sync Workflow

```bash
git fetch upstream
git rebase upstream/main
# Re-apply edits from "Upstream Files We Patch" if conflicts
pnpm install && pnpm build && pnpm check
# Update sync point at top of this file
spinup oc --defer
# Send a real Discord message to confirm delivery (probe alone won't catch config issues)
```

## Why the Discord Hardening?

Our use case routes long-running tasks (builds, compiles, tests) through Discord.
This keeps the bot busy for extended periods, causing:

- Missed heartbeats → gateway drops the connection
- Stale session → resume fails → rapid reconnect loop (flapping)

The upstream `GatewayPlugin` from @buape/carbon doesn't account for this workload
pattern. Our `ResilientGatewayPlugin` (in `gateway-plugin.ts`) fixes two carbon
bugs (reconnect counter reset, zombie heartbeat crash), and `KiroGatewayPlugin`
(in `gateway-plugin-kiro.ts`) adds flap detection (force fresh IDENTIFY after 8
rapid disconnects) and exponential backoff with jitter on top.

This is specific to our usage — not a general upstream bug — which is why we
keep it in separate files rather than PRing it upstream.
