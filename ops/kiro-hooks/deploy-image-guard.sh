#!/usr/bin/env bash
# deploy-image-guard.sh — wire the preToolUse image-guard hook into kiro agent
# configs so oversized image reads can't poison a session. Idempotent: skips
# configs that already have it. Re-run after adding a new channel/agent.
#
# Usage: deploy-image-guard.sh [config.json ...]
#   No args → auto-discovers the global agent + every channel's local default.json.
set -euo pipefail
HOOK='bash /home/ubuntu/.kiro/hooks/guard-image-read.sh'

if [ "$#" -gt 0 ]; then
  CONFIGS=("$@")
else
  mapfile -t CONFIGS < <(
    ls /home/ubuntu/.kiro/agents/*.json 2>/dev/null
    find /home/ubuntu/openclaw /home/ubuntu/code/personal -maxdepth 5 -path '*/.kiro/agents/*.json' 2>/dev/null
  )
fi

for cfg in "${CONFIGS[@]}"; do
  [ -f "$cfg" ] || continue
  CFG="$cfg" HOOK="$HOOK" python3 - <<'PY'
import os, json
cfg, hook = os.environ["CFG"], os.environ["HOOK"]
try:
    d = json.load(open(cfg))
except Exception as e:
    print(f"SKIP (unparseable): {cfg} [{e}]"); raise SystemExit(0)
hooks = d.setdefault("hooks", {})
pre = hooks.setdefault("preToolUse", [])
if any("guard-image-read.sh" in (h.get("command","")) for h in pre if isinstance(h, dict)):
    print(f"ok (already present): {cfg}"); raise SystemExit(0)
pre.append({"matcher": "read", "command": hook,
            "description": "Block oversized image reads (>1568px/1.15MP) that would 500 + poison the session"})
json.dump(d, open(cfg, "w"), indent=2); open(cfg, "a").write("\n")
print(f"ADDED image-guard hook → {cfg}")
PY
done
