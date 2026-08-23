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
# Independent study cover page (added 2026-07-26, Brandon req):
# After identifying the primary sermon PDF we (1) detect the main Bible passage
# from the notes text, (2) ask the #sermon Discord channel agent — via the
# bridge-send A2A skill — to build an ORIGINAL exegetical study of that passage
# (Hebrew/Greek word work, context, structure, cross-refs, questions, takeaway),
# and (3) print that study as the email body = cover page ahead of the notes PDF.
# HP ePrint prints the email body as page 1, so the study becomes the cover
# sheet. If passage detection or the #sermon bridge fails, the cover page
# gracefully falls back to the short 2-3 sentence summary, then to a generic line.
#
# Dry run:
#   scripts/sermon-notes-print.sh --dry-run
# Prints what WOULD be sent (article + PDF URL + filename + size) and the
# detected passage, without calling the study agent, emailing, or posting.
#
# Preview (test the full study path without printing):
#   scripts/sermon-notes-print.sh --preview [email]
# Runs the whole pipeline (scrape, detect passage, build study via #sermon) but
# emails ONLY the assembled study cover page to the preview address (default
# brandon.tyler@gmail.com) instead of the printer, and skips the Discord post.
set -Eeuo pipefail

DRY_RUN=0
PREVIEW=0
PREVIEW_EMAIL="brandon.tyler@gmail.com"
case "${1:-}" in
  --dry-run|-n) DRY_RUN=1 ;;
  --preview)    PREVIEW=1; [[ -n "${2:-}" ]] && PREVIEW_EMAIL="$2" ;;
esac

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

