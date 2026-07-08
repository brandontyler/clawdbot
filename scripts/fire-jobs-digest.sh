#!/usr/bin/env bash
# fire-jobs-digest.sh — Generate personalized job digest via kiro-cli
# Input: TSV file (jid\ttitle\turl\tsource\tlocation) as $1
# Output: Markdown digest to stdout
set -uo pipefail

INPUT="${1:?Usage: fire-jobs-digest.sh <new-jobs.tsv>}"
[ ! -s "$INPUT" ] && exit 0

DATE_LABEL=$(date '+%A, %B %d %Y')

# Build job details for the prompt
JOB_DETAILS=""
while IFS=$'\t' read -r jid title url source location; do
  [ -z "$jid" ] && continue
  JOB_DETAILS="${JOB_DETAILS}
---
ID: ${jid}
Title: ${title}
URL: ${url}
Source: ${source}
Location: ${location}"
done < "$INPUT"

[ -z "$JOB_DETAILS" ] && exit 0

PROMPT="Write a personalized job digest email for Brady Tyler. Be encouraging but concise.

BRADY'S PROFILE:
- Age 22, lives in Denton, TX
- Firefighter/EMT certified (TCFP & NREMT)
- Currently looking for his first career fire department position
- Also interested in bridge/holdover jobs (ER tech, private ambulance, industrial fire, fire watch) that build experience while he interviews
- Strong work ethic, team player, physically fit
- Available immediately
- Has reliable transportation, willing to commute up to 75mi

TODAY'S NEW JOB POSTINGS:${JOB_DETAILS}

WRITE A DIGEST with this format:
1. Start with a one-line encouraging opener (vary it daily, be genuine not cheesy)
2. For EACH job, write 2-3 sentences: why it's a good fit, estimated commute time, what to emphasize in the application, and any deadline urgency
3. End with a brief action item (e.g., 'Apply to the Aubrey one first — small dept, they'll see your app faster')

Keep it under 300 words total. Write in a direct, supportive tone like a mentor texting advice. Use markdown formatting (bold titles, bullet points). Include the URL for each job."

# Run kiro-cli
RAW=$(timeout 120 kiro-cli chat --trust-tools= --wrap never "$PROMPT" 2>/dev/null)

# Strip ANSI escape codes and the leading "> " prompt marker
echo "$RAW" | sed 's/\x1b\[[0-9;]*m//g' | sed 's/^> //'
