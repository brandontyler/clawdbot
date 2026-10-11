#!/usr/bin/env bash
# guard-openclaw-dist.sh — kiro-cli preToolUse guard for the `shell` tool.
#
# WHY: ~/openclaw/dist/ is the compiled JS that the LIVE openclaw-gateway runs.
# tsdown.config.ts has `clean: true`, so `pnpm build` rm -rf's dist/ as its very
# first step and then needs ~6 min on this 4-core box. On 2026-09-05 the Hermes-Kiro
# worker ran `pnpm build` in-place to "verify" a change; the ACP turn timed out, the
# wrapper group-killed the child mid-build, and dist/ stayed gone. Services showed
# `active` (everything already in memory) while every Discord channel silently died.
# See ~/.hermes/skills/devops/openclaw-ec2-recovery/SKILL.md "Failure Mode 1b".
#
# WHAT IT BLOCKS (only when aimed at ~/openclaw — ~/openclaw-stage is fine):
#   pnpm/npm/bun/yarn build*, ui:build, clean:dist · node scripts/{build-all,tsdown-build,runtime-postbuild}.mjs
#   pnpm openclaw|dev|start|tui|gateway:dev|gateway:watch|proxy:*|openclaw:rpc|test:all (→ scripts/run-node.mjs,
#     which silently rebuilds in place when HEAD is ahead of dist/.buildstamp — 2026-09-28 outage)
#   node scripts/{run-node,watch-node,gateway-watch-tmux}.mjs
#   tsdown · rm/mv/rsync/rimraf/rmSync/rmtree/find -delete touching dist/ or dist.last-good
#   git clean with -x/-X (nukes ignored files incl. dist/)
# "Aimed at ~/openclaw" = shell tool working_dir / session cwd is ~/openclaw or below,
#   OR the command text references /home/ubuntu/openclaw, ~/openclaw, $HOME/openclaw.
# Everything else (pnpm test, tsgo, check:changed, format, oxlint, git status…) passes.
#
# Wire via agent config: hooks.preToolUse[{ "matcher": "shell", "command": "bash /home/ubuntu/.kiro/hooks/guard-openclaw-dist.sh" }]
# Deploy everywhere with: bash ~/.kiro/hooks/deploy-dist-guard.sh
# Exit 0 = allow · Exit 2 = block (STDERR shown to the model). Fails OPEN on unparseable input.
# Debug: GUARD_DIST_LOG=/tmp/guard-dist.log to append every decision.
set -uo pipefail
EVENT="$(cat)"
VERDICT="$(EVENT="$EVENT" PWD_FALLBACK="$PWD" python3 - <<'PY'
import os, json, re, sys
try:
    ev = json.loads(os.environ["EVENT"])
except Exception:
    sys.exit(0)  # unparseable → don't block
ti = ev.get("tool_input") or {}
cmd = ti.get("command") if isinstance(ti, dict) else None
if not isinstance(cmd, str) or not cmd.strip():
    sys.exit(0)

REPO = "/home/ubuntu/openclaw"
home = "/home/ubuntu"

def norm(p):
    if not p or not isinstance(p, str):
        return None
    p = os.path.expanduser(p.replace("$HOME", home))
    if not os.path.isabs(p):
        p = os.path.join(ev.get("cwd") or os.environ.get("PWD_FALLBACK") or "/", p)
    return os.path.normpath(p)

def under_repo(p):
    return p is not None and (p == REPO or p.startswith(REPO + "/"))

effective_dir = norm(ti.get("working_dir")) or norm(ev.get("cwd")) or norm(os.environ.get("PWD_FALLBACK"))
# Does the command text itself point at the repo? (cd ~/openclaw && …, absolute paths…)
# Require a terminator after "openclaw" so ~/openclaw-stage / openclaw-releases don't match.
mentions_repo = re.search(r'(/home/ubuntu/openclaw|~/openclaw|\$HOME/openclaw|\$\{HOME\}/openclaw)(?=[/\s;&|"\'`)]|$)', cmd) is not None
aimed = under_repo(effective_dir) or mentions_repo
if not aimed:
    sys.exit(0)

