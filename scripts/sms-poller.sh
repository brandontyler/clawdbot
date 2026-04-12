#!/usr/bin/env bash
# SMS Commute Notes Poller
# Reads inbound SMS from SQS, saves to daily bead, sends brief confirmation.
set -euo pipefail

QUEUE_URL="https://sqs.us-east-1.amazonaws.com/035405309532/sms-inbound-queue"
PROFILE="tylerbtt"
REGION="us-east-1"
ORIGIN="+18778495397"
ALLOWED="+19405363405"
PROJECT_DIR="$HOME/code/personal/clawdbot"
BATCH_WINDOW=30
DISCORD_CHANNEL="1457570910474211587"

aws_() { aws --profile "$PROFILE" --region "$REGION" "$@"; }

post_discord() {
  cd "$PROJECT_DIR"
  node dist/index.js message send --channel discord --target "$DISCORD_CHANNEL" --message "$1" --silent 2>/dev/null || true
}

today_bead() {
  local tag="notes-$(date +%Y-%m-%d)"
  local id
  cd "$PROJECT_DIR"
  id=$(br list --json --no-auto-flush 2>/dev/null | jq -r ".[] | select(.title | contains(\"$tag\")) | .id" | head -1)
  if [[ -z "$id" ]]; then
    id=$(br create "Commute $tag" -t task -p 3 -l notes --no-auto-flush --silent 2>/dev/null)
    echo "[$(date '+%H:%M:%S')] Created bead $id" >&2
  fi
  echo "$id"
}

send_sms() {
  aws_ pinpoint-sms-voice-v2 send-text-message \
    --destination-phone-number "$1" \
    --origination-identity "$ORIGIN" \
    --message-body "$2" \
    --message-type TRANSACTIONAL --no-cli-pager >/dev/null 2>&1
}

delete_msg() {
  aws_ sqs delete-message --queue-url "$QUEUE_URL" --receipt-handle "$1" --no-cli-pager 2>/dev/null
}

# Globals for batching — use files to survive subshell boundaries
BATCH_DIR=$(mktemp -d /tmp/sms-batch.XXXXXX)
BODIES_FILE="$BATCH_DIR/bodies"
TIMES_FILE="$BATCH_DIR/times"
: > "$BODIES_FILE"
: > "$TIMES_FILE"
LAST_MSG_AT=0

batch_count() { wc -l < "$BODIES_FILE" | tr -d ' '; }

process_batch() {
  local count
  count=$(batch_count)
  (( count == 0 )) && return

  local id
  id=$(today_bead)
  cd "$PROJECT_DIR"

  local i=0
  while IFS= read -r body && IFS= read -r ts <&3; do
    i=$((i + 1))
    echo "[$(date '+%H:%M:%S')] Saving note $i/$count to $id"
    br comments add "$id" --message "$ts: $body" --author sms-poller --no-auto-flush -q || echo "  WARN: failed to save note $i"
  done < "$BODIES_FILE" 3< "$TIMES_FILE"

  if (( count == 1 )); then
    send_sms "$ALLOWED" "✓ Noted"
  else
    send_sms "$ALLOWED" "✓ $count notes saved"
  fi

  # Discord summary — AI-cleaned version
  local raw_notes=""
  while IFS= read -r body; do
    raw_notes+="- $body"$'\n'
  done < "$BODIES_FILE"

  echo "[$(date '+%H:%M:%S')] Running AI cleanup on $count note(s)..."
  local prompt="You are a note cleanup assistant. Below are raw voice-to-text SMS notes from a commute. They contain Siri transcription errors, run-on sentences, and garbled proper nouns.

Clean them up:
1. Fix obvious speech-to-text errors and misspellings
2. Fix proper nouns (e.g. 'Arama' → 'Emmaus', 'Gastown' → likely a project name — keep as-is if unsure)
3. Keep the original meaning and tone — don't add or remove ideas
4. Format as a bullet list with one clean note per bullet
5. If a note contains an action item, prefix it with ⚡
6. Be concise. No preamble, no explanation — just the cleaned bullet list.

Raw notes:
${raw_notes}"

  local cleaned
  cleaned=$(cd "$PROJECT_DIR" && echo "$prompt" | timeout 60 kiro-cli chat --no-interactive --trust-all-tools 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | grep -E '^\s*[-•⚡✦]' || echo "$raw_notes")

  local summary="📱 **${count} SMS note(s) saved to \`${id}\`**"$'\n'"${cleaned}"
  post_discord "$summary"

  echo "[$(date '+%H:%M:%S')] Saved $count note(s) to $id"

  # Clear batch
  : > "$BODIES_FILE"
  : > "$TIMES_FILE"
}

trap 'rm -rf "$BATCH_DIR"' EXIT

echo "SMS poller started. Queue: $QUEUE_URL"
echo "Allowed: $ALLOWED | Batch window: ${BATCH_WINDOW}s"

while true; do
  RESP=$(aws_ sqs receive-message \
    --queue-url "$QUEUE_URL" \
    --max-number-of-messages 10 \
    --wait-time-seconds 20 \
    --no-cli-pager 2>/dev/null || echo '{}')

  COUNT=$(echo "$RESP" | jq -r '.Messages // [] | length' 2>/dev/null || echo 0)

  if (( COUNT > 0 )); then
    echo "$RESP" | jq -c '.Messages[]' | while IFS= read -r msg; do
      HANDLE=$(echo "$msg" | jq -r '.ReceiptHandle')
      BODY=$(echo "$msg" | jq -r '.Body')

      if echo "$BODY" | jq -e '.Type == "Notification"' &>/dev/null; then
        BODY=$(echo "$BODY" | jq -r '.Message')
      fi

      FROM=$(echo "$BODY" | jq -r '.originationNumber // empty' 2>/dev/null || true)
      TEXT=$(echo "$BODY" | jq -r '.messageBody // empty' 2>/dev/null || true)

      if [[ -z "$TEXT" ]]; then
        TEXT="$BODY"
        FROM="$ALLOWED"
      fi

      if [[ "$FROM" != "$ALLOWED" ]]; then
        echo "[$(date '+%H:%M:%S')] Ignored from $FROM"
        delete_msg "$HANDLE"
        continue
      fi

      echo "[$(date '+%H:%M:%S')] SMS: $TEXT"
      echo "$TEXT" >> "$BODIES_FILE"
      echo "$(date '+%H:%M CDT')" >> "$TIMES_FILE"
      delete_msg "$HANDLE"
    done

    LAST_MSG_AT=$(date +%s)
  fi

  NOW=$(date +%s)
  BC=$(batch_count)
  if (( BC > 0 && (NOW - LAST_MSG_AT) >= BATCH_WINDOW )); then
    process_batch
  fi
done
