#!/usr/bin/env python3
"""Make unreleased/zero-byte Qwen 3.8 sentinels impossible to download/promote.

This is intentionally a fail-closed source transform because LocalModelRuntime.swift
is large and shared by the production app and test target. The transform is
idempotent and refuses to modify drifted source.
"""
from pathlib import Path

PATH = Path("AgentPad/Services/LocalModelRuntime.swift")
source = PATH.read_text(encoding="utf-8")

old_download = '''    static func download(\n        variant: LocalModelVariant,\n        destination: URL,\n        progress: @escaping @Sendable (LocalModelDownloadProgress) async -> Void\n    ) async throws {\n        let directory = destination.deletingLastPathComponent()\n'''
new_download = '''    static func download(\n        variant: LocalModelVariant,\n        destination: URL,\n        progress: @escaping @Sendable (LocalModelDownloadProgress) async -> Void\n    ) async throws {\n        try validateDownloadableVariant(variant)\n        let directory = destination.deletingLastPathComponent()\n'''

old_validate = '''    static func validateCompleteDownload(variant: LocalModelVariant, receivedBytes: Int64) throws {\n        let expectedBytes = variant.expectedBytes\n        guard receivedBytes == expectedBytes else {\n'''
new_validate = '''    static func validateDownloadableVariant(_ variant: LocalModelVariant) throws {\n        guard variant.expectedBytes > 0,\n              !variant.expectedSHA256.isEmpty,\n              variant.downloadURL.host?.lowercased() != "example.invalid"\n        else {\n            throw LocalModelRuntimeError.downloadFailed(\n                "Qwen 3.8 27B public weights are not available yet. Check for the verified release before downloading."\n            )\n        }\n    }\n\n    static func validateCompleteDownload(variant: LocalModelVariant, receivedBytes: Int64) throws {\n        try validateDownloadableVariant(variant)\n        let expectedBytes = variant.expectedBytes\n        guard receivedBytes == expectedBytes else {\n'''

changed = False
if old_download in source:
    if source.count(old_download) != 1:
        raise SystemExit("download marker ambiguous")
    source = source.replace(old_download, new_download, 1)
    changed = True
elif new_download not in source:
    raise SystemExit("download marker drifted")

if old_validate in source:
    if source.count(old_validate) != 1:
        raise SystemExit("validation marker ambiguous")
    source = source.replace(old_validate, new_validate, 1)
    changed = True
elif new_validate not in source:
    raise SystemExit("validation marker drifted")

if source.count("try validateDownloadableVariant(variant)") < 2:
    raise SystemExit("post-transform guard count invalid")
if "Qwen 3.8 27B public weights are not available yet" not in source:
    raise SystemExit("post-transform release guard missing")

if changed:
    PATH.write_text(source, encoding="utf-8")
    print(f"patched {PATH}")
else:
    print(f"already patched {PATH}")
