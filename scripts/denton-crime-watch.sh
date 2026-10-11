#!/usr/bin/env bash
# denton-crime-watch.sh — weekly digest for the configured Denton home block.
# Pulls data via scripts/denton-crime-watch.py, has kiro-cli write a plain-English
# digest, and posts it to #openclaw-ec2. Runs via systemd timer (weekly).
# Kiro-only file (see UPSTREAM.md). Pattern mirrors nathan-jobs.sh.
set -uo pipefail
umask 077

HERE="$(cd "$(dirname "$0")" && pwd)"
PY="$HERE/denton-crime-watch.py"
DISCORD_CHANNEL="1503414103341797406"   # #openclaw-ec2
MODE="${1:-run}"                          # run | dry-run
DATE_LABEL="$(date '+%b %-d, %Y')"
FETCH_TIMEOUT_SECS="${DENTON_CRIME_FETCH_TIMEOUT_SECS:-20}"
FETCH_GRACE_SECS=5
MODEL_TIMEOUT_SECS="${DENTON_CRIME_MODEL_TIMEOUT_SECS:-150}"
DISCORD_TIMEOUT_SECS="${DENTON_CRIME_DISCORD_TIMEOUT_SECS:-20}"
MAX_DIGEST_CHARS="${DENTON_CRIME_MAX_DIGEST_CHARS:-9000}"
HOME_ADDRESS="${DENTON_HOME_ADDRESS:-}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
log(){ echo "[$(date '+%F %T')] $*"; }

case "$MODE" in
  run|dry-run) ;;
  *) log "invalid mode: $MODE (expected run or dry-run)" >&2; exit 2 ;;
esac
for setting in FETCH_TIMEOUT_SECS MODEL_TIMEOUT_SECS DISCORD_TIMEOUT_SECS MAX_DIGEST_CHARS; do
  value="${!setting}"
  [[ "$value" =~ ^[0-9]+$ ]] || { log "$setting must be an integer" >&2; exit 2; }
done
if (( FETCH_TIMEOUT_SECS < 1 || FETCH_TIMEOUT_SECS > 30 \
   || MODEL_TIMEOUT_SECS < 1 || MODEL_TIMEOUT_SECS > 180 \
   || DISCORD_TIMEOUT_SECS < 1 || DISCORD_TIMEOUT_SECS > 30 \
   || MAX_DIGEST_CHARS < 1800 || MAX_DIGEST_CHARS > 9000 )); then
  log "Denton timeout/body settings exceed their service-budget bounds" >&2
  exit 2
fi

HOME_CONTEXT="Brandon's configured home is on the 4XX HEADLEE block in Denton, TX"
if [ -n "$HOME_ADDRESS" ]; then
  HOME_CONTEXT="Brandon lives at ${HOME_ADDRESS} (the 4XX HEADLEE block) in Denton, TX"
fi

# ── 1) Gather data ────────────────────────────────────────────────────────────
gather_report() {
  local scope="$1" days="$2" output="$3" error_file="$TMP/${scope}-${days}.stderr"
  if ! timeout "$((FETCH_TIMEOUT_SECS + FETCH_GRACE_SECS))" \
      python3 "$PY" --scope "$scope" --days "$days" \
      --fetch-timeout "$FETCH_TIMEOUT_SECS" > "$output" 2> "$error_file"; then
    log "Denton data fetch failed for scope=$scope days=$days: $(tail -1 "$error_file" | cut -c1-300)" >&2
    return 1
  fi
}

gather_report home 7 "$TMP/home7" || exit 1
gather_report neighborhood 7 "$TMP/nb7" || exit 1
gather_report neighborhood 30 "$TMP/nb30" || exit 1

# ── 2) Build the kiro-cli prompt (data injected via command substitution) ──────
read -r -d '' PROMPT <<PROMPT_EOF || true
You are writing Brandon's WEEKLY neighborhood crime digest for a Discord channel. ${HOME_CONTEXT}. The data below is Denton PD OFFENSE REPORTS only (not all police calls); addresses are masked to the hundred-block. HOME is exactly 4XX HEADLEE. NEIGHBORHOOD is already filtered to exact street names and verified hundred-block representatives within 700 meters, so do not infer additional locations.

