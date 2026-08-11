#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOUR="$REPO_ROOT/scripts/codex-preview-theme-tour.sh"
VERIFY="$REPO_ROOT/scripts/codex-preview-theme-tour-verify.sh"
THEME="$REPO_ROOT/AgentPad/Design/AgentTheme.swift"
APP="$REPO_ROOT/AgentPad/App/AgentPadApp.swift"
FAST="$REPO_ROOT/scripts/codex-fast-screenshot.sh"

for required in "$TOUR" "$VERIFY" "$THEME" "$APP" "$FAST"; do
  [[ -f "$required" ]] || { echo "missing Preview theme-tour dependency: $required" >&2; exit 1; }
done

bash -n "$TOUR"
bash -n "$VERIFY"

python3 - "$TOUR" "$VERIFY" "$THEME" "$APP" "$FAST" <<'PY'
from pathlib import Path
import re
import sys

tour = Path(sys.argv[1]).read_text()
verify = Path(sys.argv[2]).read_text()
theme = Path(sys.argv[3]).read_text()
app = Path(sys.argv[4]).read_text()
fast = Path(sys.argv[5]).read_text()

canonical = [
    ("matrixRain", "01-matrix-rain"),
    ("midnightBlack", "02-midnight-black"),
    ("whiteGold", "03-white-gold"),
    ("arcticGlass", "04-arctic-glass"),
    ("emberCore", "05-ember-core"),
]
states = ["forge-clean", "pending-approval", "local-ready", "local-missing", "history-proof"]

cases = re.findall(r'^\s*case\s+([A-Za-z][A-Za-z0-9_]*)\s*$', theme, re.MULTILINE)
if cases[:5] != [raw for raw, _ in canonical] or len(set(cases[:5])) != 5:
    raise SystemExit(f"AgentTheme canonical five-world contract drifted: {cases[:5]}")

if 'argument.hasPrefix("--theme-world=")' not in theme:
    raise SystemExit('AgentTheme no longer accepts the --theme-world= screenshot fixture')

# The tour needs an active-process launch override, but deliberately does not
# own whether that override is persisted. The theme durability lane (#230 and
# its Swift implementation) owns that semantic. Accept both the current direct
# resolver and the non-persisting resolvedForLaunch shape so this evidence lane
# cannot freeze an obsolete persistence contract.
if (
    'AgentTheme.launchOverride(from: arguments)' not in app
    and 'AgentTheme.resolvedForLaunch(' not in app
):
    raise SystemExit('missing active launch-theme override resolution in app bootstrap')
if 'AgentPalette.refreshThemeCache(' not in app or 'AgentThemeUIKit.apply(' not in app:
    raise SystemExit('missing active launch-theme application to SwiftUI/UIKit appearance')

for raw, prefix in canonical:
    if f'capture_theme {raw} {prefix}' not in tour:
        raise SystemExit(f"tour missing canonical theme capture: {raw}")
    if raw not in verify:
        raise SystemExit(f"verifier manifest contract missing theme: {raw}")
    for state in states:
        expected = f'{prefix}-{state}.png'
        if expected not in verify:
            raise SystemExit(f"verifier missing expected frame: {expected}")

for state in states:
    if f'capture_state "$theme" "$prefix" {state}' not in tour:
        raise SystemExit(f"tour missing Preview-critical state: {state}")

required_tour_contract = [
    '--reset-ui',
    '"--theme-world=$theme"',
    '--pending-approval-demo',
    '--settings-local-model-ready',
    '--first-run-local-model-missing',
    '--project-proof-demo',
    'expected_png_count=25',
    'SOURCE_SHA="$(git -C "$ROOT_DIR" rev-parse HEAD',
    'This is capture evidence, not visual acceptance by itself.',
]
for needle in required_tour_contract:
    if needle not in tour:
        raise SystemExit(f"theme tour lost required contract: {needle}")

required_verify_contract = [
    'expected_png_count=25',
    'VERIFY_UNIQUE_THEME_FRAMES',
    'Theme tour manifest is not bound to an exact source SHA.',
    'Image integrity/coverage passing is not visual-design acceptance by itself.',
]
for needle in required_verify_contract:
    if needle not in verify:
        raise SystemExit(f"theme tour verifier lost required contract: {needle}")

if 'INSTALL_IF_NEWER="${INSTALL_IF_NEWER:-1}"' not in fast:
    raise SystemExit('codex-fast-screenshot no longer exposes install-if-newer reuse contract')
if '"${LAUNCH_ARGS[@]}"' not in fast:
    raise SystemExit('codex-fast-screenshot no longer forwards exact launch arguments')

expected_frame_names = re.findall(r'^\s+[0-9]{2}-[a-z-]+\.png$', verify, re.MULTILINE)
if len(expected_frame_names) != 25 or len(set(name.strip() for name in expected_frame_names)) != 25:
    raise SystemExit(f"expected exactly 25 unique theme-tour frame names, got {len(expected_frame_names)}")

if '--open-terminal' in tour:
    raise SystemExit('Preview theme matrix should focus on normal-user release surfaces, not Terminal/Pro UI')

print('V14 Preview theme-tour contract PASS: 5 themes x 5 release states, active launch override, exact-SHA manifest, duplicate/image/semantic guards')
PY
