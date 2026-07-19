#!/usr/bin/env bash
# x-digest-foryou.sh — Daily X digest powered by your For You timeline + LLM filter
#
# Strategy:
#   1. Pull ~60 tweets from X's "For You" algorithmic timeline (GraphQL)
#   2. Dedup against DynamoDB (skip tweets already sent in previous digests)
#   3. Score remaining tweets via kiro-cli for actionability/relevance
#   4. Top results (score ≥ 7) go in the digest
#   5. Deliver to Discord + mark seen in DynamoDB
#
# Dependencies: curl, jq, kiro-cli, aws-cli (DynamoDB)
# Auth: AUTH_TOKEN + CT0 env vars (X cookies from ~/.profile)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TODAY=$(date +%Y-%m-%d)
DATE_LABEL=$(TZ='America/Chicago' date '+%a %b %d, %Y')
DIGEST_DIR="/tmp/x-digest"
DIGEST_FILE="$DIGEST_DIR/digest-${TODAY}.md"

# DynamoDB dedup
DYNAMO_TABLE="x-digest-seen"
PROFILE="personal"
REGION="us-east-1"
# The table has TTL enabled on `expires_at` — every item we write MUST carry
# it or rows live forever (bug fixed 2026-07-12: the foryou rewrite dropped
# the attribute the v3 script wrote). 30 days: longer than the 7-day search
# age gate, so nothing can expire and then resurface.
TTL_DAYS=30
EXPIRES_AT=$(date -d "+${TTL_DAYS} days" +%s)

# DRY_RUN=1 → full pipeline (pull, dedup, score, build digest file) but NO
# deliveries (Discord/email/alerts) and NO DynamoDB writes. For testing.
DRY_RUN="${DRY_RUN:-0}"
[ "$DRY_RUN" = "1" ] && DIGEST_FILE="${DIGEST_FILE%.md}-dryrun.md"  # don't clobber the real digest

# GraphQL config
QUERY_ID_FILE="$HOME/.config/bird/home-timeline-qid.txt"
BEARER="AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZz4puTs%3D1Zv7ttfk8LF81IUq16cHjhLTvJu4FA33AGWWjCpTnA"
FEATURES='{"responsive_web_graphql_exclude_directive_enabled":true,"verified_phone_label_enabled":false,"responsive_web_graphql_timeline_navigation_enabled":true,"responsive_web_graphql_skip_user_profile_image_extensions_enabled":false,"creator_subscriptions_tweet_preview_api_enabled":true,"communities_web_enable_tweet_community_results_fetch":true,"c9s_tweet_anatomy_moderator_badge_enabled":true,"articles_preview_enabled":true,"responsive_web_edit_tweet_api_enabled":true,"graphql_is_translatable_rweb_tweet_is_translatable_enabled":true,"view_counts_everywhere_api_enabled":true,"longform_notetweets_consumption_enabled":true,"tweet_awards_web_tipping_enabled":false,"freedom_of_speech_not_reach_fetch_enabled":true,"standardized_nudges_misinfo":true,"rweb_video_timestamps_enabled":true,"longform_notetweets_rich_text_read_enabled":true,"longform_notetweets_inline_media_enabled":true,"responsive_web_enhance_cards_enabled":false}'

# LLM config
RELEVANCE_THRESHOLD=7

source ~/.profile
mkdir -p "$DIGEST_DIR"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# --- Discord alert helper (for failures) ---
# Sends a one-line alert to the OpenClaw EC2 admin channel.
alert_discord() {
  local msg="$1"
  [ "$DRY_RUN" = "1" ] && { log "DRY_RUN: would alert Discord: $msg"; return; }
  local channel="${DIGEST_DISCORD_CHANNEL:-1503414103341797406}"
  local token
  token=$(jq -r '.channels.discord.token // empty' ~/.openclaw/openclaw.json 2>/dev/null)
  [ -z "$token" ] && { log "alert_discord: no token, skipping alert"; return; }
  curl -s -X POST "https://discord.com/api/v10/channels/$channel/messages" \
    -H "Authorization: Bot $token" \
    -H "Content-Type: application/json" \
    -d "{\"content\":$(printf '%s' "$msg" | jq -Rs .)}" > /dev/null 2>&1
}

