#!/usr/bin/env bash
# fire-jobs.sh — Daily North Texas firefighter job search
# Sources:
#   1. governmentjobs.com (NEOGOV) via dev-browser CLI — real city job postings
#   2. firejobs.com — dedicated firefighter job board
#   3. TCFP (Texas Commission on Fire Protection) — official state fire careers
#   4. Craigslist DFW — bridge/holdover jobs (ER tech, fire watch, private EMS)
#   5. publicsafetyanswers.com — fire/police hiring platform (catches Haltom City, etc)
# Dedupes via DynamoDB. Emails + SMS on new finds.
set -uo pipefail


# Kill ALL dev-browser daemons before starting (prevent memory pileup from orphans)
# The daemon auto-starts when dev-browser CLI needs it, so this is safe.
pkill -f "daemon.mjs" 2>/dev/null || true
sleep 2

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROFILE="personal"
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

# Intelligent filtering via kiro-cli (replaces hardcoded city regex)
FILTER_SCRIPT="$SCRIPT_DIR/fire-jobs-filter.sh"

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

# --- Source 1: GovernmentJobs.com via dev-browser (primary) ---
log "[1/5] GovernmentJobs.com (NEOGOV) via dev-browser..."
if /home/ubuntu/.local/bin/dev-browser status > /dev/null 2>&1; then
  log "  dev-browser daemon — connected"
  neogov_tmp=$(mktemp)
  timeout 1800 bash "$SCRIPT_DIR/scrape-neogov.sh" > "$neogov_tmp" 2>> "$LOGFILE"
  neogov_exit=$?
  if [ "$neogov_exit" -eq 124 ]; then
    log "  NEOGOV timed out at 1800s — using partial results"
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
    # 5th column: best location info (parsed location or city slug fallback)
    loc_ctx="${location:-$city}"
    printf '%s\t%s\t%s\tgovernmentjobs\t%s\n' "$jid" "$line_fmt" "$url" "$loc_ctx" >> "$JOBS_FILE"
    log "  found: $title ($city)"
  done < "$neogov_tmp"
  rm -f "$neogov_tmp"
  neogov_count=$(grep -c 'governmentjobs' "$JOBS_FILE" 2>/dev/null || echo 0)
  log "  NEOGOV done: $neogov_count jobs (exit=$neogov_exit)"
else
  log_err "  dev-browser daemon not running — skipping NEOGOV"
fi

# --- Source 2: firejobs.com (secondary) ---
# Site uses <a class="block ..."> cards. We extract fields via python regex
# since the HTML has no semantic tags (no <li>, <h3>, <p> wrappers for fields).
log "[2/5] firejobs.com..."
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
    url="https://www.firejobs.com/jobs/${slug}"
    jid="fj-${slug}"
    line="${title} — ${dept}"
    [ -n "$city" ] && line="${line} (${city})"
    [ -n "$salary" ] && line="${line} | ${salary}"
    [ -n "$jtype" ] && line="${line} | ${jtype}"
    printf '%s\t%s\t%s\tfirejobs\t%s\n' "$jid" "$line" "$url" "$city" >> "$JOBS_FILE"
    log "  found: $title ($city)"
  done
  page_jobs=$(echo "$html" | grep -oP 'href="/jobs/[^"]+' | grep -v 'new' | wc -l)
  fj_total_scraped=$((fj_total_scraped + page_jobs))
  log "  page $page: $page_jobs listings scraped"
  sleep 1
done
fj_count=$(grep -c 'firejobs' "$JOBS_FILE" 2>/dev/null || echo 0)
log "  firejobs done: scraped $fj_total_scraped total listings, $fj_count North TX jobs"

