#!/usr/bin/env zsh
emulate -L zsh
set -e
set -u
set -o pipefail

# NovaForge's single test entry point.
#
#   smoke    Four UI journeys for a sub-three-minute sanity check.
#   critical Package contracts, all unit tests, and the highest-value UI paths.
#   unit     Package contracts and all app unit tests, without UI tests.
#   visual   A representative UI census with screenshots written to QA.
#   release  Package contracts, all unit tests, and every UI journey.
#
# Every app lane incrementally builds one shared test bundle, then executes it
# with test-without-building. Critical runs units once and gives each UI journey
# a fresh XCTest runner so one poisoned accessibility session cannot strand the
# rest of the lane. The runner never sleeps for an arbitrary amount of time.

ROOT_DIR="${0:A:h:h}"
LANE="${1:-critical}"
PROJECT_PATH="${PROJECT_PATH:-$ROOT_DIR/AgentPad.xcodeproj}"
SCHEME="${SCHEME:-AgentPad}"
CONFIGURATION="${CONFIGURATION:-Debug}"
SIMULATOR_ID="${SIMULATOR_ID:-4B9AB34A-404C-485F-B0BC-964F24D0AE83}"
DESTINATION_TIMEOUT="${DESTINATION_TIMEOUT:-120}"
BUILD_TIMEOUT="${BUILD_TIMEOUT:-720}"
TEST_TIMEOUT="${TEST_TIMEOUT:-1200}"
UNIT_TEST_TIMEOUT="${UNIT_TEST_TIMEOUT:-600}"
UI_TEST_TIMEOUT="${UI_TEST_TIMEOUT:-300}"
UI_TEST_RESTART_INTERVAL="${UI_TEST_RESTART_INTERVAL:-4}"
PACKAGE_TIMEOUT="${PACKAGE_TIMEOUT:-600}"
SIM_BOOT_TIMEOUT="${SIM_BOOT_TIMEOUT:-180}"
TIMEOUT_RUNNER="$ROOT_DIR/scripts/codex-timeout-runner.pl"
MANAGED_DERIVED_DATA_PATH="$ROOT_DIR/QA/DerivedData/codex-tests"
MANAGED_DERIVED_DATA_LOCK_DIR="$ROOT_DIR/QA/DerivedData/.codex-tests.lock"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$MANAGED_DERIVED_DATA_PATH}"
LOG_DIR="${LOG_DIR:-$ROOT_DIR/QA/codex-tests-$(date +%Y%m%d-%H%M%S)-$LANE}"
if [[ -n "${RESULT_BUNDLE_PATH+x}" ]]; then
  RESULT_BUNDLE_PATH_WAS_EXPLICIT=1
else
  RESULT_BUNDLE_PATH_WAS_EXPLICIT=0
fi
RESULT_BUNDLE_PATH="${RESULT_BUNDLE_PATH:-$LOG_DIR/$LANE.xcresult}"
WRITE_RESULT_BUNDLE="${WRITE_RESULT_BUNDLE:-auto}"
XCTESTRUN_PATH="${XCTESTRUN_PATH:-}"
BUILD_FOR_TESTING_FIRST="${BUILD_FOR_TESTING_FIRST:-1}"
RESET_DERIVED_DATA_BEFORE_BUILD="${RESET_DERIVED_DATA_BEFORE_BUILD:-0}"
MAX_DERIVED_DATA_GIB="${MAX_DERIVED_DATA_GIB:-6}"
SHUTDOWN_SIMULATOR_AFTER_TESTS="${SHUTDOWN_SIMULATOR_AFTER_TESTS:-0}"
NOVAFORGE_TEST_VALIDATE_ONLY="${NOVAFORGE_TEST_VALIDATE_ONLY:-0}"
NOVAFORGE_TEST_INCLUDE_PREFLIGHT="${NOVAFORGE_TEST_INCLUDE_PREFLIGHT:-auto}"
NOVAFORGE_TEST_INCLUDE_PACKAGE="${NOVAFORGE_TEST_INCLUDE_PACKAGE:-auto}"
NOVAFORGE_CAPTURE_MODE="${NOVAFORGE_CAPTURE_MODE:-auto}"
NOVAFORGE_SCREENSHOT_DIR="${NOVAFORGE_SCREENSHOT_DIR:-$LOG_DIR/screenshots}"
MANAGED_DERIVED_DATA_LOCKED=0

