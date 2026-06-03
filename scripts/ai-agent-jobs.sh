#!/usr/bin/env bash
# ai-agent-jobs.sh — Daily search for AI agent consultant/setup jobs
# For Brandon: OpenClaw, Hermes, personal AI assistant setup roles
set -uo pipefail
source ~/.profile

TODAY=$(date +%Y-%m-%d)
LOGFILE="/home/ubuntu/logs/ai-agent-jobs/$(date +%Y-%m-%d).log"
JOBS_FILE=$(mktemp)
DIGEST_FILE="/tmp/ai-agent-jobs-digest-${TODAY}.md"
PROFILE="personal"
REGION="us-east-1"
DYNAMO_TABLE="ai-agent-jobs-seen"
TTL_DAYS=60
EXPIRES_AT=$(date -d "+${TTL_DAYS} days" +%s)

mkdir -p "$(dirname "$LOGFILE")"
log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOGFILE"; }

# --- DynamoDB dedup ---
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
  local clean_title=$(echo "$2" | tr -d '"' | cut -c1-200)
  aws dynamodb put-item --table-name "$DYNAMO_TABLE" \
    --item "{\"job_id\":{\"S\":\"$1\"},\"title\":{\"S\":\"$clean_title\"},\"source\":{\"S\":\"$3\"},\"found_date\":{\"S\":\"$TODAY\"},\"expires_at\":{\"N\":\"$EXPIRES_AT\"}}" \
    --profile "$PROFILE" --region "$REGION" > /dev/null 2>&1
}

log "=== AI Agent Jobs Search — $TODAY ==="

# --- LinkedIn searches ---
log "Searching LinkedIn..."

SEARCHES=(
  # AI agent setup/consultant roles (remote)
  "https://www.linkedin.com/jobs/search?keywords=%22AI+agent%22+OR+%22OpenClaw%22+OR+%22personal+AI+assistant%22+OR+%22agent+architect%22+OR+%22AI+automation%22+%28consultant+OR+setup+OR+deploy+OR+configure+OR+freelance%29&f_TPR=r604800&f_WT=2&position=1&pageNum=0"
  # AI/LLM engineer roles (remote only)
  "https://www.linkedin.com/jobs/search?keywords=%22AI+agent%22+OR+%22LLM+engineer%22+OR+%22AI+architect%22+OR+%22prompt+engineer%22+%28Claude+OR+Anthropic+OR+Bedrock+OR+OpenAI%29&location=United+States&f_TPR=r604800&f_WT=2&position=1&pageNum=0"
  # OpenClaw/Hermes specific (remote)
  "https://www.linkedin.com/jobs/search?keywords=%22OpenClaw%22+OR+%22Hermes+Agent%22+OR+%22AI+assistant+setup%22+OR+%22agent+deployment%22&f_TPR=r604800&f_WT=2&position=1&pageNum=0"
  # Contact center AI / voice bot / telecom + AI (remote)
  "https://www.linkedin.com/jobs/search?keywords=%22contact+center+AI%22+OR+%22voice+bot%22+OR+%22conversational+AI%22+OR+%22Amazon+Connect%22+%28architect+OR+engineer+OR+consultant+OR+lead%29&location=United+States&f_TPR=r604800&f_WT=2&position=1&pageNum=0"
  # DFW local AI/automation roles
  "https://www.linkedin.com/jobs/search?keywords=%22AI+agent%22+OR+%22AI+automation%22+OR+%22AI+architect%22+OR+%22machine+learning%22+OR+%22generative+AI%22&location=Dallas-Fort+Worth+Metroplex&f_TPR=r604800&position=1&pageNum=0"
)

for url in "${SEARCHES[@]}"; do
  curl -sL "$url" \
    -H "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36" \
    -H "Accept: text/html" 2>/dev/null | python3 -c "