# --- Source 3: TCFP (Texas Commission on Fire Protection) ---
log "[3/5] TCFP fire service careers..."
if /home/ubuntu/.local/bin/dev-browser status > /dev/null 2>&1; then
  tcfp_tmp=$(mktemp)
  timeout 60 bash "$SCRIPT_DIR/scrape-tcfp.sh" > "$tcfp_tmp" 2>> "$LOGFILE"
  tcfp_exit=$?
  if [ "$tcfp_exit" -ne 0 ]; then
    log_err "  TCFP scraper exited $tcfp_exit"
  fi
  tcfp_count=0
  while IFS= read -r line; do
    title=$(echo "$line" | jq -r '.title // empty' 2>/dev/null)
    city=$(echo "$line" | jq -r '.city // empty' 2>/dev/null)
    dept=$(echo "$line" | jq -r '.department // empty' 2>/dev/null)
    url=$(echo "$line" | jq -r '.url // empty' 2>/dev/null)
    salary=$(echo "$line" | jq -r '.salary // empty' 2>/dev/null)
    jtype=$(echo "$line" | jq -r '.type // empty' 2>/dev/null)
    [ -z "$title" ] && continue
    # Create a stable job ID from city+dept+title
    jid="tcfp-$(echo "${city}-${dept}-${title}" | md5sum | cut -c1-10)"
    line_fmt="${title} — ${dept}"
    [ -n "$city" ] && line_fmt="${line_fmt} (${city}, TX)"
    [ -n "$salary" ] && line_fmt="${line_fmt} | ${salary}"
    [ -n "$jtype" ] && line_fmt="${line_fmt} | ${jtype}"
    loc_ctx="${city}, TX"
    printf '%s\t%s\t%s\ttcfp\t%s\n' "$jid" "$line_fmt" "$url" "$loc_ctx" >> "$JOBS_FILE"
    tcfp_count=$((tcfp_count + 1))
  done < "$tcfp_tmp"
  rm -f "$tcfp_tmp"
  log "  TCFP done: $tcfp_count jobs"
else
  log_err "  dev-browser daemon not running — skipping TCFP"
fi

# --- Source 4: Craigslist DFW (bridge/holdover jobs) ---
log "[4/5] Craigslist DFW (bridge jobs)..."
if /home/ubuntu/.local/bin/dev-browser status > /dev/null 2>&1; then
  cl_tmp=$(mktemp)
  timeout 300 bash "$SCRIPT_DIR/scrape-craigslist.sh" > "$cl_tmp" 2>> "$LOGFILE"
  cl_exit=$?
  if [ "$cl_exit" -ne 0 ]; then
    log_err "  Craigslist scraper exited $cl_exit"
  fi
  cl_count=0
  while IFS= read -r line; do
    title=$(echo "$line" | jq -r '.title // empty' 2>/dev/null)
    city=$(echo "$line" | jq -r '.city // empty' 2>/dev/null)
    url=$(echo "$line" | jq -r '.url // empty' 2>/dev/null)
    [ -z "$title" ] && continue
    jid="cl-$(echo "$url" | grep -oP '[0-9]{8,}' | tail -1)"
    [ -z "$jid" ] || [ "$jid" = "cl-" ] && jid="cl-$(echo "$url" | md5sum | cut -c1-10)"
    line_fmt="${title}"
    [ -n "$city" ] && line_fmt="${line_fmt} (${city})"
    printf '%s\t%s\t%s\tcraigslist\t%s\n' "$jid" "$line_fmt" "$url" "$city" >> "$JOBS_FILE"
    cl_count=$((cl_count + 1))
  done < "$cl_tmp"
  rm -f "$cl_tmp"
  log "  Craigslist done: $cl_count jobs"
else
  log_err "  dev-browser daemon not running — skipping Craigslist"
fi

# --- Source 5: publicsafetyanswers.com (fire/police hiring platform) ---
log "[5/5] publicsafetyanswers.com..."
psa_tmp=$(mktemp)
timeout 180 bash "$SCRIPT_DIR/scrape-publicsafety.sh" > "$psa_tmp" 2>> "$LOGFILE"
psa_exit=$?
if [ "$psa_exit" -eq 124 ]; then
  log "  publicsafetyanswers.com timed out at 180s — using partial results"
elif [ "$psa_exit" -ne 0 ]; then
  log_err "  publicsafetyanswers.com scraper exited $psa_exit"
fi
psa_count=0
while IFS= read -r line; do
  title=$(echo "$line" | jq -r '.title // empty' 2>/dev/null)
  url=$(echo "$line" | jq -r '.url // empty' 2>/dev/null)
  city=$(echo "$line" | jq -r '.city // empty' 2>/dev/null)
  closes=$(echo "$line" | jq -r '.closes // empty' 2>/dev/null)
  desc=$(echo "$line" | jq -r '.description // empty' 2>/dev/null | tr '\t\n' '  ' | cut -c1-300)
  [ -z "$title" ] && continue
  [ -z "$url" ] && continue
  # Stable job id from city slug + closes date (so a re-opened cycle gets a fresh id)
  jid="psa-${city}-${closes}"
  line_fmt="${title}"
  [ -n "$closes" ] && line_fmt="${line_fmt} (closes ${closes})"
  [ -n "$desc" ] && line_fmt="${line_fmt} | ${desc}"
  printf '%s\t%s\t%s\tpublicsafetyanswers\t%s\n' "$jid" "$line_fmt" "$url" "$city" >> "$JOBS_FILE"
  psa_count=$((psa_count + 1))