smoke_ui_tests=(
  testLaunchShowsNovaForge
  testForgeChatSendStreamsOneAssistantBubbleAndClearsRunningState
  testComposerProviderSwitchingRepairsStaleModelInline
  testReasoningAndUltraCodePickerUsesExpandableLiquidGlassControl
)

critical_ui_tests=(
  "${smoke_ui_tests[@]}"
  testForgeChatFailedSendShowsTranscriptErrorAndRecoversComposer
  testFourTabDockAndMissionDossierRouteSemantics
  testFirstRunLocalMissingBlocksStarterMissionsAndShowsDownloadsSetup
  testChatGPTSubscriptionSignInReplacesSimulatedTerminal
  testFilesStressListAndSearch
  testToolBearingMarkdownCompletedRunDetachesToLatest
  testCanonicalActivityApprovalIsAccessibleCompactAndLegacyFree
  testLocalWebArtifactCreatesPreviewableLandingPage
  testFilesVisibleActionsDuplicateAndConfirmDelete
)

visual_ui_tests=(
  testBigPictureFirstRunMissionBriefingScreenshot
  testChatComposerKeyboardAndResponseScreenshots
  testFourTabDockAndMissionDossierRouteSemantics
  testChatDrawerScreenshot
  testLocalModelSettingsScreenshot
  testNativeModelPickerAndChatGPTProviderScreenshot
  testReasoningAndUltraCodePickerUsesExpandableLiquidGlassControl
  testLegacyV1ArtifactPreviewStudioModes
  testGoalMatrixChatReadabilityAndThemeSwitchingScreenshots
  testAccessibilityLayoutTouchTargetsAndCompactLabels
)

preflight_scripts=(
  scripts/verify-agent-v1-goldens.sh
  scripts/verify-workspace-mutation-boundary.sh
  scripts/verify-hermes-baseline-lock.sh
  scripts/test-codex-timeout-runner.sh
  scripts/test-focused-test-harness.sh
  scripts/test-m5-scorecard.sh
  scripts/test-release-candidate-audit.sh
)

case "$LANE" in
  smoke|critical|unit|visual|release) ;;
  *)
    echo "Unknown lane '$LANE'. Use smoke, critical, unit, visual, or release." >&2
    exit 2
    ;;
esac

if [[ "$NOVAFORGE_TEST_INCLUDE_PREFLIGHT" == "auto" ]]; then
  case "$LANE" in
    critical|unit|release) NOVAFORGE_TEST_INCLUDE_PREFLIGHT=1 ;;
    *) NOVAFORGE_TEST_INCLUDE_PREFLIGHT=0 ;;
  esac
fi
if [[ "$NOVAFORGE_TEST_INCLUDE_PACKAGE" == "auto" ]]; then
  case "$LANE" in
    critical|unit|release) NOVAFORGE_TEST_INCLUDE_PACKAGE=1 ;;
    *) NOVAFORGE_TEST_INCLUDE_PACKAGE=0 ;;
  esac
fi
if [[ "$NOVAFORGE_CAPTURE_MODE" == "auto" ]]; then
  [[ "$LANE" == "visual" ]] && NOVAFORGE_CAPTURE_MODE=all || NOVAFORGE_CAPTURE_MODE=off
fi
if [[ "$WRITE_RESULT_BUNDLE" == "auto" ]]; then
  if (( RESULT_BUNDLE_PATH_WAS_EXPLICIT == 1 )) || [[ "$LANE" == "release" ]]; then
    WRITE_RESULT_BUNDLE=1
  else
    WRITE_RESULT_BUNDLE=0
  fi