# Ask the #sermon channel agent (via the bridge-send A2A skill) to build an
# ORIGINAL exegetical study of a passage. Prints the study text to stdout.
# Fully non-fatal: any failure (missing bridge-send, timeout, empty reply)
# degrades to empty stdout so the caller can fall back. Diagnostics go to
# stderr so they don't contaminate the captured study text.
build_sermon_study() {
  local passage="$1" theme="${2:-}"
  [[ -n "$passage" ]] || { printf ''; return 0; }
  if ! command -v bridge-send >/dev/null 2>&1; then
    log "  study: bridge-send not on PATH — skipping" 1>&2
    printf ''; return 0
  fi

  local qfile rfile out rc=0
  qfile=$(mktemp); rfile=$(mktemp)
  {
    echo "Weekly automated sermon-study request from #openclaw-ec2 (Brandon's Sunday print pipeline)."
    echo
    echo "This Sunday's Denton Bible teaching is on: ${passage}"
    [[ -n "$theme" ]] && echo "Sermon title/theme (context only): ${theme}"
    echo
    echo "Build an original, careful exegetical study of ${passage} using your own resources. Do the real work in the text — don't just summarize a commentary. This is an INDEPENDENT study Brandon reads alongside the preached sermon so he can compare. Include, in order:"
    echo
    echo "1. PASSAGE OVERVIEW — one paragraph: who, where, when in the book's flow."
    echo "2. GENRE AND HOW IT SHAPES READING — name the genre and how it should govern the reading (e.g. narrative teaches via plot, characterization, and the narrator's verdicts, not verse-by-verse propositions; an epistle argues; poetry works by imagery/parallelism)."
    echo "3. WORD WORK — 4-6 key Hebrew or Greek terms/phrases: transliteration, gloss, and why the word choice matters. Note LXX/NT echoes where relevant."
    echo "4. HISTORICAL & LITERARY CONTEXT."
    echo "5. STRUCTURE — a clean outline of the passage's movements."
    echo "6. CROSS-REFERENCES — the most important intertextual links, one line each."
    echo "7. INTERPRETIVE QUESTIONS — 4-6 good study/discussion questions."
    echo "8. TEACHING SYNTHESIS — a one-line BIG IDEA (subject + complement, per Haddon Robinson), a FALLEN CONDITION FOCUS (the human condition the text addresses, per Bryan Chapell), and a one-line REDEMPTIVE TRAJECTORY (how the passage points to Christ / the gospel)."
    echo "9. THEOLOGICAL TAKEAWAY — 2-3 sentences on the enduring point."
    echo
    echo "FORMAT: plain readable text for a printed 1-2 page study cover sheet. Simple ALL-CAPS or numbered section headers, short paragraphs, hyphen bullets. NO Discord markdown (no ##, no **bold**, no backticks). Aim 800-1100 words. Begin your reply DIRECTLY with the study title line — no preamble sentence, no sign-off, no '---' separators. Research/writing only: do not edit files or take any actions."
  } > "$qfile"

  log "  study: asking #sermon to build a study of '${passage}' (waiting up to 600s)..." 1>&2
  out=$(bridge-send sermon "$(cat "$qfile")" --timeout 600 --from openclaw-ec2 --no-echo-reply 2>>"$rfile") || rc=$?
  if (( rc != 0 )); then
    log "  study: bridge-send exited ${rc}: $(tail -1 "$rfile" 2>/dev/null)" 1>&2
  fi
  rm -f "$qfile" "$rfile"

  # Belt-and-suspenders: if a conversational preamble + '---' fence slipped in
  # despite the instruction, keep only what follows the fence.
  if printf '%s\n' "$out" | head -6 | grep -q '^[[:space:]]*---[[:space:]]*$'; then
    out=$(printf '%s\n' "$out" | sed -n '/^[[:space:]]*---[[:space:]]*$/,$p' | sed '1d')
  fi
  printf '%s' "$out"
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

# Step 2: For each article, follow the link and extract its first sermon media
# file. Denton publishes notes as PDF *or* DOCX (e.g. 2026-08-23 the notes were
# a .docx: sermon-notes-082326.docx). Matching pdf-only silently skipped the
# real sermon article and let a stale reading-resources book-list PDF win the
# selection, so match pdf|docx|doc (docx before doc so the longer ext wins).
# Match both S3 URL styles (path- and virtual-hosted-style).
MEDIA_RE='https://(s3\.amazonaws\.com/account-media|account-media\.s3\.amazonaws\.com)/21140/uploaded/[^"]+\.(pdf|docx|doc)'

declare -a MATCH_URLS=()      # filtered PDFs (filename contains SERMON_FILENAME_MATCH)
declare -a MATCH_TITLES=()
declare -a MATCH_DATES=()     # YYMMDD parsed from each match filename (current-week filter)
declare -a ALL_URLS=()        # every PDF we found, for the fallback path
declare -a ALL_TITLES=()

for ap in "${ARTICLE_PATHS[@]}"; do
  aurl="$BASE$ap"
  pdf=$(curl -sL "$aurl" | grep -oP "$MEDIA_RE" | head -1 || true)
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

  # Filter: only keep sermon-notes-*.pdf, capturing the MMDDYY date token.
  if [[ "$fname" == *"$SERMON_FILENAME_MATCH"* ]]; then
    MATCH_URLS+=("$pdf"); MATCH_TITLES+=("$title")
    d=$(echo "$fname" | grep -oP 'sermon-notes-\K[0-9]{6}' | head -1 || true)
    if [[ -n "$d" ]]; then
      MATCH_DATES+=("${d:4:2}${d:0:2}${d:2:2}")   # MMDDYY -> YYMMDD for chronological compare
    else
      MATCH_DATES+=("")
    fi
  fi
done

# Restrict to the CURRENT week only. The this-week page can keep a PRIOR week's
# companion item linked (e.g. /article/reading-resources still points at last
# week's sermon-notes-<date>-book-list.pdf) after a new sermon posts. Sermon PDFs
# are named sermon-notes-<MMDDYY>, so keep only those whose date equals the most
# recent date among matches: same-week items (sermon + book-list) all print;
# stale prior-week leftovers are dropped. (Fix 2026-07-12.)
if (( ${#MATCH_URLS[@]} > 0 )); then
  latest=""
  for d in "${MATCH_DATES[@]}"; do
    [[ -n "$d" ]] || continue
    if [[ -z "$latest" || "$d" > "$latest" ]]; then latest="$d"; fi
  done
  if [[ -n "$latest" ]]; then
    declare -a CUR_URLS=() CUR_TITLES=()
    for j in "${!MATCH_URLS[@]}"; do
      if [[ "${MATCH_DATES[$j]}" == "$latest" ]]; then
        CUR_URLS+=("${MATCH_URLS[$j]}"); CUR_TITLES+=("${MATCH_TITLES[$j]}")
      else
        log "  drop stale prior-week item: $(basename "${MATCH_URLS[$j]}") (older than current week $latest)"
      fi
    done
    MATCH_URLS=("${CUR_URLS[@]}"); MATCH_TITLES=("${CUR_TITLES[@]}")
    log "Current week 20${latest:0:2}-${latest:2:2}-${latest:4:2} -> ${#MATCH_URLS[@]} item(s) after date filter"
  fi
fi

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

# Step 3: Download all PDFs first, so the sermon summary can be generated
# BEFORE sending — HP ePrint prints the email body as the cover page, so we
# make that body the sermon summary instead of a generic line. (Brandon req
# 2026-07-26.)
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
MAX_BYTES=$((9 * 1024 * 1024))
SUCCESS_COUNT=0
FAILURE_COUNT=0
declare -a REPORT_LINES=()
declare -a SEND_PATHS=() SEND_TITLES=() SEND_FNAMES=() SEND_SIZES=()

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

  SEND_PATHS+=("$local_pdf"); SEND_TITLES+=("$title")
  SEND_FNAMES+=("$fname"); SEND_SIZES+=("$size")
done

# Step 3b: Pick the primary sermon PDF and generate the summary NOW (before
# sending) so it can serve as BOTH the printed cover page and the Discord note.
PRIMARY_PDF=""
PRIMARY_TITLE=""
for j in "${!SEND_PATHS[@]}"; do
  f="${SEND_FNAMES[$j]}"
  # Primary = the plain sermon-notes-<date>.pdf (not the companion book list).
  if [[ "$f" != *"book-list"* && "$f" != *"reading"* ]]; then
    PRIMARY_PDF="${SEND_PATHS[$j]}"; PRIMARY_TITLE="${SEND_TITLES[$j]}"; break
  fi
done
if [[ -z "$PRIMARY_PDF" && ${#SEND_PATHS[@]} -gt 0 ]]; then
  PRIMARY_PDF="${SEND_PATHS[0]}"; PRIMARY_TITLE="${SEND_TITLES[0]}"
fi

SUMMARY=""
# Extract PDF text once (first 3 pages) for BOTH the short summary and passage
# detection. Cheap local parse — safe to run even in dry-run.
PDF_TEXT=""
if [[ -n "$PRIMARY_PDF" && -f "$PRIMARY_PDF" ]]; then
  PDF_TEXT=$(PRIMARY_PDF="$PRIMARY_PDF" python3 <<'PY' 2>/dev/null
import os, re, html, zipfile
p = os.environ["PRIMARY_PDF"]
ext = os.path.splitext(p)[1].lower()
text = ""
try:
    if ext == ".docx":
        # .docx is a zip of XML — extract paragraph text with the stdlib only
        # (no python-docx dependency). Sermon notes are now sometimes DOCX.
        with zipfile.ZipFile(p) as z:
            xml = z.read("word/document.xml").decode("utf-8", "ignore")
        xml = re.sub(r"</w:p>", "\n", xml)     # paragraph breaks
        text = html.unescape(re.sub(r"<[^>]+>", "", xml))  # strip tags
    else:
        import PyPDF2
        reader = PyPDF2.PdfReader(p)
        text = " ".join(page.extract_text() or "" for page in reader.pages[:3])
except Exception:
    text = ""
# Drop chars that would break later interpolation into the LLM prompt strings.
text = text.translate({ord(c): None for c in '"`$\\'})
print(text[:1500])
PY
)
fi

# Detect the primary Bible passage from the notes (for logging + to hand to the
# #sermon study agent). The model is told to reply with only the reference; we
# also regex-extract as a safety net and normalize en/em dashes. Non-fatal.
PASSAGE_REF=""
if [[ -n "$PDF_TEXT" ]]; then
  PASSAGE_REF=$(cd "$HOME" && timeout 60 kiro-cli chat --no-interactive --wrap never "From these sermon notes, identify the single primary Bible passage being taught. Reply with ONLY the reference in the form Book Chapter:Verses (for example: 1 Kings 12:25-33). No other words.

${PDF_TEXT}" 2>&1 | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g; s/[–—]/-/g' | grep -v "^$" | grep -v "Credits:\|Time:" | grep -oiE '([1-3][[:space:]])?[A-Za-z]+[[:space:]]+[0-9]+:[0-9]+(-[0-9]+)?' | head -1) || PASSAGE_REF=""
  if [[ -n "$PASSAGE_REF" ]]; then
    log "Detected passage: $PASSAGE_REF"
  else
    log "Could not detect a passage reference from the notes"
  fi
fi

# Short 2-3 sentence summary for the Discord notification.
if [[ -n "$PDF_TEXT" ]] && (( ! DRY_RUN )); then
  log "Generating sermon summary from $PRIMARY_TITLE..."
  SUMMARY=$(cd "$HOME" && timeout 60 kiro-cli chat --no-interactive --wrap never "Summarize this sermon in 2-3 sentences. What is the main topic, key scripture, and one takeaway? Be concise.

${PDF_TEXT}" 2>&1 | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' | grep -v "^$" | grep -v "Credits:\|Time:" | tail -5 | head -3) || SUMMARY=""
fi

# Ask the #sermon channel agent to build an INDEPENDENT study of the passage
# (bridge-send A2A). Printed as the cover page ahead of the notes PDF. Any
# failure degrades gracefully to the short summary cover. (Brandon req 2026-07-26)
STUDY=""
if [[ -n "$PASSAGE_REF" ]] && (( ! DRY_RUN )); then
  STUDY=$(build_sermon_study "$PASSAGE_REF" "$PRIMARY_TITLE")
  if [[ -n "$STUDY" ]]; then
    log "Study built for $PASSAGE_REF (${#STUDY} chars)"
  else
    log "Study unavailable — cover page will fall back to the short summary"
  fi
elif (( DRY_RUN )); then
  log "[DRY RUN] would ask #sermon to build a study of: ${PASSAGE_REF:-<passage undetected>}"
fi

# Preview mode: send ONLY the assembled study cover page to a preview address
# (default Brandon's Gmail) instead of the printer, then stop. Lets us see how
# the printed cover page will look on Sunday without touching the printer.
if (( PREVIEW )); then
  cover="Sermon Study - ${PRIMARY_TITLE}"
  if [[ -n "$STUDY" ]]; then
    pv_body="================================================================
  PREVIEW ONLY - this was NOT sent to the printer.
  This is how the study cover page (page 1) will print on Sunday,
  ahead of the sermon-notes PDF.
  Passage detected: ${PASSAGE_REF:-<none>}
================================================================

${cover}

${STUDY}"
  else
    pv_body="PREVIEW: study unavailable (passage: ${PASSAGE_REF:-<none>}). Check the journal logs for the #sermon bridge result."
  fi
  log "Preview: emailing study cover page to $PREVIEW_EMAIL (not the printer)"
  if gog gmail send -a brandon.tyler@gmail.com \
      --to "$PREVIEW_EMAIL" \
      --subject "[PREVIEW] Sermon Study Cover Page - ${PASSAGE_REF:-passage} (not printed)" \
      --body "$pv_body"; then
    log "Preview email sent to $PREVIEW_EMAIL."
  else
    log "Preview email FAILED (see gog output above)."
  fi
  log "Preview mode done — nothing printed, no Discord post."
  exit 0
fi

# Step 3c: Send each PDF. The primary sermon email body = the summary (so the
# printed cover page is the useful summary, not a generic line). Companion
# items (book list) keep a short generic body.
for j in "${!SEND_PATHS[@]}"; do
  local_pdf="${SEND_PATHS[$j]}"
  title="${SEND_TITLES[$j]}"
  fname="${SEND_FNAMES[$j]}"
  size="${SEND_SIZES[$j]}"

  body="Sermon notes attached."
  if [[ "$local_pdf" == "$PRIMARY_PDF" ]]; then
    if [[ -n "$STUDY" ]]; then
      body="Sermon Study — ${title}
(Independent study prepared by the #sermon agent — read alongside the sermon notes that follow.)

${STUDY}"
    elif [[ -n "$SUMMARY" ]]; then
      body="Sermon Notes — ${title}

${SUMMARY}"
    fi
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
      --body "$body" \
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
        --body "$body" \
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

# Step 4: Compose Discord notification (SUMMARY generated above in Step 3b).

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
if [[ -n "$STUDY" ]]; then
  FULL_MSG="$FULL_MSG

📖 Independent study of ${PASSAGE_REF} built by #sermon and printed as the cover page."
elif [[ -n "$PASSAGE_REF" ]]; then
  FULL_MSG="$FULL_MSG

📖 Passage detected: ${PASSAGE_REF} (study unavailable this run — printed the short summary as the cover)."
fi

post_discord "$FULL_MSG"
log "Done."
