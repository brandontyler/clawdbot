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
DFW_CITIES = {'dallas','fort worth','ft. worth','ft worth','plano','frisco','mckinney','irving','arlington','denton','garland','mesquite','richardson','lewisville','allen','carrollton','grand prairie','rowlett','wylie','flower mound','addison','coppell','southlake','colleyville','grapevine','euless','bedford','hurst','haltom city','keller','roanoke','mansfield','desoto','cedar hill','duncanville','farmers branch','the colony','little elm','rockwall','burleson','cleburne','sherman','watauga','saginaw','crowley','benbrook','white settlement','university park','highland park','addison','prosper','melissa','anna','celina','aubrey','argyle','justin','sachse','murphy','parker','fairview','sunnyvale','seagoville','glenn heights','ovilla','red oak','waxahachie','midlothian','ennis','terrell','forney','kaufman','heath','royse city','fate','caddo mills','greenville','sulphur springs','sherman','denison','gainesville','decatur','bridgeport','springtown','azle','weatherford','aledo','granbury','glen rose','stephenville','northeast tarrant','north dallas','dfw'}
NON_DFW_TX = {'san antonio','houston','austin','el paso','corpus christi','lubbock','amarillo','waco','galveston','mcallen','midland','odessa','killeen','tyler','beaumont','abilene','laredo','brownsville','college station','san marcos','round rock','pflugerville','cedar park','georgetown','katy','sugar land','the woodlands','spring','cypress','pearland','league city','baytown','conroe','huntsville','nacogdoches','lufkin','longview','marshall','texarkana','victoria','del rio','eagle pass','harlingen','edinburg','mission','pharr','san benito','kingsville','port arthur','orange'}

def is_dfw(city, desc):
    c = (city or '').lower()
    d = (desc or '').lower()
    if any(x in c for x in DFW_CITIES):
        return True
    if any(x in c for x in NON_DFW_TX):
        return False
    if 'dfw' in d or 'dallas' in d or 'fort worth' in d or 'ft. worth' in d or 'ft worth' in d or 'north texas' in d or 'dallas-fort worth' in d or 'dallas/fort worth' in d:
        return True
    return False

try:
    import re, hashlib
    d = json.loads(sys.stdin.read())
    schemas = d['props']['pageProps']['jobSchemas']
    for i, j in enumerate(schemas):
        title = j.get('title', '')
        company = j.get('hiringOrganization', {}).get('name', '')
        loc = j.get('jobLocation', {}).get('address', {})
        city = loc.get('addressLocality', '')
        state = loc.get('addressRegion', '')
        desc = j.get('description', '').replace('\n', ' ').replace('\t', ' ')[:150]
        # DFW-only: must be in TX (or remote with DFW mention) AND match DFW city/keywords
        if state not in ('TX', 'Texas') and 'remote' not in desc.lower():
            continue
        if not is_dfw(city, desc):
            continue
        # Stable id: prefer schema url/identifier, fallback to title+company hash
        url_field = j.get('url') or j.get('@id') or ''
        id_field = j.get('identifier')
        if isinstance(id_field, dict):
            id_field = id_field.get('value', '')
        m = re.search(r'(\d{6,})', str(url_field) + str(id_field or ''))
        if m:
            jid = 'smu-' + m.group(1)
        else:
            jid = 'smu-' + hashlib.md5((title + company + city).encode()).hexdigest()[:10]
        print(f'{jid}\tstaffmeup\t{company}\t{title} [{city}, {state}] — {desc}\thttps://app.staffmeup.com/jobs')
except Exception as e:
    pass
" >> "$JOBS_FILE" 2>/dev/null
  SMU_COUNT=$(grep -c "staffmeup" "$JOBS_FILE" 2>/dev/null || echo 0)
  log "  Staff Me Up: found $SMU_COUNT DFW jobs"
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

