#!/usr/bin/env zsh
emulate -L zsh
set -e
set -u
set -o pipefail

ROOT_DIR="${0:A:h:h}"
PROJECT_PATH="${PROJECT_PATH:-$ROOT_DIR/AgentPad.xcodeproj}"
SCHEME="${SCHEME:-AgentPad}"
CONFIGURATION="${CONFIGURATION:-Debug}"
BUNDLE_ID="${BUNDLE_ID:-com.joey.NovaForge}"
APP_NAME="${APP_NAME:-NovaForge.app}"
APP_PATH="${APP_PATH:-}"
BUILD_FIRST="${BUILD_FIRST:-0}"
BUILD_SDK="${BUILD_SDK:-iphonesimulator}"
INSTALL_APP="${INSTALL_APP:-1}"
LAUNCH_APP="${LAUNCH_APP:-1}"
CAPTURE_SCREENSHOT="${CAPTURE_SCREENSHOT:-1}"
SIMCTL_TIMEOUT="${SIMCTL_TIMEOUT:-90}"
BUILD_TIMEOUT="${BUILD_TIMEOUT:-600}"
CHECK_SIMULATOR_HEALTH="${CHECK_SIMULATOR_HEALTH:-1}"
ENSURE_BOOTED="${ENSURE_BOOTED:-0}"
DERIVED_DATA_ROOT="${DERIVED_DATA_ROOT:-$HOME/Library/Developer/Xcode/DerivedData}"
# This repo already has a clean simulator used for fast NovaForge checks.
# Override with SIMULATOR_ID=<udid>, or set AUTO_DETECT_SIMULATOR=1 to pick
# the first booted simulator from CoreSimulator.
SIMULATOR_ID="${SIMULATOR_ID:-4B9AB34A-404C-485F-B0BC-964F24D0AE83}"
AUTO_DETECT_SIMULATOR="${AUTO_DETECT_SIMULATOR:-0}"
ONLY_ACTIVE_ARCH="${ONLY_ACTIVE_ARCH:-YES}"
WAIT_SECONDS="${WAIT_SECONDS:-5}"
MAX_WAIT_SECONDS="${MAX_WAIT_SECONDS:-30}"
STAMP="$(date +%Y%m%d-%H%M%S)-$$"
LOG_DIR="${LOG_DIR:-$ROOT_DIR/QA/codex-smoke-$STAMP}"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-$ROOT_DIR/NovaForgeScreenshots/codex-smoke-$STAMP}"
SCREENSHOT_NAME="${SCREENSHOT_NAME:-codex-smoke-$STAMP.png}"
SOURCE_COMMIT="${NOVAFORGE_SOURCE_COMMIT:-$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || true)}"
NOVAFORGE_SOURCE_COMMIT="$SOURCE_COMMIT"
SOURCE_TREE_HASH="${NOVAFORGE_SOURCE_TREE_HASH:-}"
RUN_METADATA_PATH="${RUN_METADATA_PATH:-$LOG_DIR/run-metadata.txt}"
TERMINATE_ON_EXIT="${TERMINATE_ON_EXIT:-1}"

