#!/usr/bin/env bash
#
# Local build for miryoku_zmk, mirroring .github/workflows/main.yml.
#
# Targets (board / shield, matching the build-cygnus*.yml workflows):
#
#   cygnus-left      nice_nano_v2   cygnus_left
#   cygnus-right     nice_nano_v2   cygnus_right
#   cygnus-dongle    nice_nano_v2   cygnus_dongle dongle_display
#   settings-reset   nice_nano_v2   settings_reset
#
# Everything happens inside .build/ so the checkout is never modified:
#
#   .build/miryoku_zmk/    staged copy of this repo with the CI-only mutations
#                          applied (the custom_config.h define and the
#                          dongle_display outboard symlink)
#   .build/zmk/            ZMK 0.3 west workspace (zephyr + modules)
#   .build/outboards/      cloned outboard repositories
#   .build/build/<target>  per-target CMake build directory
#
# Artifacts are copied to ./artifacts/<target>/.
#
# The west workspace is reused between runs, so only the first run pays for the
# `west update` (roughly 1-2 GB). Pass --clean-workspace to throw it away.
#
# Run it through the flake so the toolchain is on PATH:
#
#   nix run .#cygnus-dongle
#   nix develop -c ./scripts/zmk-build.sh cygnus-dongle

set -euo pipefail

ZMK_REPOSITORY='zmkfirmware/zmk'
ZMK_BRANCH='v0.3-branch'

usage() {
  cat >&2 <<'EOF'
Usage: scripts/zmk-build.sh [--clean-workspace] <target>...

Targets:
  cygnus-left      nice_nano_v2   cygnus_left
  cygnus-right     nice_nano_v2   cygnus_right
  cygnus-dongle    nice_nano_v2   cygnus_dongle dongle_display
  settings-reset   nice_nano_v2   settings_reset

Options:
  --clean-workspace   discard .build/zmk first (re-fetches the ZMK 0.3
                      west workspace on this run)
  -h, --help          show this help

Requires the ZMK 0.3 toolchain on PATH (ZEPHYR_TOOLCHAIN_VARIANT=gnuarmemb and
GNUARMEMB_TOOLCHAIN_PATH); both come from 'nix develop' or 'nix run .#'.
EOF
  exit 2
}

resolve_target() {
  case "$1" in
    cygnus-left)     shield='cygnus_left' ;;
    cygnus-right)    shield='cygnus_right' ;;
    cygnus-dongle)   shield='cygnus_dongle dongle_display' ;;
    settings-reset)  shield='settings_reset' ;;
    *) echo "error: unknown target '$1'" >&2; usage ;;
  esac
  # main.yml uses only the first shield word as the keyboard name.
  keyboard=$(printf '%s' "$shield" | cut -d ' ' -f 1)
  board=nice_nano_v2
}

clean_workspace=0
target_count=0
target_list=''
while [ $# -gt 0 ]; do
  case "$1" in
    --clean-workspace) clean_workspace=1 ;;
    -h | --help) usage ;;
    -*) echo "error: unknown option '$1'" >&2; usage ;;
    *) target_list="$target_list $1"; target_count=$((target_count + 1)) ;;
  esac
  shift
done
[ "$target_count" -gt 0 ] || usage

root=$(git rev-parse --show-toplevel 2>/dev/null) || root=$PWD
if [ ! -f "$root/config/cygnus.keymap" ]; then
  echo "error: not inside a miryoku_zmk checkout (run it from the repository)" >&2
  exit 1
fi
cd "$root"

for tool in git west cmake ninja dtc gperf rsync; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "error: '$tool' is not on PATH" >&2
    echo "       run through the flake: nix run .#<target>" >&2
    exit 1
  }
done

: "${ZEPHYR_TOOLCHAIN_VARIANT:=gnuarmemb}"
export ZEPHYR_TOOLCHAIN_VARIANT
if [ "$ZEPHYR_TOOLCHAIN_VARIANT" = 'gnuarmemb' ] && [ -z "${GNUARMEMB_TOOLCHAIN_PATH:-}" ]; then
  echo "error: GNUARMEMB_TOOLCHAIN_PATH is not set" >&2
  echo "       run through the flake: nix run .#<target>" >&2
  exit 1
fi

build_root="$root/.build"
stage="$build_root/miryoku_zmk"
workspace="$build_root/zmk"
outboards="$build_root/outboards"
artifact_dir="$root/artifacts"

mkdir -p "$build_root" "$outboards" "$artifact_dir"

# -- staging ---------------------------------------------------------------

# The staged copy is what CI actually builds: it holds the same mutations
# main.yml applies to its throwaway checkout, while this checkout stays clean.
stage_repo() {
  rsync -a --delete \
    --exclude '.git' \
    --exclude '.build' \
    --exclude 'artifacts' \
    --exclude 'result' \
    --exclude '.DS_Store' \
    "$root/" "$stage/"
}

