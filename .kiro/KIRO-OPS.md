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
| `upstream-sync.timer` | 13:00 | 8:00am | OpenClaw upstream sync |

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

## Deferred Restart (from Discord)

**CRITICAL:** When running as a Discord agent, restarting the proxy kills your own
ACP session mid-response. Always use a deferred restart so the Discord reply
delivers before the proxy goes down.

```bash
# Deferred proxy restart (30s delay — enough for response delivery)
(sleep 30 && systemctl --user restart kiro-proxy) &

# Deferred full restart (proxy + gateway)
(sleep 30 && systemctl --user restart kiro-proxy && sleep 5 && systemctl --user restart openclaw-gateway) &
```

After issuing the deferred restart, finish your Discord response immediately.
The session will drop after ~30s and reconnect automatically when the proxy
comes back up (2-3 seconds). No manual intervention needed.

**Never** run `systemctl --user restart kiro-proxy` synchronously from a Discord
agent session — it will hang and the response will never deliver.

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
