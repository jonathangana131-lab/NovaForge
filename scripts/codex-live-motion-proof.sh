#!/usr/bin/env bash
set -euo pipefail

SIM_ID="${SIM_ID:-4B9AB34A-404C-485F-B0BC-964F24D0AE83}"
CONFIGURATION="${CONFIGURATION:-Debug}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="${RUN_DIR:-QA/live-motion-proof-${TIMESTAMP}}"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-NovaForgeScreenshots/live-motion-proof-${TIMESTAMP}}"
SHUTDOWN_SIMULATOR_AFTER_PROOF="${SHUTDOWN_SIMULATOR_AFTER_PROOF:-1}"

mkdir -p "$RUN_DIR" "$SCREENSHOT_DIR"
printf '%s\n' "$RUN_DIR" > QA/latest-live-motion-proof-dir.txt
printf '%s\n' "$SCREENSHOT_DIR" > QA/latest-live-motion-proof-screenshots.txt

cleanup() {
  if [[ "$SHUTDOWN_SIMULATOR_AFTER_PROOF" == "1" ]]; then
    xcrun simctl terminate "$SIM_ID" com.joey.NovaForge >/dev/null 2>&1 || true
    xcrun simctl shutdown "$SIM_ID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

xcrun simctl terminate "$SIM_ID" com.joey.NovaForge >/dev/null 2>&1 || true
xcrun simctl boot "$SIM_ID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$SIM_ID" -b

export NOVAFORGE_SCREENSHOT_DIR="$PWD/$SCREENSHOT_DIR"
export TEST_RUNNER_NOVAFORGE_SCREENSHOT_DIR="$PWD/$SCREENSHOT_DIR"

LOG="$RUN_DIR/xcodebuild-live-motion-proof.log"
RESULT="$RUN_DIR/live-motion-proof.xcresult"
rm -rf "$RESULT"

scripts/codex-timeout-runner.pl 900 "$LOG" \
  xcodebuild \
    -project AgentPad.xcodeproj \
    -scheme AgentPad \
    -configuration "$CONFIGURATION" \
    -sdk iphonesimulator \
    -destination "platform=iOS Simulator,id=${SIM_ID}" \
    -derivedDataPath "$RUN_DIR/DerivedData" \
    -resultBundlePath "$RESULT" \
    -skipPackageUpdates \
    -skipPackagePluginValidation \
    -skipMacroValidation \
    ONLY_ACTIVE_ARCH=YES \
    CODE_SIGNING_ALLOWED=NO \
    test \
    -only-testing:AgentPadUITests/AgentPadUITests/testStreamingKeepsBottomPinnedDuringLiveResponse \
    -only-testing:AgentPadUITests/AgentPadUITests/testChatLayoutContractKeepsStreamingReadableWithFocusedComposer

printf '\nLive motion proof screenshots:\n'
find "$SCREENSHOT_DIR" -maxdepth 1 -type f -name '*.png' -print | sort | tee "$RUN_DIR/screenshots.txt"

required=(
  "NovaForge-iPhone12-Clean-23-streaming-bottom-pinned.png"
  "NovaForge-iPhone12-Clean-29-chat-layout-contract-keyboard-streaming.png"
  "NovaForge-iPhone12-Clean-31-liquid-motion-mid-reveal.png"
  "NovaForge-iPhone12-Clean-32-liquid-motion-settled-reveal.png"
)
for file in "${required[@]}"; do
  if [[ ! -s "$SCREENSHOT_DIR/$file" ]]; then
    echo "Missing required proof screenshot: $SCREENSHOT_DIR/$file" >&2
    exit 1
  fi
done

echo "Live motion proof passed"
echo "Proof dir: $RUN_DIR"
echo "Screenshots: $SCREENSHOT_DIR"
