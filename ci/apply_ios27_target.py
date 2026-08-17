#!/usr/bin/env python3
from pathlib import Path

path = Path('AgentPad.xcodeproj/project.pbxproj')
text = path.read_text()
old = 'IPHONEOS_DEPLOYMENT_TARGET = 26.0;'
new = 'IPHONEOS_DEPLOYMENT_TARGET = 27.0;'
count = text.count(old)
if count < 4:
    raise SystemExit(f'expected multiple iOS 26 target declarations, found {count}')
text = text.replace(old, new)
if 'IPHONEOS_DEPLOYMENT_TARGET = 26.0;' in text:
    raise SystemExit('iOS 26 deployment target remains')
path.write_text(text)
print(f'raised {count} deployment-target declarations to iOS 27.0')
