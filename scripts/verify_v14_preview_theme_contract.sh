#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
theme="$repo_root/AgentPad/Design/AgentTheme.swift"
settings="$repo_root/AgentPad/Views/SettingsView.swift"
components="$repo_root/AgentPad/Views/SettingsComponents.swift"
app="$repo_root/AgentPad/App/AgentPadApp.swift"
ui_tests="$repo_root/AgentPadUITests/AgentPadUITests.swift"

for path in "$theme" "$settings" "$components" "$app" "$ui_tests"; do
  [[ -f "$path" ]] || { echo "Preview theme contract: missing ${path#$repo_root/}" >&2; exit 1; }
done

python3 - "$theme" "$settings" "$components" "$app" "$ui_tests" <<'PY'
from pathlib import Path
import re
import sys

theme = Path(sys.argv[1]).read_text()
settings = Path(sys.argv[2]).read_text()
components = Path(sys.argv[3]).read_text()
app = Path(sys.argv[4]).read_text()
ui_tests = Path(sys.argv[5]).read_text()

expected = [
    ("matrixRain", "Matrix Rain"),
    ("midnightBlack", "Midnight Black"),
    ("whiteGold", "White Gold"),
    ("arcticGlass", "Arctic Glass"),
    ("emberCore", "Ember Core"),
]

header = theme.split('static let storageKey', 1)[0]
cases = re.findall(r'^\s*case\s+([A-Za-z0-9_]+)\s*$', header, flags=re.MULTILINE)
expected_cases = [case for case, _ in expected]
if cases != expected_cases:
    raise SystemExit(f"expected exactly five canonical theme worlds {expected_cases}, found {cases}")

required_theme = [
    'static let storageKey = "novaForgeTheme"',
    'static let defaultTheme: AgentTheme = .midnightBlack',
    'static func normalizeStoredTheme() -> AgentTheme',
    'static func launchOverride(from arguments: [String]) -> AgentTheme?',
    'return AgentTheme(rawValue: rawValue) ?? theme(matching: rawValue) ?? .defaultTheme',
    'case .whiteGold: .light',
    'default: .dark',
]
for needle in required_theme:
    if needle not in theme:
        raise SystemExit(f"missing theme persistence/resolution contract: {needle}")

for case, title in expected:
    if f'case .{case}: "{title}"' not in theme:
        raise SystemExit(f"missing public title for {case}: {title}")

required_settings = [
    '@AppStorage(AgentTheme.storageKey) private var selectedThemeRawValue = AgentTheme.defaultTheme.rawValue',
    'ForEach(AgentTheme.allCases) { theme in',
    'selectedThemeRawValue = theme.rawValue',
    'AgentPalette.refreshThemeCache(theme)',
    'AgentThemeUIKit.apply(theme)',
]
for needle in required_settings:
    if needle not in settings:
        raise SystemExit(f"missing Settings theme-selection contract: {needle}")

if '.accessibilityIdentifier("settingsThemeStudioCard-\\(theme.rawValue)")' not in components:
    raise SystemExit('missing stable accessibility identity for theme studio cards')

required_app = [
    '@AppStorage(AgentTheme.storageKey) private var selectedThemeRawValue = AgentTheme.defaultTheme.rawValue',
    'if let launchTheme = AgentTheme.launchOverride(from: arguments)',
    'UserDefaults.standard.set(launchTheme.rawValue, forKey: AgentTheme.storageKey)',
    'AgentPalette.refreshThemeCache(AgentTheme.normalizeStoredTheme())',
    'AgentThemeUIKit.apply(AgentTheme.current)',
    '.preferredColorScheme(selectedTheme.preferredColorScheme)',
]
for needle in required_app:
    if needle not in app:
        raise SystemExit(f"missing app launch/relaunch theme contract: {needle}")

required_ui_proof = [
    'func testGoalMatrixChatReadabilityAndThemeSwitchingScreenshots() throws',
    'settingsThemeStudioCard-matrixRain',
    'settingsThemeStudioCard-midnightBlack',
    'Control should durably select Matrix before switching away from it.',
    'Control should finish applying Midnight before visual proof is captured.',
]
for needle in required_ui_proof:
    if needle not in ui_tests:
        raise SystemExit(f"missing existing interactive theme proof hook: {needle}")

print('Preview theme contract: five canonical worlds + persisted Settings/app wiring + existing Matrix/Midnight interactive proof hook')
PY
