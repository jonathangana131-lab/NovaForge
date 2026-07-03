#!/bin/bash
# NovaForge CI pipeline - runs on a macOS GitHub Actions runner.
# Builds the app for the iPhone simulator, restores the binary app icon if
# missing, walks every app surface via launch arguments, captures screenshots
# and a matrix-rain video, and force-pushes all captures to the `ci-shots`
# branch (fetchable as public raw URLs). Build logs are published even when
# the build fails.
set -euo pipefail

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
  echo "==> Publishing captures to ci-shots branch"
  mkdir -p captures
  [ -f build.log ] && tail -300 build.log > captures/build-log-tail.txt
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
echo "==> Creating and booting simulator"
DEVICE_TYPE=$(xcrun simctl list -j devicetypes | jq -r '[.devicetypes[] | select(.productFamily == "iPhone")] | last | .identifier')
RUNTIME=$(xcrun simctl list -j runtimes | jq -r '[.runtimes[] | select(.platform == "iOS" and .isAvailable == true)] | last | .identifier')
echo "device: $DEVICE_TYPE / runtime: $RUNTIME"
UDID=$(xcrun simctl create "NovaCI" "$DEVICE_TYPE" "$RUNTIME")
xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b

echo "==> Installing app"
ls -la "$APP_PATH"
xcrun simctl install "$UDID" "$APP_PATH"

# ---------------------------------------------------------------------------
echo "==> Screenshot tour"
mkdir -p captures
shot() {
  NAME="$1"; shift
  xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
  sleep 1
  xcrun simctl launch "$UDID" "$BUNDLE" "$@"
  sleep 9
  xcrun simctl io "$UDID" screenshot "captures/$NAME.png"
  echo "captured $NAME"
}
shot "01-first-launch"
shot "02-project" --open-project
shot "03-files" --open-files
shot "04-chat" --open-chat
shot "05-runs" --open-runs
shot "06-settings" --open-settings
shot "07-matrix-project" --open-project --theme=matrix
shot "08-matrix-chat" --open-chat --theme=matrix
shot "09-matrix-settings" --open-settings --theme=matrix
shot "10-whitegold-project" --open-project --theme=whitegold
shot "11-arctic-project" --open-project --theme=arctic
shot "12-ember-project" --open-project --theme=ember

# ---------------------------------------------------------------------------
echo "==> Recording matrix rain video (10s)"
xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
xcrun simctl launch "$UDID" "$BUNDLE" --open-project --theme=matrix
sleep 6
xcrun simctl io "$UDID" recordVideo --codec h264 --force captures/matrix-rain.mp4 &
REC_PID=$!
sleep 10
kill -INT "$REC_PID"
sleep 3
wait "$REC_PID" || true
ls -la captures/

echo "==> Pipeline complete"
