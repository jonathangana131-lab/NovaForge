#!/usr/bin/env python3
"""One-shot deterministic source transform for the Qwen 27B Extreme catalog entry.

This exists so the production LocalModelRuntime stays the single source of truth
for download/resume/checksum/admission/provider behavior. The transform is
fail-closed: every marker must match exactly once and the resulting source is
validated before it is written.
"""
from pathlib import Path

PATH = Path("AgentPad/Services/LocalModelRuntime.swift")

source = PATH.read_text(encoding="utf-8")

replacements = [
    (
        """enum LocalModelDeviceFit: String, Sendable, Hashable {\n    case deviceProven\n    case ultraLight\n    case memorySaver\n""",
        """enum LocalModelDeviceFit: String, Sendable, Hashable {\n    case deviceProven\n    case ultraLight\n    case memorySaver\n    case extreme\n""",
    ),
    (
        """        case .memorySaver: \"Memory saver\"\n        }\n""",
        """        case .memorySaver: \"Memory saver\"\n        case .extreme: \"27B Extreme\"\n        }\n""",
    ),
    (
        """        case .memorySaver: \"memorychip.fill\"\n        }\n""",
        """        case .memorySaver: \"memorychip.fill\"\n        case .extreme: \"externaldrive.badge.timemachine\"\n        }\n""",
    ),
]

for old, new in replacements:
    count = source.count(old)
    if count != 1:
        raise SystemExit(f"expected exactly one marker, found {count}: {old[:80]!r}")
    source = source.replace(old, new, 1)

atlas_tail = '''            details: "NovaForge pins an exact GGUF revision and checksum, then caps context and output for its iPhone-targeted profile."\n        )\n    ]'''

qwen_variant = '''            details: "NovaForge pins an exact GGUF revision and checksum, then caps context and output for its iPhone-targeted profile."\n        ),\n        .init(\n            id: "unsloth/Qwen3.6-27B-UD-IQ2_XXS",\n            displayName: "Qwen3.6 27B — Extreme",\n            shortName: "Qwen 27B Extreme",\n            quantization: "UD-IQ2_XXS",\n            filename: "Qwen3.6-27B-UD-IQ2_XXS.gguf",\n            downloadURL: URL(string: "https://huggingface.co/unsloth/Qwen3.6-27B-GGUF/resolve/0d948e3cb47ffa30812abe67cf4f42d38b0dceb2/Qwen3.6-27B-UD-IQ2_XXS.gguf?download=true")!,\n            expectedBytes: 9_388_779_744,\n            expectedSHA256: "968bfc712832031afebec339da3ae61c6822ab9a118e1d72b6be2a7781a96e30",\n            minimumPhysicalMemoryBytes: 3_800_000_000,\n            recommendedFreeDiskBytes: 12_500_000_000,\n            contextTokens: 4_096,\n            batchTokens: 24,\n            maxNewTokens: 384,\n            maxGenerationSeconds: 240,\n            useGPU: true,\n            gpuLayerCount: 1,\n            generationThreadCount: 2,\n            batchThreadCount: 4,\n            isIPhone12SafeDefault: false,\n            releaseDateISO8601: "2026-04-22",\n            releaseDateLabel: "Apr 22, 2026",\n            parameterLabel: "27B",\n            licenseLabel: "Apache 2.0",\n            benchmarkSummary: "Storage-backed research target · exact-device qualification pending",\n            capabilitySummary: "Agentic coding · repository reasoning · long-project planning",\n            deviceFit: .extreme,\n            estimatedPeakMemoryBytes: 2_050_000_000,\n            minimumAvailableMemoryBeforeLoadBytes: 1_250_000_000,\n            sourceURL: URL(string: "https://huggingface.co/unsloth/Qwen3.6-27B-GGUF/blob/0d948e3cb47ffa30812abe67cf4f42d38b0dceb2/Qwen3.6-27B-UD-IQ2_XXS.gguf")!,\n            details: "A verified 9.39 GB ultra-low-bit 27B target for storage-backed research mode. NovaForge keeps the GGUF on disk, uses mmap and bounded hot Metal residency, compresses KV to Q8 by default, and keeps the physical context deliberately small while Project Capsule retrieval carries long-project continuity. No iPhone 12 speed or reliability label is granted until exact-device receipts exist."\n        )\n    ]'''

count = source.count(atlas_tail)
if count != 1:
    raise SystemExit(f"expected exactly one Atlas tail marker, found {count}")
source = source.replace(atlas_tail, qwen_variant, 1)

# Extreme is intentionally opt-in. Never let the fallback selection choose it
# just because physical RAM clears the minimum.
old_safest = '''        all.first { $0.isIPhone12SafeDefault && physicalMemory >= $0.minimumPhysicalMemoryBytes }\n            ?? all.first { physicalMemory >= $0.minimumPhysicalMemoryBytes }\n            ?? all.last!'''
new_safest = '''        all.first { $0.isIPhone12SafeDefault && physicalMemory >= $0.minimumPhysicalMemoryBytes }\n            ?? all.first { $0.deviceFit != .extreme && physicalMemory >= $0.minimumPhysicalMemoryBytes }\n            ?? all.first { $0.deviceFit != .extreme }\n            ?? all.last!'''
if source.count(old_safest) != 1:
    raise SystemExit("safestVariant marker drifted")
source = source.replace(old_safest, new_safest, 1)

required = [
    'case extreme',
    'id: "unsloth/Qwen3.6-27B-UD-IQ2_XXS"',
    'expectedBytes: 9_388_779_744',
    'expectedSHA256: "968bfc712832031afebec339da3ae61c6822ab9a118e1d72b6be2a7781a96e30"',
    'deviceFit: .extreme',
]
for needle in required:
    if source.count(needle) != 1:
        raise SystemExit(f"post-transform validation failed for {needle!r}")

PATH.write_text(source, encoding="utf-8")
print(f"patched {PATH}")
