#!/usr/bin/env python3
"""Wire SwiftLlama's content-free timing snapshot into NovaForge benchmark UI.

This is a fail-closed one-shot source transform because the three production
files are large and are safer to mutate against exact source markers than to
replace wholesale through the Contents API.
"""
from pathlib import Path

RUNTIME = Path("AgentPad/Services/LocalModelRuntime.swift")
AGENT = Path("AgentPad/Services/AgentRuntime.swift")
UI = Path("AgentPad/Views/ModelManagerPanels.swift")

runtime = RUNTIME.read_text(encoding="utf-8")
agent = AGENT.read_text(encoding="utf-8")
ui = UI.read_text(encoding="utf-8")

old_result = '''struct LocalModelBenchmarkResult: Equatable, Sendable {\n    let modelName: String\n    let timeToFirstToken: TimeInterval\n    let totalDuration: TimeInterval\n    let generatedCharacters: Int\n\n    /// Rough token estimate — llama.cpp doesn't surface counts through this\n    /// path, and honest ≈ beats fabricated precision.\n    var estimatedTokens: Int { max(1, Int(Double(generatedCharacters) / 3.8)) }\n\n    var tokensPerSecond: Double {\n        let generation = max(totalDuration - timeToFirstToken, 0.05)\n        return Double(estimatedTokens) / generation\n    }\n}\n'''
new_result = '''struct LocalModelPerformanceSnapshot: Equatable, Sendable {\n    let prefillDuration: TimeInterval\n    let timeToFirstToken: TimeInterval?\n    let decodeDuration: TimeInterval\n    let generatedTokens: Int\n    let decodeTokensPerSecond: Double\n    let runtimeProfile: String\n}\n\nstruct LocalModelBenchmarkResult: Equatable, Sendable {\n    let modelName: String\n    let timeToFirstToken: TimeInterval\n    let totalDuration: TimeInterval\n    let generatedCharacters: Int\n    let prefillDuration: TimeInterval?\n    let decodeDuration: TimeInterval?\n    let generatedTokens: Int?\n    let exactTokensPerSecond: Double?\n    let runtimeProfile: String?\n\n    init(\n        modelName: String,\n        timeToFirstToken: TimeInterval,\n        totalDuration: TimeInterval,\n        generatedCharacters: Int,\n        prefillDuration: TimeInterval? = nil,\n        decodeDuration: TimeInterval? = nil,\n        generatedTokens: Int? = nil,\n        exactTokensPerSecond: Double? = nil,\n        runtimeProfile: String? = nil\n    ) {\n        self.modelName = modelName\n        self.timeToFirstToken = max(0, timeToFirstToken)\n        self.totalDuration = max(0, totalDuration)\n        self.generatedCharacters = max(0, generatedCharacters)\n        self.prefillDuration = prefillDuration.map { max(0, $0) }\n        self.decodeDuration = decodeDuration.map { max(0, $0) }\n        self.generatedTokens = generatedTokens.map { max(0, $0) }\n        self.exactTokensPerSecond = exactTokensPerSecond.map { max(0, $0) }\n        self.runtimeProfile = runtimeProfile\n    }\n\n    /// Retained only as an explicit fallback for inference backends that do not\n    /// yet expose exact token accounting. llama.cpp-backed runs use the exact\n    /// generated-token count and decode timing from LlamaService.\n    var estimatedTokens: Int { max(1, Int(Double(generatedCharacters) / 3.8)) }\n\n    var hasExactTokenTelemetry: Bool {\n        generatedTokens != nil && exactTokensPerSecond != nil\n    }\n\n    var tokensPerSecond: Double {\n        if let exactTokensPerSecond { return exactTokensPerSecond }\n        let generation = max(totalDuration - timeToFirstToken, 0.05)\n        return Double(estimatedTokens) / generation\n    }\n\n    var displayedTokenCount: Int {\n        generatedTokens ?? estimatedTokens\n    }\n}\n'''
if old_result in runtime:
    if runtime.count(old_result) != 1:
        raise SystemExit("LocalModelBenchmarkResult marker not unique")
    runtime = runtime.replace(old_result, new_result, 1)
