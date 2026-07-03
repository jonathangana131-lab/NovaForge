#!/usr/bin/env zsh
emulate -L zsh
set -e
set -u
set -o pipefail

ROOT_DIR="${0:A:h:h}"
PROJECT_PATH="${PROJECT_PATH:-$ROOT_DIR/AgentPad.xcodeproj}"
SCHEME="${SCHEME:-AgentPad}"
CONFIGURATION="${CONFIGURATION:-Debug}"
BUILD_SDK="${BUILD_SDK:-iphonesimulator}"
SIMULATOR_ID="${SIMULATOR_ID:-4B9AB34A-404C-485F-B0BC-964F24D0AE83}"
TEST_TIMEOUT="${TEST_TIMEOUT:-240}"
BUILD_TIMEOUT="${BUILD_TIMEOUT:-480}"
SIM_BOOT_TIMEOUT="${SIM_BOOT_TIMEOUT:-180}"
DESTINATION_TIMEOUT="${DESTINATION_TIMEOUT:-120}"
ONLY_ACTIVE_ARCH="${ONLY_ACTIVE_ARCH:-YES}"
BUILD_FOR_TESTING_FIRST="${BUILD_FOR_TESTING_FIRST:-1}"
FOCUSED_TEST_MODE="${FOCUSED_TEST_MODE:-batch}"
PREBOOT_SIMULATOR="${PREBOOT_SIMULATOR:-1}"
REBOOT_SIMULATOR_BETWEEN_SUITES="${REBOOT_SIMULATOR_BETWEEN_SUITES:-1}"
SHUTDOWN_SIMULATOR_AFTER_TESTS="${SHUTDOWN_SIMULATOR_AFTER_TESTS:-1}"
LOG_DIR="${LOG_DIR:-$ROOT_DIR/QA/codex-focused-tests-$(date +%Y%m%d-%H%M%S)}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$LOG_DIR/DerivedData}"
XCTESTRUN_PATH="${XCTESTRUN_PATH:-}"
TIMEOUT_RUNNER="$ROOT_DIR/scripts/codex-timeout-runner.pl"

mkdir -p "$LOG_DIR"

cleanup_on_exit() {
  local exit_status=$?
  if [[ "$SHUTDOWN_SIMULATOR_AFTER_TESTS" == "1" ]]; then
    "$TIMEOUT_RUNNER" "$SIM_BOOT_TIMEOUT" "$LOG_DIR/simulator-shutdown-final.log" xcrun simctl shutdown "$SIMULATOR_ID" >/dev/null 2>&1 || true
  fi
  return "$exit_status"
}

trap cleanup_on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

derived_data_args=()
if [[ -n "$DERIVED_DATA_PATH" ]]; then
  mkdir -p "$DERIVED_DATA_PATH"
  derived_data_args=(-derivedDataPath "$DERIVED_DATA_PATH")
fi

suites=(
  "AgentPadTests/AgentRuntimeLifecycleTests"
  "AgentPadTests/ProjectFoundationTests"
  "AgentPadTests/CommandRunnerTests"
  "AgentPadTests/FilesWorkspacePersistenceTests"
)

only_testing_args=()
for suite in "${suites[@]}"; do
  only_testing_args+=("-only-testing:$suite")
done

package_args=(
  -skipPackageUpdates
  -skipPackagePluginValidation
  -skipMacroValidation
)

run_project_xcodebuild_with_timeout() {
  local timeout="$1"
  local log_path="$2"
  shift 2

  "$TIMEOUT_RUNNER" "$timeout" "$log_path" xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -sdk "$BUILD_SDK" \
    -destination "id=$SIMULATOR_ID" \
    -destination-timeout "$DESTINATION_TIMEOUT" \
    "${derived_data_args[@]}" \
    "${package_args[@]}" \
    ONLY_ACTIVE_ARCH="$ONLY_ACTIVE_ARCH" \
    CODE_SIGNING_ALLOWED=NO \
    "$@"
}

run_xctestrun_with_timeout() {
  local timeout="$1"
  local log_path="$2"
  shift 2

  "$TIMEOUT_RUNNER" "$timeout" "$log_path" xcodebuild \
    -xctestrun "$XCTESTRUN_PATH" \
    -destination "id=$SIMULATOR_ID" \
    -destination-timeout "$DESTINATION_TIMEOUT" \
    "$@"
}

preboot_simulator() {
  local label="${1:-suite}"
  local boot_log_path="$LOG_DIR/simulator-bootstatus-$label.log"
  local shutdown_log_path="$LOG_DIR/simulator-shutdown-$label.log"
  echo "Preparing simulator $SIMULATOR_ID"
  xcrun simctl terminate "$SIMULATOR_ID" com.joey.NovaForge >/dev/null 2>&1 || true
  if [[ "$REBOOT_SIMULATOR_BETWEEN_SUITES" == "1" ]]; then
    "$TIMEOUT_RUNNER" "$SIM_BOOT_TIMEOUT" "$shutdown_log_path" xcrun simctl shutdown "$SIMULATOR_ID" >/dev/null 2>&1 || true
  fi
  xcrun simctl boot "$SIMULATOR_ID" >/dev/null 2>&1 || true
  "$TIMEOUT_RUNNER" "$SIM_BOOT_TIMEOUT" "$boot_log_path" xcrun simctl bootstatus "$SIMULATOR_ID" -b
}

