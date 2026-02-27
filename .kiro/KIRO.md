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

| Discord Channel   | Channel ID          | Project Directory          |
| ----------------- | ------------------- | -------------------------- |
| `#openclaw`       | 1475513267433767014 | `~/code/personal/clawdbot` |
| `#accode-agent`   | 1475211350291779594 | `~/code/work/accode-agent` |
| `#pwc`            | 1475210716632973494 | `~/code/work/PwC`          |
| `#sermon-metrics` | 1475216992956059698 | `~/code/personal/sermon`   |
| `#main`           | —                   | (general / unrouted)       |

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
spinup oc            # Start/reset only the openclaw infra session (proxy + gateway)
spinup oc --defer    # Same, but backgrounds with 3s delay (safe from Discord agent)
spinup oc-cli        # Start/reset only the openclaw kiro-cli session
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
- **Target windows** via `tmux send-keys -t oc:kiro-proxy` or by title lookup.
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

#### Internals

- **ANSI stripping**: all service output is piped through `sed -u "s/\x1b\[[0-9;]*m//g"` before `tee` to keep logs clean.
- **Port cleanup**: `kill_port` (`lsof -ti:<port> | xargs -r kill -9`) runs before starting services that bind ports (kiro-proxy on 18790, dev-browser on 9222/9223).
- **`remain-on-exit on`**: set on all sessions so crashed panes stay readable (enables `dead=1` detection in `spinup status`).

#### Pane commands

| Pane        | Actual command                                                                                               |
| ----------- | ------------------------------------------------------------------------------------------------------------ |
| kiro-proxy  | `pnpm openclaw kiro-proxy --verbose --routes kiro-proxy-routes.json` (cwd: `~/code/personal/clawdbot`)       |
| gateway     | `pnpm openclaw gateway run --verbose --force --port 18789 --bind loopback` (cwd: `~/code/personal/clawdbot`) |
| kiro-cli    | `kiro-cli` (cwd: varies per session)                                                                         |
| dev-browser | kills ports 9222/9223, then `./server.sh --headless` (cwd: `~/code/work/dev-browser/skills/dev-browser`)     |

#### Sessions & ports

| Session    | What runs             | Ports        | Panes/Windows |
| ---------- | --------------------- | ------------ | ------------- |
| **oc**     | kiro-proxy, gateway   | 18790, 18789 | 2 windows     |
| **oc-cli** | kiro-cli              | —            | 1 window      |
| **mcp**    | kiro-cli, dev-browser | 9222, 9223   | 2 windows     |
| **pwc**    | kiro-cli              | —            | 1 pane        |
| **sermon** | kiro-cli              | —            | 1 pane        |

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

## Operational Diagnostics

### Checking context usage across all sessions

The kiro-proxy logs `context: X%` after each ACP response. The gateway logs
detailed `[context-diag]` entries with message counts, history chars, image
blocks, and system prompt size per session key.

Quick commands:

```bash
# Latest context % per channel (from proxy logs)
grep -E 'channel route:|context:' /tmp/kiro-proxy.log | tail -40

# Detailed context-diag per session (from gateway logs)
grep 'context-diag' /tmp/openclaw-gateway.log | tail -20

# Latest context-diag per unique session
grep 'context-diag' /tmp/openclaw-gateway.log | awk -F'sessionKey=' '{print $2}' | \
  awk '{print $1}' | sort -u | while read key; do
    grep "sessionKey=$key " /tmp/openclaw-gateway.log | grep 'context-diag' | tail -1
  done
```

### Key metrics to watch

| Metric                | Where                                   | Warning threshold    |
| --------------------- | --------------------------------------- | -------------------- |
| kiro-cli context %    | proxy log `context: X%`                 | >50% consider `/new` |
| Gateway history chars | gateway `context-diag` historyTextChars | >200K chars          |
| Gateway message count | gateway `context-diag` messages=        | >200 msgs            |
| System memory         | `free -h`                               | <1GB available       |
| Load average          | `uptime`                                | >2.0 sustained       |
| ACP child process RSS | `ps aux --sort=-%mem \| head -15`       | >200MB per process   |

### GC idle timeout behavior

The proxy kills idle ACP sessions after 1800s (30 min) of inactivity. When
this happens, the log shows:

```
[kiro-session] killing process (pid XXXXX) reason=gc-idle-timeout (session=..., idle=XXXXs, limit=1800s)
```

The session respawns automatically on the next message. Context resets to ~2%.
This is normal and expected — it keeps memory usage bounded.

### System resource baseline (exe.dev VM)

- 7.8GB RAM total, ~4.5GB available under normal load
- Gateway: ~390MB RSS (largest single process)
- kiro-proxy: ~180MB RSS
- Each kiro-cli ACP child: 65-90MB RSS
- dev-browser + Chromium: ~170MB combined
- Swap usage of 1-1.5GB is normal; watch for >3GB

### ACP session architecture (not tmux)

The kiro-proxy spawns `kiro-cli acp` as direct child processes with
stdin/stdout ACP protocol pipes. These are NOT the tmux kiro-cli sessions.
The tmux sessions (`oc-cli`, `mcp:main`, `pwc:main`, `sermon:main`) are
separate interactive sessions for manual laptop use. The proxy doesn't
interact with tmux at all.

### Cross-session communication

There is no inter-agent communication. Each Discord channel → kiro-cli ACP
session is fully isolated. The `#oc-tmux-session` agent can monitor all
sessions via logs and `spinup status` but cannot inject messages into other
channels' ACP sessions.
