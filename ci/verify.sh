#!/bin/bash
# Fast, bounded pull-request gate for NovaForge. One xcodebuild invocation
# runs the unit bundle plus one deterministic Forge streaming UI journey, so
# UI-test sources compile and the message path is exercised on a real process.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT_DIR"

ARTIFACT_DIR="artifacts/verify"
DERIVED_DATA="DerivedData/CI-Verify"
BUILD_LOG="$ARTIFACT_DIR/build.log"
RESULT_BUNDLE="$ARTIFACT_DIR/AgentPadTests.xcresult"
XCODEBUILD_CAP_MINUTES="${XCODEBUILD_CAP_MINUTES:-30}"
BOOT_CAP_MINUTES="${BOOT_CAP_MINUTES:-5}"

rm -rf "$ARTIFACT_DIR" "$DERIVED_DATA"
mkdir -p "$ARTIFACT_DIR"

# macOS does not ship GNU timeout. This wrapper emits a heartbeat and stops the
# command tree when its cap elapses so a wedged simulator cannot consume the
# entire Actions job timeout.
run_capped() {
  local cap_minutes="$1"
  local label="$2"
  shift 2

  local marker
  marker=$(mktemp -t "novaforge-${label}.XXXXXX")
  rm -f "$marker"

  "$@" &
  local command_pid=$!

  (
    local waited=0
    local cap_seconds=$((cap_minutes * 60))
    while kill -0 "$command_pid" 2>/dev/null && [ "$waited" -lt "$cap_seconds" ]; do
      sleep 30
      waited=$((waited + 30))
      echo "HEARTBEAT ${label}: ${waited}s elapsed (cap ${cap_seconds}s)"
    done

    if kill -0 "$command_pid" 2>/dev/null; then
      echo "WATCHDOG: ${label} exceeded ${cap_minutes}m; stopping it"
      : > "$marker"
      pkill -TERM -P "$command_pid" 2>/dev/null || true
      kill -TERM "$command_pid" 2>/dev/null || true
      sleep 5
      pkill -KILL -P "$command_pid" 2>/dev/null || true
      kill -KILL "$command_pid" 2>/dev/null || true
    fi
  ) &
  local watchdog_pid=$!

  local status=0
  wait "$command_pid" || status=$?
  kill "$watchdog_pid" 2>/dev/null || true
  wait "$watchdog_pid" 2>/dev/null || true

  if [ -f "$marker" ]; then
    status=124
  fi
  rm -f "$marker"
  echo "${label} finished with status ${status}"
  return "$status"
}

echo "==> Selecting newest Xcode"
NEWEST_XCODE=$(find /Applications -maxdepth 1 -type d -name 'Xcode*.app' -print | sort -V | tail -1)
if [ -z "$NEWEST_XCODE" ]; then
  echo "No Xcode installation found under /Applications" >&2
  exit 69
fi
sudo xcode-select -s "$NEWEST_XCODE/Contents/Developer"
xcodebuild -version

echo "==> Selecting one available iPhone simulator"
UDID=$(xcrun simctl list -j devices available | jq -r '
  [.devices
    | to_entries[]
    | select(.key | contains("iOS"))
    | .value[]
    | select(.isAvailable == true and (.name | startswith("iPhone")))]
  | last
  | .udid // empty
')

if [ -z "$UDID" ]; then
  echo "No pre-provisioned iPhone simulator; creating one"
  DEVICE_TYPE=$(xcrun simctl list -j devicetypes | jq -r '
    [.devicetypes[] | select(.productFamily == "iPhone")]
    | last
    | .identifier // empty
  ')
  if [ -z "$DEVICE_TYPE" ]; then
    echo "No compatible iPhone simulator device type found" >&2
    exit 69
  fi
  UDID=$(xcrun simctl create "NovaForge CI" "$DEVICE_TYPE")
fi

BOOTED_HERE=0
SIMULATOR_STATE=$(xcrun simctl list -j devices | jq -r --arg udid "$UDID" '
  [.devices[][] | select(.udid == $udid)] | first | .state // "Unknown"
')
if [ "$SIMULATOR_STATE" != "Booted" ]; then
  xcrun simctl boot "$UDID" 2>/dev/null || true
  BOOTED_HERE=1
fi

cleanup() {
  if [ "$BOOTED_HERE" -eq 1 ]; then
    xcrun simctl shutdown "$UDID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

if ! run_capped "$BOOT_CAP_MINUTES" "simulator-boot" xcrun simctl bootstatus "$UDID" -b; then
  echo "Simulator boot failed or timed out" >&2
  exit 66
fi

echo "==> Building NovaForge and running AgentPadTests"
run_unit_tests() {
  xcodebuild \
    -project AgentPad.xcodeproj \
    -scheme AgentPad \
    -configuration Debug \
    -sdk iphonesimulator \
    -destination "platform=iOS Simulator,id=$UDID" \
    -derivedDataPath "$DERIVED_DATA" \
    -resultBundlePath "$RESULT_BUNDLE" \
    -parallel-testing-enabled NO \
    -maximum-concurrent-test-simulator-destinations 1 \
    -only-testing:AgentPadTests \
    -only-testing:AgentPadUITests/AgentPadUITests/testForgeChatSendStreamsOneAssistantBubbleAndClearsRunningState \
    CODE_SIGNING_ALLOWED=NO \
    test > "$BUILD_LOG" 2>&1
}

STATUS=0
run_capped "$XCODEBUILD_CAP_MINUTES" "AgentPadTests" run_unit_tests || STATUS=$?

if [ "$STATUS" -ne 0 ]; then
  echo "AgentPadTests failed or timed out (status $STATUS)"
  echo "==> Last 120 build-log lines"
  tail -120 "$BUILD_LOG" || true
  exit "$STATUS"
fi

tail -40 "$BUILD_LOG"
echo "==> AgentPadTests passed"
