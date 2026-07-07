#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/AgentPad.xcodeproj"
SCHEME="${SCHEME:-AgentPad}"
CONFIGURATION="${CONFIGURATION:-Release}"
BUNDLE_ID="${BUNDLE_ID:-com.joey.NovaForge}"
DEVICE_ID="${DEVICE_ID:-A9CFDD8D-E5B9-5B93-917A-513357EAD81E}"
PHONE_UDID="${PHONE_UDID:-00008101-000D05022061401E}"
WAIT_FOR_DEVICE="${WAIT_FOR_DEVICE:-1}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-60}"
SLEEP_SECONDS="${SLEEP_SECONDS:-10}"
BUILD_FIRST="${BUILD_FIRST:-1}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/QA/phone-update-$(date +%Y%m%d-%H%M%S)}"
DERIVED_DATA="${DERIVED_DATA:-$OUT_DIR/DerivedData}"
APP_PATH="${APP_PATH:-}"

mkdir -p "$OUT_DIR"
printf '%s\n' "$OUT_DIR" > "$ROOT_DIR/QA/latest-phone-update-dir.txt"

log() {
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
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
      build > "$OUT_DIR/iphoneos-build.log" 2>&1
  fi

  APP_PATH="$(find "$DERIVED_DATA/Build/Products/$CONFIGURATION-iphoneos" -name 'NovaForge.app' -type d -print -quit 2>/dev/null || true)"
  if [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
    log "Could not find NovaForge.app after build. See $OUT_DIR/iphoneos-build.log"
    return 5
  fi
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

cd "$ROOT_DIR"
log "NovaForge phone update started"
log "out=$OUT_DIR device=$DEVICE_ID udid=$PHONE_UDID bundle=$BUNDLE_ID config=$CONFIGURATION"
snapshot_device_state "initial"

build_app_if_needed

if ! wait_for_device; then
  log "PHONE UPDATE BLOCKED: Joey's iPhone is not reachable for install. Unlock it, plug/replug the cable, and tap Trust/Allow if prompted. Logs: $OUT_DIR"
  exit 2
fi

install_launch_verify
