#!/usr/bin/env bash
set -euo pipefail

# Static/self-test lane only. It never invokes xcrun, xcodebuild, simctl, or a
# device. The unavailable case is exercised with a harmless xcrun stub.
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROTOCOL="$ROOT_DIR/scripts/run-local-ai-device-protocol.sh"
POWER_PROTOCOL="$ROOT_DIR/scripts/run-qwen38-out-of-core-device-protocol.sh"
TOOLCHAIN_SELECTOR="$ROOT_DIR/scripts/select-xcode27.sh"
COREAI_EXPORT="$ROOT_DIR/scripts/export-coreai-qwen.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/novaforge-local-ai-protocol.XXXXXX")"
cleanup_test_artifacts() {
  local exit_status=$?
  if [[ "${KEEP_PROTOCOL_TEST_ARTIFACTS:-0}" == 1 ]]; then
    printf 'Protocol self-test artifacts: %s\n' "$TMP_DIR" >&2
  else
    rm -rf "$TMP_DIR"
  fi
  return "$exit_status"
}
trap cleanup_test_artifacts EXIT

bash -n "$PROTOCOL"
bash -n "$POWER_PROTOCOL"
bash -n "$TOOLCHAIN_SELECTOR"
grep -Fq 'Xcode 27 toolchain unavailable' "$TOOLCHAIN_SELECTOR"
grep -Fq 'XCODE_27_APP' "$TOOLCHAIN_SELECTOR"
grep -Fq 'NOVAFORGE_IPHONEOS_SDK_VERSION' "$TOOLCHAIN_SELECTOR"
grep -Fq 'source "$TOOLCHAIN_SELECTOR"' "$PROTOCOL"
grep -Fq 'xcode27-physical-device-build' "$PROTOCOL"
grep -Fq 'app_sdk_name' "$PROTOCOL"
grep -Fq 'iphoneos27.' "$PROTOCOL"
grep -Fq 'local-power-admission-experiment' "$POWER_PROTOCOL"
grep -Fq 'local-out-of-core-storage-benchmark' "$POWER_PROTOCOL"
grep -Fq 'useful_tokens >= 128' "$POWER_PROTOCOL"
grep -Fq 'advisedEvictionBytes > 0' "$POWER_PROTOCOL"
grep -Fq 'POWER_VARIANT' "$POWER_PROTOCOL"
grep -Fq 'iq1)' "$POWER_PROTOCOL"
grep -Fq 'iq2)' "$POWER_PROTOCOL"
grep -Fq 'q3)' "$POWER_PROTOCOL"
grep -Fq 'A9CFDD8D-E5B9-5B93-917A-513357EAD81E' "$PROTOCOL"
grep -Fq 'MIN_USEFUL_TOKENS' "$PROTOCOL"
grep -Fq 'THERMAL_SOAK_SECONDS' "$PROTOCOL"
grep -Fq 'synthetic-memory-warning-and-background-notifications' "$PROTOCOL"
grep -Fq 'device process terminate' "$PROTOCOL"
grep -Fq 'evidence-manifest.json' "$PROTOCOL"
! grep -Fq 'df308952a875aafe56425e98c795c96f8d9ccc9b04f1f25bedffc0379ba612c6' "$PROTOCOL"

# Verify the pre-existing Core AI lanes remain guarded and pinned without
# invoking Xcode, coreai-build, or Instruments.
grep -Fq 'Apple Silicon Mac' "$COREAI_EXPORT"
grep -Fq 'Xcode 27 or later' "$COREAI_EXPORT"
grep -Fq 'coreai-build compile' "$COREAI_EXPORT"
grep -Fq 'min-deployment-version 27.0' "$COREAI_EXPORT"
grep -Fq 'f43b6da728c6af5af15db345ffb2d8402d27013b' "$COREAI_EXPORT"

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/Developer/usr/bin"
cat > "$TMP_DIR/bin/xcrun" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--sdk" && "${2:-}" == "iphoneos" && "${3:-}" == "--show-sdk-version" ]]; then
  echo "27.0"
  exit 0
fi
echo "stubbed CoreDevice: no physical device is available"
exit 0
EOF
cat > "$TMP_DIR/Developer/usr/bin/xcodebuild" <<'EOF'
#!/usr/bin/env bash
echo "Xcode 27.0"
echo "Build version 18A000"
EOF
chmod +x "$TMP_DIR/bin/xcrun"
chmod +x "$TMP_DIR/Developer/usr/bin/xcodebuild"

set +e
PATH="$TMP_DIR/bin:$PATH" \
  DEVELOPER_DIR="$TMP_DIR/Developer" \
  EVIDENCE_DIR="$TMP_DIR/evidence" \
  PROTOCOL_TIMEOUT_SECONDS=2 \
  POLL_SECONDS=0 \
  "$PROTOCOL" >"$TMP_DIR/stdout" 2>"$TMP_DIR/stderr"
status=$?
set -e
[[ "$status" -eq 2 ]]
jq -e '
  .executionClass == "unavailable" and
  .availability == "unavailable" and
  .claimsAllowed == false and
  .device.isPhysicalDevice == true and
  (.unavailableReason | type == "string" and length > 0)
' "$TMP_DIR/evidence/physical-protocol-receipt.json" >/dev/null
jq -e '.status == "unavailable" and (.files | length > 0)' \
  "$TMP_DIR/evidence/evidence-manifest.json" >/dev/null
grep -Fq 'exact iPhone target' "$TMP_DIR/stderr"
grep -Fq 'Selected Xcode 27.0 (27.0 SDK' "$TMP_DIR/stdout"

echo "PASS: protocol syntax, fail-closed gates, unavailable receipt, cleanup, and evidence manifest are covered without device execution."
