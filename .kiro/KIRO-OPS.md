# Kiro Ops — spinup, tmux, diagnostics

Load this file when doing operational work (spinup, debugging, monitoring).
Architecture and fork management are in `KIRO.md`.

## spinup — Session Manager

`~/bin/spinup` manages tmux development sessions. It is idempotent and safe to run repeatedly.

### Usage

```bash
spinup               # Start/reset ALL sessions
spinup oc            # Start/reset only the openclaw infra session (proxy + gateway + sms-poller)
spinup oc --defer    # Same, but backgrounds with 45s delay (safe from Discord agent)
spinup oc-cli        # Start/reset only the openclaw kiro-cli session
spinup mcp           # Start/reset only the MCP session (kiro-cli + dev-browser + excalidraw)
spinup pwc           # Start/reset only the PwC session
spinup sermon        # Start/reset only the sermon session
spinup realestate    # Start/reset only the real-estate session
spinup status        # Machine-readable health of all sessions, panes, and ports
spinup context       # ACP session context usage bars (reads from proxy /sessions endpoint)
spinup logs [name]   # Tail logs (kiro-proxy|gateway|dev-browser|excalidraw|defer|all) [lines=30]
spinup hibernate     # Hibernate all idle ACP sessions (safe shutdown prep)
spinup snapshot      # Save all session IDs to disk without killing processes
spinup wake          # Show hibernated sessions (they restore on next Discord message)
spinup restart-pane <title>  # Restart a single crashed pane by title without nuking the session
```

### Agent interaction

Every pane has a title and its startup command stored in tmux env (`CMD_<title>`). Agents can:

- **Diagnose** with `spinup status` — session/pane liveness, PIDs, dead flags, cwds, port status.
- **Read logs** with `spinup logs gateway 50`.
- **Restart surgically** with `spinup restart-pane gateway` — respawns just that pane.
- **Target windows** via `tmux send-keys -t oc:kiro-proxy` or by title lookup.
- **Discover commands** with `tmux show-environment -t oc`.

Pane titles across all sessions: `kiro-proxy`, `gateway`, `sms-poller`, `kiro-cli`, `dev-browser`, `excalidraw`.

### When to run it

| User says                                                                    | Command             |
| ---------------------------------------------------------------------------- | ------------------- |
| "spin up" / "spinup" / "start everything" / "set me up" / "boot up"          | `spinup`            |
| "restart everything" / "reset everything" / "nuke it"                        | `spinup`            |
| "the proxy is down" / "proxy crashed" / "gateway is broken" / "oc is broken" | `spinup oc`         |
| "restart openclaw" / "reset oc"                                              | `spinup oc`         |
| "dev-browser is broken" / "browser server crashed" / "restart mcp"           | `spinup mcp`        |
| "restart pwc" / "reset pwc"                                                  | `spinup pwc`        |
| "restart sermon" / "reset sermon"                                            | `spinup sermon`     |
| "restart realestate" / "reset realestate"                                    | `spinup realestate` |

### Internals

- **ANSI stripping**: service output piped through `sed -u "s/\x1b\[[0-9;]*m//g"` before `tee`.
- **Port cleanup**: `kill_port` runs before services that bind ports (kiro-proxy 18801, dev-browser 9222/9223).
- **`remain-on-exit on`**: crashed panes stay readable (`dead=1` detection in `spinup status`).

### Pane commands

| Pane        | Actual command                                                                                                      |
| ----------- | ------------------------------------------------------------------------------------------------------------------- |
| kiro-proxy  | `pnpm openclaw kiro-proxy --port 18801 --verbose --routes kiro-proxy-routes.json` (cwd: `~/code/personal/clawdbot`) |
| gateway     | `pnpm openclaw gateway run --verbose --force --port 18800 --bind loopback` (cwd: `~/code/personal/clawdbot`)        |
| sms-poller  | `scripts/sms-poller.sh` (cwd: `~/code/personal/clawdbot`)                                                           |
| kiro-cli    | `kiro-cli` (cwd: varies per session)                                                                                |
| dev-browser | kills ports 9222/9223, then `./server.sh --headless` (cwd: `~/code/work/dev-browser/skills/dev-browser`)            |
| excalidraw  | `PORT=3000 npm run canvas` (cwd: `~/code/work/mcp_excalidraw`)                                                      |

### Sessions & ports

| Session        | What runs                         | Ports            | Panes/Windows |
| -------------- | --------------------------------- | ---------------- | ------------- |
| **oc**         | kiro-proxy, gateway, sms-poller   | 18801, 18800     | 3 windows     |
| **oc-cli**     | kiro-cli                          | —                | 1 window      |
| **mcp**        | kiro-cli, dev-browser, excalidraw | 9222, 9223, 3000 | 3 windows     |
| **pwc**        | kiro-cli                          | —                | 1 pane        |
| **sermon**     | kiro-cli                          | —                | 1 pane        |
| **realestate** | kiro-cli                          | —                | 1 pane        |

### After running

