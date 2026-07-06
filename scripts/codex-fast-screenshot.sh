#!/usr/bin/env zsh
emulate -L zsh
set -e
set -u
set -o pipefail
zmodload zsh/datetime 2>/dev/null || true

ROOT_DIR="${0:A:h:h}"
BUNDLE_ID="${BUNDLE_ID:-com.joey.NovaForge}"
APP_NAME="${APP_NAME:-NovaForge.app}"
CONFIGURATION="${CONFIGURATION:-Release}"
SIMULATOR_ID="${SIMULATOR_ID:-4B9AB34A-404C-485F-B0BC-964F24D0AE83}"
SIMCTL_TIMEOUT="${SIMCTL_TIMEOUT:-30}"
WAIT_SECONDS="${WAIT_SECONDS:-1}"
SCREENSHOT_READY_ATTEMPTS="${SCREENSHOT_READY_ATTEMPTS:-12}"
SCREENSHOT_READY_INTERVAL="${SCREENSHOT_READY_INTERVAL:-0.75}"
MIN_SCREENSHOT_BYTES="${MIN_SCREENSHOT_BYTES:-120000}"
INSTALL_ON_LAUNCH_FAILURE="${INSTALL_ON_LAUNCH_FAILURE:-1}"
INSTALL_APP="${INSTALL_APP:-0}"
INSTALL_IF_NEWER="${INSTALL_IF_NEWER:-1}"
LAUNCH_APP="${LAUNCH_APP:-1}"
CAPTURE_SCREENSHOT="${CAPTURE_SCREENSHOT:-1}"
CAPTURE_STDIO="${CAPTURE_STDIO:-0}"
TERMINATE_AFTER_CAPTURE="${TERMINATE_AFTER_CAPTURE:-1}"
BOOT_SIMULATOR="${BOOT_SIMULATOR:-1}"
SHUTDOWN_SIMULATOR_AFTER_CAPTURE="${SHUTDOWN_SIMULATOR_AFTER_CAPTURE:-0}"
DERIVED_DATA_ROOT="${DERIVED_DATA_ROOT:-$HOME/Library/Developer/Xcode/DerivedData}"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-$ROOT_DIR/NovaForgeScreenshots}"
LOG_DIR="${LOG_DIR:-$ROOT_DIR/QA/codex-fast-screenshot}"
STAMP="$(date +%Y%m%d-%H%M%S)"
SCREENSHOT_NAME="${SCREENSHOT_NAME:-codex-fast-$STAMP.png}"
SCREENSHOT_PATH="${SCREENSHOT_PATH:-$SCREENSHOT_DIR/$SCREENSHOT_NAME}"
APP_PATH="${APP_PATH:-}"
LAUNCHED_APP_PID=""

SCREENSHOT_DIR="${SCREENSHOT_DIR:A}"
LOG_DIR="${LOG_DIR:A}"
SCREENSHOT_PATH="${SCREENSHOT_PATH:A}"

