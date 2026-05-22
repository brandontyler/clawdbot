#!/usr/bin/env bash
# fire-jobs-filter.sh — Intelligent job filtering via kiro-cli headless
# Input: TSV file (jid\ttitle\turl\tsource\tlocation) as $1
# Output: JSONL to stdout — jobs scoring 3+ relevance
set -uo pipefail

INPUT="${1:?Usage: fire-jobs-filter.sh <jobs.tsv>}"
[ ! -s "$INPUT" ] && exit 0

# Build job list with location context
JOB_LIST=""
while IFS=$'\t' read -r jid title url source location; do
  [ -z "$jid" ] && continue
  loc_info=""
  [ -n "$location" ] && loc_info=" [location: ${location}]"
  JOB_LIST="${JOB_LIST}
- [${jid}] ${title}${loc_info}"
done < "$INPUT"

[ -z "$JOB_LIST" ] && exit 0

PROMPT="You are a job relevance filter for Brady Tyler.

BRADY'S PROFILE:
- Firefighter/EMT certified (TCFP & NREMT)
- Lives in Denton, TX (center point for distance)
- Maximum commute: 75 miles
- Target roles (CAREER): firefighter, EMT, paramedic, fire inspector, fire marshal, EMS coordinator, fire captain, fire engineer
- Target roles (BRIDGE/HOLDOVER — great experience while interviewing for career depts): ER tech, emergency room technician, ambulance/private EMS, fire watch, industrial fire brigade, first responder, hazmat tech, fire safety officer
- Prefers full-time but open to part-time that builds fire/EMS experience
- NOT interested in: police-only, admin-only, clerical, IT, non-emergency roles, volunteer-only

DISTANCE REFERENCE (from Denton, TX):
- 0-15mi: Denton, Corinth, Lake Dallas, Highland Village, Lewisville, Aubrey, Sanger, Argyle, The Colony
- 15-35mi: Frisco, McKinney, Flower Mound, Carrollton, Plano, Allen, Prosper, Coppell, Grapevine
- 35-55mi: Dallas, Fort Worth, Arlington, Irving, Grand Prairie, Garland, Mesquite, Weatherford, Sherman
- 55-75mi: Mansfield, Cedar Hill, Midlothian, Waxahachie, Rockwall, Forney, Denison, Gainesville
- OUTSIDE 75mi (reject): Waco (~130mi), Temple (~160mi), Longview (~170mi), Texarkana (~280mi), Houston (~260mi), Austin (~220mi), San Antonio (~280mi), Alice (~400mi), Burnet (~200mi)

JOBS TO EVALUATE:${JOB_LIST}

INSTRUCTIONS:
The [location: ...] field tells you where the job is. Use it for distance scoring.
For each job output ONE JSON line (no markdown, no extra text):
{\"jid\":\"<id>\",\"score\":<1-5>,\"reason\":\"<10 words max>\"}

Scoring:
5 = Career fire/EMS role within 30mi of Denton
4 = Career fire/EMS role 30-55mi OR bridge role within 30mi
3 = Career fire/EMS role 55-75mi OR bridge role 30-75mi
2 = Fire/EMS role OUTSIDE 75mi, or only tangentially relevant
1 = Not relevant (wrong field, outside 75mi, volunteer-only, non-emergency)

CRITICAL: Jobs outside 75mi of Denton MUST score 2 or below regardless of role match.
Output ONLY JSON lines, one per job."

# Run kiro-cli with positional arg (exits cleanly)
RAW=$(timeout 120 kiro-cli chat --trust-tools= --wrap never "$PROMPT" 2>/dev/null)

# Strip ANSI codes and extract JSON lines
echo "$RAW" | sed 's/\x1b\[[0-9;]*m//g' | grep -oP '\{[^}]+\}' | while IFS= read -r line; do
  score=$(echo "$line" | jq -r '.score // 0' 2>/dev/null)
  [ "$score" -ge 3 ] 2>/dev/null && echo "$line"
done
