#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
RUNNER="$ROOT_DIR/scripts/run-on-iphone.sh"
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/novaforge-phone-guard.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT

SOURCE_ROOT="$TMP_DIR/source"
BIN_DIR="$TMP_DIR/bin"
APP_PATH="$TMP_DIR/NovaForge.app"
SIMULATOR_APP_PATH="$TMP_DIR/NovaForgeSimulator.app"
PROVIDER_EVIDENCE_LOG="$TMP_DIR/provider-proof.log"
PROVIDER_EVIDENCE_SCREENSHOT="$TMP_DIR/provider-proof.png"
DEVICE_CALL_LOG="$TMP_DIR/device-calls.log"
AUDIT_CALL_LOG="$TMP_DIR/audit-calls.log"
HEAD_SHA="1111111111111111111111111111111111111111"
DEVICE_MANIFEST=""
SIMULATOR_MANIFEST=""
SIMULATOR_ID="4B9AB34A-404C-485F-B0BC-964F24D0AE83"
FAKE_GIT_DIRTY_FILE="$TMP_DIR/fake-git-dirty"
MUTATION_MARKER="$TMP_DIR/device-wait-mutated"
VERIFIED_AT_UTC="$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"
VERIFIED_AT_LOCAL="$(/bin/date '+%Y-%m-%d %H:%M:%S.000')"
FUTURE_AT_UTC="$(/usr/bin/python3 - <<'PY'
from datetime import datetime, timedelta, timezone

future = datetime.now(timezone.utc) + timedelta(hours=1)
print(future.strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
)"

mkdir -p "$SOURCE_ROOT/QA" "$SOURCE_ROOT/scripts" "$BIN_DIR" "$APP_PATH" "$SIMULATOR_APP_PATH"
SOURCE_ROOT="$(cd "$SOURCE_ROOT" && pwd)"
BIN_DIR="$(cd "$BIN_DIR" && pwd)"
APP_PATH="$(cd "$APP_PATH" && pwd)"
SIMULATOR_APP_PATH="$(cd "$SIMULATOR_APP_PATH" && pwd)"
RELATIVE_SOURCE_ROOT="$(/usr/bin/python3 - "$SOURCE_ROOT" "$(pwd -P)" <<'PY'
import os
import sys

print(os.path.relpath(sys.argv[1], start=sys.argv[2]))
PY
)"
/usr/bin/plutil -create xml1 "$APP_PATH/Info.plist"
/usr/bin/plutil -insert CFBundleIdentifier -string com.joey.NovaForge "$APP_PATH/Info.plist"
/usr/bin/plutil -insert CFBundleShortVersionString -string 1.0 "$APP_PATH/Info.plist"
/usr/bin/plutil -insert CFBundleVersion -string 3 "$APP_PATH/Info.plist"
/usr/bin/plutil -insert NovaForgeSourceCommit -string "$HEAD_SHA" "$APP_PATH/Info.plist"
/usr/bin/plutil -insert CFBundleExecutable -string NovaForge "$APP_PATH/Info.plist"
/usr/bin/plutil -insert CFBundleSupportedPlatforms -array "$APP_PATH/Info.plist"
/usr/bin/plutil -insert CFBundleSupportedPlatforms.0 -string iPhoneOS "$APP_PATH/Info.plist"
: > "$APP_PATH/NovaForge"
DEVICE_MANIFEST="sha256:$(/usr/bin/shasum -a 256 "$APP_PATH/NovaForge" | /usr/bin/awk '{print $1}')"

