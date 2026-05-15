#!/bin/bash
export NVM_DIR="$HOME/.nvm"
source ~/.profile 2>/dev/null || true
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
nvm use 22 >/dev/null 2>&1
export PATH="$HOME/.local/bin:$HOME/.local/share/pnpm:$HOME/.local/share/pnpm/bin:$PATH"
cd ~/openclaw
exec node openclaw.mjs kiro-proxy --port 18801 --verbose --routes kiro-proxy-routes.json
