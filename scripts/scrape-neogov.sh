#!/usr/bin/env bash
# scrape-neogov.sh — Scrape governmentjobs.com city pages via dev-browser CLI
# Uses the dev-browser daemon (Unix socket, pipe mode). No CDP port needed.
#
# Usage: bash scrape-neogov.sh [slug1 slug2 ...]
# Output: JSONL to stdout (one JSON object per matching job)
# Errors: stderr
set -uo pipefail

DEV_BROWSER="${DEV_BROWSER:-/home/ubuntu/.local/bin/dev-browser}"
PER_CITY_TIMEOUT=45

# Verified North TX NEOGOV slugs (centered on Denton, ~100mi radius)
DEFAULT_SLUGS=(
  # Denton County core
  dentontx denton dentoncounty highlandvillage lewisville flowermoundtx
  aubreytx sanger argyle crossroads prospertx trophyclub roanoke
  # Collin County
  frisco cityofmckinney allen princeton sachsetx murphytx
  # Dallas County
  dallas garland mesquitetx cityofmesquite cityofirving farmersbranch
  addisontx highlandpark desototx lancastertx cedarhill glennheights
  rowlett lakeworth
  # Tarrant County
  fortworth arlington arlingtontx grandprairietx mansfieldtx colleyville
  grapevinetx coppell haltomcity wataugatx joshuatx
  # Rockwall / Kaufman / East
  rockwalltx forneytx
  # Ellis / Johnson / South
  waxahachie midlothiantx ennistx redoak
  # Parker / Wise / West
  weatherford
  # Grayson / Cooke / North
  shermantx denisontx gainesvilletx
  # The Colony (Denton County, ~15mi)
  thecolonytx
)

SLUGS=("${@:-${DEFAULT_SLUGS[@]}}")

# Verify dev-browser daemon is running
if ! "$DEV_BROWSER" status >/dev/null 2>&1; then
  echo "ERROR: dev-browser daemon not running" >&2
  exit 1
fi

scrape_city() {
  local slug="$1"
  local url="https://www.governmentjobs.com/careers/${slug}"
  local err_tmp
  err_tmp=$(mktemp)

  # Notes on dev-browser sandbox best practices:
  # - Use browser.newPage() + page.close() for anonymous pages (no accumulation)
  # - Do NOT use page.$() — it hangs in QuickJS sandbox. Use page.evaluate() instead.
  # - Use waitUntil:"commit" — NEOGOV pages hang on "load"/"domcontentloaded"
  # - 8s render wait for JS-rendered content
  local output
  output=$("$DEV_BROWSER" --headless --timeout "$PER_CITY_TIMEOUT" 2>"$err_tmp" <<DEVSCRIPT
const page = await browser.newPage();
page.setDefaultTimeout(60000);
try {
  await page.goto("${url}", { timeout: 40000, waitUntil: "commit" });
  await new Promise(r => setTimeout(r, 8000));
  // Dismiss cookie consent via evaluate (page.\$ hangs in QuickJS sandbox)
  await page.evaluate(() => {
    const btn = document.querySelector('[class*="osano-cm-accept"]');
    if (btn) btn.click();
  });
  await new Promise(r => setTimeout(r, 1000));
  const jobs = await page.evaluate(() => {
    return Array.from(document.querySelectorAll('.list-item')).map(el => ({
      title: (el.querySelector('.item-details-link')?.textContent || '').trim(),
      url: el.querySelector('.item-details-link')?.href || '',
      meta: (el.querySelector('.list-meta')?.textContent || '').trim().replace(/\\s+/g, ' '),
    }));
  });
  const re = /firefight|fire\\s*(fighter|chief|inspector|marshal|captain|engineer|cadet|recruit|watch|safety|prevention)|paramedic|\\bems\\b|\\bemt\\b|emergency\\s*(medical|services|technician|room)|ambulance|er\\s+tech|first\\s*responder|hazmat|industrial\\s+fire/i;
  const filtered = jobs.filter(j => re.test(j.title + " " + j.meta));
  for (const j of filtered) {
    j.city = "${slug}";
    console.log(JSON.stringify(j));
  }
} finally {
  await page.close();
}
DEVSCRIPT
  )
  local exit_code=$?

  if [ $exit_code -ne 0 ]; then
    local err_msg
    err_msg=$(head -1 "$err_tmp")
    if [[ "$err_msg" == *"timed out"* ]]; then
      printf "  TIMEOUT" >&2
    else
      printf "  ERR(%s)" "$err_msg" >&2
    fi
  fi
  rm -f "$err_tmp"

  [ -n "$output" ] && echo "$output"
}

total=0
for slug in "${SLUGS[@]}"; do
  printf "[%s] " "$slug" >&2
  output=$(scrape_city "$slug")
  count=0
  if [ -n "$output" ]; then
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      echo "$line"
      count=$((count + 1))
    done <<< "$output"
  fi
  printf " %d\n" "$count" >&2
  total=$((total + count))
  sleep 0.5
done

printf "[done] %d fire jobs from %d cities\n" "$total" "${#SLUGS[@]}" >&2
