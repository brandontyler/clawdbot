#!/usr/bin/env bash
# Sermon Notes Auto-Print
# Scrapes Denton Bible's latest sermon notes PDF and emails it to HP ePrint.
# Runs Sunday mornings via systemd timer.
set -Eeuo pipefail

BASE="https://dentonbible.org"
PUB_URL="$BASE/media/publications/?category=this-week"
PRINT_EMAIL="Brandon.Tyler@hpeprint.com"
FROM="noreply@tylerbtt.email.connect.aws"
PROFILE="personal"
REGION="us-east-1"
DISCORD_CHANNEL="1503414103341797406"
PROJECT_DIR="$HOME/code/personal/clawdbot"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

post_discord() {
  # Post directly via Discord REST API — same pattern x-digest-foryou.sh uses.
  # Avoids the stale `node dist/index.js` path and the system openclaw CLI's
  # missing-plugin warnings; both were silently failing pre-2026-06-14.
  local msg="$1"
  local token
  token=$(jq -r '.channels.discord.token // empty' ~/.openclaw/openclaw.json 2>/dev/null)
  if [ -z "$token" ]; then
    return 0
  fi
  curl -sS -o /dev/null -X POST \
    "https://discord.com/api/v10/channels/$DISCORD_CHANNEL/messages" \
    -H "Authorization: Bot $token" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg c "$msg" '{content: $c}')" || true
}

# Safety net: catch any unexpected non-zero exit (silent failures, broken pipes,
# upstream HTML changes that bypass our explicit error branches) and post to
# Discord so silent-fail-mode can't bite us again. Explicit error branches set
# EXPECTED_FAIL=1 first to suppress double-posting.
EXPECTED_FAIL=0
on_unexpected_error() {
  local exit_code=$?
  local line=${BASH_LINENO[0]:-?}
  local cmd=${BASH_COMMAND:-?}
  if [ "$EXPECTED_FAIL" = "1" ]; then
    return
  fi
  log "UNEXPECTED ERROR at line $line (exit $exit_code): $cmd"
  post_discord "⚠️ Sermon notes print hit an unexpected error at line $line (exit $exit_code): \`$cmd\`"
  exit "$exit_code"
}
trap on_unexpected_error ERR

# Step 1: Get first article link from publications page
log "Fetching $PUB_URL"
ARTICLE_PATH=$(curl -sL "$PUB_URL" | grep -oP 'href="/article/[^"]+' | head -1 | sed 's/href="//')
if [[ -z "$ARTICLE_PATH" ]]; then
  log "ERROR: No article found on publications page"
  post_discord "⚠️ Sermon notes print failed: no article found on publications page"
  EXPECTED_FAIL=1
  exit 1
fi
ARTICLE_URL="$BASE$ARTICLE_PATH"
log "Found article: $ARTICLE_URL"

# Step 2: Get PDF link from article page
# Match both S3 URL styles:
#   - path-style:           https://s3.amazonaws.com/account-media/21140/uploaded/...
#   - virtual-hosted-style: https://account-media.s3.amazonaws.com/21140/uploaded/...
# Denton Bible flipped from path-style to virtual-hosted-style sometime before 2026-06-14.
PDF_URL=$(curl -sL "$ARTICLE_URL" | grep -oP 'https://(s3\.amazonaws\.com/account-media|account-media\.s3\.amazonaws\.com)/21140/uploaded/[^"]+\.pdf' | head -1)
if [[ -z "$PDF_URL" ]]; then
  log "ERROR: No PDF found on $ARTICLE_URL"
  post_discord "⚠️ Sermon notes print failed: no PDF found at $ARTICLE_URL"
  EXPECTED_FAIL=1
  exit 1
fi
log "Found PDF: $PDF_URL"

# Step 3: Download PDF
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
PDF_FILE="$TMPDIR/sermon-notes.pdf"
curl -sL "$PDF_URL" -o "$PDF_FILE"
PDF_SIZE=$(stat -c%s "$PDF_FILE")
log "Downloaded PDF: ${PDF_SIZE} bytes"

if (( PDF_SIZE < 1000 )); then
  log "ERROR: PDF too small (${PDF_SIZE} bytes), likely a bad download"
  post_discord "⚠️ Sermon notes print failed: PDF download was only ${PDF_SIZE} bytes"
  EXPECTED_FAIL=1
  exit 1
fi

# Step 4: Base64 encode and email to HP ePrint via SES
B64=$(base64 -w0 "$PDF_FILE")
TITLE=$(echo "$ARTICLE_PATH" | sed 's|/article/||; s/-/ /g')

# Send PDF to HP ePrint via gog gmail (with attachment)
if gog gmail send -a brandon.tyler@gmail.com \
  --to "$PRINT_EMAIL" \
  --subject "Sermon Notes - $TITLE" \
  --body "Sermon notes attached." \
  --attach "$PDF_FILE" 2>&1; then
  log "Emailed PDF to $PRINT_EMAIL via gog"
else
  log "ERROR: gog gmail send failed — retrying in 30s..."
  sleep 30
  gog gmail send -a brandon.tyler@gmail.com \
    --to "$PRINT_EMAIL" \
    --subject "Sermon Notes - $TITLE" \
    --body "Sermon notes attached." \
    --attach "$PDF_FILE" 2>&1
  log "Retry sent to $PRINT_EMAIL via gog"
fi

# Generate sermon topic summary via kiro-cli
log "Generating sermon summary..."
PDF_TEXT=$(python3 -c "
import PyPDF2, sys
try:
    reader = PyPDF2.PdfReader('$PDF_FILE')
    text = ' '.join(page.extract_text() or '' for page in reader.pages[:3])
    print(text[:1500])
except: pass
" 2>/dev/null | tr -d '"\\`$')
SUMMARY=""
if [ -n "$PDF_TEXT" ]; then
  SUMMARY=$(cd "$HOME" && timeout 60 kiro-cli chat --no-interactive --wrap never "Summarize this sermon in 2-3 sentences. What is the main topic, key scripture, and one takeaway? Be concise.

${PDF_TEXT}" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -v "^$" | grep -v "Credits:\|Time:" | tail -5 | head -3)
fi

if [ -n "$SUMMARY" ]; then
  post_discord "🖨️ Sermon notes sent to printer: **$TITLE** ($((PDF_SIZE / 1024))KB)

📝 ${SUMMARY}"
else
  post_discord "🖨️ Sermon notes sent to printer: **$TITLE** ($((PDF_SIZE / 1024))KB)"
fi