fi

ui_tests=()
case "$LANE" in
  smoke) ui_tests=( "${smoke_ui_tests[@]}" ) ;;
  critical) ui_tests=( "${critical_ui_tests[@]}" ) ;;
  visual) ui_tests=( "${visual_ui_tests[@]}" ) ;;
esac

validate_test_inventory() {
  local source="$ROOT_DIR/AgentPadUITests/AgentPadUITests.swift"
  local test_name=""
  local -a configured=(
    "${smoke_ui_tests[@]}"
    "${critical_ui_tests[@]}"
    "${visual_ui_tests[@]}"
  )
  local -A seen=()
  local -a search_command
  if command -v rg >/dev/null 2>&1; then
    search_command=(rg -q)
  else
    search_command=(grep -Eq)
  fi
  for test_name in "${configured[@]}"; do
    if ! "${search_command[@]}" "^[[:space:]]*func[[:space:]]+${test_name}\\(" "$source"; then
      echo "Configured UI test does not exist: $test_name" >&2
      return 2
    fi
    seen[$test_name]=1
  done
  echo "Validated ${#seen} unique UI tests across smoke, critical, and visual lanes."
}

validate_lane_contract() {
  validate_test_inventory
  if (( ${#smoke_ui_tests} > 5 )); then
    echo "Smoke lane grew past five UI journeys; move coverage to critical." >&2
    return 2
  fi
  if (( ${#critical_ui_tests} > 16 )); then
    echo "Critical lane grew past sixteen UI journeys; move coverage to release." >&2
    return 2
  fi
  if [[ "$LANE" == "unit" && ${#ui_tests} -ne 0 ]]; then
    echo "Unit lane unexpectedly contains UI tests." >&2
    return 2
  fi
  echo "Validated $LANE lane contract."
}

validate_lane_contract
if [[ "$NOVAFORGE_TEST_VALIDATE_ONLY" == "1" ]]; then
  exit 0
fi

mkdir -p "$LOG_DIR"

acquire_derived_data_lock() {
  [[ "$DERIVED_DATA_PATH" == "$MANAGED_DERIVED_DATA_PATH" ]] || return 0
  mkdir -p "$ROOT_DIR/QA/DerivedData"
  if mkdir "$MANAGED_DERIVED_DATA_LOCK_DIR" 2>/dev/null; then
    print -r -- "$$" > "$MANAGED_DERIVED_DATA_LOCK_DIR/pid"
    MANAGED_DERIVED_DATA_LOCKED=1
    return 0
  fi

  local owner_pid=""
  [[ -f "$MANAGED_DERIVED_DATA_LOCK_DIR/pid" ]] && owner_pid="$(<"$MANAGED_DERIVED_DATA_LOCK_DIR/pid")"
  if [[ "$owner_pid" != <-> ]] || ! kill -0 "$owner_pid" 2>/dev/null; then
    echo "Removing stale NovaForge test-cache lock${owner_pid:+ from PID $owner_pid}."
    rm -rf -- "$MANAGED_DERIVED_DATA_LOCK_DIR"
    mkdir "$MANAGED_DERIVED_DATA_LOCK_DIR"
    print -r -- "$$" > "$MANAGED_DERIVED_DATA_LOCK_DIR/pid"
    MANAGED_DERIVED_DATA_LOCKED=1
    return 0
  fi

  echo "Another NovaForge test lane owns the shared build cache${owner_pid:+ (PID $owner_pid)}." >&2
  exit 75
}

prepare_derived_data() {
  [[ "$DERIVED_DATA_PATH" == "$MANAGED_DERIVED_DATA_PATH" ]] || {
    mkdir -p "$DERIVED_DATA_PATH"
    return 0
  }
  if [[ "$RESET_DERIVED_DATA_BEFORE_BUILD" == "1" ]]; then
    echo "Resetting managed test cache: $DERIVED_DATA_PATH"
    rm -rf -- "$DERIVED_DATA_PATH"
  elif [[ -d "$DERIVED_DATA_PATH" ]]; then
    if [[ "$MAX_DERIVED_DATA_GIB" != <-> ]]; then
      echo "MAX_DERIVED_DATA_GIB must be a non-negative integer." >&2
      exit 2
    fi
    local size_kib="$(du -sk "$DERIVED_DATA_PATH" | cut -f1)"
    local max_kib=$(( MAX_DERIVED_DATA_GIB * 1024 * 1024 ))
    if (( size_kib > max_kib )); then
      echo "Managed test cache exceeded ${MAX_DERIVED_DATA_GIB} GiB; rebuilding it."
      rm -rf -- "$DERIVED_DATA_PATH"
    fi
  fi
  mkdir -p "$DERIVED_DATA_PATH"
}

cleanup() {
  local exit_status=$?
  if [[ "$SHUTDOWN_SIMULATOR_AFTER_TESTS" == "1" ]]; then
    TIMEOUT_RUNNER_LABEL="simulator-shutdown" \
      "$TIMEOUT_RUNNER" 60 "$LOG_DIR/simulator-shutdown.log" \
      xcrun simctl shutdown "$SIMULATOR_ID" >/dev/null 2>&1 || true
  fi
  if (( MANAGED_DERIVED_DATA_LOCKED == 1 )); then
    rm -rf -- "$MANAGED_DERIVED_DATA_LOCK_DIR" || true
  fi
  return "$exit_status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

run_preflight() {
  local script=""
  echo "==> Deterministic source and harness preflight"
  for script in "${preflight_scripts[@]}"; do
    case "$script" in
      scripts/verify-agent-v1-goldens.sh|scripts/test-focused-test-harness.sh)
        zsh "$ROOT_DIR/$script"
        ;;
      *)
        bash "$ROOT_DIR/$script"
        ;;
    esac
  done
}

run_package_tests() {
  echo "==> AgentHarnessKit contracts"
  TIMEOUT_RUNNER_LABEL="AgentHarnessKit" \
    "$TIMEOUT_RUNNER" "$PACKAGE_TIMEOUT" "$LOG_DIR/agent-harness-package-tests.log" \
    swift test --package-path "$ROOT_DIR/Packages/AgentHarnessKit"
}

project_xcodebuild() {
  local timeout="$1"
  local log_path="$2"
  shift 2
  TIMEOUT_RUNNER_LABEL="NovaForge-$LANE" \
    "$TIMEOUT_RUNNER" "$timeout" "$log_path" \
    xcodebuild \
      -project "$PROJECT_PATH" \
      -scheme "$SCHEME" \
      -configuration "$CONFIGURATION" \
      -sdk iphonesimulator \
      -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
      -destination-timeout "$DESTINATION_TIMEOUT" \
      -derivedDataPath "$DERIVED_DATA_PATH" \
      -skipPackageUpdates \
      -skipPackagePluginValidation \
      -skipMacroValidation \
      ONLY_ACTIVE_ARCH=YES \
      CODE_SIGNING_ALLOWED=NO \
      "$@"
}

xctestrun_xcodebuild() {
  local timeout="$1"
  local log_path="$2"
  shift 2
  local -a result_bundle_args=()
  if [[ "$WRITE_RESULT_BUNDLE" == "1" ]]; then
    result_bundle_args=( -resultBundlePath "$RESULT_BUNDLE_PATH" )
  fi
  TIMEOUT_RUNNER_LABEL="NovaForge-$LANE" \
    "$TIMEOUT_RUNNER" "$timeout" "$log_path" \
    env \
      NOVAFORGE_CAPTURE_MODE="$NOVAFORGE_CAPTURE_MODE" \
      TEST_RUNNER_NOVAFORGE_CAPTURE_MODE="$NOVAFORGE_CAPTURE_MODE" \
      NOVAFORGE_SCREENSHOT_DIR="$NOVAFORGE_SCREENSHOT_DIR" \
      TEST_RUNNER_NOVAFORGE_SCREENSHOT_DIR="$NOVAFORGE_SCREENSHOT_DIR" \
    xcodebuild \
      -xctestrun "$XCTESTRUN_PATH" \
      -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
      -destination-timeout "$DESTINATION_TIMEOUT" \
      -parallel-testing-enabled NO \
      -maximum-concurrent-test-simulator-destinations 1 \
      "${result_bundle_args[@]}" \
      "$@"
}

discover_xctestrun() {
  local -a candidates=()
  if [[ -n "$XCTESTRUN_PATH" ]]; then
    [[ -f "$XCTESTRUN_PATH" ]] && print -r -- "$XCTESTRUN_PATH" && return 0
    return 1
  fi
  candidates=( "$DERIVED_DATA_PATH"/Build/Products/${SCHEME}_*.xctestrun(N.om[1]) )
  (( ${#candidates} > 0 )) || return 1
  print -r -- "$candidates[1]"
}

validate_xctestrun() {
  local plist=""
  plist="$(/usr/bin/plutil -convert xml1 -o - "$XCTESTRUN_PATH")"
  [[ "$plist" == *AgentPadTests* ]] || {
    echo "Test bundle is missing AgentPadTests: $XCTESTRUN_PATH" >&2
    return 2
  }
  [[ "$plist" == *AgentPadUITests* ]] || {
    echo "Test bundle is missing AgentPadUITests: $XCTESTRUN_PATH" >&2
    return 2
  }
}

boot_simulator() {
  echo "==> Simulator $SIMULATOR_ID"
  xcrun simctl boot "$SIMULATOR_ID" >/dev/null 2>&1 || true
  TIMEOUT_RUNNER_LABEL="simulator-boot" \
    "$TIMEOUT_RUNNER" "$SIM_BOOT_TIMEOUT" "$LOG_DIR/simulator-boot.log" \
    xcrun simctl bootstatus "$SIMULATOR_ID" -b
}

refresh_simulator() {
  local batch="$1"
  echo "==> Refreshing simulator before critical UI batch $batch"
  TIMEOUT_RUNNER_LABEL="simulator-refresh-shutdown" \
    "$TIMEOUT_RUNNER" 60 "$LOG_DIR/simulator-refresh-$batch-shutdown.log" \
    xcrun simctl shutdown "$SIMULATOR_ID"
  xcrun simctl boot "$SIMULATOR_ID" >/dev/null 2>&1 || true
  TIMEOUT_RUNNER_LABEL="simulator-refresh-boot" \
    "$TIMEOUT_RUNNER" "$SIM_BOOT_TIMEOUT" "$LOG_DIR/simulator-refresh-$batch-boot.log" \
    xcrun simctl bootstatus "$SIMULATOR_ID" -b
}

build_test_bundle() {
  if [[ "$BUILD_FOR_TESTING_FIRST" == "1" ]]; then
    echo "==> Incremental build-for-testing"
    project_xcodebuild "$BUILD_TIMEOUT" "$LOG_DIR/build-for-testing.log" build-for-testing
    XCTESTRUN_PATH="$(discover_xctestrun)" || {
      echo "No .xctestrun was produced under $DERIVED_DATA_PATH." >&2
      return 1
    }
  elif [[ -z "$XCTESTRUN_PATH" ]]; then
    XCTESTRUN_PATH="$(discover_xctestrun)" || {
      echo "BUILD_FOR_TESTING_FIRST=0 requires a reusable XCTESTRUN_PATH." >&2
      return 2
    }
  fi
  validate_xctestrun
  print -r -- "$XCTESTRUN_PATH" > "$LOG_DIR/xctestrun.path"
  echo "Using $XCTESTRUN_PATH"
}

run_xctest_selection() {
  local timeout="$1"
  local log_path="$2"
  local result_path="$3"
  shift 3
  local previous_result_path="$RESULT_BUNDLE_PATH"
  local selection_status=0

  if [[ "$WRITE_RESULT_BUNDLE" == "1" ]]; then
    RESULT_BUNDLE_PATH="$result_path"
    rm -rf -- "$RESULT_BUNDLE_PATH"
  fi
  xctestrun_xcodebuild "$timeout" "$log_path" "$@" || selection_status=$?
  RESULT_BUNDLE_PATH="$previous_result_path"
  return "$selection_status"
}

run_critical_lane() {
  if [[ "$UI_TEST_RESTART_INTERVAL" != <-> ]] || (( UI_TEST_RESTART_INTERVAL < 1 )); then
    echo "UI_TEST_RESTART_INTERVAL must be a positive integer." >&2
    return 2
  fi

  local result_prefix="${RESULT_BUNDLE_PATH%.xcresult}"
  echo "==> Running critical units in one fresh XCTest runner"
  run_xctest_selection \
    "$UNIT_TEST_TIMEOUT" \
    "$LOG_DIR/test-unit.log" \
    "$result_prefix-unit.xcresult" \
    test-without-building -only-testing:AgentPadTests

  local index=0
  local batch=1
  local ordinal=""
  local test_name=""
  refresh_simulator "$batch"
  for test_name in "${critical_ui_tests[@]}"; do
    (( index += 1 ))
    if (( index > 1 && (index - 1) % UI_TEST_RESTART_INTERVAL == 0 )); then
      (( batch += 1 ))
      refresh_simulator "$batch"
    fi
    printf -v ordinal '%02d' "$index"
    echo "==> Running critical UI journey $index/${#critical_ui_tests}: $test_name"
    run_xctest_selection \
      "$UI_TEST_TIMEOUT" \
      "$LOG_DIR/test-ui-$ordinal-$test_name.log" \
      "$result_prefix-ui-$ordinal-$test_name.xcresult" \
      test-without-building \
      "-only-testing:AgentPadUITests/AgentPadUITests/$test_name"
  done
}

run_lane() {
  local -a selectors=()
  local test_name=""
  case "$LANE" in
    unit)
      selectors+=( "-only-testing:AgentPadTests" )
      ;;
    smoke|visual)
      for test_name in "${ui_tests[@]}"; do
        selectors+=( "-only-testing:AgentPadUITests/AgentPadUITests/$test_name" )
      done
      ;;
    critical) ;;
    release)
      selectors+=( "-only-testing:AgentPadTests" "-only-testing:AgentPadUITests" )
      ;;
  esac

  [[ "$NOVAFORGE_CAPTURE_MODE" == "all" ]] && mkdir -p "$NOVAFORGE_SCREENSHOT_DIR"
  if [[ "$LANE" == "critical" ]]; then
    echo "==> Running critical lane (1 unit runner + ${#critical_ui_tests} isolated UI runners, capture=$NOVAFORGE_CAPTURE_MODE, xcresult=$WRITE_RESULT_BUNDLE)"
    run_critical_lane
    return
  fi

  echo "==> Running $LANE lane (${#selectors} selectors, capture=$NOVAFORGE_CAPTURE_MODE, xcresult=$WRITE_RESULT_BUNDLE)"
  run_xctest_selection \
    "$TEST_TIMEOUT" \
    "$LOG_DIR/test.log" \
    "$RESULT_BUNDLE_PATH" \
    test-without-building "${selectors[@]}"
}

acquire_derived_data_lock
prepare_derived_data
[[ "$NOVAFORGE_TEST_INCLUDE_PREFLIGHT" == "1" ]] && run_preflight
[[ "$NOVAFORGE_TEST_INCLUDE_PACKAGE" == "1" ]] && run_package_tests
build_test_bundle
boot_simulator
run_lane

echo "PASS: NovaForge $LANE lane"
echo "Logs: $LOG_DIR"
if [[ "$NOVAFORGE_CAPTURE_MODE" == "all" ]]; then
  echo "Screenshots: $NOVAFORGE_SCREENSHOT_DIR"
fi
