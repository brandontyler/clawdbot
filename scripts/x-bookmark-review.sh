#!/usr/bin/env bash
# x-bookmark-review.sh — Daily bookmark review via bird CLI
#
# Fetches X bookmarks, filters out previously reviewed ones, posts new
# bookmarks to Discord for interactive triage.
#
# Dedup strategy:
#   - Primary: local seen-file (~/.local/share/x-bookmark-review/seen.tsv)
#   - Backup:  DynamoDB table (x-bookmark-seen) for cross-machine queryability
#   - Bookmarks are only marked as seen AFTER successful Discord delivery
#   - Local file is authoritative; DynamoDB is best-effort
#
# The seen file is a TSV: tweet_id \t reviewed_date \t author
# Entries older than TTL_DAYS are purged on each run.
set -uo pipefail

PROFILE="personal"
REGION="us-east-1"
DYNAMO_TABLE="x-bookmark-seen"
TTL_DAYS=30
WORK_DIR="/tmp/x-bookmark-review"
BIRD="/home/ubuntu/.local/bin/bird"
DISCORD_CHANNEL="1503414103341797406"
SEEN_DIR="$HOME/.local/share/x-bookmark-review"
SEEN_FILE="$SEEN_DIR/seen.tsv"

source ~/.profile
mkdir -p "$WORK_DIR" "$SEEN_DIR"
touch "$SEEN_FILE"

TODAY=$(date +%Y-%m-%d)
EXPIRES_AT=$(date -d "+${TTL_DAYS} days" +%s 2>/dev/null || date -v+${TTL_DAYS}d +%s)
LOG="$WORK_DIR/review-${TODAY}.log"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }

# --- Cleanup on exit ---
TMPFILES=()
cleanup() { rm -f "${TMPFILES[@]}" 2>/dev/null; }
trap cleanup EXIT

mktmp() {
  local f; f=$(mktemp)
  TMPFILES+=("$f")
  echo "$f"
}

# --- Purge expired entries from seen file ---
cutoff=$(date -d "-${TTL_DAYS} days" +%Y-%m-%d 2>/dev/null || date -v-${TTL_DAYS}d +%Y-%m-%d)
tmp_seen=$(mktmp)
awk -F'\t' -v c="$cutoff" '$2 >= c' "$SEEN_FILE" > "$tmp_seen" && mv "$tmp_seen" "$SEEN_FILE"

# --- Fetch bookmarks ---
log "Fetching bookmarks..."
bookmarks=$("$BIRD" bookmarks --json 2>/dev/null || echo "[]")
total=$(echo "$bookmarks" | jq 'length')
log "Found $total bookmarks"

if [ "$total" -eq 0 ]; then
  log "No bookmarks found, exiting"
  exit 0
fi

# --- Build set of seen IDs for fast lookup ---
# Using a temp file with sorted IDs + grep -F for O(n) matching
seen_ids=$(mktmp)
cut -f1 "$SEEN_FILE" | sort -u > "$seen_ids"

# --- Filter to new bookmarks only ---
new_bookmarks=$(mktmp)
all_ids=$(mktmp)
echo "$bookmarks" | jq -r '.[].id | tostring' > "$all_ids"

# Find IDs not in seen file
new_ids=$(mktmp)
grep -vxFf "$seen_ids" "$all_ids" > "$new_ids" || true

# Extract full tweet objects for new IDs only
if [ ! -s "$new_ids" ]; then
  log "All bookmarks already reviewed, exiting"
  exit 0
fi

# Build new_bookmarks file: one JSON object per line for each new tweet
while IFS= read -r tid; do
  echo "$bookmarks" | jq -c --arg id "$tid" '.[] | select((.id | tostring) == $id)'
done < "$new_ids" > "$new_bookmarks"

new_count=$(wc -l < "$new_bookmarks" | xargs)
log "$new_count new bookmarks to review"

# --- Format bookmark data for LLM analysis ---
BOOKMARK_LIST=""
idx=1

while IFS= read -r tweet; do
  user=$(echo "$tweet" | jq -r '.author.username')
  text=$(echo "$tweet" | jq -r '.text' | tr '\n' ' ' | tr -d '"\\`$' | cut -c1-250)
  likes=$(echo "$tweet" | jq -r '.likeCount')
  rts=$(echo "$tweet" | jq -r '.retweetCount')

  BOOKMARK_LIST="${BOOKMARK_LIST}[${idx}] @${user} (${likes} likes, ${rts} RTs): ${text}
"
  idx=$((idx + 1))
done < "$new_bookmarks"

# --- LLM categorization and scoring ---
log "Analyzing bookmarks via kiro-cli..."

PROMPT="Categorize and score these X bookmarks for Brandon Tyler (AWS engineer, AI/agents enthusiast, builds with kiro-cli/Claude, interested in SpaceX, Tesla, firefighting, film production).

