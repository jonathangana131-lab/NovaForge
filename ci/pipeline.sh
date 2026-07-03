#!/bin/bash
# NovaForge CI pipeline - runs on a macOS GitHub Actions runner.
# Builds the app for the iPhone simulator, restores the binary app icon if
# missing, walks every app surface via launch arguments, captures screenshots
# and a matrix-rain video, and force-pushes all captures to the `ci-shots`
# branch (fetchable as public raw URLs). Build logs are published even when
# the build fails.
set -euo pipefail

# Mirror EVERYTHING this script does into pipeline.log — the publish trap
# ships its tail to the ci-shots branch, so failures are always inspectable
# from outside without the Actions log API.
exec > >(tee -a pipeline.log) 2>&1

BUNDLE="com.joey.NovaForge"
ICON="AgentPad/App/Assets.xcassets/AppIcon.appiconset/icon_1024.png"
IMPORT_TARBALL_URL="https://pub.hyperagent.com/api/published/pbf01KWKBBTZB_0ZV3WMJ212R4ZGSN/novaforge-import.tar.gz"
APP_PATH="DerivedData/Build/Products/Release-iphonesimulator/NovaForge.app"

# ---------------------------------------------------------------------------
# Always publish whatever we captured (screenshots, video, build log tail),
# even if an earlier step failed. Uses the credentials persisted by
# actions/checkout.
# ---------------------------------------------------------------------------
publish_captures() {
  set +e
  set +x
  echo "==> Publishing captures to ci-shots branch"
  mkdir -p captures
  [ -f build.log ] && tail -300 build.log > captures/build-log-tail.txt
  [ -f pipeline.log ] && tail -400 pipeline.log > captures/pipeline-log-tail.txt
  if [ -z "$(ls -A captures)" ]; then
    echo "nothing to publish"
    return 0
  fi
  AUTH_HEADER=$(git config --get http.https://github.com/.extraheader)
  REPO_DIR=$(pwd)
  cd captures
  git init -q -b ci-shots
  git config user.name "github-actions[bot]"
  git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
  git add -A
  git commit -q -m "CI captures: run ${GITHUB_RUN_NUMBER:-local} (${GITHUB_SHA:-unknown})"
  git -c "http.https://github.com/.extraheader=$AUTH_HEADER" \
    push --force "https://github.com/${GITHUB_REPOSITORY}.git" ci-shots
  cd "$REPO_DIR"
  echo "captures published"
}
trap publish_captures EXIT

# Trace every command from here on (captured into pipeline.log).
set -x

# ---------------------------------------------------------------------------
echo "==> Selecting newest Xcode"
NEWEST=$(ls -d /Applications/Xcode*.app | sort -V | tail -1)
sudo xcode-select -s "$NEWEST/Contents/Developer"
xcodebuild -version

# ---------------------------------------------------------------------------
echo "==> Ensuring binary app icon"
if [ ! -f "$ICON" ]; then
  echo "icon missing - restoring from import archive"
  curl -fsSL "$IMPORT_TARBALL_URL" -o /tmp/novaforge-import.tar.gz
  mkdir -p /tmp/novaforge-import
  tar -xzf /tmp/novaforge-import.tar.gz -C /tmp/novaforge-import
  cp "/tmp/novaforge-import/$ICON" "$ICON"
  git config user.name "github-actions[bot]"
  git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
  git add "$ICON"
  git commit -m "chore: restore binary app icon from import archive [skip ci]"
  git push origin "HEAD:${GITHUB_REF_NAME:-main}" || echo "WARN: icon push failed, continuing with local copy"
fi

# ---------------------------------------------------------------------------
echo "==> Building NovaForge (Release, iPhone simulator)"
set -o pipefail
xcodebuild \
  -project AgentPad.xcodeproj \
  -scheme AgentPad \
  -configuration Release \
  -destination "generic/platform=iOS Simulator" \
  -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build 2>&1 | tee build.log | tail -40

# ---------------------------------------------------------------------------
echo "==> Selecting a simulator"
# Prefer a pre-provisioned iPhone simulator from the runner image — these are
# guaranteed-valid (device type + runtime pairing already exists). Fall back
# to creating one only if none exist.
UDID=$(xcrun simctl list -j devices available | jq -r '[.devices | to_entries[] | select(.key | contains("iOS")) | .value[] | select(.isAvailable == true and (.name | startswith("iPhone")))] | last | .udid // empty')
if [ -z "$UDID" ]; then
  echo "no pre-provisioned iPhone simulator; creating one"
  DEVICE_TYPE=$(xcrun simctl list -j devicetypes | jq -r '[.devicetypes[] | select(.productFamily == "iPhone")] | last | .identifier')
  UDID=$(xcrun simctl create "NovaCI" "$DEVICE_TYPE")
fi
xcrun simctl list devices | grep -i "$UDID" || true
xcrun simctl bootstatus "$UDID" -b
echo "simulator ready: $UDID"

echo "==> Installing app"
ls -la "$APP_PATH"
xcrun simctl install "$UDID" "$APP_PATH"

# ---------------------------------------------------------------------------
echo "==> Screenshot tour (full surface census)"
# Let SpringBoard settle so first-boot system banners (Apple Intelligence
# onboarding etc.) clear before we start photographing.
sleep 15
mkdir -p captures
# shot <name> [WAIT=n] [launch args...] — every stateful capture passes
# --reset-ui so fixtures from earlier shots never contaminate later ones.
shot() {
  NAME="$1"; shift
  WAIT=9
  if [[ "${1:-}" == WAIT=* ]]; then WAIT="${1#WAIT=}"; shift; fi
  xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
  sleep 1
  xcrun simctl launch "$UDID" "$BUNDLE" "$@"
  sleep "$WAIT"
  xcrun simctl io "$UDID" screenshot "captures/$NAME.png"
  echo "captured $NAME"
}

# --- Core tabs, clean state ------------------------------------------------
shot "01-first-run" --reset-ui --first-run-local-model-missing
shot "02-project" --open-project
shot "03-files" --open-files
shot "04-chat-welcome" --open-chat --settings-local-model-ready
shot "05-runs" --open-runs
shot "06-settings" --open-settings
shot "07-terminal" --open-terminal

# --- Chat depth: streaming, tools, code, failure, approval, keyboard --------
shot "08-chat-stream" --reset-ui --open-chat --stress-streaming
shot "09-chat-tools" --reset-ui --open-chat --running-tool-call-demo
shot "10-chat-code" --reset-ui --open-chat --code-block-demo
shot "11-chat-failed" --reset-ui --open-chat --failed-tool-call-demo
shot "12-chat-approval" --reset-ui --open-chat --pending-approval-demo
shot "13-chat-keyboard" WAIT=11 --reset-ui --open-chat --keyboard-focus-demo

# --- Project journey states -------------------------------------------------
shot "14-project-running" --reset-ui --open-project --project-running-demo
shot "15-project-blocked" --reset-ui --open-project --project-blocked-demo
shot "16-project-waiting" --reset-ui --open-project --project-waiting-demo
shot "17-project-proof" --reset-ui --open-project --project-proof-demo
shot "18-project-countdown" --reset-ui --open-project --auto-continue-countdown-demo

# --- Runs / terminal / artifact depth ----------------------------------------
shot "19-runs-approval" --reset-ui --open-runs --pending-approval-demo
shot "20-runs-populated" --reset-ui --open-runs --project-proof-demo
shot "21-terminal-live" --reset-ui --open-terminal --terminal-live-record-demo
shot "22-artifact-preview" WAIT=14 --reset-ui --open-files --project-proof-demo --workbench-open-artifact-preview

# --- Files / settings depth ---------------------------------------------------
shot "23-files-stress" --reset-ui --open-files --stress-files
shot "24-settings-model-ready" --reset-ui --open-settings --settings-local-model-ready
shot "25-settings-model-partial" --reset-ui --open-settings --settings-local-model-partial

# --- Theme deep pass (populated where it matters) ----------------------------
shot "26-matrix-project" --reset-ui --open-project --theme=matrix --project-proof-demo
shot "27-matrix-chat" --reset-ui --open-chat --theme=matrix --stress-streaming
shot "28-matrix-settings" --reset-ui --open-settings --theme=matrix
shot "29-whitegold-project" --reset-ui --open-project --theme=whitegold --project-proof-demo
shot "30-whitegold-chat" --reset-ui --open-chat --theme=whitegold --stress-streaming
shot "31-arctic-project" --reset-ui --open-project --theme=arctic --project-proof-demo
shot "32-arctic-files" --reset-ui --open-files --theme=arctic
shot "33-ember-project" --reset-ui --open-project --theme=ember --project-proof-demo
shot "34-ember-runs" --reset-ui --open-runs --theme=ember --project-proof-demo

# ---------------------------------------------------------------------------
record_clip() {
  NAME="$1"; SETTLE="$2"; DURATION="$3"; shift 3
  echo "==> Recording $NAME (${DURATION}s)"
  xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
  sleep 1
  xcrun simctl launch "$UDID" "$BUNDLE" "$@"
  sleep "$SETTLE"
  xcrun simctl io "$UDID" recordVideo --codec h264 --force "captures/$NAME.mp4" &
  REC_PID=$!
  sleep "$DURATION"
  kill -INT "$REC_PID"
  sleep 3
  wait "$REC_PID" || true
}
record_clip "matrix-rain" 6 10 --reset-ui --open-project --theme=matrix
record_clip "chat-stream" 4 8 --reset-ui --open-chat --stress-streaming
ls -la captures/

echo "==> Pipeline complete"
