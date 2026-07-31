#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_ROOT_INPUT="${SOURCE_ROOT:-$ROOT_DIR}"
if ! SOURCE_ROOT="$(cd "$SOURCE_ROOT_INPUT" 2>/dev/null && pwd)"; then
  printf 'proof receipt blocked: SOURCE_ROOT does not exist: %s\n' "$SOURCE_ROOT_INPUT" >&2
  exit 65
fi

SIMULATOR_APP_PATH="${SIMULATOR_APP_PATH:-}"
DEVICE_CANDIDATE_APP_PATH="${DEVICE_CANDIDATE_APP_PATH:-}"
PROVIDER_EVIDENCE_LOG="${PROVIDER_EVIDENCE_LOG:-}"
PROVIDER_EVIDENCE_SCREENSHOT="${PROVIDER_EVIDENCE_SCREENSHOT:-}"
PROVIDER_ID="${PROVIDER_ID:-}"
RESPONSE_MARKER="${RESPONSE_MARKER:-}"
PROVIDER_TEST_IDENTIFIER="${PROVIDER_TEST_IDENTIFIER:-}"
SIMULATOR_ID="${SIMULATOR_ID:-4B9AB34A-404C-485F-B0BC-964F24D0AE83}"
BUNDLE_ID="${BUNDLE_ID:-com.joey.NovaForge}"
OUT_RECEIPT="${OUT_RECEIPT:-}"
GIT_BIN="${GIT_BIN:-git}"
RELEASE_AUDIT="${RELEASE_AUDIT:-$SOURCE_ROOT/scripts/codex-release-candidate-audit.sh}"
APP_BUNDLE_MANIFEST="${APP_BUNDLE_MANIFEST:-$SOURCE_ROOT/scripts/codex-app-bundle-manifest.sh}"

die() {
  printf 'proof receipt blocked: %s\n' "$*" >&2
  exit 65
}

canonical_directory() {
  [[ -d "$1" ]] || return 1
  /usr/bin/python3 - "$1" <<'PY'
import os
import sys

print(os.path.realpath(sys.argv[1]))
PY
}

canonical_file() {
  [[ -f "$1" ]] || return 1
  /usr/bin/python3 - "$1" <<'PY'
import os
import sys

print(os.path.realpath(sys.argv[1]))
PY
}

plist_value() {
  /usr/bin/plutil -extract "$1" raw "$2" 2>/dev/null
}

sha256_file() {
  printf 'sha256:%s\n' "$(/usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}')"
}

verification_timestamp_from_log() {
  /usr/bin/python3 - "$1" "$2" <<'PY'
from datetime import datetime, timezone
import re
import sys

path, test_identifier = sys.argv[1:]
test_class, test_method = test_identifier.split("/", 1)
passed_line = f"Test Case '-[{test_class} {test_method}]' passed"
with open(path, "r", encoding="utf-8", errors="replace") as handle:
    lines = handle.readlines()

passed_indices = [index for index, line in enumerate(lines) if passed_line in line]
if not passed_indices:
    raise SystemExit(1)

suite_pattern = re.compile(
    r"Test Suite 'Selected tests' passed at "
    r"(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}(?:\.\d{1,6})?)\."
)
for index in range(passed_indices[-1] + 1, len(lines)):
    match = suite_pattern.search(lines[index])
    if match is None:
        continue
    completion_window = "".join(lines[index:index + 5])
    if not re.search(r"Executed\s+1\s+test, with 0 failures", completion_window):
        continue
    timestamp_text = match.group(1)
    timestamp_format = "%Y-%m-%d %H:%M:%S.%f" if "." in timestamp_text else "%Y-%m-%d %H:%M:%S"
    local_time = datetime.strptime(timestamp_text, timestamp_format)
    verified = local_time.astimezone().astimezone(timezone.utc)
    age = int((datetime.now(timezone.utc) - verified).total_seconds())
    if age < -300 or age > 1800:
        raise SystemExit(1)
    print(verified.strftime("%Y-%m-%dT%H:%M:%SZ"))
    raise SystemExit(0)
raise SystemExit(1)
PY
}

require_clean_committed_source() {
  local source_commit untracked_compiled
  source_commit="$("$GIT_BIN" -C "$SOURCE_ROOT" rev-parse HEAD 2>/dev/null || true)"
  [[ "$source_commit" =~ ^[0-9a-fA-F]{40}$ ]] || die "could not resolve the current source commit."
  "$GIT_BIN" -C "$SOURCE_ROOT" diff --quiet --ignore-submodules -- || \
    die "tracked source differs from commit $source_commit."
  "$GIT_BIN" -C "$SOURCE_ROOT" diff --cached --quiet --ignore-submodules -- || \
    die "staged source differs from commit $source_commit."
  untracked_compiled="$("$GIT_BIN" -C "$SOURCE_ROOT" ls-files --others --exclude-standard -- \
    AgentPad NovaForgeWidgets Packages/AgentHarnessKit/Sources \
    Vendor/swift-llama-cpp/Sources AgentPad.xcodeproj 2>/dev/null || true)"
  [[ -z "$untracked_compiled" ]] || \
    die "untracked compiled source is present; commit or remove it before creating proof."
  printf '%s\n' "$source_commit" | /usr/bin/tr '[:upper:]' '[:lower:]'
}

