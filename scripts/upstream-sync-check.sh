#!/usr/bin/env bash
# Daily upstream sync check — posts to #openclaw when a new STABLE release exists.
# Compares our running version against the latest stable tag (ignores beta).
# Includes: new features, patched-file conflict risk, and dep bumps.
set -euo pipefail

REPO_DIR="$HOME/code/personal/clawdbot"
CHANNEL_ID="1503414103341797406"
OUR_VERSION="2026.5.6"  # Update this after each sync

cd "$REPO_DIR"

# Fetch tags + commits
git fetch upstream --quiet --tags 2>/dev/null || { echo "fetch failed"; exit 1; }

# Find latest stable tag (no beta suffix)
LATEST_STABLE=$(git tag -l 'v2026.*' --sort=-v:refname | grep -v beta | head -1)
LATEST_STABLE_VERSION="${LATEST_STABLE#v}"

# Compare against our version
if [ "$LATEST_STABLE_VERSION" = "$OUR_VERSION" ]; then
  exit 0  # already on latest stable, no notification needed
fi

# How many stable releases we're behind
STABLE_TAGS_AHEAD=$(git tag -l 'v2026.*' --sort=-v:refname | grep -v beta | while read tag; do
  ver="${tag#v}"
  if [[ "$ver" > "$OUR_VERSION" ]]; then echo "$tag"; fi
done | wc -l || echo 0)

# Commits between our version tag and latest stable
OUR_TAG="v${OUR_VERSION}"
BEHIND=$(git rev-list --count "${OUR_TAG}..${LATEST_STABLE}" 2>/dev/null || echo "?")

# --- What's new (commits between our tag and latest stable) ---
FEATS=$(git log --oneline "${OUR_TAG}..${LATEST_STABLE}" --no-merges --grep='^feat' --regexp-ignore-case 2>/dev/null | head -15 || true)
FEAT_COUNT=$(git log --oneline "${OUR_TAG}..${LATEST_STABLE}" --no-merges --grep='^feat' --regexp-ignore-case 2>/dev/null | wc -l || echo 0)
FEAT_SECTION=""
if [ -n "$FEATS" ]; then
  FEAT_SECTION=$'\n'"🆕 **New features since v${OUR_VERSION}** (${FEAT_COUNT}):"$'\n'
  while IFS= read -r line; do
    msg="${line#* }"
    FEAT_SECTION+="• ${msg}"$'\n'
  done <<< "$FEATS"
  if [ "$FEAT_COUNT" -gt 15 ]; then
    FEAT_SECTION+="  …and $((FEAT_COUNT - 15)) more"$'\n'
  fi
fi

# --- Fixes ---
FIXES=$(git log --oneline "${OUR_TAG}..${LATEST_STABLE}" --no-merges --grep='^fix' --regexp-ignore-case 2>/dev/null | wc -l || echo 0)

# --- Patched files that changed upstream (conflict risk) ---
PATCHED_FILES=(
  "extensions/discord/src/gateway-logging.ts"
  "src/auto-reply/reply/queue/settings.ts"
  "src/auto-reply/reply/typing.ts"
  "extensions/discord/src/monitor/timeouts.ts"
  "extensions/discord/src/config-ui-hints.ts"
  "src/config/types.discord.ts"
  "src/cli/program/register.subclis-core.ts"
  "src/cli/program/subcli-descriptors.ts"
  "src/gateway/channel-health-monitor.ts"
  "src/index.ts"
  "src/agents/pi-embedded-runner/run/attempt.ts"
  "extensions/discord/src/monitor/gateway-plugin.ts"
  "extensions/discord/src/monitor/provider.ts"
  "package.json"
  "pnpm-workspace.yaml"
  ".gitignore"
)

CHANGED_PATCHED=""
CHANGED_COUNT=0
for f in "${PATCHED_FILES[@]}"; do
  if git diff --quiet "${OUR_TAG}..${LATEST_STABLE}" -- "$f" 2>/dev/null; then
    continue
  else
    CHANGED_COUNT=$((CHANGED_COUNT + 1))
    ADD_DEL=$(git diff --numstat "${OUR_TAG}..${LATEST_STABLE}" -- "$f" 2>/dev/null | awk '{printf "+%s/-%s", $1, $2}')
    CHANGED_PATCHED+="• \`${f}\` (${ADD_DEL})"$'\n'
  fi
done

PATCH_SECTION=""
if [ "$CHANGED_COUNT" -gt 0 ]; then
  PATCH_SECTION=$'\n'"⚠️ **Patched files changed** (${CHANGED_COUNT}/${#PATCHED_FILES[@]}):"$'\n'
  PATCH_SECTION+="${CHANGED_PATCHED}"
  PATCH_SECTION+="Review these against \`UPSTREAM.md\` during rebase."$'\n'
else
  PATCH_SECTION=$'\n'"✅ **No patched files changed** — clean rebase expected."$'\n'
fi

# --- Overall diff stats ---
STAT_SUMMARY=$(git diff --shortstat "${OUR_TAG}..${LATEST_STABLE}" 2>/dev/null || echo "")

# --- Compose message ---
MSG="📦 **Upstream Sync — New Stable Release Available**

We're on: \`v${OUR_VERSION}\`
Latest stable: \`${LATEST_STABLE}\`
**${STABLE_TAGS_AHEAD} stable release(s)** ahead, ${BEHIND} commits
Overall:${STAT_SUMMARY}
${FEAT_SECTION}
🔧 **Fixes:** ${FIXES} bug fixes since our version
${PATCH_SECTION}
Upgrade when you have a window for a proxy restart."

# Discord 2000 char limit
if [ "${#MSG}" -gt 1950 ]; then
  MSG="${MSG:0:1920}…

*(truncated — run \`scripts/upstream-sync-check.sh --local\` for full output)*"
fi

# --local flag: print to stdout
if [[ "${1:-}" == "--local" ]]; then
  echo "$MSG"
  exit 0
fi

# Post via Discord API
TOKEN=$(python3 -c "import json; d=json.load(open('$HOME/.openclaw/openclaw.json')); print(d.get('channels',{}).get('discord',{}).get('token','') or d.get('plugins',{}).get('entries',{}).get('discord',{}).get('config',{}).get('token',''))" 2>/dev/null)
if [ -z "$TOKEN" ]; then
  TOKEN=$(grep -o '"token": "[^"]*"' ~/.openclaw/openclaw.json | head -1 | cut -d'"' -f4)
fi

if [ -z "$TOKEN" ]; then
  echo "no discord token"
  exit 1
fi

curl -s -X POST "https://discord.com/api/v10/channels/${CHANNEL_ID}/messages" \
  -H "Authorization: Bot ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg content "$MSG" '{content: $content}')" > /dev/null

echo "posted sync reminder (${STABLE_TAGS_AHEAD} stable releases ahead, latest: ${LATEST_STABLE})"
