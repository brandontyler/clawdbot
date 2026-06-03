#!/usr/bin/env bash
# email-triage.sh — Daily inbox status + importance triage
#
# Each morning posts a Discord report with:
#   • Total unread count (Primary + Updates, no Promotions/Social/Spam)
#   • Last 24h vs older breakdown
#   • Oldest unread age
#   • Items worth attention (LLM-scored ≥ THRESHOLD)
#   • Cleanup/noise counts
#
# Dependencies: gog, kiro-cli, jq, curl
# Auth: GOG_KEYRING_PASSWORD env var
set -uo pipefail

source ~/.profile

DISCORD_CHANNEL="${EMAIL_DISCORD_CHANNEL:-1503414103341797406}"
DISCORD_TOKEN=$(jq -r '.channels.discord.token // empty' ~/.openclaw/openclaw.json 2>/dev/null)
THRESHOLD=6        # surface emails scoring this or higher
MAX_PULL=200       # how many unread to scan for stats
MAX_SCORE=50       # how many newest unread to send through the LLM

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# --- Pull all unread (Primary + Updates, no Promotions/Social/Spam) ---
log "Pulling up to $MAX_PULL unread emails..."
EMAILS_JSON=$(gog gmail list -a brandon.tyler@gmail.com -j --max "$MAX_PULL" \
  "is:unread -category:promotions -category:social -in:spam" 2>/dev/null)

if [ -z "$EMAILS_JSON" ]; then
  log "No emails returned or gog failed"
  exit 0
fi

# --- Inbox stats: total, last-24h, oldest-age ---
STATS=$(python3 <(cat <<'PY'
import sys, json, datetime
d = json.load(sys.stdin)
threads = d.get('threads', [])
total = len(threads)
now = datetime.datetime.now()
last_24h = 0
oldest = None
for t in threads:
    date = t.get('date', '')
    try:
        ts = datetime.datetime.strptime(date[:16], '%Y-%m-%d %H:%M')
        if (now - ts).total_seconds() < 86400:
            last_24h += 1
        if oldest is None or ts < oldest:
            oldest = ts
    except Exception:
        pass
older = total - last_24h
oldest_str = oldest.strftime('%Y-%m-%d') if oldest else '?'
days_old = (now - oldest).days if oldest else 0
print(f'{total}|{last_24h}|{older}|{oldest_str}|{days_old}')
PY
) <<< "$EMAILS_JSON")

IFS='|' read -r TOTAL LAST24 OLDER OLDEST_DATE OLDEST_DAYS <<< "$STATS"
log "Inbox: total=$TOTAL, 24h=$LAST24, older=$OLDER, oldest=$OLDEST_DATE (${OLDEST_DAYS}d)"

