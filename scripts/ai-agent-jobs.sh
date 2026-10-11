#!/usr/bin/env bash
# ai-agent-jobs.sh — Daily search for remote roles comparable to Brandon's AWS delivery work
# Ground truth: Delivery Consultant — Connect and Lex, Amazon Connect Center of Delivery Excellence
# Sources: LinkedIn, Upwork, public remote-board feeds, Wellfound, X/bird, and Reddit Atom hiring leads
set -uo pipefail
source ~/.profile
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TODAY=$(date +%Y-%m-%d)
LOGFILE="/home/ubuntu/logs/ai-agent-jobs/$(date +%Y-%m-%d).log"
JOBS_FILE=$(mktemp)
DIGEST_FILE="/tmp/ai-agent-jobs-digest-${TODAY}.md"
PROFILE="personal"
REGION="us-east-1"
DYNAMO_TABLE="ai-agent-jobs-seen"
TTL_DAYS=60
EXPIRES_AT=$(date -d "+${TTL_DAYS} days" +%s)
DRY_RUN="${AI_AGENT_JOBS_DRY_RUN:-0}"
[[ "$DRY_RUN" =~ ^[01]$ ]] || { echo "AI_AGENT_JOBS_DRY_RUN must be 0 or 1" >&2; exit 2; }

mkdir -p "$(dirname "$LOGFILE")"
log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOGFILE"; }

# --- DynamoDB dedup ---
DYNAMO_OK=0
if [ "$DRY_RUN" -eq 0 ] && aws dynamodb describe-table --table-name "$DYNAMO_TABLE" --profile "$PROFILE" --region "$REGION" > /dev/null 2>&1; then
  DYNAMO_OK=1
elif [ "$DRY_RUN" -eq 0 ]; then
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
  local clean_title item
  clean_title=$(echo "$2" | cut -c1-200)
  item=$(jq -nc \
    --arg job_id "$1" --arg title "$clean_title" --arg source "$3" \
    --arg found_date "$TODAY" --argjson expires_at "$EXPIRES_AT" \
    '{job_id:{S:$job_id},title:{S:$title},source:{S:$source},found_date:{S:$found_date},expires_at:{N:($expires_at|tostring)}}')
  aws dynamodb put-item --table-name "$DYNAMO_TABLE" \
    --item "$item" \
    --profile "$PROFILE" --region "$REGION" > /dev/null 2>&1
}

log "=== AI Agent Jobs Search — $TODAY ==="

# --- LinkedIn searches ---
log "Searching LinkedIn..."

SEARCHES=(
  # Exact lane: Amazon Connect / CCaaS customer delivery and architecture
  "remote|https://www.linkedin.com/jobs/search?keywords=%28%22Amazon+Connect%22+OR+%22contact+center%22+OR+CCaaS%29+%28%22delivery+consultant%22+OR+%22professional+services%22+OR+%22solutions+architect%22+OR+architect%29&location=United+States&f_TPR=r604800&f_WT=2&position=1&pageNum=0"
  # Conversational and voice AI architecture / implementation
  "remote|https://www.linkedin.com/jobs/search?keywords=%28%22conversational+AI%22+OR+%22voice+AI%22+OR+%22voice+bot%22+OR+NLP+OR+NLU+OR+Lex%29+%28architect+OR+%22principal+consultant%22+OR+%22delivery+consultant%22+OR+%22customer+engineer%22%29&location=United+States&f_TPR=r604800&f_WT=2&position=1&pageNum=0"
  # Agentic / generative AI customer delivery: adjacent upward lane
  "remote|https://www.linkedin.com/jobs/search?keywords=%28%22agentic+AI%22+OR+%22generative+AI%22+OR+LLM+OR+Bedrock+OR+AgentCore%29+%28%22solutions+architect%22+OR+%22customer+engineer%22+OR+%22forward+deployed%22+OR+%22professional+services%22+OR+%22delivery+consultant%22%29&location=United+States&f_TPR=r604800&f_WT=2&position=1&pageNum=0"
  # Senior hands-on AI/agent engineering remains a strong transferable lane
  "remote|https://www.linkedin.com/jobs/search?keywords=%28%22AI+agent%22+OR+%22LLM+engineer%22+OR+%22applied+AI%22+OR+%22AI+architect%22%29+%28senior+OR+staff+OR+principal+OR+lead%29&location=United+States&f_TPR=r604800&f_WT=2&position=1&pageNum=0"
  # Adjacent enterprise contact-center platforms
  "remote|https://www.linkedin.com/jobs/search?keywords=%28Genesys+OR+%22NICE+CXone%22+OR+Five9+OR+Cisco+OR+Avaya+OR+Salesforce%29+%28%22contact+center+architect%22+OR+%22conversational+AI+architect%22+OR+%22principal+consultant%22%29&location=United+States&f_TPR=r604800&f_WT=2&position=1&pageNum=0"
  # Exact Denton local exception; elsewhere must be fully remote
  "denton|https://www.linkedin.com/jobs/search?keywords=%28%22Amazon+Connect%22+OR+%22contact+center%22+OR+%22conversational+AI%22+OR+%22agentic+AI%22+OR+%22solutions+architect%22+OR+%22AI+architect%22%29&location=Denton%2C+Texas%2C+United+States&f_TPR=r604800&position=1&pageNum=0"
)

