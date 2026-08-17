#!/usr/bin/env python3
"""Fail-closed one-shot patch for the 27B Extreme device-fit presentation."""
from pathlib import Path

path = Path("AgentPad/Views/SettingsComponents.swift")
source = path.read_text(encoding="utf-8")

old = '''        case .deviceProven: AgentPalette.cyan\n        case .ultraLight: AgentPalette.cyan\n        case .memorySaver: AgentPalette.lilac\n'''
new = '''        case .deviceProven: AgentPalette.cyan\n        case .ultraLight: AgentPalette.cyan\n        case .memorySaver: AgentPalette.lilac\n        case .extreme: AgentPalette.rose\n'''

if old in source:
    if source.count(old) != 1:
        raise SystemExit(f"fitColor marker is not unique: {source.count(old)}")
    source = source.replace(old, new, 1)
elif "case .extreme: AgentPalette.rose" not in source:
    raise SystemExit("fitColor marker drifted")

if source.count("case .extreme: AgentPalette.rose") != 1:
    raise SystemExit("post-transform extreme fit color validation failed")

path.write_text(source, encoding="utf-8")
print(f"patched {path}")
