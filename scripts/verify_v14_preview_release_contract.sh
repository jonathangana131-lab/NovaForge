#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "${1:-}" == "--root" ]]; then
  [[ -n "${2:-}" ]] || { echo "[preview-release][FAIL] ROOT_ARGUMENT_MISSING"; exit 2; }
  ROOT="$(cd "$2" && pwd)"
  shift 2
fi
[[ $# -eq 0 ]] || { echo "[preview-release][FAIL] UNEXPECTED_ARGUMENTS $*"; exit 2; }

failures=0
pass() { printf '[preview-release][PASS] %s\n' "$1"; }
fail() {
  printf '[preview-release][FAIL] %s\n' "$1"
  failures=$((failures + 1))
}

EFFORT="$ROOT/scripts/verify_v14_preview_effort_contract.sh"
THEME="$ROOT/AgentPad/Design/AgentTheme.swift"
SETTINGS="$ROOT/AgentPad/Views/SettingsView.swift"
APP="$ROOT/AgentPad/App/AgentPadApp.swift"

printf '[preview-release] root=%s\n' "$ROOT"
printf '[preview-release] section=effort\n'
if [[ ! -f "$EFFORT" ]]; then
  fail "EFFORT_CONTRACT_MISSING scripts/verify_v14_preview_effort_contract.sh"
elif bash "$EFFORT"; then
  pass "EFFORT_CONTRACT"
else
  fail "EFFORT_CONTRACT"
fi

printf '[preview-release] section=themes\n'
python3 - "$THEME" "$SETTINGS" "$APP" <<'PY' || failures=$((failures + 1))
from pathlib import Path
import re
import sys

theme_path, settings_path, app_path = map(Path, sys.argv[1:])
for path in (theme_path, settings_path, app_path):
    if not path.is_file():
        print(f"[preview-release][FAIL] THEME_SOURCE_MISSING {path}")
        raise SystemExit(1)

theme = theme_path.read_text()
settings = settings_path.read_text()
app = app_path.read_text()
errors: list[str] = []

expected = [
    ("matrixRain", "Matrix Rain"),
    ("midnightBlack", "Midnight Black"),
    ("whiteGold", "White Gold"),
    ("arcticGlass", "Arctic Glass"),
    ("emberCore", "Ember Core"),
]

prefix = theme.split("static let storageKey", 1)[0]
cases = re.findall(r"(?m)^\s*case\s+([A-Za-z_][A-Za-z0-9_]*)\s*$", prefix)
if cases != [name for name, _ in expected]:
    errors.append(f"THEME_FIVE_CASES expected={[name for name, _ in expected]} actual={cases}")

for case, title in expected:
    pattern = rf"case\s+\.{re.escape(case)}\s*:\s*\"{re.escape(title)}\""
    if not re.search(pattern, theme):
        errors.append(f"THEME_TITLE_MISSING {case}={title}")

if 'static let storageKey = "novaForgeTheme"' not in theme:
    errors.append("THEME_STORAGE_AUTHORITY_MISSING")
if "ForEach(AgentTheme.allCases)" not in settings:
    errors.append("THEME_SELECTOR_NOT_CASEITERABLE")
if "@AppStorage(AgentTheme.storageKey)" not in settings:
    errors.append("THEME_SELECTOR_NOT_PERSISTED_THROUGH_CANONICAL_KEY")

bad_write = re.compile(
    r"UserDefaults\.standard\.set\s*\(\s*launchTheme\.rawValue\s*,\s*"
    r"forKey\s*:\s*AgentTheme\.storageKey\s*\)",
    re.S,
)
if bad_write.search(app):
    errors.append("THEME_LAUNCH_OVERRIDE_PERSISTS")

if "AgentTheme.launchOverride(" not in app and "AgentTheme.resolvedForLaunch(" not in app:
    errors.append("THEME_LAUNCH_OVERRIDE_NOT_APPLIED")

if errors:
    for error in errors:
        print(f"[preview-release][FAIL] {error}")
    raise SystemExit(1)

print("[preview-release][PASS] THEME_FIVE_CASES")
print("[preview-release][PASS] THEME_TITLES")
print("[preview-release][PASS] THEME_SELECTOR_ALL_CASES")
print("[preview-release][PASS] THEME_PERSISTENCE_AUTHORITY")
print("[preview-release][PASS] THEME_LAUNCH_OVERRIDE_NONPERSISTING")
PY

if (( failures > 0 )); then
  printf '[preview-release][RESULT] FAIL failures=%d\n' "$failures"
  exit 1
fi

printf '[preview-release][RESULT] PASS\n'
