#!/usr/bin/env bash
# production-jobs.sh — Daily DFW film/TV/video production job search
#
# Sources:
#   1. Staff Me Up (industry standard for film/TV crew)
#   2. LinkedIn (broad + 1st AD specific)
#   3. X/Twitter crew calls (bird search)
#   4. Craigslist DFW (tv/film/video + crew gigs sections)
#   5. GovernmentJobs (city media departments)
#   6. kiro-cli LLM filter for relevance
#
# Deduplication: DynamoDB (production-jobs-seen, 60-day TTL)
# Delivery: Discord + email
set -uo pipefail

source ~/.profile
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TODAY=$(date +%Y-%m-%d)
LOGFILE="/home/ubuntu/logs/production-jobs/$(date +%Y-%m-%d).log"
JOBS_FILE=$(mktemp)
DIGEST_FILE="/tmp/production-jobs-digest-${TODAY}.md"
PROFILE="personal"
REGION="us-east-1"
DYNAMO_TABLE="production-jobs-seen"
TTL_DAYS=60
EXPIRES_AT=$(date -d "+${TTL_DAYS} days" +%s)

mkdir -p "$(dirname "$LOGFILE")" /tmp

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOGFILE"; }

# --- DynamoDB dedup setup ---
DYNAMO_OK=0
if aws dynamodb describe-table --table-name "$DYNAMO_TABLE" --profile "$PROFILE" --region "$REGION" > /dev/null 2>&1; then
  DYNAMO_OK=1
else
  log "Creating DynamoDB table $DYNAMO_TABLE..."
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
  local clean_title=$(echo "$2" | tr -d '"' | cut -c1-200)
  aws dynamodb put-item --table-name "$DYNAMO_TABLE" \
    --item "{\"job_id\":{\"S\":\"$1\"},\"title\":{\"S\":\"$clean_title\"},\"source\":{\"S\":\"$3\"},\"found_date\":{\"S\":\"$TODAY\"},\"expires_at\":{\"N\":\"$EXPIRES_AT\"}}" \
    --profile "$PROFILE" --region "$REGION" > /dev/null 2>&1
}

log "=== Production Jobs Search — $TODAY ==="

# --- Source 1: Staff Me Up (primary — industry standard for film/TV crew) ---
log "Searching Staff Me Up..."
SMU_DATA=$(timeout 30 dev-browser --headless --timeout 25 <<'DEVEOF' 2>/dev/null
const page = await browser.newPage();
try {
  await page.goto("https://app.staffmeup.com/jobs", { timeout: 15000 });
  await new Promise(r => setTimeout(r, 6000));
  const html = await page.content();
  const match = html.match(/__NEXT_DATA__[^>]*>(.*?)<\/script/s);
  if (match) console.log(match[1]);
} catch(e) {}
await page.close();
DEVEOF
)

if [ -n "$SMU_DATA" ]; then
  echo "$SMU_DATA" | python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    schemas = d['props']['pageProps']['jobSchemas']
    for i, j in enumerate(schemas):
        title = j.get('title', '')
        company = j.get('hiringOrganization', {}).get('name', '')
        loc = j.get('jobLocation', {}).get('address', {})
        city = loc.get('addressLocality', '')
        state = loc.get('addressRegion', '')
        desc = j.get('description', '').replace('\n', ' ').replace('\t', ' ')[:150]
        # Only include Texas jobs or remote
        if state in ('TX', 'Texas', '') or 'remote' in desc.lower():
            print(f'smu-{i}\tstaffmeup\t{company}\t{title} [{city}, {state}] — {desc}\thttps://app.staffmeup.com/jobs')
except Exception as e:
    pass
" >> "$JOBS_FILE" 2>/dev/null
  SMU_COUNT=$(grep -c "staffmeup" "$JOBS_FILE" 2>/dev/null || echo 0)
  log "  Staff Me Up: found $SMU_COUNT Texas jobs"
else
  log "  Staff Me Up: login/fetch failed (will retry next run)"
fi

# --- Source 2: LinkedIn (broad coverage) ---
log "Searching LinkedIn for DFW production jobs..."

# Search 1: Film/TV production management + crew roles
LINKEDIN_HTML=$(curl -sL "https://www.linkedin.com/jobs/search?keywords=%22production+coordinator%22+OR+%22production+assistant%22+OR+%22line+producer%22+OR+%22UPM%22+OR+%22post+production%22+OR+%22production+manager%22+OR+%222nd+AD%22+OR+%22second+assistant+director%22+OR+%22key+PA%22+OR+%22production+supervisor%22+%28film+OR+tv+OR+video+OR+media+OR+broadcast+OR+streaming+OR+entertainment+OR+studio+OR+creative+OR+set%29&location=Dallas-Fort+Worth+Metroplex&f_TPR=r2592000&position=1&pageNum=0" \
  -H "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36" \
  -H "Accept: text/html" 2>/dev/null)

