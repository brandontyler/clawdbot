# Upstream Sync Guide

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

| File                                         | Purpose                                                                                              |
| -------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| `src/kiro-proxy/`                            | Kiro proxy session management, context usage events, ACP bridge                                      |
| `src/discord/monitor/gateway-plugin-kiro.ts` | Flap detection, exponential backoff, resume logging — subclasses upstream's `ResilientGatewayPlugin` |
| `.kiro/`                                     | Kiro agent config (gitignored)                                                                       |
| `UPSTREAM.md`                                | This file                                                                                            |

## Upstream Files We Patch (review on every sync)

These files have small, intentional edits. Check them after every `git pull --rebase`.

| File                                    | What we changed                                                                                                        | Why                                                                         |
| --------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------- |
| `src/discord/monitor/gateway-plugin.ts` | `class` → `export class`, `private` → `protected` on `_reconnectAttempts` accessors (3 lines)                          | Allows `gateway-plugin-kiro.ts` to subclass and access reconnect state      |
| `src/discord/monitor/provider.ts`       | Import `createKiroGatewayPlugin` instead of `createDiscordGatewayPlugin`; 5s `setTimeout` on stall reconnect (2 lines) | Routes through Kiro hardened plugin; prevents hammering Discord after stall |
| `src/discord/gateway-logging.ts`        | Added `"Resumed successfully"` to `INFO_DEBUG_MARKERS` array (1 line)                                                  | Promotes resume debug messages to info level for visibility                 |
| `.gitignore`                            | Added `.beads/` (3 lines appended)                                                                                     | Local issue tracker data                                                    |

## Generated Files (re-run after sync)

| File                                  | Regenerate with           |
| ------------------------------------- | ------------------------- |
| `src/canvas-host/a2ui/.bundle.hash`   | `pnpm canvas:a2ui:bundle` |
| `src/canvas-host/a2ui/a2ui.bundle.js` | `pnpm canvas:a2ui:bundle` |

## Sync Workflow

```bash
git fetch origin main
git rebase origin/main

# If conflicts in patched files: re-apply the small edits listed above
# If conflicts in generated files: just accept upstream, then regenerate:
pnpm canvas:a2ui:bundle

# Verify
pnpm build
pnpm check
```

## Why the Discord Hardening?

Our use case routes long-running tasks (builds, compiles, tests) through Discord.
This keeps the bot busy for extended periods, causing:

- Missed heartbeats → gateway drops the connection
- Stale session → resume fails → rapid reconnect loop (flapping)

The upstream `ResilientGatewayPlugin` handles basic reconnect bugs but doesn't
account for this workload pattern. Our `KiroGatewayPlugin` adds flap detection
(force fresh IDENTIFY after 8 rapid disconnects) and exponential backoff with
jitter to handle it gracefully.

This is specific to our usage — not a general upstream bug — which is why we
keep it in a separate file rather than PRing it upstream.
