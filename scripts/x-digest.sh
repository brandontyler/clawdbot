#!/usr/bin/env bash
# x-digest.sh — Daily X/Twitter digest via bird CLI
#
# v3: DynamoDB cross-day dedup. Tweets sent in previous digests are skipped.
#
# Design principles:
#   1. Account-based queries first (high signal) — official sources, key voices
#   2. Keyword queries second (community buzz) — catches what watchlist misses
#   3. Dedup by tweet ID across topics AND across days (DynamoDB)
#   4. Sort by engagement within each topic
#   5. 48-hour window — catches posts still gaining traction
#   6. Graceful degradation — DynamoDB down? Run without dedup. bird fails? Skip topic.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOPICS_FILE="$SCRIPT_DIR/x-digest-topics.txt"
DIGEST_DIR="/tmp/x-digest"
FETCH_COUNT=30
PROFILE="tylerbtt"
REGION="us-east-1"
DYNAMO_TABLE="x-digest-seen"
TTL_DAYS=7
EMAIL_FROM="noreply@tylerbtt.email.connect.aws"
EMAIL_TO="Brandon.tyler@gmail.com"
SMS_PHONE="+19405363405"
TOLL_FREE="+18778495397"

source ~/.profile
mkdir -p "$DIGEST_DIR"

DATE_LABEL=$(date '+%A, %B %d %Y')
TODAY=$(date +%Y-%m-%d)
DIGEST_FILE="$DIGEST_DIR/digest-${TODAY}.md"
SINCE=$(date -d "2 days ago" +%Y-%m-%d 2>/dev/null || date -v-2d +%Y-%m-%d)
EXPIRES_AT=$(date -d "+${TTL_DAYS} days" +%s 2>/dev/null || date -v+${TTL_DAYS}d +%s)

# --- DynamoDB helpers ---

# Check if a tweet was already sent. Returns 0 (true) if seen, 1 if new.
is_seen() {
  local tid="$1"
  aws dynamodb get-item \
    --table-name "$DYNAMO_TABLE" \
    --key "{\"tweet_id\":{\"S\":\"$tid\"}}" \
    --projection-expression "tweet_id" \
    --profile "$PROFILE" --region "$REGION" \
    --output text 2>/dev/null | grep -q "$tid"
}

# Batch-write seen tweet IDs to DynamoDB (max 25 per batch).
mark_seen_batch() {
  local ids_file="$1"
  local batch_items=""
  local count=0

  while IFS=$'\t' read -r tid author topic likes; do
    [ -z "$tid" ] && continue
    batch_items="${batch_items}{\"PutRequest\":{\"Item\":{\"tweet_id\":{\"S\":\"$tid\"},\"author\":{\"S\":\"$author\"},\"topic\":{\"S\":\"$topic\"},\"likes\":{\"N\":\"$likes\"},\"sent_date\":{\"S\":\"$TODAY\"},\"expires_at\":{\"N\":\"$EXPIRES_AT\"}}}},"
    count=$((count + 1))

    if [ "$count" -ge 25 ]; then
      batch_items="${batch_items%,}"
      aws dynamodb batch-write-item \
        --request-items "{\"$DYNAMO_TABLE\":[${batch_items}]}" \
        --profile "$PROFILE" --region "$REGION" > /dev/null 2>&1
      batch_items=""
      count=0
    fi
  done < "$ids_file"

  if [ "$count" -gt 0 ]; then
    batch_items="${batch_items%,}"
    aws dynamodb batch-write-item \
      --request-items "{\"$DYNAMO_TABLE\":[${batch_items}]}" \
      --profile "$PROFILE" --region "$REGION" > /dev/null 2>&1
  fi
}

# Test DynamoDB connectivity. Sets DYNAMO_OK=1 if reachable.
DYNAMO_OK=0
if aws dynamodb describe-table --table-name "$DYNAMO_TABLE" --profile "$PROFILE" --region "$REGION" > /dev/null 2>&1; then
  DYNAMO_OK=1
  echo "DynamoDB: connected ($DYNAMO_TABLE)"
else
  echo "DynamoDB: unreachable — running without cross-day dedup" >&2
fi

# --- In-memory dedup (within single run, across topics) ---
RUN_SEEN_FILE=$(mktemp)
echo '[]' > "$RUN_SEEN_FILE"
MARK_SEEN_FILE=$(mktemp)
: > "$MARK_SEEN_FILE"
trap 'rm -f "$RUN_SEEN_FILE" "$MARK_SEEN_FILE"' EXIT

# --- Build digest ---
{
  echo "# Daily X Digest — $DATE_LABEL"
  echo ""
} > "$DIGEST_FILE"

topic_count=0
total_posts=0
skipped_seen=0

