#!/usr/bin/env bash
set -euo pipefail

SIM_ID="${SIM_ID:-4B9AB34A-404C-485F-B0BC-964F24D0AE83}"
CONFIGURATION="${CONFIGURATION:-Debug}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="${RUN_DIR:-QA/ai-streaming-video-proof-${TIMESTAMP}}"
MEDIA_DIR="${MEDIA_DIR:-NovaForgeScreenshots/ai-streaming-video-proof-${TIMESTAMP}}"
BUNDLE_ID="${BUNDLE_ID:-com.joey.NovaForge}"
BUILD_FIRST="${BUILD_FIRST:-1}"
RECORD_SECONDS="${RECORD_SECONDS:-10}"
MIN_VIDEO_BYTES="${MIN_VIDEO_BYTES:-500000}"
MIN_SCREENSHOT_BYTES="${MIN_SCREENSHOT_BYTES:-120000}"
SHUTDOWN_SIMULATOR_AFTER_PROOF="${SHUTDOWN_SIMULATOR_AFTER_PROOF:-1}"

mkdir -p "$RUN_DIR" "$MEDIA_DIR"
printf '%s\n' "$RUN_DIR" > QA/latest-ai-streaming-video-proof-dir.txt
printf '%s\n' "$MEDIA_DIR" > QA/latest-ai-streaming-video-proof-media.txt

APP_PATH="${APP_PATH:-}"
VIDEO_PATH="$MEDIA_DIR/ai-response-stage-live.mp4"
MID_SCREENSHOT="$MEDIA_DIR/ai-response-stage-mid.png"
FINAL_SCREENSHOT="$MEDIA_DIR/ai-response-stage-final.png"
CONTACT_SHEET="$MEDIA_DIR/ai-response-stage-contact-sheet.jpg"
STDOUT_LOG="$RUN_DIR/app-stdout.log"
STDERR_LOG="$RUN_DIR/app-stderr.log"
LAUNCH_LOG="$RUN_DIR/launch.log"
INSTALL_LOG="$RUN_DIR/install.log"
BUILD_LOG="$RUN_DIR/xcodebuild-build.log"
DERIVED_DATA="$RUN_DIR/DerivedData"

