#!/usr/bin/env bash
# scrape-publicsafety.sh — Scrape publicsafetyanswers.com for active fire job postings
#
# Output: JSONL to stdout, one object per active firefighter posting.
#   {"title": "...", "url": "...", "city": "<slug>", "department": "...",
#    "opens": "YYYY-MM-DD", "closes": "YYYY-MM-DD", "description": "..."}
#
# Strategy:
#   1. Fetch /pages-sitemap.xml, get all /<city> slugs
#   2. Skip known non-city pages (blog, interviews, team, etc.)
#   3. For each city, fetch the page and look for "Firefighter Applications"
#   4. Parse "Opens: <date>" and "Closes: <date>"
#   5. Emit only if the posting is active (Closes >= today)
#
# Polite delay between requests to avoid hammering the host.
set -uo pipefail

SITEMAP="https://www.publicsafetyanswers.com/pages-sitemap.xml"
BASE_URL="https://www.publicsafetyanswers.com"
USER_AGENT="Mozilla/5.0 (compatible; fire-jobs-bot/1.0; brandon.tyler@gmail.com)"
DELAY_MS=300  # ms between requests

# Pages that are NOT individual city/department pages
declare -a SKIP_SLUGS=(
  "interviews" "team" "resources" "learnmore" "blog" "recruit-entrance-exam"
  "promotional-exams" "firedepartmentapplications" "afma" "theforpaulfoundation"
  "my-projects-2" "" 
)

is_skipped() {
  local slug="$1"
  for s in "${SKIP_SLUGS[@]}"; do
    [ "$slug" = "$s" ] && return 0
  done
  # Skip multi-segment paths
  echo "$slug" | grep -q '/' && return 0
  return 1
}

log_err() { echo "[scrape-publicsafety] $*" >&2; }

# Fetch sitemap and extract slugs
log_err "Fetching sitemap..."
SLUGS=$(curl -sL --max-time 30 -A "$USER_AGENT" "$SITEMAP" 2>/dev/null \
  | grep -oE '<loc>[^<]+</loc>' \
  | sed "s|<loc>${BASE_URL}/\?||;s|</loc>||" \
  | grep -v '^$' \
  | sort -u)

if [ -z "$SLUGS" ]; then
  log_err "Failed to fetch or parse sitemap"
  exit 1
fi

TOTAL=$(echo "$SLUGS" | wc -l)
log_err "Found $TOTAL pages in sitemap"