for search in "${SEARCHES[@]}"; do
  IFS='|' read -r search_scope url <<< "$search"
  curl -sL "$url" \
    -H "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36" \
    -H "Accept: text/html" 2>/dev/null | python3 -c "
import sys, re, hashlib
html = sys.stdin.read()
titles = re.findall(r'base-search-card__title[^>]*>\s*([^<]+)', html)
companies = re.findall(r'base-search-card__subtitle[^>]*>\s*([^<]+)', html)
locations = re.findall(r'job-search-card__location[^>]*>\s*([^<]+)', html)
links = re.findall(r'href=\"(https://www.linkedin.com/jobs/view/[^\"?]+)', html)

# Salary patterns we honor as REAL (not guessed). Only extract from strings.
# Handles: \$180K-\$250K, \$180,000 - \$250,000, \$75/hr, \$75-\$100/hr, 100k-150k, etc.
SALARY_RE = re.compile(
    r'(\\\$?\d{2,3}[Kk](?:[,.]?\d{3})?(?:\s*[-–]\s*\\\$?\d{2,3}[Kk]?)?'
    r'(?:\s*/\s*(?:hr|hour|yr|year))?'
    r'|\\\$\d{2,3}(?:,\d{3})*(?:\s*[-–]\s*\\\$?\d{2,3}(?:,\d{3})*)?(?:\s*/\s*(?:hr|hour|yr|year))?'
    r'|\\\$\d{2,3}(?:\s*[-–]\s*\\\$?\d{2,3})?\s*/\s*(?:hr|hour))'
)

def extract_salary(s: str) -> str:
    m = SALARY_RE.search(s or '')
    return m.group(0).strip() if m else ''

for i in range(min(len(titles), 15)):
    t = titles[i].strip() if i < len(titles) else ''
    c = companies[i].strip() if i < len(companies) else '-'
    l = locations[i].strip() if i < len(locations) else ''
    link = links[i] if i < len(links) else ''
    if not c: c = '-'
    if not t: continue
    # Extract salary from title only if literally present (never guess).
    salary = extract_salary(t)
    # Stable id from LinkedIn job URL (last numeric segment), fallback to title+company hash
    m = re.search(r'/jobs/view/(\d+)', link)
    if m:
        jid = 'li-' + m.group(1)
    else:
        jid = 'li-' + hashlib.md5((t + c).encode()).hexdigest()[:10]
    # TSV columns: jid, source, poster, title[loc], url, salary
    print(f'{jid}\tlinkedin-{sys.argv[1]}\t{c}\t{t} [{l}]\t{link}\t{salary}')
" "$search_scope" >> "$JOBS_FILE" 2>/dev/null
done

LI_COUNT=$(grep -c "linkedin" "$JOBS_FILE" 2>/dev/null || echo 0)
log "  LinkedIn: found $LI_COUNT results"

# --- Upwork ---
log "Searching Upwork..."
curl -sL "https://www.upwork.com/nx/search/jobs/?q=%22Amazon%20Connect%22%20OR%20%22conversational%20AI%22%20OR%20%22voice%20bot%22%20OR%20%22AI%20agent%22%20%28architect%20OR%20consultant%20OR%20implementation%29&sort=recency" \
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
    # 6 TSV columns to match linkedin shape (salary col empty — Upwork search HTML doesn't expose it here)
    print(f'{jid}\tupwork\t-\t{title}\thttps://www.upwork.com/nx/search/jobs/?q=Amazon+Connect+conversational+AI+voice+agent\t')