/usr/bin/plutil -create xml1 "$SIMULATOR_APP_PATH/Info.plist"
/usr/bin/plutil -insert CFBundleIdentifier -string com.joey.NovaForge "$SIMULATOR_APP_PATH/Info.plist"
/usr/bin/plutil -insert CFBundleShortVersionString -string 1.0 "$SIMULATOR_APP_PATH/Info.plist"
/usr/bin/plutil -insert CFBundleVersion -string 3 "$SIMULATOR_APP_PATH/Info.plist"
/usr/bin/plutil -insert NovaForgeSourceCommit -string "$HEAD_SHA" "$SIMULATOR_APP_PATH/Info.plist"
/usr/bin/plutil -insert CFBundleExecutable -string NovaForge "$SIMULATOR_APP_PATH/Info.plist"
/usr/bin/plutil -insert CFBundleSupportedPlatforms -array "$SIMULATOR_APP_PATH/Info.plist"
/usr/bin/plutil -insert CFBundleSupportedPlatforms.0 -string iPhoneSimulator "$SIMULATOR_APP_PATH/Info.plist"
: > "$SIMULATOR_APP_PATH/NovaForge"
printf '%s\n' \
  'provider completed with NF_SIMULATOR_PROOF_3' \
  "Test Case '-[AgentPadUITests.AgentPadUITests testSimulatorAnonymousZenProviderCanaryCompletesAndPersists]' passed (1.000 seconds)." \
  "Test Suite 'Selected tests' passed at $VERIFIED_AT_LOCAL." \
  $'\t Executed 1 test, with 0 failures (0 unexpected) in 1.000 (1.000) seconds' \
  > "$PROVIDER_EVIDENCE_LOG"
printf 'not-a-real-png-but-stable-proof-bytes\n' > "$PROVIDER_EVIDENCE_SCREENSHOT"
SIMULATOR_MANIFEST="$(/bin/bash "$ROOT_DIR/scripts/codex-app-bundle-manifest.sh" "$SIMULATOR_APP_PATH")"

cat > "$BIN_DIR/git-stub" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
  *" rev-parse HEAD "*)
    printf '%s\n' "${FAKE_GIT_HEAD:?}"
    ;;
  *" diff "*)
    if [[ "${FAKE_GIT_DIRTY:-0}" == "1" ||
          ( -n "${FAKE_GIT_DIRTY_FILE:-}" && -f "$FAKE_GIT_DIRTY_FILE" ) ]]; then
      exit 1
    fi
    exit 0
    ;;
  *" ls-files --others --exclude-standard "*)
    if [[ "${FAKE_GIT_UNTRACKED_COMPILED:-0}" == "1" ]]; then
      echo "AgentPad/UntrackedCompiled.swift"
    fi
    ;;
  *)
    echo "unexpected git-stub invocation: $*" >&2
    exit 90
    ;;
esac
STUB

cat > "$SOURCE_ROOT/scripts/codex-release-candidate-audit.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$1" >> "${AUDIT_CALL_LOG:?}"
candidate_manifest="sha256:$(/usr/bin/shasum -a 256 "$1/NovaForge" | /usr/bin/awk '{print $1}')"
cat <<JSON
{
  "schemaVersion": 1,
  "status": "pass",
  "bundleID": "com.joey.NovaForge",
  "teamID": "93MYZUV85K",
  "platform": "iPhoneOS",
  "candidateManifestSHA256": "$candidate_manifest"
}
JSON
STUB

cat > "$BIN_DIR/xcrun" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${DEVICE_CALL_LOG:?}"
if [[ "$*" == "devicectl list devices"* && ! -f "${MUTATION_MARKER:?}" ]]; then
  : > "$MUTATION_MARKER"
  if [[ "${MUTATE_SOURCE_ON_DEVICE_WAIT:-0}" == "1" ]]; then
    : > "${FAKE_GIT_DIRTY_FILE:?}"
  fi
  if [[ "${MUTATE_CANDIDATE_ON_DEVICE_WAIT:-0}" == "1" ]]; then
    printf 'changed-after-initial-audit\n' >> "${CANDIDATE_EXECUTABLE:?}"
  fi
  if [[ "${MUTATE_SIMULATOR_APP_ON_DEVICE_WAIT:-0}" == "1" ]]; then
    printf 'changed-after-initial-proof\n' >> "${SIMULATOR_EXECUTABLE:?}"
  fi
  if [[ "${MUTATE_EVIDENCE_LOG_ON_DEVICE_WAIT:-0}" == "1" ]]; then
    printf 'changed-after-initial-proof\n' >> "${PROVIDER_EVIDENCE_LOG:?}"
  fi
  if [[ "${MUTATE_EVIDENCE_SCREENSHOT_ON_DEVICE_WAIT:-0}" == "1" ]]; then
    printf 'changed-after-initial-proof\n' >> "${PROVIDER_EVIDENCE_SCREENSHOT:?}"
  fi
  if [[ "${STALE_RECEIPT_ON_DEVICE_WAIT:-0}" == "1" ]]; then
    /usr/bin/python3 - "${SIMULATOR_PROOF_RECEIPT:?}" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as handle:
    receipt = json.load(handle)
