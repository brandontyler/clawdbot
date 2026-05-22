#!/usr/bin/env bash
# scrape-tcfp.sh — Scrape TCFP fire service careers via dev-browser (pipe mode)
# Output: JSONL to stdout (one JSON object per job, ALL Texas jobs — filtering done later)
# Errors: stderr
set -uo pipefail

DEV_BROWSER="${DEV_BROWSER:-/home/ubuntu/.local/bin/dev-browser}"

if ! "$DEV_BROWSER" status >/dev/null 2>&1; then
  echo "ERROR: dev-browser daemon not running" >&2
  exit 1
fi

# Scrape TCFP — accept disclaimer, extract job table as JSON
RAW=$(timeout 45 "$DEV_BROWSER" --headless --timeout 40 2>/dev/null <<'DEVSCRIPT'
const page = await browser.newPage();
page.setDefaultTimeout(30000);
try {
  await page.goto("https://www.tcfp.texas.gov/fireservice-careers", { timeout: 20000, waitUntil: "commit" });
  await new Promise(r => setTimeout(r, 3000));
  await page.evaluate(() => {
    const cb = document.querySelector('input[type=checkbox]');
    if (cb) { cb.checked = true; cb.dispatchEvent(new Event('change', {bubbles: true})); }
    const btn = document.querySelector('input[type=submit], button[type=submit]');
    if (btn) btn.click();
    const form = document.querySelector('form');
    if (form && !btn) form.submit();
  });
  await new Promise(r => setTimeout(r, 5000));
  const jobs = await page.evaluate(() => {
    const rows = [];
    for (const tr of document.querySelectorAll('table tr')) {
      const cells = tr.querySelectorAll('td');
      if (cells.length >= 4) {
        const link = tr.querySelector('a[href]');
        rows.push({
          city: cells[0]?.innerText?.trim() || '',
          department: cells[1]?.innerText?.trim() || '',
          position: cells[2]?.innerText?.trim() || '',
          type: cells[3]?.innerText?.trim() || '',
          salary: cells[4]?.innerText?.trim() || '',
          url: link?.href || 'https://www.tcfp.texas.gov/fireservice-careers',
        });
      }
    }
    return JSON.stringify(rows);
  });
  console.log(jobs);
} finally {
  await page.close();
}
DEVSCRIPT
)

if [ -z "$RAW" ]; then
  echo "ERROR: no output from dev-browser" >&2
  exit 1
fi

# Convert JSON array to JSONL (one object per line)
echo "$RAW" | python3 -c "
import sys, json
data = json.loads(sys.stdin.read())
for job in data:
    # Output as JSONL with normalized fields
    out = {
        'title': job.get('position', ''),
        'department': job.get('department', ''),
        'city': job.get('city', ''),
        'type': job.get('type', ''),
        'salary': job.get('salary', ''),
        'url': job.get('url', ''),
    }
    print(json.dumps(out))
" 2>/dev/null
