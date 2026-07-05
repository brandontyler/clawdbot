#!/usr/bin/env bash
# Sermon Notes Auto-Print
# Scrapes Denton Bible's latest sermon notes PDF(s) and emails each one to
# HP ePrint. Runs Sunday mornings via systemd timer.
#
# HP ePrint constraints (per HP's own confirmation email — captured 2026-07-05):
#   1. Total size of all attachments must be ≤ 10 MB
#   2. Maximum of 10 attachments per email
#   3. Printer must be online
#   4. Slow email delivery / internet may delay the print job
#   5. Printer owner (Brandon.Tyler@gmail.com's HP Smart account) must have
#      permitted the sending address
# HP Smart account owner receives a confirmation email at Brandon.Tyler@gmail.com
# for each job. Confirmations can be turned off at www.hpsmart.com → Change
# Settings → uncheck "Get notified when an ePrint is sent" (currently enabled).
# See www.hp.com/go/eprinthelp for troubleshooting.
#
# Multi-item handling (added 2026-07-05):
# The publications page can list multiple articles this-week (e.g. the sermon
# plus a companion "Reading Resources" book list). We iterate over ALL articles,
# extract each PDF, and print any whose filename matches `sermon-notes*`. This
# skips evergreen items like "Read the Bible in a Year Plan" that live on the
# same category page permanently. Safety net: if no sermon-notes-*.pdf matches,
# we fall back to printing the first PDF found (preserves pre-fix behavior).
#
# Dry run:
#   scripts/sermon-notes-print.sh --dry-run
# Prints what WOULD be sent (article + PDF URL + filename + size) without
# emailing anything or posting to Discord.
set -Eeuo pipefail

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" || "${1:-}" == "-n" ]]; then
  DRY_RUN=1
fi

BASE="https://dentonbible.org"
PUB_URL="$BASE/media/publications/?category=this-week"
PRINT_EMAIL="Brandon.Tyler@hpeprint.com"
FROM="noreply@tylerbtt.email.connect.aws"
PROFILE="personal"
REGION="us-east-1"
DISCORD_CHANNEL="1503414103341797406"
PROJECT_DIR="$HOME/code/personal/clawdbot"

# Filter: only print PDFs whose filename contains this substring. Anything
# else on the this-week page (like "read-the-bible-in-a-year-plan.pdf") is
# assumed evergreen and skipped.
SERMON_FILENAME_MATCH="sermon-notes"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