if (( $# > 0 )); then
  LAUNCH_ARGS=("$@")
elif [[ -n "${APP_ARGS:-}" ]]; then
  LAUNCH_ARGS=(${(z)APP_ARGS})
else
  LAUNCH_ARGS=("--reset-ui")
fi

find_booted_simulator() {
  xcrun simctl list devices available | awk '
    /\(Booted\)/ {
      if (match($0, /\([0-9A-F-]{36}\) \(Booted\)/)) {
        print substr($0, RSTART + 1, 36)
        exit
      }
    }
  '
}

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
  [[ "$timeout_seconds" =~ '^[1-9][0-9]*$' ]] || {
    echo "Timeout must be a positive integer: $timeout_seconds" >&2
    return 2
  }
  "$@" &
  local command_pid=$!
  local elapsed=0

  while kill -0 "$command_pid" 2>/dev/null; do
    if (( timeout_seconds > 0 && elapsed >= timeout_seconds )); then
      terminate_process_tree "$command_pid" TERM
      sleep 1
      terminate_process_tree "$command_pid" KILL
      wait "$command_pid" 2>/dev/null || true
      return 124
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  wait "$command_pid"
}

terminate_process_tree() {
  local process_pid="$1"
  local signal="$2"
  local child_pid
  local child_pids

  [[ "$process_pid" =~ '^[0-9]+$' ]] || return 0
  child_pids="$(pgrep -P "$process_pid" 2>/dev/null || true)"
  for child_pid in ${(f)child_pids}; do
    terminate_process_tree "$child_pid" "$signal"
  done
  kill -s "$signal" "$process_pid" 2>/dev/null || true
}

source_tree_hash() {
  local commit_tree tracked_diff_hash untracked_hash diff_hash
  commit_tree="$(git -C "$ROOT_DIR" rev-parse 'HEAD^{tree}' 2>/dev/null || true)"
  [[ -n "$commit_tree" ]] || {
    print -r -- "unknown"
    return
  }
  tracked_diff_hash="$(git -C "$ROOT_DIR" diff --no-ext-diff --binary HEAD 2>/dev/null | shasum -a 256 | awk '{ print $1 }')"
  untracked_hash="$({
    # Keep app provenance stable when host-only Codex/Hermes state lives in
    # the checkout. Those directories are not NovaForge build inputs.
    git -C "$ROOT_DIR" ls-files --others --exclude-standard -z -- . \
      ':(exclude).hermes/**' ':(exclude)automation/**' 2>/dev/null |
      while IFS= read -r -d '' relative_path; do
        local file_hash
        if [[ -L "$ROOT_DIR/$relative_path" ]]; then
          file_hash="symlink:$(readlink "$ROOT_DIR/$relative_path" | shasum -a 256 | awk '{ print $1 }')"
        elif [[ -f "$ROOT_DIR/$relative_path" ]]; then
          file_hash="$(shasum -a 256 "$ROOT_DIR/$relative_path" 2>/dev/null | awk '{ print $1 }')"
        elif [[ -d "$ROOT_DIR/$relative_path" ]]; then
          file_hash="directory"
        else
          file_hash="unreadable"
        fi
        print -rn -- "$relative_path\0${file_hash:-unreadable}\0"
      done
  } | shasum -a 256 | awk '{ print $1 }')"
  diff_hash="$(print -rn -- "$tracked_diff_hash\0$untracked_hash" | shasum -a 256 | awk '{ print $1 }')"
  print -r -- "sha256:${commit_tree}:${diff_hash}"
}

app_bundle_hash() {
  local app_path="$1"
  local bundle_hash
  bundle_hash="$(find "$app_path" -type f -print0 | sort -z |
    while IFS= read -r -d '' artifact_path; do
      local artifact_hash
      artifact_hash="$(shasum -a 256 "$artifact_path" 2>/dev/null | awk '{ print $1 }')"
      print -rn -- "$artifact_path\0${artifact_hash:-unreadable}\0"
    done | shasum -a 256 | awk '{ print $1 }')"
  print -r -- "sha256:$bundle_hash"
}

write_run_metadata() {
  local build_log_hash="unavailable"
  if [[ -f "$BUILD_LOG" ]]; then
    build_log_hash="sha256:$(shasum -a 256 "$BUILD_LOG" | awk '{ print $1 }')"
  fi
  [[ -n "$SOURCE_TREE_HASH" ]] || SOURCE_TREE_HASH="$(source_tree_hash)"
  mkdir -p "${RUN_METADATA_PATH:h}"
  print -r -- "runID=$STAMP" > "$RUN_METADATA_PATH"
  print -r -- "sourceCommit=$SOURCE_COMMIT" >> "$RUN_METADATA_PATH"
  print -r -- "sourceTreeHash=$SOURCE_TREE_HASH" >> "$RUN_METADATA_PATH"
  print -r -- "configuration=$CONFIGURATION" >> "$RUN_METADATA_PATH"
  print -r -- "simulatorID=$SIMULATOR_ID" >> "$RUN_METADATA_PATH"
  print -r -- "appPath=$APP_PATH" >> "$RUN_METADATA_PATH"
  print -r -- "appBundleHash=$(app_bundle_hash "$APP_PATH")" >> "$RUN_METADATA_PATH"
  print -r -- "buildLogHash=$build_log_hash" >> "$RUN_METADATA_PATH"
}

require_core_simulator_health() {
  [[ "$CHECK_SIMULATOR_HEALTH" == "1" ]] || return 0

  local issues
  if issues="$(ps -axo pid,stat,command | awk '
    /CoreSimulator|simctl|Simulator\.app/ && $2 ~ /[ZE]/ {
      print "  " $0
      found = 1
    }
    END { exit found ? 0 : 1 }
  ')"; then
    echo "CoreSimulator appears wedged before launching NovaForge." >&2
    echo "Stuck simulator processes:" >&2
    print -r -- "$issues" >&2
    echo "Restart macOS or log out/back in, then rerun this script." >&2
    echo "Set CHECK_SIMULATOR_HEALTH=0 only if you intentionally want to bypass this preflight." >&2
    exit 75
  fi
}

