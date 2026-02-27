#!/usr/bin/env bash
# Add a new Discord channel + kiro-cli session for a project.
#
# Usage: scripts/add-channel.sh <session-name> <project-dir>
#   e.g.: scripts/add-channel.sh myproject ~/code/work/myproject
#
# What it does:
#   1. Creates a Discord text channel named #<session-name> in the guild
#   2. Adds the channel→cwd route to kiro-proxy-routes.json
#   3. Adds a tmux session block to ~/bin/spinup
#   4. Prints next steps (restart proxy, spinup new session)
#
# Requires: DISCORD_BOT_TOKEN env var or ~/.openclaw discord token config

set -euo pipefail

GUILD_ID="1457570909798797534"
ROUTES_FILE="kiro-proxy-routes.json"
SPINUP="$HOME/bin/spinup"
KIRO_MD=".kiro/KIRO.md"

die() { echo "ERROR: $*" >&2; exit 1; }

# --- args ---
NAME="${1:-}"
DIR="${2:-}"
[[ -n "$NAME" ]] || die "Usage: $0 <session-name> <project-dir>"
[[ -n "$DIR" ]]  || die "Usage: $0 <session-name> <project-dir>"

# Expand ~ and resolve
DIR="${DIR/#\~/$HOME}"
DIR="$(realpath -m "$DIR")"
[[ -d "$DIR" ]] || die "Directory does not exist: $DIR"

# --- Discord bot token ---
TOKEN="${DISCORD_BOT_TOKEN:-}"
if [[ -z "$TOKEN" ]]; then
  # Try reading from openclaw config
  TOKEN=$(python3 -c "
import json, os
with open(os.path.expanduser('~/.openclaw/openclaw.json')) as f:
    d = json.load(f)
t = d.get('channels',{}).get('discord',{}).get('token','')
print(t)
" 2>/dev/null || true)
fi
[[ -n "$TOKEN" ]] || die "No Discord bot token found. Set DISCORD_BOT_TOKEN or configure in openclaw."

# --- Create Discord channel ---
echo "Creating Discord channel #$NAME in guild $GUILD_ID..."
RESPONSE=$(curl -sS -X POST \
  "https://discord.com/api/v10/guilds/$GUILD_ID/channels" \
  -H "Authorization: Bot $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"name\": \"$NAME\", \"type\": 0}")

CHANNEL_ID=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || true)
if [[ -z "$CHANNEL_ID" || "$CHANNEL_ID" == "None" ]]; then
  echo "Discord API response: $RESPONSE" >&2
  die "Failed to create Discord channel"
fi
echo "  Created channel #$NAME with ID: $CHANNEL_ID"

# --- Add route to kiro-proxy-routes.json ---
echo "Adding route to $ROUTES_FILE..."
python3 -c "
import json
with open('$ROUTES_FILE') as f:
    routes = json.load(f)
routes['$CHANNEL_ID'] = {'cwd': '$DIR'}
with open('$ROUTES_FILE', 'w') as f:
    json.dump(routes, f, indent=2)
    f.write('\n')
"
echo "  Added: $CHANNEL_ID → $DIR"

# --- Add session to spinup ---
UPPER_NAME=$(echo "$NAME" | tr '-' '_' | tr '[:lower:]' '[:upper:]')
if grep -q "TARGET\" == \"$NAME\"" "$SPINUP" 2>/dev/null; then
  echo "  spinup already has a '$NAME' block — skipping"
else
  echo "Adding session block to $SPINUP..."
  # Insert before the final "Done." line
  sed -i "/^echo \"Done.\"/i\\
\\
# --- $NAME session ---\\
${UPPER_NAME}_DIR=$DIR\\
\\
if [[ \"\$TARGET\" == \"all\" || \"\$TARGET\" == \"$NAME\" ]]; then\\
  new_session $NAME -n main -c \"\$${UPPER_NAME}_DIR\" \"\$KIRO_CLI_CMD\"\\
  tag_pane $NAME $NAME:main.0 kiro-cli \"\$KIRO_CLI_CMD\"\\
  echo \"  tmux attach -t $NAME\"\\
fi" "$SPINUP"
  echo "  Added '$NAME' session block"

  # Also add to the status loop
  if ! grep -q "\"$NAME\"" <(grep 'for sess in' "$SPINUP"); then
    sed -i "s/for sess in oc oc-cli mcp pwc sermon/for sess in oc oc-cli mcp pwc sermon $NAME/" "$SPINUP"
    echo "  Added '$NAME' to status loop"
  fi
fi

echo ""
echo "=== Done ==="
echo "Channel: #$NAME (ID: $CHANNEL_ID)"
echo "Route:   $CHANNEL_ID → $DIR"
echo ""
echo "Next steps:"
echo "  1. Restart proxy:  spinup oc --defer"
echo "  2. Start session:  spinup $NAME"
echo "  3. Update KIRO.md channel table if desired"