" >> "$JOBS_FILE" 2>/dev/null

UW_COUNT=$(grep -c "upwork" "$JOBS_FILE" 2>/dev/null || echo 0)
log "  Upwork: found $UW_COUNT results"

# --- X/Twitter ---
log "Searching X for AI agent gigs..."
TWITTER_RESULTS=$(bird search '("Amazon Connect" OR "contact center AI" OR "conversational AI" OR "agentic AI") (hiring OR "delivery consultant" OR architect OR "professional services") (remote OR "US remote") -is:retweet' -n 10 --json 2>/dev/null || echo "[]")
echo "$TWITTER_RESULTS" | jq -r '.[] | "\(.id)\ttwitter\t\(.author.username)\t\(.text | gsub("\n";" ") | .[0:200])\thttps://x.com/\(.author.username)/status/\(.id)\t"' >> "$JOBS_FILE" 2>/dev/null

TW_COUNT=$(grep -c "twitter" "$JOBS_FILE" 2>/dev/null || echo 0)
log "  X/Twitter: found $TW_COUNT results"

# --- Reddit (explicit remote or exact Denton hiring-side leads; unverified until checked officially) ---
log "Searching Reddit for AI agent jobs..."
REDDIT_TMP=$(mktemp)
REDDIT_EXIT=0
timeout 45 python3 "$SCRIPT_DIR/reddit-job-leads.py" ai-agent > "$REDDIT_TMP" 2>> "$LOGFILE" || REDDIT_EXIT=$?
if [ "$REDDIT_EXIT" -eq 124 ]; then
  log "  Reddit: timed out — skipping"
elif [ "$REDDIT_EXIT" -ne 0 ]; then
  log "  Reddit: unavailable (exit=$REDDIT_EXIT) — skipping"
fi
while IFS= read -r line; do
  jid=$(echo "$line" | jq -r '.id // empty' 2>/dev/null)
  subreddit=$(echo "$line" | jq -r '.subreddit // empty' 2>/dev/null)
  author=$(echo "$line" | jq -r '.author // empty' 2>/dev/null)
  title=$(echo "$line" | jq -r '.title // empty' 2>/dev/null)
  excerpt=$(echo "$line" | jq -r '.excerpt // empty' 2>/dev/null)
  url=$(echo "$line" | jq -r '.url // empty' 2>/dev/null)
  [ -z "$jid" ] && continue
  [ -z "$title" ] && continue
  [ -z "$url" ] && continue
  poster="r/${subreddit}"
  [ -n "$author" ] && poster="${poster} ${author}"
  lead_title="[UNVERIFIED REDDIT LEAD] ${title}"
  [ -n "$excerpt" ] && lead_title="${lead_title} | ${excerpt:0:300}"
  printf '%s\treddit\t%s\t%s\t%s\t\n' "$jid" "$poster" "$lead_title" "$url" >> "$JOBS_FILE"
done < "$REDDIT_TMP"
rm -f "$REDDIT_TMP"
REDDIT_COUNT=$(awk -F'\t' '$2 == "reddit" { count++ } END { print count + 0 }' "$JOBS_FILE")
log "  Reddit: found $REDDIT_COUNT candidate leads"

# --- Public remote job boards (personal use; attribution preserved in source + canonical URL) ---
log "Searching public remote job boards..."
REMOTE_TMP=$(mktemp)
REMOTE_EXIT=0
timeout 90 python3 "$SCRIPT_DIR/remote-job-boards.py" --limit-per-source 10 \
  > "$REMOTE_TMP" 2>> "$LOGFILE" || REMOTE_EXIT=$?
if [ "$REMOTE_EXIT" -eq 124 ]; then
  log "  Remote boards: timed out — keeping any completed source results"
elif [ "$REMOTE_EXIT" -ne 0 ]; then
  log "  Remote boards: unavailable (exit=$REMOTE_EXIT) — keeping any completed source results"
fi
if [ -s "$REMOTE_TMP" ]; then
  cat "$REMOTE_TMP" >> "$JOBS_FILE"
fi
REMOTE_COUNT=$(wc -l < "$REMOTE_TMP" 2>/dev/null || echo 0)
REMOTE_SUMMARY=""
for remote_source in workingnomads remoteok remotive himalayas weworkremotely wellfound; do
  source_count=$(awk -F'\t' -v source="$remote_source" '$2 == source { count++ } END { print count + 0 }' "$REMOTE_TMP")
  REMOTE_SUMMARY="${REMOTE_SUMMARY} ${remote_source}=${source_count}"
