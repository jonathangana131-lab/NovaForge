#!/usr/bin/env bash
set -euo pipefail

DEVICE_ID="${DEVICE_ID:-A9CFDD8D-E5B9-5B93-917A-513357EAD81E}"
UDID="${UDID:-00008101-000D05022061401E}"
APP_BUNDLE_ID="${APP_BUNDLE_ID:-com.joey.NovaForge}"
DERIVED_DATA="${DERIVED_DATA:-/tmp/NovaForgeMetalDeviceDerivedData}"
MODEL_PATH="${MODEL_PATH:-/tmp/novaforge-models/VibeThinker-3B.Q2_K.gguf}"
APP_PATH="${APP_PATH:-$DERIVED_DATA/Build/Products/Debug-iphoneos/NovaForge.app}"
LOG_DIR="${LOG_DIR:-/tmp/novaforge-device-checks}"

mkdir -p "$LOG_DIR"

if [[ ! -d "$APP_PATH" ]]; then
  echo "Missing built app at $APP_PATH" >&2
  exit 1
fi

if [[ ! -f "$MODEL_PATH" ]]; then
  echo "Missing Q2 model at $MODEL_PATH" >&2
  exit 1
fi

MODEL_BYTES="$(stat -f '%z' "$MODEL_PATH")"
if [[ "$MODEL_BYTES" != "1274755776" ]]; then
  echo "Unexpected Q2 model size: $MODEL_BYTES bytes" >&2
  exit 1
fi

echo "Device state:"
xcrun devicectl list devices --timeout 30

echo "Installing NovaForge..."
xcrun devicectl device install app \
  --device "$DEVICE_ID" \
  "$APP_PATH" \
  --timeout 120 \
  --json-output "$LOG_DIR/install-q2.json" \
  --log-output "$LOG_DIR/install-q2.log"

echo "Creating app model directory..."
xcrun devicectl device copy to \
  --device "$DEVICE_ID" \
  --source "$MODEL_PATH" \
  --destination "Library/Application Support/LocalModels/VibeThinker-3B.Q2_K.gguf" \
  --domain-type appDataContainer \
  --domain-identifier "$APP_BUNDLE_ID" \
  --timeout 300 \
  --json-output "$LOG_DIR/copy-q2-model.json" \
  --log-output "$LOG_DIR/copy-q2-model.log"

echo "Launching local smoke test..."
xcrun devicectl device process launch \
  --device "$UDID" \
  --terminate-existing \
  --activate \
  "$APP_BUNDLE_ID" \
  --local-smoke-test \
  --json-output "$LOG_DIR/launch-q2-smoke.json" \
  --log-output "$LOG_DIR/launch-q2-smoke.log"

sleep 20
echo "NovaForge process after smoke launch:"
xcrun devicectl device info processes --device "$DEVICE_ID" --columns '*' --timeout 30 | grep -i NovaForge || true
