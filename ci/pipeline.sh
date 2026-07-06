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
# Facelift arc-reactor icon (binary assets can't ride the text-only git
# bridge, so the build fetches it — same trust path as the import tarball).
FACELIFT_ICON_URL="https://pub.hyperagent.com/api/published/pbf01KWNCR2ZQ_1N7M4RF7JH7D9EVH/icon_new.png"
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

echo "==> Applying facelift app icon"
if curl -fsSL "$FACELIFT_ICON_URL" -o /tmp/facelift-icon.png && [ -s /tmp/facelift-icon.png ]; then
  cp /tmp/facelift-icon.png "$ICON"
  echo "facelift icon applied ($(wc -c < "$ICON") bytes)"
else
  echo "WARN: facelift icon fetch failed — building with repo icon"
fi

# ---------------------------------------------------------------------------
# Watchdog: runs 30/31 sat in_progress for 36-45+ min against a 15-24 min
# historical envelope, with no captures and no logs (the EXIT trap only fires
# if the job ends cleanly — a 90-min runner timeout may SIGKILL past it).
# Every potentially-unbounded step now runs under a hard cap so a wedge
# becomes a failed-but-diagnosable run: build.log / pipeline.log always
# publish, and heartbeats show where time actually went.
run_capped() {
  # run_capped <minutes> <label> <cmd...>  — kills the command tree if the
  # cap elapses; returns the command's status (124 on timeout).
  local CAP_MIN="$1"; shift
  local LABEL="$1"; shift
  "$@" &
  local CMD_PID=$!
  (
    local waited=0
    while kill -0 "$CMD_PID" 2>/dev/null && [ "$waited" -lt $((CAP_MIN * 60)) ]; do
      sleep 30
      waited=$((waited + 30))
      echo "HEARTBEAT ${LABEL}: ${waited}s elapsed (cap $((CAP_MIN * 60))s) — $(tail -1 build.log 2>/dev/null | cut -c1-160)"
    done
    if kill -0 "$CMD_PID" 2>/dev/null; then
      echo "WATCHDOG: ${LABEL} exceeded ${CAP_MIN}m — killing"
      pkill -TERM -P "$CMD_PID" 2>/dev/null || true
      kill -TERM "$CMD_PID" 2>/dev/null || true
      sleep 5
      pkill -KILL -P "$CMD_PID" 2>/dev/null || true
      kill -KILL "$CMD_PID" 2>/dev/null || true
    fi
  ) &
  local WATCH_PID=$!
  local STATUS=0
  wait "$CMD_PID" || STATUS=$?
  kill "$WATCH_PID" 2>/dev/null || true
  wait "$WATCH_PID" 2>/dev/null || true
  echo "${LABEL} finished with status ${STATUS}"
  return "$STATUS"
}

build_once() {
  xcodebuild \
    -project AgentPad.xcodeproj \
    -scheme AgentPad \
    -configuration Release \
    -destination "generic/platform=iOS Simulator" \
    -derivedDataPath DerivedData \
    CODE_SIGNING_ALLOWED=NO \
    OTHER_SWIFT_FLAGS='$(inherited) -Xfrontend -warn-long-function-bodies=15000 -Xfrontend -warn-long-expression-type-checking=15000' \
    build > build.log 2>&1
}

echo "==> Building NovaForge (Release, iPhone simulator; 30m cap)"
set -o pipefail
if ! run_capped 30 "xcodebuild" build_once; then
  echo "BUILD FAILED OR TIMED OUT — slowest type-checks:"
  grep -E "warning: (expression|function|instance method|getter) took" build.log | head -30 || true
  tail -60 build.log || true
  exit 65
fi
tail -30 build.log
echo "==> Slow type-check report (anything over 15s):"
grep -E "warning: (expression|function) took" build.log | head -20 || echo "none over threshold"

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
run_capped 10 "simulator-boot" xcrun simctl bootstatus "$UDID" -b || {
  echo "SIMULATOR BOOT TIMED OUT"
  exit 66
}
echo "simulator ready: $UDID"

echo "==> Installing app"
ls -la "$APP_PATH"
echo "==> Verifying widget extension embedding"
ls -la "$APP_PATH/PlugIns/"
test -d "$APP_PATH/PlugIns/NovaForgeWidgets.appex"
echo "widget appex embedded OK"
xcrun simctl install "$UDID" "$APP_PATH"

