#!/usr/bin/env bash
# Daily upstream sync check — posts to #openclaw if we're behind.
# Includes: new features, patched-file conflict risk, and dep bumps.
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

# --- New features ---
FEATS=$(git log --oneline "$MERGE_BASE"..upstream/main --no-merges --grep='^feat' --regexp-ignore-case | head -15 || true)
FEAT_COUNT=$(git log --oneline "$MERGE_BASE"..upstream/main --no-merges --grep='^feat' --regexp-ignore-case | wc -l || echo 0)
FEAT_SECTION=""
if [ -n "$FEATS" ]; then
  FEAT_SECTION=$'\n'"🆕 **New features** (${FEAT_COUNT}):"$'\n'
  while IFS= read -r line; do
    msg="${line#* }"
    FEAT_SECTION+="• ${msg}"$'\n'
  done <<< "$FEATS"
  if [ "$FEAT_COUNT" -gt 15 ]; then
    FEAT_SECTION+="  …and $((FEAT_COUNT - 15)) more"$'\n'
  fi
fi

# --- Patched files that changed upstream (conflict risk) ---
# Keep in sync with UPSTREAM.md "Upstream Files We Patch" table
PATCHED_FILES=(
  "extensions/discord/src/monitor/gateway-plugin.ts"
  "extensions/discord/src/monitor/provider.ts"
  "extensions/discord/src/gateway-logging.ts"
  "extensions/discord/src/monitor/provider.lifecycle.reconnect.ts"
  "src/index.ts"
  "src/auto-reply/reply/queue/settings.ts"
  "src/auto-reply/reply/typing.ts"
  "src/auto-reply/commands-registry.data.ts"
  "src/auto-reply/commands-registry.shared.ts"
  "src/auto-reply/reply/commands-handlers.runtime.ts"
  "src/cli/program/register.subclis.ts"
  "src/agents/pi-embedded-runner/run/attempt.ts"
  "package.json"
  ".gitignore"
  "src/logging/console.ts"
  "src/gateway/channel-health-monitor.ts"
  "src/auto-reply/command-detection.ts"
  "extensions/discord/src/monitor/message-handler.preflight.ts"
  "src/plugin-sdk/command-auth.ts"
  "extensions/slack/package.json"
)

CHANGED_PATCHED=""
CHANGED_COUNT=0
for f in "${PATCHED_FILES[@]}"; do
  if git diff --quiet "$MERGE_BASE"..upstream/main -- "$f" 2>/dev/null; then
    continue
  fi
  CHANGED_COUNT=$((CHANGED_COUNT + 1))
  ADD_DEL=$(git diff --numstat "$MERGE_BASE"..upstream/main -- "$f" 2>/dev/null | awk '{printf "+%s/-%s", $1, $2}')
  CHANGED_PATCHED+="• \`${f}\` (${ADD_DEL})"$'\n'
done

PATCH_SECTION=""
if [ "$CHANGED_COUNT" -gt 0 ]; then
  PATCH_SECTION=$'\n'"⚠️ **Patched files changed upstream** (${CHANGED_COUNT}/${#PATCHED_FILES[@]}):"$'\n'
  PATCH_SECTION+="${CHANGED_PATCHED}"
  PATCH_SECTION+="Review these against \`UPSTREAM.md\` during rebase."$'\n'
else
  PATCH_SECTION=$'\n'"✅ **No patched files changed** — clean rebase expected."$'\n'
fi

# --- Overall diff stats ---
STAT_SUMMARY=$(git diff --shortstat "$MERGE_BASE"..upstream/main 2>/dev/null || echo "")

# --- Compose message ---
MSG="📦 **Upstream Sync Reminder**

We're **${BEHIND} commits** behind \`upstream/main\`.
Merge base: \`${MERGE_BASE}\`
Latest upstream tag: \`${LATEST_TAG}\`
Upstream HEAD: \`${UPSTREAM_HEAD}\`
Overall:${STAT_SUMMARY}
${FEAT_SECTION}${PATCH_SECTION}
Run the sync when you have a window for a proxy restart."

# Discord has a 2000 char limit — truncate if needed
if [ "${#MSG}" -gt 1950 ]; then
  MSG="${MSG:0:1920}…

*(truncated — run \`scripts/upstream-sync-check.sh --local\` for full output)*"
fi

# --local flag: print to stdout instead of posting
if [[ "${1:-}" == "--local" ]]; then
  echo "$MSG"
  exit 0
fi

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
