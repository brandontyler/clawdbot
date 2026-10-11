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
# Multi-item handling (added 2026-07-05; tightened 2026-09-27):
# The publications page can list multiple articles this-week (e.g. the sermon
# plus a companion "Reading Resources" book list). We iterate over ALL articles,
# but print only `sermon-notes-<MMDDYY>` files dated for the applicable Sunday in
# America/Chicago. Stale, undated, and unrelated files are skipped; if a guest
# teacher publishes no notes, the job exits successfully without printing.
#
# Independent study cover page (added 2026-07-26, Brandon req):
# After identifying the primary sermon PDF we (1) detect the main Bible passage
# from the notes text, (2) run the sermon project's default agent headlessly
# and directly in that project to build an ORIGINAL exegetical study of the passage
# (Hebrew/Greek word work, context, structure, cross-refs, questions, takeaway),
# and (3) print that study as the email body = cover page ahead of the notes PDF.
# HP ePrint prints the email body as page 1, so the study becomes the cover
# sheet. If passage detection or the sermon project agent fails, the cover page
# gracefully falls back to the short 2-3 sentence summary, then to a generic line.
#
# Dry run:
#   scripts/sermon-notes-print.sh --dry-run
# Prints what WOULD be sent (article + PDF URL + filename + size) and the
# detected passage, without calling the study agent, emailing, or posting.
#
# Preview (test the full study path without printing):
#   scripts/sermon-notes-print.sh --preview [email]
# Runs the whole pipeline (scrape, detect passage, build study in the sermon project) but
# emails ONLY the assembled study cover page to the preview address (default
# brandon.tyler@gmail.com) instead of the printer, and skips the Discord post.
#
# Routing check (real Discord post, no scrape/email/print):
#   scripts/sermon-notes-print.sh --routing-check
# Sermon-agent check (direct project agent + real status post, no scrape/email/print):
#   scripts/sermon-notes-print.sh --agent-check
set -Eeuo pipefail

DRY_RUN=0
PREVIEW=0
ROUTING_CHECK=0
AGENT_CHECK=0
PREVIEW_EMAIL="brandon.tyler@gmail.com"
case "${1:-}" in
  --dry-run|-n)   DRY_RUN=1 ;;
  --preview)      PREVIEW=1; [[ -n "${2:-}" ]] && PREVIEW_EMAIL="$2" ;;
  --routing-check) ROUTING_CHECK=1 ;;
  --agent-check)   AGENT_CHECK=1 ;;
esac

BASE="https://dentonbible.org"
PUB_URL="$BASE/media/publications/?category=this-week"
PRINT_EMAIL="Brandon.Tyler@hpeprint.com"
FROM="noreply@tylerbtt.email.connect.aws"
PROFILE="personal"
REGION="us-east-1"
SERMON_CHANNEL_ID="${SERMON_NOTES_DISCORD_CHANNEL_ID:-1538537707696029757}"
DISCORD_CHANNEL="$SERMON_CHANNEL_ID"
SERMON_PROJECT_DIR="${SERMON_NOTES_PROJECT_DIR:-$HOME/code/personal/sermon}"
PROJECT_DIR="$HOME/code/personal/clawdbot"

# Filter: only print media whose filename contains this substring and whose
# embedded MMDDYY date is the applicable Sunday. Anything else on this-week is
# stale, undated, or unrelated and must fail closed.
SERMON_FILENAME_MATCH="sermon-notes"
SERMON_TIMEZONE="America/Chicago"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# Persistent timers may catch up after Sunday, so target the most recent Sunday
# rather than assuming the process itself starts on Sunday. The override keeps
# date-boundary behavior deterministic in regression tests.
REFERENCE_DATE="${SERMON_NOTES_REFERENCE_DATE:-$(TZ="$SERMON_TIMEZONE" date +%F)}"
if ! REFERENCE_DATE=$(TZ="$SERMON_TIMEZONE" date -d "$REFERENCE_DATE" +%F 2>/dev/null); then
  log "ERROR: invalid SERMON_NOTES_REFERENCE_DATE"
  exit 1