# ---------------------------------------------------------------------------
echo "==> Screenshot tour (full surface census)"
# Let SpringBoard settle so first-boot system banners (Apple Intelligence
# onboarding etc.) clear before we start photographing.
sleep 15
# Kill first-boot keyboard education sheets so keyboard captures show keys.
xcrun simctl spawn "$UDID" defaults write com.apple.keyboard.preferences DidShowContinuousPathIntroduction -bool true 2>/dev/null || true
xcrun simctl spawn "$UDID" defaults write com.apple.Preferences DidShowContinuousPathIntroduction -bool true 2>/dev/null || true
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
shot "09-chat-tools" --reset-ui --open-chat --open-project-chat --running-tool-call-demo
shot "10-chat-code" --reset-ui --open-chat --open-project-chat --code-block-demo
shot "11-chat-failed" --reset-ui --open-chat --open-project-chat --failed-tool-call-demo
shot "12-chat-approval" --reset-ui --open-chat --pending-approval-demo
shot "13-chat-keyboard" WAIT=11 --reset-ui --open-chat --settings-local-model-ready --keyboard-focus-demo

# --- Project journey states -------------------------------------------------
shot "14-project-running" --reset-ui --open-project --project-running-demo
shot "15-project-blocked" --reset-ui --open-project --project-blocked-demo
shot "16-project-waiting" --reset-ui --open-project --project-waiting-demo
shot "17-project-proof" --reset-ui --open-project --project-proof-demo
shot "18-project-countdown" --reset-ui --open-project --auto-continue-countdown-demo

# --- Runs / terminal / artifact depth ----------------------------------------
# --runs-approval-demo keeps the Runs tab in front (the generic
# --pending-approval-demo forces the chat tab and raced --open-runs).
shot "19-runs-approval" --reset-ui --open-runs --runs-approval-demo
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
shot "35-run-replay" WAIT=14 --reset-ui --open-runs --project-proof-demo --open-run-replay-demo

# --- Home screen: the app icon in situ ---------------------------------------
echo "==> Capturing home screen app icon"
xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
sleep 3
xcrun simctl io "$UDID" screenshot "captures/36-app-icon.png"

# --- Facelift census: surfaces never photographed before ----------------------
shot "37-chat-drawer" WAIT=11 --reset-ui --open-chat --settings-local-model-ready --open-chat-drawer-demo
shot "38-code-editor" WAIT=12 --reset-ui --open-files --open-code-editor-demo
shot "39-file-comparison" WAIT=11 --reset-ui --open-files --open-file-comparison-demo
shot "40-files-search" WAIT=13 --reset-ui --open-files --stress-files --open-files-search-demo
shot "41-model-picker" WAIT=11 --reset-ui --open-settings --open-model-picker-demo
shot "42-project-intake" WAIT=11 --reset-ui --open-project --project-intake-demo
shot "43-delete-confirm" WAIT=11 --reset-ui --open-project --project-delete-confirm-demo
shot "44-artifact-landscape" WAIT=17 --reset-ui --open-files --project-spine-e2e-demo --workbench-open-artifact-landscape-preview

# --- iPad census (device family claims iPad; prove it on camera) --------------
echo "==> iPad census"
IPAD_UDID=$(xcrun simctl list -j devices available | jq -r '[.devices | to_entries[] | select(.key | contains("iOS")) | .value[] | select(.isAvailable == true and (.name | startswith("iPad")))] | last | .udid // empty')
if [ -n "$IPAD_UDID" ]; then
  if run_capped 10 "ipad-boot" xcrun simctl bootstatus "$IPAD_UDID" -b; then
    xcrun simctl install "$IPAD_UDID" "$APP_PATH"
    ipad_shot() {
      NAME="$1"; shift
      xcrun simctl terminate "$IPAD_UDID" "$BUNDLE" 2>/dev/null || true
      sleep 1
      xcrun simctl launch "$IPAD_UDID" "$BUNDLE" "$@"
      sleep 11
      xcrun simctl io "$IPAD_UDID" screenshot "captures/$NAME.png"
      echo "captured $NAME"
    }
    ipad_shot "45-ipad-project" --reset-ui --open-project --project-proof-demo
    ipad_shot "46-ipad-chat" --reset-ui --open-chat --settings-local-model-ready
    xcrun simctl shutdown "$IPAD_UDID" || true
  else
    echo "WARN: iPad boot failed — skipping iPad shots"
  fi
else
  echo "WARN: no iPad simulator available"
fi

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
