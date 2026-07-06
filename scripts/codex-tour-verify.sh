#!/usr/bin/env zsh
emulate -L zsh
set -e
set -u
set -o pipefail

ROOT_DIR="${0:A:h:h}"
MIN_SCREENSHOT_BYTES="${MIN_SCREENSHOT_BYTES:-120000}"
ALLOW_EXTRA_TOUR_SCREENSHOTS="${ALLOW_EXTRA_TOUR_SCREENSHOTS:-0}"
VERIFY_UNIQUE_TOUR_SCREENSHOTS="${VERIFY_UNIQUE_TOUR_SCREENSHOTS:-1}"

TOUR_DIR="${1:-${TOUR_DIR:-}}"
if [[ -z "$TOUR_DIR" ]]; then
  latest=("$ROOT_DIR"/NovaForgeScreenshots/codex-tour-*(/Nom[1]))
  if (( ${#latest} > 0 )); then
    TOUR_DIR="$latest[1]"
  fi
fi

if [[ -z "$TOUR_DIR" || ! -d "$TOUR_DIR" ]]; then
  echo "Tour directory not found. Pass TOUR_DIR or a directory path." >&2
  exit 1
fi

TOUR_VERIFY_SUMMARY_PATH="${TOUR_VERIFY_SUMMARY_PATH:-$TOUR_DIR/tour-verification-summary.txt}"

expected=(
  "01-chat-default-clean.png"
  "02-project-idle.png"
  "03-project-running.png"
  "04-project-approval.png"
  "05-project-waiting.png"
  "06-project-blocked.png"
  "07-project-proof.png"
  "08-project-resume.png"
  "09-project-auto-continue-countdown.png"
  "10-runs-proof.png"
  "11-files-proof.png"
  "12-terminal-live-record.png"
  "13-settings-local-ready.png"
  "14-chat-pending-approval.png"
  "15-theme-matrix-project-running.png"
  "16-theme-midnight-chat-general.png"
  "17-theme-whitegold-settings.png"
  "18-theme-arctic-runs-proof.png"
  "19-theme-ember-terminal-proof.png"
  "20-project-intake-brief.png"
)

echo "Verifying tour screenshots: $TOUR_DIR"
{
  echo "NovaForge tour verification"
  echo "Tour directory: $TOUR_DIR"
  echo "Minimum screenshot bytes: $MIN_SCREENSHOT_BYTES"
  echo "Unique screenshot guard: $VERIFY_UNIQUE_TOUR_SCREENSHOTS"
  echo
} > "$TOUR_VERIFY_SUMMARY_PATH"

typeset -A screenshot_hashes
duplicate_screenshots=()

for name in "${expected[@]}"; do
  screenshot_path="$TOUR_DIR/$name"
  if [[ ! -f "$screenshot_path" ]]; then
    echo "Missing tour screenshot: $name" >&2
    exit 1
  fi

  bytes="$(wc -c < "$screenshot_path" | tr -d '[:space:]')"
  if (( bytes < MIN_SCREENSHOT_BYTES )); then
    echo "Tour screenshot is below ${MIN_SCREENSHOT_BYTES}B: $name (${bytes}B)" >&2
    exit 1
  fi

  image_info="$(sips -g pixelWidth -g pixelHeight "$screenshot_path" 2>/dev/null || true)"
  width="$(print -r -- "$image_info" | awk '/pixelWidth:/ { print $2; exit }')"
  height="$(print -r -- "$image_info" | awk '/pixelHeight:/ { print $2; exit }')"
  if [[ -z "$width" || -z "$height" || "$width" == "0" || "$height" == "0" ]]; then
    echo "Tour screenshot is not a readable image: $name" >&2
    exit 1
  fi

  screenshot_hash="$(shasum -a 256 "$screenshot_path" | awk '{ print $1 }')"
  if [[ -n "${screenshot_hashes[$screenshot_hash]-}" ]]; then
    duplicate_screenshots+=("$name duplicates ${screenshot_hashes[$screenshot_hash]}")
  else
    screenshot_hashes[$screenshot_hash]="$name"
  fi

  echo "ok $name ${bytes}B ${width}x${height} sha256=$screenshot_hash"
  echo "$name ${bytes}B ${width}x${height} sha256=$screenshot_hash" >> "$TOUR_VERIFY_SUMMARY_PATH"
done

if [[ "$ALLOW_EXTRA_TOUR_SCREENSHOTS" != "1" ]]; then
  actual_count="$(find "$TOUR_DIR" -maxdepth 1 -type f -name '*.png' | wc -l | tr -d '[:space:]')"
  expected_count="${#expected[@]}"
  if (( actual_count != expected_count )); then
    echo "Tour screenshot count mismatch: expected $expected_count, found $actual_count." >&2
    echo "Set ALLOW_EXTRA_TOUR_SCREENSHOTS=1 to allow extra PNGs." >&2
    exit 1
  fi
fi

if [[ "$VERIFY_UNIQUE_TOUR_SCREENSHOTS" == "1" && ${#duplicate_screenshots[@]} -gt 0 ]]; then
  echo "Tour screenshots repeated; the app may not have reached every requested surface:" >&2
  for duplicate in "${duplicate_screenshots[@]}"; do
    echo "  $duplicate" >&2
  done
  echo "Set VERIFY_UNIQUE_TOUR_SCREENSHOTS=0 only when intentionally verifying duplicate frames." >&2
  exit 1
fi

echo "Tour verification passed."
echo "Summary: $TOUR_VERIFY_SUMMARY_PATH"