# dist token: "dist" or "dist.last-good" as a path component, not dist.prev-* / dist.new / dist-runtime.
DIST = r'(?:^|[\s/=:"\'`])dist(?:\.last-good)?(?=[/\s"\'`;&|)]|$)'
SEG = r'[^;&|\n]*'  # stay within one pipeline segment
patterns = [
    (r'\b(?:pnpm|npm|bun|yarn)\s+(?:(?:-{1,2}[\w-]+(?:[= ]\S+)?|run|exec)\s+)*(?:build(?::[\w.:-]+)?|ui:build|clean:dist)(?=[\s;&|"\'`)]|$)', "package-script build/clean wipes dist/"),
    # run-node.mjs auto-rebuilds when HEAD/sources are newer than dist/.buildstamp, and
    # tsdown-build.mjs rm -rf's dist/ first regardless of --no-clean (2026-09-28 outage:
    # `pnpm -s openclaw plugins list` / `memory status` in the live tree).
    (r'\b(?:pnpm|npm|bun|yarn)\s+(?:(?:-{1,2}[\w-]+(?:[= ]\S+)?|run|exec)\s+)*(?:openclaw(?::rpc)?|moltbot:rpc|dev|start|tui(?::dev)?|gateway:(?:dev(?::reset)?|watch(?::raw)?)|proxy:[\w:-]+|test:all|test:cli-response:contract)(?=[\s;&|"\'`)]|$)', "package script runs run-node.mjs, which auto-rebuilds (rm -rf dist/) when HEAD is ahead of the build"),
    (r'scripts/(?:build-all|tsdown-build|runtime-postbuild|run-node|watch-node|gateway-watch-tmux)\.mjs|scripts/ui\.js\s+build', "direct build/run-node script writes/cleans dist/"),
    (r'(?<![\w/.-])tsdown(?![\w-])', "tsdown (clean:true) wipes dist/"),
    (r'\b(?:rm|rmdir|mv|rsync|rimraf|trash|shred)\b' + SEG + DIST, "removes/moves dist/"),
    (r'\bfind\b' + SEG + DIST + SEG + r'-(?:delete|exec\s+rm)', "find … -delete on dist/"),
    (r'(?:rmSync|rmdirSync|rm)\s*\(' + SEG + DIST, "fs.rm* on dist/"),
    (r'rmtree\s*\(' + SEG + DIST, "shutil.rmtree on dist/"),
    (r'\bgit\s+clean\b' + SEG + r'\s-\w*[xX]', "git clean -x removes ignored files incl. dist/"),
]
hit = None
for pat, why in patterns:
    if re.search(pat, cmd, re.M):
        hit = why
        break
if hit:
    print(json.dumps({"why": hit, "dir": effective_dir, "cmd": cmd[:600]}))
PY
)"
if [ -n "${GUARD_DIST_LOG:-}" ]; then
  printf '%s verdict=%s event=%s\n' "$(date -Is)" "${VERDICT:-allow}" "${EVENT:0:800}" >> "$GUARD_DIST_LOG" 2>/dev/null || true
fi
[ -z "$VERDICT" ] && exit 0
WHY="$(printf '%s' "$VERDICT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["why"])')"
DIR="$(printf '%s' "$VERDICT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["dir"])')"
{
  echo "BLOCKED by guard-openclaw-dist.sh — $WHY (working dir: $DIR)."
  echo "~/openclaw/dist/ is what the LIVE openclaw-gateway is running from. tsdown has clean:true, so any build"
  echo "rm -rf's dist/ first and then needs ~6 min; if this turn times out or the child is killed, dist/ stays gone"
  echo "and every OpenClaw Discord channel dies while systemd still says 'active' (2026-09-05 and again 2026-09-28)."
  echo ""
  echo "Do this instead:"
  echo "  • To run the OpenClaw CLI (status, plugins list, memory status, doctor…): node openclaw.mjs <args>"
  echo "    from ~/openclaw — it runs the existing dist/ and never rebuilds. NOT 'pnpm openclaw' / 'pnpm dev'"
  echo "    (those go through scripts/run-node.mjs, which rebuilds in place whenever HEAD is newer than the build)."
  echo "  • To verify a change compiles/passes: pnpm tsgo:core · pnpm test <file> · pnpm check:changed · pnpm format:check — none touch dist/."
  echo "  • If a real build is required: bash scripts/staged-deploy.sh stage"
  echo "    (builds at HEAD in ~/openclaw-stage under a memory cap; the live tree is never touched; safe to run any time)."
  echo "    Then report 'STAGE OK' and let Brandon or Fable decide when to run 'promote' (it restarts live services)."
  echo "  • Never delete/move ~/openclaw/dist or dist.last-good — dist.last-good is the reboot-time rollback snapshot."
  echo ""
  echo "Blocked command: $(printf '%s' "$VERDICT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["cmd"][:300])')"
} >&2
exit 2
