#!/usr/bin/env bash
# nathan-jobs.sh — Daily teaching/youth/nonprofit job search for Nathan Tyler
#
# Bridge-jobs toward a teaching career (NCTC degree pathway).
# Targets: ISD paraprofessional/aide/sub, district AV/media tech, after-school
# programs, tutoring centers, youth-serving nonprofits (Boys & Girls Club, YMCA,
# Communities In Schools, Big Brothers Big Sisters), parks-rec youth programming.
#
# Centered on Denton, TX. Sends digest to Brandon (Discord + Gmail).
# Mirrors the structure of ai-agent-jobs.sh: LinkedIn HTML + X/bird, kiro-cli
# scoring, DynamoDB dedupe (60-day TTL), Discord + Gmail delivery.
set -uo pipefail
source ~/.profile

TODAY=$(date +%Y-%m-%d)
DATE_LABEL=$(date '+%A, %B %d %Y')
LOGFILE="/home/ubuntu/logs/nathan-jobs/${TODAY}.log"
JOBS_FILE=$(mktemp)
DIGEST_FILE="/tmp/nathan-jobs-digest-${TODAY}.md"
PROFILE="personal"
REGION="us-east-1"
DYNAMO_TABLE="nathan-jobs-seen"
TTL_DAYS=60
EXPIRES_AT=$(date -d "+${TTL_DAYS} days" +%s)
DISCORD_CHANNEL="1503414103341797406"  # #openclaw-ec2