1. Confirm exit code 0
2. Tell the user which sessions were started
3. Remind them to attach: `tmux attach -t <session-name>`
4. Services take ~5–10s to fully start. If user reports issues immediately, wait and recheck with `spinup status`.

### Logs

`spinup logs [name] [lines]` tails logs. Direct paths if needed:

| Service     | Log file                               |
| ----------- | -------------------------------------- |
| kiro-proxy  | `/tmp/kiro-proxy-YYYY-MM-DD.log`       |
| gateway     | `/tmp/openclaw-gateway-YYYY-MM-DD.log` |
| dev-browser | `/tmp/dev-browser-YYYY-MM-DD.log`      |

## Operational Diagnostics

### Checking context usage across all sessions

The kiro-proxy logs `context: X%` after each ACP response. The gateway logs
detailed `[context-diag]` entries with message counts, history chars, image
blocks, and system prompt size per session key.

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

The proxy's default idle timeout is 4 hours (`DEFAULT_IDLE_SECS = 14400` in
`session-manager.ts`). When a session goes idle, the proxy hibernates it:
kills the ACP child process but saves the session ID to
`~/.openclaw/kiro-proxy-hibernated.json`. On the next Discord message, it
spawns a new kiro-cli process and calls `loadSession` with the saved ID,
restoring the full conversation history. If `loadSession` fails, it falls
back to a fresh session automatically.

```
session hibernated: session=<key> acp=<id> ctx=X% reason=gc-idle-timeout (idle=14400s)
```

To disable hibernation for a specific route (kill outright, no context
preserved), add `"noHibernate": true` to that route in
`kiro-proxy-routes.json` and restart the proxy (`spinup oc --defer`).

### System resource baseline (exe.dev VM)

- 7.8GB RAM total, ~4.5GB available under normal load
- Gateway: ~390MB RSS (largest single process)
- kiro-proxy: ~180MB RSS
- Each kiro-cli ACP child: 65-90MB RSS
- dev-browser + Chromium: ~170MB combined
- Swap usage of 1-1.5GB is normal; watch for >3GB

### ACP session architecture (critical path)

The kiro-proxy spawns `kiro-cli acp` as direct child processes with
stdin/stdout ACP protocol pipes. These drive the entire Discord → kiro-cli
pipeline. The tmux `kiro-cli` sessions are separate interactive sessions
for manual use — NOT part of the Discord pipeline.

```bash
# List all ACP processes
ps aux | grep -E 'kiro-cli.*acp|kiro-cli-chat.*acp' | grep -v grep

# Cross-reference with proxy's known sessions
grep -E 'spawned|killing|gc-idle-timeout' /tmp/kiro-proxy.log | tail -20
```

### Diagnosing problems

First step is always `spinup status`. If a specific service is misbehaving:
`spinup logs gateway 50` (or `kiro-proxy`, `dev-browser`, `all`).

A pane showing `dead=1` means the process crashed but was preserved. Read with:
`tmux capture-pane -t <session>:<window>.<pane> -p | tail -20`

### Proxy admin API

The proxy exposes admin endpoints for session management:

```bash
# List all active sessions
curl -s http://localhost:18801/sessions | python3 -m json.tool

# Kill a specific channel's session (respawns with fresh config on next message)
curl -s -X POST http://localhost:18801/admin/kill/<channelId>

# Kill all idle sessions (skips sessions mid-prompt)
curl -s -X POST http://localhost:18801/admin/kill-all

# Hibernate a session (preserves context for later restore)
curl -s -X POST http://localhost:18801/hibernate/<sessionKey>
```

Use `/admin/kill-all` after changing `kiro-cli settings` (e.g. default model)
to force all sessions to respawn with the new config.

### Querying ACP sessions via the proxy

You can send text (including kiro-cli slash commands) to any channel's ACP
session through the proxy's OpenAI-compatible endpoint:

```bash
curl -s http://localhost:18801/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "x-openclaw-session-key: agent:main:discord:channel:<CHANNEL_ID>" \
  -d '{"model":"kiro-default","stream":false,"messages":[{"role":"user","content":"/model"}]}'
```

**Limitation:** kiro-cli slash commands only return output on the **first
prompt** of a fresh ACP session. After that, slash command output is not
routed through the ACP response stream (kiro-cli bug/limitation). Normal
text prompts work on every turn.

### Targeted recovery

- **Single pane crashed** → `spinup restart-pane <title>`
- **Whole session broken** → `spinup oc` / `spinup mcp` etc.
- **Only reset all** (`spinup`) if explicitly asked or multiple sessions are broken.
- **Stale config** (model change, settings update) → `curl -s -X POST http://localhost:18801/admin/kill-all`

### Conservative cleanup rule

Never kill an ACP process unless confirmed orphaned (no matching proxy session,
no recent activity). Long-running jobs are expected.

### Cross-session communication

Each Discord channel → kiro-cli ACP session is fully isolated. However, any
agent can query or manage other sessions through the proxy admin API
(`/sessions`, `/admin/kill/<channelId>`, `/v1/chat/completions` with a
target session key). The `#oc-tmux-session` agent can also monitor via logs
and `spinup status`.