fi
REFERENCE_DOW=$(TZ="$SERMON_TIMEZONE" date -d "$REFERENCE_DATE" +%w)
CURRENT_SUNDAY=$(TZ="$SERMON_TIMEZONE" date -d "$REFERENCE_DATE -${REFERENCE_DOW} days" +%F)
CURRENT_SUNDAY_YYMMDD=$(TZ="$SERMON_TIMEZONE" date -d "$CURRENT_SUNDAY" +%y%m%d)

# Extract and normalize the first real Bible reference from model/PDF/title text.
# Supports chapter, chapter-range, verse-range, and cross-chapter forms. The
# optional second argument allows a final title-slug fallback such as
# "2 kings 18 19" -> "2 Kings 18-19" after stronger sources have failed.
extract_passage_reference() {
  local candidate="${1:-}" allow_space_range="${2:-0}"
  [[ -n "$candidate" ]] || { printf ''; return 0; }
  PASSAGE_CANDIDATE="$candidate" PASSAGE_SPACE_RANGE="$allow_space_range" python3 <<'PYREF'
import os, re
books = [
    "Genesis", "Exodus", "Leviticus", "Numbers", "Deuteronomy", "Joshua", "Judges", "Ruth",
    "1 Samuel", "2 Samuel", "1 Kings", "2 Kings", "1 Chronicles", "2 Chronicles", "Ezra",
    "Nehemiah", "Esther", "Job", "Psalms", "Psalm", "Proverbs", "Ecclesiastes",
    "Song of Solomon", "Song of Songs", "Isaiah", "Jeremiah", "Lamentations", "Ezekiel",
    "Daniel", "Hosea", "Joel", "Amos", "Obadiah", "Jonah", "Micah", "Nahum", "Habakkuk",
    "Zephaniah", "Haggai", "Zechariah", "Malachi", "Matthew", "Mark", "Luke", "John", "Acts",
    "Romans", "1 Corinthians", "2 Corinthians", "Galatians", "Ephesians", "Philippians",
    "Colossians", "1 Thessalonians", "2 Thessalonians", "1 Timothy", "2 Timothy", "Titus",
    "Philemon", "Hebrews", "James", "1 Peter", "2 Peter", "1 John", "2 John", "3 John", "Jude",
    "Revelation",
]
canonical = {re.sub(r"\s+", " ", b.lower()): b for b in books}
text = re.sub(r"\s+", " ", os.environ.get("PASSAGE_CANDIDATE", "").replace("–", "-").replace("—", "-"))
book_re = "|".join(re.escape(b) for b in sorted(books, key=len, reverse=True))
prefix = rf"(?<![A-Za-z])(?P<book>{book_re})\s+"
patterns = [
    rf"{prefix}(?P<c>\d{{1,3}}):(?P<v>\d{{1,3}})(?:-(?:(?P<ec>\d{{1,3}}):)?(?P<ev>\d{{1,3}}))?",
    rf"{prefix}(?P<c>\d{{1,3}})-(?P<endc>\d{{1,3}})",
]
match = next((m for pat in patterns if (m := re.search(pat, text, re.I))), None)
if not match and os.environ.get("PASSAGE_SPACE_RANGE") == "1":
    match = re.search(rf"{prefix}(?P<c>\d{{1,3}})\s+(?P<endc>\d{{1,3}})(?!\d)", text, re.I)
if not match:
    match = re.search(rf"{prefix}(?P<c>\d{{1,3}})", text, re.I)
if not match:
    raise SystemExit(0)
book = canonical[re.sub(r"\s+", " ", match.group("book").lower())]
c = match.group("c")
g = match.groupdict()
if g.get("v"):
    result = f"{book} {c}:{g['v']}"
    if g.get("ev"):
        result += f"-{g['ec'] + ':' if g.get('ec') else ''}{g['ev']}"
elif g.get("endc"):
    result = f"{book} {c}-{g['endc']}"
else:
    result = f"{book} {c}"
print(result)
PYREF
}