For each bookmark output a JSON line:
{\"idx\":<N>,\"category\":\"<AI Tools|AI News|Dev Workflow|SpaceX/Tesla|Career|Other>\",\"action\":\"<try|research|task|read|skip>\",\"summary\":\"<1-line what it is and why it matters>\"}

Actions:
- try = install/use this tool or technique
- research = dig deeper, could be valuable
- task = create a bead/task for this
- read = interesting but just read it
- skip = low value, noise

Be selective. Only 'try' or 'task' for genuinely useful things. Most should be 'read' or 'skip'.

${BOOKMARK_LIST}"

RAW=$(cd "$HOME" && timeout 90 kiro-cli chat --no-interactive --wrap never "$PROMPT" 2>&1)
SCORES=$(echo "$RAW" | sed 's/\x1b\[[0-9;]*m//g' | grep -oP '\{[^}]+\}')

log "LLM returned $(echo "$SCORES" | grep -c '{' || echo 0) scores"

# --- Build categorized Discord message ---
msg=""
# Process scores into categorized output
msg=$(echo "$SCORES" | python3 -c "
import sys, json

categories = {}
lines = sys.stdin.read().strip().split('\n')
for line in lines:
    if not line.strip():
        continue
    try:
        d = json.loads(line)
        idx = d.get('idx', 0)
        cat = d.get('category', 'Other')
        action = d.get('action', 'read')
        summary = d.get('summary', '')
        if action == 'skip':
            continue
        emoji = {'try': '🔧', 'task': '📋', 'research': '🔍', 'read': '📖'}.get(action, '•')
        if cat not in categories:
            categories[cat] = []
        categories[cat].append(f'{emoji} {summary}')
    except:
        continue

output = ''
for cat in ['AI Tools', 'AI News', 'Dev Workflow', 'SpaceX/Tesla', 'Career', 'Other']:
    if cat in categories and categories[cat]:
        output += f'**{cat}**\n'
        for item in categories[cat]:
            output += f'{item}\n'
        output += '\n'

output += '_Legend: 🔧=try it 📋=create task 🔍=research 📖=read_'
print(output)
" 2>/dev/null)

if [ -z "$msg" ]; then
  # Fallback: raw list if LLM failed
  log "WARN: LLM categorization failed, using raw format"
  msg=""
  idx=1
  while IFS= read -r tweet; do
    user=$(echo "$tweet" | jq -r '.author.username')
    text=$(echo "$tweet" | jq -r '.text' | tr '\n' ' ' | cut -c1-150)
    tid=$(echo "$tweet" | jq -r '.id')
    msg+="${idx}. @${user}: ${text}
   https://x.com/${user}/status/${tid}

"
    idx=$((idx + 1))
  done < "$new_bookmarks"
fi

# --- Post to Discord FIRST (only mark seen after successful delivery) ---
log "Posting to Discord #openclaw..."
DISCORD_TOKEN=$(jq -r '.channels.discord.token' ~/.openclaw/openclaw.json)
full_msg="📑 **X Bookmark Review — $TODAY ($new_count new)**

$msg"
if [ ${#full_msg} -gt 1990 ]; then
  full_msg="${full_msg:0:1987}..."
fi
payload=$(jq -n --arg content "$full_msg" '{content: $content}')
resp_file=$(mktmp)
http_code=$(curl -s --connect-timeout 10 --max-time 30 -o "$resp_file" -w "%{http_code}" \
  -X POST "https://discord.com/api/v10/channels/${DISCORD_CHANNEL}/messages" \
  -H "Authorization: Bot ${DISCORD_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$payload" 2>&1) || http_code="curl_err"

if [ "$http_code" != "200" ]; then
  log "Discord send FAILED (HTTP $http_code) — $(cat "$resp_file" 2>/dev/null | head -c 200)"
  log "NOT marking bookmarks as reviewed (will retry next run)"
  exit 1
fi
log "Discord message sent (HTTP $http_code)"

# --- Mark as reviewed AFTER successful delivery ---
log "Marking $new_count bookmarks as reviewed..."

# 1. Local seen file (primary — always reliable)
while IFS= read -r tweet; do
  tid=$(echo "$tweet" | jq -r '.id')
  user=$(echo "$tweet" | jq -r '.author.username')
  printf '%s\t%s\t%s\n' "$tid" "$TODAY" "$user" >> "$SEEN_FILE"
done < "$new_bookmarks"

# 2. DynamoDB (backup — best-effort, errors logged not fatal)
batch_items=""
batch_count=0

while IFS= read -r tweet; do
  tid=$(echo "$tweet" | jq -r '.id')
  user=$(echo "$tweet" | jq -r '.author.username')
  text_short=$(echo "$tweet" | jq -r '.text' | tr '\n' ' ' | cut -c1-100)

  batch_items="${batch_items}{\"PutRequest\":{\"Item\":{\"tweet_id\":{\"S\":\"$tid\"},\"author\":{\"S\":\"$user\"},\"text\":{\"S\":$(echo "$text_short" | jq -Rs .)},\"reviewed_date\":{\"S\":\"$TODAY\"},\"action\":{\"S\":\"none\"},\"expires_at\":{\"N\":\"$EXPIRES_AT\"}}}},"
  batch_count=$((batch_count + 1))

  if [ "$batch_count" -ge 25 ]; then
    batch_items="${batch_items%,}"
    dynamo_out=$(aws dynamodb batch-write-item \
      --request-items "{\"$DYNAMO_TABLE\":[${batch_items}]}" \
      --profile "$PROFILE" --region "$REGION" 2>&1) || log "WARN: DynamoDB batch write failed: $dynamo_out"
    batch_items=""
    batch_count=0
  fi
done < "$new_bookmarks"

if [ "$batch_count" -gt 0 ]; then
  batch_items="${batch_items%,}"
  dynamo_out=$(aws dynamodb batch-write-item \
    --request-items "{\"$DYNAMO_TABLE\":[${batch_items}]}" \
    --profile "$PROFILE" --region "$REGION" 2>&1) || log "WARN: DynamoDB batch write failed: $dynamo_out"
fi

log "Done — $new_count new bookmarks reviewed"
