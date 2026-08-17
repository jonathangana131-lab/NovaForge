#!/usr/bin/env python3
from pathlib import Path

path = Path('scripts/codex-test.sh')
text = path.read_text()
old_boot = '''  local started=$SECONDS
  local state=""
  : > "$LOG_DIR/simulator-boot.log"
  while (( SECONDS - started < SIM_BOOT_TIMEOUT )); do
'''
new_boot = '''  local started=$SECONDS
  local state=""
  local consecutive_booted=0
  : > "$LOG_DIR/simulator-boot.log"
  while (( SECONDS - started < SIM_BOOT_TIMEOUT )); do
'''
if text.count(old_boot) != 1:
    raise SystemExit(f'boot counter marker count={text.count(old_boot)}')
text = text.replace(old_boot, new_boot)

old_probe = '''    if [[ "$state" == "Booted" ]]; then
      # A Booted state precedes full service readiness on some Xcode 27 images.
      # A trivial spawn is a bounded, nonblocking proof that launchd is serving
      # the simulator. Never hand the entire lane to a single `bootstatus -b`.
      if xcrun simctl spawn "$SIMULATOR_ID" /usr/bin/true >/dev/null 2>&1; then
        echo "Simulator $SIMULATOR_ID is booted and responsive."
        return 0
      fi
    elif [[ -z "$state" ]]; then
'''
new_probe = '''    if [[ "$state" == "Booted" ]]; then
      consecutive_booted=$(( consecutive_booted + 1 ))
      # Xcode 27 beta runners can report Booted while `simctl spawn` remains
      # unusable for minutes. Three stable CoreSimulator observations are enough
      # to hand readiness to xcodebuild, which is the authoritative app-launch
      # proof and already has a destination timeout of its own.
      if (( consecutive_booted >= 3 )); then
        echo "Simulator $SIMULATOR_ID reported Booted for three consecutive polls."
        return 0
      fi
    elif [[ -z "$state" ]]; then
'''
if text.count(old_probe) != 1:
    raise SystemExit(f'boot probe marker count={text.count(old_probe)}')
text = text.replace(old_probe, new_probe)

old_sleep = '''    fi
    sleep 2
  done
'''
new_sleep = '''    else
      consecutive_booted=0
    fi
    sleep 2
  done
'''
# Only replace the first occurrence inside boot_simulator after the probe.
idx = text.find(new_probe)
if idx < 0:
    raise SystemExit('new probe not found after replacement')
tail = text[idx:]
if old_sleep not in tail:
    raise SystemExit('boot sleep marker missing')
tail = tail.replace(old_sleep, new_sleep, 1)
text = text[:idx] + tail

old_refresh = '''  xcrun simctl boot "$SIMULATOR_ID" >/dev/null 2>&1 || true
  TIMEOUT_RUNNER_LABEL="simulator-refresh-boot" \\
    "$TIMEOUT_RUNNER" "$SIM_BOOT_TIMEOUT" "$LOG_DIR/simulator-refresh-$batch-boot.log" \\
    xcrun simctl bootstatus "$SIMULATOR_ID" -b
}
'''
new_refresh = '''  xcrun simctl boot "$SIMULATOR_ID" >/dev/null 2>&1 || true
  local started=$SECONDS
  local state=""
  local stable=0
  : > "$LOG_DIR/simulator-refresh-$batch-boot.log"
  while (( SECONDS - started < SIM_BOOT_TIMEOUT )); do
    state="$(python3 - "$SIMULATOR_ID" <<'PY'
import json, subprocess, sys
udid = sys.argv[1]
try:
    data = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "-j"], stderr=subprocess.DEVNULL))
except Exception:
    print("")
    raise SystemExit(0)
for devices in data.get("devices", {}).values():
    for device in devices:
        if device.get("udid") == udid:
            print(device.get("state", ""))
            raise SystemExit(0)
print("")
PY
)"
    printf '%s state=%s\\n' "$(date -u +%FT%TZ)" "${state:-unknown}" >> "$LOG_DIR/simulator-refresh-$batch-boot.log"
    if [[ "$state" == "Booted" ]]; then
      stable=$(( stable + 1 ))
      if (( stable >= 3 )); then
        return 0
      fi
    else
      stable=0
    fi
    sleep 2
  done
  echo "Refreshed simulator did not remain Booted within ${SIM_BOOT_TIMEOUT}s." >&2
  cat "$LOG_DIR/simulator-refresh-$batch-boot.log" >&2 || true
  return 124
}
'''
if text.count(old_refresh) != 1:
    raise SystemExit(f'refresh marker count={text.count(old_refresh)}')
text = text.replace(old_refresh, new_refresh)

if 'simctl spawn "$SIMULATOR_ID" /usr/bin/true' in text:
    raise SystemExit('old spawn readiness probe remains')
if 'xcrun simctl bootstatus "$SIMULATOR_ID" -b' in text:
    raise SystemExit('old blocking bootstatus remains')
path.write_text(text)
print('patched simulator readiness to stable Booted state')
