#!/usr/bin/env bash
# Sermon Notes Auto-Print
# Scrapes Denton Bible's latest sermon notes PDF and emails it to HP ePrint.
# Runs Sunday mornings via systemd timer.
set -euo pipefail

BASE="https://dentonbible.org"
PUB_URL="$BASE/media/publications/?category=this-week"
PRINT_EMAIL="Brandon.Tyler@hpeprint.com"
FROM="noreply@tylerbtt.email.connect.aws"
PROFILE="tylerbtt"
REGION="us-east-1"
DISCORD_CHANNEL="1475513267433767014"
PROJECT_DIR="$HOME/code/personal/clawdbot"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

post_discord() {
  cd "$PROJECT_DIR"
  node dist/index.js message send --channel discord --target "$DISCORD_CHANNEL" --message "$1" --silent 2>/dev/null || true
}

# Step 1: Get first article link from publications page
log "Fetching $PUB_URL"
ARTICLE_PATH=$(curl -sL "$PUB_URL" | grep -oP 'href="/article/[^"]+' | head -1 | sed 's/href="//')
if [[ -z "$ARTICLE_PATH" ]]; then
  log "ERROR: No article found on publications page"
  post_discord "⚠️ Sermon notes print failed: no article found on publications page"
  exit 1
fi
ARTICLE_URL="$BASE$ARTICLE_PATH"
log "Found article: $ARTICLE_URL"

# Step 2: Get PDF link from article page
PDF_URL=$(curl -sL "$ARTICLE_URL" | grep -oP 'https://s3\.amazonaws\.com/account-media/21140/uploaded/[^"]+\.pdf' | head -1)
if [[ -z "$PDF_URL" ]]; then
  log "ERROR: No PDF found on $ARTICLE_URL"
  post_discord "⚠️ Sermon notes print failed: no PDF found at $ARTICLE_URL"
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
  exit 1
fi

# Step 4: Base64 encode and email to HP ePrint via SES
B64=$(base64 -w0 "$PDF_FILE")
TITLE=$(echo "$ARTICLE_PATH" | sed 's|/article/||; s/-/ /g')

# Build raw MIME email with PDF attachment
RAW_EMAIL=$(cat <<MIME
From: $FROM
To: $PRINT_EMAIL
Subject: Sermon Notes - $TITLE
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="BOUNDARY123"

--BOUNDARY123
Content-Type: text/plain; charset=UTF-8


--BOUNDARY123
Content-Type: application/pdf; name="sermon-notes.pdf"
Content-Transfer-Encoding: base64
Content-Disposition: attachment; filename="sermon-notes.pdf"

$B64
--BOUNDARY123--
MIME
)

RAW_B64=$(echo "$RAW_EMAIL" | base64 -w0)

aws ses send-raw-email \
  --raw-message "Data=$RAW_B64" \
  --profile "$PROFILE" --region "$REGION" --no-cli-pager >/dev/null

log "Emailed PDF to $PRINT_EMAIL"
post_discord "🖨️ Sermon notes sent to printer: **$TITLE** ($((PDF_SIZE / 1024))KB)"