receipt["verifiedAtUTC"] = "2000-01-01T00:00:00Z"
with open(path, "w", encoding="utf-8") as handle:
    json.dump(receipt, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
  fi
fi
case "$*" in
  "devicectl list devices"*)
    echo "Joey iPhone A9CFDD8D-E5B9-5B93-917A-513357EAD81E connected"
    ;;
  "devicectl device info details"*)
    echo "tunnelState: connected"
    echo "ddiServicesAvailable: true"
    ;;
  "xcdevice list"*)
    echo "[]"
    ;;
  "devicectl device info processes"*)
    echo "NovaForge com.joey.NovaForge"
    ;;
esac
STUB

cat > "$BIN_DIR/system_profiler" <<'STUB'
#!/usr/bin/env bash
echo "Apple Mobile Device"
STUB

cat > "$BIN_DIR/sleep" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB

chmod +x \
  "$BIN_DIR/git-stub" \
  "$SOURCE_ROOT/scripts/codex-release-candidate-audit.sh" \
  "$BIN_DIR/xcrun" \
  "$BIN_DIR/system_profiler" \
  "$BIN_DIR/sleep"

write_receipt() {
  local path="$1"
  local source_commit="$2"
  local build_version="$3"
  local device_manifest="$4"
  local verified_at="$5"
  local simulator_manifest="${6:-$SIMULATOR_MANIFEST}"
  local evidence_log_manifest evidence_screenshot_manifest
  evidence_log_manifest="sha256:$(/usr/bin/shasum -a 256 "$PROVIDER_EVIDENCE_LOG" | /usr/bin/awk '{print $1}')"
  evidence_screenshot_manifest="sha256:$(/usr/bin/shasum -a 256 "$PROVIDER_EVIDENCE_SCREENSHOT" | /usr/bin/awk '{print $1}')"
  cat > "$path" <<JSON
{
  "schemaVersion": 2,
  "status": "pass",
  "proofKind": "novaforge-live-provider-simulator-v2",
  "sourceCommit": "$source_commit",
  "bundleID": "com.joey.NovaForge",
  "appMarketingVersion": "1.0",
  "appBuildVersion": "$build_version",
  "simulatorID": "$SIMULATOR_ID",
  "simulatorPlatform": "iOS Simulator",
  "simulatorAppPath": "$SIMULATOR_APP_PATH",
  "simulatorAppManifestSHA256": "$simulator_manifest",
  "deviceCandidateManifestSHA256": "$device_manifest",
  "providerID": "openCodeZen",
  "responseMarker": "NF_SIMULATOR_PROOF_3",
  "providerTestIdentifier": "AgentPadUITests.AgentPadUITests/testSimulatorAnonymousZenProviderCanaryCompletesAndPersists",
  "providerEvidenceLogPath": "$PROVIDER_EVIDENCE_LOG",
  "providerEvidenceLogSHA256": "$evidence_log_manifest",
  "providerEvidenceScreenshotPath": "$PROVIDER_EVIDENCE_SCREENSHOT",
  "providerEvidenceScreenshotSHA256": "$evidence_screenshot_manifest",
  "verifiedAtUTC": "$verified_at"
}
JSON
}

