#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="${PROJECT_PATH:-$ROOT_DIR/AgentPad.xcodeproj}"
SCHEME="${SCHEME:-AgentPad}"
CONFIGURATION="${CONFIGURATION:-Release}"
APP_NAME="${APP_NAME:-NovaForge.app}"
BUNDLE_ID="${BUNDLE_ID:-com.joey.NovaForge}"
DEVICE_ID="${DEVICE_ID:-${1:-}}"
EXPECTED_PRODUCT_TYPE="${EXPECTED_PRODUCT_TYPE:-iPhone13,2}"
EXPECTED_IOS_MAJOR="${EXPECTED_IOS_MAJOR:-27}"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}"
ALLOW_PROVISIONING_DEVICE_REGISTRATION="${ALLOW_PROVISIONING_DEVICE_REGISTRATION:-0}"
LAUNCH_AFTER_INSTALL="${LAUNCH_AFTER_INSTALL:-0}"
BUILD_TIMEOUT="${BUILD_TIMEOUT:-1200}"
DEVICE_TIMEOUT="${DEVICE_TIMEOUT:-180}"
STAMP="$(date +%Y%m%d-%H%M%S)"
SOURCE_SHA="$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || true)"
SOURCE_SHORT="${SOURCE_SHA:0:12}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$HOME/Library/Developer/Xcode/DerivedData/NovaForgePreviewInstall-$SOURCE_SHORT}"
RECEIPT_DIR="${RECEIPT_DIR:-$HOME/Library/Logs/NovaForge/PreviewInstall/$STAMP-$SOURCE_SHORT}"

usage() {
  cat <<'EOF'
Usage:
  DEVICE_ID=<connected-device-id> scripts/codex-device-preview-install.sh
  scripts/codex-device-preview-install.sh <connected-device-id>

Find the connected device identifier with:
  xcrun devicectl list devices

Defaults bind the Preview qualification target to iPhone 12 (product type
`iPhone13,2`) on iOS 27. Override EXPECTED_PRODUCT_TYPE / EXPECTED_IOS_MAJOR
only when intentionally testing a different device; the receipt will record it.

Optional signing/build controls:
  DEVELOPMENT_TEAM=<Apple team id>
  ALLOW_PROVISIONING_DEVICE_REGISTRATION=1
  CONFIGURATION=Release|Debug
  LAUNCH_AFTER_INSTALL=1
  DERIVED_DATA_PATH=/path
  RECEIPT_DIR=/path/outside/repo
EOF
}

if [[ -z "$DEVICE_ID" ]]; then
  usage >&2
  exit 2
fi
if [[ "${2:-}" != "" ]]; then
  usage >&2
  exit 2
