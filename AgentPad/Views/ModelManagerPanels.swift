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

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
            storageHeader

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

    private var storageHeader: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 5))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))

        return layout {
            HStack(spacing: 8) {
                Image(systemName: "internaldrive.fill")
                    .font(.system(.caption, weight: .bold))
                    .foregroundStyle(AgentPalette.storageAccent)
                    .accessibilityHidden(true)
                Text("On-Device Storage")
                    .font(.system(.caption, design: AgentPalette.interfaceFontDesign, weight: .bold))
                    .foregroundStyle(AgentPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("\(totalText) used · \(freeText) free")
                .font(.system(.caption2, design: AgentPalette.interfaceFontDesign, weight: .semibold))
                .foregroundStyle(AgentPalette.secondaryText)
                .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
                .fixedSize(horizontal: false, vertical: true)
                .frame(
                    maxWidth: .infinity,
                    alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing
                )
        }
        .accessibilityElement(children: .combine)
    }

    private func storageRow(_ entry: VariantStorage) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 7))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 9))

        return layout {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Circle()
                    .fill(entry.isDownloaded ? AgentPalette.green : (entry.isPartial ? AgentPalette.warning : AgentPalette.quaternaryText))
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(entry.name)
                            .font(.system(.subheadline, design: AgentPalette.interfaceFontDesign, weight: .bold))
                            .foregroundStyle(AgentPalette.ink)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                            .fixedSize(horizontal: false, vertical: dynamicTypeSize.isAccessibilitySize)

                        Text(entry.quantization)
                            .font(.system(.caption2, design: .monospaced, weight: .bold))
                            .foregroundStyle(AgentPalette.secondaryText)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .agentControlSurface(radius: 5, tint: AgentPalette.storageAccent.opacity(0.10), selected: false)
                            .fixedSize()
                            .accessibilityHidden(true)
                    }

                    Text(storageDetail(entry))
                        .font(.system(.caption, design: AgentPalette.interfaceFontDesign, weight: .semibold))
                        .foregroundStyle(AgentPalette.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(entry.name), \(entry.quantization), \(storageDetail(entry))\(entry.isSelected ? ", selected" : "")")

            if entry.isSelected {
                HStack(spacing: 8) {
                    Text("Selected")
                        .font(.system(.caption2, design: AgentPalette.interfaceFontDesign, weight: .bold))
                        .foregroundStyle(AgentPalette.cyan)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .agentControlSurface(radius: 7, tint: AgentPalette.cyan.opacity(0.12), selected: true)
                        .accessibilityHidden(true)

                    if entry.onDiskBytes > 0 {
                        Button {
                            confirmingDelete = true
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(.body, weight: .semibold))
                                .foregroundStyle(AgentPalette.rose)
                                .frame(
                                    minWidth: AgentDesign.minimumTouchTarget,
                                    minHeight: AgentDesign.minimumTouchTarget
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Delete downloaded model \(entry.name)")
                        .accessibilityHint("Removes the downloaded model file from this device")
                    }
                }
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .contain)
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

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var phase: Phase = .idle

    private var canRun: Bool {
        settings.provider == .local && runtime.localModels.isDownloaded && phase != .running && !runtime.isWorking
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            benchmarkHeader

            switch phase {
            case .idle:
                Text(runtime.localModels.isDownloaded
                     ? "Run a local timing sample on this device. Results are session diagnostics, not qualification evidence."
                     : "Download the local model to benchmark it.")
                    .font(.system(.caption, design: AgentPalette.interfaceFontDesign, weight: .semibold))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            case .running:
                Text("Generating a capped sample with \(LocalModelCatalog.variant(for: settings.modelID)?.shortName ?? "the local model")…")
                    .font(.system(.caption, design: AgentPalette.interfaceFontDesign, weight: .semibold))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            case .finished(let result):
                benchmarkMetrics(result)
                Text("\(result.modelName) · \(result.generatedCharacters) observed characters · not qualification evidence")
                    .font(.system(.caption2, design: AgentPalette.interfaceFontDesign, weight: .semibold))
                    .foregroundStyle(AgentPalette.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(.caption, design: AgentPalette.interfaceFontDesign, weight: .bold))
                    .foregroundStyle(AgentPalette.rose)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .agentSurface(radius: 16, tint: AgentPalette.cyan.opacity(0.06))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("modelBenchmarkPanel")
    }

    private var benchmarkHeader: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 8))

        return layout {
            HStack(spacing: 8) {
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .font(.system(.caption, weight: .bold))
                    .foregroundStyle(AgentPalette.cyan)
                    .accessibilityHidden(true)
                Text("On-Device Benchmark")
                    .font(.system(.caption, design: AgentPalette.interfaceFontDesign, weight: .bold))
                    .foregroundStyle(AgentPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                runBenchmark()
            } label: {
                HStack(spacing: 5) {
                    if phase == .running {
                        ProgressView()
                            .controlSize(.mini)
                            .accessibilityHidden(true)
                    } else {
                        Image(systemName: "bolt.fill")
                            .font(.system(.caption, weight: .bold))
                            .accessibilityHidden(true)
                    }
                    Text(phase == .running ? "Measuring…" : "Run")
                        .font(.system(.subheadline, design: AgentPalette.interfaceFontDesign, weight: .bold))
                }
                .foregroundStyle(canRun ? AgentPalette.ink : AgentPalette.tertiaryText)
                .padding(.horizontal, 12)
                .frame(
                    maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil,
                    minHeight: AgentDesign.minimumTouchTarget
                )
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .agentControlSurface(radius: 14, tint: AgentPalette.cyan.opacity(canRun ? 0.14 : 0.05), selected: canRun)
            .disabled(!canRun)
            .accessibilityLabel(phase == .running ? "Local benchmark running" : "Run local benchmark")
            .accessibilityHint(benchmarkAccessibilityHint)
            .accessibilityIdentifier("modelBenchmarkRunButton")
        }
    }

    private var benchmarkAccessibilityHint: String {
        if phase == .running {
            return "Measures the selected local model on this device"
        }
        if settings.provider != .local {
            return "Select the Local provider to benchmark an on-device model"
        }
        if !runtime.localModels.isDownloaded {
            return "Download the selected local model before benchmarking"
        }
        if runtime.isWorking {
            return "Wait for the current NovaForge run to finish"
        }
        return "Runs a capped timing sample; results are diagnostics, not qualification evidence"
    }

    private func benchmarkMetrics(_ result: LocalModelBenchmarkResult) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 8))

        return layout {
            benchmarkMetric(
                value: String(format: "%.0f", endToEndCharactersPerSecond(result)),
                unit: "e2e chars/s",
                accessibilityUnit: "end-to-end characters per second",
                tint: AgentPalette.green
            )
            benchmarkMetric(
                value: String(format: "%.2fs", result.timeToFirstToken),
                unit: "first output",
                accessibilityUnit: "time to first output",
                tint: AgentPalette.cyan
            )
            benchmarkMetric(
                value: String(format: "%.1fs", result.totalDuration),
                unit: "total",
                accessibilityUnit: "total duration",
                tint: AgentPalette.lilac
            )
        }
    }

    private func benchmarkMetric(
        value: String,
        unit: String,
        accessibilityUnit: String,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(.headline, design: .monospaced, weight: .bold))
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
            Text(unit)
                .font(.system(.caption2, design: AgentPalette.interfaceFontDesign, weight: .bold))
                .foregroundStyle(AgentPalette.tertiaryText)
                .textCase(.uppercase)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .agentControlSurface(radius: 11, tint: tint.opacity(0.08), selected: false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(accessibilityUnit), \(value)")
    }

    private func endToEndCharactersPerSecond(_ result: LocalModelBenchmarkResult) -> Double {
        guard result.totalDuration > 0 else { return 0 }
        return Double(result.generatedCharacters) / result.totalDuration
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
