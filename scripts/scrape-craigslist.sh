#!/usr/bin/env bash
# scrape-craigslist.sh — Scrape Craigslist DFW for EMS/fire bridge jobs
# Runs multiple searches (CL doesn't support OR). Dedupes by URL.
# Output: JSONL to stdout
set -uo pipefail

DEV_BROWSER="${DEV_BROWSER:-/home/ubuntu/.local/bin/dev-browser}"

if ! "$DEV_BROWSER" status >/dev/null 2>&1; then
  echo "ERROR: dev-browser daemon not running" >&2
  exit 1
fi

# Search terms for bridge/holdover jobs
QUERIES=("EMT" "ER+tech" "paramedic" "firefighter" "fire+watch" "fire+safety" "emergency+technician")

ALL_JOBS="[]"

for q in "${QUERIES[@]}"; do
  RAW=$(timeout 30 "$DEV_BROWSER" --headless --timeout 25 2>/dev/null <<DEVSCRIPT
const page = await browser.newPage();
try {
  await page.goto("https://dallas.craigslist.org/search/jjj?query=${q}#search=1~list~0~0", { timeout: 20000, waitUntil: "commit" });
  await new Promise(r => setTimeout(r, 5000));
  const jobs = await page.evaluate(() => {
    const seen = new Set();
    const results = [];
    document.querySelectorAll('a[href*="/d/"]').forEach(a => {
      const text = a.textContent?.trim();
      if (!text || text.length < 5 || text.length > 200) return;
      if (!a.href.includes('dallas.craigslist.org')) return;
      if (seen.has(a.href)) return;
      seen.add(a.href);
      results.push({ title: text, url: a.href });
    });
    return JSON.stringify(results);
  });
  console.log(jobs);
} finally {
  await page.close();
}
DEVSCRIPT
  )
  [ -n "$RAW" ] && [ "$RAW" != "[]" ] && ALL_JOBS=$(echo "$ALL_JOBS" "$RAW" | python3 -c "
import sys, json
chunks = sys.stdin.read().strip().split(']')
merged = []
seen = set()
for chunk in chunks:
    chunk = chunk.strip().lstrip('[').strip()
    if not chunk: continue
    try:
        items = json.loads('[' + chunk + ']')
        for item in items:
            if item.get('url') not in seen:
                seen.add(item['url'])
                merged.append(item)
    except: pass
print(json.dumps(merged))
" 2>/dev/null)
  sleep 1
done

if [ -z "$ALL_JOBS" ] || [ "$ALL_JOBS" = "[]" ]; then
  exit 0
fi

# Output as JSONL with city extracted from URL
echo "$ALL_JOBS" | python3 -c "
import sys, json, re

data = json.loads(sys.stdin.read())
for job in data:
    url = job.get('url', '')
    title = job.get('title', '')
    city = 'DFW, TX'
    m = re.search(r'/d/([^/]+)/', url)
    if m:
        slug = m.group(1)
        parts = slug.split('-')
        # City is usually first 1-3 words before the job title keywords
        city_words = []
        for p in parts:
            if p.lower() in ('er', 'emt', 'fire', 'tech', 'paramedic', 'emergency', 'on', 'site', 'flight'):
                break
            city_words.append(p)
        if city_words:
            city = ' '.join(city_words).title() + ', TX'
    print(json.dumps({'title': title, 'url': url, 'city': city}))
" 2>/dev/null