post_discord() {
  # Post directly via Discord REST API — same pattern x-digest-foryou.sh uses.
  local msg="$1"
  if (( DRY_RUN )); then
    log "[DRY RUN] would post to Discord: $msg"
    return 0
  fi
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

# Safety net for silent failures / upstream HTML shape changes.
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

# Step 1: Enumerate all article links on the this-week publications page.
log "Fetching $PUB_URL"
PUB_HTML=$(curl -sL "$PUB_URL")
mapfile -t ARTICLE_PATHS < <(echo "$PUB_HTML" | grep -oP 'href="/article/[^"]+' | sed 's/^href="//' | awk '!seen[$0]++')

if [[ ${#ARTICLE_PATHS[@]} -eq 0 ]]; then
  log "ERROR: No articles found on publications page"
  post_discord "⚠️ Sermon notes print failed: no articles on publications page"
  EXPECTED_FAIL=1
  exit 1
fi
log "Found ${#ARTICLE_PATHS[@]} article(s): ${ARTICLE_PATHS[*]}"

# Step 2: For each article, follow the link and extract its first PDF.
# Match both S3 URL styles (path- and virtual-hosted-style).
PDF_RE='https://(s3\.amazonaws\.com/account-media|account-media\.s3\.amazonaws\.com)/21140/uploaded/[^"]+\.pdf'

declare -a MATCH_URLS=()      # filtered PDFs (filename contains SERMON_FILENAME_MATCH)
declare -a MATCH_TITLES=()
declare -a ALL_URLS=()        # every PDF we found, for the fallback path
declare -a ALL_TITLES=()

for ap in "${ARTICLE_PATHS[@]}"; do
  aurl="$BASE$ap"
  pdf=$(curl -sL "$aurl" | grep -oP "$PDF_RE" | head -1 || true)
  if [[ -z "$pdf" ]]; then
    log "  $ap → no PDF"
    continue
  fi
  # Dedupe on URL
  local_seen=0
  for existing in "${ALL_URLS[@]:-}"; do
    if [[ "$existing" == "$pdf" ]]; then local_seen=1; break; fi
  done
  if (( local_seen )); then continue; fi

  fname=$(basename "$pdf")
  title=$(echo "$ap" | sed 's|/article/||; s/-/ /g')
  ALL_URLS+=("$pdf"); ALL_TITLES+=("$title")
  log "  $ap → $fname"

  # Filter: only keep sermon-notes-*.pdf
  if [[ "$fname" == *"$SERMON_FILENAME_MATCH"* ]]; then
    MATCH_URLS+=("$pdf"); MATCH_TITLES+=("$title")
  fi
done

# Decide which set to actually print.
if (( ${#MATCH_URLS[@]} > 0 )); then
  PRINT_URLS=("${MATCH_URLS[@]}"); PRINT_TITLES=("${MATCH_TITLES[@]}")
  log "Filtered to ${#PRINT_URLS[@]} sermon-notes PDF(s)"
elif (( ${#ALL_URLS[@]} > 0 )); then
  # Fallback: print just the first PDF (preserves pre-fix behavior)
  PRINT_URLS=("${ALL_URLS[0]}"); PRINT_TITLES=("${ALL_TITLES[0]}")
  log "No sermon-notes-*.pdf match — falling back to first PDF: ${PRINT_URLS[0]}"
else
  log "ERROR: no PDFs found on any article"
  post_discord "⚠️ Sermon notes print failed: no PDFs on any of ${#ARTICLE_PATHS[@]} article(s)"
  EXPECTED_FAIL=1
  exit 1
fi

# Step 3: Download + send each PDF.
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
MAX_BYTES=$((9 * 1024 * 1024))
SUCCESS_COUNT=0
FAILURE_COUNT=0
declare -a REPORT_LINES=()

for i in "${!PRINT_URLS[@]}"; do
  url="${PRINT_URLS[$i]}"
  title="${PRINT_TITLES[$i]}"
  fname=$(basename "$url")
  local_pdf="$TMPDIR/$fname"

  curl -sL "$url" -o "$local_pdf"
  size=$(stat -c%s "$local_pdf")
  log "  [$((i+1))/${#PRINT_URLS[@]}] $fname → ${size} bytes"

  if (( size < 1000 )); then
    log "  SKIP: PDF too small (${size} B)"
    REPORT_LINES+=("⚠️ SKIP $fname — download was only ${size} B")
    FAILURE_COUNT=$((FAILURE_COUNT + 1))
    continue
  fi
  if (( size > MAX_BYTES )); then
    log "  SKIP: PDF too large ($((size / 1024 / 1024)) MB > 9 MB HP limit)"
    REPORT_LINES+=("⚠️ SKIP $fname — ${size} B over 9 MB HP ePrint limit")
    FAILURE_COUNT=$((FAILURE_COUNT + 1))
    continue
  fi

  if (( DRY_RUN )); then
    log "  [DRY RUN] would send: $fname ($((size / 1024)) KB) → $PRINT_EMAIL"
    REPORT_LINES+=("[DRY RUN] $title — $fname ($((size / 1024)) KB)")
    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    continue
  fi

  # Live send via gog gmail (Brandon's authenticated Gmail — reliable path).
  if gog gmail send -a brandon.tyler@gmail.com \
      --to "$PRINT_EMAIL" \
      --subject "Sermon Notes - $title" \
      --body "Sermon notes attached." \
      --attach "$local_pdf" 2>&1; then
    log "  emailed $fname → $PRINT_EMAIL"
    REPORT_LINES+=("🖨️ $title — $fname ($((size / 1024)) KB)")
    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
  else
    log "  RETRY: gog gmail send failed for $fname, retrying in 30s..."
    sleep 30
    if gog gmail send -a brandon.tyler@gmail.com \
        --to "$PRINT_EMAIL" \
        --subject "Sermon Notes - $title" \
        --body "Sermon notes attached." \
        --attach "$local_pdf" 2>&1; then
      log "  retry sent $fname → $PRINT_EMAIL"
      REPORT_LINES+=("🖨️ $title — $fname ($((size / 1024)) KB)")
      SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
      log "  ERROR: gog gmail send failed twice for $fname"
      REPORT_LINES+=("❌ FAIL $fname — gog send failed twice")
      FAILURE_COUNT=$((FAILURE_COUNT + 1))
    fi
  fi
done

# Step 4: Compose Discord notification.
# Use the SERMON PDF (first sermon-notes filename) as the "primary" to
# summarize; skip the summary if the primary can't be text-extracted.
PRIMARY_PDF=""
PRIMARY_TITLE=""
for i in "${!PRINT_URLS[@]}"; do
  fname=$(basename "${PRINT_URLS[$i]}")
  local_pdf="$TMPDIR/$fname"
  # Heuristic: the "primary" is the one whose filename does NOT contain
  # "book-list" or "reading" — i.e. the plain sermon-notes-<date>.pdf.
  if [[ -f "$local_pdf" && "$fname" != *"book-list"* && "$fname" != *"reading"* ]]; then
    PRIMARY_PDF="$local_pdf"
    PRIMARY_TITLE="${PRINT_TITLES[$i]}"
    break
  fi
done
if [[ -z "$PRIMARY_PDF" && ${#PRINT_URLS[@]} -gt 0 ]]; then
  PRIMARY_PDF="$TMPDIR/$(basename "${PRINT_URLS[0]}")"
  PRIMARY_TITLE="${PRINT_TITLES[0]}"
fi

SUMMARY=""
if [[ -n "$PRIMARY_PDF" && -f "$PRIMARY_PDF" ]] && (( ! DRY_RUN )); then
  log "Generating sermon summary from $PRIMARY_TITLE..."
  PDF_TEXT=$(python3 -c "
import PyPDF2, sys
try:
    reader = PyPDF2.PdfReader('$PRIMARY_PDF')
    text = ' '.join(page.extract_text() or '' for page in reader.pages[:3])
    print(text[:1500])
except: pass
" 2>/dev/null | tr -d '"\\`$')
  if [ -n "$PDF_TEXT" ]; then
    SUMMARY=$(cd "$HOME" && timeout 60 kiro-cli chat --no-interactive --wrap never "Summarize this sermon in 2-3 sentences. What is the main topic, key scripture, and one takeaway? Be concise.

${PDF_TEXT}" 2>&1 | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' | grep -v "^$" | grep -v "Credits:\|Time:" | tail -5 | head -3)
  fi
fi

if (( DRY_RUN )); then
  HEADER="🧪 [DRY RUN] Sermon notes print — $SUCCESS_COUNT of ${#PRINT_URLS[@]} would print"
else
  HEADER="🖨️ Sermon notes print — $SUCCESS_COUNT printed, $FAILURE_COUNT failed"
fi

BODY_JOINED=$(printf '%s\n' "${REPORT_LINES[@]}")
FULL_MSG="$HEADER

$BODY_JOINED"
if [[ -n "$SUMMARY" ]]; then
  FULL_MSG="$FULL_MSG

📝 ${SUMMARY}"
fi

post_discord "$FULL_MSG"
log "Done."
