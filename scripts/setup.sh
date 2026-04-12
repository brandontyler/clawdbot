#!/usr/bin/env bash
# Bootstrap a fresh clawdbot checkout: check deps, generate config, symlink spinup.
#
# Usage: scripts/setup.sh [--discord-token TOKEN] [--channel-id ID]
#
# Run from the repo root after cloning.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

DISCORD_TOKEN=""
CHANNEL_ID=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --discord-token) DISCORD_TOKEN="$2"; shift 2 ;;
    --channel-id)    CHANNEL_ID="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: scripts/setup.sh [--discord-token TOKEN] [--channel-id ID]"
      echo ""
      echo "Options:"
      echo "  --discord-token   Discord bot token (prompted if omitted)"
      echo "  --channel-id      Discord channel ID for this repo's #openclaw channel"
      echo ""
      echo "See docs/setup.md for full instructions."
      exit 0 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

ok()   { echo "  ✓ $*"; }
fail() { echo "  ✗ $*"; }
warn() { echo "  ⚠ $*"; }

# --- 1. Check required tools ---
echo "Checking dependencies..."
MISSING=0
for cmd in node pnpm tmux python3 jq; do
  if command -v "$cmd" &>/dev/null; then
    ok "$cmd ($(command -v "$cmd"))"
  else
    fail "$cmd — not found"
    MISSING=1
  fi
done

# Node version check
if command -v node &>/dev/null; then
  NODE_VER=$(node -v | sed 's/v//' | cut -d. -f1)
  if (( NODE_VER < 22 )); then
    fail "node v22+ required, found v$NODE_VER"
    MISSING=1
  fi
fi

# kiro-cli
if command -v kiro-cli &>/dev/null; then
  ok "kiro-cli ($(command -v kiro-cli))"
else
  warn "kiro-cli — not found. Install: curl -fsSL https://cli.kiro.dev/install | bash"
fi

if (( MISSING )); then
  echo ""
  echo "Install missing dependencies and re-run."
  exit 1
fi

# --- 2. Install npm deps ---
if [[ ! -d node_modules ]]; then
  echo ""
  echo "Installing dependencies..."
  pnpm install
else
  ok "node_modules exists"
fi

# --- 3. Generate kiro-proxy-routes.json ---
echo ""
if [[ -f kiro-proxy-routes.json ]]; then
  ok "kiro-proxy-routes.json already exists"
else
  if [[ -z "$CHANNEL_ID" ]]; then
    echo "No kiro-proxy-routes.json found."
    read -rp "  Discord channel ID for this repo (leave blank to skip): " CHANNEL_ID
  fi
  if [[ -n "$CHANNEL_ID" ]]; then
    python3 -c "
import json
routes = {
    '$CHANNEL_ID': {
        'cwd': '$REPO_ROOT',
        'kiroArgs': ['--agent', 'default', '--trust-all-tools'],
        'noHibernate': True
    }
}
with open('kiro-proxy-routes.json', 'w') as f:
    json.dump(routes, f, indent=2)
    f.write('\n')
"
    ok "Created kiro-proxy-routes.json ($CHANNEL_ID → $REPO_ROOT)"
  else
    # Create minimal empty routes so spinup doesn't break
    echo '{}' > kiro-proxy-routes.json
    warn "Created empty kiro-proxy-routes.json — add channels with scripts/add-channel.sh"
  fi
fi

# --- 4. Symlink spinup ---
echo ""
SPINUP_SRC="$REPO_ROOT/scripts/spinup"
SPINUP_DST="$HOME/bin/spinup"
mkdir -p "$HOME/bin"
if [[ -L "$SPINUP_DST" && "$(readlink -f "$SPINUP_DST")" == "$(readlink -f "$SPINUP_SRC")" ]]; then
  ok "~/bin/spinup already linked"
elif [[ -e "$SPINUP_DST" ]]; then
  warn "~/bin/spinup exists but points elsewhere: $(readlink -f "$SPINUP_DST")"
  read -rp "  Overwrite? [y/N] " ans
  if [[ "${ans:-N}" =~ ^[Yy]$ ]]; then
    ln -sf "$SPINUP_SRC" "$SPINUP_DST"
    ok "Relinked ~/bin/spinup"
  else
    warn "Skipped — link manually: ln -sf $SPINUP_SRC $SPINUP_DST"
  fi
else
  ln -sf "$SPINUP_SRC" "$SPINUP_DST"
  ok "Linked ~/bin/spinup → scripts/spinup"
fi

# Check PATH
if ! echo "$PATH" | tr ':' '\n' | grep -qx "$HOME/bin"; then
  warn "~/bin is not in PATH. Add to ~/.bashrc:  export PATH=\"\$HOME/bin:\$PATH\""
fi

# --- 5. OpenClaw config (Discord token + gateway) ---
echo ""
CONFIG_FILE="$HOME/.openclaw/openclaw.json"
if [[ -f "$CONFIG_FILE" ]]; then
  ok "~/.openclaw/openclaw.json exists"
  # Check for discord token
  HAS_TOKEN=$(python3 -c "
import json
with open('$CONFIG_FILE') as f:
    d = json.load(f)
t = d.get('channels',{}).get('discord',{}).get('token','')
print('yes' if t else 'no')
" 2>/dev/null || echo "no")
  if [[ "$HAS_TOKEN" == "yes" ]]; then
    ok "Discord bot token configured"
  else
    warn "No Discord bot token in config"
  fi
else
  echo "No ~/.openclaw/openclaw.json found. Setting up..."
  mkdir -p "$HOME/.openclaw"

  if [[ -z "$DISCORD_TOKEN" ]]; then
    read -rsp "  Discord bot token (paste, hidden): " DISCORD_TOKEN
    echo ""
  fi

  if [[ -n "$DISCORD_TOKEN" ]]; then
    pnpm openclaw config set channels.discord.token "$DISCORD_TOKEN"
    pnpm openclaw config set channels.discord.enabled true --strict-json
    pnpm openclaw config set gateway.mode local
    pnpm openclaw config set gateway.port 18800 --strict-json
    pnpm openclaw config set gateway.bind loopback
    ok "Config created with Discord token and gateway settings"
  else
    warn "Skipped config — run 'pnpm openclaw config' for guided setup"
  fi
fi

# --- 6. Build ---
echo ""
echo "Building..."
pnpm build
ok "Build complete"

# --- Done ---
echo ""
echo "=== Setup complete ==="
echo ""
echo "Start the system:"
echo "  spinup oc        # proxy + gateway"
echo "  spinup oc-cli    # interactive kiro-cli session"
echo ""
echo "Add project channels:"
echo "  scripts/add-channel.sh <name> /path/to/project"
echo ""
echo "See docs/setup.md for full documentation."