# main.yml prepends '#define MIRYOKU_KEYBOARD_<base>' to custom_config.h. It is
# unreferenced in this fork but kept for parity with CI.
write_keyboard_define() {
  local configfile="$stage/miryoku/custom_config.h"
  local tmpfile="$configfile.tmp"
  local define
  define=$(printf '%s' "MIRYOKU_KEYBOARD_$keyboard_base" \
    | tr -c '[:alnum:]' '_' | tr '[:lower:]' '[:upper:]')
  printf '#define %s\n' "$define" > "$tmpfile"
  cat "$configfile" >> "$tmpfile"
  mv "$tmpfile" "$configfile"
}

# Mirrors the outboards loop in main.yml: clone the repository named by
# .github/workflows/outboards/<outboard> and symlink its shield directory into
# the staged config. Clones are cached in .build/outboards/.
link_outboards() {
  local list="shields/$keyboard_base boards/$board"
  local idx=0 extra_shield
  for extra_shield in $shield; do
    if [ "$idx" -gt 0 ]; then
      list="$list shields/${extra_shield}_extra"
    fi
    idx=$((idx + 1))
  done

  local outboard outboard_file
  for outboard in $list; do
    outboard_file="$root/.github/workflows/outboards/$outboard"
    [ -f "$outboard_file" ] || continue

    outboard_repository=''
    outboard_ref=''
    outboard_from=''
    outboard_to=''
    # shellcheck disable=SC1090
    . "$outboard_file"

    if [ -z "$outboard_repository" ] || [ -z "$outboard_ref" ] ||
      [ -z "$outboard_from" ] || [ -z "$outboard_to" ]; then
      continue
    fi

    case "$outboard_repository" in
      https://*) : ;;
      *) outboard_repository="https://github.com/$outboard_repository.git" ;;
    esac

    local dir="$outboards/$outboard"
    if [ ! -e "$dir" ]; then
      git clone --depth 1 -b "$outboard_ref" "$outboard_repository" "$dir"
    fi

    local to="$stage/config/$outboard_to"
    mkdir -p "$(dirname "$to")"
    ln -sfn "$dir/$outboard_from" "$to"
    echo "  outboard $outboard -> config/$outboard_to"
  done
}

# -- workspace -------------------------------------------------------------

setup_workspace() {
  if [ "$clean_workspace" -eq 1 ]; then
    case "$workspace" in
      "$root"/.build/*)
        echo "  removing stale west workspace"
        rm -rf "$workspace"
        ;;
      *) echo "error: refusing to remove $workspace" >&2; exit 1 ;;
    esac
  fi

  if [ ! -e "$workspace/.west" ]; then
    if [ ! -d "$workspace" ]; then
      echo "  cloning $ZMK_REPOSITORY ($ZMK_BRANCH)"
      git clone --depth 1 -b "$ZMK_BRANCH" \
        "https://github.com/$ZMK_REPOSITORY.git" "$workspace"
    fi
    echo "  west init -l app"
    (cd "$workspace" && west init -l app)
  fi

  echo "  west update (first run only; this is the big download)"
  (cd "$workspace" && west update)
  echo "  west zephyr-export"
  (cd "$workspace" && west zephyr-export)
}

# -- build -----------------------------------------------------------------

build_target() {
  local outdir="$build_root/build/$target"
  echo "  west build -b $board -d $outdir -- -DSHIELD=\"$shield\""
  (cd "$workspace/app" && west build -b "$board" -d "$outdir" -- \
    -DSHIELD="$shield" -DZMK_CONFIG="$stage/config")
}

copy_artifacts() {
  local ext file dest="$artifact_dir/$target"
  mkdir -p "$dest"
  # CI copies the first of uf2/bin/hex/elf it finds; the uf2 is what gets flashed.
  for ext in uf2 bin hex elf; do
    file="$build_root/build/$target/zephyr/zmk.$ext"
    if [ -f "$file" ]; then
      cp "$file" "$dest/"
      echo "  artifact $dest/zmk.$ext"
      return
    fi
  done
  echo "error: no zmk.{uf2,bin,hex,elf} in $build_root/build/$target/zephyr" >&2
  exit 1
}

for target in $target_list; do
  echo "=== $target ==="
  board=''
  shield=''
  keyboard=''
  resolve_target "$target"
  keyboard_base=$(printf '%s' "$keyboard" \
    | sed -e 's/_\(left\|right\|dongle\)//' -e 's/@.*//')

  echo "  board=$board shield=\"$shield\""
  stage_repo
  write_keyboard_define
  link_outboards
  setup_workspace
  build_target
  copy_artifacts
  echo
done