discover_xctestrun() {
  local -a candidates=()
  if [[ -n "$XCTESTRUN_PATH" ]]; then
    [[ -f "$XCTESTRUN_PATH" ]] && print -r -- "$XCTESTRUN_PATH" && return 0
    return 1
  fi

  if [[ -n "$DERIVED_DATA_PATH" ]]; then
    candidates+=( "$DERIVED_DATA_PATH"/Build/Products/${SCHEME}_*.xctestrun(N.om[1]) )
  else
    candidates+=( "$HOME"/Library/Developer/Xcode/DerivedData/${SCHEME}-*/Build/Products/${SCHEME}_*.xctestrun(N.om[1]) )
  fi

  (( ${#candidates} > 0 )) || return 1
  print -r -- "$candidates[1]"
}

if [[ "$BUILD_FOR_TESTING_FIRST" == "1" ]]; then
  build_log="$LOG_DIR/build-for-testing.log"
  echo "Building focused test bundle"
  if run_project_xcodebuild_with_timeout "$BUILD_TIMEOUT" "$build_log" build-for-testing; then
    echo "ok build-for-testing"
  else
    exit_status=$?
    if (( exit_status == 142 )); then
      echo "build-for-testing timed out after ${BUILD_TIMEOUT}s." >&2
    else
      echo "build-for-testing failed with status $exit_status." >&2
    fi
    echo "Last 80 lines from $build_log:" >&2
    tail -n 80 "$build_log" >&2
    exit "$exit_status"
  fi

  if XCTESTRUN_PATH="$(discover_xctestrun)"; then
    echo "Using xctestrun: $XCTESTRUN_PATH"
    print -r -- "$XCTESTRUN_PATH" > "$LOG_DIR/xctestrun.path"
  else
    echo "Could not find an .xctestrun file after build-for-testing." >&2
    exit 1
  fi
fi

run_suite() {
  local suite="$1"
  local suite_label="${suite//\//-}"
  local log_name="${suite//\//-}.log"
  local log_path="$LOG_DIR/$log_name"
  local action="test"
  if [[ "$BUILD_FOR_TESTING_FIRST" == "1" || -n "$XCTESTRUN_PATH" ]]; then
    action="test-without-building"
  fi

  if [[ "$PREBOOT_SIMULATOR" == "1" ]]; then
    if preboot_simulator "$suite_label"; then
      echo "ok simulator bootstatus $suite"
    else
      exit_status=$?
      if (( exit_status == 142 )); then
        echo "simulator bootstatus timed out after ${SIM_BOOT_TIMEOUT}s." >&2
      else
        echo "simulator bootstatus failed with status $exit_status." >&2
      fi
      echo "Last 80 lines from $LOG_DIR/simulator-bootstatus-$suite_label.log:" >&2
      tail -n 80 "$LOG_DIR/simulator-bootstatus-$suite_label.log" >&2
      exit "$exit_status"
    fi
  fi

  echo "Running $suite"
  local exit_status=0
  if [[ -n "$XCTESTRUN_PATH" ]]; then
    run_xctestrun_with_timeout "$TEST_TIMEOUT" "$log_path" "$action" -only-testing:"$suite" || exit_status=$?
  else
    run_project_xcodebuild_with_timeout "$TEST_TIMEOUT" "$log_path" "$action" -only-testing:"$suite" || exit_status=$?
  fi

  if (( exit_status == 0 )); then
    echo "ok $suite"
    return 0
  fi

  if (( exit_status == 142 )); then
    echo "$suite timed out after ${TEST_TIMEOUT}s." >&2
  else
    echo "$suite failed with status $exit_status." >&2
  fi
  echo "Last 80 lines from $log_path:" >&2
  tail -n 80 "$log_path" >&2
  exit "$exit_status"
}

run_batch() {
  local log_path="$LOG_DIR/focused-suites.log"
  local action="test"
  if [[ "$BUILD_FOR_TESTING_FIRST" == "1" || -n "$XCTESTRUN_PATH" ]]; then
    action="test-without-building"
  fi

  if [[ "$PREBOOT_SIMULATOR" == "1" ]]; then
    if preboot_simulator "focused-suites"; then
      echo "ok simulator bootstatus focused suites"
    else
      exit_status=$?
      if (( exit_status == 142 )); then
        echo "simulator bootstatus timed out after ${SIM_BOOT_TIMEOUT}s." >&2
      else
        echo "simulator bootstatus failed with status $exit_status." >&2
      fi
      echo "Last 80 lines from $LOG_DIR/simulator-bootstatus-focused-suites.log:" >&2
      tail -n 80 "$LOG_DIR/simulator-bootstatus-focused-suites.log" >&2
      exit "$exit_status"
    fi
  fi

  echo "Running focused suites"
  local exit_status=0
  if [[ -n "$XCTESTRUN_PATH" ]]; then
    run_xctestrun_with_timeout "$TEST_TIMEOUT" "$log_path" "$action" "${only_testing_args[@]}" || exit_status=$?
  else
    run_project_xcodebuild_with_timeout "$TEST_TIMEOUT" "$log_path" "$action" "${only_testing_args[@]}" || exit_status=$?
  fi

  if (( exit_status == 0 )); then
    echo "ok focused suites"
    return 0
  fi

  if (( exit_status == 142 )); then
    echo "focused suites timed out after ${TEST_TIMEOUT}s." >&2
  else
    echo "focused suites failed with status $exit_status." >&2
  fi
  echo "Last 120 lines from $log_path:" >&2
  tail -n 120 "$log_path" >&2
  exit "$exit_status"
}

case "$FOCUSED_TEST_MODE" in
  batch)
    run_batch
    ;;
  per-suite)
    for suite in "${suites[@]}"; do
      run_suite "$suite"
    done
    ;;
  *)
    echo "Unknown FOCUSED_TEST_MODE=$FOCUSED_TEST_MODE. Use batch or per-suite." >&2
    exit 2
    ;;
esac

echo "Focused tests passed."
echo "Logs: $LOG_DIR"
