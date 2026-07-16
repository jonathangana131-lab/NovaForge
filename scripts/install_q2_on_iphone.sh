#!/usr/bin/env bash
set -euo pipefail

DEVICE_ID="${DEVICE_ID:-A9CFDD8D-E5B9-5B93-917A-513357EAD81E}"
UDID="${UDID:-00008101-000D05022061401E}"
APP_BUNDLE_ID="${APP_BUNDLE_ID:-com.joey.NovaForge}"
DERIVED_DATA="${DERIVED_DATA:-/tmp/NovaForgeMetalDeviceDerivedData}"
MODEL_PATH="${MODEL_PATH:-/tmp/novaforge-models/qwen2.5-coder-1.5b-instruct-q4_k_m.gguf}"
APP_PATH="${APP_PATH:-$DERIVED_DATA/Build/Products/Debug-iphoneos/NovaForge.app}"
LOG_DIR="${LOG_DIR:-/tmp/novaforge-device-checks}"

mkdir -p "$LOG_DIR"

if [[ ! -d "$APP_PATH" ]]; then
  echo "Missing built app at $APP_PATH" >&2
  exit 1
fi

if [[ ! -f "$MODEL_PATH" ]]; then
  echo "Missing verified local model at $MODEL_PATH" >&2
  exit 1
fi

MODEL_BYTES="$(stat -f '%z' "$MODEL_PATH")"
if [[ "$MODEL_BYTES" != "1117320768" ]]; then
  echo "Unexpected local model size: $MODEL_BYTES bytes" >&2
  exit 1
fi

MODEL_SHA256="$(shasum -a 256 "$MODEL_PATH" | awk '{print $1}')"
if [[ "$MODEL_SHA256" != "cc324af070c2ecbfd324a30884d2f951a7ff756aba85cb811a6ec436933bb046" ]]; then
  echo "Unexpected local model SHA-256" >&2
  exit 1
fi

echo "Device state:"
xcrun devicectl list devices --timeout 30

echo "Installing NovaForge..."
xcrun devicectl device install app \
  --device "$DEVICE_ID" \
  "$APP_PATH" \
  --timeout 120 \
  --json-output "$LOG_DIR/install-local.json" \
  --log-output "$LOG_DIR/install-local.log"

echo "Creating app model directory..."
xcrun devicectl device copy to \
  --device "$DEVICE_ID" \
  --source "$MODEL_PATH" \
  --destination "Library/Application Support/LocalModels/qwen2.5-coder-1.5b-instruct-q4_k_m.gguf" \
  --domain-type appDataContainer \
  --domain-identifier "$APP_BUNDLE_ID" \
  --timeout 300 \
  --json-output "$LOG_DIR/copy-local-model.json" \
  --log-output "$LOG_DIR/copy-local-model.log"

echo "Launching local smoke test..."
PROOF_PATH="$LOG_DIR/LocalAgentSmokeProof.json"
TOOL_PROOF_PATH="$LOG_DIR/canonical-tool-proof.txt"
rm -f "$PROOF_PATH" "$TOOL_PROOF_PATH"
xcrun devicectl device process launch \
  --device "$DEVICE_ID" \
  --terminate-existing \
  --activate \
  "$APP_BUNDLE_ID" \
  --local-smoke-test \
  --json-output "$LOG_DIR/launch-local-smoke.json" \
  --log-output "$LOG_DIR/launch-local-smoke.log"

echo "Waiting for canonical Qwen + tool proof..."
for attempt in $(seq 1 48); do
  if xcrun devicectl device copy from \
    --device "$DEVICE_ID" \
    --source "Library/Application Support/LocalAgentSmokeProof.json" \
    --destination "$PROOF_PATH" \
    --domain-type appDataContainer \
    --domain-identifier "$APP_BUNDLE_ID" \
    --timeout 20 \
    --json-output "$LOG_DIR/copy-smoke-proof.json" \
    --log-output "$LOG_DIR/copy-smoke-proof.log" >/dev/null 2>&1; then
    break
  fi
  sleep 5
done

if [[ ! -f "$PROOF_PATH" ]]; then
  echo "Local agent smoke proof was not produced." >&2
  exit 1
fi

SMOKE_STATUS="$(/usr/bin/plutil -extract status raw "$PROOF_PATH")"
if [[ "$SMOKE_STATUS" != "passed" ]]; then
  echo "Local agent smoke failed:" >&2
  /bin/cat "$PROOF_PATH" >&2
  exit 1
fi

PROOF_MODEL_SHA="$(/usr/bin/plutil -extract model_sha256 raw "$PROOF_PATH")"
if [[ "$PROOF_MODEL_SHA" != "$MODEL_SHA256" ]]; then
  echo "Local smoke ran against an unexpected model digest." >&2
  exit 1
fi

xcrun devicectl device copy from \
  --device "$DEVICE_ID" \
  --source "Documents/Workspaces/Default/LocalAgentSmoke/canonical-tool-proof.txt" \
  --destination "$TOOL_PROOF_PATH" \
  --domain-type appDataContainer \
  --domain-identifier "$APP_BUNDLE_ID" \
  --timeout 30 \
  --json-output "$LOG_DIR/copy-tool-proof.json" \
  --log-output "$LOG_DIR/copy-tool-proof.log"

if ! /usr/bin/grep -q "canonical qwen local agent tool proof" "$TOOL_PROOF_PATH"; then
  echo "Canonical local tool output was missing or incorrect." >&2
  exit 1
fi

echo "Canonical local agent smoke passed:"
/bin/cat "$PROOF_PATH"
