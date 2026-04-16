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
LOG_DIR="$HOME/logs/fire-jobs"
DIGEST_DIR="/tmp/fire-jobs"
mkdir -p "$DIGEST_DIR" "$LOG_DIR"
LOGFILE="$LOG_DIR/run-${TODAY}.log"
DIGEST_FILE="$DIGEST_DIR/digest-${TODAY}.md"
JOBS_FILE=$(mktemp)
NEWCOUNT_FILE="$DIGEST_DIR/.newcount"
trap 'rm -f "$JOBS_FILE" "$NEWCOUNT_FILE"' EXIT
: > "$JOBS_FILE"
rm -f "$NEWCOUNT_FILE"

EXPIRES_AT=$(date -d "+${TTL_DAYS} days" +%s 2>/dev/null || date -v+${TTL_DAYS}d +%s)

# Logging helper — writes to both stdout (→ journalctl) and per-run log file
log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOGFILE"; }
log_err() { echo "[$(date '+%H:%M:%S')] ERROR: $*" | tee -a "$LOGFILE" >&2; }

# North TX cities for firejobs.com filtering
NORTH_TX="denton|corinth|lake dallas|sanger|aubrey|pilot point|argyle|lewisville|flower mound|highland village|the colony|little elm|frisco|mckinney|allen|plano|prosper|celina|anna|carrollton|coppell|grapevine|southlake|keller|roanoke|fort worth|arlington|dallas|irving|grand prairie|mansfield|trophy club|crossroads"

# --- DynamoDB ---
DYNAMO_OK=0
if aws dynamodb describe-table --table-name "$DYNAMO_TABLE" --profile "$PROFILE" --region "$REGION" > /dev/null 2>&1; then
  DYNAMO_OK=1
  log "DynamoDB table $DYNAMO_TABLE: OK"
else
  log "DynamoDB table $DYNAMO_TABLE not found, creating..."
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

log "=== Fire Jobs Search: $DATE_LABEL ==="

# --- Source 1: GovernmentJobs.com via CDP (primary) ---
log "[1/2] GovernmentJobs.com (NEOGOV) via headless Chrome..."
if curl -s http://localhost:9223/json/version > /dev/null 2>&1; then
  log "  dev-browser on :9223 — connected"
  neogov_tmp=$(mktemp)
  timeout 300 node "$SCRIPT_DIR/scrape-neogov.mjs" > "$neogov_tmp" 2>> "$LOGFILE"
  neogov_exit=$?
  if [ "$neogov_exit" -eq 124 ]; then
    log "  NEOGOV timed out at 300s — using partial results"
  elif [ "$neogov_exit" -ne 0 ]; then
    log_err "  NEOGOV scraper exited $neogov_exit"
  fi
  # Output is JSONL (one JSON object per line), not a JSON array
  while IFS= read -r line; do
    url=$(echo "$line" | jq -r '.url // empty' 2>/dev/null)
    title=$(echo "$line" | jq -r '.title // empty' 2>/dev/null)
    meta=$(echo "$line" | jq -r '.meta // empty' 2>/dev/null)
    city=$(echo "$line" | jq -r '.city // empty' 2>/dev/null)
    [ -z "$url" ] && continue
    jid="neogov-$(echo "$url" | grep -oP 'jobs/\K[0-9]+' | head -1)"
    [ -z "$jid" ] || [ "$jid" = "neogov-" ] && jid="neogov-$(echo "$url" | md5sum | cut -c1-12)"
    salary=$(echo "$meta" | grep -oP '\$[0-9,.]+(\s*-\s*\$[0-9,.]+)?\s*(Annually|Hourly|Monthly)' | head -1)
    type=$(echo "$meta" | grep -oP '(Full[- ]?Time|Part[- ]?Time)' | head -1)
    location=$(echo "$meta" | grep -oP '[A-Z][a-z]+( [A-Z][a-z]+)*, TX' | head -1)
    line_fmt="${title}"
    [ -n "$location" ] && line_fmt="${line_fmt} — ${location}"
    [ -n "$salary" ] && line_fmt="${line_fmt} | ${salary}"
    [ -n "$type" ] && line_fmt="${line_fmt} | ${type}"
    printf '%s\t%s\t%s\tgovernmentjobs\n' "$jid" "$line_fmt" "$url" >> "$JOBS_FILE"
    log "  found: $title ($city)"
  done < "$neogov_tmp"
  rm -f "$neogov_tmp"
  neogov_count=$(grep -c 'governmentjobs' "$JOBS_FILE" 2>/dev/null || echo 0)
  log "  NEOGOV done: $neogov_count jobs (exit=$neogov_exit)"
else
  log_err "  dev-browser not running on :9223 — skipping NEOGOV"
fi

# --- Source 2: firejobs.com (secondary) ---
# Site uses <a class="block ..."> cards. We extract fields via python regex
# since the HTML has no semantic tags (no <li>, <h3>, <p> wrappers for fields).
log "[2/2] firejobs.com..."
fj_total_scraped=0
fj_tx_found=0
fj_north_tx=0
for page in $(seq 1 10); do
  html=$(curl -s "https://www.firejobs.com/jobs?page=${page}" -H "User-Agent: Mozilla/5.0" --max-time 20 2>/dev/null || true)
  if [ -z "$html" ]; then
    log_err "  page $page: empty response (curl failed or timeout)"
    break
  fi
  # Detect wrap-around: if page N returns same first slug as page 1, we've looped
  first_slug=$(echo "$html" | grep -oP 'href="/jobs/([^"]+)"' | grep -v 'new' | head -1)
  if [ "$page" -gt 1 ] && [ "$first_slug" = "$fj_first_slug" ]; then
    log "  page $page: wrapped to page 1 — stopping"
    break
  fi
  [ "$page" -eq 1 ] && fj_first_slug="$first_slug"

  # Parse job cards with python — more reliable than sed/grep on complex HTML
  echo "$html" | python3 -c "
