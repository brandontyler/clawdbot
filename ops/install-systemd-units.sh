#!/usr/bin/env bash
# install-systemd-units.sh — Reconcile OpenClaw EC2 systemd units and drop-ins.
#
# Idempotent: copies (not symlinks) repository user units into
# ~/.config/systemd/user/ and repository system drop-ins into
# /etc/systemd/system/. Managed files deleted from the repository are retired.
# With no --unit filters, all user units and system drop-ins are reconciled.
# A --unit filter keeps the original focused user-unit behavior and does not
# reconcile system drop-ins or retire other units.
#
# Usage:
#   ./ops/install-systemd-units.sh                         # reconcile all + reload
#   ./ops/install-systemd-units.sh --enable                # also enable + start selected timers
#   ./ops/install-systemd-units.sh --unit=example.timer    # reconcile one user unit only
#   ./ops/install-systemd-units.sh --dry-run --unit=x.timer
#   ./ops/install-systemd-units.sh --diff                  # show selected diffs and retirements
#
# Notes:
# - System-path reads and writes always use noninteractive sudo (`sudo -n`).
# - This script does NOT touch gog.env. If you're setting up a fresh box,
#   copy ops/systemd/gog.env.example ~/.config/systemd/user/gog.env,
#   fill in the password, and chmod 600 it.
# - Service ExecStart paths assume /home/ubuntu/openclaw and an nvm-based
#   Node install at /home/ubuntu/.nvm/versions/node/v22.16.0. Adjust the
#   units in the repo if your layout differs.
set -euo pipefail

export LC_ALL=C

DEFAULT_REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_DIR="${OPENCLAW_SYSTEMD_REPO_DIR:-$DEFAULT_REPO_DIR}"
UNITS_SRC="$REPO_DIR/ops/systemd/units"
SYSTEM_DROPINS_SRC="$REPO_DIR/ops/systemd/system-dropins"
UNITS_DEST="${OPENCLAW_SYSTEMD_USER_DEST:-$HOME/.config/systemd/user}"
SYSTEM_DROPINS_DEST="${OPENCLAW_SYSTEMD_SYSTEM_DEST:-/etc/systemd/system}"
STATE_DIR="${OPENCLAW_SYSTEMD_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/openclaw}"
USER_MANIFEST="$STATE_DIR/systemd-user-units.manifest"
SYSTEM_DROPINS_MANIFEST="$STATE_DIR/systemd-system-dropins.manifest"

DRY_RUN=0
ENABLE=0
DIFF_ONLY=0
ONLY_UNITS=()

valid_unit_name() {
  [[ "$1" =~ ^[A-Za-z0-9_.@-]+\.(service|timer)$ ]]
}

valid_dropin_path() {
  [[ "$1" =~ ^[A-Za-z0-9_.@-]+\.(service|socket|timer|path|target|mount|automount|slice|scope)\.d/[A-Za-z0-9_.@-]+\.conf$ ]]
}

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --enable) ENABLE=1 ;;
    --diff) DIFF_ONLY=1 ;;
    --unit=*)
      unit="${arg#--unit=}"
      if ! valid_unit_name "$unit"; then
        echo "invalid unit name: $unit" >&2
        exit 1
      fi
      ONLY_UNITS+=("$unit")
      ;;
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

MANAGE_SYSTEM_DROPINS=1
if [ "${#ONLY_UNITS[@]}" -gt 0 ]; then
  MANAGE_SYSTEM_DROPINS=0
elif [ ! -d "$SYSTEM_DROPINS_SRC" ]; then
  echo "ERROR: $SYSTEM_DROPINS_SRC does not exist" >&2
  exit 1
fi

unit_selected() {
  local base="$1"
  [ "${#ONLY_UNITS[@]}" -eq 0 ] && return 0
  local selected
  for selected in "${ONLY_UNITS[@]}"; do
    [ "$base" = "$selected" ] && return 0
  done
  return 1
}

load_manifest() {
  local manifest="$1"
  local kind="$2"
  local -n entries="$3"
  local entry

  [ -f "$manifest" ] || return 0
  while IFS= read -r entry || [ -n "$entry" ]; do
    [ -n "$entry" ] || continue
    if { [ "$kind" = unit ] && valid_unit_name "$entry"; } ||
      { [ "$kind" = dropin ] && valid_dropin_path "$entry"; }; then
      entries["$entry"]=1
    else
      echo "WARNING: ignoring invalid $kind ownership entry: $entry" >&2
    fi
  done <"$manifest"
}

sorted_keys() {
  local -n entries="$1"
  [ "${#entries[@]}" -gt 0 ] || return 0
  printf '%s\n' "${!entries[@]}" | sort
}