cleanup() {
  if [[ -n "${RECORDER_PID:-}" ]] && kill -0 "$RECORDER_PID" >/dev/null 2>&1; then
    kill -INT "$RECORDER_PID" >/dev/null 2>&1 || true
    wait "$RECORDER_PID" >/dev/null 2>&1 || true
  fi
  xcrun simctl terminate "$SIM_ID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  if [[ "$SHUTDOWN_SIMULATOR_AFTER_PROOF" == "1" ]]; then
    xcrun simctl shutdown "$SIM_ID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if [[ "$BUILD_FIRST" == "1" ]]; then
  rm -rf "$DERIVED_DATA"
  scripts/codex-timeout-runner.pl 900 "$BUILD_LOG" \
    xcodebuild \
      -project AgentPad.xcodeproj \
      -scheme AgentPad \
      -configuration "$CONFIGURATION" \
      -sdk iphonesimulator \
      -destination "platform=iOS Simulator,id=${SIM_ID}" \
      -derivedDataPath "$DERIVED_DATA" \
      -skipPackageUpdates \
      -skipPackagePluginValidation \
      -skipMacroValidation \
      ONLY_ACTIVE_ARCH=YES \
      CODE_SIGNING_ALLOWED=NO \
      build
  APP_PATH="$DERIVED_DATA/Build/Products/${CONFIGURATION}-iphonesimulator/NovaForge.app"
fi

if [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
  echo "No built NovaForge.app found. Set APP_PATH or run with BUILD_FIRST=1." >&2
  exit 1
fi

xcrun simctl boot "$SIM_ID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$SIM_ID" -b
xcrun simctl terminate "$SIM_ID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl uninstall "$SIM_ID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl install "$SIM_ID" "$APP_PATH" >"$INSTALL_LOG" 2>&1
# SpringBoard can deny an immediate launch right after install on a freshly booted
# simulator. Give the service delegate a short settle window before recording.
sleep "${POST_INSTALL_SETTLE_SECONDS:-3}"

rm -f "$VIDEO_PATH" "$MID_SCREENSHOT" "$FINAL_SCREENSHOT" "$CONTACT_SHEET"

xcrun simctl launch \
  --terminate-running-process \
  "$SIM_ID" \
  "$BUNDLE_ID" \
  --reset-ui \
  --open-chat \
  --stress-streaming \
  --new-ai-streaming-stage-demo >"$LAUNCH_LOG" 2>&1

# Start recording after a verified launch; this avoids SBMainWorkspace launch
# denials seen when ScreenCapture starts first on a freshly booted simulator.
sleep "${POST_LAUNCH_SETTLE_SECONDS:-1}"
xcrun simctl io "$SIM_ID" recordVideo --codec=h264 "$VIDEO_PATH" >/dev/null 2>&1 &
RECORDER_PID=$!
sleep 1

sleep 4
xcrun simctl io "$SIM_ID" screenshot "$MID_SCREENSHOT" >/dev/null
sleep "$RECORD_SECONDS"
xcrun simctl io "$SIM_ID" screenshot "$FINAL_SCREENSHOT" >/dev/null
kill -INT "$RECORDER_PID" >/dev/null 2>&1 || true
wait "$RECORDER_PID" >/dev/null 2>&1 || true
RECORDER_PID=""

video_bytes=$(wc -c < "$VIDEO_PATH" | tr -d '[:space:]')
mid_bytes=$(wc -c < "$MID_SCREENSHOT" | tr -d '[:space:]')
final_bytes=$(wc -c < "$FINAL_SCREENSHOT" | tr -d '[:space:]')

if (( video_bytes < MIN_VIDEO_BYTES )); then
  echo "Video proof too small (${video_bytes}B < ${MIN_VIDEO_BYTES}B): $VIDEO_PATH" >&2
  exit 1
fi
if (( mid_bytes < MIN_SCREENSHOT_BYTES )); then
  echo "Mid screenshot too small (${mid_bytes}B < ${MIN_SCREENSHOT_BYTES}B): $MID_SCREENSHOT" >&2
  exit 1
fi
if (( final_bytes < MIN_SCREENSHOT_BYTES )); then
  echo "Final screenshot too small (${final_bytes}B < ${MIN_SCREENSHOT_BYTES}B): $FINAL_SCREENSHOT" >&2
  exit 1
fi

if command -v ffmpeg >/dev/null 2>&1; then
  if ! ffmpeg -v error -i "$VIDEO_PATH" -f null - >"$RUN_DIR/video-validate.log" 2>&1; then
    echo "Video proof is not readable by ffmpeg: $VIDEO_PATH" >&2
    cat "$RUN_DIR/video-validate.log" >&2
    exit 1
  fi
  ffmpeg -y -hide_banner -loglevel error \
    -i "$VIDEO_PATH" \
    -vf "fps=1/${RECORD_SECONDS},scale=390:-1,tile=4x1:padding=16:margin=16:color=0x111318" \
    -frames:v 1 "$CONTACT_SHEET"
fi

cat > "$RUN_DIR/manifest.txt" <<EOF
AI response stage video proof passed
App: $APP_PATH
Video: $VIDEO_PATH (${video_bytes} bytes)
Mid screenshot: $MID_SCREENSHOT (${mid_bytes} bytes)
Final screenshot: $FINAL_SCREENSHOT (${final_bytes} bytes)
Contact sheet: $CONTACT_SHEET
Launch args: --reset-ui --open-chat --stress-streaming --new-ai-streaming-stage-demo
EOF

cat "$RUN_DIR/manifest.txt"
