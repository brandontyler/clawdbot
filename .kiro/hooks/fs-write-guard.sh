#!/bin/bash
# Kiro preToolUse hook: Block fs_write to sensitive files or outside repo
set -uo pipefail

EVENT=$(cat)
FILE_PATH=$(echo "$EVENT" | jq -r '.tool_input.path // empty')
[ -z "$FILE_PATH" ] && exit 0

# Resolve repo root
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -z "$REPO_ROOT" ]; then
  echo "BLOCKED: Cannot determine repo root" >&2
  exit 2
fi

# Resolve to absolute path for comparison
ABS_PATH=$(realpath -m "$FILE_PATH" 2>/dev/null || echo "$FILE_PATH")

# Block writes outside repo
case "$ABS_PATH" in
  "$REPO_ROOT"/*) ;;
  *) echo "BLOCKED: Write outside repo root: $ABS_PATH" >&2; exit 2 ;;
esac

# Block sensitive file patterns
BASENAME=$(basename "$ABS_PATH")
case "$BASENAME" in
  .env|.env.*|*.pem|*.key|*.p12|*.pfx|*.jks)
    echo "BLOCKED: Write to sensitive file: $BASENAME" >&2; exit 2 ;;
esac
case "$ABS_PATH" in
  *credentials*|*secret*|*.aws/*|*id_rsa*|*id_ed25519*)
    echo "BLOCKED: Write to sensitive path: $ABS_PATH" >&2; exit 2 ;;
esac

exit 0