[[ -n "$SIMULATOR_APP_PATH" ]] || die "SIMULATOR_APP_PATH is required."
[[ -n "$DEVICE_CANDIDATE_APP_PATH" ]] || die "DEVICE_CANDIDATE_APP_PATH is required."
[[ -n "$PROVIDER_EVIDENCE_LOG" ]] || die "PROVIDER_EVIDENCE_LOG is required."
[[ -n "$PROVIDER_EVIDENCE_SCREENSHOT" ]] || die "PROVIDER_EVIDENCE_SCREENSHOT is required."
[[ -n "$OUT_RECEIPT" ]] || die "OUT_RECEIPT is required."
[[ "$PROVIDER_ID" =~ ^[A-Za-z0-9._-]{1,80}$ ]] || die "PROVIDER_ID is invalid."
[[ "$RESPONSE_MARKER" =~ ^NF_[A-Za-z0-9_-]{3,120}$ ]] || die "RESPONSE_MARKER is invalid."
[[ "$PROVIDER_TEST_IDENTIFIER" =~ ^[A-Za-z0-9_.-]{1,120}/test[A-Za-z0-9_]{3,160}$ ]] || \
  die "PROVIDER_TEST_IDENTIFIER must name the exact passed XCTest case."
[[ "$SIMULATOR_ID" =~ ^[0-9A-Fa-f-]{36}$ ]] || die "SIMULATOR_ID is invalid."
[[ -x "$RELEASE_AUDIT" ]] || die "release candidate audit is unavailable: $RELEASE_AUDIT"
[[ -x "$APP_BUNDLE_MANIFEST" ]] || die "app manifest helper is unavailable: $APP_BUNDLE_MANIFEST"

SIMULATOR_APP_PATH="$(canonical_directory "$SIMULATOR_APP_PATH" || true)"
DEVICE_CANDIDATE_APP_PATH="$(canonical_directory "$DEVICE_CANDIDATE_APP_PATH" || true)"
PROVIDER_EVIDENCE_LOG="$(canonical_file "$PROVIDER_EVIDENCE_LOG" || true)"
PROVIDER_EVIDENCE_SCREENSHOT="$(canonical_file "$PROVIDER_EVIDENCE_SCREENSHOT" || true)"
[[ -n "$SIMULATOR_APP_PATH" ]] || die "Simulator app bundle does not exist."
[[ -n "$DEVICE_CANDIDATE_APP_PATH" ]] || die "signed iPhoneOS candidate does not exist."
[[ -n "$PROVIDER_EVIDENCE_LOG" && -s "$PROVIDER_EVIDENCE_LOG" ]] || die "provider evidence log is missing or empty."
[[ -n "$PROVIDER_EVIDENCE_SCREENSHOT" && -s "$PROVIDER_EVIDENCE_SCREENSHOT" ]] || die "provider evidence screenshot is missing or empty."
grep -Fq -- "$RESPONSE_MARKER" "$PROVIDER_EVIDENCE_LOG" || \
  die "provider evidence log does not contain the exact completed-response marker."
PROVIDER_TEST_CLASS="${PROVIDER_TEST_IDENTIFIER%/*}"
PROVIDER_TEST_METHOD="${PROVIDER_TEST_IDENTIFIER#*/}"
grep -Fq -- "Test Case '-[$PROVIDER_TEST_CLASS $PROVIDER_TEST_METHOD]' passed" "$PROVIDER_EVIDENCE_LOG" || \
  die "provider evidence log does not show the exact live-provider XCTest case passing."