elif "struct LocalModelPerformanceSnapshot: Equatable, Sendable" not in runtime:
    raise SystemExit("LocalModelBenchmarkResult marker drifted")

service_anchor = '''    func stop(model: String) async {\n        #if canImport(SwiftLlama)\n        let variant = LocalModelCatalog.variant(for: model) ?? LocalModelCatalog.defaultVariant\n        if loadedService?.variantID == variant.id,\n           let service = loadedService?.service {\n            await service.stopCompletion()\n        }\n        #endif\n    }\n\n'''
service_insert = '''    func stop(model: String) async {\n        #if canImport(SwiftLlama)\n        let variant = LocalModelCatalog.variant(for: model) ?? LocalModelCatalog.defaultVariant\n        if loadedService?.variantID == variant.id,\n           let service = loadedService?.service {\n            await service.stopCompletion()\n        }\n        #endif\n    }\n\n    /// Returns only content-free timing/counter telemetry for the currently\n    /// loaded model. Prompt text, generated text, token ids and file paths are\n    /// deliberately absent from this bridge.\n    func performanceSnapshot(modelID: String) async -> LocalModelPerformanceSnapshot? {\n        #if canImport(SwiftLlama)\n        guard let loadedService, loadedService.variantID == modelID,\n              let snapshot = await loadedService.service.performanceSnapshot()\n        else { return nil }\n        return LocalModelPerformanceSnapshot(\n            prefillDuration: snapshot.prefillSeconds,\n            timeToFirstToken: snapshot.timeToFirstTokenSeconds,\n            decodeDuration: snapshot.decodeSeconds,\n            generatedTokens: snapshot.generatedTokenCount,\n            decodeTokensPerSecond: snapshot.decodeTokensPerSecond,\n            runtimeProfile: snapshot.runtimeReason\n        )\n        #else\n        return nil\n        #endif\n    }\n\n'''
if service_anchor in runtime:
    if runtime.count(service_anchor) != 1:
        raise SystemExit("LocalModelClient stop marker not unique")
    runtime = runtime.replace(service_anchor, service_insert, 1)
elif "func performanceSnapshot(modelID: String)" not in runtime:
    raise SystemExit("LocalModelClient stop marker drifted")

old_return = '''        let finished = Date()\n        let first = probe.firstBatchAt ?? finished\n        return .success(LocalModelBenchmarkResult(\n            modelName: variant.shortName,\n            timeToFirstToken: first.timeIntervalSince(started),\n            totalDuration: finished.timeIntervalSince(started),\n            generatedCharacters: probe.characters\n        ))\n'''
new_return = '''        let finished = Date()\n        let first = probe.firstBatchAt ?? finished\n        let exact = await localModelClient.performanceSnapshot(modelID: variant.id)\n        return .success(LocalModelBenchmarkResult(\n            modelName: variant.shortName,\n            timeToFirstToken: exact?.timeToFirstToken ?? first.timeIntervalSince(started),\n            totalDuration: finished.timeIntervalSince(started),\n            generatedCharacters: probe.characters,\n            prefillDuration: exact?.prefillDuration,\n            decodeDuration: exact?.decodeDuration,\n            generatedTokens: exact?.generatedTokens,\n            exactTokensPerSecond: exact?.decodeTokensPerSecond,\n            runtimeProfile: exact?.runtimeProfile\n        ))\n'''
if old_return in agent:
    if agent.count(old_return) != 1:
        raise SystemExit("benchmark return marker not unique")
    agent = agent.replace(old_return, new_return, 1)
elif "let exact = await localModelClient.performanceSnapshot" not in agent:
    raise SystemExit("benchmark return marker drifted")

