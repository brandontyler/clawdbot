# Kiro Agent Guide — clawdbot

## What This Is

A fork of [OpenClaw](https://github.com/openclaw/openclaw) customized for
`kiro-cli`. We run long-running tasks (builds, compiles, tests) through Discord,
which drives most of our custom code. The goal: keep upstream sync easy while
adding Kiro-specific behavior.

## Upstream Fork Management (Critical)

Read `UPSTREAM.md` before touching any upstream files. It lists every patched
file and every Kiro-only file.

- **Kiro logic goes in separate files** — never weave into upstream code.
- **Upstream patches must be surgical** — a few lines max.
- **Update `UPSTREAM.md`** when you add/change a patch or add a Kiro-only file.
- **`AGENTS.md` is upstream** — don't add Kiro-specific content there.
- After syncing: check patched files in `UPSTREAM.md`, re-run
  `pnpm canvas:a2ui:bundle` for generated files, then `pnpm build && pnpm check`.

## Our Kiro-Specific Code

| Location                                                | What                                                                                                 |
| ------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| `src/kiro-proxy/`                                       | Kiro proxy session management, ACP bridge, per-channel cwd routing                                   |
| `extensions/discord/src/monitor/gateway-plugin-kiro.ts` | Flap detection, exponential backoff, resume logging (subclasses upstream's `ResilientGatewayPlugin`) |
| `kiro-proxy-routes.json`                                | Discord channel ID → project cwd mapping (gitignored, machine-local)                                 |
| `kiro-proxy-routes.example.json`                        | Template for routes file                                                                             |
| `scripts/setup.sh`                                      | One-command bootstrap for new machines                                                               |
| `docs/setup.md`                                         | New-machine setup documentation                                                                      |
| `.kiro/`                                                | This file and agent config (gitignored)                                                              |
| `UPSTREAM.md`                                           | Tracks all fork changes — the source of truth for merge safety                                       |

## Discord → Proxy Architecture

Discord messages flow: Discord → OpenClaw gateway (port 18800) → kiro-proxy
(port 18801) → spawns kiro-cli in the correct project directory.

Each Discord channel is mapped to a project directory via `kiro-proxy-routes.json`.
The proxy parses the channel ID from the `x-openclaw-session-key` header
(injected by a small patch in `attempt.ts`) and spawns kiro-cli in the matched cwd.

| Discord Channel    | Channel ID          | Project Directory            |
| ------------------ | ------------------- | ---------------------------- |
|   | 1475216992956059698 |      |
|      | 1478840488944468191 |  |
|            | 1479885670741704704 |      |
|       | 1495383782717391019 |   |
|         | 1500137795866595458 |    |

Note: channel→directory mappings live in `kiro-proxy-routes.json` (gitignored).
On a new machine, run `scripts/setup.sh` then add channels with `scripts/add-channel.sh`.
See `docs/setup.md` for full bootstrap instructions.

### Adding a new project channel

One command sets up everything (Discord channel, proxy route, tmux session):

```bash
scripts/add-channel.sh <name> <project-dir>
# e.g.: scripts/add-channel.sh newproject ~/code/work/newproject
```

Then restart the proxy and start the session:

```bash
spinup oc --defer
spinup <name>
```

To tear down: `scripts/remove-channel.sh <name>` (doesn't delete the Discord
channel — do that manually if needed).

### Self-management constraints

When running as the `#oc-tmux-session` Discord agent, you ARE running inside
the `oc-cli` tmux session (separate from the `oc` infra session). Use
`spinup status`, `spinup logs`, and `spinup restart-pane <title>` for diagnosis.
**Never run `spinup oc-cli`** or `spinup` (all) — those kill your own session.

**Restarting oc from Discord:** only the `#oc-tmux-session` agent should restart
the `oc` session — it runs in the companion `oc-cli` session and can verify the
restart. Other channel agents (`#mcp-tmux-session`, `#pwc-tmux-session`, etc.)
depend on the gateway but should not restart it; they can diagnose with
`spinup status` / `spinup logs` and tell the user to restart via `#oc-tmux-session`.

When restarting, always use `spinup oc --defer` (not bare `spinup oc`). The
`--defer` flag backgrounds the restart with a 45-second delay so the Discord
response can be delivered before the gateway goes down. Without it, the gateway
dies mid-response and the conversation drops. You can also specify a custom
delay: `spinup oc --defer=5`.

## EC2 Operations

This machine runs on EC2 (Linux ARM64). Services are managed via **systemd user units**, NOT tmux/spinup.

### Services

| Service | Port | Command |
|---------|------|---------|
| `openclaw-gateway.service` | 18800 | OpenClaw gateway |
| `kiro-proxy.service` | 18801 | Kiro CLI proxy (ACP bridge) |
| `excalidraw.service` | 3000 | Excalidraw canvas server |

```bash
systemctl --user status openclaw-gateway
systemctl --user restart kiro-proxy
journalctl --user -u openclaw-gateway -f
```

### Scheduled Jobs (systemd timers)

| Timer | Schedule (CDT) | What |
|-------|----------------|------|
| `fire-jobs.timer` | 6:30am | North TX firefighter job search |
| `x-digest.timer` | 6:00am | X/Twitter digest |
| `x-bookmark-review.timer` | 6:15am | X bookmark review |

### Key Differences from Laptop

- **No tmux/spinup** — all services are systemd. Ignore `spinup` references.
- **No `tylerbtt` AWS profile** — no mwinit dongle on EC2. Use `personal` profile for AWS calls.
- **dev-browser** — daemon auto-starts via CLI (`dev-browser --headless status`), no dedicated pane.
- **Discord admin channel** — `#openclaw-ec2` (ID: `1503414103341797406`)
- **Restart services** — `systemctl --user restart <service>`, not `spinup`.
- **Logs** — `journalctl --user -u <service> -f`, not `/tmp/*.log`.

## Lessons Learned

- Don't edit `AGENTS.md` — it's an upstream file and will conflict on sync.
- The Discord gateway hardening (flap detection, backoff) is specific to our
  long-running workload, not a general upstream bug. Keep it in our subclass.
- Prefer subclassing + separate files over modifying upstream classes. Example:
  `KiroGatewayPlugin extends ResilientGatewayPlugin` with only 3 lines changed
  in the upstream file (`export class`, `private` → `protected`).
- Generated files (`a2ui.bundle.js`, `.bundle.hash`) are disposable — never
  try to merge them, just regenerate after sync.
- When upstream changes come, the smaller our diff the easier the rebase.
  Every line we add to an upstream file is future merge conflict surface.
- **Upstream sync: never use `git checkout --theirs`** — during rebase, "theirs"
  is the old merge-base version, not upstream HEAD. Always use
  `git show upstream/main:<file> > <file>` then re-apply our patch. After
  resolving, verify: `diff <(git show upstream/main:<file>) <file>` should show
  only our patch lines. Stale files silently pass rebase but break the build.
- **Upstream sync: patches get absorbed.** Each sync, check whether upstream
  adopted our changes (e.g. EAI_AGAIN handling, config deprecations). Drop
  patches that are no longer needed — fewer patches = easier future syncs.
- **Upstream sync: the running gateway rewrites config.** Stop the gateway
  before editing `~/.openclaw/openclaw.json` or it will restore old values.
- **gateway-plugin-kiro.ts type pitfalls:** (1) `ResolveDiscordGatewayIntentsParams`
  is not exported from upstream — use `Parameters<typeof resolveDiscordGatewayIntents>[0]`.
  (2) `gatewayInfo` is inherited as `protected gatewayInfo?: APIGatewayBotInfo` —
  don't redeclare it. (3) `setupWebSocket` is private — monkey-patch in constructor,
  don't use `override`. (4) Return types need `as unknown as discordGateway.GatewayPlugin`
  cast due to private field mismatch in subclass hierarchy.

## Context Management

- You're loaded with `AGENTS.md` (upstream codebase rules) and this file.
- Build/test commands, project structure, and coding style are in `AGENTS.md` — don't duplicate here.
- Beads issue tracker commands are in `memory.md` — don't duplicate here.
- Load docs lazily via the doc map below — don't stuff everything upfront.

## On-Demand Doc Map

| Area                       | Load                                                           |
| -------------------------- | -------------------------------------------------------------- |
| Upstream fork / sync       | `UPSTREAM.md`                                                  |
| Ops / EC2 systemd          | `.kiro/KIRO-OPS.md`                                            |
| Gateway / WS protocol      | `docs/architecture.md`, `docs/gateway/protocol.md`             |
| Agent loop / auto-reply    | `docs/concepts/agent-loop.md`                                  |
| Sessions / compaction      | `docs/concepts/session.md`                                     |
| System prompt              | `docs/concepts/system-prompt.md`                               |
| Context window             | `docs/concepts/context.md`                                     |
| Skills system              | `docs/tools/skills.md`                                         |
| Tool execution             | `docs/tools/exec.md`                                           |
| Testing                    | `docs/help/testing.md`                                         |
| Debugging                  | `docs/help/debugging.md`                                       |
| Environment / config       | `docs/help/environment.md`                                     |
| Gateway config ref         | `docs/gateway/configuration-reference.md` (large — grep first) |
| Channel-specific           | `docs/channels/<channel>.md`                                   |
| Provider-specific          | `docs/providers/<provider>.md`                                 |
| Plugin dev                 | `docs/plugins/manifest.md`                                     |
| Memory / QMD               | `docs/concepts/memory.md`                                      |
| macOS app                  | `docs/mac/`                                                    |

## Skill Governance

This section captures the conventions adopted by the
[Google Agent Skills whitepaper governance program](.beads/beads.db) (umbrella
bead `openclaw-agent-skills-paper-governance-3bu`). Source PDF and
extracted markdown:
`/home/ubuntu/Downloads/whitepaper-extract/whitepaper.md` (Singhal et al.,
May 2026).

### Authoritative spec sources

- **Kiro CLI**: <https://kiro.dev/docs/cli/skills/>
- **Open Agent Skills standard**: <https://agentskills.io/specification>

Skills auto-load by description match (same as Claude Code) and can also
be invoked as `/skill-name`. Frontmatter loads at session start; the
SKILL.md body loads when the skill activates; `references/` and
`scripts/` load on demand from the body.

### Tier model (read / draft / act ladder)

| Tier | Definition | `allowed-tools` guidance |
| --- | --- | --- |
| `read-only` | Queries, summaries, describes. No external side effects. | `Read` plus bounded `Bash` for read-only commands. |
| `draft-only` | Produces artifacts for human review. Local file writes OK. | `Bash Read Write` (and `AskUserQuestion` if interactive). |
| `action-allowed` | Real-system side effects (SMS, email, posts, infra restarts). | Narrowest possible `allowed-tools` plus `disable-model-invocation: true`. |

Tier classification for the current library lives at
`~/.kiro/skills/TIER-AUDIT.md`.

### Required frontmatter per skill

```yaml
---
name: <kebab-case>                            # spec-required
description: "What it does + when to use it." # spec-required, ≤ 1024 chars
allowed-tools: Bash Read                      # SPACE-SEPARATED string, not list
metadata:
  tier: read-only | draft-only | action-allowed
  version: "X.Y.Z"                            # preferred placement
# Action-allowed only:
disable-model-invocation: true
---
```

Spec note: `allowed-tools` is **space-separated** per
<https://agentskills.io/specification>. `Bash, Read` (comma) and
`[Bash, Read]` (YAML list) are non-standard. `disable-model-invocation`
is undocumented in the spec but works in Kiro CLI 2.6.0
(precedent: `~/.kiro/skills/thermo-nuclear-review/SKILL.md`).

### Version placement

Tolerate both `metadata.version` (spec-compliant, preferred for new
skills) and top-level `version:` (existing convention in
`drawio-skill`, `last30days`). See bead `openclaw-fji` for the
decision rationale.

### Body conventions (whitepaper §A)

- SKILL.md body **≤ 5 KB / 500 lines ideal, ≤ 10 KB hard cap**.
- Long reference material → `references/<topic>.md`.
- Executable helpers → `scripts/`.
- Templates and static assets → `assets/`.
- Body should be a router: when to use, decision tree, links into
  `references/` and `scripts/`.

### Versioning bumps (semver)

- Patch: typo / clarification / pitfall added.
- Minor: new section, expanded coverage, new script.
- Major: rename, slash-command change, removed surface.

### Tooling

- `~/.kiro/skills/skill-curator/` — lints frontmatter, body size, version
  presence, tier annotations, evals coverage. Run before merging skill
  changes.
- `evals/` directory inside each skill (paper §6) — golden + adversarial
  cases plus `run.sh`. Pilot example lives in `~/.kiro/skills/aws-sms/evals/`.

### When adding a new skill

1. Pick the tier first (read / draft / action). When in doubt, choose
   the more restrictive tier — the paper's failure-modes section showed
   19 % of skills *degrade* capability vs. no skill.
2. Write a precise `description` with trigger phrases — that is what
   the model matches against during auto-routing.
3. Set `allowed-tools` to the narrowest set that lets the skill work.
4. If side effects are external, add `disable-model-invocation: true`.
5. Run `~/.kiro/skills/skill-curator/scripts/lint.sh ~/.kiro/skills/<new>`.

## Workflow Tips

- Before editing, use `code search_symbols` to understand structure.
- For large files, `grep` to find the section before reading.
- When touching shared logic (routing, pairing, allowlists), all channels are affected.
- Don't modify or add tests unless explicitly asked.
- Run `pnpm build && pnpm check` before considering work done.
