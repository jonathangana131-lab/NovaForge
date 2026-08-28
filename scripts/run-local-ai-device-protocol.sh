#!/usr/bin/env bash
set -euo pipefail

# Unattended, fail-closed iPhone 12 evidence runner. Missing device/tool/receipt
# evidence is recorded as unavailable or failed and exits non-zero.

ROOT_DIR="$(cd "$(dirname "$BASH_SOURCE")/.." && pwd)"
DEVICE_ID="${DEVICE_ID:-A9CFDD8D-E5B9-5B93-917A-513357EAD81E}"
DEVICE_UDID="${DEVICE_UDID:-00008101-000D05022061401E}"
APP_BUNDLE_ID="${APP_BUNDLE_ID:-com.joey.NovaForge}"
MODEL_ID="Qwen/Qwen2.5-Coder-1.5B-Instruct-Q4_K_M"
MODEL_REVISION="f86cb2c1fa58255f8052cc32aeede1b7482d4361"
MODEL_SHA256="cc324af070c2ecbfd324a30884d2f951a7ff756aba85cb811a6ec436933bb046"
CORPUS_SHA256="75fd1e718c227ee71f350c336522074a0dc66d56b144a1eed028c79cc35519e4"
EXPECTED_DEVICE_MODEL="iPhone13,2"
CORPUS_PATH="${CORPUS_PATH:-$ROOT_DIR/AgentPad/Resources/LocalAI2Corpus.v1.json}"
RUN_STAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
EVIDENCE_DIR="${EVIDENCE_DIR:-$ROOT_DIR/QA/local-ai2-physical-$RUN_STAMP}"
PROTOCOL_TIMEOUT_SECONDS="${PROTOCOL_TIMEOUT_SECONDS:-2700}"
POLL_SECONDS="${POLL_SECONDS:-5}"
DEVICE_COMMAND_TIMEOUT_SECONDS="${DEVICE_COMMAND_TIMEOUT_SECONDS:-30}"
THERMAL_SOAK_SECONDS="${THERMAL_SOAK_SECONDS:-180}"
MIN_USEFUL_TOKENS="${MIN_USEFUL_TOKENS:-128}"
INSTALL_SCRIPT="$ROOT_DIR/scripts/install_q2_on_iphone.sh"
APP_MANIFEST_HELPER="$ROOT_DIR/scripts/codex-app-bundle-manifest.sh"
TIMEOUT_RUNNER="$ROOT_DIR/scripts/codex-timeout-runner.pl"
TOOLCHAIN_SELECTOR="$ROOT_DIR/scripts/select-xcode27.sh"
APP_PATH="${APP_PATH:-/tmp/NovaForgeMetalDeviceDerivedData/Build/Products/Debug-iphoneos/NovaForge.app}"
DEVICE_DERIVED_DATA="${DEVICE_DERIVED_DATA:-/tmp/NovaForgeMetalDeviceDerivedData}"
BUILD_FIRST="${BUILD_FIRST:-1}"
MODEL_PATH="${MODEL_PATH:-/tmp/novaforge-models/qwen2.5-coder-1.5b-instruct-q4_k_m.gguf}"
PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 2>/dev/null || true)}"
APP_MANIFEST_SHA256=null
MODEL_BYTES=null
XCODE_VERSION=null
IOS_SDK_VERSION=null
SUMMARY_PATH="$EVIDENCE_DIR/physical-protocol-receipt.json"
MANIFEST_PATH="$EVIDENCE_DIR/evidence-manifest.json"
DEVICE_READY=0
BACKGROUND_APP_BUNDLE_ID=""
PROTOCOL_STATUS=running
PROTOCOL_FAILURE_REASON=""
DEADLINE=0
mkdir -p "$EVIDENCE_DIR"

die() { PROTOCOL_STATUS=failed; PROTOCOL_FAILURE_REASON="$1"; echo "Physical Local AI protocol failed: $1" >&2; exit 1; }
positive() { [[ "$2" =~ ^[1-9][0-9]*$ ]] || die "$1 must be positive: $2"; }
nonnegative() { [[ "$2" =~ ^[0-9]+$ ]] || die "$1 must be non-negative: $2"; }

