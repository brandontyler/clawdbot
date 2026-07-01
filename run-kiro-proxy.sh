#!/bin/bash
export NVM_DIR="$HOME/.nvm"
source ~/.profile 2>/dev/null || true
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
nvm use 22 >/dev/null 2>&1
export PATH="$HOME/.local/bin:$HOME/.local/share/pnpm:$HOME/.local/share/pnpm/bin:$PATH"
cd ~/openclaw
# Self-heal (openclaw-d1g, wired 2026-06-30): verify the build completed end-to-end
# and auto-rollback to dist.last-good if dist/ is missing or partial, so a broken
# build cannot crash-loop the proxy. Exits non-zero only if dist is broken AND no
# good snapshot exists (surfaces a clear FATAL in the journal, not a node stack trace).
"$HOME/openclaw/scripts/verify-gateway-dist.sh" || exit $?
# --idle-secs 3600: hibernate sessions after 1h of inactivity (down from CLI
# default 24h). Memory mitigation for t4g.large — see bead openclaw-d1g.
# Trade-off: idle channels pay a fresh-spawn delay (~3s) on first message after
# hibernation; conversation history is preserved via hibernated.json snapshot.
exec node openclaw.mjs kiro-proxy --port 18801 --verbose --idle-secs 3600 --routes kiro-proxy-routes.json
