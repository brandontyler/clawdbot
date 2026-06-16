# Kiro Ops — EC2 (systemd)

This is the operations guide for the EC2 instance. Services run as **systemd user units** under the `ubuntu` user.

## Services

| Unit | Port | Description |
|------|------|-------------|
| `openclaw-gateway.service` | 18800 | OpenClaw gateway (Discord inbound, agent routing) |
| `kiro-proxy.service` | 18801 | Kiro CLI proxy (ACP session management, channel→cwd routing) |
| `excalidraw.service` | 3000 | Excalidraw MCP canvas server |
| `dev-browser.service` | — | Dev-browser daemon (auto-starts via CLI, Unix socket) |

## Common Commands

```bash
# Status
systemctl --user status openclaw-gateway
systemctl --user status kiro-proxy

# Restart a service
systemctl --user restart openclaw-gateway
systemctl --user restart kiro-proxy

# Tail logs (live)
journalctl --user -u openclaw-gateway -f
journalctl --user -u kiro-proxy -f

# Recent logs (last 100 lines)
journalctl --user -u openclaw-gateway -n 100 --no-pager

# All services at once
systemctl --user list-units 'openclaw*' 'kiro*' 'excalidraw*' 'dev-browser*' 'fire-jobs*'
```

## Scheduled Timers

```bash
# List active timers
systemctl --user list-timers

# Check a specific timer
systemctl --user status fire-jobs.timer

# Run a timer job manually
systemctl --user start fire-jobs.service
```

| Timer | Schedule (UTC) | CDT | What |
|-------|---------------|-----|------|
| `fire-jobs.timer` | 11:30 | 6:30am | North TX firefighter job search |
| `x-digest.timer` | 11:00 | 6:00am | X/Twitter digest |
| `x-bookmark-review.timer` | 11:15 | 6:15am | X bookmark review |

## Dev-Browser

The dev-browser daemon communicates via Unix socket (`~/.dev-browser/daemon.sock`), not network ports.

```bash
# Check status
dev-browser status

# Restart (if stuck)
dev-browser stop
dev-browser --headless status   # auto-starts fresh daemon

# Use in scripts
dev-browser --headless --timeout 30 <<'EOF'
const page = await browser.newPage();
await page.goto("https://example.com", { waitUntil: "commit" });
console.log(await page.title());
await page.close();
EOF
```

## Key Differences from Laptop

- No tmux, no `~/bin/spinup` — everything is systemd
- No `tylerbtt` AWS profile — use `personal` profile
- No mwinit/Isengard — EC2 uses instance role + named profiles
- Logs via `journalctl`, not `/tmp/*.log`
- dev-browser uses pipe mode (Unix socket), not CDP ports 9222/9223
- Discord admin channel: `#openclaw-ec2` (ID: `1503414103341797406`)

## Diagnostics

```bash
# System health
uptime && free -h && df -h /

# All kiro/openclaw processes
ps aux | grep -E 'openclaw|kiro' | grep -v grep

# ACP sessions
ps aux | grep 'kiro-cli.*acp' | grep -v grep

# Check proxy sessions
curl -s http://localhost:18801/sessions 2>/dev/null | python3 -m json.tool

# Config health
cat ~/.openclaw/logs/config-health.json | python3 -m json.tool
```

## Restart Order

If everything needs restarting:
```bash
systemctl --user restart kiro-proxy
sleep 5
systemctl --user restart openclaw-gateway
```

The gateway depends on the proxy (configured via `Requires=kiro-proxy.service`).

## Deferred Restart (from Discord) — ABSOLUTE RULE

🚨 **NEVER run `systemctl --user stop` or `systemctl --user restart` of
`kiro-proxy` or `openclaw-gateway` synchronously from a project Discord
channel.** This is not "slow" — it's an **outage**. The flow:

1. Agent issues `systemctl restart kiro-proxy`
2. Proxy SIGTERMs the agent's own ACP session mid-call
3. Agent process dies before the start half of the restart can complete
4. `Restart=always` does NOT cover manual stops/restarts → services stay DOWN
5. All 8 project channels are silent until somebody manually starts them

This happened 4 times on 2026-06-15 alone (bead `openclaw-gvm`). Use the
deferred pattern, no exceptions:

```bash
# Proxy only
(sleep 30 && systemctl --user restart kiro-proxy) &

# Full stack (proxy + gateway)
(sleep 30 && systemctl --user restart kiro-proxy && \
   sleep 5 && systemctl --user restart openclaw-gateway) &
```

After issuing the deferred restart, **finish your Discord reply immediately**.
The session drops after ~30s and reconnects automatically when the proxy
comes back (~3s). No manual intervention needed.

The only restart sources that may be synchronous:
- A shell run by Brandon directly
- The `#hermes-kiro-ec2` bot (different profile, different gateway, not affected)

## Don't "Maintain" hibernated.json — ABSOLUTE RULE

🚨 **`~/.openclaw/state/kiro-proxy-hibernated.json` does not need cleanup.**
It's a dict keyed by session key, one entry per channel that has ever been
hibernated. Apparent "duplicates" between hibernated.json and live in-memory
sessions are intentional cache layering (disk snapshot + live state showing
the same key). Apparent "drift upward" after a restart is the proxy reloading
all 8 hibernated entries from disk, which is correct.

If a session genuinely needs to be evicted (channel deleted, route removed),
the right tool is `scripts/remove-channel.sh <name>` — not hand-editing
hibernated.json. Hand-editing this file from inside a project Discord channel
is the most common cause of self-induced outages on this box.

## Systemd Units (managed via `ops/systemd/`)

All `.service` and `.timer` files used on this EC2 box are committed to
`ops/systemd/units/`. The installer keeps the live `~/.config/systemd/user/`
directory in sync with the repo.

### Common operations

```bash
# Show what would change vs the live state (dry-run)
./ops/install-systemd-units.sh --dry-run

# See unified diff for any changed units
./ops/install-systemd-units.sh --diff

# Apply changes (copies + daemon-reload)
./ops/install-systemd-units.sh

# First-time setup on a fresh box: install + enable all timers
./ops/install-systemd-units.sh --enable
```

### Editing a unit

Edit the file under `ops/systemd/units/`, then run the installer to push it
live. Don't edit `~/.config/systemd/user/*` directly — they'll get overwritten
on the next install run, and the change will never be in git.

### gog.env (secrets — not in git)

Several services (`fire-jobs`, `email-triage`, etc.) read `GOG_KEYRING_PASSWORD`
via `EnvironmentFile=/home/ubuntu/.config/systemd/user/gog.env`.

On a fresh box:
```bash
cp ops/systemd/gog.env.example ~/.config/systemd/user/gog.env
chmod 600 ~/.config/systemd/user/gog.env
# Edit and put the real keyring password
```

The real `gog.env` is gitignored. `gog.env.example` (committed) is a placeholder.