# fail <message> — log, alert Discord, exit 1.
fail() {
  local msg="$1"
  log "FATAL: $msg"
  alert_discord "⚠️ **x-digest failed** — $msg
See \`~/logs/x-digest/cron.log\` on EC2 for details."
  exit 1
}

# --- GraphQL query ID management ---
get_query_id() {
  # Try cached ID first
  if [ -f "$QUERY_ID_FILE" ]; then
    local cached
    cached=$(cat "$QUERY_ID_FILE")
    local age
    age=$(( $(date +%s) - $(stat -c %Y "$QUERY_ID_FILE") ))
    # Use cached if less than 7 days old
    if [ "$age" -lt 604800 ] && [ -n "$cached" ]; then
      echo "$cached"
      return
    fi
  fi
  # Try known working IDs
  local candidates=("HJFjzBgCs16TqxewQOeLNg" "W4Tpu1uueTGK53paUgxF0Q" "lAKISuk_McyDUlhS2Zmv4A")
  for qid in "${candidates[@]}"; do
    local test
    test=$(curl -s "https://x.com/i/api/graphql/${qid}/HomeTimeline" \
      -H "authorization: Bearer $BEARER" \
      -H "cookie: auth_token=${AUTH_TOKEN}; ct0=${CT0}" \
      -H "x-csrf-token: ${CT0}" \
      -G --data-urlencode 'variables={"count":1,"includePromotedContent":false,"latestControlAvailable":true}' \
      --data-urlencode "features=${FEATURES}" 2>/dev/null | head -c 100)
    if echo "$test" | grep -q "home_timeline_urt"; then
      mkdir -p "$(dirname "$QUERY_ID_FILE")"
      echo "$qid" > "$QUERY_ID_FILE"
      echo "$qid"
      return
    fi
  done
  log "ERROR: No working HomeTimeline query ID found"
  return 1
}

# --- Pull For You timeline ---
pull_foryou() {
  local qid
  qid=$(get_query_id) || return 1
  local count="${1:-60}"

  curl -s "https://x.com/i/api/graphql/${qid}/HomeTimeline" \
    -H "authorization: Bearer $BEARER" \
    -H "cookie: auth_token=${AUTH_TOKEN}; ct0=${CT0}" \
    -H "x-csrf-token: ${CT0}" \
    -H "content-type: application/json" \
    -G --data-urlencode "variables={\"count\":${count},\"includePromotedContent\":false,\"latestControlAvailable\":true}" \
    --data-urlencode "features=${FEATURES}" 2>/dev/null
}

# --- Pull supplemental searches ---
# Loops through scripts/x-digest-searches.txt and runs each query via the
# `bird search` CLI. Catches high-engagement topic content For You may miss
# (e.g., authors Brandon doesn't engage with on X often).
# Emits TSV rows: tid \t user \t name \t likes \t rts \t created \t text
pull_search_supplements() {
  local searches_file="${SCRIPT_DIR}/x-digest-searches.txt"
  echo "0 0" > "$DIGEST_DIR/.suppl_status"  # reset (also covers early return)
  if [ ! -f "$searches_file" ]; then
    log "No supplemental searches file at $searches_file — skipping"
    return
  fi

  # Age gate: without since:, a dormant account's months-old post can surface
  # (and resurface once its DynamoDB dedup row expires). 7 days keeps posts
  # eligible while still gaining traction but bounds staleness.
  local since
  since=$(date -d '7 days ago' +%Y-%m-%d)

  local total=0 ran=0 failed=0
  while IFS='|' read -r name query max_results; do
    # Skip comments and blank lines
    [[ "$name" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${name// }" ]] && continue
    [ -z "$query" ] && continue
    max_results="${max_results:-5}"
    [[ "$query" != *"since:"* ]] && query="$query since:$since"
    ran=$((ran + 1))

    local results
    results=$(timeout 15 bird search "$query" --json 2>/dev/null) || {
      log "search '$name' timed out or failed — skipping" >&2
      failed=$((failed + 1))
      continue
    }
    [ -z "$results" ] && continue

    # Parse to TSV (same shape as For You parsing, plus a source tag column)
    # Extract min_faves:N from the query, if present. bird / X's API sometimes
    # returns tweets below the operator's floor (observed 0-like tweets on
    # min_faves:1000 queries), so we enforce script-side too.
    local qmf
    qmf=$(echo "$query" | grep -oP 'min_faves:\K\d+' | head -1)
    local floor
    if [ -n "$qmf" ]; then
      # min_faves in the query always wins: honor N/2 as the digest-time floor
      # (leaves slack for bird's occasional bypass; still keeps out zeros).
      # Applies uniformly to keyword and account queries — an explicit min_faves
      # is intentional (e.g., elonmusk_top has min_faves:10000 because Elon
      # posts a LOT and Brandon only wants his top posts).
      floor=$(( qmf / 2 ))
      [ "$floor" -lt 3 ] && floor=3
    else
      # No min_faves in the query.
      # Account-only queries (bare 'from:USER' with no keyword clauses) →
      # trusted source, no floor. Brandon has hand-vetted these authors, so
      # fresh 0-like posts should surface (SpaceX launch, karpathy insight).
      # Everything else → default 3-like floor (blocks keyword-search noise).
      local qtrim
      qtrim=$(echo "$query" | tr -s ' ' | sed 's/^ *//;s/ *$//')
      if echo "$qtrim" | grep -qE '^from:[A-Za-z0-9_]+$'; then
        floor=0
      else
        floor=3
      fi
    fi

    local rows
    rows=$(echo "$results" | FLOOR="$floor" python3 -c "
import sys, json, os
try:
    data = json.load(sys.stdin)
except (json.JSONDecodeError, ValueError):
    sys.exit(0)
limit = int('${max_results}')
floor = int(os.environ.get('FLOOR', '3'))
kept = 0
for tweet in (data or []):
    if kept >= limit:
        break
    try:
        tid = tweet.get('id', '')
        author = tweet.get('author', {}) or {}
        user = author.get('username', '')
        name = author.get('name', '')
        text = (tweet.get('text', '') or '').replace('\n', ' ').replace('\t', ' ')
        likes = tweet.get('likeCount', 0) or 0
        rts = tweet.get('retweetCount', 0) or 0
        created = tweet.get('createdAt', '')
        if not text or not user or not tid:
            continue
        if text.startswith('RT @'):
            continue
        # Engagement floor — the fix Brandon asked for.
        # Enforced script-side because bird / X's API occasionally returns
        # tweets below the min_faves: operator's declared floor.
        if likes < floor:
            continue
        print(f'{tid}\t{user}\t{name}\t{likes}\t{rts}\t{created}\t{text[:300]}')
        kept += 1
    except (KeyError, TypeError):
        pass
" 2>/dev/null | sed "s/$/	${name}/")

    if [ -n "$rows" ]; then
      local n
      n=$(echo "$rows" | grep -c '.' || echo 0)
      total=$((total + n))
      log "  $name: $n tweets" >&2
      printf '%s\n' "$rows"
    fi
  done < "$searches_file"

  log "Supplemental searches: $total tweets pulled across all queries ($failed/$ran queries failed)" >&2
  # Surface total-failure to the caller (we run inside $(...), so no globals).
  # bird silently dying would otherwise degrade this to a For-You-only digest
  # forever with only per-query log lines to notice.
  echo "$failed $ran" > "$DIGEST_DIR/.suppl_status"
}

# --- DynamoDB helpers ---
# Batch dedup: read tweet ids on stdin (one per line), emit the SEEN subset
# on stdout. Uses batch-get-item (100 keys/call) instead of one get-item
# subprocess per tweet — the old per-tweet loop cost ~70s of a ~150s run.
seen_ids_batch() {
  local ids resp
  ids=$(cat)
  [ -z "$ids" ] && return
  echo "$ids" | xargs -n 100 | while IFS= read -r batch; do
    local keys=""
    local tid
    for tid in $batch; do
      keys="${keys}{\"tweet_id\":{\"S\":\"$tid\"}},"
    done
    keys="${keys%,}"
    resp=$(aws dynamodb batch-get-item \
      --request-items "{\"$DYNAMO_TABLE\":{\"Keys\":[${keys}],\"ProjectionExpression\":\"tweet_id\"}}" \
      --profile "$PROFILE" --region "$REGION" \
      --query "Responses.\"$DYNAMO_TABLE\"[].tweet_id.S" --output text 2>/dev/null) || {
      # DynamoDB read failure → treat batch as unseen (graceful degradation;
      # worst case is a repeat tweet, not a lost one).
      continue
    }
    [ -n "$resp" ] && [ "$resp" != "None" ] && tr '\t' '\n' <<< "$resp"
  done
}

batch_mark_seen() {
  local ids_file="$1"
  [ ! -s "$ids_file" ] && return
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN: would mark $(wc -l < "$ids_file" | xargs) tweets seen in DynamoDB"
    return
  fi
  local batch_items="" count=0
  while IFS= read -r tid; do
    [ -z "$tid" ] && continue
    batch_items="${batch_items}{\"PutRequest\":{\"Item\":{\"tweet_id\":{\"S\":\"$tid\"},\"seen_date\":{\"S\":\"$TODAY\"},\"expires_at\":{\"N\":\"$EXPIRES_AT\"}}}},"
    count=$((count + 1))
    if [ "$count" -ge 25 ]; then
      batch_items="${batch_items%,}"
      aws dynamodb batch-write-item \
        --request-items "{\"$DYNAMO_TABLE\":[${batch_items}]}" \
        --profile "$PROFILE" --region "$REGION" > /dev/null 2>&1
      batch_items="" count=0
    fi
  done < "$ids_file"
  if [ "$count" -gt 0 ]; then
    batch_items="${batch_items%,}"
    aws dynamodb batch-write-item \
      --request-items "{\"$DYNAMO_TABLE\":[${batch_items}]}" \
      --profile "$PROFILE" --region "$REGION" > /dev/null 2>&1
  fi
}

# --- LLM scoring ---
score_tweets() {
  local tweets_text="$1"
  local count
  count=$(echo "$tweets_text" | grep -c '^[0-9]' || echo 0)
  [ "$count" -eq 0 ] && return

  local prompt="You are filtering tweets from Brandon's X 'For You' feed for his daily digest.

Brandon wants to see (he's an AWS ProServe engineer on Amazon Connect, currently building an agent-evaluation framework, daily tools: Kiro CLI, Claude Code, OpenAI Codex):
- Amazon Connect — ANY substantive Connect content: new features, Contact Lens, Q in Connect, Cases, CCaaS industry moves, contact-center AI. This is his DAY JOB — score substantive Connect posts 8+, even at low engagement.
- Eval-driven development & TESTING AGENTS — DeepEval, agent evaluation, eval harnesses, LLM-as-a-judge/verifier, eval metrics, agent benchmarks (Terminal-Bench, SWE-Bench), rubrics, regression testing for agents. He is BUILDING an eval framework right now — score substantive posts here 8+.
- Claude Code best practices — how to use it better, tips, workflows, what power users are doing
- Kiro CLI best practices — how people are using it, tips, what's new
- OpenAI Codex (the coding agent/CLI) — releases, changelog, workflows, comparisons with Claude Code. NOT the old Codex model, NOT unrelated "codex" words (games, manuscripts).
- How people are using AI to solve REAL problems (not hype, actual use cases)
- Real Estate x AI — HIGH PRIORITY right now: Brandon is preparing a presentation (due this Friday) on how to use AI in real estate and needs inspiration. Surface practical, substantive posts on how agents/brokers actually use AI: listing descriptions, valuations/CMAs, lead-gen, marketing/content, CRM/follow-up, virtual & AI staging, transaction/ops automation, plus notable industry news (Zillow/Redfin AI features, portals, proptech tools). Score substantive RE-AI posts 8+, even at modest engagement. Do NOT score high: generic \"real estate market/bubble/rates\" macro-finance takes, and motivational realtor-hustle posts with no AI substance.
- Agent skills (SKILL.md files) — TOP INTEREST. New skill releases, what people are building/installing/using, skill-authoring patterns, marketplaces (ClawHub). Score substantive agent-skills posts 8+ and surface these generously.
- AI for productivity — Gmail/Calendar/Drive/Workspace automation, agentic email/calendar assistants
- Discord / Slack agent integrations — multi-channel agent platforms, chat-driven agents
- Voice agents / TTS — ElevenLabs, Vapi, voice-first agent UX
- What's happening in AI — latest breakthroughs, new tools, what people are excited about
- Agent workflow orchestration & multi-agent systems — how agents are composed, coordinated, and orchestrated (planner/worker patterns, agent handoffs, multi-agent frameworks like LangGraph/CrewAI/Strands). This is a real interest — score good posts here 7-8. Just avoid the \"loop\"-branded niche (see Score LOW).
- Agent architectures & how agents are built and wired to tools. (MCP is OK when it's genuinely notable/new, but do NOT over-emphasize MCP — skip routine \"here's another MCP server\" posts. Brandon does not want MCP surfaced heavily.)
- AWS news and services (Amazon Connect, Bedrock, AgentCore, Strands, Lambda, new launches) — Brandon works at AWS
- SpaceX launches, milestones, engineering achievements
- Tesla, FSD, robotaxi, Cybercab, Optimus, Boring Company news and progress
- @Tesla (corporate account) and @SpaceX (corporate account) — ALWAYS score 8+ when posting about their actual products: Cybercab, Optimus, Starship, Falcon, Dragon, FSD updates, factory news, production milestones, engineering tests, launch events. These are official company announcements — score them HIGH even if engagement is modest. Skip only obvious marketing fluff (e.g., generic 'thanks to our customers' or holiday greetings).
- @elonmusk — ONLY include when it's about SpaceX, Tesla, Neuralink, xAI, Boring Company, or engineering. Skip political takes, culture war, government/DOGE commentary, and casual replies.
- @SawyerMerritt — breaking Tesla/SpaceX news. Only his biggest posts (he posts a lot too).
- ENGAGEMENT RULE: For high-volume posters (Elon, Sawyer, Boris Cherny), only surface their top 1-2 posts — the ones with unusually high engagement relative to their normal. If Elon averages 50K likes, only include 100K+ posts. If Sawyer averages 2K, only include 5K+.
- ALWAYS include anything from @karpathy (Andrej Karpathy) when it's about AI, models, or tech — score 9+
- @bcherny (Boris Cherny, Claude Code creator) — include his best stuff but he tweets a lot, only score 8+ when it's a real tip or insight

Score LOW (1-3):
- Crypto/token promotions, memecoins, trading
- Generic motivational/hustle content
- Celebrity gossip, politics, culture war
- Ads/promoted content
- Non-English content — EXCEPT substantive Amazon Connect or Kiro posts: the Japanese AWS community publishes excellent Connect/Kiro case studies and verification write-ups. Score those on substance like any English post (X auto-translates). Non-English content on any OTHER topic: score low. Non-English engagement bait/spam: always low.
- Pure entertainment (sports, memes)
- Retweets without added commentary
- Courses/giveaways/engagement bait
- Company drama or stock price speculation
- \"Loop\"-branded content specifically — \"Loop Engineering\", \"Ralph loop\", \"agentic loops\", self-looping-agent mechanics. It is ONLY the LOOP framing/terminology Brandon wants to avoid. (IMPORTANT: agent workflow orchestration, multi-agent systems, and agent development in general ARE wanted and stay HIGH — do NOT downrank an orchestration/workflow post just because agents run steps; only score low when the post's actual subject is the \"loop\" niche/terminology.)
- MCP overexposure — routine \"new MCP server\" / \"MCP tutorial\" posts. Not banned, but do not emphasize; only surface MCP when it's genuinely notable.

Score each tweet 1-10. A 10 is something Brandon would stop scrolling to read and maybe act on. A 7 is solid, worth including. Below 7 is noise.

ALSO categorize each tweet into ONE of these topics (use the exact string, lowercase):
- claude_code       — Claude Code tips, workflows, official Anthropic content
- kiro_cli          — Kiro CLI, Kiro one, Kiro dev
- codex             — OpenAI Codex coding agent/CLI: releases, workflows, comparisons
- agent_skills      — SKILL.md, agent skills, ClawHub, npx skills add
- evals             — Agent evaluation & testing, DeepEval, eval harnesses, eval metrics, LLM-as-a-judge/verifier, agent benchmarks (Terminal-Bench/SWE-Bench), rubrics, regression testing
- agent_orchestration — Multi-agent systems, agent workflow orchestration, agent frameworks (LangGraph, CrewAI, Strands), planner/worker & handoff patterns
- mcp               — MCP servers, MCP tools, tool integrations (tag only when MCP is the actual subject)
- ai_productivity   — Gmail/Calendar/Drive/Workspace AI automation, personal assistants
- voice_agents      — ElevenLabs, Vapi, voice-first agents, TTS, conversational AI
- aws               — Amazon Connect, Bedrock, AgentCore, Strands, general AWS AI
- ai_news           — Model releases (Gemini, GPT, Claude, Llama), industry breakthroughs, research
- ai_consulting     — AI agencies, freelance, vibe coding, revenue transparency
- real_estate_ai    — AI in real estate: agent/broker AI use, listing descriptions, valuations/CMA, lead-gen, marketing, virtual/AI staging, proptech, Zillow/Redfin AI features
- spacex            — SpaceX launches, Starship, Falcon, Dragon, Super Heavy, engineering
- tesla             — Tesla, FSD, Cybercab, Optimus, Robotaxi, Boring Company, xAI, Neuralink
- other             — anything not in the list above

Reply ONLY with a JSON array of objects, one per tweet — include the tweet's language as a 2-letter code. For NON-ENGLISH tweets only, also include \"gist\": a one-sentence English summary (max 25 words) of what the tweet actually says, so Brandon can decide whether it's worth opening. Omit \"gist\" for English tweets. No prose, no code fences. Example:
[{\"score\":8,\"topic\":\"claude_code\",\"lang\":\"en\"},{\"score\":2,\"topic\":\"other\",\"lang\":\"en\"},{\"score\":9,\"topic\":\"aws\",\"lang\":\"ja\",\"gist\":\"Municipal call-center bot using Connect+Lex+Q in Connect RAG improved answer accuracy from 60% to 81%\"}]

Tweets:
${tweets_text}"

  # Run from $HOME so kiro-cli picks up ~/.kiro/agents/default.json.
  # Timeout 180: the gist field (added 2026-07-12) makes the model generate
  # noticeably more output for 40+ tweets; 60s hit the ceiling and killed
  # scoring on a full-size batch.
  # Response shape: JSON array of {score,topic,lang,gist?} objects. Extraction
  # uses a real JSON parser (raw_decode at each '[') instead of the old
  # grep -oP '\[\{[^]]+\}\]' — that regex died at the first ']' inside any
  # string value, which free-prose gists can legitimately contain.
  timeout 180 bash -c "cd \$HOME && kiro-cli chat --no-interactive --wrap never \"\$1\"" -- "$prompt" 2>&1 | \
    sed 's/\x1b\[[0-9;]*m//g' | python3 -c "
import sys, json
buf = sys.stdin.read()
dec = json.JSONDecoder()
i = 0
while True:
    i = buf.find('[', i)
    if i < 0:
        break
    try:
        obj, _ = dec.raw_decode(buf, i)
    except ValueError:
        i += 1
        continue
    if isinstance(obj, list) and obj and all(isinstance(o, dict) and 'score' in o for o in obj):
        print(json.dumps(obj))
        break
    i += 1
"
}

# --- Main ---
log "Pulling For You timeline..."
RAW_JSON=$(pull_foryou 60)

if [ -z "$RAW_JSON" ] || ! echo "$RAW_JSON" | jq -e '.data.home' > /dev/null 2>&1; then
  log "ERROR: Failed to pull For You timeline"
  # Check if auth expired
  if echo "$RAW_JSON" | grep -qi "unauthorized\|forbidden\|Could not authenticate"; then
    fail "Auth tokens may be expired — check AUTH_TOKEN and CT0 in ~/.profile"
  fi
  fail "Pulled empty/invalid response from X For You GraphQL endpoint"
fi

# Parse tweets from the timeline
TWEETS_TSV=$(echo "$RAW_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
entries = d['data']['home']['home_timeline_urt']['instructions'][0]['entries']
for e in entries:
    try:
        content = e['content']
        if content.get('__typename') != 'TimelineTimelineItem':
            continue
        ic = content.get('itemContent', {})
        # Skip promoted content
        if ic.get('promotedMetadata'):
            continue
        tweet = ic['tweet_results']['result']
        if tweet.get('__typename') == 'TweetWithVisibilityResults':
            tweet = tweet['tweet']
        legacy = tweet.get('legacy', {})
        core = tweet.get('core', {})
        user_legacy = core.get('user_results', {}).get('result', {}).get('legacy', {})
        username = user_legacy.get('screen_name', '')
        name = user_legacy.get('name', '')
        text = legacy.get('full_text', '').replace('\n', ' ').replace('\t', ' ')
        likes = legacy.get('favorite_count', 0)
        rts = legacy.get('retweet_count', 0)
        tid = legacy.get('id_str', '')
        created = legacy.get('created_at', '')
        # Skip if no real content
        if not text or not username or not tid:
            continue
        # Skip pure RTs (text starts with 'RT @')
        if text.startswith('RT @'):
            continue
        print(f'{tid}\t{username}\t{name}\t{likes}\t{rts}\t{created}\t{text[:300]}\tforyou')
    except (KeyError, TypeError):
        pass
")

TOTAL_RAW=$(echo "$TWEETS_TSV" | grep -c '.' || true)
log "Parsed $TOTAL_RAW tweets from For You (promoted/RTs filtered)"

# --- Supplemental: topic searches via bird CLI ---
# Catches high-engagement topic content For You may not surface, plus
# always-include accounts (karpathy, bcherny). Output merged with For You
# before DynamoDB dedup so cross-source repeats are eliminated.
log "Running supplemental topic searches..."
SUPPL_TSV=$(pull_search_supplements)
SUPPL_COUNT=$(echo "$SUPPL_TSV" | grep -c '.' || true)

# If EVERY search failed, bird is likely broken (expired cookies, API change)
# — alert once instead of silently degrading to a For-You-only digest forever.
read -r SUPPL_FAILED SUPPL_RAN 2>/dev/null < "$DIGEST_DIR/.suppl_status" || { SUPPL_FAILED=0; SUPPL_RAN=0; }
if [ "$SUPPL_RAN" -gt 0 ] && [ "$SUPPL_FAILED" -eq "$SUPPL_RAN" ]; then
  alert_discord "⚠️ **x-digest: all $SUPPL_RAN supplemental bird searches failed** — bird CLI may be broken (cookies expired? API change?). Digest continues with For You only."
fi

if [ "$SUPPL_COUNT" -gt 0 ]; then
  # Merge + cross-source dedup by tid. When a tweet appears in BOTH For You
  # AND a search, concatenate the sources (e.g., "foryou+karpathy") so the
  # digest shows where it surfaced from. Source preservation is what makes
  # the digest tunable — Brandon can see which queries are pulling weight.
  TWEETS_TSV=$(printf '%s\n%s\n' "$TWEETS_TSV" "$SUPPL_TSV" | python3 -c "
import sys
seen = {}
order = []
for line in sys.stdin:
    p = line.rstrip('\n').split('\t')
    if len(p) < 8 or not p[0]:
        continue
    tid, src = p[0], p[7]
    if tid in seen:
        existing = seen[tid][7].split('+')
        if src and src not in existing:
            seen[tid][7] = seen[tid][7] + '+' + src
    else:
        seen[tid] = p
        order.append(tid)
for tid in order:
    print('\t'.join(seen[tid]))
")
  TOTAL_RAW=$(echo "$TWEETS_TSV" | grep -c '.' || echo 0)
  log "After merging $SUPPL_COUNT supplemental + cross-source dedup: $TOTAL_RAW unique tweets"
fi

# Dedup against DynamoDB — one batch-get per 100 ids instead of a get-item
# subprocess per tweet (the old loop cost ~70s/run). FRESH file (not a shell
# var round-tripped through echo -e, which corrupted tweets containing
# literal \n or \t sequences).
FRESH_FILE=$(mktemp)
SEEN_FILE=$(mktemp)
trap 'rm -f "$FRESH_FILE" "$SEEN_FILE"' EXIT

printf '%s\n' "$TWEETS_TSV" | cut -f1 | grep -E '^[0-9]+$' | seen_ids_batch | sort -u > "$SEEN_FILE"

SKIPPED=0
while IFS= read -r row; do
  tid="${row%%$'\t'*}"
  [ -z "$tid" ] && continue
  if grep -qxF "$tid" "$SEEN_FILE"; then
    SKIPPED=$((SKIPPED + 1))
  else
    printf '%s\n' "$row" >> "$FRESH_FILE"
  fi
done <<< "$TWEETS_TSV"

FRESH_COUNT=$(grep -c '.' "$FRESH_FILE" || true)
log "After dedup: $FRESH_COUNT new tweets ($SKIPPED previously seen)"

if [ "$FRESH_COUNT" -eq 0 ]; then
  log "No new tweets — skipping digest"
  {
    echo "# Daily X Digest — $DATE_LABEL"
    echo ""
    echo "_(No new posts in your For You feed today. $SKIPPED previously seen tweets skipped.)_"
  } > "$DIGEST_FILE"
  # Still deliver the "nothing new" message
else
  # Build numbered list for LLM scoring
  NUMBERED=""
  i=1
  while IFS=$'\t' read -r tid user name likes rts created text source; do
    [ -z "$tid" ] && continue
    NUMBERED="${NUMBERED}${i}. @${user} (${likes} likes): ${text}"$'\n'
    i=$((i + 1))
  done < "$FRESH_FILE"

  log "Scoring $FRESH_COUNT tweets via kiro-cli..."
  SCORES=$(score_tweets "$NUMBERED")

  if [ -z "$SCORES" ]; then
    # Fail-closed: don't flood Discord with unscored tweets.
    alert_discord "⚠️ **x-digest scoring failed** — kiro-cli returned no scores for $FRESH_COUNT tweets.
No digest sent. Raw tweets in \`/tmp/x-digest/digest-${TODAY}.md\` on EC2.
Tweets are NOT marked seen — they will be re-evaluated next run."
    log "FATAL: LLM scoring returned empty — aborting without marking tweets seen"
    exit 1
  fi

  # Validate score-array length. A truncated/misaligned response silently
  # assigns scores to the WRONG tweets (and the mis-scored ones get marked
  # seen — permanently lost). Fail closed instead, same as empty scores.
  SCORE_COUNT=$(echo "$SCORES" | jq 'length' 2>/dev/null || echo 0)
  if [ "$SCORE_COUNT" -ne "$FRESH_COUNT" ]; then
    alert_discord "⚠️ **x-digest scoring misaligned** — kiro-cli returned $SCORE_COUNT scores for $FRESH_COUNT tweets.
No digest sent; tweets NOT marked seen — they will be re-evaluated next run."
    log "FATAL: score count ($SCORE_COUNT) != tweet count ($FRESH_COUNT) — aborting without marking tweets seen"
    exit 1
  fi

  log "Scores: $SCORES"

  # Adaptive threshold: if fewer than 3 posts meet ≥7, lower threshold to the
  # 3rd-highest score so the digest is never near-empty on slow days. Quality
  # bar stays at 7 for normal days, falls back to top-3 on thin days.
  # (SCORES is now an array of {score,topic} objects — extract .score for math.)
  EFFECTIVE_THRESHOLD="$RELEVANCE_THRESHOLD"
  ADAPTIVE_NOTE=""
  COUNT_AT_THRESHOLD=$(echo "$SCORES" | jq "[.[] | .score | select(. >= $RELEVANCE_THRESHOLD)] | length" 2>/dev/null || echo 0)
  if [ "$COUNT_AT_THRESHOLD" -lt 3 ] && [ "$FRESH_COUNT" -ge 3 ]; then
    THIRD_HIGHEST=$(echo "$SCORES" | jq "[.[] | .score] | sort | reverse | .[2]" 2>/dev/null)
    if [ -n "$THIRD_HIGHEST" ] && [ "$THIRD_HIGHEST" != "null" ]; then
      EFFECTIVE_THRESHOLD="$THIRD_HIGHEST"
      ADAPTIVE_NOTE=" (adaptive: only $COUNT_AT_THRESHOLD met ≥${RELEVANCE_THRESHOLD}, lowered to top-3)"
      log "Adaptive threshold: only $COUNT_AT_THRESHOLD met ≥${RELEVANCE_THRESHOLD}, lowering to ${EFFECTIVE_THRESHOLD} to guarantee 3 posts"
    fi
  fi

  # Build digest with scored tweets
  {
    echo "# Daily X Digest — $DATE_LABEL"
    echo ""
    echo "_Powered by your For You feed + LLM relevance filter_"
    echo ""
  } > "$DIGEST_FILE"

  MARK_FILE=$(mktemp)
  SOURCE_TALLY=$(mktemp)
  INCLUDED=0

  # Annotate each row with its score+topic (paste is safe: SCORE_COUNT was
  # validated == FRESH_COUNT above), then render best-first. Feed order buried
  # the 9/10s mid-scroll; sorted output puts the best content on top.
  SCORED_FILE=$(mktemp)
  # NOTE: empty TSV fields get SWALLOWED by bash `read` (tab is IFS whitespace,
  # consecutive tabs collapse) — an empty gist shifted every later column left.
  # Emit "-" as the empty-gist sentinel and map it back to "" in the loop.
  paste <(echo "$SCORES" | jq -r '.[] | [(.score // 0), (.topic // "other"), (.lang // "en"), ((.gist // "") | if . == "" then "-" else . end)] | @tsv') "$FRESH_FILE" > "$SCORED_FILE"

  while IFS=$'\t' read -r score topic lang gist tid user name likes rts created text source; do
    [ -z "$tid" ] && continue
    [ "$gist" = "-" ] && gist=""
    # Track source for evaluation breakdown (whether surfaced or not)
    echo "eval:${source:-unknown}" >> "$SOURCE_TALLY"
    if [ "$score" -ge "$EFFECTIVE_THRESHOLD" ] 2>/dev/null; then
      # Format date
      cdt=$(TZ='America/Chicago' date -d "$created" '+%a %b %d, %l:%M %p CDT' 2>/dev/null || echo "$created")
      # Render source as friendly badges
      source_display="${source:-unknown}"
      if [ "$source_display" = "foryou" ]; then
        # For You feed → append LLM-classified topic so Brandon knows the subject
        src_line="📡 For You feed · \`${topic}\` · score ${score}/10"
      elif [[ "$source_display" == *"+"* ]]; then
        # Multiple sources — show all
        src_line="🎯 \`${source_display}\` · score ${score}/10"
      else
        src_line="🎯 \`${source_display}\` search · score ${score}/10"
      fi
      # Non-English badge — surfaced via the Connect/Kiro substance exception.
      # Flag it so Brandon expects the auto-translate button before tapping.
      if [ -n "$lang" ] && [ "$lang" != "en" ]; then
        src_line="${src_line} · 🌐 ${lang}"
      fi
      {
        echo "**@${user}** ($name) — ${likes} likes, ${rts} RTs — ${cdt}"
        echo "$src_line"
        # English gist first for non-English tweets: clicking through costs a
        # For-You algorithm signal, so Brandon decides from the gist alone.
        if [ -n "$gist" ]; then
          echo "> 💬 ${gist}"
        fi
        echo "${text}"
        echo "https://x.com/${user}/status/${tid}"
        echo ""
      } >> "$DIGEST_FILE"
      INCLUDED=$((INCLUDED + 1))
      echo "$tid" >> "$MARK_FILE"
      echo "surfaced:${source:-unknown}" >> "$SOURCE_TALLY"
    else
      # Still mark low-scoring tweets as seen so they don't reappear
      echo "$tid" >> "$MARK_FILE"
    fi
  done < <(sort -t$'\t' -k1,1nr -k8,8nr "$SCORED_FILE")

  # --- Real Estate × AI topic boost (Brandon actively wants this niche) ---
  # Root cause of "never a single RE post": RE-AI is low-volume and its posts
  # (industry news, practitioner tips) tend to score ~6 as bare tweets — solid
  # for this niche but just under the global 7 gate, so they were filtered every
  # day. Fix: give RE-sourced posts a slightly lower but still-quality bar and
  # surface up to RE_MAX of them that the main loop didn't already take.
  # This is a QUALITY gate, NOT a guarantee: a dry day (nothing >= RE_THRESHOLD)
  # still yields zero — we never pad the digest with weak (<=5) posts. Keyed off
  # SOURCE because the model often mistags RE news as other/ai_news.
  RE_THRESHOLD=6
  RE_MAX=2
  re_added=0
  while IFS=$'\t' read -r score topic lang gist tid user name likes rts created text source; do
    [ -z "$tid" ] && continue
    [ "$re_added" -ge "$RE_MAX" ] && break
    case "$source" in *real_estate_ai*) : ;; *) continue ;; esac
    # score in [RE_THRESHOLD, EFFECTIVE_THRESHOLD): good-for-niche but not
    # already surfaced by the main loop (avoids double-render).
    { [ "$score" -ge "$RE_THRESHOLD" ] && [ "$score" -lt "$EFFECTIVE_THRESHOLD" ]; } 2>/dev/null || continue
    [ "$gist" = "-" ] && gist=""
    cdt=$(TZ='America/Chicago' date -d "$created" '+%a %b %d, %l:%M %p CDT' 2>/dev/null || echo "$created")
    {
      echo "**@${user}** ($name) — ${likes} likes, ${rts} RTs — ${cdt}"
      echo "📌 \`Real Estate × AI\` · \`${source}\` · score ${score}/10"
      if [ -n "$gist" ]; then
        echo "> 💬 ${gist}"
      fi
      echo "${text}"
      echo "https://x.com/${user}/status/${tid}"
      echo ""
    } >> "$DIGEST_FILE"
    INCLUDED=$((INCLUDED + 1))
    re_added=$((re_added + 1))
    grep -qxF "$tid" "$MARK_FILE" || echo "$tid" >> "$MARK_FILE"
    echo "surfaced:${source:-unknown}" >> "$SOURCE_TALLY"
    log "RE-AI boost surfaced: @${user} (score ${score}, source ${source})"
  done < <(sort -t$'\t' -k1,1nr "$SCORED_FILE")

  rm -f "$SCORED_FILE"

  # Build source breakdown (top 8 sources by surfaced count, plus evaluated totals)
  EVAL_BREAKDOWN=$(grep '^eval:' "$SOURCE_TALLY" | sed 's/^eval://' | tr '+' '\n' | sort | uniq -c | sort -rn | awk '{printf "%s %d · ", $2, $1}' | sed 's/ · $//')
  SURFACED_BREAKDOWN=$(grep '^surfaced:' "$SOURCE_TALLY" | sed 's/^surfaced://' | tr '+' '\n' | sort | uniq -c | sort -rn | awk '{printf "%s %d · ", $2, $1}' | sed 's/ · $//')
  rm -f "$SOURCE_TALLY"

  {
    echo "---"
    echo "_${FRESH_COUNT} new posts evaluated, ${INCLUDED} surfaced (score ≥ ${EFFECTIVE_THRESHOLD}/10), ${SKIPPED} previously seen skipped.${ADAPTIVE_NOTE}_"
    if [ -n "$EVAL_BREAKDOWN" ]; then
      echo ""
      echo "_📥 Evaluated by source: ${EVAL_BREAKDOWN}_"
    fi
    if [ -n "$SURFACED_BREAKDOWN" ]; then
      echo "_🎯 Surfaced by source: ${SURFACED_BREAKDOWN}_"
    fi
  } >> "$DIGEST_FILE"

  # Mark all evaluated tweets as seen
  batch_mark_seen "$MARK_FILE"
  rm -f "$MARK_FILE"

  log "Digest: $INCLUDED tweets surfaced from $FRESH_COUNT new"
fi

# --- Send to Discord ---
DISCORD_CHANNEL="${DIGEST_DISCORD_CHANNEL:-1503414103341797406}"
DISCORD_TOKEN=$(jq -r '.channels.discord.token // empty' ~/.openclaw/openclaw.json 2>/dev/null)
if [ "$DRY_RUN" = "1" ]; then
  log "DRY_RUN: skipping Discord + email delivery"
elif [ -n "$DISCORD_TOKEN" ]; then
  chunk=""
  sent=0
  while IFS= read -r line; do
    if [ ${#chunk} -gt 0 ] && [[ "$line" == "**@"* ]] && [ $((${#chunk} + ${#line})) -gt 1900 ]; then
      curl -s -X POST "https://discord.com/api/v10/channels/$DISCORD_CHANNEL/messages" \
        -H "Authorization: Bot $DISCORD_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"content\":$(echo "$chunk" | jq -Rs .)}" > /dev/null
      sent=$((sent + 1))
      chunk=""
      sleep 1
    fi
    chunk="${chunk}${line}"$'\n'
  done < "$DIGEST_FILE"
  if [ -n "$chunk" ]; then
    curl -s -X POST "https://discord.com/api/v10/channels/$DISCORD_CHANNEL/messages" \
      -H "Authorization: Bot $DISCORD_TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"content\":$(echo "$chunk" | jq -Rs .)}" > /dev/null
    sent=$((sent + 1))
  fi
  log "Discord: sent $sent message(s)"
fi

# Email digest
if [ "$DRY_RUN" != "1" ]; then
  TODAY_LABEL=$(date '+%a %b %d, %Y')
  gog gmail send -a brandon.tyler@gmail.com \
    --to "brandon.tyler@gmail.com" \
    --subject "📱 X Digest — $TODAY_LABEL" \
    --body "$(cat "$DIGEST_FILE")" 2>/dev/null && log "Email sent" || log "Email failed"
fi

log "Done. Digest: $DIGEST_FILE"
cat "$DIGEST_FILE"