import sys, re, hashlib
html = sys.stdin.read()
titles = re.findall(r'base-search-card__title[^>]*>\s*([^<]+)', html)
companies = re.findall(r'base-search-card__subtitle[^>]*>\s*([^<]+)', html)
locations = re.findall(r'job-search-card__location[^>]*>\s*([^<]+)', html)
links = re.findall(r'href=\"(https://www.linkedin.com/jobs/view/[^\"?]+)', html)
for i in range(min(len(titles), 15)):
    t = titles[i].strip() if i < len(titles) else ''
    c = companies[i].strip() if i < len(companies) else '-'
    l = locations[i].strip() if i < len(locations) else ''
    link = links[i] if i < len(links) else ''
    if not c: c = '-'
    if not t: continue
    # Stable id from LinkedIn job URL (last numeric segment), fallback to title+company hash
    m = re.search(r'/jobs/view/(\d+)', link)
    if m:
        jid = 'li-' + m.group(1)
    else:
        jid = 'li-' + hashlib.md5((t + c).encode()).hexdigest()[:10]
    print(f'{jid}\tlinkedin\t{c}\t{t} [{l}]\t{link}')
" >> "$JOBS_FILE" 2>/dev/null
done

LI_COUNT=$(grep -c "linkedin" "$JOBS_FILE" 2>/dev/null || echo 0)
log "  LinkedIn: found $LI_COUNT results"

# --- Upwork ---
log "Searching Upwork..."
curl -sL "https://www.upwork.com/nx/search/jobs/?q=OpenClaw%20OR%20%22AI%20agent%22%20setup%20OR%20%22personal%20AI%20assistant%22&sort=recency" \
  -H "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36" 2>/dev/null | python3 -c "
import sys, re, hashlib
html = sys.stdin.read()
titles = re.findall(r'class=\"job-tile-title\"[^>]*>.*?<a[^>]*>([^<]+)', html, re.S)
if not titles:
    titles = re.findall(r'\"title\":\"([^\"]+)\"', html)
for i, t in enumerate(titles[:10]):
    title = t.strip()
    if not title: continue
    # Stable id from title hash so the same posting isn't re-shown across days
    jid = 'uw-' + hashlib.md5(title.encode()).hexdigest()[:10]
    print(f'{jid}\tupwork\t-\t{title}\thttps://www.upwork.com/nx/search/jobs/?q=OpenClaw+AI+agent')
" >> "$JOBS_FILE" 2>/dev/null

UW_COUNT=$(grep -c "upwork" "$JOBS_FILE" 2>/dev/null || echo 0)
log "  Upwork: found $UW_COUNT results"

# --- X/Twitter ---
log "Searching X for AI agent gigs..."
TWITTER_RESULTS=$(bird search '"AI agent" OR "OpenClaw" OR "Hermes Agent" (hiring OR consultant OR freelance OR "looking for" OR contract) -is:retweet' -n 10 --json 2>/dev/null || echo "[]")
echo "$TWITTER_RESULTS" | jq -r '.[] | "\(.id)\ttwitter\t\(.author.username)\t\(.text | gsub("\n";" ") | .[0:200])\thttps://x.com/\(.author.username)/status/\(.id)"' >> "$JOBS_FILE" 2>/dev/null

TW_COUNT=$(grep -c "twitter" "$JOBS_FILE" 2>/dev/null || echo 0)
log "  X/Twitter: found $TW_COUNT results"

# --- Total ---
TOTAL=$(wc -l < "$JOBS_FILE" 2>/dev/null || echo 0)
log "Total raw results: $TOTAL"

if [ "$TOTAL" -eq 0 ]; then
  log "No AI agent jobs found today"
  rm -f "$JOBS_FILE"
  exit 0
fi

# --- LLM Filter ---
log "Filtering via kiro-cli..."