if [ "$TOTAL" -eq 0 ]; then
  log "Inbox zero — nothing to report"
  # Still send a positive confirmation so Brandon knows the script ran
  if [ -n "$DISCORD_TOKEN" ]; then
    PAYLOAD=$(jq -n --arg c "📧 **Email Status**

✅ Inbox zero — no unread emails." '{content: $c}')
    curl -s -X POST "https://discord.com/api/v10/channels/$DISCORD_CHANNEL/messages" \
      -H "Authorization: Bot $DISCORD_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$PAYLOAD" > /dev/null
  fi
  exit 0
fi

# --- Build threads list for LLM (newest first, capped at MAX_SCORE) ---
THREADS=$(echo "$EMAILS_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
threads = d.get('threads', [])
for i, t in enumerate(threads[:${MAX_SCORE}]):
    sender = t.get('from', '?')
    subject = t.get('subject', '?')
    date = t.get('date', '?')[:16]
    print(f'{i+1}. From: {sender} | Subject: {subject} | Date: {date}')
" 2>/dev/null)

SCORE_COUNT=$(echo "$THREADS" | grep -c '^[0-9]' || echo 0)
log "Scoring $SCORE_COUNT emails via kiro-cli..."

PROMPT="You are triaging Brandon's email inbox. Score each email 1-10 for importance/urgency.

SCORE 8-10 (URGENT — needs prompt action):
- Real human family/friend/colleague asking for response
- Time-sensitive money issue (failed payment, urgent bill)
- Kids' school requiring parent action
- Medical/insurance/legal requiring action

SCORE 6-7 (WORTH ATTENTION — should look at):
- Bills/statements he should review
- Real human emails (even if not urgent)
- Account changes requiring verification
- Amazon Subscribe & Save price changes
- Receipts for unfamiliar purchases

SCORE 4-5 (CAN WAIT — informational):
- Shipping confirmations, app notifications
- Order receipts for known purchases
- Newsletters he subscribed to
- Automated reports

SCORE 1-3 (NOISE — likely cleanup):
- Marketing/sales that slipped past filters
- Duplicate alerts, automated noise
- Emails from Brandon to himself (automation)

Emails:
${THREADS}

Reply ONLY with a JSON array of integers, one per email, in order. Example: [3,8,2,9,4]"

SCORES_RAW=$(cd "$HOME" && timeout 90 kiro-cli chat --no-interactive --wrap never "$PROMPT" 2>&1 | \
  sed 's/\x1b\[[0-9;]*m//g')
SCORES=$(echo "$SCORES_RAW" | grep -oP '\[[\d,\s]+\]' | head -1)

if [ -z "$SCORES" ]; then
  log "WARN: LLM scoring failed — reporting stats only"
  SCORES="[]"
fi
log "Scores: $SCORES"

# --- Build digest message ---
DIGEST=$(python3 <(cat <<'PY'
import sys, json

total = int(sys.argv[1])
last24 = int(sys.argv[2])
older = int(sys.argv[3])
oldest_date = sys.argv[4]
oldest_days = int(sys.argv[5])
scores_str = sys.argv[6]
threshold = int(sys.argv[7])

try:
    scores = json.loads(scores_str) if scores_str and scores_str != '[]' else []
except Exception:
    scores = []

d = json.load(sys.stdin)
threads = d.get('threads', [])

out = []
out.append("📧 **Email Status**")
out.append("")
out.append(f"📥 Unread: **{total}**" + (f" (capped, may be more)" if total >= 200 else ""))
out.append(f"   Last 24h: {last24} | Older: {older}")
if oldest_days >= 1:
    out.append(f"   Oldest: {oldest_date} ({oldest_days}d ago)")
out.append("")

attention = []
cleanup_count = 0
noise_count = 0
unscored_count = max(0, total - len(scores))

for i, t in enumerate(threads):
    if i >= len(scores):
        break
    s = scores[i]
    sender = t.get('from', '?')
    subject = t.get('subject', '?')
    date = t.get('date', '')[:10]
    if len(subject) > 80:
        subject = subject[:77] + '...'
    if s >= 8:
        attention.append(f"⭐ **{sender}** — {subject} ({date})")
    elif s >= threshold:
        attention.append(f"• {sender} — {subject} ({date})")
    elif s <= 3:
        noise_count += 1
    else:
        cleanup_count += 1

if attention:
    out.append(f"⭐ **Worth attention ({len(attention)}):**")
    out.extend(attention)
    out.append("")
else:
    out.append("✅ Nothing scored as needing attention")
    out.append("")

if cleanup_count > 0 or noise_count > 0 or unscored_count > 0:
    parts = []
    if cleanup_count: parts.append(f"{cleanup_count} can wait")
    if noise_count: parts.append(f"{noise_count} noise")
    if unscored_count: parts.append(f"{unscored_count} unscored")
    out.append(f"🗑️  Rest: " + " | ".join(parts))

print('\n'.join(out))
PY
) "$TOTAL" "$LAST24" "$OLDER" "$OLDEST_DATE" "$OLDEST_DAYS" "$SCORES" "$THRESHOLD" <<< "$EMAILS_JSON")

# --- Send to Discord ---
if [ -n "$DISCORD_TOKEN" ] && [ -n "$DIGEST" ]; then
  # Discord message limit is 2000 chars — truncate if needed
  if [ ${#DIGEST} -gt 1990 ]; then
    DIGEST="${DIGEST:0:1987}..."
  fi
  PAYLOAD=$(echo "$DIGEST" | jq -Rs '{content: .}')
  curl -s -X POST "https://discord.com/api/v10/channels/$DISCORD_CHANNEL/messages" \
    -H "Authorization: Bot $DISCORD_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" > /dev/null
  log "Discord: sent inbox status"
fi

log "Done"