mkdir -p "$(dirname "$LOGFILE")"
log()     { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOGFILE"; }
log_err() { echo "[$(date '+%H:%M:%S')] ERROR: $*" | tee -a "$LOGFILE" >&2; }
trap 'rm -f "$JOBS_FILE"' EXIT

# --- DynamoDB dedup ---
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

log "=== Nathan's Job Search — $DATE_LABEL ==="

# --- LinkedIn (primary) ---
# Seven tuned searches covering: ISD aides/subs, AV/media at schools, after-school
# / youth nonprofit, tutoring centers, district education paraprofessionals,
# foster care, and film/media teaching (Nathan's expertise + teaching path).
log "Searching LinkedIn..."
LI_SEARCHES=(
  # 1. Direct teacher-pipeline jobs near Denton
  "https://www.linkedin.com/jobs/search?keywords=paraprofessional+OR+%22instructional+aide%22+OR+%22teaching+assistant%22+OR+%22substitute+teacher%22&location=Denton%2C+Texas&f_TPR=r604800&distance=25&position=1&pageNum=0"
  # 2. After-school / youth program staff (DFW radius)
  "https://www.linkedin.com/jobs/search?keywords=%22after+school%22+OR+%22youth+program%22+OR+%22youth+development%22+OR+%22youth+coordinator%22&location=Dallas-Fort+Worth+Metroplex&f_TPR=r604800&position=1&pageNum=0"
  # 3. Big-name youth nonprofits
  "https://www.linkedin.com/jobs/search?keywords=%22Boys+%26+Girls+Club%22+OR+%22Boys+Girls+Club%22+OR+%22Communities+In+Schools%22+OR+%22Big+Brothers+Big+Sisters%22+OR+%22YMCA%22&location=Dallas-Fort+Worth+Metroplex&f_TPR=r604800&position=1&pageNum=0"
  # 4. AV / video / media specialist (uses film background) — schools or nonprofits
  "https://www.linkedin.com/jobs/search?keywords=%22AV+technician%22+OR+%22media+specialist%22+OR+%22video+producer%22+OR+%22video+production%22+%28school+OR+ISD+OR+nonprofit+OR+education%29&location=Dallas-Fort+Worth+Metroplex&f_TPR=r604800&position=1&pageNum=0"
  # 5. Tutoring / educational support centers
  "https://www.linkedin.com/jobs/search?keywords=tutor+OR+%22tutoring%22+OR+%22Sylvan%22+OR+%22Mathnasium%22+OR+%22Kumon%22+OR+%22Varsity+Tutors%22&location=Denton%2C+Texas&f_TPR=r604800&distance=25&position=1&pageNum=0"
  # 6. Foster care / foster youth / CASA / child welfare
  "https://www.linkedin.com/jobs/search?keywords=%22foster+care%22+OR+%22foster+youth%22+OR+%22CASA%22+OR+%22child+welfare%22+OR+%22residential+childcare%22+OR+%22Buckner%22+OR+%22ACH+Child%22+OR+%22Pathways+Youth%22&location=Dallas-Fort+Worth+Metroplex&f_TPR=r604800&position=1&pageNum=0"
  # 7. Film/media TEACHING (NEW — combines his expertise with his teaching path)
  "https://www.linkedin.com/jobs/search?keywords=%22film+teacher%22+OR+%22video+production+teacher%22+OR+%22digital+media+teacher%22+OR+%22media+arts+teacher%22+OR+%22broadcast+journalism+teacher%22+OR+%22film+instructor%22+OR+%22audio+video+production%22+OR+%22cinema+teacher%22&location=Dallas-Fort+Worth+Metroplex&f_TPR=r604800&position=1&pageNum=0"
)

for url in "${LI_SEARCHES[@]}"; do
  curl -sL "$url" \
    -H "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36" \
    -H "Accept: text/html" 2>/dev/null | python3 -c "
import sys, re, hashlib
html = sys.stdin.read()
titles    = re.findall(r'base-search-card__title[^>]*>\s*([^<]+)', html)
companies = re.findall(r'base-search-card__subtitle[^>]*>\s*([^<]+)', html)
locations = re.findall(r'job-search-card__location[^>]*>\s*([^<]+)', html)
links     = re.findall(r'href=\"(https://www.linkedin.com/jobs/view/[^\"?]+)', html)
for i in range(min(len(titles), 15)):
    t = titles[i].strip() if i < len(titles) else ''
    c = companies[i].strip() if i < len(companies) else '-'
    l = locations[i].strip() if i < len(locations) else ''
    link = links[i] if i < len(links) else ''
    if not c: c = '-'
    if not t: continue
    m = re.search(r'/jobs/view/(\d+)', link)
    jid = 'li-' + m.group(1) if m else 'li-' + hashlib.md5((t + c).encode()).hexdigest()[:10]
    print(f'{jid}\tlinkedin\t{c}\t{t} [{l}]\t{link}')
" >> "$JOBS_FILE" 2>/dev/null
  sleep 1
done

LI_COUNT=$(grep -c "linkedin" "$JOBS_FILE" 2>/dev/null || echo 0)
log "  LinkedIn: $LI_COUNT results"

# --- X/Twitter (secondary) ---
log "Searching X/Twitter..."
TW_RESULTS=$(bird search '("paraprofessional" OR "teacher aide" OR "instructional aide" OR "after school" OR "youth coordinator" OR "Boys Girls Club" OR "Communities In Schools" OR "foster care" OR "foster youth" OR "CASA" OR "Buckner" OR "ACH Child") (hiring OR "we'\''re hiring" OR "now hiring" OR "join our team") (Denton OR DFW OR "North Texas" OR Lewisville OR Frisco OR "Flower Mound") -is:retweet' -n 10 --json 2>/dev/null || echo "[]")
echo "$TW_RESULTS" | jq -r '.[] | "\(.id)\ttwitter\t\(.author.username)\t\(.text | gsub("\n";" ") | .[0:200])\thttps://x.com/\(.author.username)/status/\(.id)"' >> "$JOBS_FILE" 2>/dev/null

TW_COUNT=$(grep -c "twitter" "$JOBS_FILE" 2>/dev/null || echo 0)
log "  X/Twitter: $TW_COUNT results"

# --- Total ---
TOTAL=$(wc -l < "$JOBS_FILE" 2>/dev/null || echo 0)
log "Total raw results: $TOTAL"

if [ "$TOTAL" -eq 0 ]; then
  log "No jobs found"
  exit 0
fi

# --- LLM Filter via kiro-cli ---
log "Filtering via kiro-cli..."

JOB_LIST=""
i=1
while IFS=$'\t' read -r jid source poster title url; do
  [ -z "$jid" ] && continue
  [ "$i" -gt 50 ] && break
  clean_title=$(echo "$title" | tr -d '"\\`$' | cut -c1-160)
  company=""
  [ "$poster" != "-" ] && [ -n "$poster" ] && company=" @ ${poster}"
  JOB_LIST="${JOB_LIST}- [${i}] ${clean_title}${company}
"
  i=$((i + 1))
done < "$JOBS_FILE"

PROMPT="Filter jobs for NATHAN TYLER (Brandon Tyler's son).

NATHAN'S BACKGROUND:
- Long-term goal: become a TEACHER. Planning to enroll at NCTC (North Central
  Texas College) for a teaching degree.
- Current background: FILM PRODUCTION (worked in film/video for years).
- AGE/GRADE PREFERENCE: wants to work with MIDDLE SCHOOL or HIGH SCHOOL
  students (roughly grades 6-12). Open to upper elementary (4th-5th) but NOT
  early childhood. EXPLICITLY AVOID: daycare, preschool, pre-K, infant/toddler
  care, K-2 only roles. The teaching path he wants is older kids.
- Looking for a transitional/bridge job that builds toward teaching certification,
  ideally at a school district (paraprofessional, instructional aide, sub, AV/media
  tech) at a MIDDLE or HIGH SCHOOL, OR at a youth-serving nonprofit (Boys & Girls
  Club, YMCA, Communities In Schools, Big Brothers Big Sisters, after-school
  programs that serve teens).
- Open to roles that leverage his film/video background (district media specialist,
  school video production, nonprofit communications/comms-coordinator).
- *** BULLSEYE: TEACHING FILM/MEDIA at secondary level *** — film teacher, video
  production teacher, digital media teacher, media arts teacher, broadcast
  journalism teacher, audio-video production (AV/TV) teacher. This combines
  his teaching career path with his film expertise. ALWAYS score these 5.
- *** EXPLICITLY DECLINED: SPECIAL EDUCATION-only roles. *** Nathan has said
  he does not want SPED aide / SPED paraprofessional / behavior tech / autism
  aide positions. Filter these to score 1, regardless of grade level.
- Location: Denton, TX. MUST be commutable from Denton (~25 mi radius). NO
  RELOCATION. Acceptable cities: Denton, Krum, Sanger, Aubrey, Pilot Point,
  Argyle, Lewisville, Flower Mound, Highland Village, Lake Dallas, Little Elm,
  Frisco, The Colony, Northwest ISD, Justin, Roanoke, Trophy Club. AVOID: Dallas
  proper, Fort Worth proper (unless explicitly remote-friendly).
- He does NOT yet have a teaching certificate, so anything requiring one is wrong.

Score 1-5:
5 = Direct teacher-path role at MIDDLE or HIGH SCHOOL: ISD paraprofessional,
    instructional aide, substitute teacher, long-term sub, district AV/media
    specialist serving secondary grades; OR strong youth-serving nonprofit role
    near Denton (Boys & Girls Club, YMCA, Communities In Schools, BBBS) where
    he gets meaningful contact with teens / older kids; OR foster-care / foster-
    youth / CASA / child-welfare role at a child-placing or family-services
    agency (Buckner, ACH Child & Family Services, Pathways Youth & Family,
    Methodist Children's Home, CASA of Denton County, 4Kids of North Texas) —
    Nathan has explicit interest in working with foster youth.
    *** ALSO SCORE 5: FILM / MEDIA / VIDEO PRODUCTION TEACHING at middle or
    high school — film teacher, video production teacher, digital media
    teacher, media arts teacher, broadcast journalism teacher, audio-video
    production (AV/TV) teacher, cinema/film instructor. This is the BULLSEYE:
    combines his teaching career path with his film expertise. Even
    'sponsor' or 'advisor' roles for school film/media clubs at secondary
    level qualify. ***
4 = Adjacent secondary-grade roles: tutoring center for middle/high school
    (Sylvan/Mathnasium/Varsity Tutors targeting older students), private school
    aide (middle/high), after-school program staff for teens, library aide at
    a middle/high school, nonprofit communications role using his film background.
    Also: K-12 instructional aide where the grade isn't specified (default to 4
    since most ISD aide roles cover multiple grades). Foster-adjacent roles
    (residential childcare, transitional living, juvenile-justice mentoring)
    that aren't strictly foster-care orgs but serve the same population.
3 = General nonprofit/education role he could grow into, parks-rec youth
    programming serving teens, edtech support, museum/library education,
    school district admin that exposes him to secondary teachers daily.
    Elementary-only aide roles default here (acceptable but not preferred).
2 = Adjacent but weak: school district admin/clerical, customer service at a
    nonprofit, retail with 'youth team' wording, college-level (not K-12) roles
    even at education orgs (e.g., university career-services coordinator).
    Location borderline (20-25mi).
1 = Wrong field. Specifically includes:
    *** SPECIAL EDUCATION-only roles (SPED aide, SPED paraprofessional, SPED
    instructional aide, behavior tech for SPED, autism aide) — Nathan is
    explicitly NOT pursuing SPED and has declined SPED-specific positions.
    Filter these out regardless of grade level or location. ***
    DAYCARE, preschool, pre-K, infant/toddler care, child-development centers
    serving under-5 (e.g. KinderCare, Bright Horizons, Goddard, Primrose,
    Children's Lighthouse, Child Development Schools, Learning Experience).
    Also: anything requiring a teaching cert he
    doesn't have, requires relocation, far outside the 25mi commute radius, or
    unrelated to youth/education.

Output ONLY JSON lines: {\"idx\":<N>,\"score\":<1-5>,\"reason\":\"<brief why this fits Nathan>\",\"pay\":\"<estimated range, hourly or annual>\"}

${JOB_LIST}"

RAW=$(cd "$HOME" && timeout 90 kiro-cli chat --no-interactive --wrap never "$PROMPT" 2>&1)
SCORES=$(echo "$RAW" | sed 's/\x1b\[[0-9;]*m//g' | grep -oP '\{[^}]+\}')

# --- Build digest ---
{
  echo "# 📚 Nathan's Job Search — $DATE_LABEL"
  echo ""
  echo "_Bridge jobs toward teaching career — North Texas, ~25mi from Denton_"
  echo ""
} > "$DIGEST_FILE"

KEPT=0
NEW_JOBS_TSV=$(mktemp)
while IFS= read -r score_line; do
  [ -z "$score_line" ] && continue
  idx=$(echo "$score_line"   | jq -r '.idx    // 0'  2>/dev/null)
  score=$(echo "$score_line" | jq -r '.score  // 0'  2>/dev/null)
  reason=$(echo "$score_line" | jq -r '.reason // ""' 2>/dev/null)
  pay=$(echo "$score_line"   | jq -r '.pay    // ""' 2>/dev/null)
  [ "$score" -lt 3 ] 2>/dev/null && continue

  JOB_LINE=$(sed -n "${idx}p" "$JOBS_FILE")
  [ -z "$JOB_LINE" ] && continue
  IFS=$'\t' read -r jid source poster title url <<< "$JOB_LINE"
  if is_seen "$jid"; then continue; fi

  {
    echo "${title}"
    [ -n "$pay" ] && [ "$pay" != "null" ] && echo "  💰 Est: ${pay}"
    echo "Source: ${source} | Score: ${score}/5 | ${reason}"
    echo "${url}"
    echo ""
  } >> "$DIGEST_FILE"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$jid" "$score" "$pay" "$reason" "$source" "$title" "$url" >> "$NEW_JOBS_TSV"
  mark_seen "$jid" "$title" "$source"
  KEPT=$((KEPT + 1))
done <<< "$SCORES"

{
  echo "---"
  echo "_${TOTAL} postings scanned, ${KEPT} relevant (score ≥ 3/5)_"
} >> "$DIGEST_FILE"

log "Filter result: $TOTAL → $KEPT jobs kept"

# --- Deliver ---
if [ "$KEPT" -gt 0 ]; then
  DISCORD_TOKEN=$(jq -r '.channels.discord.token // empty' ~/.openclaw/openclaw.json 2>/dev/null)
  if [ -n "$DISCORD_TOKEN" ] && [ -s "$NEW_JOBS_TSV" ]; then
    send_discord() {
      curl -s -X POST "https://discord.com/api/v10/channels/${DISCORD_CHANNEL}/messages" \
        -H "Authorization: Bot $DISCORD_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$(jq -nc --arg c "$1" '{content:$c}')" > /dev/null
    }
    chunk="📚 **${KEPT} new job(s) for Nathan — North TX** — ${DATE_LABEL}"
    while IFS=$'\t' read -r jid score pay reason source title url; do
      short_title="${title:0:200}"
      job_block=$'\n\n'"• **${short_title}** _(score ${score}/5)_"
      [ -n "$pay" ] && [ "$pay" != "null" ] && job_block="${job_block}"$'\n'"  💰 ${pay}"
      [ -n "$reason" ] && job_block="${job_block}"$'\n'"  _${reason}_"
      job_block="${job_block}"$'\n'"  <${url}>"
      candidate="${chunk}${job_block}"
      if [ ${#candidate} -gt 1800 ]; then
        send_discord "$chunk"
        chunk="${job_block#$'\n\n'}"
      else
        chunk="$candidate"
      fi
    done < "$NEW_JOBS_TSV"
    [ -n "$chunk" ] && send_discord "$chunk"
    log "Discord: sent ($KEPT jobs)"
  fi

  if gog gmail send -a brandon.tyler@gmail.com \
       --to "brandon.tyler@gmail.com" \
       --subject "📚 Nathan's Jobs — ${KEPT} found ($DATE_LABEL)" \
       --body "$(cat "$DIGEST_FILE")" > /dev/null 2>&1; then
    log "Email sent via gog"
  else
    log_err "Email send failed"
  fi
fi

rm -f "$NEW_JOBS_TSV"
log "Done. Log: $LOGFILE"
