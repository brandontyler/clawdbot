# Upstream Sync Guide

**Last synced:** v2026.2.24 (`b12216af9`) — 2026-02-25

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
| `src/cli/kiro-proxy-cli.ts`                  | CLI wiring for the `openclaw kiro-proxy` subcommand                                           |
| `src/discord/monitor/gateway-plugin-kiro.ts` | Flap detection, exponential backoff, resume logging — subclasses our `ResilientGatewayPlugin` |
| `docs/kiro-proxy-plan.md`                    | Kiro proxy design doc                                                                         |
| `.kiro/`                                     | Kiro agent config (gitignored)                                                                |
| `UPSTREAM.md`                                | This file                                                                                     |

## Upstream Files We Patch (review on every sync)

These files have small, intentional edits. Check them after every rebase.

| File                                         | What we changed                                                                                                                  | Why                                                                 |
| -------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------- |
| `src/discord/monitor/gateway-plugin.ts`      | Added `ResilientGatewayPlugin` class (exported, protected accessors) + factory uses it instead of bare `GatewayPlugin` (~80 LOC) | Fixes @buape/carbon reconnect-counter and zombie-heartbeat bugs     |
| `src/discord/monitor/provider.ts`            | Import `createKiroGatewayPlugin` instead of `createDiscordGatewayPlugin` (3 lines)                                               | Routes through Kiro hardened plugin with flap detection and backoff |
| `src/discord/monitor/provider.proxy.test.ts` | `toBeInstanceOf(GatewayPlugin)` instead of prototype check (1 line)                                                              | Test assertion updated for `ResilientGatewayPlugin` subclass        |
| `src/discord/gateway-logging.ts`             | Added `"Resumed successfully"` to `INFO_DEBUG_MARKERS` array (1 line)                                                            | Promotes resume debug messages to info level for visibility         |
| `src/index.ts`                               | Suppress `"zombie connection"` uncaught exceptions instead of crashing (~8 lines)                                                | @buape/carbon heartbeat race is non-fatal; gateway reconnects fine  |
| `src/auto-reply/reply/queue/settings.ts`     | Default queue mode `"collect"` → `"steer-backlog"` (1 line)                                                                      | Better behavior for long-running Discord tasks                      |
| `src/cli/program/register.subclis.ts`        | Register `kiro-proxy` subcli entry (~9 lines)                                                                                    | Wires `openclaw kiro-proxy` command                                 |
| `package.json`                               | Added `kiro-proxy` and `kiro-proxy:dev` scripts (2 lines)                                                                        | Dev convenience scripts                                             |
| `.gitignore`                                 | Added `.beads/` (3 lines appended)                                                                                               | Local issue tracker data                                            |

## Generated Files

None currently — upstream removed the a2ui bundle files.

## Sync Workflow

```bash
git fetch upstream
git rebase upstream/main

# If conflicts in patched files: re-apply the small edits listed above

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