post_discord() {
  # Post directly via Discord REST API — same pattern x-digest-foryou.sh uses.
  # Normal job notices are non-fatal; routing-check passes strict=1.
  local msg="$1" strict="${2:-0}"
  if (( DRY_RUN )); then
    log "[DRY RUN] would post to Discord channel $DISCORD_CHANNEL: $msg"
    return 0
  fi
  local token status="" rc=0
  token=$(jq -r '.channels.discord.token // empty' ~/.openclaw/openclaw.json 2>/dev/null)
  if [ -z "$token" ]; then
    (( strict )) && return 1
    return 0
  fi
  status=$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
    "https://discord.com/api/v10/channels/$DISCORD_CHANNEL/messages" \
    -H "Authorization: Bot $token" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg c "$msg" '{content: $c}')") || rc=$?
  if (( rc != 0 )) || [[ ! "$status" =~ ^2[0-9][0-9]$ ]]; then
    log "Discord post failed for channel $DISCORD_CHANNEL (curl=$rc http=${status:-none})"
    (( strict )) && return 1
  fi
  return 0
}

run_sermon_agent() {
  local prompt_file="$1" timeout_seconds="${2:-600}"
  local error_file out rc=0
  [[ -f "$prompt_file" && -d "$SERMON_PROJECT_DIR" ]] || {
    log "  sermon agent: missing prompt or project directory" 1>&2
    return 2
  }
  error_file=$(mktemp)
  out=$(cd "$SERMON_PROJECT_DIR" && timeout --kill-after=10s "$timeout_seconds" \
    kiro-cli chat --agent default --effort xhigh \
      --trust-tools=fs_read,grep,glob,web_search,web_fetch \
      --no-interactive --wrap never "$(cat "$prompt_file")" 2>"$error_file") || rc=$?
  if (( rc != 0 )); then
    log "  sermon agent: kiro-cli exited $rc: $(tail -1 "$error_file" 2>/dev/null)" 1>&2
    rm -f "$error_file"
    return "$rc"
  fi
  rm -f "$error_file"
  printf '%s\n' "$out" \
    | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' \
    | sed -n '/^> /,$p' \
    | sed '1s/^> //; /^Credits:/d; /^Time:/d'
}

if (( ROUTING_CHECK )); then
  if post_discord "✅ Sermon notes print routing check — future start, completion, and error notices will appear in this sermon channel. No printer or email action was taken." 1; then
    log "Routing check posted to Discord channel $DISCORD_CHANNEL; no printer or email action was taken."
    exit 0
  fi
  log "ERROR: routing check could not post to Discord channel $DISCORD_CHANNEL; no printer or email action was taken."
  exit 1
fi

if (( AGENT_CHECK )); then
  _agent_probe=$(mktemp)
  printf '%s\n' "Reply with exactly SERMON_AGENT_OK and nothing else. Do not use tools." >"$_agent_probe"
  _agent_result=$(run_sermon_agent "$_agent_probe" 90) || _agent_rc=$?
  rm -f "$_agent_probe"
  if [[ "${_agent_rc:-0}" != "0" ]] || [[ "$_agent_result" != "SERMON_AGENT_OK" ]]; then
    log "ERROR: direct sermon-project agent check failed; no printer or email action was taken."
    exit 1
  fi
  if post_discord "✅ Sermon content agent check — ran headlessly inside the sermon project with no Discord bridge. No printer or email action was taken." 1; then
    log "Direct sermon-project agent check passed; no printer or email action was used, and no Discord bridge was used."
    exit 0
  fi
  log "ERROR: sermon agent passed but status post failed; no printer or email action was taken."
  exit 1
fi

