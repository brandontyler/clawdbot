#!/usr/bin/env bash
# x-bookmark-review.sh — Daily bookmark review via bird CLI + DynamoDB dedup
#
# Fetches X bookmarks, filters out previously seen ones (DynamoDB), posts
# new bookmarks to Discord #openclaw for interactive triage.
set -uo pipefail

PROFILE="tylerbtt"
REGION="us-east-1"
DYNAMO_TABLE="x-bookmark-seen"
TTL_DAYS=30
WORK_DIR="/tmp/x-bookmark-review"
BIRD="/usr/local/bin/bird"
PROJECT_DIR="$HOME/code/personal/clawdbot"
DISCORD_CHANNEL="1475513267433767014"

source ~/.profile
mkdir -p "$WORK_DIR"

TODAY=$(date +%Y-%m-%d)
EXPIRES_AT=$(date -d "+${TTL_DAYS} days" +%s 2>/dev/null || date -v+${TTL_DAYS}d +%s)
LOG="$WORK_DIR/review-${TODAY}.log"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }

# --- Fetch bookmarks ---
log "Fetching bookmarks..."
bookmarks=$($BIRD bookmarks --json 2>/dev/null || echo "[]")
total=$(echo "$bookmarks" | jq 'length')
log "Found $total bookmarks"

if [ "$total" -eq 0 ]; then
  log "No bookmarks found, exiting"
  exit 0
fi

# --- Check DynamoDB for already-seen ---
log "Checking DynamoDB for previously reviewed..."
new_bookmarks=$(mktemp)
new_count=0

echo "$bookmarks" | jq -c '.[]' | while IFS= read -r tweet; do
  tid=$(echo "$tweet" | jq -r '.id')
  seen=$(aws dynamodb get-item \
    --table-name "$DYNAMO_TABLE" \
    --key "{\"tweet_id\":{\"S\":\"$tid\"}}" \
    --projection-expression "tweet_id" \
    --profile "$PROFILE" --region "$REGION" \
    --output text 2>/dev/null)
  if ! echo "$seen" | grep -q "$tid"; then
    echo "$tweet" >> "$new_bookmarks"
  fi
done

new_count=$(wc -l < "$new_bookmarks" | xargs)
log "$new_count new bookmarks (not previously reviewed)"

if [ "$new_count" -eq 0 ]; then
  log "All bookmarks already reviewed, exiting"
  rm -f "$new_bookmarks"
  exit 0
fi

# --- Format message ---
msg="📑 **New Bookmarks** — $new_count new since last review"$'\n\n'
idx=1

while IFS= read -r tweet; do
  user=$(echo "$tweet" | jq -r '.author.username')
  name=$(echo "$tweet" | jq -r '.author.name')
  text=$(echo "$tweet" | jq -r '.text' | tr '\n' ' ' | cut -c1-200)
  likes=$(echo "$tweet" | jq -r '.likeCount')
  rts=$(echo "$tweet" | jq -r '.retweetCount')
  tid=$(echo "$tweet" | jq -r '.id')
  created=$(echo "$tweet" | jq -r '.createdAt')
  cdt=$(TZ='America/Chicago' date -d "$created" '+%b %d, %l:%M %p CDT' 2>/dev/null || echo "$created")

  msg+="${idx}. **@${user}** ($name) — ${likes} likes, ${rts} RTs — ${cdt}"$'\n'
  msg+="   ${text}"$'\n'
  msg+="   https://x.com/${user}/status/${tid}"$'\n\n'
  idx=$((idx + 1))
done < "$new_bookmarks"

msg+="_Reply with actions (e.g. \"task for 1,3\" or \"research 2\") — auto-reviewed in 24h_"

# --- Mark all new bookmarks as reviewed in DynamoDB ---
log "Marking $new_count bookmarks as reviewed..."
batch_items=""
count=0

while IFS= read -r tweet; do
  tid=$(echo "$tweet" | jq -r '.id')
  user=$(echo "$tweet" | jq -r '.author.username')
  text_short=$(echo "$tweet" | jq -r '.text' | tr '\n' ' ' | cut -c1-100)

  batch_items="${batch_items}{\"PutRequest\":{\"Item\":{\"tweet_id\":{\"S\":\"$tid\"},\"author\":{\"S\":\"$user\"},\"text\":{\"S\":$(echo "$text_short" | jq -Rs .)},\"reviewed_date\":{\"S\":\"$TODAY\"},\"action\":{\"S\":\"none\"},\"expires_at\":{\"N\":\"$EXPIRES_AT\"}}}},"
  count=$((count + 1))

  if [ "$count" -ge 25 ]; then
    batch_items="${batch_items%,}"
    aws dynamodb batch-write-item \
      --request-items "{\"$DYNAMO_TABLE\":[${batch_items}]}" \
      --profile "$PROFILE" --region "$REGION" > /dev/null 2>&1
    batch_items=""
    count=0
  fi
done < "$new_bookmarks"

if [ "$count" -gt 0 ]; then
  batch_items="${batch_items%,}"
  aws dynamodb batch-write-item \
    --request-items "{\"$DYNAMO_TABLE\":[${batch_items}]}" \
    --profile "$PROFILE" --region "$REGION" > /dev/null 2>&1
fi

log "DynamoDB: marked $new_count bookmarks as reviewed"

# --- Post to Discord ---
log "Posting to Discord #openclaw..."
DISCORD_TOKEN=$(jq -r '.channels.discord.token' ~/.openclaw/openclaw.json)
full_msg="📑 **X Bookmark Review — $TODAY ($new_count new)**

$msg"
# Discord max message length is 2000 chars; truncate if needed
if [ ${#full_msg} -gt 1990 ]; then
  full_msg="${full_msg:0:1987}..."
fi
payload=$(jq -n --arg content "$full_msg" '{content: $content}')
resp_file=$(mktemp)
http_code=$(curl -s --connect-timeout 10 --max-time 30 -o "$resp_file" -w "%{http_code}" \
  -X POST "https://discord.com/api/v10/channels/${DISCORD_CHANNEL}/messages" \
  -H "Authorization: Bot ${DISCORD_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$payload" 2>&1) || http_code="curl_err"
if [ "$http_code" = "200" ]; then
  log "Discord message sent (HTTP $http_code)"
else
  log "Discord send failed (HTTP $http_code) — $(cat "$resp_file" 2>/dev/null | head -c 200)"
fi
rm -f "$resp_file"

rm -f "$new_bookmarks"
log "Done — $new_count new bookmarks reviewed"