old_finished = '''            case .finished(let result):\n                HStack(spacing: 8) {\n                    benchmarkMetric(value: String(format: "%.0f", endToEndCharactersPerSecond(result)), unit: "e2e chars/s", tint: AgentPalette.green)\n                    benchmarkMetric(value: String(format: "%.2fs", result.timeToFirstToken), unit: "first output", tint: AgentPalette.cyan)\n                    benchmarkMetric(value: String(format: "%.1fs", result.totalDuration), unit: "total", tint: AgentPalette.lilac)\n                }\n                Text("\\(result.modelName) · \\(result.generatedCharacters) observed characters · not qualification evidence")\n                    .font(.system(size: 9, weight: .semibold, design: AgentPalette.interfaceFontDesign))\n                    .foregroundStyle(AgentPalette.tertiaryText)\n'''
new_finished = '''            case .finished(let result):\n                HStack(spacing: 8) {\n                    benchmarkMetric(\n                        value: String(format: result.hasExactTokenTelemetry ? "%.2f" : "≈%.2f", result.tokensPerSecond),\n                        unit: result.hasExactTokenTelemetry ? "decode tok/s" : "estimated tok/s",\n                        tint: AgentPalette.green\n                    )\n                    benchmarkMetric(value: String(format: "%.2fs", result.timeToFirstToken), unit: "TTFT", tint: AgentPalette.cyan)\n                    benchmarkMetric(\n                        value: result.prefillDuration.map { String(format: "%.2fs", $0) } ?? String(format: "%.1fs", result.totalDuration),\n                        unit: result.prefillDuration == nil ? "total" : "prefill",\n                        tint: AgentPalette.lilac\n                    )\n                }\n                Text(benchmarkDetail(result))\n                    .font(.system(size: 9, weight: .semibold, design: AgentPalette.interfaceFontDesign))\n                    .foregroundStyle(AgentPalette.tertiaryText)\n                    .lineLimit(3)\n                    .fixedSize(horizontal: false, vertical: true)\n'''
if old_finished in ui:
    if ui.count(old_finished) != 1:
        raise SystemExit("benchmark UI finished marker not unique")
    ui = ui.replace(old_finished, new_finished, 1)
elif "decode tok/s" not in ui:
    raise SystemExit("benchmark UI finished marker drifted")

old_helper = '''    private func endToEndCharactersPerSecond(_ result: LocalModelBenchmarkResult) -> Double {\n        guard result.totalDuration > 0 else { return 0 }\n        return Double(result.generatedCharacters) / result.totalDuration\n    }\n\n'''
new_helper = '''    private func benchmarkDetail(_ result: LocalModelBenchmarkResult) -> String {\n        let tokenLabel = result.hasExactTokenTelemetry\n            ? "\\(result.displayedTokenCount) exact tokens"\n            : "≈\\(result.displayedTokenCount) tokens from \\(result.generatedCharacters) characters"\n        let decodeLabel = result.decodeDuration.map { String(format: "decode %.2fs", $0) }\n        let profile = result.runtimeProfile?.trimmingCharacters(in: .whitespacesAndNewlines)\n        return [\n            result.modelName,\n            tokenLabel,\n            decodeLabel,\n            profile,\n            "session diagnostic · not qualification evidence",\n        ]\n        .compactMap { $0 }\n        .filter { !$0.isEmpty }\n        .joined(separator: " · ")\n    }\n\n'''
if old_helper in ui:
    if ui.count(old_helper) != 1:
        raise SystemExit("benchmark UI helper marker not unique")
    ui = ui.replace(old_helper, new_helper, 1)
elif "private func benchmarkDetail(" not in ui:
    raise SystemExit("benchmark UI helper marker drifted")

for needle, text in [
    ("struct LocalModelPerformanceSnapshot: Equatable, Sendable", runtime),
    ("func performanceSnapshot(modelID: String)", runtime),
    ("let exact = await localModelClient.performanceSnapshot(modelID: variant.id)", agent),
    ('unit: result.hasExactTokenTelemetry ? "decode tok/s" : "estimated tok/s"', ui),
    ("private func benchmarkDetail(_ result: LocalModelBenchmarkResult)", ui),
]:
    if text.count(needle) != 1:
        raise SystemExit(f"post-transform validation failed: {needle!r} count={text.count(needle)}")

RUNTIME.write_text(runtime, encoding="utf-8")
AGENT.write_text(agent, encoding="utf-8")
UI.write_text(ui, encoding="utf-8")
print("wired exact local benchmark telemetry")
