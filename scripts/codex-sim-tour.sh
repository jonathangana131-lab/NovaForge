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
MAX_WAIT_SECONDS="${MAX_WAIT_SECONDS:-30}"
SIMCTL_TIMEOUT="${SIMCTL_TIMEOUT:-90}"
STEP_TIMEOUT="${STEP_TIMEOUT:-45}"
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
APP_NAME="${APP_NAME:-NovaForge.app}"
APP_PATH="${APP_PATH:-}"
DERIVED_DATA_ROOT="${DERIVED_DATA_ROOT:-$HOME/Library/Developer/Xcode/DerivedData}"
SOURCE_COMMIT="${NOVAFORGE_SOURCE_COMMIT:-$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || true)}"
SOURCE_TREE_HASH="${NOVAFORGE_SOURCE_TREE_HASH:-}"
STAMP="$(date +%Y%m%d-%H%M%S)-$$"
TOUR_DIR="${TOUR_DIR:-$ROOT_DIR/NovaForgeScreenshots/codex-tour-$STAMP}"
TOUR_LOG_DIR="${TOUR_LOG_DIR:-$ROOT_DIR/QA/codex-tour-$STAMP}"
TOUR_INSTALL_MARKER="${TOUR_INSTALL_MARKER:-$TOUR_LOG_DIR/installed-$SIMULATOR_ID-$CONFIGURATION.stamp}"
TOUR_METADATA_PATH="${TOUR_METADATA_PATH:-$TOUR_DIR/tour-metadata.txt}"
TOUR_FIXTURE_MANIFEST_PATH="${TOUR_FIXTURE_MANIFEST_PATH:-$TOUR_DIR/tour-fixtures.tsv}"
TOUR_START_TIME="${EPOCHREALTIME:-0}"
SECONDS=0

for timeout_value in "$SIMCTL_TIMEOUT" "$BUILD_TIMEOUT" "$STEP_TIMEOUT"; do
  if ! [[ "$timeout_value" =~ '^[1-9][0-9]*$' ]]; then
    echo "SIMCTL_TIMEOUT, BUILD_TIMEOUT, and STEP_TIMEOUT must be positive integers." >&2
    exit 2
  fi
done
if ! [[ "$WAIT_SECONDS" =~ '^[0-9]+$' && "$MAX_WAIT_SECONDS" =~ '^[0-9]+$' ]]; then
  echo "WAIT_SECONDS and MAX_WAIT_SECONDS must be non-negative integers." >&2
  exit 2
fi
if (( WAIT_SECONDS > MAX_WAIT_SECONDS )); then
  echo "WAIT_SECONDS=${WAIT_SECONDS} exceeds MAX_WAIT_SECONDS=${MAX_WAIT_SECONDS}." >&2
  exit 2
fi
if ! [[ "$MAX_TOUR_SECONDS" =~ '^[1-9][0-9]*$' ]]; then
  echo "MAX_TOUR_SECONDS must be a positive integer." >&2
  exit 2
fi
if [[ "$VERIFY_TOUR_SCREENSHOTS" != "1" ]]; then
  echo "Tour screenshot verification cannot be disabled." >&2
  exit 2
fi

mkdir -p "$TOUR_DIR" "$TOUR_LOG_DIR"
if [[ -n "$(find "$TOUR_DIR" -maxdepth 1 -type f -print -quit 2>/dev/null)" ]]; then
  echo "Tour output directory is not empty: $TOUR_DIR" >&2
  echo "Choose a new TOUR_DIR; existing proof will not be overwritten." >&2
  exit 2
fi
print -r -- $'step\tfixture\tlaunch arguments' > "$TOUR_FIXTURE_MANIFEST_PATH"

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