fi
if [[ ! "$SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]]; then
  echo "Preview device install requires an exact Git source SHA." >&2
  exit 1
fi

for tool in git xcodebuild xcrun /usr/libexec/PlistBuddy codesign python3; do
  if [[ "$tool" == /* ]]; then
    [[ -x "$tool" ]] || { echo "Required tool is missing: $tool" >&2; exit 1; }
  else
    command -v "$tool" >/dev/null 2>&1 || { echo "Required tool is missing: $tool" >&2; exit 1; }
  fi
done

# The embedded NovaForgeSourceCommit marker is meaningful only for an exact,
# clean checkout. Refuse local edits/untracked source instead of stamping them
# with the current commit and creating false release evidence.
WORKTREE_STATUS="$(git -C "$ROOT_DIR" status --porcelain --untracked-files=all)"
if [[ -n "$WORKTREE_STATUS" ]]; then
  echo "Refusing device build from a dirty worktree." >&2
  echo "Commit, stash, or remove local changes first; the source receipt must bind exact bytes." >&2
  printf '%s\n' "$WORKTREE_STATUS" >&2
  exit 1
fi

if ! xcrun devicectl device info details --help 2>&1 | grep -Fq -- '--json-output'; then
  echo "This Xcode devicectl does not expose --json-output for device identity receipts." >&2
  echo "Select a current Xcode installation and retry." >&2
  exit 1
fi

mkdir -p "$RECEIPT_DIR" "$DERIVED_DATA_PATH"
DEVICE_JSON="$RECEIPT_DIR/device-details.json"
DEVICE_LOG="$RECEIPT_DIR/device-details.log"
BUILD_LOG="$RECEIPT_DIR/build.log"
INSTALL_LOG="$RECEIPT_DIR/install.log"
SIGNING_LOG="$RECEIPT_DIR/codesign.txt"
SUMMARY="$RECEIPT_DIR/receipt.txt"

run_with_timeout() {
  local timeout_seconds="$1"
  shift
  "$@" &
  local command_pid=$!
  local elapsed=0

  while kill -0 "$command_pid" 2>/dev/null; do
    if (( timeout_seconds > 0 && elapsed >= timeout_seconds )); then
      kill "$command_pid" 2>/dev/null || true
      sleep 1
      kill -9 "$command_pid" 2>/dev/null || true
      wait "$command_pid" 2>/dev/null || true
      return 124
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  wait "$command_pid"
}

echo "Inspecting connected device..."
if ! run_with_timeout "$DEVICE_TIMEOUT" xcrun devicectl device info details \
  --device "$DEVICE_ID" \
  --json-output "$DEVICE_JSON" >"$DEVICE_LOG" 2>&1; then
  status=$?
  echo "Could not inspect connected device. See: $DEVICE_LOG" >&2
  exit "${status:-1}"
fi

python3 - "$DEVICE_JSON" "$EXPECTED_PRODUCT_TYPE" "$EXPECTED_IOS_MAJOR" <<'PY'
import json
import re
import sys
from pathlib import Path

path, expected_product, expected_major = sys.argv[1:]
data = json.loads(Path(path).read_text(encoding="utf-8"))

strings = []
def walk(value):
    if isinstance(value, dict):
        for key, child in value.items():
            strings.append(str(key))
            walk(child)
    elif isinstance(value, list):
        for child in value:
            walk(child)
    elif value is not None:
        strings.append(str(value))
walk(data)

if expected_product not in strings:
    raise SystemExit(
        f"Connected device does not report required product type {expected_product}. "
        "Override EXPECTED_PRODUCT_TYPE only for an intentional non-baseline run."
    )

major = re.escape(expected_major)
version_pattern = re.compile(rf"^{major}(?:\.[0-9]+){{0,2}}$")
if not any(version_pattern.fullmatch(item) for item in strings):
    raise SystemExit(
        f"Connected device does not report an iOS {expected_major}.x version. "
        "Override EXPECTED_IOS_MAJOR only for an intentional non-baseline run."
    )
PY

printf -v device_id_hash '%s' "$DEVICE_ID"
DEVICE_ID_SHA256="$(printf '%s' "$device_id_hash" | shasum -a 256 | awk '{print $1}')"

BUILD_ARGS=(
  -project "$PROJECT_PATH"
  -scheme "$SCHEME"
  -configuration "$CONFIGURATION"
  -destination "platform=iOS,id=$DEVICE_ID"
  -destination-timeout 120
  -derivedDataPath "$DERIVED_DATA_PATH"
  -skipPackageUpdates
  -skipPackagePluginValidation
  -skipMacroValidation
  -allowProvisioningUpdates
  ONLY_ACTIVE_ARCH=YES
  CODE_SIGN_STYLE=Automatic
  COMPILER_INDEX_STORE_ENABLE=NO
  "NOVAFORGE_SOURCE_COMMIT=$SOURCE_SHA"
)
if [[ -n "$DEVELOPMENT_TEAM" ]]; then
  BUILD_ARGS+=("DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM")
fi
if [[ "$ALLOW_PROVISIONING_DEVICE_REGISTRATION" == "1" ]]; then
  BUILD_ARGS+=(-allowProvisioningDeviceRegistration)
fi

echo "Building exact source $SOURCE_SHA for connected iOS device..."
rm -rf "$DERIVED_DATA_PATH"
if ! run_with_timeout "$BUILD_TIMEOUT" xcodebuild "${BUILD_ARGS[@]}" build >"$BUILD_LOG" 2>&1; then
  status=$?
  echo "Device build failed. Last 100 lines from $BUILD_LOG:" >&2
  tail -n 100 "$BUILD_LOG" >&2 || true
  exit "${status:-1}"
fi

APP_PATH="$(find "$DERIVED_DATA_PATH/Build/Products" -path "*${CONFIGURATION}-iphoneos/$APP_NAME" -type d -print | sed -n '1p')"
if [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
  echo "Signed $APP_NAME was not produced under $DERIVED_DATA_PATH." >&2
  exit 1
fi

EMBEDDED_SHA="$(/usr/libexec/PlistBuddy -c 'Print :NovaForgeSourceCommit' "$APP_PATH/Info.plist" 2>/dev/null || true)"
EMBEDDED_SHA="$(printf '%s' "$EMBEDDED_SHA" | tr '[:upper:]' '[:lower:]')"
if [[ "$EMBEDDED_SHA" != "$SOURCE_SHA" ]]; then
  echo "Built app source marker '$EMBEDDED_SHA' does not match exact source '$SOURCE_SHA'." >&2
  exit 1
fi

if ! codesign -dv --verbose=4 "$APP_PATH" >"$SIGNING_LOG" 2>&1; then
  echo "Built app is not validly code signed for device installation." >&2
  cat "$SIGNING_LOG" >&2 || true
  exit 1
fi

APP_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Info.plist")"
if [[ "$APP_BUNDLE_ID" != "$BUNDLE_ID" ]]; then
  echo "Unexpected built bundle identifier: $APP_BUNDLE_ID (expected $BUNDLE_ID)." >&2
  exit 1
fi

echo "Installing $APP_NAME on the selected connected device..."
if ! run_with_timeout "$DEVICE_TIMEOUT" xcrun devicectl device install app \
  --device "$DEVICE_ID" \
  "$APP_PATH" >"$INSTALL_LOG" 2>&1; then
  status=$?
  echo "Device install failed. See: $INSTALL_LOG" >&2
  tail -n 100 "$INSTALL_LOG" >&2 || true
  exit "${status:-1}"
fi

if [[ "$LAUNCH_AFTER_INSTALL" == "1" ]]; then
  echo "Launching $BUNDLE_ID on the selected device..."
  run_with_timeout "$DEVICE_TIMEOUT" xcrun devicectl device process launch \
    --device "$DEVICE_ID" \
    "$BUNDLE_ID" >>"$INSTALL_LOG" 2>&1 || {
      status=$?
      echo "Install succeeded, but automatic launch failed. Open NovaForge manually or inspect $INSTALL_LOG." >&2
      exit "${status:-1}"
    }
fi

{
  echo "NovaForge Preview connected-device install receipt"
  echo "sourceSHA=$SOURCE_SHA"
  echo "embeddedSourceSHA=$EMBEDDED_SHA"
  echo "configuration=$CONFIGURATION"
  echo "bundleID=$APP_BUNDLE_ID"
  echo "expectedProductType=$EXPECTED_PRODUCT_TYPE"
  echo "expectedIOSMajor=$EXPECTED_IOS_MAJOR"
  echo "deviceIdentifierSHA256=$DEVICE_ID_SHA256"
  echo "xcode=$(xcodebuild -version | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  echo "installedAtUTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "deviceDetails=$DEVICE_JSON"
  echo "buildLog=$BUILD_LOG"
  echo "installLog=$INSTALL_LOG"
  echo "truthBoundary=This receipt proves this Mac built and installed the named exact source on a connected device matching the configured identity checks. It does not prove Local AI quality, provider health, performance, thermals, accessibility, visual acceptance, or successful app journeys."
} > "$SUMMARY"

echo
echo "NovaForge Preview installed."
echo "Source: $SOURCE_SHA"
echo "Device target: $EXPECTED_PRODUCT_TYPE / iOS $EXPECTED_IOS_MAJOR.x"
echo "Receipt: $SUMMARY"
echo "Device identifiers/signing credentials were not written to the repository."
