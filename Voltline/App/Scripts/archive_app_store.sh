#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$APP_DIR"

TEAM_ID="${DEVELOPMENT_TEAM:-93MYZUV85K}"
ARCHIVE_PATH="$APP_DIR/Artifacts/Voltline.xcarchive"
EXPORT_PATH="$APP_DIR/Artifacts/AppStoreExport"
GENERATED_EXPORT_OPTIONS="$APP_DIR/Artifacts/ExportOptions-AppStore.generated.plist"

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
cp Resources/ExportOptions-AppStore.plist "$GENERATED_EXPORT_OPTIONS"
/usr/libexec/PlistBuddy -c "Set :teamID $TEAM_ID" "$GENERATED_EXPORT_OPTIONS"
plutil -lint "$GENERATED_EXPORT_OPTIONS"

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

ARCHIVED_APP="$ARCHIVE_PATH/Products/Applications/VoltlineGame.app"
test -d "$ARCHIVED_APP"
test -f "$ARCHIVED_APP/Info.plist"
test -f "$ARCHIVED_APP/PrivacyInfo.xcprivacy"
ARCHIVED_BUNDLE_ID=$(plutil -extract CFBundleIdentifier raw "$ARCHIVED_APP/Info.plist")
if [[ "$ARCHIVED_BUNDLE_ID" != "com.joey.VoltlineGame" ]]; then
  echo "Unexpected archived bundle identifier: $ARCHIVED_BUNDLE_ID"
  exit 1
fi

xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$GENERATED_EXPORT_OPTIONS" \
  -allowProvisioningUpdates

IPA_PATH=$(find "$EXPORT_PATH" -maxdepth 1 -name '*.ipa' -print -quit)
if [[ -z "$IPA_PATH" ]]; then
  echo "Archive export completed without producing an IPA."
  exit 1
fi

echo
echo "App Store export completed: $IPA_PATH"
echo "Upload the IPA through Xcode Organizer, Transporter, or App Store Connect tooling."