now() { date +%s; }
set_deadline() { DEADLINE=$(( $(now) + PROTOCOL_TIMEOUT_SECONDS )); }
budget() { (( $(now) < DEADLINE )) || die "protocol wall-clock budget expired"; }
wait_bounded() {
  local seconds="$1" remaining=$(( DEADLINE - $(now) ))
  (( remaining > 0 )) || die "protocol wall-clock budget expired while waiting"
  (( seconds > remaining )) && seconds="$remaining"
  (( seconds > 0 )) && sleep "$seconds"
}
sha256_file() { printf 'sha256:%s\n' "$(/usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}')"; }
if SOURCE_COMMIT="$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null)" &&
   source_diff_digest="$(git -C "$ROOT_DIR" diff --no-ext-diff --binary HEAD 2>/dev/null | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"; then
  SOURCE_DIFF_SHA256="sha256:$source_diff_digest"
else
  SOURCE_COMMIT=unavailable
  SOURCE_DIFF_SHA256=unavailable
fi

write_receipt() {
  local status="$1" klass="$2" availability="$3" reason="$4" claims=false
  [[ "$status" == passed && "$klass" == physical && "$availability" == verified ]] && claims=true
  jq -n --arg status "$status" --arg klass "$klass" --arg availability "$availability" \
    --arg reason "$reason" --arg source "$SOURCE_COMMIT" --arg diff "$SOURCE_DIFF_SHA256" \
    --arg device "$DEVICE_ID" --arg expected_device_model "$EXPECTED_DEVICE_MODEL" \
    --arg model_id "$MODEL_ID" --arg model_revision "$MODEL_REVISION" \
    --arg model "$MODEL_SHA256" --arg corpus "$CORPUS_SHA256" \
    --arg run "$RUN_STAMP" --argjson claims "$claims" --arg evidence "$EVIDENCE_DIR" \
    --arg app_manifest "$APP_MANIFEST_SHA256" --argjson model_bytes "$MODEL_BYTES" \
    --arg xcode "$XCODE_VERSION" --arg sdk "$IOS_SDK_VERSION" '{
      schemaVersion: 2, receiptKind: "local_ai_benchmark", receiptID: ("physical-protocol-" + $run),
      runID: $run, recordedAt: (now | todateiso8601), executionClass: $klass,
      availability: $availability, unavailableReason: (if $reason == "" then null else $reason end), claimsAllowed: $claims,
      device: {rawModelIdentifier: (if $claims then $expected_device_model else null end), displayName: "configured iPhone 12 target", osDeviceIdentifier: $device,
               architecture: null, isSimulator: false, isPhysicalDevice: true},
      model: {id: $model_id, immutableRevision: $model_revision,
              quantization: "Q4_K_M", artifactSHA256: $model, artifactBytes: $model_bytes},
      operatingSystem: {name: "iOS", version: null, build: null},
      build: {sourceCommit: $source, sourceDiffSHA256: $diff, appVersion: null, buildNumber: null,
              configuration: "Debug", sdk: (if $sdk == "null" then null else $sdk end),
              xcode: (if $xcode == "null" then null else $xcode end),
              appSHA256: (if $app_manifest == "null" then null else $app_manifest end)},
      engine: {type: "llamaCpp", engineRevision: null, backend: null, wrapperRevision: null, executionLocation: "local"},
      generation: {contextTokens: null, maximumOutputTokens: null,
                   sampling: {temperature: 0, topP: 1, topK: 0, minP: 0, seed: 0, repetitionPenalty: null}},
      load: {cold: null, warm: null, postUnloadRecovery: null},
      performance: {promptTokensPerSecond: null, timeToFirstTokenSeconds: null, decodeTokensPerSecond: null,
                    usefulTokens: null, totalDurationSeconds: null},
      resources: {peakMemoryBytes: null, memoryCeilingBytes: null, thermalBefore: null, thermalAfter: null,
                  thermalMax: null, batteryImpact: null},
      lifecycle: {backgroundForeground: null, memoryWarning: null, unload: null, activeGenerationCountAfterRun: null},
      cancellation: {prefill: null, decode: null, leaseRelease: null, unload: null},
      quality: {corpusID: "LocalAI2Corpus.v1", corpusSHA256: $corpus, passedCaseCount: null,
                totalCaseCount: null, score: null, failureReasons: []},
      artifactHashes: {appSHA256: (if $app_manifest == "null" then null else $app_manifest end), modelSHA256: $model, corpusSHA256: $corpus, sourceCommit: $source,
                       logSHA256: null, traceSHA256: null},
      status: $status, failureReasons: (if $reason == "" then [] else [$reason] end),
      gates: {}, rawEvidenceDirectory: $evidence
    }' > "$SUMMARY_PATH"
}
write_manifest() {
  "$PYTHON_BIN" - "$EVIDENCE_DIR" "$MANIFEST_PATH" "$SOURCE_COMMIT" "$SOURCE_DIFF_SHA256" "$PROTOCOL_STATUS" "$PROTOCOL_FAILURE_REASON" <<'PY'
import hashlib, json, sys
from pathlib import Path
root, output, source, diff, status, reason = sys.argv[1:]
root = Path(root).resolve()
excluded = {Path(output).name, Path(output + ".tmp").name, Path(output).name.replace(".json", ".sha256")}
files = []
for path in sorted(root.rglob("*")):
    if path.is_file() and path.name not in excluded:
        files.append({"path": str(path.relative_to(root)), "bytes": path.stat().st_size,
                      "sha256": "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest()})
data = {"schemaVersion": 1, "status": status, "failureReason": reason or None,
        "sourceCommit": source, "sourceDiffSHA256": diff, "files": files}
tmp = output + ".tmp"
Path(tmp).write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
Path(tmp).replace(output)
Path(output.replace(".json", ".sha256")).write_text(
    "sha256:" + hashlib.sha256(Path(output).read_bytes()).hexdigest() + "  " + Path(output).name + "\n",
    encoding="utf-8")
PY
}
terminate() {
  local bundle="$1"
  [[ "$DEVICE_READY" == 1 && -n "$bundle" ]] || return 0
  xcrun devicectl device process terminate --device "$DEVICE_ID" "$bundle" \
    --timeout "$DEVICE_COMMAND_TIMEOUT_SECONDS" \
    --json-output "$EVIDENCE_DIR/cleanup-$(echo "$bundle" | tr '.' '-').json" \
    --log-output "$EVIDENCE_DIR/cleanup-$(echo "$bundle" | tr '.' '-').log" >/dev/null 2>&1 || true
}
cleanup() {
  local exit_status=$?
  # Cleanup runs from EXIT while the protocol uses `set -e`. Disable errexit
  # inside the trap so a best-effort termination or manifest refresh cannot
  # replace the protocol's deliberate unavailable/failed exit status.
  set +e
  if [[ "$DEVICE_READY" == 1 ]]; then
    terminate "$APP_BUNDLE_ID"
    terminate "$BACKGROUND_APP_BUNDLE_ID"
  fi
  if [[ "$PROTOCOL_STATUS" == running ]]; then
    PROTOCOL_STATUS=failed
    PROTOCOL_FAILURE_REASON="protocol exited before a terminal receipt was written"
    write_receipt failed physical partial "$PROTOCOL_FAILURE_REASON"
  elif [[ "$PROTOCOL_STATUS" == failed ]]; then
    write_receipt failed physical partial "$PROTOCOL_FAILURE_REASON"
  fi
  write_manifest
  return "$exit_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
unavailable() {
  PROTOCOL_STATUS=unavailable; PROTOCOL_FAILURE_REASON="$1"
  write_receipt unavailable unavailable unavailable "$PROTOCOL_FAILURE_REASON"
  # Persist the fail-closed bundle before exiting. EXIT traps are a final
  # safety net, but unavailable paths must not depend on trap semantics to
  # preserve the evidence explaining why no physical claim is allowed.
  write_manifest
  echo "Physical Local AI protocol unavailable: $PROTOCOL_FAILURE_REASON" >&2
  exit 2
}
for command_name in xcrun jq git; do
  command -v "$command_name" >/dev/null 2>&1 || unavailable "required tool is unavailable: $command_name"
done
[[ -n "$PYTHON_BIN" && -x "$PYTHON_BIN" ]] || unavailable "required tool is unavailable: python3"
for command_path in /usr/bin/plutil /usr/bin/shasum; do
  [[ -x "$command_path" ]] || unavailable "required tool is unavailable: $command_path"
done
[[ -f "$INSTALL_SCRIPT" ]] || unavailable "install helper is unavailable: $INSTALL_SCRIPT"
[[ -x "$APP_MANIFEST_HELPER" ]] || unavailable "app manifest helper is unavailable: $APP_MANIFEST_HELPER"
[[ -x "$TIMEOUT_RUNNER" ]] || unavailable "timeout runner is unavailable: $TIMEOUT_RUNNER"
[[ -f "$TOOLCHAIN_SELECTOR" ]] || unavailable "Xcode 27 selector is unavailable: $TOOLCHAIN_SELECTOR"
[[ -f "$CORPUS_PATH" ]] || unavailable "evaluation corpus is unavailable: $CORPUS_PATH"
[[ "$(sha256_file "$CORPUS_PATH")" == "sha256:$CORPUS_SHA256" ]] || unavailable "evaluation corpus hash mismatch"
positive PROTOCOL_TIMEOUT_SECONDS "$PROTOCOL_TIMEOUT_SECONDS"
nonnegative POLL_SECONDS "$POLL_SECONDS"
[[ "$BUILD_FIRST" == 0 || "$BUILD_FIRST" == 1 ]] || die "BUILD_FIRST must be 0 or 1"
positive DEVICE_COMMAND_TIMEOUT_SECONDS "$DEVICE_COMMAND_TIMEOUT_SECONDS"
positive THERMAL_SOAK_SECONDS "$THERMAL_SOAK_SECONDS"
positive MIN_USEFUL_TOKENS "$MIN_USEFUL_TOKENS"
(( THERMAL_SOAK_SECONDS <= 180 )) || die "THERMAL_SOAK_SECONDS cannot exceed 180"
set_deadline
budget

if ! source "$TOOLCHAIN_SELECTOR" > "$EVIDENCE_DIR/xcode27-toolchain.txt" 2>&1; then
  cat "$EVIDENCE_DIR/xcode27-toolchain.txt" >&2
  unavailable "Xcode 27 with the iOS 27 SDK is required for the iOS 27 physical-device protocol"
fi
cat "$EVIDENCE_DIR/xcode27-toolchain.txt"
XCODE_VERSION="$NOVAFORGE_XCODE_VERSION"
IOS_SDK_VERSION="$NOVAFORGE_IPHONEOS_SDK_VERSION"

xcrun devicectl list devices --timeout "$DEVICE_COMMAND_TIMEOUT_SECONDS" > "$EVIDENCE_DIR/device-list.txt" 2>&1 ||
  unavailable "CoreDevice could not list devices"
grep -Fq -- "$DEVICE_ID" "$EVIDENCE_DIR/device-list.txt" ||
  unavailable "exact iPhone target $DEVICE_ID is not known to CoreDevice"
grep -F -- "$DEVICE_ID" "$EVIDENCE_DIR/device-list.txt" | \
  grep -Eq '[[:space:]]available([[:space:]]|\()' ||
  unavailable "exact iPhone target $DEVICE_ID is remembered but not currently available"
xcrun devicectl device info details --device "$DEVICE_ID" --timeout "$DEVICE_COMMAND_TIMEOUT_SECONDS" \
  > "$EVIDENCE_DIR/device-details.txt" 2>&1 || unavailable "exact iPhone target $DEVICE_ID is listed but not reachable"
DEVICE_READY=1

if [[ "$BUILD_FIRST" == 1 ]]; then
  build_budget=$(( DEADLINE - $(now) ))
  (( build_budget > 0 )) || die "protocol wall-clock budget expired before the Xcode 27 device build"
  (( build_budget > 1200 )) && build_budget=1200
  TIMEOUT_RUNNER_LABEL=xcode27-physical-device-build \
    "$TIMEOUT_RUNNER" "$build_budget" "$EVIDENCE_DIR/xcode27-device-build.log" \
    xcodebuild -project "$ROOT_DIR/AgentPad.xcodeproj" -scheme AgentPad \
      -configuration Debug -destination "id=$DEVICE_UDID" \
      -derivedDataPath "$DEVICE_DERIVED_DATA" build
fi
[[ -d "$APP_PATH" ]] || unavailable "Xcode 27 NovaForge app is unavailable at $APP_PATH"
app_sdk_name="$(/usr/bin/plutil -extract DTSDKName raw "$APP_PATH/Info.plist" 2>/dev/null || true)"
app_xcode_build="$(/usr/bin/plutil -extract DTXcodeBuild raw "$APP_PATH/Info.plist" 2>/dev/null || true)"
[[ "$app_sdk_name" == iphoneos27.* ]] ||
  unavailable "NovaForge.app was not built with the iOS 27 SDK (observed ${app_sdk_name:-missing})"
printf 'app_sdk=%s\napp_xcode_build=%s\n' "$app_sdk_name" "${app_xcode_build:-missing}" \
  > "$EVIDENCE_DIR/app-toolchain.txt"

install_budget=$(( DEADLINE - $(now) ))
(( install_budget > 0 )) || die "protocol wall-clock budget expired before install"
TIMEOUT_RUNNER_LABEL=physical-local-ai-install \
  "$TIMEOUT_RUNNER" "$install_budget" "$EVIDENCE_DIR/install-helper.log" \
  env LOG_DIR="$EVIDENCE_DIR/install" DEVICE_ID="$DEVICE_ID" APP_BUNDLE_ID="$APP_BUNDLE_ID" \
    MODEL_PATH="$MODEL_PATH" APP_PATH="$APP_PATH" bash "$INSTALL_SCRIPT"
[[ -d "$APP_PATH" ]] || die "installed app bundle is missing: $APP_PATH"
APP_MANIFEST_SHA256="$("$APP_MANIFEST_HELPER" "$APP_PATH")"
MODEL_BYTES="$(stat -f '%z' "$MODEL_PATH" 2>/dev/null || printf null)"
[[ "$APP_MANIFEST_SHA256" =~ ^sha256:[0-9a-f]{64}$ ]] || die "app manifest hash is missing"
[[ "$MODEL_BYTES" =~ ^[0-9]+$ ]] || die "model byte count is missing"
if xcrun devicectl device process launch --device "$DEVICE_ID" --activate com.apple.mobilesafari \
  --timeout "$DEVICE_COMMAND_TIMEOUT_SECONDS" --json-output "$EVIDENCE_DIR/background-safari.json" \
  --log-output "$EVIDENCE_DIR/background-safari.log"; then
  BACKGROUND_APP_BUNDLE_ID=com.apple.mobilesafari
else
  xcrun devicectl device process launch --device "$DEVICE_ID" --activate com.apple.Preferences \
    --timeout "$DEVICE_COMMAND_TIMEOUT_SECONDS" --json-output "$EVIDENCE_DIR/background-settings.json" \
    --log-output "$EVIDENCE_DIR/background-settings.log"
  BACKGROUND_APP_BUNDLE_ID=com.apple.Preferences
fi
wait_bounded "$POLL_SECONDS"
xcrun devicectl device process launch --device "$DEVICE_ID" --activate "$APP_BUNDLE_ID" \
  --timeout "$DEVICE_COMMAND_TIMEOUT_SECONDS" --json-output "$EVIDENCE_DIR/foreground-novaforge.json" \
  --log-output "$EVIDENCE_DIR/foreground-novaforge.log"

copy_proof() {
  local profile="$1" run_id="$2" target="$EVIDENCE_DIR/benchmark-$1.json"
  rm -f "$target"
  while (( $(now) < DEADLINE )); do
    if xcrun devicectl device copy from --device "$DEVICE_ID" \
      --source "Library/Application Support/LocalAI/PhysicalProtocol/$profile.json" --destination "$target" \
      --domain-type appDataContainer --domain-identifier "$APP_BUNDLE_ID" \
      --timeout "$DEVICE_COMMAND_TIMEOUT_SECONDS" --json-output "$EVIDENCE_DIR/copy-$profile.json" \
      --log-output "$EVIDENCE_DIR/copy-$profile.log" >/dev/null 2>&1 &&
      [[ "$(jq -r '.run_id // empty' "$target" 2>/dev/null || true)" == "$run_id" ]] &&
      [[ "$(jq -r '.status // empty' "$target" 2>/dev/null || true)" != running ]]; then return 0; fi
    rm -f "$target"; wait_bounded "$POLL_SECONDS"
  done
  return 1
}
validate_proof() {
  local profile="$1" run_id="$2" proof="$EVIDENCE_DIR/benchmark-$1.json"
  [[ -s "$proof" ]] || die "missing benchmark receipt for $profile"
  jq -e --arg p "$profile" --arg r "$run_id" --arg model_id "$MODEL_ID" \
    --arg model_revision "$MODEL_REVISION" --arg m "$MODEL_SHA256" --arg c "$CORPUS_SHA256" \
    --argjson minimum "$MIN_USEFUL_TOKENS" --argjson soak "$THERMAL_SOAK_SECONDS" '
    def text: type == "string" and length > 0; def pos: type == "number" and . > 0;
    def nonneg: type == "number" and . >= 0; def thermal: type == "string" and (. == "nominal" or . == "fair");
    .status == "passed" and .execution_profile == $p and .run_id == $r and
    .model_id == $model_id and .immutable_revision == $model_revision and
    .model_sha256 == $m and .corpus_sha256 == $c and
    (.cold.receipt_id | text) and (.warm.receipt_id | text) and (.lifecycle_recovery | type == "array" and length > 0) and
    (.cold.ttft_seconds | pos) and (.warm.ttft_seconds | pos) and
    ((.useful_tokens // .usefulTokens // .generated_tokens // .cold.useful_tokens // .warm.useful_tokens // 0) | type == "number" and . >= $minimum) and
    ((.peak_memory_bytes // .peak_physical_footprint_bytes // .cold.peak_physical_footprint_bytes // .warm.peak_physical_footprint_bytes) | nonneg) and
    ((.memory_ceiling_bytes // .safe_process_ceiling_bytes) | pos) and
    ((.peak_memory_bytes // .peak_physical_footprint_bytes // .cold.peak_physical_footprint_bytes // .warm.peak_physical_footprint_bytes) <= (.memory_ceiling_bytes // .safe_process_ceiling_bytes)) and
    ([.thermal_before, .thermal_after, .thermal_max] | all(.[]; thermal)) and
    (.battery_impact.measurementStatus == "measured" or .battery_measurement_status == "measured") and
    ((.battery_impact.levelBefore // .battery_before) | type == "number" and . >= 0 and . <= 1) and
    ((.battery_impact.levelAfter // .battery_after) | type == "number" and . >= 0 and . <= 1) and
    (.lifecycle.background_foreground == "passed" or .lifecycle.backgroundForeground == "passed") and
    (.lifecycle.external_background_foreground == "passed" or .lifecycle.externalBackgroundForeground == "passed") and
    (.lifecycle.memory_warning == "passed" or .lifecycle.memoryWarning == "passed") and
    (.lifecycle_stimulus == "synthetic-memory-warning-and-background-notifications") and
    (.cancellation.prefill.status == "passed") and (.cancellation.decode.status == "passed") and
    (.cancellation.lease_release == "passed" or .cancellation.leaseRelease == "passed") and (.cancellation.unload == "passed") and
    ((.soak_limit_seconds // $soak) | type == "number" and . <= $soak)
  ' "$proof" >/dev/null || { echo "Benchmark receipt for $profile is incomplete or unsafe; no physical claim is allowed." >&2; /bin/cat "$proof" >&2; return 1; }
  /usr/bin/shasum -a 256 "$proof" > "$EVIDENCE_DIR/benchmark-$profile.sha256"
}
for profile in cpu partial-metal full-metal; do
  budget; run_id="$RUN_STAMP-$profile"; iterations=1
  [[ "$profile" == full-metal ]] && iterations=3
  xcrun devicectl device process launch --device "$DEVICE_ID" --terminate-existing --activate "$APP_BUNDLE_ID" \
    --local-benchmark-proof --local-benchmark-run-id="$run_id" --local-llama-profile="$profile" \
    --local-thermal-iterations="$iterations" --timeout "$DEVICE_COMMAND_TIMEOUT_SECONDS" \
    --json-output "$EVIDENCE_DIR/launch-$profile.json" --log-output "$EVIDENCE_DIR/launch-$profile.log"
  copy_proof "$profile" "$run_id" || die "benchmark proof timed out for $profile"
  validate_proof "$profile" "$run_id" || die "benchmark gates failed for $profile"
done

evaluation_run_id="$RUN_STAMP-evaluation"
evaluation_proof="$EVIDENCE_DIR/evaluation-corpus.json"
xcrun devicectl device process launch --device "$DEVICE_ID" --terminate-existing --activate "$APP_BUNDLE_ID" \
  --local-evaluation-corpus --local-evaluation-run-id="$evaluation_run_id" --local-llama-profile=full-metal \
  --timeout "$DEVICE_COMMAND_TIMEOUT_SECONDS" --json-output "$EVIDENCE_DIR/launch-evaluation.json" \
  --log-output "$EVIDENCE_DIR/launch-evaluation.log"
rm -f "$evaluation_proof"
while (( $(now) < DEADLINE )); do
  if xcrun devicectl device copy from --device "$DEVICE_ID" --source "Library/Application Support/LocalAI/EvaluationReceipts/latest.json" \
    --destination "$evaluation_proof" --domain-type appDataContainer --domain-identifier "$APP_BUNDLE_ID" \
    --timeout "$DEVICE_COMMAND_TIMEOUT_SECONDS" --json-output "$EVIDENCE_DIR/copy-evaluation.json" \
    --log-output "$EVIDENCE_DIR/copy-evaluation.log" >/dev/null 2>&1 &&
    jq -e --arg r "$evaluation_run_id" --arg m "$MODEL_SHA256" --arg c "$CORPUS_SHA256" \
      '.runID == $r and .modelSHA256 == $m and .corpusSHA256 == $c' "$evaluation_proof" >/dev/null 2>&1; then break; fi
  rm -f "$evaluation_proof"; wait_bounded "$POLL_SECONDS"
done
[[ -s "$evaluation_proof" ]] || die "pinned evaluation corpus did not produce a receipt"
jq -e --arg model_id "$MODEL_ID" --arg model_revision "$MODEL_REVISION" \
  --arg m "$MODEL_SHA256" --arg c "$CORPUS_SHA256" \
  --arg device_model "$EXPECTED_DEVICE_MODEL" --argjson minimum "$MIN_USEFUL_TOKENS" '
  def measured_battery:
    (.batteryLevelBefore | type == "number" and . >= 0 and . <= 1) and
    (.batteryLevelAfter | type == "number" and . >= 0 and . <= 1);
  def safe_thermal:
    (.thermalStateBefore == "nominal" or .thermalStateBefore == "fair") and
    (.thermalStateAfter == "nominal" or .thermalStateAfter == "fair");
  .modelID == $model_id and .immutableRevision == $model_revision and
  .modelSHA256 == $m and .corpusSHA256 == $c and
  .deviceIdentifier == $device_model and .isPhysicalDevice == true and
  .executionConfiguration == "full-metal" and
  .totalCaseCount == 19 and (.cases | length == 19) and
  .passedCaseCount == ([.cases[] | select(.passed)] | length) and
  (.score >= 0.7) and
  ([.cases[] | select(.category == "tool_selection" or .category == "tool_refusal") | .passed] | length > 0 and all) and
  ([.cases[] | select(.id == "performance-probe-cold-warm") |
    select(.passed and .generatedTokens >= $minimum)] | length == 1) and
  ([.cases[] | select((safe_thermal | not) or ((.peakPhysicalFootprintBytes | type) != "number") or .peakPhysicalFootprintBytes <= 0 or (measured_battery | not))] | length == 0)
  ' \
  "$evaluation_proof" >/dev/null || die "evaluation quality or tool-safety gate failed"
/usr/bin/shasum -a 256 "$evaluation_proof" > "$EVIDENCE_DIR/evaluation-corpus.sha256"

PROTOCOL_STATUS=passed
PROTOCOL_FAILURE_REASON=""
write_receipt passed physical verified ""
echo "Physical Local AI 2.0 protocol passed. Evidence: $EVIDENCE_DIR"