# Search 3: DFW-scoped, focused on 2nd AD / DGA / freelance / contract crew
LINKEDIN_HTML3=$(curl -sL "https://www.linkedin.com/jobs/search?keywords=%222nd+AD%22+OR+%22second+assistant+director%22+OR+%22DGA%22+OR+%22freelance+production%22+OR+%22production+manager%22+OR+%22UPM%22+OR+%22line+producer%22+%28film+OR+tv+OR+commercial+OR+streaming+OR+broadcast%29&location=Dallas-Fort+Worth+Metroplex&f_TPR=r2592000&position=1&pageNum=0" \
  -H "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36" \
  -H "Accept: text/html" 2>/dev/null)

# Parse all searches
for HTML_VAR in "$LINKEDIN_HTML" "$LINKEDIN_HTML2" "$LINKEDIN_HTML3"; do
  echo "$HTML_VAR" | python3 -c "
import sys, re
NON_DFW_TX = {'san antonio','houston','austin','el paso','corpus christi','lubbock','amarillo','waco','galveston','mcallen','midland','odessa','killeen','tyler,','beaumont','abilene','laredo','brownsville','college station','san marcos','round rock','pflugerville','cedar park','georgetown','katy','sugar land','the woodlands','spring,','cypress,','pearland','league city','baytown','conroe','huntsville','nacogdoches','lufkin','longview','marshall','texarkana','victoria','del rio','eagle pass','harlingen','edinburg','mission,','pharr','san benito','kingsville','port arthur','orange,'}
DFW_HINTS = ('dallas','fort worth','ft. worth','ft worth','plano','frisco','mckinney','irving','arlington','denton','garland','mesquite','richardson','lewisville','allen,','carrollton','grand prairie','rowlett','wylie','flower mound','coppell','southlake','colleyville','grapevine','euless','bedford','hurst','haltom','keller','roanoke','mansfield','desoto','cedar hill','duncanville','farmers branch','the colony','little elm','rockwall','burleson','cleburne','sherman','watauga','saginaw','crowley','benbrook','dfw','north texas','dallas-fort worth','dallas/fort worth')

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
    if not t:
        continue
    # Drop explicitly non-DFW Texas cities. Keep ambiguous (empty, 'Texas, United States', remote) — LLM will judge.
    loc_lower = l.lower()
    if any(x in loc_lower for x in NON_DFW_TX) and not any(x in loc_lower for x in DFW_HINTS):
        continue
    # Stable id from LinkedIn job URL (last numeric segment), fallback to title+company hash
    import hashlib
    m = re.search(r'/jobs/view/[^/?]*-(\d{8,})', link) or re.search(r'/jobs/view/(\d{8,})', link) or re.search(r'(\d{10,})', link)
    if m:
        jid = 'li-' + m.group(1)
    else:
        jid = 'li-' + hashlib.md5((t + c).encode()).hexdigest()[:10]
    print(f'{jid}\tlinkedin\t{c}\t{t} [{l}]\t{link}')
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

# TV/Film/Video section (new HTML format)
curl -s "https://dallas.craigslist.org/search/tfr" \
  -H "User-Agent: Mozilla/5.0 (X11; Linux x86_64)" 2>/dev/null | \
  python3 -c "
import sys, re
html = sys.stdin.read()
# New format: <a href=\"URL\"><div class=\"title\">TITLE</div>
pairs = re.findall(r'<a href=\"(https://dallas\.craigslist\.org/[^\"]+\.html)\">\s*<div class=\"title\">([^<]+)', html)
keywords = ['production', 'producer', 'coordinator', 'assistant', 'director', 'crew', 'film', 'video', 'tv', 'shoot', 'set', 'camera', 'grip', 'gaffer']
for url, title in pairs:
    if any(k in title.lower() for k in keywords):
        jid = 'cl-' + url.split('/')[-1].replace('.html','')
        print(f'{jid}\tcraigslist\tcraigslist\t{title.strip()}\t{url}')
