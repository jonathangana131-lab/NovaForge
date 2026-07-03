#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/AgentPad.xcodeproj"
SCHEME="AgentPad"
CONFIGURATION="${CONFIGURATION:-Debug}"
BUNDLE_ID="${BUNDLE_ID:-com.joey.NovaForge}"
DEVICE_ID="${DEVICE_ID:-A9CFDD8D-E5B9-5B93-917A-513357EAD81E}"

echo "Building $SCHEME for iPhone..."
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "generic/platform=iOS" \
  build

APP_PATH="$(
  xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "generic/platform=iOS" \
    -showBuildSettings 2>/dev/null |
    awk -F ' = ' '
      $1 ~ /TARGET_BUILD_DIR$/ { targetBuildDir = $2 }
      $1 ~ /FULL_PRODUCT_NAME$/ { productName = $2 }
      END { print targetBuildDir "/" productName }
    '
)"

echo "Installing $APP_PATH on device $DEVICE_ID..."
xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH"

echo "Launching $BUNDLE_ID..."
xcrun devicectl device process launch \
  --device "$DEVICE_ID" \
  --terminate-existing \
  "$BUNDLE_ID"