emitted=0
checked=0
for slug in $SLUGS; do
  # Strip any leading/trailing slashes
  slug="${slug%/}"
  slug="${slug#/}"
  is_skipped "$slug" && continue

  url="${BASE_URL}/${slug}"
  checked=$((checked + 1))

  # Fetch page (8s timeout)
  HTML=$(curl -sL --max-time 8 -A "$USER_AGENT" "$url" 2>/dev/null) || continue
  [ -z "$HTML" ] && continue

  # Parse the page in Python — handles HTML entities, date parsing, multi-line text.
  # Python exits 0 with no output when the page has no active firefighter posting,
  # which is the common case for non-fire pages.
  PARSED=$(python3 <(cat <<'PY'
import sys, re, json, html, datetime

slug = sys.argv[1]
url = sys.argv[2]
raw = sys.stdin.read()

# Strip script/style/comments
clean = re.sub(r'<script[^>]*>.*?</script>', ' ', raw, flags=re.S)
clean = re.sub(r'<style[^>]*>.*?</style>', ' ', clean, flags=re.S)
clean = re.sub(r'<!--.*?-->', ' ', clean, flags=re.S)
text = re.sub(r'<[^>]+>', ' ', clean)
text = html.unescape(text)
text = re.sub(r'\s+', ' ', text).strip()

# Look for the title pattern. Most common forms observed:
#   "<City> Fire Department Firefighter Applications:"
#   "Firefighter Applications:" (with department name in <h1> elsewhere)
# Look for "Firefighter Applications" as a marker. Title comes from the slug
# (clean, deterministic) rather than HTML extraction (noisy due to wix nav).
if not re.search(r'Firefighter Applications?', text, re.IGNORECASE):
    # No firefighter posting visible — skip
    sys.exit(0)

# Convert slug to a human-readable city name. Heuristic: insert space before
# capitals when slug isn't all lowercase, otherwise use a small known map.
def slug_to_city(s):
    known = {
        'haltomcity': 'Haltom City',
        'mckinney': 'McKinney',
        'colleyville': 'Colleyville',
        'baycounty': 'Bay County',
        'stcharles': 'St. Charles',
        'lascruces': 'Las Cruces',
        'fortlauderdale': 'Fort Lauderdale',
        'queencreek': 'Queen Creek',
        'brokenarrow': 'Broken Arrow',
        'sandycity': 'Sandy City',
        'crownpoint': 'Crown Point',
        'clarkcounty': 'Clark County',
        'fountainhills': 'Fountain Hills',
        'arizonacity': 'Arizona City',
        'rapidcity': 'Rapid City',
        'greenbay': 'Green Bay',
        'riorancho': 'Rio Rancho',
        'redwing': 'Red Wing',
        'oakgrove': 'Oak Grove',
        'oaklandpark': 'Oakland Park',
        'pinestrawberry': 'Pine Strawberry',
        'stevenspoint': 'Stevens Point',
        'stlucie': 'St. Lucie',
        'easthartford': 'East Hartford',
        'truckeemeadows': 'Truckee Meadows',
        'collegeofwesternidaho': 'College of Western Idaho',
        'rinconvalley': 'Rincon Valley',
        'bossiercity': 'Bossier City',
        'suncity': 'Sun City',
        'universitycity': 'University City',
        'heberovergaard': 'Heber-Overgaard',
        'blufftontownship': 'Bluffton Township',
        'timbermesa': 'Timber Mesa',
        'ftmojave': 'Fort Mojave',
    }
    if s in known:
        return known[s]
    # Fallback: title-case the slug
    return s.title()

city_name = slug_to_city(slug)
title = f"{city_name} Fire Department — Firefighter Applications"
department = f"{city_name} Fire Department"

# Parse Opens/Closes dates. Formats seen:
#   "Opens: June 10, 2026"
#   "Opens: May 1,  2026 - 8 :00 am"
#   "Closes: July 1, 2026"
#   "Closes: May 31, 2026 - 11:59 pm"
def parse_date(label, text):
    pat = rf'{label}:\s*([A-Za-z]+\s+\d{{1,2}}\s*,\s*\d{{4}})'
    m = re.search(pat, text)
    if not m: return None
    raw_date = re.sub(r'\s+', ' ', m.group(1)).strip()
    try:
        return datetime.datetime.strptime(raw_date, '%B %d, %Y').date()
    except ValueError:
        try:
            return datetime.datetime.strptime(raw_date, '%b %d, %Y').date()
        except ValueError:
            return None

opens = parse_date('Opens', text)
closes = parse_date('Closes', text)
today = datetime.date.today()

# Active = closes is in the future (or today). If we couldn't parse closes, skip
# to avoid surfacing stale postings.
if closes is None:
    sys.exit(0)

if closes < today:
    # Expired — skip
    sys.exit(0)

# Extract a short description: text following the dates, up to ~400 chars
desc = ''
desc_match = re.search(
    r'(?:Closes:[^.]*?\d{4}[^.]*?\.\s*)([A-Z][^<]{50,500})',
    text
)
if desc_match:
    desc = desc_match.group(1).strip()[:400]

out = {
    'title': title,
    'url': url,
    'city': slug,
    'department': department,
    'opens': opens.isoformat() if opens else '',
    'closes': closes.isoformat(),
    'description': desc,
}
print(json.dumps(out))
PY
) "$slug" "$url" <<< "$HTML")

  if [ -n "$PARSED" ]; then
    echo "$PARSED"
    emitted=$((emitted + 1))
    closes_date=$(echo "$PARSED" | python3 -c "import sys, json; print(json.loads(sys.stdin.read()).get('closes',''))" 2>/dev/null)
    log_err "  ✓ $slug — emitted (closes $closes_date)"
  fi

  # Polite delay
  sleep "$(awk "BEGIN{print $DELAY_MS/1000}")"
done

log_err "Done: checked $checked pages, emitted $emitted active fire postings"