if (( $# > 0 )); then
  LAUNCH_ARGS=("$@")
elif [[ -n "${APP_ARGS:-}" ]]; then
  LAUNCH_ARGS=(${(z)APP_ARGS})
else
  LAUNCH_ARGS=("--open-project")
fi

mkdir -p "$SCREENSHOT_DIR" "$LOG_DIR"
LAUNCH_LOG="$LOG_DIR/launch-$STAMP.log"
INSTALL_LOG="$LOG_DIR/install-$STAMP.log"
SCREENSHOT_LOG="$LOG_DIR/screenshot-$STAMP.log"
STDOUT_LOG="${STDOUT_LOG:-$LOG_DIR/stdout-$STAMP.log}"
STDERR_LOG="${STDERR_LOG:-$LOG_DIR/stderr-$STAMP.log}"
INSTALL_MARKER="${INSTALL_MARKER:-$LOG_DIR/installed-$SIMULATOR_ID-$CONFIGURATION.stamp}"

latest_app_path() {
  local -a matches
  matches=("$DERIVED_DATA_ROOT"/AgentPad-*/Build/Products/"$CONFIGURATION"-iphonesimulator/"$APP_NAME"(Nom[1]))
  if (( ${#matches} > 0 )); then
    print -r -- "$matches[1]"
  fi
}

run_with_timeout() {
  local timeout_seconds="$1"
  shift
  "$@" &
  local command_pid=$!
  local elapsed_tenths=0
  local timeout_tenths=$(( timeout_seconds * 10 ))

  while kill -0 "$command_pid" 2>/dev/null; do
    if (( timeout_tenths > 0 && elapsed_tenths >= timeout_tenths )); then
      kill "$command_pid" 2>/dev/null || true
      sleep 1
      kill -9 "$command_pid" 2>/dev/null || true
      disown "$command_pid" 2>/dev/null || true
      return 124
    fi
    sleep 0.1
    elapsed_tenths=$((elapsed_tenths + 1))
  done

  wait "$command_pid"
}

simulator_is_booted() {
  xcrun simctl list devices | grep -F "$SIMULATOR_ID" | grep -q "(Booted)"
}

boot_simulator_if_needed() {
  if [[ "$BOOT_SIMULATOR" != "1" ]]; then
    return
  fi

  if simulator_is_booted; then
    return
  fi

  echo "Booting simulator $SIMULATOR_ID."
  run_with_timeout "$SIMCTL_TIMEOUT" xcrun simctl boot "$SIMULATOR_ID" >/dev/null 2>&1 || true
  if ! run_with_timeout "$SIMCTL_TIMEOUT" xcrun simctl bootstatus "$SIMULATOR_ID" -b >/dev/null 2>&1; then
    echo "Simulator boot failed or timed out for $SIMULATOR_ID." >&2
    exit 1
  fi
}

shutdown_simulator() {
  if simulator_is_booted; then
    echo "Shutting down simulator $SIMULATOR_ID."
    run_with_timeout "$SIMCTL_TIMEOUT" xcrun simctl shutdown "$SIMULATOR_ID" >/dev/null 2>&1 || {
      echo "Warning: unable to shut down simulator $SIMULATOR_ID after capture." >&2
    }
  fi
}

cleanup_on_exit() {
  local exit_status=$?
  if [[ "$SHUTDOWN_SIMULATOR_AFTER_CAPTURE" == "1" ]]; then
    shutdown_simulator
  fi
  return "$exit_status"
}

trap cleanup_on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

resolve_app_path() {
  if [[ -z "$APP_PATH" ]]; then
    APP_PATH="$(latest_app_path)"
  fi

  if [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
    echo "No built $APP_NAME found for $CONFIGURATION. Run a build once, or pass APP_PATH=/path/to/$APP_NAME." >&2
    exit 1
  fi
}

install_app() {
  resolve_app_path
  echo "Installing cached app: $APP_PATH"
  if ! run_with_timeout "$SIMCTL_TIMEOUT" xcrun simctl install "$SIMULATOR_ID" "$APP_PATH" >"$INSTALL_LOG" 2>&1; then
    echo "Install failed. Last 60 lines from $INSTALL_LOG:" >&2
    tail -n 60 "$INSTALL_LOG" >&2
    exit 1
  fi
  touch "$INSTALL_MARKER"
}

install_if_newer() {
  resolve_app_path
  if [[ ! -f "$INSTALL_MARKER" || "$APP_PATH" -nt "$INSTALL_MARKER" ]]; then
    install_app
  else
    echo "Using already-installed app for $CONFIGURATION."
  fi
}

launch_app() {
  echo "Launching $BUNDLE_ID ${LAUNCH_ARGS[*]}"
  local -a stdio_args
  local -a launch_env
  if [[ "$CAPTURE_STDIO" == "1" ]]; then
    stdio_args=("--stdout=$STDOUT_LOG" "--stderr=$STDERR_LOG")
    launch_env=(env SIMCTL_CHILD_NSUnbufferedIO=YES)
  else
    stdio_args=()
    launch_env=()
  fi
  run_with_timeout "$SIMCTL_TIMEOUT" "${launch_env[@]}" xcrun simctl launch \
    --terminate-running-process \
    "${stdio_args[@]}" \
    "$SIMULATOR_ID" \
    "$BUNDLE_ID" \
    "${LAUNCH_ARGS[@]}" >"$LAUNCH_LOG" 2>&1
}

record_launched_app_pid() {
  LAUNCHED_APP_PID=""
  if [[ -f "$LAUNCH_LOG" ]]; then
    LAUNCHED_APP_PID="$(grep -E "^${BUNDLE_ID}: " "$LAUNCH_LOG" | tail -n 1 | cut -d: -f2 | tr -cd '[:digit:]' || true)"
  fi
}

assert_launched_app_is_alive() {
  record_launched_app_pid
  if [[ -z "$LAUNCHED_APP_PID" ]]; then
    echo "Warning: unable to read launched app PID from $LAUNCH_LOG; continuing with screenshot capture." >&2
    return
  fi

  if ! kill -0 "$LAUNCHED_APP_PID" >/dev/null 2>&1; then
    echo "Launched app exited before screenshot (pid $LAUNCHED_APP_PID). Refusing to capture SpringBoard/Home Screen as proof." >&2
    echo "Last 60 lines from $LAUNCH_LOG:" >&2
    tail -n 60 "$LAUNCH_LOG" >&2
    exit 1
  fi
}

terminate_app() {
  if run_with_timeout "$SIMCTL_TIMEOUT" xcrun simctl terminate "$SIMULATOR_ID" "$BUNDLE_ID" >/dev/null 2>&1; then
    :
  else
    echo "Warning: unable to terminate $BUNDLE_ID after capture." >&2
  fi
}

screenshot_size_bytes() {
  if [[ -f "$SCREENSHOT_PATH" ]]; then
    wc -c < "$SCREENSHOT_PATH" | tr -d '[:space:]'
  else
    echo 0
  fi
}

capture_ready_screenshot() {
  local attempt=1
  local screenshot_bytes=0

  while (( attempt <= SCREENSHOT_READY_ATTEMPTS )); do
    echo "Capturing screenshot."
    if ! run_with_timeout "$SIMCTL_TIMEOUT" xcrun simctl io "$SIMULATOR_ID" screenshot "$SCREENSHOT_PATH" >"$SCREENSHOT_LOG" 2>&1; then
      echo "Screenshot failed. Last 60 lines from $SCREENSHOT_LOG:" >&2
      tail -n 60 "$SCREENSHOT_LOG" >&2
      exit 1
    fi

    screenshot_bytes="$(screenshot_size_bytes)"
    if (( MIN_SCREENSHOT_BYTES <= 0 || screenshot_bytes >= MIN_SCREENSHOT_BYTES )); then
      return 0
    fi

    echo "Screenshot not ready yet (${screenshot_bytes}B < ${MIN_SCREENSHOT_BYTES}B); retrying."
    attempt=$((attempt + 1))
    sleep "$SCREENSHOT_READY_INTERVAL"
  done

  echo "Screenshot stayed below ${MIN_SCREENSHOT_BYTES}B after ${SCREENSHOT_READY_ATTEMPTS} attempts." >&2
  echo "Last screenshot size: ${screenshot_bytes}B" >&2
  echo "Screenshot: $SCREENSHOT_PATH" >&2
  exit 1
}

SECONDS=0
START_TIME="${EPOCHREALTIME:-0}"

if [[ "$LAUNCH_APP" == "1" || "$CAPTURE_SCREENSHOT" == "1" ]]; then
  boot_simulator_if_needed
fi

if [[ "$INSTALL_APP" == "1" ]]; then
  install_app
elif [[ "$INSTALL_IF_NEWER" == "1" && "$LAUNCH_APP" == "1" ]]; then
  install_if_newer
fi

if [[ "$LAUNCH_APP" == "1" ]]; then
  if launch_app; then
    :
  else
    launch_status=$?
    if [[ "$INSTALL_ON_LAUNCH_FAILURE" == "1" ]]; then
      echo "Launch failed with status $launch_status; installing cached app once and retrying."
      install_app
      launch_app || {
        echo "Launch failed after install retry. Last 60 lines from $LAUNCH_LOG:" >&2
        tail -n 60 "$LAUNCH_LOG" >&2
        exit 1
      }
    else
      echo "Launch failed. Last 60 lines from $LAUNCH_LOG:" >&2
      tail -n 60 "$LAUNCH_LOG" >&2
      exit 1
    fi
  fi
else
  echo "Skipping launch."
fi

sleep "$WAIT_SECONDS"

if [[ "$LAUNCH_APP" == "1" && "$CAPTURE_SCREENSHOT" == "1" ]]; then
  assert_launched_app_is_alive
fi

if [[ "$CAPTURE_SCREENSHOT" == "1" ]]; then
  capture_ready_screenshot
else
  echo "Skipping screenshot."
fi

if [[ "$LAUNCH_APP" == "1" && "$TERMINATE_AFTER_CAPTURE" == "1" ]]; then
  echo "Terminating $BUNDLE_ID."
  terminate_app
fi

if [[ "$SHUTDOWN_SIMULATOR_AFTER_CAPTURE" == "1" ]]; then
  shutdown_simulator
fi

if [[ -n "${EPOCHREALTIME:-}" && "$START_TIME" != "0" ]]; then
  ELAPSED_SECONDS="$(printf '%.2f' "$(( EPOCHREALTIME - START_TIME ))")"
else
  ELAPSED_SECONDS="${SECONDS}"
fi

echo "Fast screenshot passed in ${ELAPSED_SECONDS}s."
echo "Simulator: $SIMULATOR_ID"
echo "Installed first: $INSTALL_APP"
echo "Install if newer: $INSTALL_IF_NEWER"
echo "Launch app: $LAUNCH_APP"
echo "Terminate after capture: $TERMINATE_AFTER_CAPTURE"
echo "Boot simulator: $BOOT_SIMULATOR"
echo "Shutdown simulator after capture: $SHUTDOWN_SIMULATOR_AFTER_CAPTURE"
echo "Screenshot: $SCREENSHOT_PATH"
if [[ "$CAPTURE_SCREENSHOT" == "1" ]]; then
  echo "Screenshot bytes: $(screenshot_size_bytes)"
  echo "Minimum screenshot bytes: $MIN_SCREENSHOT_BYTES"
fi
if [[ "$CAPTURE_STDIO" == "1" ]]; then
  echo "Stdout: $STDOUT_LOG"
  echo "Stderr: $STDERR_LOG"
fi
echo "Logs: $LOG_DIR"