VALID_RECEIPT="$TMP_DIR/valid-receipt.json"
WRONG_COMMIT_RECEIPT="$TMP_DIR/wrong-commit-receipt.json"
WRONG_BUILD_RECEIPT="$TMP_DIR/wrong-build-receipt.json"
WRONG_MANIFEST_RECEIPT="$TMP_DIR/wrong-manifest-receipt.json"
WRONG_SIMULATOR_MANIFEST_RECEIPT="$TMP_DIR/wrong-simulator-manifest-receipt.json"
STALE_RECEIPT="$TMP_DIR/stale-receipt.json"
FUTURE_RECEIPT="$TMP_DIR/future-receipt.json"
write_receipt "$VALID_RECEIPT" "$HEAD_SHA" 3 "$DEVICE_MANIFEST" "$VERIFIED_AT_UTC"
write_receipt "$WRONG_COMMIT_RECEIPT" "2222222222222222222222222222222222222222" 3 "$DEVICE_MANIFEST" "$VERIFIED_AT_UTC"
write_receipt "$WRONG_BUILD_RECEIPT" "$HEAD_SHA" 2 "$DEVICE_MANIFEST" "$VERIFIED_AT_UTC"
write_receipt "$WRONG_MANIFEST_RECEIPT" "$HEAD_SHA" 3 "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc" "$VERIFIED_AT_UTC"
write_receipt "$WRONG_SIMULATOR_MANIFEST_RECEIPT" "$HEAD_SHA" 3 "$DEVICE_MANIFEST" "$VERIFIED_AT_UTC" "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
write_receipt "$STALE_RECEIPT" "$HEAD_SHA" 3 "$DEVICE_MANIFEST" "2000-01-01T00:00:00Z"
write_receipt "$FUTURE_RECEIPT" "$HEAD_SHA" 3 "$DEVICE_MANIFEST" "$FUTURE_AT_UTC"

GENERATED_RECEIPT="$TMP_DIR/generated-receipt.json"
env \
  SOURCE_ROOT="$SOURCE_ROOT" \
  GIT_BIN="$BIN_DIR/git-stub" \
  FAKE_GIT_HEAD="$HEAD_SHA" \
  FAKE_GIT_DIRTY_FILE="$FAKE_GIT_DIRTY_FILE" \
  FAKE_GIT_UNTRACKED_COMPILED=0 \
  RELEASE_AUDIT="$SOURCE_ROOT/scripts/codex-release-candidate-audit.sh" \
  APP_BUNDLE_MANIFEST="$ROOT_DIR/scripts/codex-app-bundle-manifest.sh" \
  SIMULATOR_APP_PATH="$SIMULATOR_APP_PATH" \
  DEVICE_CANDIDATE_APP_PATH="$APP_PATH" \
  PROVIDER_EVIDENCE_LOG="$PROVIDER_EVIDENCE_LOG" \
  PROVIDER_EVIDENCE_SCREENSHOT="$PROVIDER_EVIDENCE_SCREENSHOT" \
  PROVIDER_ID=openCodeZen \
  RESPONSE_MARKER=NF_SIMULATOR_PROOF_3 \
  PROVIDER_TEST_IDENTIFIER=AgentPadUITests.AgentPadUITests/testSimulatorAnonymousZenProviderCanaryCompletesAndPersists \
  SIMULATOR_ID="$SIMULATOR_ID" \
  OUT_RECEIPT="$GENERATED_RECEIPT" \
  AUDIT_CALL_LOG="$AUDIT_CALL_LOG" \
  /bin/bash "$ROOT_DIR/scripts/create-simulator-proof-receipt.sh" >/dev/null
[[ "$(/usr/bin/plutil -extract schemaVersion raw "$GENERATED_RECEIPT")" == "2" ]]
[[ "$(/usr/bin/plutil -extract sourceCommit raw "$GENERATED_RECEIPT")" == "$HEAD_SHA" ]]
[[ "$(/usr/bin/plutil -extract simulatorAppManifestSHA256 raw "$GENERATED_RECEIPT")" == "$SIMULATOR_MANIFEST" ]]
[[ "$(/usr/bin/plutil -extract deviceCandidateManifestSHA256 raw "$GENERATED_RECEIPT")" == "$DEVICE_MANIFEST" ]]
[[ "$(stat -f '%Lp' "$GENERATED_RECEIPT")" == "600" ]]

STALE_GENERATOR_LOG="$TMP_DIR/stale-generator-provider-proof.log"
STALE_GENERATED_RECEIPT="$TMP_DIR/stale-generated-receipt.json"
printf '%s\n' \
  'provider completed with NF_SIMULATOR_PROOF_3' \
  "Test Case '-[AgentPadUITests.AgentPadUITests testSimulatorAnonymousZenProviderCanaryCompletesAndPersists]' passed (1.000 seconds)." \
  "Test Suite 'Selected tests' passed at 2000-01-01 00:00:00.000." \
  $'\t Executed 1 test, with 0 failures (0 unexpected) in 1.000 (1.000) seconds' \
  > "$STALE_GENERATOR_LOG"
