# Kiro Ops — EC2 (systemd)

This is the operations guide for the EC2 instance. Services run as **systemd user units** under the `ubuntu` user.

## Services

| Unit                       | Port  | Description                                                  |
| -------------------------- | ----- | ------------------------------------------------------------ |
| `openclaw-gateway.service` | 18800 | OpenClaw gateway (Discord inbound, agent routing)            |
| `kiro-proxy.service`       | 18801 | Kiro CLI proxy (ACP session management, channel→cwd routing) |
| `excalidraw.service`       | 3000  | Excalidraw MCP canvas server                                 |
| `dev-browser.service`      | —     | Dev-browser daemon (auto-starts via CLI, Unix socket)        |

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
systemctl --user list-units 'openclaw*' 'kiro*' 'excalidraw*' 'dev-browser*'
```

## Scheduled Timers

```bash
# List active timers
systemctl --user list-timers

# Check a specific timer
systemctl --user status x-digest.timer

# Run a timer job manually
systemctl --user start x-digest.service
```

| Timer                     | Schedule (UTC) | CDT            | What                                                                            |
| ------------------------- | -------------- | -------------- | ------------------------------------------------------------------------------- |
| `ai-agent-jobs.timer`     | 07:30          | 2:30am         | Brandon's hands-on AI-agent/LLM/Amazon Connect job search                       |
| `nathan-jobs.timer`       | 08:30          | 3:30am         | Nathan's teaching/youth/nonprofit job search                                    |
| `x-digest.timer`          | 10:00          | 5:00am         | X/Twitter digest (moved from 5:30 so it finishes before Morning Signal)         |
| `morning-signal.timer`    | 10:15 Mon–Wed  | 5:15am Mon–Wed | Morning Signal podcast to `#openclaw-ec2` by about 5:30 (text fallback by 6:00) |
| `x-bookmark-review.timer` | 11:15          | 6:15am         | X bookmark review                                                               |

> **Retired:** The firefighter job search is no longer used. The repository and live `fire-jobs.timer` units were removed. Do not run `fire-jobs.service` or recreate its timer unless Brandon explicitly reverses this decision.

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

## Gateway Health Monitor

`kiro-proxy-heartbeat.timer` runs every five minutes and publishes four independent
CloudWatch metrics in `OpenClawProxy`:

- `ProxyHealthy` — proxy HTTP liveness on port 18801.
- `GatewayHealthy` — shallow Gateway `/healthz` liveness. The existing
  `openclaw-gateway-down` alarm uses this metric.
- `GatewayReady` — `/readyz` channel/startup readiness; it does not trigger a
  restart by itself.
- `ControlUiHealthy` — `/` availability, kept separate from Gateway liveness.

After three consecutive `/healthz` failures, the monitor writes a private,
bounded incident bundle under
`~/.openclaw/incidents/gateway-health/<timestamp>/`. It captures probe status
and errors, service state, recent journals, listeners, resource state, safe
proxy session metadata, and runtime-artifact timestamps/hashes before any
recovery decision.

Recovery is **diagnostic-only by default**. Optional Phase B recovery can only
restart `openclaw-gateway.service`; it never stops or restarts `kiro-proxy`.
It defers while any ACP session is prompting or proxy activity cannot be
verified, permits one attempt per incident, and enforces a 30-minute cooldown.

```bash
# Monitor status and logs
systemctl --user status kiro-proxy-heartbeat.timer
journalctl --user -u kiro-proxy-heartbeat.service -n 100 --no-pager

# Compare/install the repository-owned units
./ops/install-systemd-units.sh --diff \
  --unit=kiro-proxy-heartbeat.service \
  --unit=kiro-proxy-heartbeat.timer
./ops/install-systemd-units.sh --enable \
  --unit=kiro-proxy-heartbeat.service \
  --unit=kiro-proxy-heartbeat.timer

# After a successful diagnostic soak, explicitly enable guarded Phase B
mkdir -p ~/.config/openclaw
cp ops/systemd/openclaw-health-monitor.env.example \
  ~/.config/openclaw/health-monitor.env
# Set OPENCLAW_HEALTH_RECOVERY_MODE=restart, then:
systemctl --user restart kiro-proxy-heartbeat.timer
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

Several Google Workspace jobs (including `email-triage`) read `GOG_KEYRING_PASSWORD`
via `EnvironmentFile=/home/ubuntu/.config/systemd/user/gog.env`.

On a fresh box:

```bash
cp ops/systemd/gog.env.example ~/.config/systemd/user/gog.env
chmod 600 ~/.config/systemd/user/gog.env
# Edit and put the real keyring password
```

The real `gog.env` is gitignored. `gog.env.example` (committed) is a placeholder.
