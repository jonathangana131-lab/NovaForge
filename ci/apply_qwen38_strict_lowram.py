#!/usr/bin/env python3
from pathlib import Path

path = Path('AgentPad/Services/LocalModelRuntime.swift')
text = path.read_text()

replacements = []

replacements.append((
'''enum Qwen38ReleaseDiscovery {
    static let unavailableModelID = "qwen3.8-27b-awaiting-verified-open-weights"
''',
'''enum Qwen38ReleaseDiscovery {
    static let unavailableModelID = "qwen3.8-27b-awaiting-verified-open-weights"

    /// A non-runnable sentinel used while exact Qwen 3.8 27B open weights do not
    /// exist. Keeping the manager on this identity prevents any hidden fallback
    /// model from being selected or downloaded in the Qwen-3.8-only build.
    static let unavailableVariant = LocalModelVariant(
        id: unavailableModelID,
        displayName: "Qwen 3.8 27B — Awaiting Open Weights",
        shortName: "Qwen 3.8 27B",
        quantization: "Awaiting verified release",
        filename: "qwen3.8-27b.awaiting-release",
        downloadURL: URL(string: "https://huggingface.co/Qwen")!,
        expectedBytes: 0,
        expectedSHA256: String(repeating: "0", count: 64),
        minimumPhysicalMemoryBytes: 3_800_000_000,
        recommendedFreeDiskBytes: 0,
        contextTokens: 4_096,
        batchTokens: 16,
        maxNewTokens: 512,
        maxGenerationSeconds: 300,
        useGPU: false,
        gpuLayerCount: 0,
        generationThreadCount: 1,
        batchThreadCount: 1,
        isIPhone12SafeDefault: false,
        releaseDateISO8601: "",
        releaseDateLabel: "Not released",
        parameterLabel: "27B",
        licenseLabel: "Awaiting model card",
        benchmarkSummary: "Exact Qwen 3.8 27B weights have not been verified yet",
        capabilitySummary: "Release watcher active · no substitute model allowed",
        deviceFit: .extreme,
        estimatedPeakMemoryBytes: 0,
        minimumAvailableMemoryBeforeLoadBytes: 0,
        sourceURL: URL(string: "https://huggingface.co/Qwen")!,
        details: "NovaForge is locked to Qwen 3.8 27B. Refresh release discovery after verified open weights are published; no Qwen 3.6, 3.5, or small-model fallback will be loaded."
    )
'''))

replacements.append((
'''            URLQueryItem(name: "search", value: "Qwen3.8 27B GGUF"),
            URLQueryItem(name: "limit", value: "50"),
''',
'''            URLQueryItem(name: "search", value: "Qwen3.8 27B"),
            URLQueryItem(name: "limit", value: "100"),
'''))

replacements.append((
'''        for marker in ["UD-IQ2_XXS", "IQ2_XXS", "IQ2_XS", "Q2_K_XS", "Q2_K", "Q3_K_XS", "Q3_K_S", "Q3_K_M", "Q4_K_M"] where upper.contains(marker) {
            return marker
        }
''',
'''        // Prefer native ultra-low-bit formats first. Current ggml/llama.cpp
        // has Q1_0 (1.125 bpw), IQ1, Q2_0 and ternary TQ families; keeping
        // these explicit means a future exact Qwen 3.8 27B release can fit the
        // iPhone-12 storage-backed path without an app update.
        for marker in [
            "Q1_0_G128", "Q1_0", "IQ1_S", "TQ1_0", "IQ1_M",
            "TQ2_0", "Q2_0", "UD-IQ2_XXS", "IQ2_XXS", "IQ2_XS",
            "Q2_K_XS", "Q2_K", "Q3_K_XS", "Q3_K_S", "Q3_K_M", "Q4_K_M"
        ] where upper.contains(marker) {
            return marker
        }
'''))

replacements.append((
'''        switch value.uppercased() {
        case "UD-IQ2_XXS": 0
        case "IQ2_XXS": 1
        case "IQ2_XS": 2
        case "Q2_K_XS": 3
        case "Q2_K": 4
        case "Q3_K_XS": 5
        case "Q3_K_S": 6
        case "Q3_K_M": 7
        case "Q4_K_M": 8
        default: 20
        }
''',
'''        switch value.uppercased() {
        case "Q1_0_G128": 0
        case "Q1_0": 1
        case "IQ1_S": 2
        case "TQ1_0": 3
        case "IQ1_M": 4
        case "TQ2_0": 5
        case "Q2_0": 6
        case "UD-IQ2_XXS": 7
        case "IQ2_XXS": 8
        case "IQ2_XS": 9
        case "Q2_K_XS": 10
        case "Q2_K": 11
        case "Q3_K_XS": 12
        case "Q3_K_S": 13
        case "Q3_K_M": 14
        case "Q4_K_M": 15
        default: 40
        }
'''))

replacements.append((
'''    static var presentationOrder: [LocalModelVariant] {
        exactQwen38Variant.map { [$0] } ?? []
    }

    static var defaultVariant: LocalModelVariant {
        exactQwen38Variant ?? safestVariant()
    }

    static func variant(for id: String) -> LocalModelVariant? {
        if let target = exactQwen38Variant, target.id == id { return target }
        return all.first { $0.id == id }
    }
''',
'''    static var presentationOrder: [LocalModelVariant] {
        [exactQwen38Variant ?? Qwen38ReleaseDiscovery.unavailableVariant]
    }

    static var defaultVariant: LocalModelVariant {
        exactQwen38Variant ?? Qwen38ReleaseDiscovery.unavailableVariant
    }

    static func variant(for id: String) -> LocalModelVariant? {
        if let target = exactQwen38Variant, target.id == id { return target }
        if id == Qwen38ReleaseDiscovery.unavailableModelID {
            return Qwen38ReleaseDiscovery.unavailableVariant
        }
        return nil
    }
'''))

replacements.append((
'''    ) -> String? {
        if physicalMemory < variant.minimumPhysicalMemoryBytes {
''',
'''    ) -> String? {
        if variant.id == Qwen38ReleaseDiscovery.unavailableModelID {
            return "Exact Qwen 3.8 27B open weights have not been verified yet. Tap Refresh Qwen 3.8 Release after the model is published; NovaForge will not substitute another model."
        }

        if physicalMemory < variant.minimumPhysicalMemoryBytes {
'''))

for old, new in replacements:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'expected exactly one match, found {count}: {old[:80]!r}')
    text = text.replace(old, new)

path.write_text(text)
print('PASS: staged strict Qwen 3.8-only low-memory discovery/runtime policy')
