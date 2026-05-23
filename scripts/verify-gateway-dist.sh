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
set -e
DIST="/home/ubuntu/openclaw/dist"
BUILD_STAMP="$DIST/.buildstamp"
POSTBUILD_STAMP="$DIST/.runtime-postbuildstamp"

if [ ! -f "$BUILD_STAMP" ]; then
  echo "FATAL: Missing $BUILD_STAMP — build never ran (or dist/ was wiped). Run 'pnpm build'."
  exit 1
fi
if [ ! -f "$POSTBUILD_STAMP" ]; then
  echo "FATAL: Missing $POSTBUILD_STAMP — build was interrupted before runtime-postbuild step. Run 'pnpm build'."
  exit 1
fi
# Postbuild stamp must be no older than the build stamp (else dist is partially rebuilt).
if [ "$BUILD_STAMP" -nt "$POSTBUILD_STAMP" ]; then
  echo "FATAL: $BUILD_STAMP is newer than $POSTBUILD_STAMP — partial rebuild detected. Run 'pnpm build'."
  exit 1
fi
echo "Gateway dist verification passed (build stamps present and consistent)"
