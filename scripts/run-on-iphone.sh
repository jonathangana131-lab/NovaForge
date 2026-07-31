#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_ROOT_INPUT="${SOURCE_ROOT:-$ROOT_DIR}"
if ! SOURCE_ROOT="$(cd "$SOURCE_ROOT_INPUT" 2>/dev/null && pwd)"; then
  printf 'PHONE UPDATE BLOCKED: SOURCE_ROOT does not exist: %s\n' "$SOURCE_ROOT_INPUT" >&2
  exit 65
fi
PROJECT_PATH="${PROJECT_PATH:-$SOURCE_ROOT/AgentPad.xcodeproj}"
SCHEME="${SCHEME:-AgentPad}"
CONFIGURATION="${CONFIGURATION:-Release}"
BUNDLE_ID="${BUNDLE_ID:-com.joey.NovaForge}"
DEVICE_ID="${DEVICE_ID:-A9CFDD8D-E5B9-5B93-917A-513357EAD81E}"
PHONE_UDID="${PHONE_UDID:-00008101-000D05022061401E}"
EXPECTED_SIMULATOR_ID="${EXPECTED_SIMULATOR_ID:-4B9AB34A-404C-485F-B0BC-964F24D0AE83}"
WAIT_FOR_DEVICE="${WAIT_FOR_DEVICE:-1}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-60}"
SLEEP_SECONDS="${SLEEP_SECONDS:-10}"
BUILD_FIRST="${BUILD_FIRST:-1}"
ALLOW_DEVICE_INSTALL="${ALLOW_DEVICE_INSTALL:-0}"
PREPARE_ONLY="${PREPARE_ONLY:-0}"
SIMULATOR_PROOF_RECEIPT="${SIMULATOR_PROOF_RECEIPT:-}"
GIT_BIN="${GIT_BIN:-git}"
RELEASE_AUDIT="$SOURCE_ROOT/scripts/codex-release-candidate-audit.sh"
APP_BUNDLE_MANIFEST="${APP_BUNDLE_MANIFEST:-$SOURCE_ROOT/scripts/codex-app-bundle-manifest.sh}"
OUT_DIR="${OUT_DIR:-$SOURCE_ROOT/QA/phone-update-$(date +%Y%m%d-%H%M%S)}"
DERIVED_DATA="${DERIVED_DATA:-$OUT_DIR/DerivedData}"
APP_PATH="${APP_PATH:-}"
CANDIDATE_AUDIT_PATH="${CANDIDATE_AUDIT_PATH:-$OUT_DIR/release-candidate-audit.json}"
CURRENT_SOURCE_COMMIT=""
CANDIDATE_MANIFEST_SHA256=""
APP_MARKETING_VERSION=""
APP_BUILD_VERSION=""
SIMULATOR_PROOF_MAX_AGE_SECONDS=1800
SIMULATOR_PROOF_MAX_FUTURE_SKEW_SECONDS=300