while IFS= read -r line; do
  [[ "$line" =~ ^[[:space:]]*# ]] && continue
  [[ -z "${line// /}" ]] && continue

  name=$(echo "$line" | cut -d'|' -f1 | xargs)
  query_base=$(echo "$line" | cut -d'|' -f2 | xargs)
  min_faves=$(echo "$line" | cut -d'|' -f3 | xargs 2>/dev/null || echo "50")
  max_results=$(echo "$line" | cut -d'|' -f4 | xargs 2>/dev/null || echo "5")

  query="$query_base"
  [[ "$query" != *"since:"* ]] && query="$query since:$SINCE"

  echo "## $name" >> "$DIGEST_FILE"
  echo "" >> "$DIGEST_FILE"

  results=$(bird search "$query" -n "$FETCH_COUNT" --json 2>/dev/null || echo "[]")

  # Filter by min_faves, sort by engagement, dedup within run
  candidates=$(echo "$results" | jq -r --arg min "$min_faves" --slurpfile seen "$RUN_SEEN_FILE" '
    ($seen[0] // [] | map(tostring)) as $seen_ids |
    [.[] |
      select(.likeCount >= ($min | tonumber)) |
      select((.id | tostring) as $id | ($seen_ids | index($id)) | not)
    ] |
    sort_by(-(.likeCount + .retweetCount * 3)) |
    .[] |
    [(.id|tostring), .author.username, (.likeCount|tostring), (.retweetCount|tostring), .createdAt, (.text | gsub("\n"; " ") | .[0:280])] | join("\t")
  ' 2>/dev/null)

  included=0
  if [ -n "$candidates" ]; then
    while IFS=$'\t' read -r tid user likes rts created_utc text; do
      [ "$included" -ge "$max_results" ] && break

      # Cross-day dedup via DynamoDB
      if [ "$DYNAMO_OK" -eq 1 ] && is_seen "$tid"; then
        skipped_seen=$((skipped_seen + 1))
        continue
      fi

      cdt=$(TZ='America/Chicago' date -d "$created_utc" '+%a %b %d, %l:%M %p CDT' 2>/dev/null || echo "$created_utc")
      echo "**@${user}** — ${likes} likes, ${rts} RTs — ${cdt}" >> "$DIGEST_FILE"
      echo "${text}" >> "$DIGEST_FILE"
      echo "https://x.com/${user}/status/${tid}" >> "$DIGEST_FILE"
      echo "" >> "$DIGEST_FILE"

      # Track for batch write
      printf '%s\t%s\t%s\t%s\n' "$tid" "$user" "$name" "$likes" >> "$MARK_SEEN_FILE"
      included=$((included + 1))
      total_posts=$((total_posts + 1))
    done <<< "$candidates"
  fi

  if [ "$included" -eq 0 ]; then
    echo "_(no new high-engagement posts found)_" >> "$DIGEST_FILE"
  fi

  # Update in-memory seen for cross-topic dedup
  new_ids=$(echo "$results" | jq '[.[].id]' 2>/dev/null || echo '[]')
  jq -s '.[0] + .[1] | unique' "$RUN_SEEN_FILE" <(echo "$new_ids") > "${RUN_SEEN_FILE}.tmp" && mv "${RUN_SEEN_FILE}.tmp" "$RUN_SEEN_FILE"

  echo "" >> "$DIGEST_FILE"
  topic_count=$((topic_count + 1))
  sleep 2
done < "$TOPICS_FILE"

# --- Write seen IDs to DynamoDB ---
if [ "$DYNAMO_OK" -eq 1 ] && [ -s "$MARK_SEEN_FILE" ]; then
  mark_seen_batch "$MARK_SEEN_FILE"
  echo "DynamoDB: marked $(wc -l < "$MARK_SEEN_FILE" | xargs) tweets as seen"
fi

# --- Footer ---
{
  echo "---"
  echo "_${topic_count} topics scanned, ${total_posts} new posts surfaced, ${skipped_seen} previously seen skipped._"
} >> "$DIGEST_FILE"

echo "Digest saved: $DIGEST_FILE ($topic_count topics, $total_posts new, $skipped_seen skipped)"

# --- Send email ---
email_body=$(cat "$DIGEST_FILE")
aws ses send-email \
  --from "$EMAIL_FROM" \
  --destination "{\"ToAddresses\":[\"$EMAIL_TO\"]}" \
  --message "{\"Subject\":{\"Data\":\"Daily X Digest — $DATE_LABEL\"},\"Body\":{\"Text\":{\"Data\":$(echo "$email_body" | jq -Rs .)}}}" \
  --profile "$PROFILE" --region "$REGION" \
  > /dev/null 2>&1 && echo "Email sent to $EMAIL_TO" || echo "Email send failed" >&2

# --- Send SMS ---
aws pinpoint-sms-voice-v2 send-text-message \
  --destination-phone-number "$SMS_PHONE" \
  --origination-identity "$TOLL_FREE" \
  --message-body "Your daily X digest is ready — $total_posts new posts across $topic_count topics. Check your email." \
  --profile "$PROFILE" --region "$REGION" \
  > /dev/null 2>&1 && echo "SMS alert sent" || echo "SMS alert failed" >&2

cat "$DIGEST_FILE"