" >> "$JOBS_FILE" 2>/dev/null

# Crew gigs section
curl -s "https://dallas.craigslist.org/search/cwg" \
  -H "User-Agent: Mozilla/5.0 (X11; Linux x86_64)" 2>/dev/null | \
  python3 -c "
import sys, re
html = sys.stdin.read()
pairs = re.findall(r'<a href=\"(https://dallas\.craigslist\.org/[^\"]+\.html)\">\s*<div class=\"title\">([^<]+)', html)
keywords = ['production', 'producer', 'coordinator', 'film', 'video', 'tv', 'shoot', 'set', 'camera', 'grip', 'gaffer', 'PA', 'director']
for url, title in pairs:
    if any(k in title.lower() for k in keywords) or 'PA' in title:
        jid = 'cl-' + url.split('/')[-1].replace('.html','')
        print(f'{jid}\tcraigslist\tcraigslist\t{title.strip()}\t{url}')
" >> "$JOBS_FILE" 2>/dev/null

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

# --- Source 4: Texas Film Commission Job Hotline (official state film jobs) ---
log "Searching Texas Film Commission hotline..."
curl -sL "https://gov.texas.gov/film/hotline/crew" \
  -H "User-Agent: Mozilla/5.0 (X11; Linux x86_64)" 2>/dev/null | \
  python3 -c "
import sys, re
html = sys.stdin.read()
links = re.findall(r'<a[^>]*href=\"([^\"]*hotline-job/crew/[^\"]+)\"[^>]*>(.*?)</a>', html, re.S)
for url, text in links:
    title = re.sub(r'<[^>]+>', '', text).strip()
    if not title:
        continue
    jid = 'tfc-' + url.split('/')[-1][:20]
    full_url = url if url.startswith('http') else 'https://gov.texas.gov' + url
    print(f'{jid}\ttfc\tTexas Film Commission\t{title}\t{full_url}')
" >> "$JOBS_FILE" 2>/dev/null

TFC_COUNT=$(grep -c "tfc" "$JOBS_FILE" 2>/dev/null || echo 0)
log "  Texas Film Commission: found $TFC_COUNT results"

# --- Source 5: Dallas Producers Association Job Board ---
log "Searching Dallas Producers Association..."
curl -s "https://www.dallasproducers.org/jobs" \
  -H "User-Agent: Mozilla/5.0 (X11; Linux x86_64)" 2>/dev/null | \
  python3 -c "
import sys, re
html = sys.stdin.read()
# Extract job items: title in c-jobitem__head, company in c-jobitem__companyname, link in job-board/
items = re.findall(r'href=\"(/job-board/[^\"]+)\".*?c-jobitem__head\">([^<]+).*?c-jobitem__companyname\">([^<]+)', html, re.S)
for url, title, company in items:
    jid = 'dpa-' + url.split('/')[-1][:20]
    full_url = 'https://www.dallasproducers.org' + url
    print(f'{jid}\tdpa\t{company.strip()}\t{title.strip()} [DFW]\t{full_url}')
" >> "$JOBS_FILE" 2>/dev/null

DPA_COUNT=$(grep -c "dpa" "$JOBS_FILE" 2>/dev/null || echo 0)
log "  Dallas Producers Association: found $DPA_COUNT results"

# --- Total ---
TOTAL=$(wc -l < "$JOBS_FILE" 2>/dev/null || echo 0)
log "Total raw results: $TOTAL"