done
log "  Remote boards: found $REMOTE_COUNT (${REMOTE_SUMMARY# })"
rm -f "$REMOTE_TMP"

# Deduplicate overlapping searches before assigning model indices so every source
# (including X, Reddit, and remote boards) remains aligned with the digest lookup.
RAW_TOTAL=$(wc -l < "$JOBS_FILE" 2>/dev/null || echo 0)
awk -F'\t' '!seen[$1]++' "$JOBS_FILE" > "${JOBS_FILE}.dd" && mv "${JOBS_FILE}.dd" "$JOBS_FILE"
DEDUP_TOTAL=$(wc -l < "$JOBS_FILE" 2>/dev/null || echo 0)

# Fail closed on location before the model sees a lead. Remote-board parsers have
# already checked their full descriptions; LinkedIn remote candidates are fetched
# once more and must explicitly say remote with no hybrid/on-site/RTO contradiction.
# Exact Denton city listings are the only local exception.
if ! python3 "$SCRIPT_DIR/job_location_policy.py" --input "$JOBS_FILE" \
    > "${JOBS_FILE}.location" 2>> "$LOGFILE"; then
  log "ERROR: location evidence gate failed; refusing to score or deliver any jobs"
  rm -f "$JOBS_FILE" "${JOBS_FILE}.location"
  exit 1
fi
mv "${JOBS_FILE}.location" "$JOBS_FILE"
LOCATION_TOTAL=$(wc -l < "$JOBS_FILE" 2>/dev/null || echo 0)
log "Location policy: raw=$RAW_TOTAL deduped=$DEDUP_TOTAL accepted=$LOCATION_TOTAL "
log "  Rule: explicit contradiction-free remote usable from Denton, or exact Denton, TX"

# --- Total ---
TOTAL=$(wc -l < "$JOBS_FILE" 2>/dev/null || echo 0)
log "Total location-eligible results: $TOTAL"

if [ "$TOTAL" -eq 0 ]; then
  log "No AI agent jobs found today"
  rm -f "$JOBS_FILE"
  exit 0
fi

# --- LLM Filter ---
log "Filtering via kiro-cli..."

JOB_LIST=""
i=1
while IFS=$'\t' read -r jid source poster title url salary; do
  [ -z "$jid" ] && continue
  [ "$i" -gt 150 ] && break
  title_limit=150
  [ "$source" = "reddit" ] && title_limit=420
  clean_title=$(echo "$title" | tr -d '"\\`$' | cut -c "1-${title_limit}")
  company=""
  [ "$poster" != "-" ] && [ -n "$poster" ] && company=" @ ${poster}"
  JOB_LIST="${JOB_LIST}- [${i}] ${clean_title}${company}
"
  i=$((i + 1))
done < "$JOBS_FILE"
MODEL_COUNT=$((i - 1))
if [ "$MODEL_COUNT" -lt 1 ]; then
  log "ERROR: no indexed jobs were available for scoring"
  rm -f "$JOBS_FILE"
  exit 1
fi

# Agent-trap hardening (bead openclaw-79b): defang scraped job text (LinkedIn + X) before scoring.
# Normalize malformed scraper bytes before the Unicode/injection sanitizer so
# Kiro always receives valid UTF-8, even when an upstream HTML page is malformed.
JOB_LIST=$(printf '%s' "$JOB_LIST" \
  | python3 -c 'import sys; sys.stdout.write(sys.stdin.buffer.read().decode("utf-8", "replace"))' \
  | python3 "$SCRIPT_DIR/sanitize_untrusted.py" --report /tmp/aiagent-sanitize.json 2>/dev/null)
_arisk=$(python3 -c "import json;print(json.load(open('/tmp/aiagent-sanitize.json')).get('risk','low'))" 2>/dev/null || echo low)
[ "$_arisk" != "low" ] && echo "[sanitize] ai-agent-jobs untrusted-text risk=$_arisk" >&2

PROMPT="Filter jobs for Brandon Tyler. Use this confirmed current job as the ground-truth benchmark, not a generic AI-developer profile.

CURRENT JOB — CONFIRMED BY BRANDON:
AWS Delivery Consultant — Connect and Lex, Amazon Connect Center of Delivery Excellence, on the AWS Professional Services team. LinkedIn job 4470215327 is the exact team/role benchmark; its description also uses Senior Delivery Consultant.

