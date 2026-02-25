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

| Location                                     | What                                                                                                 |
| -------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| `src/kiro-proxy/`                            | Kiro proxy session management, ACP bridge, per-channel cwd routing                                   |
| `src/discord/monitor/gateway-plugin-kiro.ts` | Flap detection, exponential backoff, resume logging (subclasses upstream's `ResilientGatewayPlugin`) |
| `kiro-proxy-routes.json`                     | Discord channel ID → project cwd mapping                                                             |
| `.kiro/`                                     | This file and agent config (gitignored)                                                              |
| `UPSTREAM.md`                                | Tracks all fork changes — the source of truth for merge safety                                       |

## Discord → Proxy Architecture

Discord messages flow: Discord → OpenClaw gateway (port 18789) → kiro-proxy
(port 18790) → spawns kiro-cli in the correct project directory.

Each Discord channel is mapped to a project directory via `kiro-proxy-routes.json`.
The proxy parses the channel ID from the `x-openclaw-session-key` header
(injected by a small patch in `attempt.ts`) and spawns kiro-cli in the matched cwd.

| Discord Channel        | Project Directory                      |
| ---------------------- | -------------------------------------- |
| `#oc-tmux-session`     | `~/code/personal/clawdbot`             |
| `#mcp-tmux-session`    | `~/code/work/amazon-connect-mcp-tools` |
| `#pwc-tmux-session`    | `~/code/work/PwC`                      |
| `#sermon-tmux-session` | `~/code/personal/sermon`               |

### Self-management constraints

When running as the `#oc-tmux-session` Discord agent, you ARE running inside
the proxy. You can use `spinup status`, `spinup logs`, and
`spinup restart-pane <title>` to diagnose and fix individual panes. But
**never run `spinup oc`** — that kills the entire oc session including the
proxy, which kills your own process. Use `spinup restart-pane gateway` or
`spinup restart-pane kiro-proxy` for targeted recovery instead.

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
- Load docs lazily via the doc map below — don't stuff everything upfront.

## On-Demand Doc Map

| Area                    | Load                                                           |
| ----------------------- | -------------------------------------------------------------- |
| Upstream fork / sync    | `UPSTREAM.md`                                                  |
| Gateway / WS protocol   | `docs/architecture.md`, `docs/gateway/protocol.md`             |
| Agent loop / auto-reply | `docs/concepts/agent-loop.md`                                  |
| Sessions / compaction   | `docs/concepts/session.md`                                     |
| System prompt           | `docs/concepts/system-prompt.md`                               |
| Context window          | `docs/concepts/context.md`                                     |
| Skills system           | `docs/tools/skills.md`                                         |
| Tool execution          | `docs/tools/exec.md`                                           |
| Testing                 | `docs/help/testing.md`                                         |
| Debugging               | `docs/help/debugging.md`                                       |
| Environment / config    | `docs/help/environment.md`                                     |
| Gateway config ref      | `docs/gateway/configuration-reference.md` (large — grep first) |
| Channel-specific        | `docs/channels/<channel>.md`                                   |
| Provider-specific       | `docs/providers/<provider>.md`                                 |
| Plugin dev              | `docs/plugins/manifest.md`                                     |
| Memory / QMD            | `docs/concepts/memory.md`                                      |
| macOS app               | `docs/mac/`                                                    |

## Codebase Quick Ref

- **Runtime**: Node 22+, Bun for dev/scripts, pnpm for package management.
- **Source**: `src/` — CLI in `src/cli`, commands in `src/commands`, gateway in `src/gateway`.
- **Tests**: Colocated `*.test.ts`. Run: `pnpm test`. Build: `pnpm build`. Lint: `pnpm check`.
- **Extensions**: `extensions/*` — workspace packages with own `package.json`.
- **Channels**: `src/telegram`, `src/discord`, `src/slack`, `src/signal`, `src/imessage`, `src/web`, `src/channels`. Extensions in `extensions/*`.

## Issue Tracking (Beads)

Local-only SQLite tracker (`br`). Prefix: `oc-`. `.beads/` is gitignored.
Key commands: `br ready`, `br show <id>`, `br update <id> --claim`,
`br close <id> --reason "..."`, `br create "Title" -p 1 -t task`, `br list`.

## Workflow Tips

- Before editing, use `code search_symbols` to understand structure.
- For large files, `grep` to find the section before reading.
- When touching shared logic (routing, pairing, allowlists), all channels are affected.
- Don't modify or add tests unless explicitly asked.
- Run `pnpm build && pnpm check` before considering work done.

## Agent Instructions

This file tells agents how to manage Tyler's local development environment. The setup runs across multiple tmux sessions — openclaw services (proxy + gateway), an MCP session with a headless browser for automation, and project-specific kiro-cli sessions. Everything is managed through a single script.

### spinup — Session Manager

`~/bin/spinup` manages tmux development sessions. It is idempotent and safe to run repeatedly.

#### Usage

```bash
spinup               # Start/reset ALL sessions
spinup oc            # Start/reset only the openclaw session (proxy + gateway + kiro-cli)
spinup mcp           # Start/reset only the MCP session (kiro-cli + dev-browser)
spinup pwc           # Start/reset only the PwC session
spinup sermon        # Start/reset only the sermon session
spinup status        # Machine-readable health of all sessions, panes, and ports
spinup logs [name]   # Tail logs (kiro-proxy|gateway|dev-browser|all) [lines=30]
spinup restart-pane <title>  # Restart a single crashed pane by title without nuking the session
```

#### Agent interaction

Every pane has a title and its startup command stored in tmux env (`CMD_<title>`). This means agents can:

- **Diagnose** with `spinup status` — one command gives session/pane liveness, PIDs, dead flags, cwds, and port status in parseable key=value format.
- **Read logs** with `spinup logs gateway 50` — no need to remember log file paths.
- **Restart surgically** with `spinup restart-pane gateway` — respawns just that pane using its stored command, without touching other panes or sessions.
- **Target panes** via `tmux send-keys -t oc:main.0` or by title lookup.
- **Discover commands** with `tmux show-environment -t oc` to see what each pane runs.

Pane titles across all sessions: `kiro-proxy`, `gateway`, `kiro-cli`, `dev-browser`.

#### When to run it

| User says                                                                    | Command         |
| ---------------------------------------------------------------------------- | --------------- |
| "spin up" / "spinup" / "start everything" / "set me up" / "boot up"          | `spinup`        |
| "restart everything" / "reset everything" / "nuke it"                        | `spinup`        |
| "the proxy is down" / "proxy crashed" / "gateway is broken" / "oc is broken" | `spinup oc`     |
| "restart openclaw" / "reset oc"                                              | `spinup oc`     |
| "dev-browser is broken" / "browser server crashed" / "restart mcp"           | `spinup mcp`    |
| "restart pwc" / "reset pwc"                                                  | `spinup pwc`    |
| "restart sermon" / "reset sermon"                                            | `spinup sermon` |

#### Sessions & ports

| Session    | What runs                     | Ports        | Panes/Windows       |
| ---------- | ----------------------------- | ------------ | ------------------- |
| **oc**     | kiro-proxy, gateway, kiro-cli | 18790, 18789 | 3 panes in 1 window |
| **mcp**    | kiro-cli, dev-browser         | 9222, 9223   | 2 windows           |
| **pwc**    | kiro-cli                      | —            | 1 pane              |
| **sermon** | kiro-cli                      | —            | 1 pane              |

#### Diagnosing problems

First step is always `spinup status` — it gives session/pane liveness, PIDs, dead flags, cwds, and port status in one shot.

If a specific service is misbehaving, check its logs: `spinup logs gateway 50` (or `kiro-proxy`, `dev-browser`, `all`).

A pane showing `dead=1` means the process crashed but the pane was preserved. Read its output with `tmux capture-pane -t <session>:<window>.<pane> -p | tail -20` to understand what went wrong.

#### Targeted recovery

- **Single pane crashed** → `spinup restart-pane <title>` (e.g. `spinup restart-pane gateway`) — respawns just that pane using its stored command.
- **Whole session broken** → `spinup oc` / `spinup mcp` etc.
- **Only reset all** (`spinup`) if the user explicitly asks or multiple sessions are broken.

#### After running

1. Confirm exit code 0
2. Tell the user which sessions were started
3. Remind them to attach: `tmux attach -t <session-name>`
4. For **oc**, services take ~5–10 seconds to fully start. If the user immediately reports issues, wait and recheck with `spinup status` before re-running spinup.

#### Logs

`spinup logs [name] [lines]` tails logs without needing to remember paths. Direct paths if needed:

| Service     | Log file                    |
| ----------- | --------------------------- |
| kiro-proxy  | `/tmp/kiro-proxy.log`       |
| gateway     | `/tmp/openclaw-gateway.log` |
| dev-browser | `/tmp/dev-browser.log`      |