# --- Reorder by source quality so the LLM sees the best-targeted DFW jobs first ---
# Priority (lower = sent to LLM first):
#   1=DPA (DFW-only)  2=SMU (already DFW-filtered)  3=TFC (TX film hotline)
#   4=Craigslist DFW  5=NeoGov DFW cities  6=LinkedIn (noisy)  7=X (noisiest)
if [ "$TOTAL" -gt 0 ]; then
  SORTED=$(mktemp)
  awk -F'\t' '{
    src=$2
    p=8
    if (src=="dpa")        p=1
    else if (src=="staffmeup") p=2
    else if (src=="tfc")   p=3
    else if (src=="craigslist") p=4
    else if (src=="neogov") p=5
    else if (src=="linkedin") p=6
    else if (src=="twitter") p=7
    print p"\t"$0
  }' "$JOBS_FILE" | sort -k1,1n -s | cut -f2- > "$SORTED"
  mv "$SORTED" "$JOBS_FILE"
fi

# Trusted DFW-only sources: bypass LLM, always include
# Noisy sources (linkedin, twitter, tfc): require LLM filter
is_trusted_source() {
  case "$1" in
    dpa|staffmeup|craigslist|neogov) return 0 ;;
    *) return 1 ;;
  esac
}

if [ "$TOTAL" -eq 0 ]; then
  log "No production jobs found today"
  {
    echo "# Production Jobs — $TODAY"
    echo ""
    echo "No new production/film/TV jobs found in DFW today."
    echo "Sources checked: X/Twitter, Craigslist DFW, GovernmentJobs"
  } > "$DIGEST_FILE"
