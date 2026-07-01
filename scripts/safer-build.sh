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
#   missing/out-of-order stamps. That is exactly the state that crash-looped the
#   proxy through systemd's StartLimitBurst and produced the ~4h outage on
#   2026-06-30. An flock on .build.lock guarantees only ONE build touches dist/
#   at a time. A second invocation waits up to 15 minutes for the lock, then
#   bails (exit 1) rather than racing. ALWAYS build via this script, never a bare
#   `pnpm build`, so the lock actually protects you.
#
# Usage:
#   scripts/safer-build.sh
#
# Env:
#   SAFER_BUILD_CMD   Build command to run (default: "pnpm build"). Overridable
#                     so the lock behavior can be tested without a full build.
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
