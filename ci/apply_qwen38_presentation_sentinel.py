#!/usr/bin/env python3
from pathlib import Path

path = Path('AgentPad/Services/LocalModelRuntime.swift')
text = path.read_text()
old = '''    static var presentationOrder: [LocalModelVariant] {
        exactQwen38Variant.map { [$0] } ?? []
    }
'''
new = '''    static var presentationOrder: [LocalModelVariant] {
        [exactQwen38Variant ?? Qwen38ReleaseDiscovery.unavailableVariant]
    }
'''
if text.count(old) != 1:
    raise SystemExit(f'expected one presentationOrder target, found {text.count(old)}')
path.write_text(text.replace(old, new))
print('PASS: staged Qwen 3.8 awaiting-release presentation invariant')
