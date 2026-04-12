#!/usr/bin/env bash
# fire-jobs.sh — Daily North Texas firefighter job search
# Sources:
#   1. governmentjobs.com (NEOGOV) via CDP headless Chrome — real city job postings
#   2. firejobs.com — dedicated firefighter job board
# Dedupes via DynamoDB. Emails + SMS on new finds.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROFILE="tylerbtt"
REGION="us-east-1"
DYNAMO_TABLE="fire-jobs-seen"
TTL_DAYS=60
EMAIL_FROM="noreply@tylerbtt.email.connect.aws"
EMAIL_TO="Brandon.tyler@gmail.com"
SMS_PHONE="+19405363405"
TOLL_FREE="+18778495397"

source ~/.profile

DATE_LABEL=$(date '+%A, %B %d %Y')
TODAY=$(date +%Y-%m-%d)
DIGEST_DIR="/tmp/fire-jobs"
mkdir -p "$DIGEST_DIR"
DIGEST_FILE="$DIGEST_DIR/digest-${TODAY}.md"
JOBS_FILE=$(mktemp)
NEWCOUNT_FILE="$DIGEST_DIR/.newcount"
trap 'rm -f "$JOBS_FILE" "$NEWCOUNT_FILE"' EXIT
: > "$JOBS_FILE"
rm -f "$NEWCOUNT_FILE"

EXPIRES_AT=$(date -d "+${TTL_DAYS} days" +%s 2>/dev/null || date -v+${TTL_DAYS}d +%s)

# North TX cities for firejobs.com filtering
NORTH_TX="denton|corinth|lake dallas|sanger|aubrey|pilot point|argyle|lewisville|flower mound|highland village|the colony|little elm|frisco|mckinney|allen|plano|prosper|celina|anna|carrollton|coppell|grapevine|southlake|keller|roanoke|fort worth|arlington|dallas|irving|grand prairie|mansfield|trophy club|crossroads"

# --- DynamoDB ---
DYNAMO_OK=0
if aws dynamodb describe-table --table-name "$DYNAMO_TABLE" --profile "$PROFILE" --region "$REGION" > /dev/null 2>&1; then
  DYNAMO_OK=1
else
  aws dynamodb create-table --table-name "$DYNAMO_TABLE" \
    --attribute-definitions '[{"AttributeName":"job_id","AttributeType":"S"}]' \
    --key-schema '[{"AttributeName":"job_id","KeyType":"HASH"}]' \
    --billing-mode PAY_PER_REQUEST --profile "$PROFILE" --region "$REGION" > /dev/null 2>&1
  aws dynamodb update-time-to-live --table-name "$DYNAMO_TABLE" \
    --time-to-live-specification "Enabled=true,AttributeName=expires_at" \
    --profile "$PROFILE" --region "$REGION" > /dev/null 2>&1
  sleep 8 && DYNAMO_OK=1
fi

is_seen() {
  [ "$DYNAMO_OK" -eq 0 ] && return 1
  aws dynamodb get-item --table-name "$DYNAMO_TABLE" \
    --key "{\"job_id\":{\"S\":\"$1\"}}" --projection-expression "job_id" \
    --profile "$PROFILE" --region "$REGION" --output text 2>/dev/null | grep -q "$1"
}

mark_seen() {
  [ "$DYNAMO_OK" -eq 0 ] && return
  aws dynamodb put-item --table-name "$DYNAMO_TABLE" \
    --item "{\"job_id\":{\"S\":\"$1\"},\"title\":{\"S\":\"$2\"},\"source\":{\"S\":\"$3\"},\"found_date\":{\"S\":\"$TODAY\"},\"expires_at\":{\"N\":\"$EXPIRES_AT\"}}" \
    --profile "$PROFILE" --region "$REGION" > /dev/null 2>&1
}

echo "=== Fire Jobs Search: $DATE_LABEL ==="

# --- Source 1: GovernmentJobs.com via CDP (primary) ---
echo "[1/2] GovernmentJobs.com (NEOGOV) via headless Chrome..."
if curl -s http://localhost:9223/json/version > /dev/null 2>&1; then
  neogov_json=$(timeout 300 node "$SCRIPT_DIR/scrape-neogov.mjs" 2>/dev/null)
  echo "$neogov_json" | jq -r '.[]? | [.url, .title, .meta, .city] | join("\t")' 2>/dev/null | \
  while IFS=$'\t' read -r url title meta city; do
    [ -z "$url" ] && continue
    jid="neogov-$(echo "$url" | grep -oP 'jobs/\K[0-9]+' | head -1)"
    [ -z "$jid" ] || [ "$jid" = "neogov-" ] && jid="neogov-$(echo "$url" | md5sum | cut -c1-12)"
    # Format: title — location | salary | type
    salary=$(echo "$meta" | grep -oP '\$[0-9,.]+(\s*-\s*\$[0-9,.]+)?\s*(Annually|Hourly|Monthly)' | head -1)
    type=$(echo "$meta" | grep -oP '(Full[- ]?Time|Part[- ]?Time)' | head -1)
    location=$(echo "$meta" | grep -oP '[A-Z][a-z]+( [A-Z][a-z]+)*, TX' | head -1)
    line="${title}"
    [ -n "$location" ] && line="${line} — ${location}"
    [ -n "$salary" ] && line="${line} | ${salary}"
    [ -n "$type" ] && line="${line} | ${type}"
    printf '%s\t%s\t%s\tgovernmentjobs\n' "$jid" "$line" "$url" >> "$JOBS_FILE"
  done
  echo "  NEOGOV done: $(grep -c 'governmentjobs' "$JOBS_FILE" 2>/dev/null || echo 0) jobs"
