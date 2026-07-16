#!/bin/bash
# Visual-census lane. Unlike the retired hand-authored 46-shot script, this
# uses synchronized XCTest journeys, builds once, and publishes only the
# representative screenshots produced by those assertions.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT_DIR"

CAPTURE_DIR="$ROOT_DIR/captures"
LOG_DIR="$ROOT_DIR/artifacts/visual"
DERIVED_DATA="$ROOT_DIR/DerivedData/CI-Visual"
rm -rf "$CAPTURE_DIR" "$LOG_DIR" "$DERIVED_DATA"
mkdir -p "$CAPTURE_DIR" "$LOG_DIR"

publish_captures() {
  set +e
  echo "==> Publishing visual proof to ci-shots"
  [ -f "$LOG_DIR/test.log" ] && tail -400 "$LOG_DIR/test.log" > "$CAPTURE_DIR/test-log-tail.txt"
  if [ -z "$(ls -A "$CAPTURE_DIR")" ]; then
    echo "nothing to publish"
    return 0
  fi
  AUTH_HEADER=$(git config --get http.https://github.com/.extraheader)
  REPO_DIR=$(pwd)
  cd "$CAPTURE_DIR"
  git init -q -b ci-shots
  git config user.name "github-actions[bot]"
  git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
  git add -A
  git commit -q -m "CI visual proof: run ${GITHUB_RUN_NUMBER:-local} (${GITHUB_SHA:-unknown})"
  git -c "http.https://github.com/.extraheader=$AUTH_HEADER" \
    push --force "https://github.com/${GITHUB_REPOSITORY}.git" ci-shots
  cd "$REPO_DIR"
}
trap publish_captures EXIT

echo "==> Selecting newest Xcode"
NEWEST_XCODE=$(find /Applications -maxdepth 1 -type d -name 'Xcode*.app' -print | sort -V | tail -1)
[ -n "$NEWEST_XCODE" ] || { echo "No Xcode installation found" >&2; exit 69; }
sudo xcode-select -s "$NEWEST_XCODE/Contents/Developer"

UDID=$(xcrun simctl list -j devices available | jq -r \
  '[.devices | to_entries[] | select(.key | contains("iOS")) | .value[] | select(.isAvailable == true and (.name | startswith("iPhone")))] | last | .udid // empty')
if [ -z "$UDID" ]; then
  DEVICE_TYPE=$(xcrun simctl list -j devicetypes | jq -r \
    '[.devicetypes[] | select(.productFamily == "iPhone")] | last | .identifier // empty')
  UDID=$(xcrun simctl create "NovaForge Visual CI" "$DEVICE_TYPE")
fi

echo "==> Running synchronized visual lane"
SIMULATOR_ID="$UDID" \
DERIVED_DATA_PATH="$DERIVED_DATA" \
LOG_DIR="$LOG_DIR" \
NOVAFORGE_CAPTURE_MODE=all \
NOVAFORGE_SCREENSHOT_DIR="$CAPTURE_DIR" \
TEST_TIMEOUT=3600 \
SHUTDOWN_SIMULATOR_AFTER_TESTS=1 \
zsh scripts/codex-test.sh visual

echo "==> Visual census passed"
