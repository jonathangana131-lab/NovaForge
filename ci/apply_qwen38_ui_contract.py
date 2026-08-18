#!/usr/bin/env python3
from pathlib import Path

path = Path('AgentPadUITests/AgentPadUITests.swift')
text = path.read_text()
changed = False

old_id = 'composerModel-Qwen/Qwen2.5-Coder-1.5B-Instruct-Q4_K_M'
new_id = 'composerModel-qwen3.8-27b-awaiting-verified-open-weights'
count = text.count(old_id)
if count not in (0, 2):
    raise SystemExit(f'expected 0 or 2 stale local chooser IDs, found {count}')
if count:
    text = text.replace(old_id, new_id)
    changed = True

old_message = 'The local provider should reveal iPhone-safe local models in the same chooser.'
new_message = 'The local provider should reveal only the exact Qwen 3.8 27B target in the same chooser.'
if old_message in text:
    text = text.replace(old_message, new_message)
    changed = True

# The visual Models proof must render the real exact-target sentinel while open
# Qwen 3.8 27B weights are unavailable. It must never keep historical private
# fixture models in the product screenshot contract.
visual_replacements = {
    'app.staticTexts["Qwen Coder 1.5B — iPhone 12"]':
        'app.staticTexts["Qwen 3.8 27B — Awaiting Open Weights"]',
    'app.staticTexts["Atlas 2"]':
        'app.staticTexts["Qwen 3.8 27B — Awaiting Open Weights"]',
    '"The primary local-model picker should show the release date before selection."':
        '"The exact Qwen 3.8 target should show its verified release state before selection."',
}
for old, new in visual_replacements.items():
    if old in text:
        text = text.replace(old, new)
        changed = True

old_date_assert = '''app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Jul 20, 2026")).firstMatch.waitForExistence(timeout: 5)'''
new_date_assert = '''app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Not released")).firstMatch.waitForExistence(timeout: 5)'''
if old_date_assert in text:
    text = text.replace(old_date_assert, new_date_assert)
    changed = True

# The legacy name may remain only inside hidden fixture data and stale-provider
# repair assertions. It must never be a selectable local model identifier or a
# visual Models-screen expectation.
if old_id in text:
    raise SystemExit('stale Qwen2.5 composer model identifier remains selectable')
if text.count(new_id) < 2:
    raise SystemExit('exact Qwen 3.8 composer model contract is missing')
for stale in (
    'app.staticTexts["Qwen Coder 1.5B — iPhone 12"]',
    'app.staticTexts["Atlas 2"]',
    'label CONTAINS %@", "Jul 20, 2026"',
):
    if stale in text:
        raise SystemExit(f'stale visual local-model contract remains: {stale}')

if 'app.staticTexts["Qwen 3.8 27B — Awaiting Open Weights"]' not in text:
    raise SystemExit('visual exact-Qwen-3.8 sentinel assertion is missing')
if 'label CONTAINS %@", "Not released"' not in text:
    raise SystemExit('visual exact-Qwen-3.8 release-state assertion is missing')

if changed:
    path.write_text(text)
print('PASS: staged exact-Qwen-3.8-only composer + visual Models UI contract')