if [[ "$AUTO_DETECT_SIMULATOR" == "1" ]]; then
  SIMULATOR_ID="$(find_booted_simulator)"
fi

if [[ -z "$SIMULATOR_ID" ]]; then
  echo "No simulator selected. Pass SIMULATOR_ID=<udid> or set AUTO_DETECT_SIMULATOR=1." >&2
  exit 1
fi

if ! [[ "$WAIT_SECONDS" =~ '^[0-9]+$' && "$MAX_WAIT_SECONDS" =~ '^[0-9]+$' ]]; then
  echo "WAIT_SECONDS and MAX_WAIT_SECONDS must be non-negative integers." >&2
  exit 2
fi
if (( WAIT_SECONDS > MAX_WAIT_SECONDS )); then
  echo "WAIT_SECONDS=${WAIT_SECONDS} exceeds MAX_WAIT_SECONDS=${MAX_WAIT_SECONDS}." >&2
  exit 2
fi
if ! [[ "$SIMCTL_TIMEOUT" =~ '^[1-9][0-9]*$' && "$BUILD_TIMEOUT" =~ '^[1-9][0-9]*$' ]]; then
  echo "SIMCTL_TIMEOUT and BUILD_TIMEOUT must be positive integers." >&2
  exit 2
fi

[[ -n "$SOURCE_TREE_HASH" ]] || SOURCE_TREE_HASH="$(source_tree_hash)"

BUILD_DESTINATION="${BUILD_DESTINATION:-platform=iOS Simulator,id=$SIMULATOR_ID}"

mkdir -p "$LOG_DIR" "$SCREENSHOT_DIR"

BUILD_LOG="$LOG_DIR/build-$STAMP.log"
INSTALL_LOG="$LOG_DIR/install-$STAMP.log"
LAUNCH_LOG="$LOG_DIR/launch-$STAMP.log"
SCREENSHOT_LOG="$LOG_DIR/screenshot-$STAMP.log"
SCREENSHOT_PATH="${SCREENSHOT_PATH:-$SCREENSHOT_DIR/$SCREENSHOT_NAME}"
mkdir -p "${SCREENSHOT_PATH:h}"

APP_LAUNCHED=0

terminate_app() {
  if [[ "$APP_LAUNCHED" != "1" ]]; then
    return 0
  fi
  if run_with_timeout "$SIMCTL_TIMEOUT" xcrun simctl terminate "$SIMULATOR_ID" "$BUNDLE_ID" >/dev/null 2>&1; then
    APP_LAUNCHED=0
  else
    echo "Warning: unable to terminate $BUNDLE_ID during smoke cleanup." >&2
  fi
}

cleanup_on_exit() {
  local exit_status=$?
  if [[ "$TERMINATE_ON_EXIT" == "1" && "$APP_LAUNCHED" == "1" ]]; then
    terminate_app || true
  fi
  return "$exit_status"
}

trap cleanup_on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ "$BUILD_FIRST" == "1" ]]; then
  echo "Building $SCHEME with $BUILD_SDK..."
  if run_with_timeout "$BUILD_TIMEOUT" xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -sdk "$BUILD_SDK" \
    -destination "$BUILD_DESTINATION" \
    ONLY_ACTIVE_ARCH="$ONLY_ACTIVE_ARCH" \
    CODE_SIGNING_ALLOWED=NO \
    NOVAFORGE_SOURCE_COMMIT="$SOURCE_COMMIT" \
    NOVAFORGE_SOURCE_TREE_HASH="$SOURCE_TREE_HASH" \
    -quiet \
    build >"$BUILD_LOG" 2>&1; then
    :
  else
    build_status=$?
    if (( build_status == 124 )); then
      echo "Build timed out after ${BUILD_TIMEOUT}s." >&2
    fi
    echo "Build failed. Last 80 lines from $BUILD_LOG:" >&2
    tail -n 80 "$BUILD_LOG" >&2
    exit 1
  fi
else
  echo "Skipping build. Set BUILD_FIRST=1 to rebuild before launch."
fi

if [[ -z "$APP_PATH" ]]; then
  APP_PATH="$(latest_app_path)"
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "Built app was not found at $APP_PATH" >&2
  echo "Run BUILD_FIRST=1 $0, or pass APP_PATH=/path/to/$APP_NAME." >&2
  exit 1
fi

require_core_simulator_health