# Search 2: 1st AD + assistant director + other film-specific roles
LINKEDIN_HTML2=$(curl -sL "https://www.linkedin.com/jobs/search?keywords=%221st+AD%22+OR+%22first+assistant+director%22+OR+%22assistant+director%22+OR+%22set+PA%22+OR+%22office+PA%22+OR+%22production+secretary%22+OR+%22production+accountant%22+OR+%22script+supervisor%22+OR+%22location+manager%22+OR+%22key+PA%22+film+tv&location=Dallas-Fort+Worth+Metroplex&f_TPR=r2592000&position=1&pageNum=0" \
  -H "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36" \
  -H "Accept: text/html" 2>/dev/null)

# Search 3: Broader Texas for 1st AD (rare role, cast wider net)
LINKEDIN_HTML3=$(curl -sL "https://www.linkedin.com/jobs/search?keywords=%221st+AD%22+OR+%22first+assistant+director%22+OR+%22assistant+director%22+%28film+OR+tv+OR+set+OR+production+OR+studio%29&location=Texas%2C+United+States&f_TPR=r2592000&position=1&pageNum=0" \
  -H "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36" \
  -H "Accept: text/html" 2>/dev/null)

# Parse all searches
for HTML_VAR in "$LINKEDIN_HTML" "$LINKEDIN_HTML2" "$LINKEDIN_HTML3"; do
  echo "$HTML_VAR" | python3 -c "
import sys, re
html = sys.stdin.read()
titles = re.findall(r'base-search-card__title[^>]*>\s*([^<]+)', html)
companies = re.findall(r'base-search-card__subtitle[^>]*>\s*([^<]+)', html)
locations = re.findall(r'job-search-card__location[^>]*>\s*([^<]+)', html)
links = re.findall(r'href=\"(https://www.linkedin.com/jobs/view/[^\"?]+)', html)
for i in range(min(len(titles), 20)):
    t = titles[i].strip() if i < len(titles) else ''
    c = companies[i].strip() if i < len(companies) else '-'
    l = locations[i].strip() if i < len(locations) else ''
    link = links[i] if i < len(links) else ''
    if not c:
        c = '-'
    if t:
        print(f'li-{i}\tlinkedin\t{c}\t{t} [{l}]\t{link}')
" >> "$JOBS_FILE" 2>/dev/null
done

LI_COUNT=$(grep -c "linkedin" "$JOBS_FILE" 2>/dev/null || echo 0)
log "  LinkedIn: found $LI_COUNT results"

# --- Source 2: X/Twitter crew calls ---
log "Searching X for DFW production crew calls..."
TWITTER_RESULTS=$(bird search '"production manager" OR "production coordinator" OR "line producer" OR "UPM" OR "production assistant" OR "1st AD" OR "assistant director" OR "crew call" (Dallas OR DFW OR "Fort Worth" OR Texas OR "North Texas") (hiring OR job OR gig OR "crew call" OR apply OR paid)' -n 15 --json 2>/dev/null || echo "[]")

TWITTER_COUNT=$(echo "$TWITTER_RESULTS" | jq 'length' 2>/dev/null || echo 0)
log "  X: found $TWITTER_COUNT results"

# Extract to TSV
echo "$TWITTER_RESULTS" | jq -r '.[] | "\(.id)\ttwitter\t\(.author.username)\t\(.text | gsub("\n";" ") | .[0:200])\thttps://x.com/\(.author.username)/status/\(.id)"' >> "$JOBS_FILE" 2>/dev/null

# --- Source 2: Craigslist DFW ---
log "Searching Craigslist DFW..."

# TV/Film/Video section
CL_TFR=$(curl -s "https://dallas.craigslist.org/search/tfr#search=1~list~0~0" \
  -H "User-Agent: Mozilla/5.0 (X11; Linux x86_64)" 2>/dev/null | \
  grep -oP 'href="/[^"]*" [^>]*class="posting-title"[^>]*>.*?</a>' | \
  grep -i "production\|producer\|coordinator\|PA\b\|assistant\|manager\|crew" | \
  sed 's/.*href="//;s/" .*//' | head -10)