import sys, re
html = sys.stdin.read()
cards = re.findall(r'<a class=\"block[^\"]*\"[^>]*href=\"/jobs/([^\"]+)\"[^>]*>(.*?)</a>', html, re.DOTALL)
for slug, body in cards:
    if slug == 'new': continue
    text = re.sub(r'<[^>]+>', '|', body)
    parts = [p.strip() for p in text.split('|') if p.strip()]
    title = parts[0] if parts else ''
    dept = parts[1] if len(parts) > 1 else ''
    # Find location (City, ST or City, State, Country)
    loc = ''
    for p in parts:
        if re.search(r', (TX|Texas)', p, re.I):
            loc = p
            break
    if not loc: continue  # not Texas
    # Find salary
    salary = ''
    for p in parts:
        if '\$' in p and 'USD' in p:
            salary = p
            break
    # Find type
    jtype = ''
    for p in parts:
        if p in ('Full-time','Part-time','Contract','Volunteer'):
            jtype = p
            break
    print(f'{slug}\t{title}\t{dept}\t{loc}\t{salary}\t{jtype}')
" 2>/dev/null | while IFS=$'\t' read -r slug title dept city salary jtype; do
    [ -z "$slug" ] && continue
    fj_tx_found=$((fj_tx_found + 1))
    city_lower=$(echo "$city" | tr '[:upper:]' '[:lower:]')
    if ! echo "$city_lower" | grep -qiE "$NORTH_TX"; then
      log "  skip: $title ($city) — not North TX"
      continue
    fi
    url="https://www.firejobs.com/jobs/${slug}"
    jid="fj-${slug}"
    line="${title} — ${dept}"
    [ -n "$city" ] && line="${line} (${city})"
    [ -n "$salary" ] && line="${line} | ${salary}"
    [ -n "$jtype" ] && line="${line} | ${jtype}"
    printf '%s\t%s\t%s\tfirejobs\n' "$jid" "$line" "$url" >> "$JOBS_FILE"
    log "  found: $title ($city)"
  done
  page_jobs=$(echo "$html" | grep -oP 'href="/jobs/[^"]+' | grep -v 'new' | wc -l)
  fj_total_scraped=$((fj_total_scraped + page_jobs))
  log "  page $page: $page_jobs listings scraped"
  sleep 1
done
fj_count=$(grep -c 'firejobs' "$JOBS_FILE" 2>/dev/null || echo 0)
log "  firejobs done: scraped $fj_total_scraped total listings, $fj_count North TX jobs"

# --- Build digest ---
total=$(grep -c . "$JOBS_FILE" 2>/dev/null || echo 0)
log "Total jobs collected: $total"

{
  echo "# 🚒 North Texas Firefighter Jobs — $DATE_LABEL"
  echo ""
  echo "_Centered on Denton, TX | Sources: GovernmentJobs.com + FireJobs.com_"
  echo ""
} > "$DIGEST_FILE"

if [ "$total" -eq 0 ]; then
  echo "No North TX firefighter job postings found today." >> "$DIGEST_FILE"
  log "No postings found from any source"
else
  cur_source=""
  seen_count=0
  sort -t$'\t' -k4 "$JOBS_FILE" | while IFS=$'\t' read -r jid title url source; do
    [ -z "$jid" ] && continue
    if is_seen "$jid"; then
      seen_count=$((seen_count + 1))
      continue
    fi
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
    log "  NEW: [$source] $title"
    echo "1" >> "$NEWCOUNT_FILE"
  done
  log "  $seen_count already-seen jobs skipped"
fi

new_count=0
[ -f "$NEWCOUNT_FILE" ] && new_count=$(wc -l < "$NEWCOUNT_FILE" | tr -d ' ')

{ echo "---"; echo "_${total} postings found, ${new_count} new._"; } >> "$DIGEST_FILE"
log "Result: $total found, $new_count new"

# --- Notify ---
if [ "$new_count" -gt 0 ]; then
  body=$(cat "$DIGEST_FILE")
  if aws ses send-email --from "$EMAIL_FROM" \
    --destination "{\"ToAddresses\":[\"$EMAIL_TO\"]}" \
    --message "{\"Subject\":{\"Data\":\"🚒 ${new_count} firefighter job(s) — North TX — $DATE_LABEL\"},\"Body\":{\"Text\":{\"Data\":$(echo "$body" | jq -Rs .)}}}" \
    --profile "$PROFILE" --region "$REGION" > /dev/null 2>&1; then
    log "Email sent to $EMAIL_TO"
  else
    log_err "Email send failed"
  fi
  if aws pinpoint-sms-voice-v2 send-text-message \
    --destination-phone-number "$SMS_PHONE" --origination-identity "$TOLL_FREE" \
    --message-body "🚒 ${new_count} new firefighter job(s) in North TX. Check email." \
    --profile "$PROFILE" --region "$REGION" > /dev/null 2>&1; then
    log "SMS sent to $SMS_PHONE"
  else
    log_err "SMS send failed"
  fi
else
  log "No new jobs — skipping notifications"
fi

log "Done. Log: $LOGFILE"
cat "$DIGEST_FILE"
