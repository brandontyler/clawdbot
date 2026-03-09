# Upstream Sync Guide

**Last synced:** `upstream/main` @ `dd8fd98ad` — 2026-03-08 (883 commits past stable v2026.3.2, unreleased)

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

| File                                         | Purpose                                                                                       |
| -------------------------------------------- | --------------------------------------------------------------------------------------------- |
| `src/kiro-proxy/`                            | Kiro proxy session management, context usage events, ACP bridge                               |
| `scripts/spinup`                             | tmux session manager for dev environment (symlinked from `~/bin/spinup`)                      |
| `src/cli/kiro-proxy-cli.ts`                  | CLI wiring for the `openclaw kiro-proxy` subcommand                                           |
| `kiro-proxy-routes.json`                     | Discord channel ID → project cwd mapping for per-channel routing                              |
| `src/discord/monitor/gateway-plugin-kiro.ts` | Flap detection, exponential backoff, resume logging — subclasses our `ResilientGatewayPlugin` |
| `docs/kiro-proxy-plan.md`                    | Kiro proxy design doc                                                                         |
| `docs/kiro-known-issues.md`                  | Known kiro-cli bugs and workarounds (session corruption, etc.)                                |
| `docs/kiro-known-issues.md`                  | Known kiro-cli bugs and workarounds (session corruption, etc.)                                |
| `src/kiro-proxy/discord-api.ts`              | Shared Discord REST helpers (post, edit, delete message)                                      |
| `src/kiro-proxy/progress.ts`                 | ProgressReporter — incremental Discord updates during long ACP tool runs                      |
| `.kiro/`                                     | Kiro agent config (gitignored)                                                                |
| `UPSTREAM.md`                                | This file                                                                                     |

## Upstream Files We Patch (review on every sync)

These files have small, intentional edits. Check them after every rebase.

| File                                           | What we changed                                                                                                                  | Why                                                                                                                                     |
| ---------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| `src/discord/monitor/gateway-plugin.ts`        | Added `ResilientGatewayPlugin` class (exported, protected accessors) + factory uses it instead of bare `GatewayPlugin` (~80 LOC) | Fixes @buape/carbon reconnect-counter and zombie-heartbeat bugs                                                                         |
| `src/discord/monitor/provider.ts`              | Import `createKiroGatewayPlugin` instead of `createDiscordGatewayPlugin` (3 lines)                                               | Routes through Kiro hardened plugin with flap detection and backoff                                                                     |
| `src/discord/monitor/provider.proxy.test.ts`   | `toBeInstanceOf(GatewayPlugin)` instead of prototype check (1 line)                                                              | Test assertion updated for `ResilientGatewayPlugin` subclass                                                                            |
| `src/discord/gateway-logging.ts`               | Added `"Resumed successfully"` to `INFO_DEBUG_MARKERS` array (1 line)                                                            | Promotes resume debug messages to info level for visibility                                                                             |
| `src/index.ts`                                 | Suppress `"zombie connection"` uncaught exceptions instead of crashing (~8 lines)                                                | @buape/carbon heartbeat race is non-fatal; gateway reconnects fine                                                                      |
| `src/auto-reply/reply/queue/settings.ts`       | Default queue mode `"collect"` → `"steer-backlog"` (1 line)                                                                      | Better behavior for long-running Discord tasks                                                                                          |
| `src/auto-reply/reply/typing.ts`               | Default `typingTtlMs` `2 * 60_000` → `15 * 60_000` (1 line)                                                                      | 2-min TTL too short for long-running agent sessions                                                                                     |
| `src/cli/program/register.subclis.ts`          | Register `kiro-proxy` subcli entry (~9 lines)                                                                                    | Wires `openclaw kiro-proxy` command                                                                                                     |
| `src/agents/pi-embedded-runner/run/attempt.ts` | Inject `x-openclaw-session-key` header for kiro provider (~5 lines after `applyExtraParamsToAgent`)                              | Lets kiro-proxy route sessions to per-channel cwd                                                                                       |
| `src/agents/pi-embedded-runner/run/attempt.ts` | Removed orphan trailing-user-message removal block (~15 lines → 2-line comment)                                                  | Let `validateAnthropicTurns` merge consecutive user turns instead of dropping them (rapid-fire Discord messages)                        |
| `src/agents/pi-embedded-runner/run/attempt.ts` | Pass `params.timeoutMs` to `ensureGlobalUndiciStreamTimeouts()` (1 line)                                                         | Default 30min undici body timeout kills long-running kiro-proxy streams before the configured 60min agent timeout                       |
| `package.json`                                 | Added `kiro-proxy` and `kiro-proxy:dev` scripts (2 lines)                                                                        | Dev convenience scripts                                                                                                                 |
| `.gitignore`                                   | Added `.beads/` (3 lines appended)                                                                                               | Local issue tracker data                                                                                                                |
| `src/logging/console.ts`                       | Suppress `[EventQueue] Listener…timed out` for DiscordMessageListener (1 line widened)                                           | Carbon 30s timeout is cosmetic noise for long-running ACP sessions                                                                      |
| `src/discord/monitor/provider.lifecycle.ts`    | Handle `"Resumed successfully"` debug event as connection signal in `onGatewayDebug` (~10 lines)                                 | After health-monitor restart, lifecycle misses `"WebSocket connection opened"` → `connected` never becomes `true` → 10-min restart loop |

## Generated Files

None currently — upstream removed the a2ui bundle files.

## Sync Workflow

```bash
git fetch upstream
git rebase upstream/main

# If conflicts in patched files: re-apply the small edits listed above

# Update sync point (use commit hash, not a fake version)
# Format: `upstream/main` @ `<hash>` — YYYY-MM-DD (between stable vX and unreleased vY)

# Verify
pnpm install
pnpm build
pnpm check
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