CURRENT SCOPE:
- Designs and implements complex, scalable, secure AWS solutions for enterprise customers.
- Owns discovery, requirements, architecture, implementation, troubleshooting, performance, delivery risk, and customer outcomes.
- Acts as a trusted technical advisor; mentors, trains, and creates reusable delivery artifacts.
- Deep Amazon Connect, Lex, contact flows, IVR, voice bots, REST/web-service integration, SIP/telephony, and contact-center engineering experience.
- Builds production agentic-AI systems: OpenClaw, Hermes Agent, Kiro CLI, Claude/Bedrock, multi-agent routing, MCP integrations, evaluations, and automation on AWS.
- Benchmark requirements include 3+ years cloud architecture/implementation, 3+ years contact-center architecture or senior development, enterprise NLP/NLU for IVR/chat, and integrations across major CCaaS platforms. HIPAA/GDPR knowledge is relevant.

TARGET ROLES — COMPARABLE OR UPWARD:
1. Exact lane: Senior/Principal Delivery Consultant, AWS/Azure/GCP Professional Services Consultant, Amazon Connect or CCaaS Architect, Contact Center Architect, Conversational/Voice AI Architect, Principal Consultant.
2. Adjacent customer-delivery lane: Applied AI Solutions Architect, Agentic/Generative AI Solutions Architect, Customer Engineer, Forward Deployed Engineer, Cloud Architect, or implementation-heavy technical consultant.
3. Strong technical lane: senior/staff/principal AI, LLM, agent, automation, or voice engineer when it is production-focused and Brandon's enterprise/AWS background transfers.
4. Adjacent platforms are valid: Genesys Cloud CX, NICE CXone, Five9, Cisco, Avaya, Salesforce, Dialogflow, Rasa, or Azure Bot Service.

ROLE SHAPE:
- Prefer senior individual-contributor or genuinely technical player-coach work.
- Customer-facing is a strength when the job owns architecture and implementation. Do not require every good role to be a pure software-engineering job or to say daily coding.
- Reject down-level roles: junior/associate, support/help-desk, administrator-only, coordinator, prompt-writer-only, or one-off basic chatbot setup.
- Reject pure people management, quota-carrying sales, account executive, customer-success management, recruiting, enablement, product marketing, and demo-only pre-sales. A Solutions Consultant title is not automatically rejected, but it scores 1 if it is sales/demo/adoption work without implementation ownership.
- Deep model-training research or applied-scientist roles that require a PhD/publication record are weak unless the listing clearly values enterprise solution delivery.

LOCATION: Denton, TX. A deterministic prefilter has already admitted only jobs that explicitly confirm contradiction-free remote work usable from Denton, or jobs listed in Denton city. Brandon will not relocate. Never reinterpret United States, Dallas, DFW, or North Texas as remote or local enough.

LOCATION EVIDENCE RULE: Every title ends with [Remote ...] or [Denton, TX]. Score 1 if the text or your reason says remote is unclear, unverified, suggested, hybrid, on-site, in-office, office-based, RTO/return-to-office, relocation, or commuting is required. Do not tell Brandon to confirm remote later; reject it now.

REDDIT TRUST RULE: Reddit entries are labeled UNVERIFIED. Score a Reddit entry 3+ only when it is a hiring-side post for a concrete current paid role or contract from an identifiable employer/client, and its text explicitly says fully remote with US-compatible eligibility or lists Denton, TX. Reject [FOR HIRE] job seekers, equity-only/unpaid offers, vague DM-me posts, unknown-company aggregator redirects, affiliate spam, and anything requiring payment. For any kept Reddit lead, the reason must say to verify the role on the employer's official site before applying.

SOCIAL TRUST RULE: Score an X/Twitter entry 3+ only when the employer or an identifiable hiring manager posted a concrete current role and linked directly to the employer's job page. Score 1 for job-alert/aggregator accounts, WhatsApp or Telegram funnels, more-jobs links, affiliate/referral spam, scraped reposts, or Apply Now posts without an official employer link. Do not keep social spam merely because the title sounds relevant.

