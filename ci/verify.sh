#!/bin/bash
# Pull-request verification entry point. Critical is the default; the same
# build-once runner supports NOVAFORGE_TEST_LANE=release for scheduled/manual
# exhaustive UI coverage.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT_DIR"

TEST_LANE="${NOVAFORGE_TEST_LANE:-critical}"
ARTIFACT_DIR="artifacts/verify-$TEST_LANE"
DERIVED_DATA="DerivedData/CI-$TEST_LANE"
XCODEBUILD_CAP_MINUTES="${XCODEBUILD_CAP_MINUTES:-40}"

rm -rf "$ARTIFACT_DIR" "$DERIVED_DATA"
mkdir -p "$ARTIFACT_DIR"

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
  DEVICE_TYPE=$(xcrun simctl list -j devicetypes | jq -r \
    '[.devicetypes[] | select(.productFamily == "iPhone")] | last | .identifier // empty')
  [ -n "$DEVICE_TYPE" ] || { echo "No compatible iPhone simulator type" >&2; exit 69; }
  UDID=$(xcrun simctl create "NovaForge CI" "$DEVICE_TYPE")
fi

echo "==> Running NovaForge $TEST_LANE lane"
SIMULATOR_ID="$UDID" \
DERIVED_DATA_PATH="$DERIVED_DATA" \
LOG_DIR="$ARTIFACT_DIR" \
RESULT_BUNDLE_PATH="$ARTIFACT_DIR/$TEST_LANE.xcresult" \
TEST_TIMEOUT="$((XCODEBUILD_CAP_MINUTES * 60))" \
SHUTDOWN_SIMULATOR_AFTER_TESTS=1 \
zsh scripts/codex-test.sh "$TEST_LANE"

echo "==> NovaForge $TEST_LANE verification passed"