set +e
env \
  SOURCE_ROOT="$SOURCE_ROOT" \
  GIT_BIN="$BIN_DIR/git-stub" \
  FAKE_GIT_HEAD="$HEAD_SHA" \
  FAKE_GIT_DIRTY_FILE="$FAKE_GIT_DIRTY_FILE" \
  FAKE_GIT_UNTRACKED_COMPILED=0 \
  RELEASE_AUDIT="$SOURCE_ROOT/scripts/codex-release-candidate-audit.sh" \
  APP_BUNDLE_MANIFEST="$ROOT_DIR/scripts/codex-app-bundle-manifest.sh" \
  SIMULATOR_APP_PATH="$SIMULATOR_APP_PATH" \
  DEVICE_CANDIDATE_APP_PATH="$APP_PATH" \
  PROVIDER_EVIDENCE_LOG="$STALE_GENERATOR_LOG" \
  PROVIDER_EVIDENCE_SCREENSHOT="$PROVIDER_EVIDENCE_SCREENSHOT" \
  PROVIDER_ID=openCodeZen \
  RESPONSE_MARKER=NF_SIMULATOR_PROOF_3 \
  PROVIDER_TEST_IDENTIFIER=AgentPadUITests.AgentPadUITests/testSimulatorAnonymousZenProviderCanaryCompletesAndPersists \
  SIMULATOR_ID="$SIMULATOR_ID" \
  OUT_RECEIPT="$STALE_GENERATED_RECEIPT" \
  AUDIT_CALL_LOG="$AUDIT_CALL_LOG" \
  /bin/bash "$ROOT_DIR/scripts/create-simulator-proof-receipt.sh" >/dev/null 2>&1
generator_status=$?
set -e
[[ "$generator_status" == "65" ]]
[[ ! -e "$STALE_GENERATED_RECEIPT" ]]

run_case() {
  local name="$1"
  local expected_status="$2"
  shift 2
  local stdout_path="$TMP_DIR/$name.stdout"
  local stderr_path="$TMP_DIR/$name.stderr"
  local status=0
  set +e
  env \
    PATH="$BIN_DIR:$PATH" \
    SOURCE_ROOT="$SOURCE_ROOT" \
    GIT_BIN="$BIN_DIR/git-stub" \
    APP_BUNDLE_MANIFEST="$ROOT_DIR/scripts/codex-app-bundle-manifest.sh" \
    APP_PATH="$APP_PATH" \
    BUILD_FIRST=0 \
    CONFIGURATION=Release \
    BUNDLE_ID=com.joey.NovaForge \
    EXPECTED_SIMULATOR_ID="$SIMULATOR_ID" \
    FAKE_GIT_HEAD="$HEAD_SHA" \
    FAKE_GIT_DIRTY_FILE="$FAKE_GIT_DIRTY_FILE" \
    FAKE_GIT_UNTRACKED_COMPILED=0 \
    MUTATION_MARKER="$MUTATION_MARKER" \
    CANDIDATE_EXECUTABLE="$APP_PATH/NovaForge" \
    SIMULATOR_EXECUTABLE="$SIMULATOR_APP_PATH/NovaForge" \
    PROVIDER_EVIDENCE_LOG="$PROVIDER_EVIDENCE_LOG" \
    PROVIDER_EVIDENCE_SCREENSHOT="$PROVIDER_EVIDENCE_SCREENSHOT" \
    MUTATE_SOURCE_ON_DEVICE_WAIT=0 \
    MUTATE_CANDIDATE_ON_DEVICE_WAIT=0 \
    MUTATE_SIMULATOR_APP_ON_DEVICE_WAIT=0 \
    MUTATE_EVIDENCE_LOG_ON_DEVICE_WAIT=0 \
    MUTATE_EVIDENCE_SCREENSHOT_ON_DEVICE_WAIT=0 \
    STALE_RECEIPT_ON_DEVICE_WAIT=0 \
    DEVICE_CALL_LOG="$DEVICE_CALL_LOG" \
    AUDIT_CALL_LOG="$AUDIT_CALL_LOG" \
    WAIT_FOR_DEVICE=0 \
    MAX_ATTEMPTS=1 \
    SLEEP_SECONDS=0 \
    OUT_DIR="$TMP_DIR/out-$name" \
    "$@" \
    "$RUNNER" > "$stdout_path" 2> "$stderr_path"
  status=$?
  set -e
  if [[ "$status" != "$expected_status" ]]; then
    echo "case $name returned $status, expected $expected_status" >&2
    cat "$stdout_path" >&2
    cat "$stderr_path" >&2
    exit 1
  fi
}

