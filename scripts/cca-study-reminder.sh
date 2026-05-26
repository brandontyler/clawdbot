#!/usr/bin/env bash
# cca-study-reminder.sh — Daily CCA study reminder (Discord + email)
set -uo pipefail
source ~/.profile

TODAY=$(date +%Y-%m-%d)
DOW=$(date +%u) # 1=Mon, 7=Sun

# Skip weekends
[ "$DOW" -ge 6 ] && exit 0

# Study plan dates
WEEK1_START="2026-05-27"
WEEK2_START="2026-06-02"
WEEK3_START="2026-06-09"
WEEK4_START="2026-06-16"
END_DATE="2026-06-20"

# Check if we're in the study window
if [[ "$TODAY" < "$WEEK1_START" ]] || [[ "$TODAY" > "$END_DATE" ]]; then
  exit 0
fi

# Determine week and day
if [[ "$TODAY" < "$WEEK2_START" ]]; then
  WEEK=1
  DAY=$(( ( $(date -d "$TODAY" +%s) - $(date -d "$WEEK1_START" +%s) ) / 86400 + 1 ))
  TITLE="Week 1: API Courses + Fundamentals"
  TASKS="• Complete Claude 101 course (anthropic.skilljar.com)
• Complete AI Fluency Framework course
• Complete Building with Claude API course
• Review API docs: streaming, structured output, tool_choice
• Study Anthropic Cookbook examples"
  FOCUS="Stateless model, JSON mode, token counting, context window management"
elif [[ "$TODAY" < "$WEEK3_START" ]]; then
  WEEK=2
  DAY=$(( ( $(date -d "$TODAY" +%s) - $(date -d "$WEEK2_START" +%s) ) / 86400 + 1 ))
  TITLE="Week 2: MCP + Agentic Architecture (45% of exam!)"
  TASKS="• Complete Intro to MCP course
• Complete Claude Code developer training
• Complete Agent Skills course
• Study MCP spec (modelcontextprotocol.io)
• Study community exam guide (github.com/daronyondem/claude-architect-exam-guide)
• Do practice questions (Skilljar) — identify weak spots early"
  FOCUS="Multi-agent orchestration (27%), tool parameter design (18%), error recovery, HITL. KEY: tools=actions, resources=read-only. Never build a super-agent — use specialized agents."
elif [[ "$TODAY" < "$WEEK4_START" ]]; then
  WEEK=3
  DAY=$(( ( $(date -d "$TODAY" +%s) - $(date -d "$WEEK3_START" +%s) ) / 86400 + 1 ))
  TITLE="Week 3: Claude Code + Prompts + Context"
  TASKS="• Finish all 13 Anthropic Academy courses
• Review Claude Code docs (skills, hooks, subagents, worktrees)
• Study prompt engineering best practices
• Study context management and RAG patterns
• Study ANTI-PATTERNS: super-agent trap, prompt-only solutions, assuming shared context, lost-in-the-middle
• Do more practice questions — focus on weak areas from Week 2"
  FOCUS="Claude Code config (20%), prompt engineering (20%), context/reliability (15%). KEY: deterministic > probabilistic. Fix root causes, not symptoms. Simplest solution wins."
else
  WEEK=4
  DAY=$(( ( $(date -d "$TODAY" +%s) - $(date -d "$WEEK4_START" +%s) ) / 86400 + 1 ))
  TITLE="Week 4: Practice + TAKE THE EXAM"
  TASKS="• Take free practice questions on Skilljar
• Review weak areas from practice
• Re-read exam guide
• Register and TAKE THE EXAM (60 MCQ, 120 min, pass=720/1000)"
  FOCUS="Practice questions, review gaps, schedule exam at anthropic.skilljar.com"
fi

MSG="🎓 **CCA Study Reminder — Day ${DAY}, ${TITLE}**

${TASKS}

🎯 Focus: ${FOCUS}"

# Add a dynamic study tip via kiro-cli
TIP=$(cd "$HOME" && timeout 45 kiro-cli chat --no-interactive --wrap never "You are a study coach for the Claude Certified Architect (CCA-F) exam. Give ONE specific, actionable study tip for today. Context: Week ${WEEK}, Day ${DAY}. Topic area: ${FOCUS}. Keep it to 1-2 sentences. Be specific — reference a concept, API method, or pattern they should practice." 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -v "^$" | grep -v "Credits:\|Time:\|^>" | head -2)

if [ -n "$TIP" ]; then
  MSG="${MSG}

💡 Tip: ${TIP}"
fi

MSG="${MSG}

_Week ${WEEK}/4 | Exam: 60 MCQ, 120 min, proctored, 720/1000 to pass_"

# Send to Discord
DISCORD_CHANNEL="1503414103341797406"
DISCORD_TOKEN=$(jq -r '.channels.discord.token // empty' ~/.openclaw/openclaw.json 2>/dev/null)

if [ -n "$DISCORD_TOKEN" ]; then
  curl -s -X POST "https://discord.com/api/v10/channels/$DISCORD_CHANNEL/messages" \
    -H "Authorization: Bot $DISCORD_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"content\":$(echo "$MSG" | jq -Rs .)}" > /dev/null
fi

# Send email
EMAIL_BODY="CCA Study Reminder — Day ${DAY}, ${TITLE}

${TASKS}

Focus: ${FOCUS}

Week ${WEEK}/4 | Exam: 60 MCQ, 120 min, proctored, 720/1000 to pass
Courses: anthropic.skilljar.com"

gog gmail send -a brandon.tyler@gmail.com \
  --to "brandon.tyler@gmail.com" \
  --subject "🎓 CCA Study Day ${DAY}: ${TITLE}" \
  --body "$EMAIL_BODY" 2>/dev/null