else
  # Split jobs into trusted (auto-include) and untrusted (LLM-filtered)
  TRUSTED_FILE=$(mktemp)
  UNTRUSTED_FILE=$(mktemp)
  while IFS=$'\t' read -r jid source poster title url; do
    [ -z "$jid" ] && continue
    if is_trusted_source "$source"; then
      printf '%s\t%s\t%s\t%s\t%s\n' "$jid" "$source" "$poster" "$title" "$url" >> "$TRUSTED_FILE"
    else
      printf '%s\t%s\t%s\t%s\t%s\n' "$jid" "$source" "$poster" "$title" "$url" >> "$UNTRUSTED_FILE"
    fi
  done < "$JOBS_FILE"

  TRUSTED_COUNT=$(wc -l < "$TRUSTED_FILE")
  UNTRUSTED_COUNT=$(wc -l < "$UNTRUSTED_FILE")
  log "Trusted (DFW-curated): $TRUSTED_COUNT auto-included | Untrusted (broad sources): $UNTRUSTED_COUNT need LLM"

  # --- LLM Filter (only on untrusted/broad sources) ---
  log "Filtering $UNTRUSTED_COUNT broad-source results via kiro-cli..."

  JOB_LIST=""
  i=1
  while IFS=$'\t' read -r jid source poster title url; do
    [ -z "$jid" ] && continue
    [ "$i" -gt 100 ] && break
    clean_title=$(echo "$title" | tr -d '"\\`$' | cut -c1-100)
    company=""
    [ "$poster" != "-" ] && [ -n "$poster" ] && company=" @ ${poster}"
    # Fetch description snippet for LinkedIn jobs to help filter
    desc_snippet=""
    if [[ "$source" == "linkedin" ]] && [[ -n "$url" ]]; then
      desc_snippet=$(curl -sL "$url" \
        -H "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36" \
        -H "Accept: text/html" 2>/dev/null | python3 -c "
import sys, re, html
page = sys.stdin.read()
m = re.search(r'<meta[^>]*name=\"description\"[^>]*content=\"([^\"]+)\"', page)
if m:
    d = html.unescape(m.group(1)).strip()
    d = re.sub(r'\s+', ' ', d)[:150]
    # Remove the 'Posted X. ' prefix
    d = re.sub(r'^Posted [^.]+\.\s*', '', d)
    print(d)
" 2>/dev/null)
    fi
    if [ -n "$desc_snippet" ]; then
      JOB_LIST="${JOB_LIST}- [${i}] ${clean_title}${company} — ${desc_snippet}
"
    else
      JOB_LIST="${JOB_LIST}- [${i}] ${clean_title}${company}
"
    fi
    i=$((i + 1))
  done < "$UNTRUSTED_FILE"

  PROMPT="Filter jobs for Nathan Tyler. ONLY DFW film/TV/video production jobs. Dream role: 1st AD (First Assistant Director) on set.

HARD RULE — DFW ONLY: The job MUST be in the Dallas-Fort Worth metroplex. Score 1 for ANYTHING else, including:
- Other Texas cities: San Antonio, Houston, Austin, El Paso, Corpus Christi, Lubbock, Waco, Beaumont, Tyler, Longview, etc. → score 1
- Other states: California, New York, Idaho, Florida, etc. → score 1
- Remote-only with no DFW/Dallas/Fort Worth presence → score 1

DFW means: Dallas, Fort Worth, Plano, Frisco, McKinney, Irving, Arlington, Denton, Garland, Mesquite, Richardson, Lewisville, Allen, Carrollton, Grand Prairie, Rowlett, Wylie, Flower Mound, Coppell, Southlake, Colleyville, Grapevine, Mansfield, DeSoto, Cedar Hill, The Colony, Little Elm, Rockwall, Burleson, Sherman, Haltom City, Keller, Watauga, Crowley, Benbrook, etc. — North Texas metro only.

ALSO REJECT (score 1): manufacturing, garment, athletic wear, food production, industrial, retail, construction, warehouse, automotive, packaging, distribution, printing, logistics, data entry. These are NOT film production. Companies like Veritiv, Rebel Athletic, Variosystems, Adecco (staffing) = score 1.

Scoring (DFW-only):
5 = 1st AD or assistant director on film/TV set IN DFW
5 = film/media production management IN DFW
4 = video/creative/media production role IN DFW
3 = production-adjacent in entertainment/media IN DFW
2 = unclear if in DFW (location ambiguous, but mentions DFW-related signals)
1 = NOT in DFW, OR not media/film

Output ONLY JSON lines: {\"idx\":<N>,\"score\":<1-5>,\"reason\":\"<brief>\"}

${JOB_LIST}"

  RAW=$(cd "$HOME" && timeout 240 kiro-cli chat --no-interactive --wrap never "$PROMPT" 2>&1)

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

  # First: auto-include trusted DFW-only sources (DPA, Craigslist DFW, Staff Me Up DFW, NeoGov DFW cities)
  while IFS=$'\t' read -r jid source poster title url; do
    [ -z "$jid" ] && continue
    if is_seen "$jid"; then
      SEEN_SKIPPED=$((SEEN_SKIPPED + 1))
      continue
    fi
    {
      echo "${title}"
      echo "Source: ${source} (DFW-curated, auto-included)"
      echo "${url}"
      echo ""
    } >> "$DIGEST_FILE"
    mark_seen "$jid" "$title" "$source"
    KEPT=$((KEPT + 1))
  done < "$TRUSTED_FILE"
  log "  Trusted auto-included: $KEPT (after dedup)"

  # Then: LLM-filtered untrusted/broad sources
  while IFS= read -r score_line; do
    [ -z "$score_line" ] && continue
    idx=$(echo "$score_line" | jq -r '.idx // 0' 2>/dev/null)
    score=$(echo "$score_line" | jq -r '.score // 0' 2>/dev/null)
    reason=$(echo "$score_line" | jq -r '.reason // ""' 2>/dev/null)
    [ "$score" -lt 3 ] 2>/dev/null && continue

    # Get the original job data from UNTRUSTED_FILE (LLM only saw untrusted jobs)
    JOB_LINE=$(sed -n "${idx}p" "$UNTRUSTED_FILE")
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
    echo "_${TOTAL} postings scanned, ${KEPT} relevant (${TRUSTED_COUNT} trusted-DFW + LLM-filtered)_"
  } >> "$DIGEST_FILE"

  log "Filter result: $TOTAL → $KEPT jobs kept"
  rm -f "$TRUSTED_FILE" "$UNTRUSTED_FILE"
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