assert_no_device_calls() {
  if [[ -s "$DEVICE_CALL_LOG" ]]; then
    echo "device command stub was invoked before the install guard passed:" >&2
    cat "$DEVICE_CALL_LOG" >&2
    exit 1
  fi
}

assert_no_install_calls() {
  if [[ -s "$DEVICE_CALL_LOG" ]] &&
     grep -Fq "devicectl device install app" "$DEVICE_CALL_LOG"; then
    echo "device installation started after a time-of-check mutation:" >&2
    cat "$DEVICE_CALL_LOG" >&2
    exit 1
  fi
}

reset_case_state() {
  rm -f \
    "$DEVICE_CALL_LOG" \
    "$AUDIT_CALL_LOG" \
    "$FAKE_GIT_DIRTY_FILE" \
    "$MUTATION_MARKER"
  : > "$APP_PATH/NovaForge"
  : > "$SIMULATOR_APP_PATH/NovaForge"
  printf '%s\n' \
    'provider completed with NF_SIMULATOR_PROOF_3' \
    "Test Case '-[AgentPadUITests.AgentPadUITests testSimulatorAnonymousZenProviderCanaryCompletesAndPersists]' passed (1.000 seconds)." \
    "Test Suite 'Selected tests' passed at $VERIFIED_AT_LOCAL." \
    $'\t Executed 1 test, with 0 failures (0 unexpected) in 1.000 (1.000) seconds' \
    > "$PROVIDER_EVIDENCE_LOG"
  printf 'not-a-real-png-but-stable-proof-bytes\n' > "$PROVIDER_EVIDENCE_SCREENSHOT"
  write_receipt "$VALID_RECEIPT" "$HEAD_SHA" 3 "$DEVICE_MANIFEST" "$VERIFIED_AT_UTC"
}

reset_case_state
run_case missing-opt-in 64 ALLOW_DEVICE_INSTALL=0 PREPARE_ONLY=0
assert_no_device_calls
[[ ! -s "$AUDIT_CALL_LOG" ]]

reset_case_state
run_case prepare-only 0 ALLOW_DEVICE_INSTALL=0 PREPARE_ONLY=1
assert_no_device_calls
grep -Fxq "$APP_PATH" "$AUDIT_CALL_LOG"

reset_case_state
run_case relative-source-root 0 \
  SOURCE_ROOT="$RELATIVE_SOURCE_ROOT" \
  ALLOW_DEVICE_INSTALL=0 PREPARE_ONLY=1
assert_no_device_calls
grep -Fxq "$APP_PATH" "$AUDIT_CALL_LOG"

reset_case_state
run_case missing-receipt 65 ALLOW_DEVICE_INSTALL=1 PREPARE_ONLY=0
assert_no_device_calls

reset_case_state
run_case dirty-source 65 \
  ALLOW_DEVICE_INSTALL=1 PREPARE_ONLY=0 \
  SIMULATOR_PROOF_RECEIPT="$VALID_RECEIPT" FAKE_GIT_DIRTY=1
assert_no_device_calls

reset_case_state
run_case untracked-compiled-source 65 \
  ALLOW_DEVICE_INSTALL=1 PREPARE_ONLY=0 \
  SIMULATOR_PROOF_RECEIPT="$VALID_RECEIPT" FAKE_GIT_UNTRACKED_COMPILED=1
assert_no_device_calls

reset_case_state
run_case wrong-commit 65 \
  ALLOW_DEVICE_INSTALL=1 PREPARE_ONLY=0 \
  SIMULATOR_PROOF_RECEIPT="$WRONG_COMMIT_RECEIPT"
assert_no_device_calls

reset_case_state
run_case wrong-build 65 \
  ALLOW_DEVICE_INSTALL=1 PREPARE_ONLY=0 \
  SIMULATOR_PROOF_RECEIPT="$WRONG_BUILD_RECEIPT"
assert_no_device_calls

