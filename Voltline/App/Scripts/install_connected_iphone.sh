#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$APP_DIR"

DEVICE_ID="${1:-${VOLTLINE_DEVICE_ID:-}}"
TEAM_ID="${DEVELOPMENT_TEAM:-93MYZUV85K}"
EXPECTED_BUNDLE_ID="com.joey.VoltlineGame"
DERIVED_DATA="$APP_DIR/DeviceDerivedData"

if [[ -z "$DEVICE_ID" ]]; then
  echo "Usage: bash Scripts/install_connected_iphone.sh <iPhone device identifier>"
  echo
  echo "Connected CoreDevice entries:"
  xcrun devicectl list devices || true
  echo
  echo "Copy the iPhone identifier above and run this command again."
  exit 64
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "Xcode is required. Install Xcode and select it in Xcode > Settings > Locations."
  exit 69
fi

chmod +x Scripts/bootstrap.sh
Scripts/bootstrap.sh
rm -rf "$DERIVED_DATA"

xcodebuild \
  -project VoltlineGame.xcodeproj \
  -scheme VoltlineGame \
  -configuration Debug \
  -destination "platform=iOS,id=$DEVICE_ID" \
  -derivedDataPath "$DERIVED_DATA" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Automatic \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  build

APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphoneos/VoltlineGame.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "Signed app was not produced at: $APP_PATH"
  exit 1
fi

test -f "$APP_PATH/Info.plist"
test -f "$APP_PATH/PrivacyInfo.xcprivacy"
BUNDLE_ID=$(plutil -extract CFBundleIdentifier raw "$APP_PATH/Info.plist")
if [[ "$BUNDLE_ID" != "$EXPECTED_BUNDLE_ID" ]]; then
  echo "Unexpected bundle identifier: $BUNDLE_ID"
  exit 1
fi

xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH"
xcrun devicectl device process launch --device "$DEVICE_ID" --terminate-existing "$BUNDLE_ID" || true

echo
echo "Voltline is installed. Its generated icon should now appear on the iPhone Home Screen."
