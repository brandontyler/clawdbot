# Setting Up clawdbot on a New Machine

One-time setup to get the OpenClaw + kiro-proxy system running on a fresh laptop.

## Prerequisites

Install these before running setup:

| Tool        | Install                                                                 |
| ----------- | ----------------------------------------------------------------------- |
| Node.js 22+ | https://nodejs.org or `nvm install 22`                                  |
| pnpm        | `npm i -g pnpm`                                                         |
| tmux        | `apt install tmux` / `brew install tmux`                                |
| python3     | Usually pre-installed                                                   |
| jq          | `apt install jq` / `brew install jq`                                    |
| kiro-cli    | `curl -fsSL https://cli.kiro.dev/install \| bash` then `kiro-cli login` |

## Quick Start

```bash
git clone <repo-url> ~/code/personal/clawdbot
cd ~/code/personal/clawdbot
scripts/setup.sh
```

The setup script will:

1. Check all dependencies are installed
2. Run `pnpm install`
3. Generate `kiro-proxy-routes.json` (prompts for your Discord channel ID)
4. Symlink `~/bin/spinup` to `scripts/spinup`
5. Configure `~/.openclaw/openclaw.json` (prompts for Discord bot token)
6. Run `pnpm build`

## Discord Bot Setup

If you're setting up a new Discord server (not reusing an existing bot):

1. Go to https://discord.com/developers/applications
2. Create a new application
3. Go to Bot → Reset Token → copy the token
4. Enable these Privileged Gateway Intents:
   - Message Content Intent
   - Server Members Intent
5. Go to OAuth2 → URL Generator:
   - Scopes: `bot`
   - Permissions: Send Messages, Read Message History, Manage Messages
6. Use the generated URL to invite the bot to your server
7. Pass the token to setup: `scripts/setup.sh --discord-token YOUR_TOKEN`

## Manual Configuration

If you skipped the guided setup or need to adjust settings:

```bash
# Discord bot token
pnpm openclaw config set channels.discord.token "YOUR_TOKEN"

# Gateway settings
pnpm openclaw config set gateway.mode local
pnpm openclaw config set gateway.port 18800 --strict-json
pnpm openclaw config set gateway.bind loopback

# Model provider (kiro-proxy)
pnpm openclaw config set models.providers.kiro.baseUrl "http://127.0.0.1:18801"
pnpm openclaw config set models.providers.kiro.apiKey "kiro-local"
pnpm openclaw config set models.providers.kiro.api "openai-completions"
```

## Running

```bash
spinup oc          # Start proxy (port 18801) + gateway (port 18800)
spinup oc-cli      # Start interactive kiro-cli session
spinup status      # Check health of all sessions
spinup logs        # Tail all logs
```

## Adding Project Channels

Each Discord channel maps to a project directory. The bot runs kiro-cli in that
directory when messages arrive in that channel.

```bash
scripts/add-channel.sh myproject ~/code/work/myproject
spinup oc --defer    # Restart proxy to pick up new route
spinup myproject     # Start the tmux session
```

## Running Two Instances Side-by-Side

You can run this on two machines simultaneously with separate Discord bots:

- Each machine needs its own Discord bot token (different bot application)
- Each machine gets its own `kiro-proxy-routes.json` (gitignored, machine-local)
- The `~/.openclaw/openclaw.json` config is also machine-local
- Channel IDs will differ between Discord servers

The repo itself is identical — just clone, run `scripts/setup.sh`, and configure
for the local Discord server.

## File Layout

| File                             | Tracked         | Purpose                                   |
| -------------------------------- | --------------- | ----------------------------------------- |
| `kiro-proxy-routes.json`         | No (gitignored) | Channel → project directory mapping       |
| `kiro-proxy-routes.example.json` | Yes             | Template for routes file                  |
| `~/.openclaw/openclaw.json`      | N/A             | Bot token, gateway config, model provider |
| `scripts/spinup`                 | Yes             | tmux session orchestrator                 |
| `~/bin/spinup`                   | N/A             | Symlink to `scripts/spinup`               |
| `scripts/setup.sh`               | Yes             | One-time bootstrap                        |
| `scripts/add-channel.sh`         | Yes             | Add a new project channel                 |
