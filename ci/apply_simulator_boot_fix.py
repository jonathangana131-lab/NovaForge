#!/usr/bin/env python3
from pathlib import Path

path = Path('scripts/codex-test.sh')
text = path.read_text()
old = '''boot_simulator() {
  echo "==> Simulator $SIMULATOR_ID"
  xcrun simctl boot "$SIMULATOR_ID" >/dev/null 2>&1 || true
  TIMEOUT_RUNNER_LABEL="simulator-boot" \\
    "$TIMEOUT_RUNNER" "$SIM_BOOT_TIMEOUT" "$LOG_DIR/simulator-boot.log" \\
    xcrun simctl bootstatus "$SIMULATOR_ID" -b
}
'''
new = r'''resolve_simulator_id() {
  local requested="$SIMULATOR_ID"
  local resolved=""

  # UUIDs are host-local. A checked-in/default UUID can be perfectly valid on
  # one Mac and nonexistent on a fresh GitHub Xcode runner. Preserve an explicit
  # caller UUID only when CoreSimulator can actually see an available device.
  resolved="$(python3 - "$requested" <<'PY'
import json, subprocess, sys
requested = sys.argv[1]
data = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))
all_devices = []
for runtime, devices in data.get("devices", {}).items():
    for device in devices:
        if device.get("isAvailable", True):
            all_devices.append((runtime, device))
for runtime, device in all_devices:
    if device.get("udid") == requested:
        print(requested)
        raise SystemExit(0)

# Prefer the newest iOS runtime, then the newest Pro iPhone, while remaining
# resilient to runner-image device-name changes.
ios = [(runtime, d) for runtime, d in all_devices if "SimRuntime.iOS-" in runtime and d.get("name", "").startswith("iPhone")]
def version(runtime):
    tail = runtime.split("SimRuntime.iOS-")[-1]
    parts = []
    for piece in tail.split("-"):
        try: parts.append(int(piece))
        except ValueError: parts.append(0)
    return tuple(parts)
def device_rank(name):
    if name == "iPhone 17 Pro": return 0
    if "Pro" in name: return 1
    return 2
ios.sort(key=lambda pair: (tuple(-x for x in version(pair[0])), device_rank(pair[1].get("name", "")), pair[1].get("name", "")))
if ios:
    print(ios[0][1]["udid"])
PY
)"
  if [[ -z "$resolved" ]]; then
    echo "No available iPhone simulator was found." >&2
    xcrun simctl list devices available >&2 || true
    return 2
  fi
  if [[ "$resolved" != "$SIMULATOR_ID" ]]; then
    echo "Simulator UUID $SIMULATOR_ID is not available on this host; using $resolved."
  fi
  SIMULATOR_ID="$resolved"
}

boot_simulator() {
  resolve_simulator_id
  echo "==> Simulator $SIMULATOR_ID"
  xcrun simctl boot "$SIMULATOR_ID" >/dev/null 2>&1 || true

  local started=$SECONDS
  local state=""
  : > "$LOG_DIR/simulator-boot.log"
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
    printf '%s state=%s\n' "$(date -u +%FT%TZ)" "${state:-unknown}" >> "$LOG_DIR/simulator-boot.log"
    if [[ "$state" == "Booted" ]]; then
      # A Booted state precedes full service readiness on some Xcode 27 images.
      # A trivial spawn is a bounded, nonblocking proof that launchd is serving
      # the simulator. Never hand the entire lane to a single `bootstatus -b`.
      if xcrun simctl spawn "$SIMULATOR_ID" /usr/bin/true >/dev/null 2>&1; then
        echo "Simulator $SIMULATOR_ID is booted and responsive."
        return 0
      fi
    elif [[ -z "$state" ]]; then
      echo "Simulator $SIMULATOR_ID disappeared while booting." >&2
      xcrun simctl list devices available >&2 || true
      return 2
    fi
    sleep 2
  done

  echo "Simulator $SIMULATOR_ID did not become responsive within ${SIM_BOOT_TIMEOUT}s." >&2
  cat "$LOG_DIR/simulator-boot.log" >&2 || true
  xcrun simctl list devices >&2 || true
  return 124
}
'''
if text.count(old) != 1:
    raise SystemExit(f'boot_simulator marker count={text.count(old)}')
text = text.replace(old, new)
path.write_text(text)
print('patched deterministic simulator resolution/boot')
