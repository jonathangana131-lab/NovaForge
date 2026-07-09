#!/usr/bin/env zsh
emulate -L zsh
set -e
set -u
set -o pipefail
zmodload zsh/datetime 2>/dev/null || true

ROOT_DIR="${0:A:h:h}"
FAST_SCREENSHOT_SCRIPT="${FAST_SCREENSHOT_SCRIPT:-$ROOT_DIR/scripts/codex-fast-screenshot.sh}"
LEGACY_BUILD_SCRIPT="${LEGACY_BUILD_SCRIPT:-$ROOT_DIR/scripts/codex-sim-smoke.sh}"
SMOKE_SCRIPT="${SMOKE_SCRIPT:-$FAST_SCREENSHOT_SCRIPT}"
SIMULATOR_ID="${SIMULATOR_ID:-4B9AB34A-404C-485F-B0BC-964F24D0AE83}"
ENSURE_BOOTED="${ENSURE_BOOTED:-0}"
WAIT_SECONDS="${WAIT_SECONDS:-5}"
SIMCTL_TIMEOUT="${SIMCTL_TIMEOUT:-90}"
CHECK_SIMULATOR_HEALTH="${CHECK_SIMULATOR_HEALTH:-1}"
CONFIGURATION="${CONFIGURATION:-Release}"
BUILD_TIMEOUT="${BUILD_TIMEOUT:-600}"
MAX_TOUR_SECONDS="${MAX_TOUR_SECONDS:-360}"
SHUTDOWN_SIMULATOR_AFTER_TOUR="${SHUTDOWN_SIMULATOR_AFTER_TOUR:-1}"
VERIFY_TOUR_SCREENSHOTS="${VERIFY_TOUR_SCREENSHOTS:-1}"
TOUR_VERIFY_SCRIPT="${TOUR_VERIFY_SCRIPT:-$ROOT_DIR/scripts/codex-tour-verify.sh}"
# Fast tour mode: build once before screenshots when requested, then reuse the
# installed app for every tab. This keeps Codex screenshot proof fast without
# letting BUILD_FIRST=1 accidentally rebuild six or seven times.
BUILD_ON_FIRST_STEP="${BUILD_ON_FIRST_STEP:-${BUILD_FIRST:-0}}"
STAMP="$(date +%Y%m%d-%H%M%S)"
TOUR_DIR="${TOUR_DIR:-$ROOT_DIR/NovaForgeScreenshots/codex-tour-$STAMP}"
TOUR_LOG_DIR="${TOUR_LOG_DIR:-$ROOT_DIR/QA/codex-tour-$STAMP}"
TOUR_INSTALL_MARKER="${TOUR_INSTALL_MARKER:-$TOUR_LOG_DIR/installed-$SIMULATOR_ID-$CONFIGURATION.stamp}"
TOUR_START_TIME="${EPOCHREALTIME:-0}"
SECONDS=0

mkdir -p "$TOUR_DIR" "$TOUR_LOG_DIR"

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
      disown "$command_pid" 2>/dev/null || true
      return 124
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  wait "$command_pid"
}

require_core_simulator_health() {
  [[ "$CHECK_SIMULATOR_HEALTH" == "1" ]] || return 0

  local issues
  if issues="$(ps -axo pid,stat,command | awk '
    /CoreSimulator|simctl|Simulator\.app/ && $2 ~ /[UZE]/ {
      print "  " $0
      found = 1
    }
    END { exit found ? 0 : 1 }
  ')"; then
    echo "CoreSimulator appears wedged before starting the NovaForge tour." >&2
    echo "Stuck simulator processes:" >&2
    print -r -- "$issues" >&2
    echo "Restart macOS or log out/back in, then rerun this script." >&2
    echo "Set CHECK_SIMULATOR_HEALTH=0 only if you intentionally want to bypass this preflight." >&2
    exit 75
  fi
}

require_core_simulator_health

shutdown_simulator() {
  if xcrun simctl list devices | grep -F "$SIMULATOR_ID" | grep -q "(Booted)"; then
    echo "Shutting down simulator $SIMULATOR_ID after tour."
    run_with_timeout "$SIMCTL_TIMEOUT" xcrun simctl shutdown "$SIMULATOR_ID" >/dev/null 2>&1 || {
      echo "Warning: unable to shut down simulator $SIMULATOR_ID after tour." >&2
    }
  fi
}

tour_cleanup() {
  if [[ "$SHUTDOWN_SIMULATOR_AFTER_TOUR" == "1" ]]; then
    shutdown_simulator
  fi
}

trap tour_cleanup EXIT
trap 'tour_cleanup; exit 130' INT
trap 'tour_cleanup; exit 143' TERM

if [[ "$ENSURE_BOOTED" == "1" ]]; then
  echo "Ensuring simulator $SIMULATOR_ID is booted..."
  run_with_timeout "$SIMCTL_TIMEOUT" xcrun simctl boot "$SIMULATOR_ID" >/dev/null 2>&1 || true
  if run_with_timeout "$SIMCTL_TIMEOUT" xcrun simctl bootstatus "$SIMULATOR_ID" -b >/dev/null 2>&1; then
    :
  else
    boot_status=$?
    if (( boot_status == 124 )); then
      echo "Simulator bootstatus timed out after ${SIMCTL_TIMEOUT}s. CoreSimulator may be wedged." >&2
    fi
    echo "Simulator did not finish booting." >&2
    echo "Try restarting CoreSimulatorService, then rerun $0." >&2
    exit 1
  fi