reset_case_state
run_case wrong-manifest 65 \
  ALLOW_DEVICE_INSTALL=1 PREPARE_ONLY=0 \
  SIMULATOR_PROOF_RECEIPT="$WRONG_MANIFEST_RECEIPT"
assert_no_device_calls

reset_case_state
run_case wrong-simulator-manifest 65 \
  ALLOW_DEVICE_INSTALL=1 PREPARE_ONLY=0 \
  SIMULATOR_PROOF_RECEIPT="$WRONG_SIMULATOR_MANIFEST_RECEIPT"
assert_no_device_calls

reset_case_state
run_case stale-receipt 65 \
  ALLOW_DEVICE_INSTALL=1 PREPARE_ONLY=0 \
  SIMULATOR_PROOF_RECEIPT="$STALE_RECEIPT"
assert_no_device_calls

reset_case_state
run_case future-receipt 65 \
  ALLOW_DEVICE_INSTALL=1 PREPARE_ONLY=0 \
  SIMULATOR_PROOF_RECEIPT="$FUTURE_RECEIPT"
assert_no_device_calls

reset_case_state
run_case source-changed-during-wait 65 \
  ALLOW_DEVICE_INSTALL=1 PREPARE_ONLY=0 \
  SIMULATOR_PROOF_RECEIPT="$VALID_RECEIPT" \
  MUTATE_SOURCE_ON_DEVICE_WAIT=1
assert_no_install_calls

reset_case_state
run_case candidate-changed-during-wait 65 \
  ALLOW_DEVICE_INSTALL=1 PREPARE_ONLY=0 \
  SIMULATOR_PROOF_RECEIPT="$VALID_RECEIPT" \
  MUTATE_CANDIDATE_ON_DEVICE_WAIT=1
assert_no_install_calls
[[ "$(wc -l < "$AUDIT_CALL_LOG" | tr -d '[:space:]')" == "2" ]]

reset_case_state
run_case simulator-app-changed-during-wait 65 \
  ALLOW_DEVICE_INSTALL=1 PREPARE_ONLY=0 \
  SIMULATOR_PROOF_RECEIPT="$VALID_RECEIPT" \
  MUTATE_SIMULATOR_APP_ON_DEVICE_WAIT=1
assert_no_install_calls

reset_case_state
run_case evidence-log-changed-during-wait 65 \
  ALLOW_DEVICE_INSTALL=1 PREPARE_ONLY=0 \
  SIMULATOR_PROOF_RECEIPT="$VALID_RECEIPT" \
  MUTATE_EVIDENCE_LOG_ON_DEVICE_WAIT=1
assert_no_install_calls

reset_case_state
run_case evidence-screenshot-changed-during-wait 65 \
  ALLOW_DEVICE_INSTALL=1 PREPARE_ONLY=0 \
  SIMULATOR_PROOF_RECEIPT="$VALID_RECEIPT" \
  MUTATE_EVIDENCE_SCREENSHOT_ON_DEVICE_WAIT=1
assert_no_install_calls

reset_case_state
run_case receipt-staled-during-wait 65 \
  ALLOW_DEVICE_INSTALL=1 PREPARE_ONLY=0 \
  SIMULATOR_PROOF_RECEIPT="$VALID_RECEIPT" \
  STALE_RECEIPT_ON_DEVICE_WAIT=1
assert_no_install_calls
[[ "$(wc -l < "$AUDIT_CALL_LOG" | tr -d '[:space:]')" == "2" ]]

reset_case_state
run_case accepted 0 \
  ALLOW_DEVICE_INSTALL=1 PREPARE_ONLY=0 \
  SIMULATOR_PROOF_RECEIPT="$VALID_RECEIPT"
grep -Fq "devicectl device install app" "$DEVICE_CALL_LOG"
grep -Fq "devicectl device process launch" "$DEVICE_CALL_LOG"
[[ "$(wc -l < "$AUDIT_CALL_LOG" | tr -d '[:space:]')" == "2" ]]
if grep -Fq "simctl" "$DEVICE_CALL_LOG"; then
  echo "phone guard self-test unexpectedly invoked a Simulator command" >&2
  exit 1
fi
grep -Fq "PHONE UPDATE COMPLETE" "$TMP_DIR/accepted.stdout"

echo "PASS: phone install rehashes the exact Simulator app, provider evidence, clean committed source, and signed candidate immediately before install."
