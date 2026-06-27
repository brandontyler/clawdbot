# Upstream Sync Guide

**Last synced:** `upstream/main` @ `0358f3dda4` — 2026-05-15 (v2026.5.12)

Fork of [OpenClaw](https://github.com/openclaw/openclaw) customized for `kiro-cli`.
Keep the delta small so pulling upstream stays painless.

## Sync Workflow

```bash
git fetch upstream
git rebase upstream/main
# For each conflict: replace file with upstream HEAD, re-apply our patch:
#   git show upstream/main:<file> > <file>
#   (apply patch from table below)
#   git add <file>
# IMPORTANT: Do NOT use `git checkout --theirs` — it gives the old merge-base,
# not upstream HEAD. Always use `git show upstream/main:` instead.
# pnpm-lock.yaml: always delete and regenerate
chmod +x .kiro/hooks/*.sh 2>/dev/null
pnpm install && pnpm build && pnpm check
# Verify every patched file has a small diff vs upstream:
#   for f in <patched files>; do diff <(git show upstream/main:"$f") "$f" | wc -l; done
openclaw config set agents.defaults.timeoutSeconds 999999
# Update "Last synced" at top of this file
spinup oc --defer
# Send a real Discord message to confirm delivery
```

**Conflict strategy:** For each conflicted patched file, replace it with
upstream's current version (`git show upstream/main:<file> > <file>`), then
re-apply our edit from the Patched Files table. Do NOT use `git checkout --theirs`
— during rebase, "theirs" is the old merge-base version, not upstream HEAD.
After resolving, verify each file: `diff <(git show upstream/main:<file>) <file>`
should show only our patch lines. Kiro-only files never conflict — keep ours.
Generated files (`pnpm-lock.yaml`, `a2ui.bundle.*`): regenerate.

---

## Kiro-Only Files (zero conflict risk)

These don't exist upstream. If git tries to delete them during rebase, keep ours.

| File                                                    | Purpose                                                                                                                                                                                                                                                                                                      |
| ------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `src/kiro-proxy/`                                       | Proxy: server, session manager, ACP bridge, alerts, progress, cleanup, tests. Translates OpenAI multimodal `image_url` content into ACP `ContentBlock::Image` so vision works through Discord (workaround for upstream kiro-cli bug [kirodotdev/Kiro#6937](https://github.com/kirodotdev/Kiro/issues/6937)). |
| `src/cli/kiro-proxy-cli.ts`                             | CLI wiring for `openclaw kiro-proxy`                                                                                                                                                                                                                                                                         |
| `extensions/discord/src/monitor/gateway-plugin-kiro.ts` | Flap detection, backoff — subclasses `ResilientGatewayPlugin`                                                                                                                                                                                                                                                |
| `extensions/openclaw-kiro-stop/`                        | Bundled plugin (id `stopkiro`) adding the `/stopkiro` Discord slash command that POSTs to `kiro-proxy /cancel/<sessionKey>`. Sits alongside built-in `/stop` (gateway-side cleanup); `/stopkiro` adds kiro-proxy ACP cancel on top. Zero upstream code touched; lives next to other `extensions/*` plugins   |
| `scripts/spinup`                                        | tmux session manager (symlinked from `~/bin/spinup`; laptop only)                                                                                                                                                                                                                                            |
| `run-gateway.sh`                                        | EC2 systemd launcher: nvm-load + `node openclaw.mjs gateway run`                                                                                                                                                                                                                                             |
| `run-kiro-proxy.sh`                                     | EC2 systemd launcher: nvm-load + `node openclaw.mjs kiro-proxy ...`                                                                                                                                                                                                                                          |
| `scripts/add-channel.sh`                                | Create Discord channel + proxy route + tmux session                                                                                                                                                                                                                                                          |
| `scripts/remove-channel.sh`                             | Tear down a project channel                                                                                                                                                                                                                                                                                  |
| `scripts/setup.sh`                                      | One-time machine bootstrap                                                                                                                                                                                                                                                                                   |
| `scripts/sms-poller.sh`                                 | Poll SQS inbound SMS → Discord                                                                                                                                                                                                                                                                               |
| `scripts/sermon-notes-print.sh`                         | Sunday auto-print: scrape Denton Bible sermon notes PDF → HP ePrint via SES                                                                                                                                                                                                                                  |
| `scripts/verify-runtime-artifacts.mjs`                  | Post-build: verify extension dist-runtime output                                                                                                                                                                                                                                                             |
| `scripts/extract-x-cookies.ps1`                         | PowerShell DPAPI decryption of X/Twitter cookies                                                                                                                                                                                                                                                             |
| `scripts/refresh-x-cookies`                             | Bash wrapper for above                                                                                                                                                                                                                                                                                       |
| `scripts/scrape-neogov.mjs`                             | Headless Chrome scraper for government job postings                                                                                                                                                                                                                                                          |
| `scripts/scrape-neogov.sh`                              | Bash wrapper: loops North TX city slugs through `.mjs`, emits JSONL                                                                                                                                                                                                                                          |
| `scripts/scrape-tcfp.mjs`                               | Headless Chrome scraper for TCFP fire service careers                                                                                                                                                                                                                                                        |
| `scripts/fire-jobs.sh`                                  | Daily North Texas firefighter job search aggregator                                                                                                                                                                                                                                                          |
| `scripts/nathan-jobs.sh`                                | Daily teaching/youth-nonprofit job search for Nathan (LinkedIn + X/bird, kiro-cli scoring, DynamoDB dedupe)                                                                                                                                                                                                  |
| `scripts/x-digest.sh`                                   | Daily X/Twitter digest via bird CLI + DynamoDB dedup                                                                                                                                                                                                                                                         |
| `scripts/x-digest-topics.txt`                           | Topic list for X digest                                                                                                                                                                                                                                                                                      |
| `scripts/x-bookmark-review.sh`                          | Daily X bookmark review via bird CLI + DynamoDB dedup                                                                                                                                                                                                                                                        |
| `scripts/linkedin-post.py`                              | LinkedIn posting CLI (Open Permissions API: text/URL/image shares); symlinked to `~/.local/bin/linkedin`. Skill at `~/.kiro/skills/linkedin/`.                                                                                                                                                               |
| `kiro-proxy-routes.json`                                | Channel → cwd mapping (gitignored)                                                                                                                                                                                                                                                                           |
| `kiro-proxy-routes.example.json`                        | Template for above                                                                                                                                                                                                                                                                                           |
| `docs/kiro-proxy-plan.md`                               | Proxy design doc                                                                                                                                                                                                                                                                                             |
| `docs/kiro-known-issues.md`                             | Known kiro-cli bugs and workarounds                                                                                                                                                                                                                                                                          |
| `docs/setup.md`                                         | New-machine setup guide                                                                                                                                                                                                                                                                                      |
| `.kiro/`                                                | Selectively tracked: `KIRO.md`, `KIRO-OPS.md`, `agents/*.json`, `agents/prompts/*.md`, `hooks/*.sh`. Rest gitignored (incl. `memory.md`, local config)                                                                                                                                                       |
| `UPSTREAM.md`                                           | This file                                                                                                                                                                                                                                                                                                    |

---

## Patched Files (review on every sync)

Each row is one upstream file we've edited. The "Where / What" column tells you
exactly where to look and what to change. For full code, run
`git diff $(git merge-base HEAD upstream/main)..HEAD -- <file>`.

### Group 1: One-line changes

| File                                         | Where / What                                                                             |
| -------------------------------------------- | ---------------------------------------------------------------------------------------- |
| `extensions/discord/src/gateway-logging.ts`  | `INFO_DEBUG_MARKERS` array: add `"Resumed successfully"`                                 |
| `src/auto-reply/reply/queue/settings.ts`     | `defaultQueueModeForChannel()`: return `"steer-backlog"` (upstream: `"steer"`)           |
| `src/auto-reply/reply/typing.ts`             | `createTypingController()` default: `typingTtlMs = 15 * 60_000` (upstream: `2 * 60_000`) |
| `extensions/discord/src/monitor/timeouts.ts` | `DISCORD_DEFAULT_INBOUND_WORKER_TIMEOUT_MS`: `120 * 60_000` (upstream: `30 * 60_000`)    |

### Group 2: Small additions (5–15 lines)

| File                                       | Where / What                                                                        |
| ------------------------------------------ | ----------------------------------------------------------------------------------- |
| `src/cli/program/register.subclis-core.ts` | Add `kiro-proxy` entry to `entrySpecs` array (~5 lines, after `acp`)                |
| `src/cli/program/subcli-descriptors.ts`    | Add `kiro-proxy` descriptor to `subCliCommandCatalog` array (~5 lines, after `acp`) |
| `src/gateway/channel-health-monitor.ts`    | After `evaluateChannelHealth()`: add `log.info` with all status fields (3 lines)    |

### Group 3: Larger patches

| File                                               | Where / What                                                                                                                                                                                                                           |
| -------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `src/index.ts`                                     | `uncaughtException` handler: add early return for `"zombie connection"`, `"certificate has expired"` (~8 lines before existing benign-error handler). `EAI_AGAIN`/`ENOTFOUND` absorbed by upstream's `isBenignUncaughtExceptionError`. |
| `src/agents/pi-embedded-runner/run/attempt.ts`     | After `cacheTrace.wrapStreamFn`: inject `x-openclaw-session-key` header when `provider === "kiro"` (~10 lines). Previous patches (undici timeouts, orphan trailing-user removal) absorbed by upstream.                                 |
| `extensions/discord/src/monitor/gateway-plugin.ts` | Add `ResilientGatewayPlugin` class (~45 lines) fixing reconnect-counter and zombie-heartbeat bugs; change `OpenClawGatewayPlugin` → extends `ResilientGatewayPlugin` instead of `GatewayPlugin`                                        |
| `extensions/discord/src/monitor/provider.ts`       | Import `createKiroGatewayPlugin`; use it instead of `createDiscordGatewayPlugin` in `monitorDiscordProvider()` and `__testing` (3 lines)                                                                                               |
| `package.json`                                     | Add `kiro-proxy`/`kiro-proxy:dev` scripts; append `verify-runtime-artifacts.mjs` to `build` chain                                                                                                                                      |
| `pnpm-workspace.yaml`                              | Move `@discordjs/opus` from `onlyBuiltDependencies` to `ignoredBuiltDependencies`                                                                                                                                                      |
| `.gitignore`                                       | Append: `.kiro/`, `.beads/`, `logs/`, `kiro-proxy-routes.json`, `client_secret*.json`, `excalidraw.log`                                                                                                                                |

---

## Required Gateway Config

| Setting                                 | Value              | Why                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| --------------------------------------- | ------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `agents.defaults.timeoutSeconds`        | `999999`           | Embedded run timeout. Default 48h, but resets to 3600 on some upgrades. Upstream validation rejects `0`; use large value instead. Discord worker timeout (2h) is the outer guard.                                                                                                                                                                                                                                                                  |
| `models.providers.kiro.timeoutSeconds`  | `999999`           | Per-provider request timeout. Required since upstream `e899b32e1d` (2026-04-27) restructured idle watchdog logic: `agents.defaults.timeoutSeconds` is now treated as an _implicit_ timeout clamped to 120s for the LLM idle watchdog, while `models.providers.*.timeoutSeconds` is _explicit_ and honored directly. Without this, the gateway kills kiro-proxy connections after 120s of no SSE tokens (which happens during long tool-use turns). |
| `models.providers.kiro.models[0].input` | `["text","image"]` | Tells pi-ai the kiro-default model is vision-capable so its openai-completions adapter emits multimodal content (`image_url` parts). The kiro-proxy then translates those into ACP `ContentBlock::Image` for kiro-cli. Required for Discord image attachments to reach the model — without this pi-ai silently drops images before they ever leave the gateway.                                                                                    |

```bash
openclaw config set agents.defaults.timeoutSeconds 999999
# Also required after 2026-05-04 sync:
openclaw config set models.providers.kiro.timeoutSeconds 999999
# Vision support (must edit ~/.openclaw/openclaw.json directly — config CLI
# doesn't expose array fields). Stop the gateway first or it will rewrite.
```

Note: The legacy `agents.defaults.llm.idleTimeoutSeconds` key was removed upstream.
If the running gateway keeps restoring it, stop the gateway first, edit
`~/.openclaw/openclaw.json` to remove the `llm` block, then restart.

## Post-Sync Checklist

- [ ] `pnpm build && pnpm check` pass
- [ ] `spinup oc --defer` restarts gateway/proxy
- [ ] Test Discord message delivered
- [ ] "Last synced" updated at top of this file

## Why the Discord Hardening?

Long-running tasks through Discord cause missed heartbeats → gateway drops →
resume fails → flapping. `ResilientGatewayPlugin` (in `gateway-plugin.ts`) fixes
two @buape/carbon bugs; `KiroGatewayPlugin` (in `gateway-plugin-kiro.ts`) adds
flap detection and exponential backoff. Kept in separate files, not PRed upstream.