log() {
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

safety_error() {
  log "PHONE UPDATE BLOCKED: $*" >&2
  return 65
}

require_explicit_mode() {
  [[ "$ALLOW_DEVICE_INSTALL" == "0" || "$ALLOW_DEVICE_INSTALL" == "1" ]] || {
    safety_error "ALLOW_DEVICE_INSTALL must be 0 or 1."
    return $?
  }
  [[ "$PREPARE_ONLY" == "0" || "$PREPARE_ONLY" == "1" ]] || {
    safety_error "PREPARE_ONLY must be 0 or 1."
    return $?
  }
  if [[ "$PREPARE_ONLY" != "1" && "$ALLOW_DEVICE_INSTALL" != "1" ]]; then
    log "PHONE UPDATE BLOCKED: device installation is opt-in. Set ALLOW_DEVICE_INSTALL=1 only after the verified Simulator receipt is ready." >&2
    return 64
  fi
  if [[ "$CONFIGURATION" != "Release" ]]; then
    safety_error "phone candidates must use CONFIGURATION=Release."
    return $?
  fi
}

require_clean_committed_source() {
  if ! CURRENT_SOURCE_COMMIT="$("$GIT_BIN" -C "$SOURCE_ROOT" rev-parse HEAD 2>/dev/null)" ||
     [[ ! "$CURRENT_SOURCE_COMMIT" =~ ^[0-9a-fA-F]{40}$ ]]; then
    safety_error "could not resolve the current source commit in $SOURCE_ROOT."
    return $?
  fi
  if ! "$GIT_BIN" -C "$SOURCE_ROOT" diff --quiet --ignore-submodules -- ||
     ! "$GIT_BIN" -C "$SOURCE_ROOT" diff --cached --quiet --ignore-submodules --; then
    safety_error "tracked source differs from commit $CURRENT_SOURCE_COMMIT; commit the verified source before preparing a phone build."
    return $?
  fi
  local untracked_compiled
  untracked_compiled="$("$GIT_BIN" -C "$SOURCE_ROOT" ls-files --others --exclude-standard -- \
    AgentPad NovaForgeWidgets Packages/AgentHarnessKit/Sources \
    Vendor/swift-llama-cpp/Sources AgentPad.xcodeproj 2>/dev/null || true)"
  if [[ -n "$untracked_compiled" ]]; then
    safety_error "untracked compiled source is present; commit or remove it before preparing a phone build."
    return $?
  fi
}

plist_value() {
  local key="$1"
  local plist="$2"
  /usr/bin/plutil -extract "$key" raw "$plist" 2>/dev/null
}

audit_candidate() {
  local info_plist="$APP_PATH/Info.plist"
  [[ -x "$RELEASE_AUDIT" ]] || {
    safety_error "release candidate audit is unavailable: $RELEASE_AUDIT"
    return $?
  }
  [[ -f "$info_plist" ]] || {
    safety_error "candidate has no Info.plist: $APP_PATH"
    return $?
  }

  log "Auditing exact signed iPhoneOS candidate before any device contact"
  if ! "$RELEASE_AUDIT" "$APP_PATH" > "$CANDIDATE_AUDIT_PATH"; then
    safety_error "release candidate audit failed; see $CANDIDATE_AUDIT_PATH."
    return $?
  fi

  CANDIDATE_MANIFEST_SHA256="$(plist_value candidateManifestSHA256 "$CANDIDATE_AUDIT_PATH" || true)"
  APP_MARKETING_VERSION="$(plist_value CFBundleShortVersionString "$info_plist" || true)"
  APP_BUILD_VERSION="$(plist_value CFBundleVersion "$info_plist" || true)"
  local embedded_source_commit audited_bundle_id audited_platform audited_status
  embedded_source_commit="$(plist_value NovaForgeSourceCommit "$info_plist" || true)"
  audited_bundle_id="$(plist_value bundleID "$CANDIDATE_AUDIT_PATH" || true)"
  audited_platform="$(plist_value platform "$CANDIDATE_AUDIT_PATH" || true)"
  audited_status="$(plist_value status "$CANDIDATE_AUDIT_PATH" || true)"

  [[ "$audited_status" == "pass" &&
     "$audited_bundle_id" == "$BUNDLE_ID" &&
     "$audited_platform" == "iPhoneOS" &&
     "$embedded_source_commit" == "$CURRENT_SOURCE_COMMIT" &&
     "$CANDIDATE_MANIFEST_SHA256" =~ ^sha256:[0-9a-f]{64}$ &&
     -n "$APP_MARKETING_VERSION" &&
     -n "$APP_BUILD_VERSION" ]] || {
    safety_error "candidate audit did not return the required bundle, platform, version, and manifest identity."
    return $?
  }
}

receipt_value() {
  plist_value "$1" "$SIMULATOR_PROOF_RECEIPT"
}

receipt_is_valid_json_object() {
  /usr/bin/python3 - "$SIMULATOR_PROOF_RECEIPT" <<'PY'
import json
import sys

def reject_duplicate_keys(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError(f"duplicate JSON key: {key}")
        value[key] = item
    return value

expected_keys = {
    "schemaVersion",
    "status",
    "proofKind",
    "sourceCommit",
    "bundleID",
    "appMarketingVersion",
    "appBuildVersion",
    "simulatorID",
    "simulatorPlatform",
    "simulatorAppPath",
    "simulatorAppManifestSHA256",
    "deviceCandidateManifestSHA256",
    "providerID",
    "responseMarker",
    "providerTestIdentifier",
    "providerEvidenceLogPath",
    "providerEvidenceLogSHA256",
    "providerEvidenceScreenshotPath",
    "providerEvidenceScreenshotSHA256",
    "verifiedAtUTC",
}

try:
    with open(sys.argv[1], "r", encoding="utf-8") as handle:
        value = json.load(handle, object_pairs_hook=reject_duplicate_keys)
except (OSError, UnicodeError, json.JSONDecodeError, ValueError):
    raise SystemExit(1)
if not isinstance(value, dict) or set(value) != expected_keys:
    raise SystemExit(1)
if type(value.get("schemaVersion")) is not int:
    raise SystemExit(1)
if any(not isinstance(item, str) for key, item in value.items() if key != "schemaVersion"):
    raise SystemExit(1)
PY
}

sha256_file() {
  printf 'sha256:%s\n' "$(/usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}')"
}

canonical_existing_path() {
  /usr/bin/python3 - "$1" "$2" <<'PY'
import os
import sys

path = os.path.realpath(sys.argv[1])
kind = sys.argv[2]
valid = os.path.isdir(path) if kind == "directory" else os.path.isfile(path)
if not valid:
    raise SystemExit(1)
print(path)
PY
}

require_receipt_value() {
  local key="$1"
  local expected="$2"
  local actual
  actual="$(receipt_value "$key" || true)"
  if [[ "$actual" != "$expected" ]]; then
    safety_error "Simulator proof receipt field '$key' is '${actual:-missing}', expected '$expected'."
    return $?
  fi
}

validate_simulator_proof_receipt() {
  [[ -n "$SIMULATOR_PROOF_RECEIPT" && -f "$SIMULATOR_PROOF_RECEIPT" ]] || {
    safety_error "SIMULATOR_PROOF_RECEIPT must name the explicit post-verification JSON receipt."
    return $?
  }
  local receipt_bytes
  receipt_bytes="$(stat -f '%z' "$SIMULATOR_PROOF_RECEIPT" 2>/dev/null || echo 0)"
  local receipt_prefix
  receipt_prefix="$(LC_ALL=C tr -d '[:space:]' < "$SIMULATOR_PROOF_RECEIPT" | cut -c 1)"
  if [[ ! "$receipt_bytes" =~ ^[0-9]+$ ]] ||
     (( receipt_bytes < 2 || receipt_bytes > 65536 )) ||
     [[ "$receipt_prefix" != "{" ]] ||
     ! receipt_is_valid_json_object; then
    safety_error "Simulator proof receipt is not a bounded valid JSON receipt."
    return $?
  fi

  local receipt_hash_before receipt_hash_after
  receipt_hash_before="$(sha256_file "$SIMULATOR_PROOF_RECEIPT")"

  require_receipt_value schemaVersion "2"
  require_receipt_value status "pass"
  require_receipt_value proofKind "novaforge-live-provider-simulator-v2"
  require_receipt_value sourceCommit "$CURRENT_SOURCE_COMMIT"
  require_receipt_value bundleID "$BUNDLE_ID"
  require_receipt_value appMarketingVersion "$APP_MARKETING_VERSION"
  require_receipt_value appBuildVersion "$APP_BUILD_VERSION"
  require_receipt_value simulatorID "$EXPECTED_SIMULATOR_ID"
  require_receipt_value simulatorPlatform "iOS Simulator"
  require_receipt_value deviceCandidateManifestSHA256 "$CANDIDATE_MANIFEST_SHA256"

  local simulator_manifest provider_id response_marker provider_test_identifier verified_at receipt_age_seconds
  local simulator_app_path evidence_log_path evidence_log_manifest
  local evidence_screenshot_path evidence_screenshot_manifest actual_manifest actual_evidence_manifest
  simulator_manifest="$(receipt_value simulatorAppManifestSHA256 || true)"
  provider_id="$(receipt_value providerID || true)"
  response_marker="$(receipt_value responseMarker || true)"
  provider_test_identifier="$(receipt_value providerTestIdentifier || true)"
  verified_at="$(receipt_value verifiedAtUTC || true)"
  simulator_app_path="$(receipt_value simulatorAppPath || true)"
  evidence_log_path="$(receipt_value providerEvidenceLogPath || true)"
  evidence_log_manifest="$(receipt_value providerEvidenceLogSHA256 || true)"
  evidence_screenshot_path="$(receipt_value providerEvidenceScreenshotPath || true)"
  evidence_screenshot_manifest="$(receipt_value providerEvidenceScreenshotSHA256 || true)"
  [[ "$simulator_manifest" =~ ^sha256:[0-9a-f]{64}$ ]] || {
    safety_error "Simulator proof receipt is missing its simulator app manifest SHA-256."
    return $?
  }
  [[ "$provider_id" =~ ^[A-Za-z0-9._-]{1,80}$ ]] || {
    safety_error "Simulator proof receipt has no bounded provider identity."
    return $?
  }
  [[ "$response_marker" =~ ^NF_[A-Za-z0-9_-]{3,120}$ ]] || {
    safety_error "Simulator proof receipt has no valid completed-response marker."
    return $?
  }
  [[ "$provider_test_identifier" =~ ^[A-Za-z0-9_.-]{1,120}/test[A-Za-z0-9_]{3,160}$ ]] || {
    safety_error "Simulator proof receipt has no exact live-provider XCTest identity."
    return $?
  }
  [[ "$verified_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || {
    safety_error "Simulator proof receipt has no UTC verification timestamp."
    return $?
  }

  [[ -x "$APP_BUNDLE_MANIFEST" ]] || {
    safety_error "app manifest helper is unavailable: $APP_BUNDLE_MANIFEST"
    return $?
  }
  simulator_app_path="$(canonical_existing_path "$simulator_app_path" directory || true)"
  evidence_log_path="$(canonical_existing_path "$evidence_log_path" file || true)"
  evidence_screenshot_path="$(canonical_existing_path "$evidence_screenshot_path" file || true)"
  [[ -n "$simulator_app_path" && "$simulator_app_path" == *.app ]] || {
    safety_error "Simulator proof receipt does not reference an existing app bundle."
    return $?
  }
  local evidence_log_bytes evidence_screenshot_bytes
  evidence_log_bytes="$(stat -f '%z' "$evidence_log_path" 2>/dev/null || echo 0)"
  evidence_screenshot_bytes="$(stat -f '%z' "$evidence_screenshot_path" 2>/dev/null || echo 0)"
  [[ -n "$evidence_log_path" && "$evidence_log_bytes" =~ ^[0-9]+$ &&
     "$evidence_log_bytes" -gt 0 && "$evidence_log_bytes" -le 52428800 &&
     "$evidence_log_manifest" =~ ^sha256:[0-9a-f]{64}$ ]] || {
    safety_error "Simulator proof receipt does not reference a hashed provider evidence log."
    return $?
  }
  [[ -n "$evidence_screenshot_path" && "$evidence_screenshot_bytes" =~ ^[0-9]+$ &&
     "$evidence_screenshot_bytes" -gt 0 && "$evidence_screenshot_bytes" -le 104857600 &&
     "$evidence_screenshot_manifest" =~ ^sha256:[0-9a-f]{64}$ ]] || {
    safety_error "Simulator proof receipt does not reference a hashed provider evidence screenshot."
    return $?
  }

  local simulator_info simulator_bundle simulator_marketing simulator_build simulator_platform simulator_source_commit
  simulator_info="$simulator_app_path/Info.plist"
  [[ -f "$simulator_info" ]] || {
    safety_error "Simulator proof app has no Info.plist."
    return $?
  }
  simulator_bundle="$(plist_value CFBundleIdentifier "$simulator_info" || true)"
  simulator_marketing="$(plist_value CFBundleShortVersionString "$simulator_info" || true)"
  simulator_build="$(plist_value CFBundleVersion "$simulator_info" || true)"
  simulator_platform="$(plist_value 'CFBundleSupportedPlatforms.0' "$simulator_info" || true)"
  simulator_source_commit="$(plist_value NovaForgeSourceCommit "$simulator_info" || true)"
  if [[ "$simulator_bundle" != "$BUNDLE_ID" ||
        "$simulator_marketing" != "$APP_MARKETING_VERSION" ||
        "$simulator_build" != "$APP_BUILD_VERSION" ||
        "$simulator_platform" != "iPhoneSimulator" ||
        "$simulator_source_commit" != "$CURRENT_SOURCE_COMMIT" ]]; then
    safety_error "Simulator proof app identity does not match the exact iPhoneOS candidate."
    return $?
  fi

  actual_manifest="$("$APP_BUNDLE_MANIFEST" "$simulator_app_path" || true)"
  [[ "$actual_manifest" == "$simulator_manifest" ]] || {
    safety_error "exact Simulator app bundle differs from its proof receipt manifest."
    return $?
  }
  actual_evidence_manifest="$(sha256_file "$evidence_log_path")"
  [[ "$actual_evidence_manifest" == "$evidence_log_manifest" ]] || {
    safety_error "provider evidence log differs from its proof receipt manifest."
    return $?
  }
  grep -Fq -- "$response_marker" "$evidence_log_path" || {
    safety_error "provider evidence log no longer contains the exact completed-response marker."
    return $?
  }
  local provider_test_class provider_test_method
  provider_test_class="${provider_test_identifier%/*}"
  provider_test_method="${provider_test_identifier#*/}"
  grep -Fq -- "Test Case '-[$provider_test_class $provider_test_method]' passed" "$evidence_log_path" || {
    safety_error "provider evidence log no longer shows the exact live-provider XCTest case passing."
    return $?
  }
  actual_evidence_manifest="$(sha256_file "$evidence_screenshot_path")"
  [[ "$actual_evidence_manifest" == "$evidence_screenshot_manifest" ]] || {
    safety_error "provider evidence screenshot differs from its proof receipt manifest."
    return $?
  }
  if ! receipt_age_seconds="$(/usr/bin/python3 - \
      "$verified_at" \
      "$SIMULATOR_PROOF_MAX_AGE_SECONDS" \
      "$SIMULATOR_PROOF_MAX_FUTURE_SKEW_SECONDS" <<'PY'
from datetime import datetime, timezone
import sys

try:
    verified = datetime.strptime(sys.argv[1], "%Y-%m-%dT%H:%M:%SZ").replace(
        tzinfo=timezone.utc
    )
    maximum_age = int(sys.argv[2])
    future_skew = int(sys.argv[3])
except (ValueError, OverflowError):
    raise SystemExit(1)

age = int((datetime.now(timezone.utc) - verified).total_seconds())
if age < -future_skew or age > maximum_age:
    raise SystemExit(1)
print(age)
PY
  )"; then
    safety_error "Simulator proof receipt is stale or too far in the future; rerun the live Simulator proof within 30 minutes of installation."
    return $?
  fi

  receipt_hash_after="$(sha256_file "$SIMULATOR_PROOF_RECEIPT")"
  [[ "$receipt_hash_after" == "$receipt_hash_before" ]] || {
    safety_error "Simulator proof receipt changed while it was being validated."
    return $?
  }

  log "Simulator proof receipt accepted for clean source commit $CURRENT_SOURCE_COMMIT, app $APP_MARKETING_VERSION ($APP_BUILD_VERSION), age ${receipt_age_seconds}s."
  log "Exact Simulator app $simulator_manifest and provider evidence were rehashed; the separately signed iPhoneOS candidate audited as $CANDIDATE_MANIFEST_SHA256."
}

run_and_log() {
  local name="$1"
  shift
  log "$name"
  "$@" > "$OUT_DIR/${name// /-}.log" 2>&1
}

snapshot_device_state() {
  local prefix="$1"
  xcrun devicectl list devices --timeout 30 > "$OUT_DIR/$prefix-devicectl-list.txt" 2>&1 || true
  xcrun devicectl device info details --device "$DEVICE_ID" --timeout 30 > "$OUT_DIR/$prefix-devicectl-details.txt" 2>&1 || true
  xcrun xcdevice list > "$OUT_DIR/$prefix-xcdevice-list.json" 2>&1 || true
  system_profiler SPUSBDataType -detailLevel mini > "$OUT_DIR/$prefix-usb.txt" 2>/dev/null || true
}

device_row() {
  grep -E "Joey.*iPhone|$DEVICE_ID|$PHONE_UDID" "$1" | head -n 1 || true
}

device_is_reachable() {
  local list_file="$1"
  local row
  row="$(device_row "$list_file")"
  [[ -n "$row" && "$row" != *"unavailable"* ]]
}

wait_for_device() {
  local attempt list_file details_file row tunnel ddi usb_seen
  for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
    list_file="$OUT_DIR/device-wait-$attempt-list.txt"
    details_file="$OUT_DIR/device-wait-$attempt-details.txt"
    xcrun devicectl list devices --timeout 30 > "$list_file" 2>&1 || true
    xcrun devicectl device info details --device "$DEVICE_ID" --timeout 30 > "$details_file" 2>&1 || true
    system_profiler SPUSBDataType -detailLevel mini > "$OUT_DIR/device-wait-$attempt-usb.txt" 2>/dev/null || true
    row="$(device_row "$list_file")"
    tunnel="$(grep -E 'tunnelState:' "$details_file" | tail -n 1 | sed 's/^ *//' || true)"
    ddi="$(grep -E 'ddiServicesAvailable:' "$details_file" | tail -n 1 | sed 's/^ *//' || true)"
    usb_seen="no"
    if grep -Eiq 'iPhone|Apple Mobile' "$OUT_DIR/device-wait-$attempt-usb.txt"; then
      usb_seen="yes"
    fi
    printf 'attempt=%s/%s\nusb_seen=%s\ncoredevice_row=%s\n%s\n%s\n' "$attempt" "$MAX_ATTEMPTS" "$usb_seen" "${row:-no CoreDevice row}" "${tunnel:-tunnelState: unknown}" "${ddi:-ddiServicesAvailable: unknown}" > "$OUT_DIR/latest-device-status.txt"
    log "device check $attempt/$MAX_ATTEMPTS usb=$usb_seen ${row:-no CoreDevice row} ${tunnel:-} ${ddi:-}"
    if device_is_reachable "$list_file"; then
      return 0
    fi
    [[ "$WAIT_FOR_DEVICE" == "1" ]] || return 2
    sleep "$SLEEP_SECONDS"
  done
  return 2
}

build_app_if_needed() {
  if [[ -n "$APP_PATH" ]]; then
    if [[ ! -d "$APP_PATH" ]]; then
      log "APP_PATH was supplied but does not exist: $APP_PATH"
      return 4
    fi
    APP_PATH="$(cd "$(dirname "$APP_PATH")" && pwd)/$(basename "$APP_PATH")"
    return 0
  fi

  if [[ "$BUILD_FIRST" == "1" ]]; then
    log "Building $SCHEME $CONFIGURATION for iPhone into $DERIVED_DATA"
    xcodebuild \
      -project "$PROJECT_PATH" \
      -scheme "$SCHEME" \
      -configuration "$CONFIGURATION" \
      -destination "generic/platform=iOS" \
      -derivedDataPath "$DERIVED_DATA" \
      -skipPackageUpdates \
      -skipPackagePluginValidation \
      -skipMacroValidation \
      -allowProvisioningUpdates \
      NOVAFORGE_SOURCE_COMMIT="$CURRENT_SOURCE_COMMIT" \
      build > "$OUT_DIR/iphoneos-build.log" 2>&1
  fi

  APP_PATH="$(find "$DERIVED_DATA/Build/Products/$CONFIGURATION-iphoneos" -name 'NovaForge.app' -type d -print -quit 2>/dev/null || true)"
  if [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
    log "Could not find NovaForge.app after build. See $OUT_DIR/iphoneos-build.log"
    return 5
  fi
  APP_PATH="$(cd "$(dirname "$APP_PATH")" && pwd)/$(basename "$APP_PATH")"
}

install_launch_verify() {
  printf '%s\n' "$APP_PATH" > "$OUT_DIR/iphoneos-app.path"
  log "Installing $APP_PATH on device $DEVICE_ID"
  xcrun devicectl device install app \
    --device "$DEVICE_ID" \
    "$APP_PATH" \
    --timeout 120 \
    --json-output "$OUT_DIR/install.json" \
    --log-output "$OUT_DIR/install.log" > "$OUT_DIR/install.stdout" 2>&1

  log "Launching $BUNDLE_ID on device $DEVICE_ID"
  xcrun devicectl device process launch \
    --device "$DEVICE_ID" \
    --terminate-existing \
    --activate \
    "$BUNDLE_ID" \
    --json-output "$OUT_DIR/launch.json" \
    --log-output "$OUT_DIR/launch.log" > "$OUT_DIR/launch.stdout" 2>&1

  sleep 3
  log "Verifying NovaForge process on device"
  xcrun devicectl device info processes \
    --device "$DEVICE_ID" \
    --columns '*' \
    --timeout 30 > "$OUT_DIR/processes-after-launch.txt" 2>&1 || true

  if grep -Ei "NovaForge|$BUNDLE_ID" "$OUT_DIR/processes-after-launch.txt" > "$OUT_DIR/novaforge-process-match.txt"; then
    log "PHONE UPDATE COMPLETE"
    cat "$OUT_DIR/novaforge-process-match.txt"
    return 0
  fi

  log "Launch command returned, but NovaForge was not visible in the process list. See $OUT_DIR/processes-after-launch.txt"
  return 6
}

require_explicit_mode
mkdir -p "$OUT_DIR" "$(dirname "$CANDIDATE_AUDIT_PATH")" "$SOURCE_ROOT/QA"
printf '%s\n' "$OUT_DIR" > "$SOURCE_ROOT/QA/latest-phone-update-dir.txt"

cd "$SOURCE_ROOT"
log "NovaForge phone update started"
log "out=$OUT_DIR device=$DEVICE_ID udid=$PHONE_UDID bundle=$BUNDLE_ID config=$CONFIGURATION"
require_clean_committed_source
build_app_if_needed
printf '%s\n' "$APP_PATH" > "$OUT_DIR/iphoneos-app.path"
audit_candidate

if [[ "$PREPARE_ONLY" == "1" ]]; then
  log "PHONE CANDIDATE PREPARED WITHOUT DEVICE CONTACT"
  log "sourceCommit=$CURRENT_SOURCE_COMMIT"
  log "app=$APP_MARKETING_VERSION ($APP_BUILD_VERSION)"
  log "deviceCandidateManifestSHA256=$CANDIDATE_MANIFEST_SHA256"
  log "After the same clean source commit/build identity passes the live Simulator proof, create its schema-v2 receipt with scripts/create-simulator-proof-receipt.sh and rerun with ALLOW_DEVICE_INSTALL=1."
  exit 0
fi

validate_simulator_proof_receipt
snapshot_device_state "initial"

if ! wait_for_device; then
  log "PHONE UPDATE BLOCKED: Joey's iPhone is not reachable for install. Unlock it, plug/replug the cable, and tap Trust/Allow if prompted. Logs: $OUT_DIR"
  exit 2
fi

log "Revalidating source, signed candidate, and Simulator receipt immediately before installation"
require_clean_committed_source
audit_candidate
validate_simulator_proof_receipt
install_launch_verify