fi

if [[ "$BUILD_ON_FIRST_STEP" == "1" ]]; then
  echo "Building NovaForge once before fast tour..."
  CONFIGURATION="$CONFIGURATION" \
    BUILD_FIRST=1 \
    LAUNCH_APP=0 \
    INSTALL_APP=0 \
    CAPTURE_SCREENSHOT=0 \
    SIMULATOR_ID="$SIMULATOR_ID" \
    BUILD_TIMEOUT="$BUILD_TIMEOUT" \
    LOG_DIR="$TOUR_LOG_DIR/build" \
    "$LEGACY_BUILD_SCRIPT"
fi

run_step() {
  local step_name="$1"
  local install_app="$2"
  local build_first="$3"
  shift 3

  local screenshot_path="$TOUR_DIR/$step_name.png"
  local step_log_dir="$TOUR_LOG_DIR/$step_name"

  echo
  echo "Tour step: $step_name"
  SCREENSHOT_PATH="$screenshot_path" \
    LOG_DIR="$step_log_dir" \
    WAIT_SECONDS="$WAIT_SECONDS" \
    SIMULATOR_ID="$SIMULATOR_ID" \
    CONFIGURATION="$CONFIGURATION" \
    INSTALL_APP="$install_app" \
    INSTALL_IF_NEWER=1 \
    INSTALL_MARKER="$TOUR_INSTALL_MARKER" \
    BUILD_FIRST="$build_first" \
    TERMINATE_AFTER_CAPTURE=1 \
    BOOT_SIMULATOR=1 \
    SHUTDOWN_SIMULATOR_AFTER_CAPTURE=0 \
    "$SMOKE_SCRIPT" "$@"
}

run_step "01-chat-default-clean" 1 0 --reset-ui --open-chat
run_step "02-mission-dossier-idle" 0 0 --reset-ui --open-project --open-mission-dossier-demo
run_step "03-mission-dossier-running" 0 0 --reset-ui --project-running-demo --open-project --open-mission-dossier-demo
run_step "04-mission-dossier-approval" 0 0 --reset-ui --project-waiting-demo --open-project --open-mission-dossier-demo
run_step "05-mission-dossier-waiting" 0 0 --reset-ui --project-waiting-demo --open-project --open-mission-dossier-demo
run_step "06-mission-dossier-blocked" 0 0 --reset-ui --project-blocked-demo --open-project --open-mission-dossier-demo
run_step "07-mission-dossier-proof" 0 0 --reset-ui --project-proof-demo --open-project --open-mission-dossier-demo
run_step "08-mission-dossier-resume" 0 0 --reset-ui --project-resume-demo --open-project --open-mission-dossier-demo
WAIT_SECONDS=1 run_step "09-mission-dossier-auto-continue-countdown" 0 0 --reset-ui --auto-continue-countdown-demo --open-project --open-mission-dossier-demo
run_step "10-runs-proof" 0 0 --reset-ui --project-proof-demo --open-runs
run_step "11-files-proof" 0 0 --reset-ui --project-proof-demo --open-files
run_step "12-terminal-live-record" 0 0 --reset-ui --terminal-live-record-demo --open-terminal
run_step "13-settings-local-ready" 0 0 --reset-ui --settings-local-model-ready --open-settings
run_step "14-chat-pending-approval" 0 0 --reset-ui --pending-approval-demo --open-chat
run_step "15-theme-matrix-mission-dossier-running" 0 0 --reset-ui --theme-world=matrixRain --project-running-demo --open-project --open-mission-dossier-demo
run_step "16-theme-midnight-chat-general" 0 0 --reset-ui --theme-world=midnightBlack --open-chat
run_step "17-theme-whitegold-settings" 0 0 --reset-ui --theme-world=whiteGold --settings-local-model-ready --open-settings
run_step "18-theme-arctic-runs-proof" 0 0 --reset-ui --theme-world=arcticGlass --project-proof-demo --open-runs
run_step "19-theme-ember-terminal-proof" 0 0 --reset-ui --theme-world=emberCore --terminal-live-record-demo --open-terminal
run_step "20-mission-dossier-intake-brief" 0 0 --reset-ui --open-project --open-mission-dossier-demo --project-intake-demo

if [[ "$VERIFY_TOUR_SCREENSHOTS" == "1" ]]; then
  MIN_SCREENSHOT_BYTES="${MIN_SCREENSHOT_BYTES:-120000}" "$TOUR_VERIFY_SCRIPT" "$TOUR_DIR"
fi

if [[ -n "${EPOCHREALTIME:-}" && "$TOUR_START_TIME" != "0" ]]; then
  TOUR_ELAPSED_SECONDS="$(printf '%.2f' "$(( EPOCHREALTIME - TOUR_START_TIME ))")"
else
  TOUR_ELAPSED_SECONDS="$SECONDS"
fi

if (( MAX_TOUR_SECONDS > 0 && TOUR_ELAPSED_SECONDS > MAX_TOUR_SECONDS )); then
  echo "Tour took ${TOUR_ELAPSED_SECONDS}s, above MAX_TOUR_SECONDS=${MAX_TOUR_SECONDS}." >&2
  exit 1
fi

echo
echo "Tour passed."
echo "Tour duration: ${TOUR_ELAPSED_SECONDS}s (max ${MAX_TOUR_SECONDS}s)"
echo "Screenshots: $TOUR_DIR"
echo "Logs: $TOUR_LOG_DIR"
