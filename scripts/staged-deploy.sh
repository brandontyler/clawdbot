#!/bin/bash
# staged-deploy.sh — build in an isolated worktree, verify, then atomically
# promote to the live dist/. The live gateway/proxy are NEVER exposed to a
# partial or failed build. Direct replacement for "stop services, pray,
# safer-build, restart".
#
# WHY (2026-07-01/02): three outages were caused by in-place builds clobbering
# dist/ under live services, plus unbounded builds that stall for 20-30 min
# eating memory. This script:
#   - builds at a COMMIT (HEAD of ~/openclaw) in ~/openclaw-stage (git worktree)
#   - caps the build: MemoryHigh=6G MemoryMax=8G, CPUQuota=300%, hard 20m timeout
#   - verifies stamps + expected content BEFORE anything touches the live tree
#   - promotes via two directory renames (never a partially-written dist/)
#   - keeps dist.prev for instant rollback; refreshes dist.last-good only after
#     you confirm services are healthy (phase: bless)
#
# Usage:
#   scripts/staged-deploy.sh stage     # worktree sync + install + capped build + verify (SAFE while live)
#   scripts/staged-deploy.sh promote   # swap staged dist into place + restart services + health check
#   scripts/staged-deploy.sh bless     # after you're happy: refresh dist.last-good from live dist
#   scripts/staged-deploy.sh rollback  # emergency: swap dist.prev back + restart
#
# Phases are intentionally separate: 'stage' can run any time with zero risk;
# 'promote' is the only moment services blip (hibernation preserves sessions).
set -euo pipefail

REPO="$HOME/openclaw"
STAGE="$HOME/openclaw-stage"
DIST="$REPO/dist"
LOCKFILE="$REPO/.build.lock"

log() { printf '[staged-deploy] %s\n' "$*" >&2; }
die() { log "FATAL: $*"; exit 1; }

node_env() {
  export NVM_DIR="$HOME/.nvm"
  # shellcheck disable=SC1091
  [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
  nvm use 22 >/dev/null 2>&1 || true
  export PATH="$HOME/.local/share/pnpm:$PATH"
}

verify_staged_dist() {
  local d="$STAGE/dist" head_now stamp_head
  [ -f "$d/.buildstamp" ] || die "staged dist missing .buildstamp"
  [ -f "$d/.runtime-postbuildstamp" ] || die "staged dist missing .runtime-postbuildstamp"
  [ "$d/.buildstamp" -nt "$d/.runtime-postbuildstamp" ] && die "staged stamps out of order (partial build)"
  head_now="$(git -C "$REPO" rev-parse HEAD)"
  stamp_head="$(node -e "console.log(JSON.parse(require('fs').readFileSync('$d/.buildstamp','utf8')).head)")"
  [ "$stamp_head" = "$head_now" ] || die "staged build head $stamp_head != repo HEAD $head_now (stale stage?)"
  log "staged dist verified: stamps consistent, head=$stamp_head matches repo HEAD"
}

case "${1:-}" in
stage)
  node_env
  # Serialize against any other build path (shares safer-build's lock).
  exec 9>"$LOCKFILE"
  flock -w 60 9 || die "another build holds $LOCKFILE"

  HEAD="$(git -C "$REPO" rev-parse HEAD)"
  log "staging build of $HEAD"

  if [ ! -d "$STAGE" ]; then
    log "creating stage worktree (detached) at $STAGE"
    git -C "$REPO" worktree add --detach "$STAGE" "$HEAD"
  else
    git -C "$STAGE" checkout --detach "$HEAD" --force
    git -C "$STAGE" clean -fd -e node_modules -e dist -e pnpm-lock.yaml >/dev/null
  fi

  # pnpm-lock.yaml is GITIGNORED on this fork — the worktree gets none, and a
  # frozen install then fails with LOCKFILE_CONFIG_MISMATCH (empty lockfile vs
  # workspace overrides). The main repo's untracked lockfile IS the known-good
  # resolution the running system was built with; mirror it into the stage so
  # we build with the exact same dependency set. Never resolve fresh here.
  [ -f "$REPO/pnpm-lock.yaml" ] || die "$REPO/pnpm-lock.yaml missing — cannot reproduce known-good deps"
  cp -f "$REPO/pnpm-lock.yaml" "$STAGE/pnpm-lock.yaml"

  cd "$STAGE"
  log "pnpm install --frozen-lockfile (lockfile mirrored from main repo; hardlinks from store)"
  pnpm install --frozen-lockfile --prefer-offline

  log "running capped build: MemoryHigh=6G MemoryMax=8G CPUQuota=300% timeout=20m"
  # systemd-run scope => the cgroup cap kills a runaway build, never the box.
  # timeout => a tsdown stall dies at 20m instead of running forever.
  if ! systemd-run --user --scope --quiet \
      -p MemoryHigh=6G -p MemoryMax=8G -p CPUQuota=300% \
      timeout 20m pnpm build; then
    die "staged build FAILED or timed out — live services untouched, nothing to clean up"
  fi

  verify_staged_dist
  log "STAGE OK. Next: scripts/staged-deploy.sh promote"
  ;;

