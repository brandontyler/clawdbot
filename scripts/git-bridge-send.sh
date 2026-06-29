#!/usr/bin/env bash
# git-bridge-send.sh — send a message to the sibling openclaw deployment
# via the shared `bridge` branch.
#
# Usage:
#   scripts/git-bridge-send.sh --to main --subject "Subject" --body "Body"
#   scripts/git-bridge-send.sh --to main --subject "Subject" --body-file ./msg.md
#   echo "body via stdin" | scripts/git-bridge-send.sh --to main --subject "Subject" --body-file -
#
# Flags:
#   --to <target>       'main' (sibling) or 'ec2' (us). Default: main.
#   --subject <text>    Required. Used in filename + frontmatter.
#   --body <text>       Inline body (single arg).
#   --body-file <path>  Body from file (use '-' for stdin).
#   --priority <p>      'normal' (default) or 'urgent'.
#   --reply-to <fname>  Filename of a message in inbox-ec2/ this responds to.
#   --dry-run           Print payload + plan but don't commit/push.
#
# Protocol: see https://github.com/brandontyler/clawdbot/blob/bridge/README.md
set -euo pipefail

# --- Args ---
TO=main
SUBJECT=""
BODY=""
BODY_FILE=""
PRIORITY=normal
REPLY_TO=""
DRY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --to)         TO="$2"; shift 2 ;;
    --subject)    SUBJECT="$2"; shift 2 ;;
    --body)       BODY="$2"; shift 2 ;;
    --body-file)  BODY_FILE="$2"; shift 2 ;;
    --priority)   PRIORITY="$2"; shift 2 ;;
    --reply-to)   REPLY_TO="$2"; shift 2 ;;
    --dry-run)    DRY=1; shift ;;
    -h|--help)    grep '^#' "$0" | head -25 | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "ERROR: unknown arg $1" >&2; exit 1 ;;
  esac
done

[ -z "$SUBJECT" ] && { echo "ERROR: --subject required" >&2; exit 1; }
[ "$TO" != "main" ] && [ "$TO" != "ec2" ] && { echo "ERROR: --to must be 'main' or 'ec2'" >&2; exit 1; }

# Body source
if [ -n "$BODY_FILE" ]; then
  if [ "$BODY_FILE" = "-" ]; then
    BODY=$(cat)
  else
    BODY=$(cat "$BODY_FILE")
  fi
fi
[ -z "$BODY" ] && { echo "ERROR: empty body (use --body or --body-file)" >&2; exit 1; }

# --- Determine sender from current branch on the main repo ---
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "/home/ubuntu/openclaw")
cd "$REPO_ROOT"
FROM=$(git -C "$REPO_ROOT" branch --show-current)
# Default fallback if we're not on a recognized branch
[ "$FROM" != "ec2" ] && [ "$FROM" != "main" ] && FROM="ec2"

# --- Build filename + frontmatter ---
TS=$(date '+%Y-%m-%dT%H-%M')
SLUG=$(echo "$SUBJECT" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | sed 's/^-*//;s/-*$//' | cut -c1-40)
[ -z "$SLUG" ] && SLUG="message"
FNAME="${TS}-from-${FROM}-${SLUG}.md"
TARGET_DIR="inbox-${TO}"

SENT_ISO=$(date -Iseconds)
PAYLOAD=$(cat <<EOF
---
from: ${FROM}
to: ${TO}
sent: ${SENT_ISO}
subject: "$(echo "$SUBJECT" | sed 's/"/\\"/g')"
reply_to: ${REPLY_TO:-null}
priority: ${PRIORITY}
---

${BODY}
EOF
)

echo "→ from:     ${FROM}"
echo "→ to:       ${TO} (inbox-${TO}/)"
echo "→ subject:  ${SUBJECT}"
echo "→ filename: ${FNAME}"
echo "→ bytes:    $(printf '%s' "$PAYLOAD" | wc -c)"

if [ "$DRY" -eq 1 ]; then
  echo "--- DRY RUN — payload below, not committing ---"
  printf '%s\n' "$PAYLOAD"
  exit 0
fi

# --- Work in a temp worktree on the bridge branch ---
WT=$(mktemp -d -t openclaw-bridge-XXXX)
cleanup() { git worktree remove -f "$WT" 2>/dev/null || rm -rf "$WT"; }
trap cleanup EXIT

echo "→ checking out bridge in $WT ..."
git fetch origin bridge --quiet
git worktree add --quiet "$WT" origin/bridge

# Switch to a local branch so we can commit
cd "$WT"
git checkout -q -B bridge origin/bridge
mkdir -p "$TARGET_DIR"
printf '%s\n' "$PAYLOAD" > "$TARGET_DIR/$FNAME"

git add "$TARGET_DIR/$FNAME"
git -c user.name="openclaw-${FROM}" -c user.email="${FROM}@bridge.openclaw" \
  commit -q -m "bridge: ${FROM} → ${TO}: ${SUBJECT}"

echo "→ pushing ..."
git push -q origin bridge

COMMIT=$(git rev-parse --short HEAD)
echo "✓ sent: bridge@${COMMIT}  inbox-${TO}/${FNAME}"
echo "  view: https://github.com/brandontyler/clawdbot/blob/bridge/inbox-${TO}/${FNAME}"
