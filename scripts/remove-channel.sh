#!/usr/bin/env bash
# Remove a Discord channel + kiro-cli session for a project.
#
# Usage: scripts/remove-channel.sh <session-name>
#   e.g.: scripts/remove-channel.sh myproject
#
# What it does:
#   1. Finds the channel ID from kiro-proxy-routes.json by matching cwd or name
#   2. Removes the route from kiro-proxy-routes.json
#   3. Kills the tmux session if running
#   4. Prints reminder to optionally delete the Discord channel manually
#
# Does NOT delete the Discord channel (safety — do that manually).

set -euo pipefail

ROUTES_FILE="kiro-proxy-routes.json"
SPINUP="$HOME/bin/spinup"

die() { echo "ERROR: $*" >&2; exit 1; }

NAME="${1:-}"
[[ -n "$NAME" ]] || die "Usage: $0 <session-name>"

# --- Find and remove route ---
REMOVED=$(python3 -c "
import json, sys
with open('$ROUTES_FILE') as f:
    routes = json.load(f)
# Find by session name in cwd path
to_remove = [k for k, v in routes.items() if '/$NAME' in v.get('cwd','').lower() or v.get('cwd','').lower().endswith('/$NAME')]
if not to_remove:
    print('none')
    sys.exit(0)
for k in to_remove:
    print(f'{k} -> {routes[k][\"cwd\"]}')
    del routes[k]
with open('$ROUTES_FILE', 'w') as f:
    json.dump(routes, f, indent=2)
    f.write('\n')
" 2>/dev/null)

if [[ "$REMOVED" == "none" ]]; then
  echo "No route found matching '$NAME' in $ROUTES_FILE"
else
  echo "Removed route(s): $REMOVED"
fi

# --- Kill tmux session ---
if tmux has-session -t "$NAME" 2>/dev/null; then
  tmux kill-session -t "$NAME"
  echo "Killed tmux session: $NAME"
else
  echo "No tmux session '$NAME' running"
fi

echo ""
echo "Reminder: manually delete the Discord channel if no longer needed."
echo "Reminder: remove the '$NAME' block from $SPINUP if desired."
echo "Restart proxy to apply: spinup oc --defer"