Write a concise digest in Discord markdown, under 1500 characters:
- Lead with anything on the exact 4XX Headlee block this week; if none, say that block was quiet this week.
- Summarize this week's already-filtered neighborhood reports grouped by crime type with counts.
- One line on whether this week looks busier or quieter than the last 30 days.
- Neutral and factual. Do NOT use safe/dangerous/good/bad labels or speculate about people.
- End with one italic line: source = City of Denton open offense data; hundred-block masked; neighborhood uses verified block representatives within 700 m.
Do not use any tools; just write the digest from the data below.

=== HOME (4XX Headlee), last 7 days ===
$(cat "$TMP/home7" 2>/dev/null)

=== NEIGHBORHOOD, last 7 days ===
$(cat "$TMP/nb7" 2>/dev/null)

=== NEIGHBORHOOD, last 30 days (context for trend) ===
$(cat "$TMP/nb30" 2>/dev/null)
PROMPT_EOF

if [ "$MODE" = "dry-run" ]; then
  echo "===== GATHERED DATA + PROMPT (dry-run, no kiro-cli, no post) ====="
  printf '%s\n' "$PROMPT"
  exit 0
fi

# ── 3) Have kiro-cli write the digest (fallback to plain report) ───────────────
log "running kiro-cli digest…"
MODEL_EXIT=0
RAW_DIGEST=$(cd "$HOME" && timeout "$MODEL_TIMEOUT_SECS" \
  kiro-cli chat --model claude-opus-4.8 --no-interactive --wrap never "$PROMPT" 2>&1) \
  || MODEL_EXIT=$?
DIGEST=$(printf '%s' "$RAW_DIGEST" | sed 's/\x1b\[[0-9;]*m//g')
if [ "$MODEL_EXIT" -ne 0 ] || [ -z "${DIGEST// /}" ] \
    || printf '%s' "$DIGEST" | grep -qiE '^error|not a terminal|panic'; then
  log "kiro-cli unusable (exit=$MODEL_EXIT), falling back to plain neighborhood report"
  DIGEST="$(cat "$TMP/nb7")"$'\n\n_source: City of Denton open crime data; offense reports only, hundred-block masked._'
fi
if [ "${#DIGEST}" -gt "$MAX_DIGEST_CHARS" ]; then
  DIGEST="${DIGEST:0:MAX_DIGEST_CHARS}"$'\n… _digest truncated to the configured delivery bound_'
fi

BODY="🚔 **Weekly Denton crime — your neighborhood (Headlee)** — ${DATE_LABEL}"$'\n\n'"${DIGEST}"

# ── 4) Post to Discord (#openclaw-ec2), chunked ≤1800 chars ────────────────────
DISCORD_TOKEN="$(jq -r '.channels.discord.token // empty' ~/.openclaw/openclaw.json 2>/dev/null)"
if [ -z "$DISCORD_TOKEN" ]; then
  log "Discord token missing; digest was not delivered" >&2
  exit 1
fi
send_discord() {
  local content="$1" response_file code
  response_file=$(mktemp "$TMP/discord.XXXXXX")
  code=$(curl --silent --show-error --connect-timeout 5 --max-time "$DISCORD_TIMEOUT_SECS" \
    -o "$response_file" -w '%{http_code}' \
    -X POST "https://discord.com/api/v10/channels/${DISCORD_CHANNEL}/messages" \
    -H "Authorization: Bot $DISCORD_TOKEN" -H "Content-Type: application/json" \
    -d "$(jq -nc --arg c "$content" '{content:$c}')") || code="000"
  if [[ ! "$code" =~ ^2[0-9][0-9]$ ]]; then
    log "Discord delivery failed with HTTP ${code}" >&2
    return 1
  fi
}

# Fixed-width splitting keeps the service budget exact: the bounded body can
# require at most six verified Discord requests.
remaining="$BODY"
while [ "${#remaining}" -gt 1800 ]; do
  send_discord "${remaining:0:1800}" || exit 1
  remaining="${remaining:1800}"
done
[ -z "${remaining// /}" ] || send_discord "$remaining" || exit 1
log "posted and verified weekly crime digest to #openclaw-ec2"
