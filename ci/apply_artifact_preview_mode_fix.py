#!/usr/bin/env python3
"""Keep web-preview mode identity stable while load state changes.

The preview title describes the presentation mode (normal vs fullscreen), while
loading/error/readiness belongs in the detail/status line. This also keeps the
mode visible to VoiceOver and UI automation as soon as the preview studio opens.
The transform is deliberately idempotent so exact-tree CI may run repeatedly.
"""
from pathlib import Path

PATH = Path("AgentPad/Views/ArtifactPreviewSheet.swift")
source = PATH.read_text(encoding="utf-8")
old = '''    private var previewHintTitle: String {\n        if artifact.isWebPage {\n            switch previewLoadState {\n            case .loading: return "Loading preview"\n            case .failed: return "Preview unavailable"\n            case .ready: break\n            }\n        }\n        if artifact.isSwiftGameArtifact { return "Native game ready" }\n        if artifact.isWebPage { return "Normal preview" }\n'''
new = '''    private var previewHintTitle: String {\n        // This is the preview *mode*, not its transient network/render state.\n        // Keep it stable while WebKit moves through loading/ready/failed so the\n        // user always knows they are in the normal embedded preview surface.\n        if artifact.isWebPage { return "Normal preview" }\n        if artifact.isSwiftGameArtifact { return "Native game ready" }\n'''

if old in source:
    if source.count(old) != 1:
        raise SystemExit("preview title marker is ambiguous")
    source = source.replace(old, new, 1)
    PATH.write_text(source, encoding="utf-8")
    print(f"patched {PATH}")
elif new in source:
    print(f"already patched {PATH}")
else:
    raise SystemExit("preview title marker drifted: neither old nor patched form exists")

updated = PATH.read_text(encoding="utf-8")
if updated.count('if artifact.isWebPage { return "Normal preview" }') != 1:
    raise SystemExit("post-transform preview mode validation failed")
