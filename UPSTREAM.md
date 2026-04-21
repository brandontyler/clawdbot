# Upstream Sync Guide

**Last synced:** `upstream/main` @ `655e0be3d7` — 2026-04-20

Fork of [OpenClaw](https://github.com/openclaw/openclaw) customized for `kiro-cli`.
Keep the delta small so pulling upstream stays painless.

## Sync Workflow

```bash
git fetch upstream
git rebase upstream/main
# For each conflict: accept theirs, re-apply our patch (see Patched Files below)
# pnpm-lock.yaml: always delete and regenerate
chmod +x .kiro/hooks/*.sh 2>/dev/null
pnpm install && pnpm build && pnpm check
openclaw config set agents.defaults.timeoutSeconds 999999
openclaw config set agents.defaults.llm.idleTimeoutSeconds 999999
# Update "Last synced" at top of this file
spinup oc --defer
# Send a real Discord message to confirm delivery
```

**Conflict strategy:** Accept upstream (`git checkout --theirs <file>`), then
re-apply our edit from the Patched Files table. Kiro-only files never conflict —
keep ours. Generated files (`pnpm-lock.yaml`): regenerate.

---

## Kiro-Only Files (zero conflict risk)

These don't exist upstream. If git tries to delete them during rebase, keep ours.

| File                                                    | Purpose                                                                      |
| ------------------------------------------------------- | ---------------------------------------------------------------------------- |
| `src/kiro-proxy/`                                       | Proxy: server, session manager, ACP bridge, alerts, progress, cleanup, tests |
| `src/cli/kiro-proxy-cli.ts`                             | CLI wiring for `openclaw kiro-proxy`                                         |
| `extensions/discord/src/monitor/gateway-plugin-kiro.ts` | Flap detection, backoff — subclasses `ResilientGatewayPlugin`                |
| `scripts/spinup`                                        | tmux session manager (symlinked from `~/bin/spinup`)                         |
| `scripts/add-channel.sh`                                | Create Discord channel + proxy route + tmux session                          |
| `scripts/remove-channel.sh`                             | Tear down a project channel                                                  |
| `scripts/setup.sh`                                      | One-time machine bootstrap                                                   |
| `scripts/sms-poller.sh`                                 | Poll SQS inbound SMS → Discord                                               |
| `scripts/sermon-notes-print.sh`                         | Sunday auto-print: scrape Denton Bible sermon notes PDF → HP ePrint via SES  |
| `scripts/upstream-sync-check.sh`                        | Daily cron: sync reminder with feature/conflict analysis                     |
| `scripts/verify-runtime-artifacts.mjs`                  | Post-build: verify extension dist-runtime output                             |
| `scripts/extract-x-cookies.ps1`                         | PowerShell DPAPI decryption of X/Twitter cookies                             |
| `scripts/refresh-x-cookies`                             | Bash wrapper for above                                                       |
| `scripts/scrape-neogov.mjs`                             | Headless Chrome scraper for government job postings                          |
| `scripts/scrape-tcfp.mjs`                               | Headless Chrome scraper for TCFP fire service careers                        |
| `scripts/fire-jobs.sh`                                  | Daily North Texas firefighter job search aggregator                          |
| `scripts/x-digest.sh`                                   | Daily X/Twitter digest via bird CLI + DynamoDB dedup                         |
| `scripts/x-digest-topics.txt`                           | Topic list for X digest                                                      |
| `scripts/x-bookmark-review.sh`                          | Daily X bookmark review via bird CLI + DynamoDB dedup                        |
| `kiro-proxy-routes.json`                                | Channel → cwd mapping (gitignored)                                           |
| `kiro-proxy-routes.example.json`                        | Template for above                                                           |
| `docs/kiro-proxy-plan.md`                               | Proxy design doc                                                             |
| `docs/kiro-known-issues.md`                             | Known kiro-cli bugs and workarounds                                          |
| `docs/setup.md`                                         | New-machine setup guide                                                      |
| `.kiro/`                                                | Agent config, hooks, agent profiles (gitignored except tracked hooks)        |
| `UPSTREAM.md`                                           | This file                                                                    |

---

## Patched Files (review on every sync)

Each row is one upstream file we've edited. The "Where / What" column tells you
exactly where to look and what to change. For full code, run
`git diff $(git merge-base HEAD upstream/main)..HEAD -- <file>`.

### Group 1: One-line changes

| File                                         | Where / What                                                                             |
| -------------------------------------------- | ---------------------------------------------------------------------------------------- |
| `extensions/discord/src/gateway-logging.ts`  | `INFO_DEBUG_MARKERS` array: add `"Resumed successfully"`                                 |
| `src/auto-reply/reply/queue/settings.ts`     | `defaultQueueModeForChannel()`: return `"steer-backlog"` (upstream: `"collect"`)         |
| `src/auto-reply/reply/typing.ts`             | `createTypingController()` default: `typingTtlMs = 15 * 60_000` (upstream: `2 * 60_000`) |
| `extensions/discord/src/monitor/timeouts.ts` | `DISCORD_DEFAULT_INBOUND_WORKER_TIMEOUT_MS`: `120 * 60_000` (upstream: `30 * 60_000`)    |
| `extensions/discord/src/config-ui-hints.ts`  | `inboundWorker.runTimeoutMs` help string: `1800000` → `7200000` (matches timeouts.ts)    |
| `src/config/types.discord.ts`                | `runTimeoutMs` JSDoc: `1800000 (30 minutes)` → `7200000 (2 hours)` (matches timeouts.ts) |

### Group 2: Small additions (5–15 lines)

| File                                       | Where / What                                                                        |
| ------------------------------------------ | ----------------------------------------------------------------------------------- |
| `src/cli/program/register.subclis-core.ts` | Add `kiro-proxy` entry to `entrySpecs` array (~5 lines, after `acp`)                |
| `src/cli/program/subcli-descriptors.ts`    | Add `kiro-proxy` descriptor to `subCliCommandCatalog` array (~5 lines, after `acp`) |
| `src/gateway/channel-health-monitor.ts`    | After `evaluateChannelHealth()`: add `log.info` with all status fields (3 lines)    |

### Group 3: Larger patches

| File                                               | Where / What                                                                                                                                                                                                                  |
| -------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `src/index.ts`                                     | `uncaughtException` handler: add early return for `"zombie connection"`, `"certificate has expired"`, `"EAI_AGAIN"`, `"ENOTFOUND"` (~16 lines before existing crash handler)                                                  |
| `src/agents/pi-embedded-runner/run/attempt.ts`     | After `cacheTrace.wrapStreamFn`: inject `x-openclaw-session-key` header when `provider === "kiro"` (~10 lines). Previous patches (undici timeouts, orphan trailing-user removal) absorbed by upstream.                        |
| `extensions/discord/src/monitor/gateway-plugin.ts` | Export `fetchDiscordGatewayInfo`; add `ResilientGatewayPlugin` class (~45 lines) fixing reconnect-counter and zombie-heartbeat bugs; change `SafeGatewayPlugin` → `SafeResilientGatewayPlugin extends ResilientGatewayPlugin` |
| `extensions/discord/src/monitor/provider.ts`       | Import `createKiroGatewayPlugin`; use it instead of `createDiscordGatewayPlugin` in `monitorDiscordProvider()` and `__testing` (3 lines)                                                                                      |
| `package.json`                                     | Add `kiro-proxy`/`kiro-proxy:dev` scripts; append `verify-runtime-artifacts.mjs` to `build` chain                                                                                                                             |
| `pnpm-workspace.yaml`                              | Consolidate `minimumReleaseAgeExclude` (add `@buape/*`, `@jscpd/*`, `@tloncorp/*`, `jscpd*`; remove stale entries); move `@discordjs/opus` from `onlyBuiltDependencies` to `ignoredBuiltDependencies`                         |
| `.gitignore`                                       | Append: `.kiro/`, `.beads/`, `logs/`, `kiro-proxy-routes.json`, `client_secret*.json`                                                                                                                                         |

---

## Required Gateway Config

| Setting                                  | Value    | Why                                                                                                                                                                               |
| ---------------------------------------- | -------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `agents.defaults.timeoutSeconds`         | `999999` | Embedded run timeout. Default 48h, but resets to 3600 on some upgrades. Upstream validation rejects `0`; use large value instead. Discord worker timeout (2h) is the outer guard. |
| `agents.defaults.llm.idleTimeoutSeconds` | `999999` | Upstream's 60s idle timeout kills long-running tool executions. Upstream validation rejects `0`. Proxy manages its own.                                                           |

```bash
openclaw config set agents.defaults.timeoutSeconds 999999
openclaw config set agents.defaults.llm.idleTimeoutSeconds 999999
```

## Post-Sync Checklist

- [ ] `pnpm build && pnpm check` pass
- [ ] `spinup oc --defer` restarts gateway/proxy
- [ ] Test Discord message delivered
- [ ] "Last synced" updated at top of this file
- [ ] `scripts/upstream-sync-check.sh` patched files array matches this doc

## Why the Discord Hardening?

Long-running tasks through Discord cause missed heartbeats → gateway drops →
resume fails → flapping. `ResilientGatewayPlugin` (in `gateway-plugin.ts`) fixes
two @buape/carbon bugs; `KiroGatewayPlugin` (in `gateway-plugin-kiro.ts`) adds
flap detection and exponential backoff. Kept in separate files, not PRed upstream.