write_manifest() {
  local manifest="$1"
  shift
  local manifest_dir tmp
  manifest_dir="$(dirname "$manifest")"
  mkdir -p "$manifest_dir"
  tmp="$(mktemp "$manifest_dir/.manifest.XXXXXX")"
  if [ "$#" -gt 0 ]; then
    printf '%s\n' "$@" | sort -u >"$tmp"
  else
    : >"$tmp"
  fi
  chmod 600 "$tmp"
  mv -f "$tmp" "$manifest"
}

mapfile -t REPO_UNITS < <(
  find "$UNITS_SRC" -maxdepth 1 -type f \( -name '*.service' -o -name '*.timer' \) \
    -printf '%f\n' | sort
)
declare -A CURRENT_USER_UNITS=()
for unit in "${REPO_UNITS[@]}"; do
  if ! valid_unit_name "$unit"; then
    echo "ERROR: unsupported user unit path: $unit" >&2
    exit 1
  fi
  CURRENT_USER_UNITS["$unit"]=1
done

if [ "${#ONLY_UNITS[@]}" -gt 0 ]; then
  for unit in "${ONLY_UNITS[@]}"; do
    if [ -z "${CURRENT_USER_UNITS[$unit]+present}" ]; then
      echo "ERROR: selected unit does not exist: $UNITS_SRC/$unit" >&2
      exit 1
    fi
  done
fi

REPO_DROPINS=()
declare -A CURRENT_SYSTEM_DROPINS=()
if [ "$MANAGE_SYSTEM_DROPINS" -eq 1 ]; then
  mapfile -t REPO_DROPINS < <(find "$SYSTEM_DROPINS_SRC" -type f -printf '%P\n' | sort)
  for dropin in "${REPO_DROPINS[@]}"; do
    if ! valid_dropin_path "$dropin"; then
      echo "ERROR: unsupported system drop-in path: $dropin" >&2
      exit 1
    fi
    CURRENT_SYSTEM_DROPINS["$dropin"]=1
  done
fi

declare -A PREVIOUS_USER_UNITS=()
declare -A PREVIOUS_SYSTEM_DROPINS=()
load_manifest "$USER_MANIFEST" unit PREVIOUS_USER_UNITS
if [ "$MANAGE_SYSTEM_DROPINS" -eq 1 ]; then
  load_manifest "$SYSTEM_DROPINS_MANIFEST" dropin PREVIOUS_SYSTEM_DROPINS
fi

# Before ownership manifests existed, deleted repository units had no ledger.
# Conservatively adopt only historical names whose live bytes exactly match the
# last version committed at that repository path. External units are untouched.
adopt_matching_historical_user_units() {
  [ ! -e "$USER_MANIFEST" ] || return 0
  command -v git >/dev/null 2>&1 || return 0
  git -C "$REPO_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0

  local rel base commit
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    base="${rel##*/}"
    [ "$rel" = "ops/systemd/units/$base" ] || continue
    valid_unit_name "$base" || continue
    [ -z "${CURRENT_USER_UNITS[$base]+present}" ] || continue
    [ -e "$UNITS_DEST/$base" ] || continue
    commit="$(git -C "$REPO_DIR" log -n 1 --format=%H --diff-filter=AM -- "$rel" 2>/dev/null || true)"
    [ -n "$commit" ] || continue
    if git -C "$REPO_DIR" show "$commit:$rel" 2>/dev/null | cmp -s "$UNITS_DEST/$base" -; then
      PREVIOUS_USER_UNITS["$base"]=1
    fi
  done < <(
    git -C "$REPO_DIR" log --format= --name-only --diff-filter=AM -- ops/systemd/units \
      2>/dev/null | sed '/^$/d' | sort -u
  )
}

if [ "${#ONLY_UNITS[@]}" -eq 0 ]; then
  adopt_matching_historical_user_units
fi

mkdir -p "$UNITS_DEST"

user_changed=0
for unit in "${REPO_UNITS[@]}"; do
  unit_selected "$unit" || continue
  src="$UNITS_SRC/$unit"
  dest="$UNITS_DEST/$unit"

  if [ "$DIFF_ONLY" -eq 1 ]; then
    if [ -e "$dest" ]; then
      if ! cmp -s "$src" "$dest"; then
        echo "=== $unit (would change) ==="
        diff -u "$dest" "$src" | head -20 || true
      fi
    else
      echo "=== $unit (would install — not present) ==="
    fi
    continue
  fi

  if [ -e "$dest" ] && cmp -s "$src" "$dest"; then
    continue
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    if [ -e "$dest" ]; then
      echo "would update: $unit"
    else
      echo "would install: $unit"
    fi
  else
    cp "$src" "$dest"
    echo "installed: $unit"
  fi
  user_changed=$((user_changed + 1))
done