# Run the sermon project's default agent directly to build an ORIGINAL exegetical
# study of a passage. Prints the study text to stdout. Fully non-fatal: a timeout,
# missing CLI/project, or empty reply degrades to empty stdout for fallback.
build_sermon_study() {
  local passage="$1" theme="${2:-}"
  [[ -n "$passage" ]] || { printf ''; return 0; }

  # Preferred: PSR's GROUNDED passage-study endpoint — the study is built from the
  # tagged Hebrew/Greek text + lexicon, TSK cross-references, and public-domain
  # commentaries, then citation-verified, so it can't hallucinate word work or
  # references (sermon-sermon-study-quality-kch). Falls back to the local agent.
  local _psr_api="https://psr-functions-dev.azurewebsites.net"
  local _admin_key
  _admin_key=$(grep -h '^ADMIN_KEY=' "$HOME/code/personal/sermon/.env" 2>/dev/null | head -1 | cut -d= -f2-)
  if [[ -n "$_admin_key" ]] && command -v jq >/dev/null 2>&1; then
    log "  study: requesting GROUNDED study from PSR for '${passage}'..." 1>&2
    local _body _resp _grounded
    _body=$(jq -n --arg r "$passage" --arg t "$theme" '{ref:$r, title:$t}')
    _resp=$(curl -sS -X POST "$_psr_api/api/passage-study" \
      -H "x-admin-key: $_admin_key" -H "Content-Type: application/json" \
      -d "$_body" --max-time 220 2>/dev/null) || _resp=""
    _grounded=$(printf '%s' "$_resp" | jq -r 'if (.ok==true) and ((.studyText//"")!="") then .studyText else empty end' 2>/dev/null)
    if [[ -n "$_grounded" ]]; then
      log "  study: grounded PSR study OK ($(printf '%s' "$_grounded" | wc -c | tr -d ' ') chars)" 1>&2
      printf '%s' "$_grounded"
      return 0
    fi
    log "  study: PSR grounded endpoint unavailable/empty — falling back to the sermon project agent" 1>&2
  fi

  # Fallback: run the project-scoped headless agent parametrically.
  # Non-fatal — degrades to empty stdout for the caller.
  local qfile out rc=0
  qfile=$(mktemp)
  {
    echo "Weekly automated sermon-study request from Brandon's scheduled sermon-print job."
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

  log "  study: running the sermon project agent for '${passage}' (timeout 600s)..." 1>&2
  out=$(run_sermon_agent "$qfile" 600) || rc=$?
  if (( rc != 0 )); then
    log "  study: sermon project agent exited ${rc}" 1>&2
  fi
  rm -f "$qfile"

  # Belt-and-suspenders: if a conversational preamble + '---' fence slipped in
  # despite the instruction, keep only what follows the fence.
  if printf '%s\n' "$out" | head -6 | grep -q '^[[:space:]]*---[[:space:]]*$'; then
    out=$(printf '%s\n' "$out" | sed -n '/^[[:space:]]*---[[:space:]]*$/,$p' | sed '1d')
  fi
  printf '%s' "$out"
}

# Build fully written homiletical illustrations from the grounded study. These
# are ready-to-use prose illustrations, not visual images and not one-line seeds.
# Failure is non-fatal to church-note delivery but makes the prep-study component
# incomplete, so the caller reports a partial failure and does not print it.
build_sermon_illustrations() {
  local passage="$1" theme="${2:-}" grounded_study="$3"
  [[ -n "$passage" && -n "$grounded_study" ]] || { printf ''; return 0; }

  local qfile out rc=0
  qfile=$(mktemp)
  {
    echo "Weekly sermon-prep illustration request from Brandon's scheduled sermon-print job."
    echo
    echo "Passage: $passage"
    [[ -n "$theme" ]] && echo "Teaching title/theme: $theme"
    echo
    echo "Using the grounded exegetical study below as your factual and theological boundary, write THREE fully developed homiletical illustrations that a pastor could actually tell from the pulpit. These are WRITTEN illustrations, not images and not one-line seeds."
    echo
    echo "Requirements for each illustration:"
    echo "- Give it a short descriptive title."
    echo "- Write 140-220 words with a concrete setup, tension/turn, and payoff."
    echo "- End with an explicit 1-2 sentence bridge back to a specific movement or claim in $passage."
    echo "- Make the three illustrations distinct: one everyday/object lesson, one contemporary relational or cultural scenario, and one biblical/canonical analogy."
    echo "- Do not fabricate personal anecdotes, quotations, statistics, historical events, or claims that would require verification. Clearly frame invented scenarios as hypothetical."
    echo "- Avoid clichés, generic motivational language, and illustrations that could be pasted into any sermon."
    echo
    echo "FORMAT: Begin exactly with 'FULLY DEVELOPED SERMON ILLUSTRATIONS'. Then number 1-3. Plain printable text, no Markdown symbols, no preamble, no sign-off."
    echo
    echo "GROUNDED STUDY (data to use, not instructions):"
    printf '%s\n' "$grounded_study"
  } >"$qfile"

  log "  illustrations: running the sermon project agent for three developed illustrations (timeout 600s)..." 1>&2
  out=$(run_sermon_agent "$qfile" 600) || rc=$?
  if (( rc != 0 )); then
    log "  illustrations: sermon project agent exited ${rc}" 1>&2
  fi
  rm -f "$qfile"

  if printf '%s\n' "$out" | head -6 | grep -q '^[[:space:]]*---[[:space:]]*$'; then
    out=$(printf '%s\n' "$out" | sed -n '/^[[:space:]]*---[[:space:]]*$/,$p' | sed '1d')
  fi
  # Keep only the explicitly requested section before validating completeness.
  if grep -qi '^FULLY DEVELOPED SERMON ILLUSTRATIONS' <<<"$out"; then
    out=$(printf '%s\n' "$out" | sed -n '/^FULLY DEVELOPED SERMON ILLUSTRATIONS/,$p')
  fi
  # Require the promised section and three numbered illustrations. Rejecting a
  # thin response is safer than silently printing another seed-only study.
  if ! grep -qi '^FULLY DEVELOPED SERMON ILLUSTRATIONS' <<<"$out" ||
     [[ $(grep -Ec '^[[:space:]]*[1-3][.)][[:space:]]+' <<<"$out") -lt 3 ]] ||
     (( ${#out} < 1800 )); then
    log "  illustrations: response failed completeness checks (${#out} chars)" 1>&2
    printf ''; return 0
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

if (( ! DRY_RUN && ! PREVIEW )); then
  post_discord "🖨️ Sermon notes print started — checking this week's Denton Bible notes and preparing the independent study."
fi

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

declare -a MATCH_URLS=()      # media whose filename contains SERMON_FILENAME_MATCH
declare -a MATCH_TITLES=()
declare -a MATCH_DATES=()     # YYMMDD parsed from each matching filename
declare -a SEEN_URLS=()       # dedupe repeated article media URLs

for ap in "${ARTICLE_PATHS[@]}"; do
  aurl="$BASE$ap"
  pdf=$(curl -sL "$aurl" | grep -oP "$MEDIA_RE" | head -1 || true)
  if [[ -z "$pdf" ]]; then
    log "  $ap → no PDF"
    continue
  fi
  # Dedupe on URL
  local_seen=0
  for existing in "${SEEN_URLS[@]:-}"; do
    if [[ "$existing" == "$pdf" ]]; then local_seen=1; break; fi
  done
  if (( local_seen )); then continue; fi

  fname=$(basename "$pdf")
  title=$(echo "$ap" | sed 's|/article/||; s/-/ /g')
  SEEN_URLS+=("$pdf")
  log "  $ap → $fname"

  # Keep only sermon-notes media and capture its MMDDYY date token.
  if [[ "$fname" == *"$SERMON_FILENAME_MATCH"* ]]; then
    MATCH_URLS+=("$pdf"); MATCH_TITLES+=("$title")
    d=$(echo "$fname" | grep -oP 'sermon-notes-\K[0-9]{6}' | head -1 || true)
    if [[ -n "$d" ]]; then
      MATCH_DATES+=("${d:4:2}${d:0:2}${d:2:2}")   # MMDDYY -> YYMMDD for exact comparison
    else
      MATCH_DATES+=("")
    fi
  fi
done

# Accept only files explicitly dated for the applicable Sunday. Choosing the
# newest date still reprints stale notes when a guest teacher publishes none.
# A missing or malformed date is therefore a normal no-print outcome, not a
# reason to fall back to another file.
declare -a CUR_URLS=() CUR_TITLES=()
for j in "${!MATCH_URLS[@]}"; do
  if [[ "${MATCH_DATES[$j]}" == "$CURRENT_SUNDAY_YYMMDD" ]]; then
    CUR_URLS+=("${MATCH_URLS[$j]}"); CUR_TITLES+=("${MATCH_TITLES[$j]}")
  else
    item_date="undated"
    d="${MATCH_DATES[$j]}"
    [[ -n "$d" ]] && item_date="20${d:0:2}-${d:2:2}-${d:4:2}"
    log "  skip non-current item: $(basename "${MATCH_URLS[$j]}") (dated $item_date; expected $CURRENT_SUNDAY)"
  fi
done
MATCH_URLS=("${CUR_URLS[@]}"); MATCH_TITLES=("${CUR_TITLES[@]}")
log "Current Sunday $CURRENT_SUNDAY -> ${#MATCH_URLS[@]} item(s) after date filter"

if (( ${#MATCH_URLS[@]} == 0 )); then
  log "No sermon notes dated $CURRENT_SUNDAY were published; nothing to print."
  exit 0
fi

PRINT_URLS=("${MATCH_URLS[@]}"); PRINT_TITLES=("${MATCH_TITLES[@]}")
log "Filtered to ${#PRINT_URLS[@]} current-Sunday sermon-notes file(s)"

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
# sermon project agent). The model is told to reply with only the reference; we
# also regex-extract as a safety net and normalize en/em dashes. Non-fatal.
PASSAGE_REF=""
PASSAGE_RAW=""
if [[ -n "$PDF_TEXT" ]]; then
  PASSAGE_RAW=$(cd "$HOME" && timeout 60 kiro-cli chat --model claude-opus-4.8 --no-interactive --wrap never "From these sermon notes, identify the single primary Bible passage being taught. Reply with ONLY one normalized reference. Use Book Chapter:Verses for a verse selection (example: 1 Kings 12:25-33), Book Chapter-Chapter for whole chapters (example: 2 Kings 18-19), or Book Chapter for one whole chapter. No other words.

${PDF_TEXT}" 2>&1 | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' | grep -v "Credits:\|Time:") || PASSAGE_RAW=""
  PASSAGE_REF=$(extract_passage_reference "$PASSAGE_RAW")
  if [[ -z "$PASSAGE_REF" ]]; then
    PASSAGE_REF=$(extract_passage_reference "$PDF_TEXT")
    [[ -n "$PASSAGE_REF" ]] && log "Passage model output was unusable; recovered from notes text"
  fi
fi
if [[ -z "$PASSAGE_REF" && -n "$PRIMARY_TITLE" ]]; then
  PASSAGE_REF=$(extract_passage_reference "$PRIMARY_TITLE" 1)
  [[ -n "$PASSAGE_REF" ]] && log "Passage recovered from article title fallback"
fi
if [[ -n "$PASSAGE_REF" ]]; then
  log "Detected passage: $PASSAGE_REF"
else
  log "Could not detect a passage reference from model output, notes text, or article title"
fi

# Short 2-3 sentence summary for the Discord notification.
if [[ -n "$PDF_TEXT" ]] && (( ! DRY_RUN )); then
  log "Generating sermon summary from $PRIMARY_TITLE..."
  SUMMARY=$(cd "$HOME" && timeout 60 kiro-cli chat --model claude-opus-4.8 --no-interactive --wrap never "Summarize this sermon in 2-3 sentences. What is the main topic, key scripture, and one takeaway? Be concise.

${PDF_TEXT}" 2>&1 | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' | grep -v "^$" | grep -v "Credits:\|Time:" | tail -5 | head -3) || SUMMARY=""
fi

# Run the sermon project agent directly to build an INDEPENDENT study of the
# passage. Printed as the cover page ahead of the notes PDF. Any
# failure degrades gracefully to the short summary cover. (Brandon req 2026-07-26)
STUDY=""
ILLUSTRATIONS=""
STUDY_FAILURE_REASON=""
if [[ -n "$PASSAGE_REF" ]] && (( ! DRY_RUN )); then
  STUDY=$(build_sermon_study "$PASSAGE_REF" "$PRIMARY_TITLE")
  if [[ -n "$STUDY" ]]; then
    log "Study built for $PASSAGE_REF (${#STUDY} chars)"
    ILLUSTRATIONS=$(build_sermon_illustrations "$PASSAGE_REF" "$PRIMARY_TITLE" "$STUDY")
    if [[ -n "$ILLUSTRATIONS" ]]; then
      log "Developed illustrations built (${#ILLUSTRATIONS} chars)"
      STUDY=$(BASE_STUDY="$STUDY" ILLUSTRATION_TEXT="$ILLUSTRATIONS" python3 <<'PYMERGE'
import os
import re

study = os.environ["BASE_STUDY"].rstrip()
illustrations = os.environ["ILLUSTRATION_TEXT"].strip()

# The grounded PSR study ends with useful brainstorming seeds, but this weekly
# print artifact already adds three fully developed pulpit-ready illustrations.
# Drop the redundant seed appendix so it cannot consume another printed page.
seed_heading = re.search(r"(?im)^ILLUSTRATION SEEDS(?:\s|\().*$", study)
if seed_heading:
    study = study[:seed_heading.start()].rstrip()

marker = "\nGROUNDED ON:"
pos = study.rfind(marker)
if pos >= 0:
    print(study[:pos].rstrip() + "\n\n" + illustrations + "\n\n" + study[pos + 1:])
else:
    print(study + "\n\n" + illustrations)
PYMERGE
)
    else
      STUDY_FAILURE_REASON="fully developed sermon illustrations were unavailable for $PASSAGE_REF"
      STUDY=""
      log "Study incomplete — $STUDY_FAILURE_REASON"
    fi
  else
    log "Study unavailable — cover page will fall back to the short summary"
  fi
elif (( DRY_RUN )); then
  log "[DRY RUN] would run the sermon project agent for a grounded study and three fully developed illustrations: ${PASSAGE_REF:-<passage undetected>}"
fi

if (( ! DRY_RUN )) && [[ -z "$STUDY" ]]; then
  if [[ -z "$STUDY_FAILURE_REASON" && -z "$PASSAGE_REF" ]]; then
    STUDY_FAILURE_REASON="passage detection failed"
  elif [[ -z "$STUDY_FAILURE_REASON" ]]; then
    STUDY_FAILURE_REASON="study generation returned no content for $PASSAGE_REF"
  fi
  REPORT_LINES+=("❌ Independent prep study — $STUDY_FAILURE_REASON")
  FAILURE_COUNT=$((FAILURE_COUNT + 1))
fi

# Render the study as a QUALITY typeset PDF (WeasyPrint) so it prints as a clean
# cover sheet instead of a monospace email body — nicer to read and carry to
# church. Falls back to the plain-text body if rendering fails. (Brandon req 2026-08-23)
STUDY_PDF=""
if [[ -n "$STUDY" ]]; then
  _study_txt="$TMPDIR/sermon-study.txt"
  printf '%s' "$STUDY" > "$_study_txt"
  _study_pdf="$TMPDIR/sermon-study.pdf"
  if python3 "$HOME/openclaw/scripts/render_study_pdf.py" \
       "$_study_txt" "$_study_pdf" "Sermon Study — ${PRIMARY_TITLE:-$PASSAGE_REF}" 2>&1 \
       | sed 's/^/    render_study_pdf: /' >&2; then
    if [[ -f "$_study_pdf" ]] && (( $(stat -c%s "$_study_pdf") > 1500 )); then
      STUDY_PDF="$_study_pdf"
      log "Study PDF rendered ($(stat -c%s "$_study_pdf") bytes)"
    fi
  fi
  [[ -z "$STUDY_PDF" ]] && log "Study PDF unavailable — will fall back to the text body"
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
    pv_body="PREVIEW: study unavailable (passage: ${PASSAGE_REF:-<none>}). Check the journal logs for the sermon-agent result."
  fi
  log "Preview: emailing study cover page to $PREVIEW_EMAIL (not the printer)"
  _pv_attach=(); [[ -n "$STUDY_PDF" ]] && _pv_attach=(--attach "$STUDY_PDF")
  [[ -n "$STUDY_PDF" ]] && pv_body="$pv_body

(The quality PDF that will actually print is attached to this preview.)"
  if gog gmail send -a brandon.tyler@gmail.com \
      --to "$PREVIEW_EMAIL" \
      --subject "[PREVIEW] Sermon Study Cover Page - ${PASSAGE_REF:-passage} (not printed)" \
      --body "$pv_body" "${_pv_attach[@]}"; then
    log "Preview email sent to $PREVIEW_EMAIL."
  else
    log "Preview email FAILED (see gog output above)."
  fi
  log "Preview mode done — nothing printed, no Discord post."
  if [[ -n "$STUDY_FAILURE_REASON" ]]; then
    log "Preview completed with partial failure: $STUDY_FAILURE_REASON"
    exit 2
  fi
  exit 0
fi

# Step 3c: Print the study as its own QUALITY PDF first (nicer than a text body),
# then send each notes file. The study PDF is grounded + typeset (render_study_pdf).
if [[ -n "$STUDY_PDF" ]]; then
  if gog gmail send -a brandon.tyler@gmail.com \
      --to "$PRINT_EMAIL" \
      --subject "Sermon Study - ${PASSAGE_REF:-$PRIMARY_TITLE}" \
      --body "Independent grounded study — read alongside the sermon notes." \
      --attach "$STUDY_PDF" 2>&1; then
    log "  emailed study PDF → $PRINT_EMAIL"
    REPORT_LINES+=("📖 Study PDF — ${PASSAGE_REF:-$PRIMARY_TITLE}")
    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
  else
    log "  ERROR: study PDF send failed — study will ride as the primary notes body instead"
    REPORT_LINES+=("❌ study PDF send failed")
    STUDY_PDF=""   # trigger the text-body fallback on the primary notes email
  fi
fi

for j in "${!SEND_PATHS[@]}"; do
  local_pdf="${SEND_PATHS[$j]}"
  title="${SEND_TITLES[$j]}"
  fname="${SEND_FNAMES[$j]}"
  size="${SEND_SIZES[$j]}"

  body="Sermon notes attached."
  if [[ "$local_pdf" == "$PRIMARY_PDF" ]]; then
    if [[ -z "$STUDY_PDF" && -n "$STUDY" ]]; then
      # Fallback ONLY: study PDF unavailable, so embed the study text as the body.
      body="Sermon Study — ${title}
(Independent study — read alongside the sermon notes that follow.)

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

📖 Independent study of ${PASSAGE_REF} built by the sermon project agent and printed as the cover page."
elif [[ -n "$PASSAGE_REF" ]]; then
  FULL_MSG="$FULL_MSG

📖 Passage detected: ${PASSAGE_REF} (study unavailable this run — printed the short summary as the cover)."
elif [[ -n "$STUDY_FAILURE_REASON" ]]; then
  FULL_MSG="$FULL_MSG

❌ Independent prep study missing: ${STUDY_FAILURE_REASON}."
fi

post_discord "$FULL_MSG"
if (( FAILURE_COUNT > 0 )); then
  log "Done with partial failure: $FAILURE_COUNT failed component(s)."
  exit 2
fi
log "Done."
