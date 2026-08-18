#!/usr/bin/env python3
from pathlib import Path

path = Path('AgentPadUITests/AgentPadUITests.swift')
text = path.read_text()
old_id = 'composerModel-Qwen/Qwen2.5-Coder-1.5B-Instruct-Q4_K_M'
new_id = 'composerModel-qwen3.8-27b-awaiting-verified-open-weights'
count = text.count(old_id)
if count not in (0, 2):
    raise SystemExit(f'expected 0 or 2 stale local chooser IDs, found {count}')
if count:
    text = text.replace(old_id, new_id)

text = text.replace(
    'The local provider should reveal iPhone-safe local models in the same chooser.',
    'The local provider should reveal only the exact Qwen 3.8 27B target in the same chooser.',
)

# The legacy name may remain only inside assertions that prove stale provider
# state gets repaired. It must never be a selectable local model identifier.
if old_id in text:
    raise SystemExit('stale Qwen2.5 composer model identifier remains selectable')
if text.count(new_id) < 2:
    raise SystemExit('exact Qwen 3.8 composer model contract is missing')

path.write_text(text)
print('PASS: staged exact-Qwen-3.8-only composer UI contract')