if [ "${#ONLY_UNITS[@]}" -eq 0 ]; then
  while IFS= read -r unit; do
    [ -n "$unit" ] || continue
    [ -z "${CURRENT_USER_UNITS[$unit]+present}" ] || continue
    dest="$UNITS_DEST/$unit"
    [ -e "$dest" ] || continue

    if [ "$DIFF_ONLY" -eq 1 ]; then
      echo "=== $unit (would retire — deleted from repo) ==="
    elif [ "$DRY_RUN" -eq 1 ]; then
      echo "would retire user unit: $unit"
      user_changed=$((user_changed + 1))
    else
      systemctl --user disable --now "$unit"
      rm -f -- "$dest"
      echo "retired user unit: $unit"
      user_changed=$((user_changed + 1))
    fi
  done < <(sorted_keys PREVIOUS_USER_UNITS)
fi

system_changed=0
if [ "$MANAGE_SYSTEM_DROPINS" -eq 1 ]; then
  for dropin in "${REPO_DROPINS[@]}"; do
    src="$SYSTEM_DROPINS_SRC/$dropin"
    dest="$SYSTEM_DROPINS_DEST/$dropin"
    system_exists=0
    system_equal=0
    if sudo -n test -e "$dest"; then
      system_exists=1
      if sudo -n cmp -s "$src" "$dest"; then
        system_equal=1
      fi
    fi

    if [ "$DIFF_ONLY" -eq 1 ]; then
      if [ "$system_exists" -eq 0 ]; then
        echo "=== $dropin (system drop-in would install — not present) ==="
      elif [ "$system_equal" -eq 0 ]; then
        echo "=== $dropin (system drop-in would change) ==="
        sudo -n diff -u "$dest" "$src" | head -20 || true
      fi
      continue
    fi

    [ "$system_equal" -eq 0 ] || continue
    if [ "$DRY_RUN" -eq 1 ]; then
      if [ "$system_exists" -eq 1 ]; then
        echo "would update system drop-in: $dropin"
      else
        echo "would install system drop-in: $dropin"
      fi
    else
      sudo -n install -D -m 0644 "$src" "$dest"
      echo "installed system drop-in: $dropin"
    fi
    system_changed=$((system_changed + 1))
  done

  while IFS= read -r dropin; do
    [ -n "$dropin" ] || continue
    [ -z "${CURRENT_SYSTEM_DROPINS[$dropin]+present}" ] || continue
    dest="$SYSTEM_DROPINS_DEST/$dropin"
    sudo -n test -e "$dest" || continue

    if [ "$DIFF_ONLY" -eq 1 ]; then
      echo "=== $dropin (system drop-in would retire — deleted from repo) ==="
    elif [ "$DRY_RUN" -eq 1 ]; then
      echo "would retire system drop-in: $dropin"
      system_changed=$((system_changed + 1))
    else
      sudo -n rm -f -- "$dest"
      echo "retired system drop-in: $dropin"
      system_changed=$((system_changed + 1))
    fi
  done < <(sorted_keys PREVIOUS_SYSTEM_DROPINS)
fi

[ "$DIFF_ONLY" -eq 1 ] && exit 0

changed=$((user_changed + system_changed))
if [ "$DRY_RUN" -eq 1 ]; then
  echo ""
  echo "Dry run: $changed managed file(s) would change. Run without --dry-run to apply."
  exit 0
fi

if [ "$user_changed" -gt 0 ]; then
  echo ""
  echo "Reloading systemd user daemon..."
  systemctl --user daemon-reload
  echo "Done."
fi

if [ "$system_changed" -gt 0 ]; then
  echo ""
  echo "Reloading system systemd daemon..."
  sudo -n systemctl daemon-reload
  echo "Done."
fi

if [ "$ENABLE" -eq 1 ]; then
  echo ""
  echo "Enabling + starting selected timers..."
  for unit in "${REPO_UNITS[@]}"; do
    [[ "$unit" = *.timer ]] || continue
    unit_selected "$unit" || continue
    systemctl --user enable --now "$unit" 2>&1 | sed "s|^|  $unit: |"
  done
fi

declare -A MANAGED_USER_UNITS=()
if [ "${#ONLY_UNITS[@]}" -eq 0 ]; then
  for unit in "${REPO_UNITS[@]}"; do
    MANAGED_USER_UNITS["$unit"]=1
  done
else
  for unit in "${!PREVIOUS_USER_UNITS[@]}" "${ONLY_UNITS[@]}"; do
    [ -n "$unit" ] && MANAGED_USER_UNITS["$unit"]=1
  done
fi
mapfile -t MANAGED_USER_UNIT_NAMES < <(sorted_keys MANAGED_USER_UNITS)
write_manifest "$USER_MANIFEST" "${MANAGED_USER_UNIT_NAMES[@]}"

if [ "$MANAGE_SYSTEM_DROPINS" -eq 1 ]; then
  write_manifest "$SYSTEM_DROPINS_MANIFEST" "${REPO_DROPINS[@]}"
fi

echo ""
echo "Installed units:"
for unit in "${REPO_UNITS[@]}"; do
  unit_selected "$unit" || continue
  [ -e "$UNITS_DEST/$unit" ] && echo "  $unit"
done
