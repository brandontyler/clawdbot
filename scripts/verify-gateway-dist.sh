#!/bin/bash
# Quick pre-start check: verify critical dist files exist before gateway starts.
# Prevents the gateway from starting with an incomplete build.
DIST="/home/ubuntu/openclaw/dist"
CRITICAL_FILES=(
  "$DIST/plugin-sdk/channel-targets.js"
  "$DIST/plugin-sdk/state-paths.js"
  "$DIST/cli/gateway-cli/run-loop.js"
  "$DIST/gateway/server.js"
)
for f in "${CRITICAL_FILES[@]}"; do
  if [ ! -f "$f" ]; then
    echo "FATAL: Missing critical dist file: $f — build incomplete, refusing to start"
    exit 1
  fi
done
echo "Gateway dist verification passed"