latest_app_path() {
  local -a matches
  matches=("$DERIVED_DATA_ROOT"/AgentPad-*/Build/Products/"$CONFIGURATION"-iphonesimulator/"$APP_NAME"(Nom[1]))
  if (( ${#matches} > 0 )); then
    print -r -- "$matches[1]"
  fi
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

write_tour_metadata() {
  mkdir -p "${TOUR_METADATA_PATH:h}"
  print -r -- "tourID=$STAMP" > "$TOUR_METADATA_PATH"
  print -r -- "sourceCommit=$SOURCE_COMMIT" >> "$TOUR_METADATA_PATH"
  print -r -- "sourceTreeHash=$SOURCE_TREE_HASH" >> "$TOUR_METADATA_PATH"
  print -r -- "configuration=$CONFIGURATION" >> "$TOUR_METADATA_PATH"
  print -r -- "simulatorID=$SIMULATOR_ID" >> "$TOUR_METADATA_PATH"
  print -r -- "appPath=$APP_PATH" >> "$TOUR_METADATA_PATH"
  print -r -- "appBundleHash=$(app_bundle_hash "$APP_PATH")" >> "$TOUR_METADATA_PATH"
  print -r -- "expectedSurfaceCount=20" >> "$TOUR_METADATA_PATH"
}

record_fixture() {
  local step_name="$1"
  local fixture_id="$2"
  shift 2
  print -r -- "$step_name"$'\t'"$fixture_id"$'\t'"${(j: :)@}" >> "$TOUR_FIXTURE_MANIFEST_PATH"
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
  if run_with_timeout "$SIMCTL_TIMEOUT" xcrun simctl list devices | grep -F "$SIMULATOR_ID" | grep -q "(Booted)"; then
    echo "Shutting down simulator $SIMULATOR_ID after tour."
    run_with_timeout "$SIMCTL_TIMEOUT" xcrun simctl shutdown "$SIMULATOR_ID" >/dev/null 2>&1 || {
      echo "Warning: unable to shut down simulator $SIMULATOR_ID after tour." >&2
    }
  fi
}

tour_cleanup() {
  local exit_status=$?
  if (( exit_status != 0 )); then
    local helper_pid
    local helper_pids
    helper_pids="$(pgrep -f "$ROOT_DIR/scripts/codex-(sim-tour|fast-screenshot)\.sh" 2>/dev/null || true)"
    for helper_pid in ${(f)helper_pids}; do
      [[ "$helper_pid" == "$$" ]] || terminate_process_tree "$helper_pid" TERM
    done
  fi
  if [[ "$SHUTDOWN_SIMULATOR_AFTER_TOUR" == "1" ]]; then
    shutdown_simulator
  fi
  return "$exit_status"
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
  [[ -n "$SOURCE_TREE_HASH" ]] || SOURCE_TREE_HASH="$(source_tree_hash)"
  mkdir -p "$TOUR_LOG_DIR/build"
  if ! run_with_timeout "$BUILD_TIMEOUT" env \
    "CONFIGURATION=$CONFIGURATION" \
    "BUILD_FIRST=1" \
    "LAUNCH_APP=0" \
    "INSTALL_APP=0" \
    "CAPTURE_SCREENSHOT=0" \
    "SIMULATOR_ID=$SIMULATOR_ID" \
    "BUILD_TIMEOUT=$BUILD_TIMEOUT" \
    "DERIVED_DATA_ROOT=$DERIVED_DATA_ROOT" \
    "NOVAFORGE_SOURCE_COMMIT=$SOURCE_COMMIT" \
    "NOVAFORGE_SOURCE_TREE_HASH=$SOURCE_TREE_HASH" \
    "RUN_METADATA_PATH=$TOUR_LOG_DIR/build/run-metadata.txt" \
    "LOG_DIR=$TOUR_LOG_DIR/build" \
    "$LEGACY_BUILD_SCRIPT" > "$TOUR_LOG_DIR/build/tour-build.log" 2>&1; then
    echo "Tour build failed or timed out. Last 80 lines:" >&2
    tail -n 80 "$TOUR_LOG_DIR/build/tour-build.log" >&2 || true
    exit 1
  fi
fi

if [[ -z "$SOURCE_TREE_HASH" ]]; then
  SOURCE_TREE_HASH="$(source_tree_hash)"
fi
if [[ -z "$APP_PATH" ]]; then
  APP_PATH="$(latest_app_path)"
fi
if [[ ! -d "$APP_PATH" ]]; then
  echo "Tour app was not found at $APP_PATH" >&2
  echo "Build once or pass APP_PATH=/path/to/$APP_NAME." >&2
  exit 1
fi
write_tour_metadata

run_step() {
  local step_name="$1"
  local fixture_id="$2"
  local install_app="$3"
  local build_first="$4"
  shift 4

  local screenshot_path="$TOUR_DIR/$step_name.png"
  local step_log_dir="$TOUR_LOG_DIR/$step_name"
  mkdir -p "$step_log_dir"
  record_fixture "$step_name.png" "$fixture_id" "$@"

  echo
  echo "Tour step: $step_name"
  if ! run_with_timeout "$STEP_TIMEOUT" env \
    "SCREENSHOT_PATH=$screenshot_path" \
    "LOG_DIR=$step_log_dir" \
    "WAIT_SECONDS=$WAIT_SECONDS" \
    "SIMULATOR_ID=$SIMULATOR_ID" \
    "CONFIGURATION=$CONFIGURATION" \
    "APP_PATH=$APP_PATH" \
    "INSTALL_APP=$install_app" \
    "INSTALL_IF_NEWER=1" \
    "INSTALL_MARKER=$TOUR_INSTALL_MARKER" \
    "BUILD_FIRST=$build_first" \
    "TERMINATE_AFTER_CAPTURE=1" \
    "BOOT_SIMULATOR=1" \
    "SHUTDOWN_SIMULATOR_AFTER_CAPTURE=0" \
    "$SMOKE_SCRIPT" "$@" > "$step_log_dir/tour-step.log" 2>&1; then
    echo "Tour step failed or timed out: $step_name. Last 80 lines:" >&2
    tail -n 80 "$step_log_dir/tour-step.log" >&2 || true
    exit 1
  fi
}

run_step "01-chat-default-clean" "chat-clean" 1 0 --reset-ui --open-chat
WAIT_SECONDS=30 run_step "02-mission-dossier-idle" "project-idle" 0 0 --reset-ui --settings-local-model-ready --open-project --open-mission-dossier-demo
WAIT_SECONDS=30 run_step "03-mission-dossier-running" "project-running" 0 0 --reset-ui --settings-local-model-ready --project-running-demo --open-project --open-mission-dossier-demo
WAIT_SECONDS=30 run_step "04-chat-pending-approval" "chat-pending-approval" 0 0 --reset-ui --settings-local-model-ready --pending-approval-demo --open-chat
WAIT_SECONDS=30 run_step "05-mission-dossier-waiting" "project-waiting-approval" 0 0 --reset-ui --settings-local-model-ready --project-waiting-demo --open-project --open-mission-dossier-demo
WAIT_SECONDS=30 run_step "06-mission-dossier-blocked" "project-blocked" 0 0 --reset-ui --settings-local-model-ready --project-blocked-demo --open-project --open-mission-dossier-demo
WAIT_SECONDS=30 run_step "07-mission-dossier-proof" "project-proof" 0 0 --reset-ui --settings-local-model-ready --project-proof-demo --open-project --open-mission-dossier-demo
WAIT_SECONDS=30 run_step "08-mission-dossier-resume" "project-resume" 0 0 --reset-ui --settings-local-model-ready --project-resume-demo --open-project --open-mission-dossier-demo
WAIT_SECONDS=30 run_step "09-mission-dossier-auto-continue-countdown" "project-auto-continue" 0 0 --reset-ui --settings-local-model-ready --auto-continue-countdown-demo --open-project --open-mission-dossier-demo
WAIT_SECONDS=30 run_step "10-runs-proof" "runs-proof" 0 0 --reset-ui --project-proof-demo --open-runs
WAIT_SECONDS=30 run_step "11-files-proof" "files-proof" 0 0 --reset-ui --project-proof-demo --open-files
WAIT_SECONDS=30 run_step "12-terminal-live-record" "terminal-live-record" 0 0 --reset-ui --terminal-live-record-demo --open-terminal
WAIT_SECONDS=30 run_step "13-settings-local-ready" "settings-local-ready" 0 0 --reset-ui --settings-local-model-ready --open-settings
WAIT_SECONDS=30 run_step "14-runs-pending-approval" "runs-approval-history" 0 0 --reset-ui --runs-approval-demo --open-runs
WAIT_SECONDS=30 run_step "15-theme-matrix-mission-dossier-running" "theme-matrix-project-running" 0 0 --reset-ui --settings-local-model-ready --theme-world=matrixRain --project-running-demo --open-project --open-mission-dossier-demo
WAIT_SECONDS=30 run_step "16-theme-midnight-chat-general" "theme-midnight-chat" 0 0 --reset-ui --settings-local-model-ready --theme-world=midnightBlack --theme-proof-demo --open-chat
WAIT_SECONDS=30 run_step "17-theme-whitegold-settings" "theme-whitegold-settings" 0 0 --reset-ui --theme-world=whiteGold --settings-local-model-ready --open-settings
WAIT_SECONDS=30 run_step "18-theme-arctic-runs-proof" "theme-arctic-runs-proof" 0 0 --reset-ui --theme-world=arcticGlass --project-proof-demo --open-runs
WAIT_SECONDS=30 run_step "19-theme-ember-terminal-proof" "theme-ember-terminal-proof" 0 0 --reset-ui --theme-world=emberCore --terminal-live-record-demo --open-terminal
WAIT_SECONDS=30 run_step "20-mission-dossier-intake-brief" "project-intake" 0 0 --reset-ui --settings-local-model-ready --open-project --open-mission-dossier-demo --project-intake-demo

MIN_SCREENSHOT_BYTES="${MIN_SCREENSHOT_BYTES:-120000}" "$TOUR_VERIFY_SCRIPT" "$TOUR_DIR"

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