for url in $CL_TFR; do
  title=$(curl -s "https://dallas.craigslist.org${url}" -H "User-Agent: Mozilla/5.0" 2>/dev/null | grep -oP '<title>[^<]+' | sed 's/<title>//' | head -1)
  [ -n "$title" ] && printf '%s\tcraigslist\t%s\t%s\thttps://dallas.craigslist.org%s\n' "cl-$(echo "$url" | grep -oP '\d+')" "craigslist" "$title" "$url" >> "$JOBS_FILE"
done

# Crew gigs section
CL_CWG=$(curl -s "https://dallas.craigslist.org/search/cwg#search=1~list~0~0" \
  -H "User-Agent: Mozilla/5.0 (X11; Linux x86_64)" 2>/dev/null | \
  grep -oP 'href="/[^"]*" [^>]*class="posting-title"[^>]*>.*?</a>' | \
  grep -i "production\|producer\|coordinator\|film\|video\|tv\|shoot\|set" | \
  sed 's/.*href="//;s/" .*//' | head -10)

for url in $CL_CWG; do
  title=$(curl -s "https://dallas.craigslist.org${url}" -H "User-Agent: Mozilla/5.0" 2>/dev/null | grep -oP '<title>[^<]+' | sed 's/<title>//' | head -1)
  [ -n "$title" ] && printf '%s\tcraigslist\t%s\t%s\thttps://dallas.craigslist.org%s\n' "cl-$(echo "$url" | grep -oP '\d+')" "craigslist" "$title" "$url" >> "$JOBS_FILE"
done

CL_COUNT=$(grep -c "craigslist" "$JOBS_FILE" 2>/dev/null || echo 0)
log "  Craigslist: found $CL_COUNT results"

# --- Source 3: GovernmentJobs (city media/production departments) ---
log "Searching GovernmentJobs for city media positions..."
NEOGOV_SEARCHES=(
  "https://www.governmentjobs.com/careers/cityofdallas?keywords=production+video+film+media"
  "https://www.governmentjobs.com/careers/cityofirving?keywords=production+video+media"
  "https://www.governmentjobs.com/careers/cityoffortworth?keywords=production+video+media"
  "https://www.governmentjobs.com/careers/cityofplano?keywords=production+media"
)

for url in "${NEOGOV_SEARCHES[@]}"; do
  RESULTS=$(curl -s "$url" -H "User-Agent: Mozilla/5.0 (X11; Linux x86_64)" 2>/dev/null | \
    grep -oP 'class="item-title"[^>]*>[^<]+' | sed 's/.*>//g')
  while IFS= read -r title; do
    [ -n "$title" ] && printf '%s\tneogov\t%s\t%s\t%s\n' "ng-$(echo "$title" | md5sum | cut -c1-8)" "neogov" "$title" "$url" >> "$JOBS_FILE"
  done <<< "$RESULTS"
done

NEOGOV_COUNT=$(grep -c "neogov" "$JOBS_FILE" 2>/dev/null || echo 0)
log "  GovernmentJobs: found $NEOGOV_COUNT results"

# --- Total ---
TOTAL=$(wc -l < "$JOBS_FILE" 2>/dev/null || echo 0)
log "Total raw results: $TOTAL"

if [ "$TOTAL" -eq 0 ]; then
  log "No production jobs found today"
  {
    echo "# Production Jobs — $TODAY"
    echo ""
    echo "No new production/film/TV jobs found in DFW today."
    echo "Sources checked: X/Twitter, Craigslist DFW, GovernmentJobs"
  } > "$DIGEST_FILE"
else
  # --- LLM Filter ---
  log "Filtering $TOTAL results via kiro-cli..."

  JOB_LIST=""
  i=1
  while IFS=$'\t' read -r jid source poster title url; do
    [ -z "$jid" ] && continue
    [ "$i" -gt 25 ] && break
    clean_title=$(echo "$title" | tr -d '"\\`$' | cut -c1-100)
    company=""
    [ "$poster" != "-" ] && [ -n "$poster" ] && company=" @ ${poster}"
    JOB_LIST="${JOB_LIST}- [${i}] ${clean_title}${company}
"
    i=$((i + 1))
  done < "$JOBS_FILE"

  PROMPT="Filter jobs for Nathan Tyler. DFW film/TV/video production management. Dream role: 1st AD (First Assistant Director) on set.
