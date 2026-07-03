//
//  ModelManagerPanels.swift
//  NovaForge
//
//  Model manager 2.0 surfaces: on-device storage ledger for every catalog
//  variant, and a one-tap throughput benchmark for the selected model.
//

import SwiftUI

// MARK: - Storage

struct ModelStoragePanel: View {
    let runtime: AgentRuntime
    @Bindable var settings: AgentSettings

    @State private var report: [VariantStorage] = []
    @State private var freeText = "—"
    @State private var totalText = "—"
    @State private var confirmingDelete = false

    struct VariantStorage: Identifiable, Equatable {
        let id: String
        let name: String
        let quantization: String
        let onDiskBytes: Int64
        let expectedBytes: Int64
        let isSelected: Bool

        var isDownloaded: Bool { onDiskBytes >= Int64(Double(expectedBytes) * 0.98) }
        var isPartial: Bool { onDiskBytes > 0 && !isDownloaded }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "internaldrive.fill")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(AgentPalette.storageAccent)
                Text("On-Device Storage")
                    .font(.system(size: 12, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                Spacer(minLength: 0)
                Text("\(totalText) used · \(freeText) free")
                    .font(.system(size: 10, weight: .bold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
            }

            ForEach(report) { entry in
                storageRow(entry)
            }
        }
        .padding(12)
        .agentSurface(radius: 16, tint: AgentPalette.storageAccent.opacity(0.06))
        .task { refresh() }
        .onChange(of: runtime.localModels.status) { refresh() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("modelStoragePanel")
        .confirmationDialog(
            "Delete the downloaded model file?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Model", role: .destructive) {
                runtime.localModels.deleteSelectedModel()
                refresh()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The model can be downloaded again at any time.")
        }
    }

    private func storageRow(_ entry: VariantStorage) -> some View {
        HStack(spacing: 9) {
            Circle()
                .fill(entry.isDownloaded ? AgentPalette.green : (entry.isPartial ? AgentPalette.warning : AgentPalette.quaternaryText))
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(entry.name)
                        .font(.system(size: 11.5, weight: .bold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.ink)
                        .lineLimit(1)
                    Text(entry.quantization)
                        .font(.system(size: 8.5, weight: .black, design: .monospaced))
                        .foregroundStyle(AgentPalette.secondaryText)
                        .padding(.horizontal, 5)
                        .frame(height: 15)
                        .agentControlSurface(radius: 5, tint: AgentPalette.storageAccent.opacity(0.10), selected: false)
                }
                Text(storageDetail(entry))
                    .font(.system(size: 9.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.tertiaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if entry.isSelected {
                Text("SELECTED")
                    .font(.system(size: 8, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.cyan)
                    .padding(.horizontal, 6)
                    .frame(height: 16)
                    .agentControlSurface(radius: 6, tint: AgentPalette.cyan.opacity(0.12), selected: true)
            }

            if entry.isSelected, entry.onDiskBytes > 0 {
                Button {
                    confirmingDelete = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(AgentPalette.rose)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete downloaded model \(entry.name)")
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.name), \(storageDetail(entry))\(entry.isSelected ? ", selected" : "")")
    }

    private func storageDetail(_ entry: VariantStorage) -> String {
        let expected = Self.gigabytes(entry.expectedBytes)
        if entry.isDownloaded { return "Downloaded · \(Self.gigabytes(entry.onDiskBytes))" }
        if entry.isPartial { return "Partial · \(Self.gigabytes(entry.onDiskBytes)) of \(expected)" }
        return "Not downloaded · \(expected) when installed"
    }

    private func refresh() {
        var entries: [VariantStorage] = []
        var total: Int64 = 0
        for variant in LocalModelCatalog.all {
            let url = try? LocalModelCatalog.fileURL(for: variant)
            let size = url.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int64 } ?? 0
            total += size
            entries.append(VariantStorage(
                id: variant.id,
                name: variant.shortName,
                quantization: variant.quantization,
                onDiskBytes: size,
                expectedBytes: variant.expectedBytes,
                isSelected: settings.modelID == variant.id
            ))
        }
        report = entries
        totalText = Self.gigabytes(total)
        if let free = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage {
            freeText = Self.gigabytes(free)
        }
    }

    private static func gigabytes(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 MB" }
        let mb = Double(bytes) / 1_048_576
        if mb < 1_000 { return String(format: "%.0f MB", mb) }
        return String(format: "%.2f GB", mb / 1_024)
    }
}

// MARK: - Benchmark

struct ModelBenchmarkPanel: View {
    let runtime: AgentRuntime
    @Bindable var settings: AgentSettings

    enum Phase: Equatable {
        case idle
        case running
        case finished(LocalModelBenchmarkResult)
        case failed(String)
    }

    @State private var phase: Phase = .idle

    private var canRun: Bool {
        settings.provider == .local && runtime.localModels.isDownloaded && phase != .running && !runtime.isWorking
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(AgentPalette.cyan)
                Text("On-Device Benchmark")
                    .font(.system(size: 12, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                Spacer(minLength: 0)

                Button {
                    runBenchmark()
                } label: {
                    HStack(spacing: 5) {
                        if phase == .running {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 10, weight: .black))
                        }
                        Text(phase == .running ? "Measuring…" : "Run")
                            .font(.system(size: 11, weight: .black, design: AgentPalette.interfaceFontDesign))
                    }
                    .foregroundStyle(canRun ? AgentPalette.ink : AgentPalette.tertiaryText)
                    .padding(.horizontal, 11)
                    .frame(height: 30)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .agentControlSurface(radius: 11, tint: AgentPalette.cyan.opacity(canRun ? 0.14 : 0.05), selected: canRun)
                .disabled(!canRun)
                .accessibilityIdentifier("modelBenchmarkRunButton")
            }

            switch phase {
            case .idle:
                Text(runtime.localModels.isDownloaded
                     ? "Measure real generation speed on this device. Takes a few seconds."
                     : "Download the local model to benchmark it.")
                    .font(.system(size: 10.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
            case .running:
                Text("Generating a capped sample with \(LocalModelCatalog.variant(for: settings.modelID)?.shortName ?? "the local model")…")
                    .font(.system(size: 10.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
            case .finished(let result):
                HStack(spacing: 8) {
                    benchmarkMetric(value: String(format: "≈%.1f", result.tokensPerSecond), unit: "tok/s", tint: AgentPalette.green)
                    benchmarkMetric(value: String(format: "%.2fs", result.timeToFirstToken), unit: "first token", tint: AgentPalette.cyan)
                    benchmarkMetric(value: String(format: "%.1fs", result.totalDuration), unit: "total", tint: AgentPalette.lilac)
                }
                Text("\(result.modelName) · \(result.generatedCharacters) characters · token count estimated")
                    .font(.system(size: 9, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.tertiaryText)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10.5, weight: .bold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.rose)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .agentSurface(radius: 16, tint: AgentPalette.cyan.opacity(0.06))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("modelBenchmarkPanel")
    }

    private func benchmarkMetric(value: String, unit: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 15, weight: .black, design: .monospaced))
                .foregroundStyle(tint)
            Text(unit)
                .font(.system(size: 8.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(AgentPalette.tertiaryText)
                .textCase(.uppercase)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .agentControlSurface(radius: 11, tint: tint.opacity(0.08), selected: false)
    }

    private func runBenchmark() {
        guard canRun else { return }
        phase = .running
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        Task { @MainActor in
            let outcome = await runtime.runLocalModelBenchmark(settings: settings)
            switch outcome {
            case .success(let result):
                phase = .finished(result)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            case .failure(let error):
                phase = .failed(error.localizedDescription)
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }
}
