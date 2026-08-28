#!/usr/bin/env bash
set -euo pipefail

# Physical-only, fail-closed Qwen3.8-27B staged-weight admission experiment.
# A failed load, jetsam, timeout, incomplete receipt, or missing measurement
# leaves Power On-device unadmitted and never selects the LAN companion.

ROOT_DIR="$(cd "$(dirname "$BASH_SOURCE")/.." && pwd)"
DEVICE_ID="${DEVICE_ID:-A9CFDD8D-E5B9-5B93-917A-513357EAD81E}"
DEVICE_UDID="${DEVICE_UDID:-00008101-000D05022061401E}"
APP_BUNDLE_ID="${APP_BUNDLE_ID:-com.joey.NovaForge}"
MODEL_REVISION="f4480441d4fb4fe2e283c5d1e05d230195afd939"
POWER_VARIANT="${POWER_VARIANT:-iq1}"
case "$POWER_VARIANT" in
  iq1)
    MODEL_ID="unsloth/Qwen3.8-27B-UD-IQ1_S-Power-On-Device"
    MODEL_QUANTIZATION="UD-IQ1_S"
    MODEL_SHA256="ffcaee8ef32a3fc91ac1b57f529f14e3054624c40cfae809437d490aa2cd597d"
    MODEL_BYTES=6192222304
    MODEL_FILENAME="Qwen3.8-27B-UD-IQ1_S.gguf"
    ;;
  iq2)
    MODEL_ID="unsloth/Qwen3.8-27B-UD-IQ2_XXS-Power-On-Device"
    MODEL_QUANTIZATION="UD-IQ2_XXS"
    MODEL_SHA256="8d1b37297d6cf98303cd396896f35e01089ddcc904053a9c6997f7a1c35b8524"
    MODEL_BYTES=9010048064
    MODEL_FILENAME="Qwen3.8-27B-UD-IQ2_XXS.gguf"
    ;;
  q3)
    MODEL_ID="unsloth/Qwen3.8-27B-Q3_K_M-Power-On-Device"
    MODEL_QUANTIZATION="Q3_K_M"
    MODEL_SHA256="7f3b845b563888ec3abc269474cf744bf703a7ce8766dbb7f696c63975facfd7"
    MODEL_BYTES=13818690528
    MODEL_FILENAME="Qwen3.8-27B-Q3_K_M.gguf"
    ;;
  *)
    echo "POWER_VARIANT must be iq1, iq2, or q3" >&2
    exit 2
    ;;
esac
MODEL_PATH="${POWER_MODEL_PATH:-/tmp/novaforge-models/$MODEL_FILENAME}"
DERIVED_DATA="${DEVICE_DERIVED_DATA:-/tmp/NovaForgeXcode27DeviceDerivedData}"
APP_PATH="${APP_PATH:-$DERIVED_DATA/Build/Products/Debug-iphoneos/NovaForge.app}"
BUILD_FIRST="${BUILD_FIRST:-1}"
PROTOCOL_TIMEOUT_SECONDS="${PROTOCOL_TIMEOUT_SECONDS:-2700}"
DEVICE_COMMAND_TIMEOUT_SECONDS="${DEVICE_COMMAND_TIMEOUT_SECONDS:-60}"
POLL_SECONDS="${POLL_SECONDS:-5}"
RUN_STAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
EVIDENCE_DIR="${EVIDENCE_DIR:-$ROOT_DIR/QA/qwen38-out-of-core-$POWER_VARIANT-$RUN_STAMP}"
TIMEOUT_RUNNER="$ROOT_DIR/scripts/codex-timeout-runner.pl"
TOOLCHAIN_SELECTOR="$ROOT_DIR/scripts/select-xcode27.sh"
CANDIDATE_MANIFEST="$ROOT_DIR/scripts/out-of-core/qwen3.8-27b-candidates.manifest.json"
CANDIDATE_MANIFEST_SHA256="2cdb7753f4d384841bfca45de5f4c04ddd5d5c1676f7511316a6759885e72a65"
SUMMARY_PATH="$EVIDENCE_DIR/admission-summary.json"
STATUS=failed
FAILURE_REASON="protocol did not reach a terminal result"
DEADLINE=$(( $(date +%s) + PROTOCOL_TIMEOUT_SECONDS ))
mkdir -p "$EVIDENCE_DIR"

