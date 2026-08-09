#!/usr/bin/env bash
# memory-guard-cron.sh — daily Cognitive-State poisoning check (bead openclaw-79b).
# Runs memory-guard.py --check over ~/.kiro/memory.md + SKILL.md files and, on any
# HIGH finding (invisible Unicode / forged chat-template token), posts a Discord
# alert to #openclaw-ec2. This removes the "silent" from silent memory poisoning.
set -uo pipefail
source ~/.profile 2>/dev/null || true
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REPORT=$(python3 "$SCRIPT_DIR/memory-guard.py" --check 2>&1); RC=$?

if [ "$RC" -ne 0 ]; then
  CHANNEL="${MEMGUARD_DISCORD_CHANNEL:-1503414103341797406}"
  TOKEN=$(jq -r '.channels.discord.token // empty' ~/.openclaw/openclaw.json 2>/dev/null)
  DETAIL=$(printf '%s\n' "$REPORT" | grep -E 'HIGH|invisible|chat-token' | head -20)
  MSG="🛡️ **memory-guard: poisoning signal in persistent memory/skills**
Invisible Unicode or a forged chat-template token was found in memory.md or a SKILL.md — a possible Cognitive-State trap. Investigate before the next agent run.
\`\`\`
${DETAIL}
\`\`\`"
  if [ -n "$TOKEN" ]; then
    curl -s -X POST "https://discord.com/api/v10/channels/$CHANNEL/messages" \
      -H "Authorization: Bot $TOKEN" -H "Content-Type: application/json" \
      -d "{\"content\":$(printf '%s' "$MSG" | jq -Rs .)}" >/dev/null 2>&1
  else
    echo "$MSG" >&2
  fi
  exit 1
fi
exit 0