else
  echo "  dev-browser not running — skipping NEOGOV"
fi

# --- Source 2: firejobs.com (secondary) ---
echo "[2/2] firejobs.com..."
for page in 1 2 3 4 5; do
  html=$(curl -s "https://www.firejobs.com/jobs?page=${page}" -H "User-Agent: Mozilla/5.0" --max-time 15 2>/dev/null || true)
  [ -z "$html" ] && break
  echo "$html" | tr '\n' ' ' | sed 's/<\/li>/\n/g' | grep -i ', TX' | while IFS= read -r item; do
    slug=$(echo "$item" | grep -oP 'href="/jobs/([^"]+)"' | head -1 | sed 's/href="\/jobs\///;s/"//')
    [ -z "$slug" ] && continue
    title=$(echo "$item" | grep -oP '<h3[^>]*>\K[^<]+' | head -1 | sed 's/^ *//;s/ *$//')
    dept=$(echo "$item" | grep -oP 'text-secondary, #4b5563[^>]*>\K[^<]+' | head -1 | sed 's/^ *//;s/ *$//')
    city=$(echo "$item" | grep -oP '<p>[A-Z][a-z].*, TX[^<]*</p>' | head -1 | sed 's/<[^>]*>//g;s/^ *//;s/ *$//')
    salary=$(echo "$item" | grep -oP '\$[0-9,.]+[^<]*USD[^<]*' | head -1)
    [ -z "$city" ] && city=$(echo "$item" | grep -oP '[A-Z][a-z]+, TX' | head -1)
    city_lower=$(echo "$city" | tr '[:upper:]' '[:lower:]')
    echo "$city_lower" | grep -qiE "$NORTH_TX" || continue
    url="https://www.firejobs.com/jobs/${slug}"
    jid="fj-${slug}"
    line="${title} — ${dept}"
    [ -n "$city" ] && line="${line} (${city})"
    [ -n "$salary" ] && line="${line} | ${salary}"
    printf '%s\t%s\t%s\tfirejobs\n' "$jid" "$line" "$url" >> "$JOBS_FILE"
  done
  echo "$html" | grep -q "page=$((page+1))" || break
  sleep 1
done
echo "  firejobs done: $(grep -c 'firejobs' "$JOBS_FILE" 2>/dev/null || echo 0) jobs"

# --- Build digest ---
total=$(grep -c . "$JOBS_FILE" 2>/dev/null || echo 0)

{
  echo "# 🚒 North Texas Firefighter Jobs — $DATE_LABEL"
  echo ""
  echo "_Centered on Denton, TX | Sources: GovernmentJobs.com + FireJobs.com_"
  echo ""
} > "$DIGEST_FILE"

if [ "$total" -eq 0 ]; then
  echo "No North TX firefighter job postings found today." >> "$DIGEST_FILE"
else
  cur_source=""
  sort -t$'\t' -k4 "$JOBS_FILE" | while IFS=$'\t' read -r jid title url source; do
    [ -z "$jid" ] && continue
    is_seen "$jid" && continue
    if [ "$source" != "$cur_source" ]; then
      case "$source" in
        governmentjobs) echo "## 🏛️ GovernmentJobs.com" ;; firejobs) echo "## 🔥 FireJobs.com" ;; esac >> "$DIGEST_FILE"
      echo "" >> "$DIGEST_FILE"
      cur_source="$source"
    fi
    echo "• **${title}**" >> "$DIGEST_FILE"
    echo "  ${url}" >> "$DIGEST_FILE"
    echo "" >> "$DIGEST_FILE"
    mark_seen "$jid" "${title:0:200}" "$source"
    echo "1" >> "$NEWCOUNT_FILE"
  done
fi

new_count=0
[ -f "$NEWCOUNT_FILE" ] && new_count=$(wc -l < "$NEWCOUNT_FILE" | tr -d ' ')

{ echo "---"; echo "_${total} postings found, ${new_count} new._"; } >> "$DIGEST_FILE"
echo "Result: $total found, $new_count new"

# --- Notify ---
if [ "$new_count" -gt 0 ]; then
  body=$(cat "$DIGEST_FILE")
  aws ses send-email --from "$EMAIL_FROM" \
    --destination "{\"ToAddresses\":[\"$EMAIL_TO\"]}" \
    --message "{\"Subject\":{\"Data\":\"🚒 ${new_count} firefighter job(s) — North TX — $DATE_LABEL\"},\"Body\":{\"Text\":{\"Data\":$(echo "$body" | jq -Rs .)}}}" \
    --profile "$PROFILE" --region "$REGION" > /dev/null 2>&1 && echo "Email sent" || echo "Email failed" >&2
  aws pinpoint-sms-voice-v2 send-text-message \
    --destination-phone-number "$SMS_PHONE" --origination-identity "$TOLL_FREE" \
    --message-body "🚒 ${new_count} new firefighter job(s) in North TX. Check email." \
    --profile "$PROFILE" --region "$REGION" > /dev/null 2>&1 && echo "SMS sent" || echo "SMS failed" >&2
else
  echo "No new jobs — skipping notifications"
fi

cat "$DIGEST_FILE"