SCORE 1-5:
5 = Same lane or a clear step up: fully remote senior/principal customer-delivery, ProServe, contact-center/CCaaS, conversational/voice AI, or applied-AI architecture role. Owns architecture plus implementation and strongly matches the benchmark.
4 = Strong adjacent fit: fully remote enterprise agentic/GenAI customer engineer, forward-deployed engineer, cloud/AI architect, implementation consultant, or senior hands-on AI/voice engineer with transferable scope.
3 = Plausible fit with one meaningful gap (platform, domain, or delivery model), or a senior technical IC role listed in Denton. Worth Brandon reviewing.
2 = Down-level, generic, mostly support, weakly transferable, or lacks meaningful architecture/implementation ownership even though location passed.
1 = Location ambiguity/contradiction, relocation, junior/entry level, pure management, sales/GTM/customer-success/enablement, or irrelevant.

DO NOT estimate or guess salary. Salary is extracted separately only when the source explicitly publishes it. Do not output a pay field.

Output ONLY JSON lines: {\"idx\":<N>,\"score\":<1-5>,\"reason\":\"<brief comparison to the current-role benchmark>\"}

${JOB_LIST}"

SCORE_EXIT=0
RAW=$(cd "$HOME" && timeout 240 kiro-cli chat --model claude-opus-4.8 --no-interactive --wrap never "$PROMPT" 2>&1) || SCORE_EXIT=$?
SCORE_VALIDATION_ERROR=$(mktemp)
SCORE_VALIDATE_EXIT=0
SCORES=""
if [ "$SCORE_EXIT" -eq 0 ]; then
  SCORES=$(printf '%s\n' "$RAW" | python3 "$SCRIPT_DIR/job_location_policy.py" \
    --validate-scores --expected-count "$MODEL_COUNT" 2> "$SCORE_VALIDATION_ERROR") \
    || SCORE_VALIDATE_EXIT=$?
else
  SCORE_VALIDATE_EXIT=1
  printf 'model command exited %s before score validation\n' "$SCORE_EXIT" > "$SCORE_VALIDATION_ERROR"
fi
if [ "$SCORE_EXIT" -ne 0 ] || [ "$SCORE_VALIDATE_EXIT" -ne 0 ] || [ -z "$SCORES" ]; then
  SCORE_DIAG="$HOME/logs/ai-agent-jobs/scorer-error-${TODAY}-$(date +%H%M%S).log"
  {
    printf 'model_exit=%s\nvalidation_exit=%s\nexpected_count=%s\n' \
      "$SCORE_EXIT" "$SCORE_VALIDATE_EXIT" "$MODEL_COUNT"
    printf '%s\n' '--- validation ---'
    cat "$SCORE_VALIDATION_ERROR"
    printf '%s\n' '--- raw model output ---'
    printf '%s\n' "$RAW"
  } | python3 -c 'import sys; sys.stdout.write(sys.stdin.buffer.read().decode("utf-8", "replace"))' \
    > "$SCORE_DIAG"
  chmod 600 "$SCORE_DIAG"
  rm -f "$SCORE_VALIDATION_ERROR" "$JOBS_FILE"
  log "ERROR: kiro-cli scoring failed closed (model=$SCORE_EXIT, validation=$SCORE_VALIDATE_EXIT, expected=$MODEL_COUNT); details: $SCORE_DIAG"
  exit 1
fi
rm -f "$SCORE_VALIDATION_ERROR"

# --- Build digest ---
{
  echo "# 🤖 Remote AI & Contact-Center Jobs — $TODAY"
  echo ""
  echo "_Remote roles benchmarked to Brandon’s AWS Connect, Lex, ProServe, and agentic-AI delivery work_"
  echo ""
} > "$DIGEST_FILE"

KEPT=0
declare -A KEPT_KEYS=()
NEW_JOBS_TSV=$(mktemp)
while IFS= read -r score_line; do
  [ -z "$score_line" ] && continue
  idx=$(echo "$score_line" | jq -r '.idx // 0' 2>/dev/null)
  score=$(echo "$score_line" | jq -r '.score // 0' 2>/dev/null)
  reason=$(echo "$score_line" | jq -r '.reason // ""' 2>/dev/null)
  [ "$score" -lt 3 ] 2>/dev/null && continue

  JOB_LINE=$(sed -n "${idx}p" "$JOBS_FILE")
  [ -z "$JOB_LINE" ] && continue
  IFS=$'\t' read -r jid source poster title url salary <<< "$JOB_LINE"

  # The same employer/title often appears on several public boards under different
  # source IDs. Keep the first ranked copy, not duplicate Discord/email entries.
  dedupe_key=$(printf '%s|%s' "$poster" "$title" \
    | sed -E 's/ \[[^]]+\]$//' \
    | tr '[:upper:]' '[:lower:]' \
    | tr -cd '[:alnum:]|')
  [ -n "${KEPT_KEYS[$dedupe_key]:-}" ] && continue
  KEPT_KEYS[$dedupe_key]=1

  if is_seen "$jid"; then continue; fi

  {
    echo "${title}"
    # Only print salary when the poster explicitly included it in the listing.
    # No LLM guessing — real numbers only.
    [ -n "$salary" ] && echo "  💰 ${salary}"
    echo "Source: ${source} | Score: ${score}/5 | ${reason}"
    echo "${url}"
    echo ""
  } >> "$DIGEST_FILE"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$jid" "$score" "$reason" "$source" "$title" "$url" "$salary" >> "$NEW_JOBS_TSV"
  KEPT=$((KEPT + 1))
done <<< "$SCORES"

{
  echo "---"
  echo "_${TOTAL} postings scanned, ${KEPT} relevant (score ≥ 3/5)_"
} >> "$DIGEST_FILE"

log "Filter result: $TOTAL → $KEPT jobs kept"

# --- Deliver ---
if [ "$KEPT" -gt 0 ]; then
  if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY RUN: final digest follows; skipping Discord, email, and dedup writes"
    cat "$DIGEST_FILE" | tee -a "$LOGFILE"
  else
    DELIVERED=0
    DISCORD_CHANNEL="1503414103341797406"
  DISCORD_TOKEN=$(jq -r '.channels.discord.token // empty' ~/.openclaw/openclaw.json 2>/dev/null)
  DISCORD_OK=1
  send_discord() {
    local response_file code
    response_file=$(mktemp)
    code=$(curl -sS -o "$response_file" -w '%{http_code}' \
      -X POST "https://discord.com/api/v10/channels/$DISCORD_CHANNEL/messages" \
      -H "Authorization: Bot $DISCORD_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$(jq -nc --arg c "$1" '{content:$c}')") || code="000"
    rm -f "$response_file"
    [[ "$code" =~ ^2[0-9][0-9]$ ]]
  }

  if [ -n "$DISCORD_TOKEN" ] && [ -s "$NEW_JOBS_TSV" ]; then
    chunk="🤖 **${KEPT} new remote-fit job(s)** — ${TODAY}"
    while IFS=$'\t' read -r jid score reason source title url salary; do
      short_title="${title:0:200}"
      short_reason="${reason:0:260}"
      job_block=$'\n\n'"• **${short_title}** _(score ${score}/5, ${source})_"
      [ -n "$salary" ] && job_block="${job_block}"$'\n'"  💰 ${salary}"
      [ -n "$short_reason" ] && job_block="${job_block}"$'\n'"  _${short_reason}_"
      job_block="${job_block}"$'\n'"  <${url}>"
      candidate="${chunk}${job_block}"
      if [ ${#candidate} -gt 1800 ]; then
        send_discord "$chunk" || DISCORD_OK=0
        chunk="${job_block#$'\n\n'}"
      else
        chunk="$candidate"
      fi
    done < "$NEW_JOBS_TSV"
    [ -n "$chunk" ] && { send_discord "$chunk" || DISCORD_OK=0; }
    if [ "$DISCORD_OK" -eq 1 ]; then
      log "Discord: sent and verified ($KEPT jobs)"
      DELIVERED=1
    else
      log "ERROR: Discord delivery failed; jobs will not be marked seen"
    fi
  else
    DISCORD_OK=0
    log "ERROR: Discord token or job payload missing"
  fi

  if gog gmail send -a brandon.tyler@gmail.com \
       --to "brandon.tyler@gmail.com" \
       --subject "🤖 Remote AI & Contact-Center Jobs — ${KEPT} found ($TODAY)" \
       --body "$(cat "$DIGEST_FILE")" > /dev/null 2>&1; then
    log "Email sent"
    DELIVERED=1
  else
    log "Email failed"
  fi

  if [ "$DELIVERED" -eq 1 ]; then
    while IFS=$'\t' read -r jid score reason source title url salary; do
      mark_seen "$jid" "$title" "$source"
    done < "$NEW_JOBS_TSV"
    else
      log "ERROR: no delivery channel succeeded; leaving jobs unseen for retry"
    fi
  fi
fi

rm -f "$JOBS_FILE" "$NEW_JOBS_TSV"
log "Done."
