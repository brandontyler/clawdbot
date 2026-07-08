#!/usr/bin/env bash
# email-triage.sh — Surfaces important unread emails via Discord
#
# Strategy:
#   1. Pull unread emails from last 24h (Primary + Updates, skip Promotions/Social/Spam)
#   2. kiro-cli scores each by sender + subject for importance
#   3. Only high-scoring emails (≥8) get surfaced to Discord
#
# Dependencies: gog, kiro-cli, jq, curl
# Auth: GOG_KEYRING_PASSWORD env var
set -uo pipefail

source ~/.profile

DISCORD_CHANNEL="${EMAIL_DISCORD_CHANNEL:-1503414103341797406}"
DISCORD_TOKEN=$(jq -r '.channels.discord.token // empty' ~/.openclaw/openclaw.json 2>/dev/null)
THRESHOLD=8

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# --- Pull unread emails (last 24h, Primary + Updates) ---
log "Pulling unread emails from last 24h..."
EMAILS_JSON=$(gog gmail list -a brandon.tyler@gmail.com -j \
  "is:unread newer_than:1d -category:promotions -category:social -in:spam" 2>/dev/null)

if [ -z "$EMAILS_JSON" ]; then
  log "No emails or gog failed"
  exit 0
fi

# Extract sender + subject for each thread
THREADS=$(echo "$EMAILS_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
threads = d.get('threads', [])
for i, t in enumerate(threads):
    sender = t.get('from', '?')
    subject = t.get('subject', '?')
    date = t.get('date', '?')
    labels = t.get('labels', [])
    is_primary = 'CATEGORY_PERSONAL' in labels or not any(l.startswith('CATEGORY_') for l in labels)
    cat = 'PRIMARY' if is_primary else 'UPDATES'
    print(f'{i+1}. [{cat}] From: {sender} | Subject: {subject} | Date: {date}')
" 2>/dev/null)

COUNT=$(echo "$THREADS" | grep -c '^[0-9]' || echo 0)
log "Found $COUNT unread threads"

if [ "$COUNT" -eq 0 ]; then
  log "No unread emails — nothing to triage"
  exit 0
fi

# --- LLM scoring ---
log "Scoring $COUNT emails via kiro-cli..."

PROMPT="You are triaging Brandon's email inbox. Score each email 1-10 for importance/urgency.

SCORE 8-10 (SURFACE — needs attention):
- From a real person Brandon knows (family, church friends, colleagues)
- Asks Brandon to DO something (reply, RSVP, sign, pay, decide)
- Time-sensitive (appointment, deadline, expiring offer that matters)
- Money that needs action (payment failed, bill due, refund issue)
- Kids' school requiring parent action
- Amazon Subscribe & Save price changes (he reviews these)

SCORE 4-7 (SKIP — informational, can wait):
- Automated notifications that don't need action
- Job alerts (handled by separate system)
- Shipping confirmations
- App/service notifications
- Newsletters he subscribed to

SCORE 1-3 (IGNORE — noise):
- Marketing/sales emails that slipped past Gmail filters
- Duplicate alerts
- Emails from Brandon to himself (automated sends)
- Generic automated reports with no action needed

Emails:
${THREADS}

Reply ONLY with a JSON array of integers. Example: [3,8,2,9,4]"

SCORES=$(cd "$HOME" && timeout 45 kiro-cli chat --no-interactive --wrap never "$PROMPT" 2>&1 | \
  sed 's/\x1b\[[0-9;]*m//g' | grep -oP '\[[\d,\s]+\]' | head -1)

if [ -z "$SCORES" ]; then
  log "WARN: LLM scoring failed — skipping triage"
  exit 0
fi

log "Scores: $SCORES"

# --- Build digest of important emails ---
IMPORTANT=$(echo "$EMAILS_JSON" | python3 -c "
import sys, json

scores_str = '''${SCORES}'''
scores = json.loads(scores_str)

d = json.load(sys.stdin)
threads = d.get('threads', [])

results = []
for i, t in enumerate(threads):
    if i >= len(scores):
        break
    if scores[i] >= ${THRESHOLD}:
        sender = t.get('from', '?')
        subject = t.get('subject', '?')
        date = t.get('date', '?')
        results.append(f'• **{sender}** — {subject} ({date})')

if results:
    print('📧 **Emails needing attention:**\n')
    print('\n'.join(results))
else:
    print('')
" 2>/dev/null)

if [ -z "$IMPORTANT" ]; then
  log "No important emails found (all scored below $THRESHOLD)"
  exit 0
fi

IMPORTANT_COUNT=$(echo "$IMPORTANT" | grep -c "^•" || echo 0)
log "Surfacing $IMPORTANT_COUNT important emails"

# --- Send to Discord ---
if [ -n "$DISCORD_TOKEN" ] && [ -n "$IMPORTANT" ]; then
  curl -s -X POST "https://discord.com/api/v10/channels/$DISCORD_CHANNEL/messages" \
    -H "Authorization: Bot $DISCORD_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"content\":$(echo "$IMPORTANT" | jq -Rs .)}" > /dev/null
  log "Discord: sent email triage"
fi

log "Done"
