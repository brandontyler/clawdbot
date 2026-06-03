#!/usr/bin/env bash
# install-systemd-units.sh — Install OpenClaw EC2 systemd user units.
#
# Idempotent: copies (not symlinks) all unit files from ops/systemd/units/
# into ~/.config/systemd/user/, then runs daemon-reload. Existing files
# are overwritten. To enable + start timers, pass --enable.
#
# Usage:
#   ./ops/install-systemd-units.sh             # install + daemon-reload only
#   ./ops/install-systemd-units.sh --enable    # also enable + start every .timer
#   ./ops/install-systemd-units.sh --dry-run   # show what would change
#   ./ops/install-systemd-units.sh --diff      # show diff against installed
#
# Notes:
# - This script does NOT touch gog.env. If you're setting up a fresh box,
#   copy ops/systemd/gog.env.example to ~/.config/systemd/user/gog.env,
#   fill in the password, and chmod 600 it.
# - Service ExecStart paths assume /home/ubuntu/openclaw and an nvm-based
#   Node install at /home/ubuntu/.nvm/versions/node/v22.16.0. Adjust the
#   units in the repo if your layout differs.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
UNITS_SRC="$REPO_DIR/ops/systemd/units"
UNITS_DEST="$HOME/.config/systemd/user"

DRY_RUN=0
ENABLE=0
DIFF_ONLY=0

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --enable)  ENABLE=1 ;;
    --diff)    DIFF_ONLY=1 ;;
    -h|--help)
      sed -n '2,/^set -euo/p' "$0" | grep '^#' | sed 's|^# \?||'
      exit 0
      ;;
    *)
      echo "unknown flag: $arg" >&2
      exit 1
      ;;
  esac
done

if [ ! -d "$UNITS_SRC" ]; then
  echo "ERROR: $UNITS_SRC does not exist" >&2
  exit 1
fi

mkdir -p "$UNITS_DEST"

changed=0
for src in "$UNITS_SRC"/*.service "$UNITS_SRC"/*.timer; do
  [ -e "$src" ] || continue
  base=$(basename "$src")
  dest="$UNITS_DEST/$base"

  if [ "$DIFF_ONLY" -eq 1 ]; then
    if [ -e "$dest" ]; then
      if ! cmp -s "$src" "$dest"; then
        echo "=== $base (would change) ==="
        diff -u "$dest" "$src" | head -20
      fi
    else
      echo "=== $base (would install — not present) ==="
    fi
    continue
  fi

  if [ -e "$dest" ] && cmp -s "$src" "$dest"; then
    continue   # already up to date
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    if [ -e "$dest" ]; then
      echo "would update: $base"
    else
      echo "would install: $base"
    fi
    changed=$((changed + 1))
    continue
  fi

  cp "$src" "$dest"
  echo "installed: $base"
  changed=$((changed + 1))
done

[ "$DIFF_ONLY" -eq 1 ] && exit 0

if [ "$DRY_RUN" -eq 1 ]; then
  echo ""
  echo "Dry run: $changed file(s) would change. Run without --dry-run to apply."
  exit 0
fi

if [ "$changed" -gt 0 ]; then
  echo ""
  echo "Reloading systemd user daemon..."
  systemctl --user daemon-reload
  echo "Done."
fi

if [ "$ENABLE" -eq 1 ]; then
  echo ""
  echo "Enabling + starting all timers..."
  for src in "$UNITS_SRC"/*.timer; do
    [ -e "$src" ] || continue
    timer=$(basename "$src")
    systemctl --user enable --now "$timer" 2>&1 | sed "s|^|  $timer: |"
  done
fi

echo ""
echo "Installed units:"
ls "$UNITS_DEST" | grep -E '\.(service|timer)$' | grep -v '\.bak$' | sort | sed 's|^|  |'