JOB_LIST=""
i=1
while IFS=$'\t' read -r jid source poster title url; do
  [ -z "$jid" ] && continue
  [ "$i" -gt 25 ] && break
  clean_title=$(echo "$title" | tr -d '"\\`$' | cut -c1-150)
  company=""
  [ "$poster" != "-" ] && [ -n "$poster" ] && company=" @ ${poster}"
  JOB_LIST="${JOB_LIST}- [${i}] ${clean_title}${company}
"
  i=$((i + 1))
done < "$JOBS_FILE"

PROMPT="Filter jobs for Brandon Tyler. Match against his FULL background:

CURRENT: AWS Solutions Architect — Amazon Connect specialist, telecom/contact center engineering
AI SKILLS: Builds production AI agent systems daily — OpenClaw, Hermes Agent, kiro-cli headless, Claude/Bedrock
WHAT HE BUILT: 12+ automated LLM-powered jobs (job search, email triage, X digest, finance automation, calendar mgmt), multi-agent Discord routing, MCP integrations, voice agent architecture (Dograh+Connect), systemd services on EC2
CERTS: Claude Certified Architect (in progress), AWS experience
TELECOM: Amazon Connect, contact flows, IVR, voice bots, SIP, telephony integration
WANTS: Help people/companies set up AI agents as executive assistants, personal automation, or contact center AI. Consulting, freelance, or full-time.
LOCATION: Denton, TX. MUST be REMOTE or DFW/North Texas. Will NOT relocate.

Score 1-5:
5 = Perfect fit: remote AI agent consulting/setup/deployment, or remote AI+telecom/contact center role
4 = Strong fit: remote AI architect, LLM engineer, or automation role matching his skills
3 = Good fit: remote AI/ML role or DFW-local tech role he could do
2 = Unclear if remote or weak match
1 = Requires relocation, irrelevant, or not matching his skills. NO EXCEPTIONS for on-site NYC/LA/SF.

Also estimate salary range based on title, company, and seniority.
Output ONLY JSON lines: {\"idx\":<N>,\"score\":<1-5>,\"reason\":\"<brief>\",\"pay\":\"<estimated range like 150-200K or 75-100/hr>\"}

${JOB_LIST}"

RAW=$(cd "$HOME" && timeout 60 kiro-cli chat --no-interactive --wrap never "$PROMPT" 2>&1)
SCORES=$(echo "$RAW" | sed 's/\x1b\[[0-9;]*m//g' | grep -oP '\{[^}]+\}')

# --- Build digest ---
{
  echo "# 🤖 AI Agent Jobs — $TODAY"
  echo ""
  echo "_AI agent consultant, setup, and architect opportunities_"
  echo ""
} > "$DIGEST_FILE"

KEPT=0
while IFS= read -r score_line; do
  [ -z "$score_line" ] && continue
  idx=$(echo "$score_line" | jq -r '.idx // 0' 2>/dev/null)
  score=$(echo "$score_line" | jq -r '.score // 0' 2>/dev/null)
  reason=$(echo "$score_line" | jq -r '.reason // ""' 2>/dev/null)
  pay=$(echo "$score_line" | jq -r '.pay // ""' 2>/dev/null)
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
  DISCORD_CHANNEL="1503414103341797406"
  DISCORD_TOKEN=$(jq -r '.channels.discord.token // empty' ~/.openclaw/openclaw.json 2>/dev/null)
  if [ -n "$DISCORD_TOKEN" ]; then
    curl -s -X POST "https://discord.com/api/v10/channels/$DISCORD_CHANNEL/messages" \
      -H "Authorization: Bot $DISCORD_TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"content\":$(cat "$DIGEST_FILE" | jq -Rs .)}" > /dev/null
    log "Discord: sent"
  fi

  gog gmail send -a brandon.tyler@gmail.com \
    --to "brandon.tyler@gmail.com" \
    --subject "🤖 AI Agent Jobs — ${KEPT} found ($TODAY)" \
    --body "$(cat "$DIGEST_FILE")" 2>/dev/null && log "Email sent" || log "Email failed"
fi

rm -f "$JOBS_FILE"
log "Done."
