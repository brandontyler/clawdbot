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

# --- DynamoDB helpers ---
is_seen() {
  local tid="$1"
  aws dynamodb get-item \
    --table-name "$DYNAMO_TABLE" \
    --key "{\"tweet_id\":{\"S\":\"$tid\"}}" \
    --profile "$PROFILE" --region "$REGION" \
    --output text 2>/dev/null | grep -q "$tid"
}

batch_mark_seen() {
  local ids_file="$1"
  [ ! -s "$ids_file" ] && return
  local batch_items="" count=0
  while IFS= read -r tid; do
    [ -z "$tid" ] && continue
    batch_items="${batch_items}{\"PutRequest\":{\"Item\":{\"tweet_id\":{\"S\":\"$tid\"},\"seen_date\":{\"S\":\"$TODAY\"}}}},"
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

Brandon wants to see:
- Claude Code best practices — how to use it better, tips, workflows, what power users are doing
- Kiro CLI best practices — how people are using it, tips, what's new
- How people are using AI to solve REAL problems (not hype, actual use cases)
- Agent skills (SKILL.md files) — what's popular, what are people installing and using
- What's happening in AI — latest breakthroughs, new tools, what people are excited about
- MCP servers, tool integrations, agent architectures
- AWS news and services (Amazon Connect, Bedrock, Lambda, new launches) — Brandon works at AWS
- SpaceX launches, milestones, engineering achievements
- Tesla, FSD, robotaxi, Boring Company news and progress
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
- Non-English content
- Pure entertainment (sports, memes)
- Retweets without added commentary
- Courses/giveaways/engagement bait
- Company drama or stock price speculation

Score each tweet 1-10. A 10 is something Brandon would stop scrolling to read and maybe act on. A 7 is solid, worth including. Below 7 is noise.
Reply ONLY with a JSON array of integers. Example: [8,2,7,1,9,3,5]

Tweets:
${tweets_text}"

  # Run from $HOME so kiro-cli picks up ~/.kiro/agents/default.json
  timeout 60 bash -c "cd \$HOME && kiro-cli chat --no-interactive --wrap never \"\$1\"" -- "$prompt" 2>&1 | \
    sed 's/\x1b\[[0-9;]*m//g' | grep -oP '\[[\d,\s]+\]' | head -1
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
        print(f'{tid}\t{username}\t{name}\t{likes}\t{rts}\t{created}\t{text[:300]}')
    except (KeyError, TypeError):
        pass
")

TOTAL_RAW=$(echo "$TWEETS_TSV" | grep -c '.' || echo 0)
log "Parsed $TOTAL_RAW tweets (promoted/RTs filtered)"

# Dedup against DynamoDB
FRESH_TSV=""
SKIPPED=0
while IFS=$'\t' read -r tid user name likes rts created text; do
  [ -z "$tid" ] && continue
  if is_seen "$tid"; then
    SKIPPED=$((SKIPPED + 1))
  else
    FRESH_TSV="${FRESH_TSV}${tid}\t${user}\t${name}\t${likes}\t${rts}\t${created}\t${text}\n"
  fi
done <<< "$TWEETS_TSV"

FRESH_COUNT=$(echo -e "$FRESH_TSV" | grep -c '.' || echo 0)
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
  while IFS=$'\t' read -r tid user name likes rts created text; do
    [ -z "$tid" ] && continue
    NUMBERED="${NUMBERED}${i}. @${user} (${likes} likes): ${text}\n"
    i=$((i + 1))
  done <<< "$(echo -e "$FRESH_TSV")"

  log "Scoring $FRESH_COUNT tweets via kiro-cli..."
  SCORES=$(score_tweets "$(echo -e "$NUMBERED")")

  if [ -z "$SCORES" ]; then
    # Fail-closed: don't flood Discord with unscored tweets.
    alert_discord "⚠️ **x-digest scoring failed** — kiro-cli returned no scores for $FRESH_COUNT tweets.
No digest sent. Raw tweets in \`/tmp/x-digest/digest-${TODAY}.md\` on EC2.
Tweets are NOT marked seen — they will be re-evaluated next run."
    log "FATAL: LLM scoring returned empty — aborting without marking tweets seen"
    exit 1
  fi

  log "Scores: $SCORES"

  # Adaptive threshold: if fewer than 3 posts meet ≥7, lower threshold to the
  # 3rd-highest score so the digest is never near-empty on slow days. Quality
  # bar stays at 7 for normal days, falls back to top-3 on thin days.
  EFFECTIVE_THRESHOLD="$RELEVANCE_THRESHOLD"
  ADAPTIVE_NOTE=""
  COUNT_AT_THRESHOLD=$(echo "$SCORES" | jq "[.[] | select(. >= $RELEVANCE_THRESHOLD)] | length" 2>/dev/null || echo 0)
  if [ "$COUNT_AT_THRESHOLD" -lt 3 ] && [ "$FRESH_COUNT" -ge 3 ]; then
    THIRD_HIGHEST=$(echo "$SCORES" | jq "[.[]] | sort | reverse | .[2]" 2>/dev/null)
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
  INCLUDED=0
  i=0
  while IFS=$'\t' read -r tid user name likes rts created text; do
    [ -z "$tid" ] && continue
    score=$(echo "$SCORES" | jq -r ".[$i] // 0" 2>/dev/null || echo "5")
    if [ "$score" -ge "$EFFECTIVE_THRESHOLD" ] 2>/dev/null; then
      # Format date
      cdt=$(TZ='America/Chicago' date -d "$created" '+%a %b %d, %l:%M %p CDT' 2>/dev/null || echo "$created")
      {
        echo "**@${user}** ($name) — ${likes} likes, ${rts} RTs — ${cdt}"
        echo "${text}"
        echo "https://x.com/${user}/status/${tid}"
        echo ""
      } >> "$DIGEST_FILE"
      INCLUDED=$((INCLUDED + 1))
      echo "$tid" >> "$MARK_FILE"
    else
      # Still mark low-scoring tweets as seen so they don't reappear
      echo "$tid" >> "$MARK_FILE"
    fi
    i=$((i + 1))
  done <<< "$(echo -e "$FRESH_TSV")"

  {
    echo "---"
    echo "_${FRESH_COUNT} new posts evaluated, ${INCLUDED} surfaced (score ≥ ${EFFECTIVE_THRESHOLD}/10), ${SKIPPED} previously seen skipped.${ADAPTIVE_NOTE}_"
  } >> "$DIGEST_FILE"

  # Mark all evaluated tweets as seen
  batch_mark_seen "$MARK_FILE"
  rm -f "$MARK_FILE"

  log "Digest: $INCLUDED tweets surfaced from $FRESH_COUNT new"
fi

# --- Send to Discord ---
DISCORD_CHANNEL="${DIGEST_DISCORD_CHANNEL:-1503414103341797406}"
DISCORD_TOKEN=$(jq -r '.channels.discord.token // empty' ~/.openclaw/openclaw.json 2>/dev/null)
if [ -n "$DISCORD_TOKEN" ]; then
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
TODAY_LABEL=$(date '+%a %b %d, %Y')
gog gmail send -a brandon.tyler@gmail.com \
  --to "brandon.tyler@gmail.com" \
  --subject "📱 X Digest — $TODAY_LABEL" \
  --body "$(cat "$DIGEST_FILE")" 2>/dev/null && log "Email sent" || log "Email failed"

log "Done. Digest: $DIGEST_FILE"
cat "$DIGEST_FILE"
