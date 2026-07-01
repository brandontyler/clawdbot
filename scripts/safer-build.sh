#!/bin/bash
# safer-build.sh — pnpm build wrapper that snapshots the last-known-good
# dist before rebuilding, so an interrupted build doesn't leave the gateway
# dead (it can auto-rollback at startup via verify-gateway-dist.sh).
#
# How it works:
#   1. If dist/.runtime-postbuildstamp exists (= last build completed end-to-end),
#      hardlink-copy dist → dist.last-good. Hardlinks cost ~zero disk because
#      every unchanged file shares its inode with the original.
#   2. Run pnpm build. tsdown writes new content to dist/ in place (--no-clean).
#      Modified files break the hardlink (CoW behavior of cp -al) — the snapshot
#      stays unchanged and only newly-replaced files use extra disk.
#   3. On failure (non-zero exit OR missing stamps), leave dist.last-good in
#      place. verify-gateway-dist.sh sees it and can promote it back to dist/
#      during the next gateway start.
#
# CONCURRENCY (flock, added 2026-06-30 — Tier 2 of the build-stall outage fix):
#   Because the build writes dist/ IN PLACE (tsdown --no-clean), two builds
#   running at once can interleave their writes and leave a partial dist/ with
#   missing/out-of-order stamps. An flock on .build.lock guarantees only ONE
#   build touches dist/ at a time.
#
# LIVE-CLOBBER GUARD (added 2026-07-01 after a 3rd outage):
#   An in-place build ALSO wipes/rewrites dist/ out from under an already-running
#   gateway/proxy (2026-07-01 06:34: an agent ran this script while the gateway
#   was live → gateway served HTTP 503 "Control UI assets not found" for ~30min).
#   Services load dist/ at startup and do NOT hot-reload it, so building in place
#   while they serve is pure downside. This script now REFUSES when the gateway
#   (:18800) or proxy (:18801) is listening. Override for a real maintenance
#   window with SAFER_BUILD_ALLOW_LIVE=1. The right long-term fix is to build
#   off-box (CI) and ship dist/, or build to a staging dir and atomically swap.
#
# Usage:
#   scripts/safer-build.sh
#
# Env:
#   SAFER_BUILD_CMD          Build command (default: "pnpm build"). Overridable
#                            so the lock behavior can be tested without a build.
#   SAFER_BUILD_ALLOW_LIVE   Set to 1 to build even while services are live.
#
# Idempotent. Safe to wedge into systemd ExecStart or run manually.
set -euo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"
DIST="$REPO_ROOT/dist"
LASTGOOD="$REPO_ROOT/dist.last-good"
LOCKFILE="$REPO_ROOT/.build.lock"
BUILD_CMD="${SAFER_BUILD_CMD:-pnpm build}"

log() { printf '[safer-build] %s\n' "$*" >&2; }

# Refuse to clobber a LIVE dist/ (see LIVE-CLOBBER GUARD above).
if [ "${SAFER_BUILD_ALLOW_LIVE:-0}" != "1" ]; then
  live=""
  for port in 18800 18801; do
    if ss -ltn 2>/dev/null | grep -q ":${port} "; then live="${live} ${port}"; fi
  done
  if [ -n "$live" ]; then
    log "REFUSING to build: service(s) listening on${live} (gateway 18800 / proxy 18801)."
    log "An in-place build rewrites dist/ under them and takes them down."
    log "Deploy by building off-box and shipping dist/, or stop the services first,"
    log "or re-run with SAFER_BUILD_ALLOW_LIVE=1 for a deliberate maintenance window."
    exit 3
  fi
fi

# 0. Serialize builds. Hold an exclusive lock for the whole snapshot+build so a
#    concurrent invocation cannot interleave writes into dist/. fd 9 stays open
#    for the life of the process and the lock releases automatically on exit.
exec 9>"$LOCKFILE"
if ! flock -w 900 9; then
  log "Another build holds $LOCKFILE and did not release within 15m — refusing to run concurrently"
  exit 1
fi
log "Acquired build lock ($LOCKFILE)"

# 1. Snapshot last-known-good dist (only if the previous build actually completed)
if [ -f "$DIST/.runtime-postbuildstamp" ] && [ -f "$DIST/.buildstamp" ]; then
  log "Snapshotting current dist → dist.last-good (hardlinked, ~0 disk)"
  rm -rf "$LASTGOOD"
  cp -al "$DIST" "$LASTGOOD"
else
  log "No complete dist to snapshot (skipping backup step)"
fi

# 2. Run the build
log "Running build: $BUILD_CMD"
if ! $BUILD_CMD; then
  rc=$?
  log "BUILD FAILED (exit=$rc). dist.last-good preserved at $LASTGOOD"
  log "Gateway can auto-rollback at next start via verify-gateway-dist.sh"
  exit "$rc"
fi

# 3. Verify the new build is consistent
if [ ! -f "$DIST/.buildstamp" ] || [ ! -f "$DIST/.runtime-postbuildstamp" ]; then
  log "Build completed but stamps are missing — something is wrong"
  log "dist.last-good preserved at $LASTGOOD for rollback"
  exit 1
fi
if [ "$DIST/.buildstamp" -nt "$DIST/.runtime-postbuildstamp" ]; then
  log "Build completed but stamps are out of order (partial rebuild)"
  log "dist.last-good preserved at $LASTGOOD for rollback"
  exit 1
fi

log "Build succeeded ($(stat -c %y "$DIST/.runtime-postbuildstamp"))"
log "New dist promoted; dist.last-good still holds previous build for emergency rollback"
