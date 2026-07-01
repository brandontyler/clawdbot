#!/bin/bash
# Pre-start check: verify the openclaw build completed end-to-end before the
# gateway starts. Prevents the gateway from starting on a partial dist (the
# May 20-21 outage scenario).
#
# Strategy: rather than hardcode dist file paths (which change with the build
# layout — rolldown emits hashed bundle names, and the directory structure
# evolves upstream), trust openclaw's own build-completion stamps:
#
#   dist/.buildstamp              — written by scripts/build-stamp.mjs
#   dist/.runtime-postbuildstamp  — written by scripts/runtime-postbuild-stamp.mjs
#                                   (the LAST step of `pnpm build`)
#
# If the postbuild stamp exists and is at least as new as the build stamp,
# the build pipeline ran to completion. Either missing or out-of-order means
# the build was interrupted or the dist is stale relative to a partial rebuild.
#
# AUTO-ROLLBACK (added 2026-06-30): if dist/ is broken (missing stamps,
# out-of-order stamps, or dist/ entirely absent) but dist.last-good/ holds a
# complete snapshot from a prior successful build, this script promotes the
# snapshot back to dist/ and exits 0. Pair with scripts/safer-build.sh which
# writes the snapshot before each build attempt. This converts the cascade
# "interrupted build → crash-loop → outage" into "interrupted build → systemd
# auto-recovers to previous good version" with no operator intervention.
set -e
REPO_ROOT="/home/ubuntu/openclaw"
DIST="$REPO_ROOT/dist"
BUILD_STAMP="$DIST/.buildstamp"
POSTBUILD_STAMP="$DIST/.runtime-postbuildstamp"
LASTGOOD="$REPO_ROOT/dist.last-good"

# Returns 0 if dist at $1 looks consistent (both stamps present and ordered)
dist_is_consistent() {
  local d="$1"
  [ -f "$d/.buildstamp" ] && [ -f "$d/.runtime-postbuildstamp" ] && \
    [ ! "$d/.buildstamp" -nt "$d/.runtime-postbuildstamp" ]
}

attempt_rollback() {
  local reason="$1"
  if dist_is_consistent "$LASTGOOD"; then
    local ts
    ts="$(date +%Y%m%d-%H%M%S)"
    echo "WARN: $reason"
    echo "WARN: Rolling back to $LASTGOOD (snapshot from $(stat -c %y "$LASTGOOD/.runtime-postbuildstamp"))"
    if [ -d "$DIST" ]; then
      mv "$DIST" "$REPO_ROOT/dist.broken.$ts"
      echo "INFO: Broken dist preserved at dist.broken.$ts for forensics"
    fi
    mv "$LASTGOOD" "$DIST"
    echo "INFO: Rollback complete. Re-validating..."
    if dist_is_consistent "$DIST"; then
      echo "Gateway dist verification passed (rolled back to last-known-good)"
      return 0
    else
      echo "FATAL: Rollback completed but dist still inconsistent. Manual recovery needed."
      return 1
    fi
  fi
  return 1
}

# Happy path: current dist is consistent → green light
if dist_is_consistent "$DIST"; then
  echo "Gateway dist verification passed (build stamps present and consistent)"
  exit 0
fi

# Diagnose the specific failure mode and try rollback
if [ ! -d "$DIST" ]; then
  attempt_rollback "dist/ does not exist — never built or wiped" || {
    echo "FATAL: dist/ missing and no dist.last-good available. Run 'pnpm build' (or scripts/safer-build.sh)."
    exit 1
  }
elif [ ! -f "$BUILD_STAMP" ]; then
  attempt_rollback "Missing $BUILD_STAMP — build never ran (or dist/ was wiped)" || {
    echo "FATAL: Missing $BUILD_STAMP and no dist.last-good available. Run 'pnpm build'."
    exit 1
  }
elif [ ! -f "$POSTBUILD_STAMP" ]; then
  attempt_rollback "Missing $POSTBUILD_STAMP — build was interrupted before runtime-postbuild step" || {
    echo "FATAL: Missing $POSTBUILD_STAMP and no dist.last-good available. Run 'pnpm build'."
    exit 1
  }
elif [ "$BUILD_STAMP" -nt "$POSTBUILD_STAMP" ]; then
  attempt_rollback "$BUILD_STAMP is newer than $POSTBUILD_STAMP — partial rebuild detected" || {
    echo "FATAL: Partial rebuild and no dist.last-good available. Run 'pnpm build'."
    exit 1
  }
else
  echo "FATAL: Unknown verification failure. Manual recovery needed."
  exit 1
fi
