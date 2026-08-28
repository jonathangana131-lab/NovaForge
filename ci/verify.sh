#!/bin/bash
# Pull-request verification entry point. Critical is the default; the same
# build-once runner supports NOVAFORGE_TEST_LANE=release for scheduled/manual
# exhaustive UI coverage.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT_DIR"

TEST_LANE="${NOVAFORGE_TEST_LANE:-critical}"
RUN_ID="${GITHUB_RUN_ID:-local-$(date +%Y%m%d-%H%M%S)-$$}"
RUN_ID="$(printf '%s' "$RUN_ID" | tr -cd '[:alnum:]_.-')"
[ -n "$RUN_ID" ] || { echo "Could not derive a safe CI run identity" >&2; exit 2; }
ARTIFACT_DIR="$ROOT_DIR/artifacts/verify-$TEST_LANE/run-$RUN_ID"
DERIVED_DATA="$ROOT_DIR/DerivedData/CI-$TEST_LANE/run-$RUN_ID"
XCODEBUILD_CAP_MINUTES="${XCODEBUILD_CAP_MINUTES:-40}"
TIMEOUT_RUNNER="$ROOT_DIR/scripts/codex-timeout-runner.pl"
SIMULATOR_ID=""
CREATED_SIMULATOR=0

mkdir -p "$ARTIFACT_DIR"

cleanup() {
  local exit_status=$?
  if [[ "$SIMULATOR_ID" =~ ^[0-9A-Fa-f-]{36}$ ]]; then
    "$ROOT_DIR/scripts/codex-ci-cleanup.sh" "$SIMULATOR_ID" "$CREATED_SIMULATOR" "$ARTIFACT_DIR" || {
      echo "CI cleanup/process sweep failed." >&2
      (( exit_status == 0 )) && exit_status=1
    }
  fi
  "$ROOT_DIR/scripts/codex-ci-evidence-manifest.sh" "$ARTIFACT_DIR" "$TEST_LANE" \
    "$([[ "$exit_status" -eq 0 ]] && echo pass || echo fail)" "$DERIVED_DATA" || {
    echo "Could not write the CI evidence manifest." >&2
    exit_status=1
  }
  exit "$exit_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ ! "$XCODEBUILD_CAP_MINUTES" =~ ^[1-9][0-9]*$ ]]; then
  echo "XCODEBUILD_CAP_MINUTES must be a positive integer." >&2
  exit 2
fi

run_bounded() {
  local seconds="$1"
  local log_path="$2"
  shift 2
  TIMEOUT_RUNNER_LABEL="ci-${TEST_LANE}" \
    "$TIMEOUT_RUNNER" "$seconds" "$log_path" "$@"
}

echo "==> Selecting newest Xcode"
NEWEST_XCODE=$(find /Applications -maxdepth 1 -type d -name 'Xcode*.app' -print | sort -V | tail -1)
if [ -z "$NEWEST_XCODE" ]; then
  echo "No Xcode installation found under /Applications" >&2
  exit 69
fi
run_bounded 60 "$ARTIFACT_DIR/xcode-select.log" sudo -n xcode-select -s "$NEWEST_XCODE/Contents/Developer"
run_bounded 60 "$ARTIFACT_DIR/xcode-version.log" xcodebuild -version
cat "$ARTIFACT_DIR/xcode-version.log"

echo "==> Selecting one available iPhone simulator"
run_bounded 60 "$ARTIFACT_DIR/simctl-list.log" xcrun simctl list -j devices available
UDID=$(jq -r '
  [.devices
    | to_entries[]
    | select(.key | contains("iOS"))
    | .value[]
    | select(.isAvailable == true and (.name | startswith("iPhone")))]
  | last
  | .udid // empty
' "$ARTIFACT_DIR/simctl-list.log")
if [ -z "$UDID" ]; then
  run_bounded 60 "$ARTIFACT_DIR/simctl-devicetypes.log" xcrun simctl list -j devicetypes
  DEVICE_TYPE=$(jq -r '[.devicetypes[] | select(.productFamily == "iPhone")] | last | .identifier // empty' \
    "$ARTIFACT_DIR/simctl-devicetypes.log")
  [ -n "$DEVICE_TYPE" ] || { echo "No compatible iPhone simulator type" >&2; exit 69; }
  run_bounded 60 "$ARTIFACT_DIR/simctl-create.log" xcrun simctl create "NovaForge CI $RUN_ID" "$DEVICE_TYPE"
  UDID=$(tr -d '[:space:]' < "$ARTIFACT_DIR/simctl-create.log")
  CREATED_SIMULATOR=1
fi
[[ "$UDID" =~ ^[0-9A-Fa-f-]{36}$ ]] || { echo "Simulator selection returned an invalid UDID" >&2; exit 69; }
SIMULATOR_ID="$UDID"

echo "==> Running NovaForge $TEST_LANE lane"
SIMULATOR_ID="$UDID" \
DERIVED_DATA_PATH="$DERIVED_DATA" \
LOG_DIR="$ARTIFACT_DIR" \
RESULT_BUNDLE_PATH="$ARTIFACT_DIR/$TEST_LANE.xcresult" \
TEST_TIMEOUT="$((XCODEBUILD_CAP_MINUTES * 60))" \
SHUTDOWN_SIMULATOR_AFTER_TESTS=1 \
zsh scripts/codex-test.sh "$TEST_LANE"

echo "==> NovaForge $TEST_LANE verification passed"
