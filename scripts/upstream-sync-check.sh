#!/usr/bin/env bash
# Daily upstream sync check — posts to #openclaw if we're behind.
set -euo pipefail

REPO_DIR="$HOME/code/personal/clawdbot"
CHANNEL_ID="1475513267433767014"

cd "$REPO_DIR"

# Fetch quietly
git fetch upstream --quiet 2>/dev/null || { echo "fetch failed"; exit 1; }

BEHIND=$(git rev-list --count HEAD..upstream/main 2>/dev/null || echo "?")
MERGE_BASE=$(git merge-base HEAD upstream/main 2>/dev/null | head -c 10)
LATEST_TAG=$(git tag -l 'v2026.*' --sort=-v:refname | head -1)
UPSTREAM_HEAD=$(git log --oneline upstream/main -1 2>/dev/null | head -c 80)

if [ "$BEHIND" = "0" ]; then
  exit 0  # up to date, no notification needed
fi

MSG="📦 **Upstream Sync Reminder**

We're **${BEHIND} commits** behind \`upstream/main\`.
Merge base: \`${MERGE_BASE}\`
Latest upstream tag: \`${LATEST_TAG}\`
Upstream HEAD: \`${UPSTREAM_HEAD}\`

Run the sync when you have a window for a proxy restart."

# Post via Discord API
TOKEN=$(python3 -c "import json; print(json.load(open('$HOME/.openclaw/openclaw.json'))['channels']['discord']['token'])" 2>/dev/null)
if [ -z "$TOKEN" ]; then
  echo "no discord token"
  exit 1
fi

curl -s -X POST "https://discord.com/api/v10/channels/${CHANNEL_ID}/messages" \
  -H "Authorization: Bot ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg content "$MSG" '{content: $content}')" > /dev/null

echo "posted sync reminder (${BEHIND} behind)"
