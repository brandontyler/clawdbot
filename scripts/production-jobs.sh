#!/usr/bin/env bash
# production-jobs.sh — Daily DFW film/TV/video production job search
#
# Sources:
#   1. X/Twitter crew calls (bird search)
#   2. Craigslist DFW (tv/film/video + crew gigs sections)
#   3. NeoGov/GovernmentJobs (city media departments)
#   4. kiro-cli LLM filter for relevance
#
# Delivery: Discord + email
set -uo pipefail

source ~/.profile
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TODAY=$(date +%Y-%m-%d)
LOGFILE="/home/ubuntu/logs/production-jobs/$(date +%Y-%m-%d).log"
JOBS_FILE=$(mktemp)
DIGEST_FILE="/tmp/production-jobs-digest-${TODAY}.md"

mkdir -p "$(dirname "$LOGFILE")" /tmp

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOGFILE"; }

log "=== Production Jobs Search — $TODAY ==="

# --- Source 1: LinkedIn (primary — best coverage for production jobs) ---
log "Searching LinkedIn for DFW production jobs..."

# Search 1: Film/TV specific titles
LINKEDIN_HTML=$(curl -sL "https://www.linkedin.com/jobs/search?keywords=%22production+coordinator%22+OR+%22production+assistant%22+OR+%22line+producer%22+OR+%22UPM%22+OR+%22post+production%22+OR+%22production+manager%22+%28film+OR+tv+OR+video+OR+media+OR+broadcast+OR+streaming+OR+entertainment+OR+studio+OR+creative%29&location=Dallas-Fort+Worth+Metroplex&f_TPR=r2592000&position=1&pageNum=0" \
  -H "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36" \
  -H "Accept: text/html" 2>/dev/null)

# Search 2: Broader Texas search for rarer film-specific roles
LINKEDIN_HTML2=$(curl -sL "https://www.linkedin.com/jobs/search?keywords=%22set+PA%22+OR+%22office+PA%22+OR+%22production+secretary%22+OR+%22production+accountant%22+OR+%22assistant+director%22+OR+%22script+supervisor%22+OR+%22location+manager%22+film+tv&location=Texas%2C+United+States&f_TPR=r2592000&position=1&pageNum=0" \
  -H "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36" \
  -H "Accept: text/html" 2>/dev/null)

# Parse both searches
for HTML_VAR in "$LINKEDIN_HTML" "$LINKEDIN_HTML2"; do
  echo "$HTML_VAR" | python3 -c "
import sys, re
html = sys.stdin.read()
titles = re.findall(r'base-search-card__title[^>]*>\s*([^<]+)', html)
companies = re.findall(r'base-search-card__subtitle[^>]*>\s*([^<]+)', html)
locations = re.findall(r'job-search-card__location[^>]*>\s*([^<]+)', html)
links = re.findall(r'href=\"(https://www.linkedin.com/jobs/view/[^\"?]+)', html)
for i in range(min(len(titles), 20)):
    t = titles[i].strip() if i < len(titles) else ''
    c = companies[i].strip() if i < len(companies) else ''
    l = locations[i].strip() if i < len(locations) else ''
    link = links[i] if i < len(links) else ''
    if t:
        print(f'li-{i}\tlinkedin\t{c}\t{t} [{l}]\t{link}')
" >> "$JOBS_FILE" 2>/dev/null
done

LI_COUNT=$(grep -c "linkedin" "$JOBS_FILE" 2>/dev/null || echo 0)
log "  LinkedIn: found $LI_COUNT results"

# --- Source 2: X/Twitter crew calls ---
log "Searching X for DFW production crew calls..."
TWITTER_RESULTS=$(bird search '"production manager" OR "production coordinator" OR "line producer" OR "UPM" OR "production assistant" OR "crew call" (Dallas OR DFW OR "Fort Worth" OR Texas OR "North Texas") (hiring OR job OR gig OR "crew call" OR apply OR paid)' -n 15 --json 2>/dev/null || echo "[]")

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
    JOB_LIST="${JOB_LIST}${i}. [${source}] ${title}\n"
    i=$((i + 1))
  done < "$JOBS_FILE"

  PROMPT="You are filtering job postings for Nathan Tyler (Brandon's son).

NATHAN'S PROFILE:
- Wants to work in film/TV/video PRODUCTION MANAGEMENT
- Located in DFW (Dallas-Fort Worth, Texas)
- Has some experience, looking for entry-to-mid level
- Target roles: Production Manager, Production Coordinator, Line Producer, UPM (Unit Production Manager), Production Assistant (PA), Assistant Production Manager
- Also interested in: Set PA, Office PA, Production Secretary, Production Accountant, Post-Production Coordinator
- Open to: film, TV, streaming, commercial, corporate video, music video, live events
- NOT interested in: acting, camera/grip/electric (unless production dept), sales, marketing, unrelated industries

Score each 1-5:
5 = Production management role in DFW
4 = Related production role in DFW, or production management in Texas
3 = Tangentially related (media, events) in DFW
2 = Wrong location or only loosely related
1 = Not relevant at all

Reply ONLY with JSON lines: {\"idx\":<number>,\"score\":<1-5>,\"reason\":\"<brief>\"}

Jobs:
$(echo -e "$JOB_LIST")"

  RAW=$(cd "$HOME" && timeout 60 kiro-cli chat --trust-tools= --wrap never "$PROMPT" 2>/dev/null)
  SCORES=$(echo "$RAW" | sed 's/\x1b\[[0-9;]*m//g' | grep -oP '\{[^}]+\}')

  # Build digest
  {
    echo "# 🎬 Production Jobs — $TODAY"
    echo ""
    echo "_DFW film/TV/video production management opportunities_"
    echo ""
  } > "$DIGEST_FILE"

  KEPT=0
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

    {
      echo "**${title}**"
      echo "Source: ${source} | Score: ${score}/5 | ${reason}"
      echo "${url}"
      echo ""
    } >> "$DIGEST_FILE"
    KEPT=$((KEPT + 1))
  done <<< "$SCORES"

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
