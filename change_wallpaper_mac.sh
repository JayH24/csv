#!/usr/bin/env bash

# change_wallpaper_mac.sh
#
# Change macOS desktop wallpaper(s) to images from a specified directory.
# - Applies to all Spaces on all Displays (via System Events).
# - Supports random or sequential order.
# - Can run once or loop at a given interval.
#
# Usage examples:
#   ./change_wallpaper_mac.sh -p "/Users/you/Pictures/Wallpapers"              # one-time change (random)
#   ./change_wallpaper_mac.sh -p "/path/to/walls" -m sequential                # one-time change (sequential, first image)
#   ./change_wallpaper_mac.sh -p "/path/to/walls" -i 900                        # change every 15 minutes (random)
#   ./change_wallpaper_mac.sh -p "/path/to/walls" -m sequential -i 300          # change every 5 minutes (sequential)
#
# Note: Run this as the logged-in user (not via sudo). Ensure the Terminal (or app) has permission
# to control "System Events" under System Settings -> Privacy & Security -> Automation (if prompted).

set -euo pipefail

print_usage() {
  cat <<'USAGE'
Usage: change_wallpaper_mac.sh -p <directory> [options]

Options:
  -p, --path <directory>     Directory containing images (jpg, jpeg, png, heic, tiff)
  -i, --interval <seconds>   If provided, loop and change every N seconds
  -m, --mode <random|sequential>
                             Selection mode (default: random)
  -h, --help                 Show this help message

Examples:
  change_wallpaper_mac.sh -p "$HOME/Pictures/Wallpapers"
  change_wallpaper_mac.sh -p "$HOME/Pictures/Wallpapers" -i 900
  change_wallpaper_mac.sh -p "$HOME/Pictures/Wallpapers" -m sequential -i 300
USAGE
}

# Defaults
WALL_DIR=""
INTERVAL=""
MODE="random"  # or "sequential"

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--path)
      WALL_DIR=${2:-}
      shift 2
      ;;
    -i|--interval)
      INTERVAL=${2:-}
      shift 2
      ;;
    -m|--mode)
      MODE=${2:-}
      shift 2
      ;;
    -h|--help)
      print_usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      print_usage
      exit 1
      ;;
  esac
done

# Basic validations
if [[ -z "$WALL_DIR" ]]; then
  echo "Error: --path is required" >&2
  print_usage
  exit 1
fi

if [[ ! -d "$WALL_DIR" ]]; then
  echo "Error: Directory not found: $WALL_DIR" >&2
  exit 1
fi

if [[ -n "$INTERVAL" ]] && ! [[ "$INTERVAL" =~ ^[0-9]+$ ]]; then
  echo "Error: --interval must be an integer number of seconds" >&2
  exit 1
fi

case "$MODE" in
  random|sequential) ;;
  *)
    echo "Error: --mode must be 'random' or 'sequential'" >&2
    exit 1
    ;;
endcase

# Check environment (best-effort; do not hard fail if OSTYPE is not set)
if [[ "${OSTYPE:-}" != darwin* ]]; then
  echo "Warning: This script is intended for macOS (darwin). Current OSTYPE='${OSTYPE:-unknown}'." >&2
fi

if ! command -v osascript >/dev/null 2>&1; then
  echo "Error: 'osascript' not found. This script requires AppleScript (macOS)." >&2
  exit 1
fi

# Gather images
images=()
# shellcheck disable=SC2039
while IFS= read -r -d '' img; do
  images+=("$img")
# macOS 'find' supports -print0; using standard portable predicates
done < <(find "$WALL_DIR" -type f \
  \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.heic' -o -iname '*.tif' -o -iname '*.tiff' \) \
  -print0)

if [[ ${#images[@]} -eq 0 ]]; then
  echo "Error: No images found in: $WALL_DIR" >&2
  exit 1
fi

# Helper: set wallpaper for all desktops via AppleScript
set_wallpaper_all_desktops() {
  local file_path="$1"
  # Use AppleScript to set the picture for every desktop (all Spaces on all Displays)
  /usr/bin/osascript - "$file_path" <<'APPLESCRIPT'
on run argv
  set thePath to item 1 of argv
  tell application "System Events"
    repeat with d in desktops
      set picture of d to POSIX file thePath
    end repeat
  end tell
end run
APPLESCRIPT
}

# Selection helpers
current_index=0
num_images=${#images[@]}

select_next_image() {
  if [[ "$MODE" == "random" ]]; then
    # Bash RANDOM is sufficient here; avoid non-portable 'shuf'
    local idx=$(( RANDOM % num_images ))
    printf '%s\n' "${images[$idx]}"
  else
    # sequential
    local selection="${images[$current_index]}"
    current_index=$(( (current_index + 1) % num_images ))
    printf '%s\n' "$selection"
  fi
}

# One-time or loop
if [[ -z "$INTERVAL" ]]; then
  chosen=$(select_next_image)
  echo "Setting wallpaper: $chosen"
  set_wallpaper_all_desktops "$chosen"
  exit 0
fi

# Looping mode
while true; do
  chosen=$(select_next_image)
  echo "Setting wallpaper: $chosen"
  set_wallpaper_all_desktops "$chosen"
  sleep "$INTERVAL"
done