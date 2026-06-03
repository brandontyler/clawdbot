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
# Tweets whose visible text is just a t.co link (or near-empty) get enriched
# via `bird read`, which follows the t.co and renders the destination as
# plain text. This turns "@trq212 — only a t.co link" into "@trq212 —
# Anthropic blog post: dynamic workflows in Claude Code...".
is_thin_text() {
  # Returns 0 (true) when the text is too thin to summarize:
  # strip URLs + whitespace, check remaining char count.
  local stripped
  stripped=$(echo "$1" | sed -E 's#https?://[^ ]+##g' | tr -d '[:space:]')
  [ "${#stripped}" -lt 30 ]
}

enrich_tweet() {
  # Fetch expanded content via `bird read` (15s timeout, capped at 800 chars).
  # Returns enriched text on stdout, or empty string on failure.
  local user="$1" tid="$2"
  local url="https://x.com/${user}/status/${tid}"
  local enriched
  enriched=$(timeout 15 "$BIRD" read "$url" --plain 2>/dev/null \
    | tr '\n' ' ' | tr -s ' ' | tr -d '"\\`$' | cut -c1-800)
  # Only return if we got something more substantive than the bare URL
  if [ -n "$enriched" ] && [ "${#enriched}" -gt 50 ]; then
    echo "$enriched"
  fi
}

BOOKMARK_LIST=""
idx=1
enriched_count=0

while IFS= read -r tweet; do
  user=$(echo "$tweet" | jq -r '.author.username')
  tid=$(echo "$tweet" | jq -r '.id')
  text=$(echo "$tweet" | jq -r '.text' | tr '\n' ' ' | tr -d '"\\`$' | cut -c1-300)

  # Enrich tweets whose visible text is too thin to summarize
  if is_thin_text "$text"; then
    log "  Bookmark [$idx] @$user is thin (${#text} chars) — fetching via bird read"
    enriched=$(enrich_tweet "$user" "$tid")
    if [ -n "$enriched" ]; then
      text="$enriched"
      enriched_count=$((enriched_count + 1))
    fi
  fi

  BOOKMARK_LIST="${BOOKMARK_LIST}[${idx}] @${user}: ${text}
"
  idx=$((idx + 1))
done < "$new_bookmarks"

[ "$enriched_count" -gt 0 ] && log "Enriched ${enriched_count}/${new_count} thin bookmarks via bird read"

# --- LLM summarization (one line per bookmark) ---
log "Summarizing bookmarks via kiro-cli..."

PROMPT="For each X bookmark below, write one short factual line describing what the post is about — name tools, people, claims, or topics. Do not editorialize. Do not categorize. Do not recommend actions.

Output exactly one JSON object per line, one per bookmark, in the form:
{\"idx\": <N>, \"summary\": \"<one short factual line>\"}

Bookmarks:
${BOOKMARK_LIST}"

RAW=$(cd "$HOME" && timeout 90 kiro-cli chat --no-interactive --wrap never "$PROMPT" 2>&1)
SUMMARIES_JSON=$(echo "$RAW" | sed 's/\x1b\[[0-9;]*m//g' | grep -oP '\{[^}]*"idx"[^}]*\}')

llm_count=$(echo "$SUMMARIES_JSON" | grep -c '{' || echo 0)
log "LLM returned ${llm_count} summaries (expected ${new_count})"

# --- Build numbered Discord message ---
# Pass tweet data + LLM summaries into python; emit a clean numbered list.
# Fallback to raw tweet text for any bookmark the LLM missed — never drop one.
TWEET_INPUT=$(mktmp)
cat "$new_bookmarks" > "$TWEET_INPUT"

msg=$(python3 - "$TWEET_INPUT" <<EOF
import json, sys

tweet_path = sys.argv[1]
summaries_raw = """${SUMMARIES_JSON}"""

# Parse LLM summaries into a {idx: summary} dict
summaries = {}
for line in summaries_raw.strip().split("\n"):
    line = line.strip()
    if not line:
        continue
    try:
        d = json.loads(line)
        idx = int(d.get("idx", 0))
        summary = d.get("summary", "").strip()
        if idx and summary:
            summaries[idx] = summary
    except Exception:
        continue

# Build the numbered list. If LLM missed an item, fall back to truncated tweet text.
output_lines = []
with open(tweet_path) as f:
    for i, raw in enumerate(f, start=1):
        raw = raw.strip()
        if not raw:
            continue
        try:
            t = json.loads(raw)
        except Exception:
            continue
        user = t.get("author", {}).get("username", "unknown")
        tid = t.get("id", "")
        url = f"https://x.com/{user}/status/{tid}"
        summary = summaries.get(i)
        if not summary:
            # Fallback: first 200 chars of the tweet itself
            text = (t.get("text") or "").replace("\n", " ").strip()
            summary = (text[:200] + "...") if len(text) > 200 else text
            if not summary:
                summary = "(no text)"
        output_lines.append(f"[{i}] @{user} — {summary}")
        output_lines.append(f"    {url}")
        output_lines.append("")

print("\n".join(output_lines).rstrip())
EOF
)

if [ -z "$msg" ]; then
  # Last-resort fallback: pure raw list with no LLM at all
  log "WARN: python builder produced no output, using raw fallback"
  msg=""
  idx=1
  while IFS= read -r tweet; do
    user=$(echo "$tweet" | jq -r '.author.username')
    text=$(echo "$tweet" | jq -r '.text' | tr '\n' ' ' | cut -c1-200)
    tid=$(echo "$tweet" | jq -r '.id')
    msg+="[${idx}] @${user} — ${text}
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