done < "$psa_tmp"
rm -f "$psa_tmp"
log "  publicsafetyanswers.com done: $psa_count jobs"

# --- Intelligent Filter via kiro-cli ---
pre_filter_count=$(grep -c . "$JOBS_FILE" 2>/dev/null || echo 0)
pre_filter_count=${pre_filter_count//[^0-9]/}
if [ "$pre_filter_count" -gt 0 ] && [ -x "$FILTER_SCRIPT" ]; then
  log "Running kiro-cli intelligent filter on $pre_filter_count jobs..."
  FILTERED_FILE=$(mktemp)
  FILTER_RESULT=$("$FILTER_SCRIPT" "$JOBS_FILE" 2>> "$LOGFILE")
  if [ -n "$FILTER_RESULT" ]; then
    # Rebuild JOBS_FILE with only jobs that passed the filter (score 3+)
    KEPT_FILE=$(mktemp)
    echo "$FILTER_RESULT" | while IFS= read -r line; do
      jid=$(echo "$line" | jq -r '.jid // empty' 2>/dev/null)
      reason=$(echo "$line" | jq -r '.reason // empty' 2>/dev/null)
      score=$(echo "$line" | jq -r '.score // 0' 2>/dev/null)
      [ -z "$jid" ] && continue
      # Find matching line in JOBS_FILE and keep it
      match=$(grep "^${jid}	" "$JOBS_FILE" | head -1)
      if [ -n "$match" ]; then
        echo "$match" >> "$KEPT_FILE"
        log "  ✅ [$score] $jid — $reason"
      fi
    done
    # Replace JOBS_FILE with filtered version
    if [ -s "$KEPT_FILE" ]; then
      mv "$KEPT_FILE" "$JOBS_FILE"
    else
      rm -f "$KEPT_FILE"
    fi
    kept_count=$(grep -c . "$JOBS_FILE" 2>/dev/null || echo 0)
    log "Filter result: $pre_filter_count → $kept_count jobs (kiro-cli scored 3+)"
  else
    log "  kiro-cli filter returned empty — keeping all jobs (fallback)"
  fi
  rm -f "$FILTERED_FILE"
else
  [ "$pre_filter_count" -eq 0 ] && log "No jobs to filter"
  [ ! -x "$FILTER_SCRIPT" ] && log "Filter script not found — using all jobs"
fi

# --- Build digest ---
total=$(grep -c . "$JOBS_FILE" 2>/dev/null | tail -1 || echo 0)
total=${total//[^0-9]/}
log "Total jobs collected: $total"

{
  echo "# 🚒 North Texas Firefighter Jobs — $DATE_LABEL"
  echo ""
  echo "_Centered on Denton, TX | Sources: GovernmentJobs.com + FireJobs.com + TCFP + Craigslist DFW_"
  echo ""
} > "$DIGEST_FILE"

if [ "$total" -eq 0 ]; then
  echo "No North TX firefighter job postings found today." >> "$DIGEST_FILE"
  log "No postings found from any source"
else
  cur_source=""
  seen_count=0
  NEW_JOBS_TSV=$(mktemp)
  sort -t$'\t' -k4 "$JOBS_FILE" | while IFS=$'\t' read -r jid title url source _location; do
    [ -z "$jid" ] && continue
    if is_seen "$jid"; then
      seen_count=$((seen_count + 1))
      continue
    fi
    if [ "$source" != "$cur_source" ]; then
      case "$source" in
        governmentjobs) echo "## 🏛️ GovernmentJobs.com" ;; firejobs) echo "## 🔥 FireJobs.com" ;; tcfp) echo "## 🧑‍🚒 TCFP (Texas Commission on Fire Protection)" ;; craigslist) echo "## 📋 Craigslist DFW (Bridge Jobs)" ;; esac >> "$DIGEST_FILE"
      echo "" >> "$DIGEST_FILE"
      cur_source="$source"
    fi
    echo "• **${title}**" >> "$DIGEST_FILE"
    echo "  ${url}" >> "$DIGEST_FILE"
    echo "" >> "$DIGEST_FILE"
    # Save new job to TSV for personalized digest
    grep "^${jid}	" "$JOBS_FILE" >> "$NEW_JOBS_TSV"
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
  # Generate personalized digest via kiro-cli
  DIGEST_SCRIPT="$SCRIPT_DIR/fire-jobs-digest.sh"
  if [ -x "$DIGEST_SCRIPT" ] && [ -s "$NEW_JOBS_TSV" ]; then
    log "Generating personalized digest via kiro-cli..."
    PERSONALIZED=$("$DIGEST_SCRIPT" "$NEW_JOBS_TSV" 2>> "$LOGFILE")
    if [ -n "$PERSONALIZED" ]; then
      {
        echo "# 🚒 North Texas Firefighter Jobs — $DATE_LABEL"
        echo ""
        echo "$PERSONALIZED"
        echo ""
        echo "---"
        echo "_${total} postings found, ${new_count} new._"
      } > "$DIGEST_FILE"
      log "Personalized digest generated"
    else
      log "kiro-cli digest returned empty — using standard digest"
    fi
  fi

  body=$(cat "$DIGEST_FILE")
  # Email via gog (Google OAuth)
  if gog gmail send -a brandon.tyler@gmail.com \
    --to "brandon.tyler@gmail.com" \
    --subject "🚒 ${new_count} firefighter job(s) — North TX — $DATE_LABEL" \
    --body "$body" > /dev/null 2>&1; then
    log "Email sent via gog"
  else
    log_err "Email send failed"
  fi
  # Discord notification — full summary, split into ≤1800-char chunks (Discord cap is 2000)
  DISCORD_TOKEN=$(jq -r '.channels.discord.token // empty' ~/.openclaw/openclaw.json 2>/dev/null)
  DISCORD_CHANNEL="1503414103341797406"
  if [ -n "$DISCORD_TOKEN" ] && [ -s "$NEW_JOBS_TSV" ]; then
    send_discord() {
      curl -s -X POST "https://discord.com/api/v10/channels/${DISCORD_CHANNEL}/messages" \
        -H "Authorization: Bot $DISCORD_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$(jq -nc --arg c "$1" '{content:$c}')" > /dev/null
    }
    chunk="🚒 **${new_count} new firefighter job(s) — North TX** — ${DATE_LABEL}"
    cur_source=""
    sec=""
    while IFS=$'\t' read -r jid title url source location; do
      [ -z "$jid" ] && continue
      if [ "$source" != "$cur_source" ]; then
        case "$source" in
          governmentjobs)      sec="🏛️ **GovernmentJobs.com**" ;;
          firejobs)            sec="🔥 **FireJobs.com**" ;;
          tcfp)                sec="🧑‍🚒 **TCFP**" ;;
          craigslist)          sec="📋 **Craigslist DFW**" ;;
          publicsafetyanswers) sec="🛡️ **PublicSafetyAnswers**" ;;
          *)                   sec="**${source}**" ;;
        esac
        chunk="${chunk}"$'\n\n'"${sec}"
        cur_source="$source"
      fi
      # Truncate over-long titles so a single job can't blow a chunk
      short_title="${title:0:200}"
      job_block=$'\n'"• **${short_title}**"$'\n'"<${url}>"
      candidate="${chunk}${job_block}"
      if [ ${#candidate} -gt 1800 ]; then
        send_discord "$chunk"
        chunk="${sec}${job_block}"
      else
        chunk="$candidate"
      fi
    done < <(sort -t$'\t' -k4 "$NEW_JOBS_TSV")
    [ -n "$chunk" ] && send_discord "$chunk"
    log "Discord summary sent (${new_count} jobs, with per-job links)"
  elif [ -n "$DISCORD_TOKEN" ]; then
    # Fallback if NEW_JOBS_TSV is missing for any reason
    curl -s -X POST "https://discord.com/api/v10/channels/${DISCORD_CHANNEL}/messages" \
      -H "Authorization: Bot $DISCORD_TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"content\":$(echo "🚒 ${new_count} new firefighter job(s) in North TX. Check email." | jq -Rs .)}" > /dev/null
    log "Discord notification sent (fallback, no NEW_JOBS_TSV)"
  fi
  rm -f "$NEW_JOBS_TSV"
else
  log "No new jobs — skipping notifications"
  rm -f "$NEW_JOBS_TSV"
fi

log "Done. Log: $LOGFILE"
cat "$DIGEST_FILE"