promote)
  verify_staged_dist
  TS="$(date +%Y%m%d-%H%M%S)"
  log "hardlink-copying staged dist → dist.new (same fs, ~0 extra disk)"
  rm -rf "$REPO/dist.new"
  cp -al "$STAGE/dist" "$REPO/dist.new"

  log "atomic swap: dist → dist.prev-$TS ; dist.new → dist"
  [ -d "$DIST" ] && mv -T "$DIST" "$REPO/dist.prev-$TS"
  mv -T "$REPO/dist.new" "$DIST"

  log "restarting services (hibernation preserves proxy sessions)"
  systemctl --user restart kiro-proxy
  systemctl --user restart openclaw-gateway

  # Gateway takes ~10-15s to bind :18800 after restart — poll, don't one-shot.
  code=000
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
    sleep 5
    code="$(curl -sS -o /dev/null -w '%{http_code}' -m 10 http://127.0.0.1:18800/v1/models 2>/dev/null || echo 000)"
    [ "$code" = "200" ] && break
  done
  if [ "$code" = "200" ]; then
    log "HEALTH OK: gateway /v1/models -> 200. dist.prev-$TS kept for rollback."
    log "When satisfied, run: scripts/staged-deploy.sh bless   (refreshes dist.last-good)"
  else
    log "HEALTH CHECK FAILED (got '$code'). Roll back with: scripts/staged-deploy.sh rollback"
    exit 1
  fi
  ;;

bless)
  [ -f "$DIST/.runtime-postbuildstamp" ] || die "live dist has no complete stamps; refusing to bless"
  log "refreshing dist.last-good from live dist (hardlinked)"
  rm -rf "$REPO/dist.last-good"
  cp -al "$DIST" "$REPO/dist.last-good"
  # prune old dist.prev-* keeping the newest two
  ls -dt "$REPO"/dist.prev-* 2>/dev/null | tail -n +3 | xargs -r rm -rf
  log "blessed. rollback snapshots retained: $(ls -d "$REPO"/dist.prev-* 2>/dev/null | wc -l)"
  ;;

rollback)
  PREV="$(ls -dt "$REPO"/dist.prev-* 2>/dev/null | head -1)"
  [ -n "$PREV" ] || die "no dist.prev-* snapshot found"
  TS="$(date +%Y%m%d-%H%M%S)"
  log "rolling back to $PREV"
  [ -d "$DIST" ] && mv -T "$DIST" "$REPO/dist.failed-$TS"
  mv -T "$PREV" "$DIST"
  systemctl --user restart kiro-proxy
  systemctl --user restart openclaw-gateway
  sleep 3
  curl -sS -o /dev/null -w 'gateway /v1/models -> %{http_code}\n' -m 15 http://127.0.0.1:18800/v1/models || true
  ;;

*)
  echo "usage: $0 {stage|promote|bless|rollback}" >&2
  exit 2
  ;;
esac