Score 1-5. Only 3+ if CONFIRMED DFW or Texas AND clearly film/TV/video/media industry.
REJECT (score 1): manufacturing, garment, athletic wear, food production, industrial, retail, construction, warehouse, automotive, packaging, distribution, printing, logistics, data entry. These are NOT film production. Companies like Veritiv, Rebel Athletic, Variosystems, Adecco (staffing) = score 1.
5=1st AD or assistant director on film/TV set. 5=film/media production management role. 4=video/creative/media production role. 3=production-adjacent in entertainment/media. 2=unclear industry. 1=non-media production or irrelevant.
Output ONLY JSON lines: {\"idx\":<N>,\"score\":<1-5>,\"reason\":\"<brief>\"}

${JOB_LIST}"

  RAW=$(cd "$HOME" && timeout 60 kiro-cli chat --no-interactive --wrap never "$PROMPT" 2>&1)

  SCORES=$(echo "$RAW" | sed 's/\x1b\[[0-9;]*m//g' | grep -oP '\{[^}]+\}')

  # Build digest
  {
    echo "# 🎬 Production Jobs — $TODAY"
    echo ""
    echo "_DFW film/TV/video production management opportunities_"
    echo ""
  } > "$DIGEST_FILE"

  KEPT=0
  SEEN_SKIPPED=0
  while IFS= read -r score_line; do
    [ -z "$score_line" ] && continue
    idx=$(echo "$score_line" | jq -r '.idx // 0' 2>/dev/null)
    score=$(echo "$score_line" | jq -r '.score // 0' 2>/dev/null)
    reason=$(echo "$score_line" | jq -r '.reason // ""' 2>/dev/null)
    [ "$score" -lt 3 ] 2>/dev/null && continue

    # Get the original job data
    JOB_LINE=$(sed -n "${idx}p" "$JOBS_FILE")
    [ -z "$JOB_LINE" ] && continue
    IFS=$'\t' read -r jid source poster title url <<< "$JOB_LINE"

    # Dedup: skip if already seen
    if is_seen "$jid"; then
      SEEN_SKIPPED=$((SEEN_SKIPPED + 1))
      continue
    fi

    # Fetch extra detail for LinkedIn jobs (public description snippet)
    DETAIL=""
    if [[ "$source" == "linkedin" ]] && [[ -n "$url" ]]; then
      DETAIL=$(curl -sL "$url" \
        -H "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36" \
        -H "Accept: text/html" 2>/dev/null | python3 -c "
import sys, re, html
page = sys.stdin.read()
# Get description from meta or show-more section
desc = ''
m = re.search(r'<meta[^>]*name=\"description\"[^>]*content=\"([^\"]+)\"', page)
if m:
    desc = html.unescape(m.group(1)).strip()
if not desc:
    m = re.search(r'show-more-less-html__markup[^>]*>(.*?)</div', page, re.S)
    if m:
        desc = re.sub(r'<[^>]+>', ' ', m.group(1)).strip()
# Clean and truncate
desc = re.sub(r'\s+', ' ', desc)[:300]
print(desc)
" 2>/dev/null)
    fi

    {
      echo "${title}"
      [ -n "$DETAIL" ] && echo "  ${DETAIL}"
      echo "Source: ${source} | Score: ${score}/5 | ${reason}"
      echo "${url}"
      echo ""
    } >> "$DIGEST_FILE"
    mark_seen "$jid" "$title" "$source"
    KEPT=$((KEPT + 1))
  done <<< "$SCORES"

  log "  Dedup: $SEEN_SKIPPED already-seen jobs skipped"

  {
    echo "---"
    echo "_${TOTAL} postings scanned, ${KEPT} relevant (score ≥ 3/5)_"
  } >> "$DIGEST_FILE"

  log "Filter result: $TOTAL → $KEPT jobs kept"
fi

# --- Deliver ---
DISCORD_CHANNEL="${PRODUCTION_JOBS_DISCORD:-1503414103341797406}"
DISCORD_TOKEN=$(jq -r '.channels.discord.token // empty' ~/.openclaw/openclaw.json 2>/dev/null)

if [ -n "$DISCORD_TOKEN" ]; then
  curl -s -X POST "https://discord.com/api/v10/channels/$DISCORD_CHANNEL/messages" \
    -H "Authorization: Bot $DISCORD_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"content\":$(cat "$DIGEST_FILE" | jq -Rs .)}" > /dev/null
  log "Discord: sent"
fi

# Email digest
if [ "$KEPT" -gt 0 ] 2>/dev/null; then
  gog gmail send -a brandon.tyler@gmail.com \
    --to "brandon.tyler@gmail.com" \
    --subject "🎬 Production Jobs DFW — ${KEPT} found ($TODAY)" \
    --body "$(cat "$DIGEST_FILE")" 2>/dev/null && log "Email sent" || log "Email failed"
fi

rm -f "$JOBS_FILE"
log "Done. Digest: $DIGEST_FILE"
cat "$DIGEST_FILE"
