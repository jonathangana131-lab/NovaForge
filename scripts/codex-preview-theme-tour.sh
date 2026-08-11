#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAST_SCREENSHOT_SCRIPT="${FAST_SCREENSHOT_SCRIPT:-$ROOT_DIR/scripts/codex-fast-screenshot.sh}"
BUILD_SCRIPT="${BUILD_SCRIPT:-$ROOT_DIR/scripts/codex-sim-smoke.sh}"
VERIFY_SCRIPT="${VERIFY_SCRIPT:-$ROOT_DIR/scripts/codex-preview-theme-tour-verify.sh}"
SIMULATOR_ID="${SIMULATOR_ID:-4B9AB34A-404C-485F-B0BC-964F24D0AE83}"
CONFIGURATION="${CONFIGURATION:-Release}"
WAIT_SECONDS="${WAIT_SECONDS:-2}"
SIMCTL_TIMEOUT="${SIMCTL_TIMEOUT:-90}"
BUILD_TIMEOUT="${BUILD_TIMEOUT:-600}"
BUILD_FIRST="${BUILD_FIRST:-1}"
VERIFY_SCREENSHOTS="${VERIFY_SCREENSHOTS:-1}"
SHUTDOWN_SIMULATOR_AFTER_TOUR="${SHUTDOWN_SIMULATOR_AFTER_TOUR:-1}"
MAX_TOUR_SECONDS="${MAX_TOUR_SECONDS:-600}"
STAMP="$(date +%Y%m%d-%H%M%S)"
TOUR_DIR="${TOUR_DIR:-$ROOT_DIR/NovaForgeScreenshots/preview-theme-tour-$STAMP}"
TOUR_LOG_DIR="${TOUR_LOG_DIR:-$ROOT_DIR/QA/preview-theme-tour-$STAMP}"
INSTALL_MARKER="${INSTALL_MARKER:-$TOUR_LOG_DIR/installed-$SIMULATOR_ID-$CONFIGURATION.stamp}"
START_SECONDS=$SECONDS

THEMES=(matrixRain midnightBlack whiteGold arcticGlass emberCore)
STATES=(forge-clean pending-approval local-ready local-missing history-proof)

mkdir -p "$TOUR_DIR" "$TOUR_LOG_DIR"

for required in "$FAST_SCREENSHOT_SCRIPT" "$BUILD_SCRIPT" "$VERIFY_SCRIPT"; do
  if [[ ! -x "$required" ]]; then
    echo "Required executable is missing: $required" >&2
    exit 1
  fi
done

SOURCE_SHA="$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || true)"
if [[ ! "$SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]]; then
  echo "Preview theme tour requires an exact Git source SHA." >&2
  exit 1
fi

cat > "$TOUR_DIR/preview-theme-tour-manifest.txt" <<EOF
NovaForge Preview five-theme release-candidate tour
source_sha=$SOURCE_SHA
simulator_id=$SIMULATOR_ID
configuration=$CONFIGURATION
themes=${THEMES[*]}
states=${STATES[*]}
expected_png_count=25
created_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
truth_boundary=Capture tooling records requested Simulator states and image evidence only; visual acceptance still requires human/agent screenshot critique on the exact source SHA.
EOF

run_with_timeout() {
  local timeout_seconds="$1"
  shift
  "$@" &
  local command_pid=$!
  local elapsed=0

  while kill -0 "$command_pid" 2>/dev/null; do
    if (( timeout_seconds > 0 && elapsed >= timeout_seconds )); then
      kill "$command_pid" 2>/dev/null || true
      sleep 1
      kill -9 "$command_pid" 2>/dev/null || true
      wait "$command_pid" 2>/dev/null || true
      return 124
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  wait "$command_pid"
}

shutdown_simulator() {
  if [[ "$SHUTDOWN_SIMULATOR_AFTER_TOUR" != "1" ]]; then
    return 0
  fi
  run_with_timeout "$SIMCTL_TIMEOUT" xcrun simctl shutdown "$SIMULATOR_ID" >/dev/null 2>&1 || true
}

cleanup() {
  local status=$?
  shutdown_simulator
  return "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ "$BUILD_FIRST" == "1" ]]; then
  echo "Building NovaForge once before the Preview theme matrix..."
  CONFIGURATION="$CONFIGURATION" \
    BUILD_FIRST=1 \
    LAUNCH_APP=0 \
    INSTALL_APP=0 \
    CAPTURE_SCREENSHOT=0 \
    SIMULATOR_ID="$SIMULATOR_ID" \
    BUILD_TIMEOUT="$BUILD_TIMEOUT" \
    LOG_DIR="$TOUR_LOG_DIR/build" \
    "$BUILD_SCRIPT"
fi

capture_state() {
  local theme="$1"
  local prefix="$2"
  local state="$3"
  shift 3
  local screenshot_path="$TOUR_DIR/${prefix}-${state}.png"
  local step_log_dir="$TOUR_LOG_DIR/${prefix}-${state}"

  echo
  echo "Preview theme tour: $theme / $state"
  SCREENSHOT_PATH="$screenshot_path" \
    LOG_DIR="$step_log_dir" \
    WAIT_SECONDS="$WAIT_SECONDS" \
    SIMULATOR_ID="$SIMULATOR_ID" \
    CONFIGURATION="$CONFIGURATION" \
    INSTALL_APP=0 \
    INSTALL_IF_NEWER=1 \
    INSTALL_MARKER="$INSTALL_MARKER" \
    BUILD_FIRST=0 \
    TERMINATE_AFTER_CAPTURE=1 \
    BOOT_SIMULATOR=1 \
    SHUTDOWN_SIMULATOR_AFTER_CAPTURE=0 \
    "$FAST_SCREENSHOT_SCRIPT" \
      --reset-ui \
      "--theme-world=$theme" \
      "$@"
}

capture_theme() {
  local theme="$1"
  local prefix="$2"
  capture_state "$theme" "$prefix" forge-clean --open-chat
  capture_state "$theme" "$prefix" pending-approval --pending-approval-demo --open-chat
  capture_state "$theme" "$prefix" local-ready --settings-local-model-ready --open-settings
  capture_state "$theme" "$prefix" local-missing --first-run-local-model-missing --open-settings
  capture_state "$theme" "$prefix" history-proof --project-proof-demo --open-runs
}

capture_theme matrixRain 01-matrix-rain
capture_theme midnightBlack 02-midnight-black
capture_theme whiteGold 03-white-gold
capture_theme arcticGlass 04-arctic-glass
capture_theme emberCore 05-ember-core

if [[ "$VERIFY_SCREENSHOTS" == "1" ]]; then
  MIN_SCREENSHOT_BYTES="${MIN_SCREENSHOT_BYTES:-120000}" "$VERIFY_SCRIPT" "$TOUR_DIR"
fi

ELAPSED_SECONDS=$((SECONDS - START_SECONDS))
if (( MAX_TOUR_SECONDS > 0 && ELAPSED_SECONDS > MAX_TOUR_SECONDS )); then
  echo "Preview theme tour took ${ELAPSED_SECONDS}s, above MAX_TOUR_SECONDS=${MAX_TOUR_SECONDS}." >&2
  exit 1
fi

echo
echo "Preview five-theme capture matrix completed."
echo "Source: $SOURCE_SHA"
echo "Screenshots: $TOUR_DIR"
echo "Logs: $TOUR_LOG_DIR"
echo "Duration: ${ELAPSED_SECONDS}s"
echo "This is capture evidence, not visual acceptance by itself."