remaining() { echo $(( DEADLINE - $(date +%s) )); }
fail() { FAILURE_REASON="$1"; echo "Qwen3.8 out-of-core admission failed: $1" >&2; exit 1; }

write_summary() {
  local claims=false
  [[ "$STATUS" == passed ]] && claims=true
  jq -n \
    --arg status "$STATUS" --arg reason "$FAILURE_REASON" \
    --arg model "$MODEL_ID" --arg revision "$MODEL_REVISION" \
    --arg quantization "$MODEL_QUANTIZATION" --arg variant "$POWER_VARIANT" \
    --arg sha "$MODEL_SHA256" --arg device "$DEVICE_ID" \
    --arg xcode "${NOVAFORGE_XCODE_VERSION:-unavailable}" \
    --arg sdk "${NOVAFORGE_IPHONEOS_SDK_VERSION:-unavailable}" \
    --argjson bytes "$MODEL_BYTES" --argjson claims "$claims" '{
      schemaVersion: 1,
      receiptKind: "qwen38_out_of_core_admission",
      status: $status,
      claimsAllowed: $claims,
      failureReason: (if $reason == "" then null else $reason end),
      deviceID: $device,
      candidateKey: $variant,
      model: {id:$model, revision:$revision, sha256:$sha, bytes:$bytes,
              quantization:$quantization, textOnly:true, visionProjector:false},
      toolchain: {xcode:$xcode, iphoneosSDK:$sdk},
      runtime: {planner:"gguf-layer-ranges+mmap+read-ahead+page-eviction",
                residentBudgetBytes:1500000000, generationLeaseCount:1,
                mtp:"disabled-until-measured"},
      profiles:["cpu","partial-metal","full-metal"]
    }' > "$SUMMARY_PATH"
}

cleanup() {
  local result=$?
  xcrun devicectl device process terminate --device "$DEVICE_ID" "$APP_BUNDLE_ID" \
    --timeout "$DEVICE_COMMAND_TIMEOUT_SECONDS" >/dev/null 2>&1 || true
  write_summary || true
  find "$EVIDENCE_DIR" -type f ! -name SHA256SUMS -print0 \
    | sort -z | xargs -0 shasum -a 256 > "$EVIDENCE_DIR/SHA256SUMS" 2>/dev/null || true
  return "$result"
}
trap cleanup EXIT

