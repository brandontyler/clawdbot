#!/usr/bin/env bash
# deploy-dist-guard.sh — wire the preToolUse openclaw-dist guard into kiro agent
# configs so no agent can `pnpm build` / rm dist under the live gateway.
# Idempotent: skips configs that already have it. Re-run after adding a new channel/agent.
#
# Usage: deploy-dist-guard.sh [--check] [config.json ...]
#   No args → auto-discovers the global agents + every channel's local agents.
#   --check → report only, change nothing (exit 1 if any config is missing the hook).
set -euo pipefail
HOOK='bash /home/ubuntu/.kiro/hooks/guard-openclaw-dist.sh'
CHECK=0
if [ "${1:-}" = "--check" ]; then CHECK=1; shift; fi

if [ "$#" -gt 0 ]; then
  CONFIGS=("$@")
else
  mapfile -t CONFIGS < <(
    ls /home/ubuntu/.kiro/agents/*.json 2>/dev/null
    find /home/ubuntu/openclaw /home/ubuntu/code/personal /home/ubuntu/hermes-kiro -maxdepth 5 -path '*/.kiro/agents/*.json' -not -path '*/node_modules/*' 2>/dev/null
  )
fi

missing=0
for cfg in "${CONFIGS[@]}"; do
  [ -f "$cfg" ] || continue
  out="$(CFG="$cfg" HOOK="$HOOK" CHECK="$CHECK" python3 - <<'PY'
import os, json
cfg, hook, check = os.environ["CFG"], os.environ["HOOK"], os.environ["CHECK"] == "1"
try:
    d = json.load(open(cfg))
except Exception as e:
    print(f"SKIP (unparseable): {cfg} [{e}]"); raise SystemExit(0)
hooks = d.setdefault("hooks", {})
pre = hooks.setdefault("preToolUse", [])
if any("guard-openclaw-dist.sh" in (h.get("command", "")) for h in pre if isinstance(h, dict)):
    print(f"ok (already present): {cfg}"); raise SystemExit(0)
if check:
    print(f"MISSING: {cfg}"); raise SystemExit(3)
pre.append({"matcher": "shell", "command": hook,
            "description": "Block pnpm build / rm dist in ~/openclaw — live gateway runs from dist/ (2026-09-05 outage)"})
json.dump(d, open(cfg, "w"), indent=2); open(cfg, "a").write("\n")
print(f"ADDED dist-guard hook → {cfg}")
PY
)" || { rc=$?; [ $rc -eq 3 ] && missing=$((missing+1)) || exit $rc; }
  echo "$out"
done
[ $missing -eq 0 ]
