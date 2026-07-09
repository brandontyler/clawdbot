#!/bin/bash
# Adapter: Kiro preToolUse hook → DCG
# DCG (hook mode) always exits 0 and puts deny in JSON stdout.
# Kiro needs exit code 2 to block, with reason on stderr.
EVENT=$(cat)
COMMAND=$(echo "$EVENT" | jq -r '.tool_input.command // empty')
[ -z "$COMMAND" ] && exit 0

OUTPUT=$(echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(echo "$COMMAND" | jq -Rs .)}}" | ~/.local/bin/dcg 2>/dev/null)

# Empty stdout = allow, non-empty with "deny" = block
if [ -n "$OUTPUT" ] && echo "$OUTPUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
  echo "$OUTPUT" | jq -r '.hookSpecificOutput.permissionDecisionReason' >&2
  exit 2
fi
exit 0
