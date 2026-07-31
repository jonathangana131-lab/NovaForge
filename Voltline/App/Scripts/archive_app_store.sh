#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$APP_DIR"

TEAM_ID="${DEVELOPMENT_TEAM:-93MYZUV85K}"
ARCHIVE_PATH="$APP_DIR/Artifacts/Voltline.xcarchive"
EXPORT_PATH="$APP_DIR/Artifacts/AppStoreExport"

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "Xcode is required to archive Voltline."
  exit 69
fi

XCODE_MAJOR=$(xcodebuild -version | awk '/^Xcode / { split($2, parts, "."); print parts[1] }')
if [[ -z "$XCODE_MAJOR" || "$XCODE_MAJOR" -lt 26 ]]; then
  echo "App Store archives must use Xcode 26 or newer. Active toolchain:"
  xcodebuild -version
  echo "Select a current Xcode in Xcode > Settings > Locations, then run this script again."
  exit 65
fi

chmod +x Scripts/bootstrap.sh
Scripts/bootstrap.sh
plutil -lint Resources/Info.plist
plutil -lint Resources/PrivacyInfo.xcprivacy
plutil -lint Resources/ExportOptions-AppStore.plist

rm -rf "$ARCHIVE_PATH" "$EXPORT_PATH"
mkdir -p "$APP_DIR/Artifacts"

xcodebuild \
  -project VoltlineGame.xcodeproj \
  -scheme VoltlineGame \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVE_PATH" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Automatic \
  -allowProvisioningUpdates \
  clean archive

xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist Resources/ExportOptions-AppStore.plist \
  -allowProvisioningUpdates

echo
echo "App Store export completed: $EXPORT_PATH"
echo "Upload the exported IPA through Xcode Organizer, Transporter, or App Store Connect tooling."
