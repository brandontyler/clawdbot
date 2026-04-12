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

| Discord Channel               | Channel ID          | Project Directory                 |
| ----------------------------- | ------------------- | --------------------------------- |
| `#openclaw`                   | 1475513267433767014 | `~/code/personal/clawdbot`        |
| `#accode-agent`               | 1475211350291779594 | `~/code/work/accode-agent`        |
| `#pwc`                        | 1475210716632973494 | `~/code/work/PwC`                 |
| `#sermon-metrics`             | 1475216992956059698 | `~/code/personal/sermon`          |
| `#main`                       | —                   | (general / unrouted)              |
| `#real-estate`                | 1478840488944468191 | `~/code/personal/realestate`      |
| `#paris`                      | 1479885670741704704 | `~/code/personal/paris`           |
| `#accode-infra-rcms-projects` | 1492157561120751757 | `~/code/work/infra-rcms-projects` |

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

## Context Management

- You're loaded with `AGENTS.md` (upstream codebase rules) and this file.
- Build/test commands, project structure, and coding style are in `AGENTS.md` — don't duplicate here.
- Beads issue tracker commands are in `memory.md` — don't duplicate here.
- Load docs lazily via the doc map below — don't stuff everything upfront.

## On-Demand Doc Map

| Area                       | Load                                                           |
| -------------------------- | -------------------------------------------------------------- |
| Upstream fork / sync       | `UPSTREAM.md`                                                  |
| Ops / spinup / diagnostics | `.kiro/KIRO-OPS.md`                                            |
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

## Workflow Tips

- Before editing, use `code search_symbols` to understand structure.
- For large files, `grep` to find the section before reading.
- When touching shared logic (routing, pairing, allowlists), all channels are affected.
- Don't modify or add tests unless explicitly asked.
- Run `pnpm build && pnpm check` before considering work done.