[[ "$PROTOCOL_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || fail "invalid wall-clock budget"
[[ "$BUILD_FIRST" == 0 || "$BUILD_FIRST" == 1 ]] || fail "BUILD_FIRST must be 0 or 1"
for command_name in xcrun xcodebuild jq shasum; do
  command -v "$command_name" >/dev/null 2>&1 || fail "missing required tool: $command_name"
done
[[ -f "$TOOLCHAIN_SELECTOR" ]] || fail "missing Xcode 27 selector"
[[ -f "$CANDIDATE_MANIFEST" ]] || fail "missing Power candidate manifest"
[[ "$(shasum -a 256 "$CANDIDATE_MANIFEST" | awk '{print $1}')" == "$CANDIDATE_MANIFEST_SHA256" ]] ||
  fail "Power candidate manifest hash mismatch"
jq -e --arg key "$POWER_VARIANT" --arg id "$MODEL_ID" \
  --arg quantization "$MODEL_QUANTIZATION" --arg filename "$MODEL_FILENAME" \
  --arg sha "$MODEL_SHA256" --argjson bytes "$MODEL_BYTES" '
    .runtime_policy.lan_fallback == "forbidden" and
    .runtime_policy.resident_budget_bytes == 1500000000 and
    any(.candidates[];
      .key == $key and .catalog_id == $id and
      .quantization == $quantization and .filename == $filename and
      .sha256 == $sha and .bytes == $bytes)
  ' "$CANDIDATE_MANIFEST" >/dev/null || fail "selected Power candidate is not pinned exactly"
source "$TOOLCHAIN_SELECTOR" | tee "$EVIDENCE_DIR/xcode27-toolchain.txt"

[[ -f "$MODEL_PATH" ]] || fail "pinned $MODEL_QUANTIZATION artifact is unavailable at $MODEL_PATH"
[[ "$(stat -f '%z' "$MODEL_PATH")" == "$MODEL_BYTES" ]] || fail "model byte count mismatch"
[[ "$(shasum -a 256 "$MODEL_PATH" | awk '{print $1}')" == "$MODEL_SHA256" ]] ||
  fail "model SHA-256 mismatch"

xcrun devicectl list devices --timeout "$DEVICE_COMMAND_TIMEOUT_SECONDS" \
  > "$EVIDENCE_DIR/device-list.txt" 2>&1 || fail "CoreDevice could not list devices"
grep -F -- "$DEVICE_ID" "$EVIDENCE_DIR/device-list.txt" | \
  grep -Eq '[[:space:]]available([[:space:]]|\()' ||
  fail "the exact iPhone 12 is remembered but not currently available"
xcrun devicectl device info details --device "$DEVICE_ID" \
  --timeout "$DEVICE_COMMAND_TIMEOUT_SECONDS" \
  > "$EVIDENCE_DIR/device-details.txt" 2>&1 || fail "the exact iPhone 12 is not reachable"

if [[ "$BUILD_FIRST" == 1 ]]; then
  build_budget="$(remaining)"
  (( build_budget > 0 )) || fail "wall-clock budget expired before build"
  (( build_budget > 1200 )) && build_budget=1200
  "$TIMEOUT_RUNNER" "$build_budget" "$EVIDENCE_DIR/xcode27-device-build.log" \
    xcodebuild -project "$ROOT_DIR/AgentPad.xcodeproj" -scheme AgentPad \
      -configuration Debug -destination "id=$DEVICE_UDID" \
      -derivedDataPath "$DERIVED_DATA" build
fi
[[ -d "$APP_PATH" ]] || fail "Xcode 27 NovaForge.app is unavailable"
app_sdk="$(/usr/bin/plutil -extract DTSDKName raw "$APP_PATH/Info.plist" 2>/dev/null || true)"
[[ "$app_sdk" == iphoneos27.* ]] || fail "app was not built with the iOS 27 SDK"

xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH" \
  --timeout 180 --json-output "$EVIDENCE_DIR/install.json" \
  --log-output "$EVIDENCE_DIR/install.log"
copy_budget="$(remaining)"
(( copy_budget > 0 )) || fail "wall-clock budget expired before model copy"
(( copy_budget > 1200 )) && copy_budget=1200
"$TIMEOUT_RUNNER" "$copy_budget" "$EVIDENCE_DIR/model-copy-outer.log" \
  xcrun devicectl device copy to --device "$DEVICE_ID" \
    --source "$MODEL_PATH" \
    --destination "Library/Application Support/LocalModels/$MODEL_FILENAME" \
    --domain-type appDataContainer --domain-identifier "$APP_BUNDLE_ID" \
    --timeout "$copy_budget" --json-output "$EVIDENCE_DIR/model-copy.json" \
    --log-output "$EVIDENCE_DIR/model-copy.log"

copy_from_app() {
  local source="$1" destination="$2" label="$3"
  while (( $(remaining) > 0 )); do
    if xcrun devicectl device copy from --device "$DEVICE_ID" \
      --source "$source" --destination "$destination" \
      --domain-type appDataContainer --domain-identifier "$APP_BUNDLE_ID" \
      --timeout "$DEVICE_COMMAND_TIMEOUT_SECONDS" \
      --json-output "$EVIDENCE_DIR/copy-$label.json" \
      --log-output "$EVIDENCE_DIR/copy-$label.log" >/dev/null 2>&1; then
      return 0
    fi
    sleep "$POLL_SECONDS"
  done
  return 1
}

xcrun devicectl device process launch --device "$DEVICE_ID" --terminate-existing \
  --activate "$APP_BUNDLE_ID" --local-out-of-core-storage-benchmark \
  --local-benchmark-model-id="$MODEL_ID" \
  --timeout "$DEVICE_COMMAND_TIMEOUT_SECONDS" \
  --json-output "$EVIDENCE_DIR/launch-storage.json" \
  --log-output "$EVIDENCE_DIR/launch-storage.log"
copy_from_app \
  "Library/Application Support/LocalAI/OutOfCore/storage-benchmark-latest.json" \
  "$EVIDENCE_DIR/storage-benchmark.json" storage || fail "storage benchmark receipt timed out"
jq -e --arg model "$MODEL_ID" '
  .modelID == $model and .storageLocation == "internal-app-container" and
  .uncachedSequentialMBps > 0 and .randomMBps > 0 and
  .peakPhysicalFootprintBytes > 0 and
  (.thermalAfter == "nominal" or .thermalAfter == "fair")
' "$EVIDENCE_DIR/storage-benchmark.json" >/dev/null || fail "storage benchmark gates failed"

for profile in cpu partial-metal full-metal; do
  run_id="$RUN_STAMP-$profile"
  proof="$EVIDENCE_DIR/benchmark-$profile.json"
  rm -f "$proof"
  xcrun devicectl device process launch --device "$DEVICE_ID" --terminate-existing \
    --activate "$APP_BUNDLE_ID" --local-benchmark-proof \
    --local-power-admission-experiment \
    --local-benchmark-model-id="$MODEL_ID" \
    --local-benchmark-run-id="$run_id" --local-llama-profile="$profile" \
    --local-thermal-iterations=1 --timeout "$DEVICE_COMMAND_TIMEOUT_SECONDS" \
    --json-output "$EVIDENCE_DIR/launch-$profile.json" \
    --log-output "$EVIDENCE_DIR/launch-$profile.log"
  copy_from_app "Library/Application Support/LocalAI/PhysicalProtocol/$profile.json" \
    "$proof" "$profile" || fail "$profile generation receipt timed out or the app was killed"
  jq -e --arg run "$run_id" --arg model "$MODEL_ID" \
    --arg revision "$MODEL_REVISION" --arg sha "$MODEL_SHA256" '
    .status == "passed" and .run_id == $run and .model_id == $model and
    .immutable_revision == $revision and .model_sha256 == $sha and
    .useful_tokens >= 128 and
    .cold.ttft_seconds > 0 and .warm.ttft_seconds > 0 and
    .cold.generated_tokens >= 128 and .warm.generated_tokens >= 128 and
    .cold.peak_physical_footprint_bytes > 0 and
    .warm.peak_physical_footprint_bytes > 0 and
    (.cold.thermal_after == "nominal" or .cold.thermal_after == "fair") and
    (.warm.thermal_after == "nominal" or .warm.thermal_after == "fair")
  ' "$proof" >/dev/null || fail "$profile did not meet TTFT/token/memory/thermal gates"

  copy_from_app "Library/Application Support/LocalAI/OutOfCore/latest.json" \
    "$EVIDENCE_DIR/out-of-core-$profile.json" "out-of-core-$profile" ||
    fail "$profile did not emit staged-weight telemetry"
  jq -e '.residentBudgetBytes == 1500000000 and .stageCount > 0 and
    .advisedReadBytes > 0 and .advisedEvictionBytes > 0 and .decodeCount > 0' \
    "$EVIDENCE_DIR/out-of-core-$profile.json" >/dev/null ||
    fail "$profile staged-weight telemetry is incomplete"

  xcrun devicectl device process launch --device "$DEVICE_ID" --activate \
    com.apple.mobilesafari --timeout "$DEVICE_COMMAND_TIMEOUT_SECONDS" \
    --json-output "$EVIDENCE_DIR/background-$profile.json" \
    --log-output "$EVIDENCE_DIR/background-$profile.log" >/dev/null
  sleep 2
done

STATUS=passed
FAILURE_REASON=""
echo "Qwen3.8-27B $MODEL_QUANTIZATION staged-weight physical admission passed: $EVIDENCE_DIR"