if [[ "$ENSURE_BOOTED" == "1" ]]; then
  echo "Ensuring simulator $SIMULATOR_ID is booted..."
  run_with_timeout "$SIMCTL_TIMEOUT" xcrun simctl boot "$SIMULATOR_ID" >/dev/null 2>&1 || true
  if run_with_timeout "$SIMCTL_TIMEOUT" xcrun simctl bootstatus "$SIMULATOR_ID" -b >/dev/null 2>&1; then
    :
  else
    boot_status=$?
    if (( boot_status == 124 )); then
      echo "Simulator bootstatus timed out after ${SIMCTL_TIMEOUT}s." >&2
    fi
    echo "Simulator did not finish booting." >&2
    exit 1
  fi
fi

if [[ "$LAUNCH_APP" != "1" ]]; then
  write_run_metadata
  echo "Skipping launch. Set LAUNCH_APP=1 to launch before screenshot."
  echo "Smoke build/setup passed."
  echo "Simulator: $SIMULATOR_ID"
  echo "Build first: $BUILD_FIRST"
  echo "Install app: $INSTALL_APP"
  echo "Launch app: $LAUNCH_APP"
  echo "App: $APP_PATH"
  echo "Logs: $LOG_DIR"
  exit 0
fi

if [[ "$INSTALL_APP" == "1" ]]; then
  echo "Installing $APP_PATH on simulator $SIMULATOR_ID..."
  if run_with_timeout "$SIMCTL_TIMEOUT" xcrun simctl install "$SIMULATOR_ID" "$APP_PATH" >"$INSTALL_LOG" 2>&1; then
    :
  else
    install_status=$?
    if (( install_status == 124 )); then
      echo "Install timed out after ${SIMCTL_TIMEOUT}s. CoreSimulator may be wedged." >&2
    fi
    echo "Install failed. Last 80 lines from $INSTALL_LOG:" >&2
    tail -n 80 "$INSTALL_LOG" >&2
    exit 1
  fi
else
  echo "Skipping install. Set INSTALL_APP=1 to reinstall before launch."
fi

echo "Launching $BUNDLE_ID ${LAUNCH_ARGS[*]}..."
if run_with_timeout "$SIMCTL_TIMEOUT" xcrun simctl launch \
  --terminate-running-process \
  "$SIMULATOR_ID" \
  "$BUNDLE_ID" \
  "${LAUNCH_ARGS[@]}" >"$LAUNCH_LOG" 2>&1; then
  :
else
  launch_status=$?
  if (( launch_status == 124 )); then
    echo "Launch timed out after ${SIMCTL_TIMEOUT}s. CoreSimulator may be wedged." >&2
  fi
  echo "Launch failed. Last 80 lines from $LAUNCH_LOG:" >&2
  tail -n 80 "$LAUNCH_LOG" >&2
  exit 1
fi
APP_LAUNCHED=1

sleep "$WAIT_SECONDS"

if [[ "$CAPTURE_SCREENSHOT" != "1" ]]; then
  write_run_metadata
  echo "Skipping screenshot. Set CAPTURE_SCREENSHOT=1 to capture after launch."
  echo "Smoke launch passed."
  echo "Simulator: $SIMULATOR_ID"
  echo "Build first: $BUILD_FIRST"
  echo "Install app: $INSTALL_APP"
  echo "Launch app: $LAUNCH_APP"
  echo "App: $APP_PATH"
  echo "Logs: $LOG_DIR"
  exit 0
fi

echo "Capturing screenshot..."
if run_with_timeout "$SIMCTL_TIMEOUT" xcrun simctl io "$SIMULATOR_ID" screenshot "$SCREENSHOT_PATH" >"$SCREENSHOT_LOG" 2>&1; then
  :
else
  screenshot_status=$?
  if (( screenshot_status == 124 )); then
    echo "Screenshot timed out after ${SIMCTL_TIMEOUT}s. CoreSimulator may be wedged." >&2
  fi
  echo "Screenshot capture failed. Last 80 lines from $SCREENSHOT_LOG:" >&2
  tail -n 80 "$SCREENSHOT_LOG" >&2
  exit 1
fi

write_run_metadata

echo "Smoke passed."
echo "Simulator: $SIMULATOR_ID"
echo "Build first: $BUILD_FIRST"
echo "Install app: $INSTALL_APP"
echo "App: $APP_PATH"
echo "Screenshot: $SCREENSHOT_PATH"
echo "Logs: $LOG_DIR"
echo "Run metadata: $RUN_METADATA_PATH"