VERIFIED_AT_UTC="$(verification_timestamp_from_log "$PROVIDER_EVIDENCE_LOG" "$PROVIDER_TEST_IDENTIFIER" || true)"
[[ "$VERIFIED_AT_UTC" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || \
  die "provider evidence is not an exact, zero-failure XCTest run completed within the last 30 minutes."
PROVIDER_LOG_BYTES="$(stat -f '%z' "$PROVIDER_EVIDENCE_LOG" 2>/dev/null || echo 0)"
PROVIDER_SCREENSHOT_BYTES="$(stat -f '%z' "$PROVIDER_EVIDENCE_SCREENSHOT" 2>/dev/null || echo 0)"
[[ "$PROVIDER_LOG_BYTES" =~ ^[0-9]+$ ]] && (( PROVIDER_LOG_BYTES > 0 && PROVIDER_LOG_BYTES <= 52428800 )) || \
  die "provider evidence log must be between 1 byte and 50 MiB."
[[ "$PROVIDER_SCREENSHOT_BYTES" =~ ^[0-9]+$ ]] && (( PROVIDER_SCREENSHOT_BYTES > 0 && PROVIDER_SCREENSHOT_BYTES <= 104857600 )) || \
  die "provider evidence screenshot must be between 1 byte and 100 MiB."

CURRENT_SOURCE_COMMIT="$(require_clean_committed_source)"
SIMULATOR_INFO_PLIST="$SIMULATOR_APP_PATH/Info.plist"
DEVICE_INFO_PLIST="$DEVICE_CANDIDATE_APP_PATH/Info.plist"
[[ -f "$SIMULATOR_INFO_PLIST" ]] || die "Simulator app has no Info.plist."
[[ -f "$DEVICE_INFO_PLIST" ]] || die "device candidate has no Info.plist."

SIMULATOR_BUNDLE_ID="$(plist_value CFBundleIdentifier "$SIMULATOR_INFO_PLIST" || true)"
SIMULATOR_MARKETING_VERSION="$(plist_value CFBundleShortVersionString "$SIMULATOR_INFO_PLIST" || true)"
SIMULATOR_BUILD_VERSION="$(plist_value CFBundleVersion "$SIMULATOR_INFO_PLIST" || true)"
SIMULATOR_PLATFORM="$(plist_value 'CFBundleSupportedPlatforms.0' "$SIMULATOR_INFO_PLIST" || true)"
SIMULATOR_SOURCE_COMMIT="$(plist_value NovaForgeSourceCommit "$SIMULATOR_INFO_PLIST" || true)"
[[ "$SIMULATOR_BUNDLE_ID" == "$BUNDLE_ID" ]] || die "Simulator bundle id is not $BUNDLE_ID."
[[ "$SIMULATOR_PLATFORM" == "iPhoneSimulator" ]] || die "Simulator bundle platform is not iPhoneSimulator."
[[ "$SIMULATOR_SOURCE_COMMIT" == "$CURRENT_SOURCE_COMMIT" ]] || \
  die "Simulator app is not provenance-bound to the current source commit."
[[ -n "$SIMULATOR_MARKETING_VERSION" && -n "$SIMULATOR_BUILD_VERSION" ]] || \
  die "Simulator app has no complete version identity."

DEVICE_BUNDLE_ID="$(plist_value CFBundleIdentifier "$DEVICE_INFO_PLIST" || true)"
DEVICE_MARKETING_VERSION="$(plist_value CFBundleShortVersionString "$DEVICE_INFO_PLIST" || true)"
DEVICE_BUILD_VERSION="$(plist_value CFBundleVersion "$DEVICE_INFO_PLIST" || true)"
DEVICE_SOURCE_COMMIT="$(plist_value NovaForgeSourceCommit "$DEVICE_INFO_PLIST" || true)"
[[ "$DEVICE_BUNDLE_ID" == "$BUNDLE_ID" ]] || die "device candidate bundle id is not $BUNDLE_ID."
[[ "$DEVICE_MARKETING_VERSION" == "$SIMULATOR_MARKETING_VERSION" &&
   "$DEVICE_BUILD_VERSION" == "$SIMULATOR_BUILD_VERSION" ]] || \
  die "Simulator and device candidate versions do not match."
[[ "$DEVICE_SOURCE_COMMIT" == "$CURRENT_SOURCE_COMMIT" ]] || \
  die "signed iPhoneOS candidate is not provenance-bound to the current source commit."

OUT_PARENT="$(dirname "$OUT_RECEIPT")"
mkdir -p "$OUT_PARENT"
OUT_PARENT="$(cd "$OUT_PARENT" && pwd)"
OUT_RECEIPT="$OUT_PARENT/$(basename "$OUT_RECEIPT")"
[[ "$OUT_RECEIPT" != "$PROVIDER_EVIDENCE_LOG" &&
   "$OUT_RECEIPT" != "$PROVIDER_EVIDENCE_SCREENSHOT" &&
   "$OUT_RECEIPT" != "$SIMULATOR_APP_PATH"/* &&
   "$OUT_RECEIPT" != "$DEVICE_CANDIDATE_APP_PATH"/* ]] || \
  die "OUT_RECEIPT must not overwrite or live inside a proof input."
AUDIT_PATH="$(mktemp "$OUT_PARENT/.simulator-proof-candidate-audit.XXXXXX")"
RECEIPT_TMP="$(mktemp "$OUT_PARENT/.simulator-proof-receipt.XXXXXX")"
trap 'rm -f "$AUDIT_PATH" "$RECEIPT_TMP"' EXIT

if ! "$RELEASE_AUDIT" "$DEVICE_CANDIDATE_APP_PATH" > "$AUDIT_PATH"; then
  die "signed iPhoneOS candidate audit failed."
fi
AUDIT_STATUS="$(plist_value status "$AUDIT_PATH" || true)"
AUDIT_BUNDLE_ID="$(plist_value bundleID "$AUDIT_PATH" || true)"
AUDIT_PLATFORM="$(plist_value platform "$AUDIT_PATH" || true)"
DEVICE_CANDIDATE_MANIFEST="$(plist_value candidateManifestSHA256 "$AUDIT_PATH" || true)"
[[ "$AUDIT_STATUS" == "pass" && "$AUDIT_BUNDLE_ID" == "$BUNDLE_ID" &&
   "$AUDIT_PLATFORM" == "iPhoneOS" &&
   "$DEVICE_CANDIDATE_MANIFEST" =~ ^sha256:[0-9a-f]{64}$ ]] || \
  die "candidate audit did not return an exact signed iPhoneOS identity."

SIMULATOR_APP_MANIFEST="$("$APP_BUNDLE_MANIFEST" "$SIMULATOR_APP_PATH")"
[[ "$SIMULATOR_APP_MANIFEST" =~ ^sha256:[0-9a-f]{64}$ ]] || \
  die "could not hash the exact Simulator app bundle."
PROVIDER_LOG_MANIFEST="$(sha256_file "$PROVIDER_EVIDENCE_LOG")"
PROVIDER_SCREENSHOT_MANIFEST="$(sha256_file "$PROVIDER_EVIDENCE_SCREENSHOT")"

/usr/bin/python3 - \
  "$RECEIPT_TMP" \
  "$CURRENT_SOURCE_COMMIT" \
  "$BUNDLE_ID" \
  "$SIMULATOR_MARKETING_VERSION" \
  "$SIMULATOR_BUILD_VERSION" \
  "$SIMULATOR_ID" \
  "$SIMULATOR_APP_PATH" \
  "$SIMULATOR_APP_MANIFEST" \
  "$DEVICE_CANDIDATE_MANIFEST" \
  "$PROVIDER_ID" \
  "$RESPONSE_MARKER" \
  "$PROVIDER_TEST_IDENTIFIER" \
  "$PROVIDER_EVIDENCE_LOG" \
  "$PROVIDER_LOG_MANIFEST" \
  "$PROVIDER_EVIDENCE_SCREENSHOT" \
  "$PROVIDER_SCREENSHOT_MANIFEST" \
  "$VERIFIED_AT_UTC" <<'PY'
import json
import os
import sys

(
    output,
    source_commit,
    bundle_id,
    marketing_version,
    build_version,
    simulator_id,
    simulator_app_path,
    simulator_manifest,
    candidate_manifest,
    provider_id,
    response_marker,
    provider_test_identifier,
    evidence_log,
    evidence_log_manifest,
    evidence_screenshot,
    evidence_screenshot_manifest,
    verified_at,
) = sys.argv[1:]

receipt = {
    "schemaVersion": 2,
    "status": "pass",
    "proofKind": "novaforge-live-provider-simulator-v2",
    "sourceCommit": source_commit,
    "bundleID": bundle_id,
    "appMarketingVersion": marketing_version,
    "appBuildVersion": build_version,
    "simulatorID": simulator_id,
    "simulatorPlatform": "iOS Simulator",
    "simulatorAppPath": simulator_app_path,
    "simulatorAppManifestSHA256": simulator_manifest,
    "deviceCandidateManifestSHA256": candidate_manifest,
    "providerID": provider_id,
    "responseMarker": response_marker,
    "providerTestIdentifier": provider_test_identifier,
    "providerEvidenceLogPath": evidence_log,
    "providerEvidenceLogSHA256": evidence_log_manifest,
    "providerEvidenceScreenshotPath": evidence_screenshot,
    "providerEvidenceScreenshotSHA256": evidence_screenshot_manifest,
    "verifiedAtUTC": verified_at,
}
with open(output, "w", encoding="utf-8") as handle:
    json.dump(receipt, handle, indent=2, sort_keys=True)
    handle.write("\n")
os.chmod(output, 0o600)
PY

mv -f "$RECEIPT_TMP" "$OUT_RECEIPT"
trap 'rm -f "$AUDIT_PATH"' EXIT
printf 'Simulator proof receipt created: %s\n' "$OUT_RECEIPT"
printf 'sourceCommit=%s\n' "$CURRENT_SOURCE_COMMIT"
printf 'simulatorAppManifestSHA256=%s\n' "$SIMULATOR_APP_MANIFEST"
printf 'deviceCandidateManifestSHA256=%s\n' "$DEVICE_CANDIDATE_MANIFEST"
