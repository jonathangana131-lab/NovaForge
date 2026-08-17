#!/usr/bin/env python3
from pathlib import Path

path = Path('AgentPad/Services/LocalModelRuntime.swift')
text = path.read_text()
old = '''        let directory = base.appendingPathComponent("LocalModels", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
'''
new = '''        var directory = base.appendingPathComponent("LocalModels", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        return directory
'''
if text.count(old) != 1:
    raise SystemExit(f'modelDirectory marker count={text.count(old)}')
path.write_text(text.replace(old, new))
print('marked LocalModels directory as excluded from backup')
