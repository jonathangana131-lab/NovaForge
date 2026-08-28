//
//  ModelManagerPanels.swift
//  NovaForge
//
//  Model manager 2.0 surfaces: on-device storage ledger for every catalog
//  variant, and a one-tap throughput benchmark for the selected model.
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Companion privacy

enum CompanionPrivacyCategory: String, CaseIterable, Identifiable {
    case prompt = "Prompt text"
    case attachments = "Attachments"
    case toolContext = "Approved tool context"
    case workspace = "Approved workspace content"
    case secrets = "Explicitly approved secrets"

    var id: String { rawValue }
}

/// Compact badge reused by Forge and Control. It intentionally states both
/// location and consent, instead of implying that a configured endpoint is
/// authorized to receive content.
struct CompanionExecutionBadge: View {
    let settings: AgentSettings
    var localModels: LocalModelManager?
    @AppStorage(CompanionPrivacyStore.consentFingerprintKey) private var consentFingerprint = ""

    private var isCompanion: Bool {
        settings.provider == .local &&
            LocalModelCatalog.variant(for: settings.modelID)?.executionLocation == .lan
    }

    private var consented: Bool {
        let _ = consentFingerprint
        return isCompanion && CompanionPrivacyStore.isConsented()
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: isCompanion ? "network.badge.shield.half.filled" : "iphone")
                .font(.system(size: 10, weight: .black))
            Text(isCompanion ? (consented ? "LAN · consented" : "LAN · consent required") : "On device")
                .font(.system(size: 9, weight: .black, design: AgentPalette.interfaceFontDesign))
                .lineLimit(1)
        }
        .foregroundStyle(isCompanion ? (consented ? AgentPalette.green : AgentPalette.warning) : AgentPalette.green)
        .padding(.horizontal, 8)
        .frame(minHeight: 24)
        .agentControlSurface(
            radius: 12,
            tint: (isCompanion ? (consented ? AgentPalette.green : AgentPalette.warning) : AgentPalette.green).opacity(0.10),
            selected: consented
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isCompanion ? (consented ? "LAN execution, consented" : "LAN execution, consent required") : "On-device execution")
        .accessibilityIdentifier("companionExecutionBadge")
    }
}

/// Per-request disclosure. Callers should render this immediately before a
/// companion send and pass only categories authorized for that request.
struct CompanionRequestDisclosure: View {
    let categories: Set<CompanionPrivacyCategory>
    let consented: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: consented ? "arrow.up.right.shield.fill" : "lock.shield.fill")
                .foregroundStyle(consented ? AgentPalette.lilac : AgentPalette.warning)
                .font(.system(size: 12, weight: .black))
            VStack(alignment: .leading, spacing: 2) {
                Text(consented ? "Leaving this iPhone: \(categoryText)" : "Companion consent required before sending")
                    .font(.caption2.weight(.black))
                    .foregroundStyle(AgentPalette.ink)
                Text(consented ? "Only the categories listed above are included in this request." : "Review and explicitly authorize the private-LAN destination in Control.")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(9)
        .agentSurface(radius: 12, tint: (consented ? AgentPalette.lilac : AgentPalette.warning).opacity(0.08))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("companionRequestDisclosure")
    }

    private var categoryText: String {
        let names = CompanionPrivacyCategory.allCases.filter { categories.contains($0) }.map(\.rawValue)
        return names.isEmpty ? "No content" : names.joined(separator: ", ")
    }
}

struct CompanionConfigurationPanel: View {
    @Bindable var manager: LocalModelManager

    @State private var endpointText = ""
    @State private var consentIntent = false
    @State private var notice: String?
    @AppStorage(CompanionPrivacyStore.consentFingerprintKey) private var consentFingerprint = ""

    private var configuration: CompanionModelConfiguration? {
        CompanionModelConfigurationStore.snapshot()
    }

    private var consented: Bool {
        let _ = consentFingerprint
        return CompanionPrivacyStore.isConsented(configuration)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "network.badge.shield.half.filled")
                    .foregroundStyle(AgentPalette.lilac)
                Text("Power Companion")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(AgentPalette.ink)
                Spacer()
                Text(manager.isCompanionConfirmed ? (consented ? "LAN · ON" : "LAN · CONSENT") : "OFF")
                    .font(.caption2.weight(.black))
                    .foregroundStyle(companionStatusColor)
                    .accessibilityIdentifier("companionConnectionStatus")
            }

            Text("Power has two explicit routes. On-device streamed is an experimental 6.19 GB IQ1_S staged-weight path awaiting its first A14 speed, memory, and thermal receipt. Companion is a separate fast private-LAN option and sends only disclosed content after you authorize it.")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AgentPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            TextField("http://192.168.1.20:8080", text: $endpointText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .font(.caption.monospaced())
                .padding(.horizontal, 11)
                .frame(height: 40)
                .agentControlSurface(radius: 11, tint: AgentPalette.lilac.opacity(0.08), selected: false)
                .accessibilityIdentifier("companionEndpointField")

            Toggle(isOn: $consentIntent) {
                Text("I authorize NovaForge to send only the categories disclosed for each request to this private-LAN endpoint.")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AgentPalette.ink)
            }
            .tint(AgentPalette.green)
            .accessibilityIdentifier("companionPrivacyConsent")

            HStack(spacing: 9) {
                SettingsActionButton(
                    title: manager.isCompanionConfirmed ? "Update & authorize" : "Confirm LAN",
                    symbol: "checkmark.shield.fill",
                    tint: AgentPalette.green,
                    prominent: true
                ) {
                    save()
                }
                .disabled(!consentIntent || endpointText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("companionConfirmButton")

                if manager.isCompanionConfirmed {
                    SettingsActionButton(title: "Disconnect", symbol: "xmark.circle", tint: AgentPalette.rose, prominent: false) {
                        manager.revokeCompanion()
                        CompanionPrivacyStore.revoke()
                        consentIntent = false
                        notice = "LAN companion access revoked."
                    }
                    .accessibilityIdentifier("companionDisconnectButton")
                }
            }

            if let notice {
                Text(notice)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(notice.hasPrefix("Saved") ? AgentPalette.green : AgentPalette.rose)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("companionConfigurationNotice")
            }
        }
        .padding(12)
        .agentSurface(radius: 16, tint: AgentPalette.lilac.opacity(0.06))
        .task {
            endpointText = manager.companionEndpointText
            consentIntent = consented
        }
        .onChange(of: endpointText) {
            let normalized = CompanionEndpointPolicy.normalizedBaseURL(from: endpointText)?.absoluteString
            if normalized != configuration?.endpoint.absoluteString {
                consentIntent = false
            }
        }
        .onChange(of: consentIntent) { _, isAuthorized in
            guard !isAuthorized, consented else { return }
            CompanionPrivacyStore.revoke()
            manager.refreshStatus()
            notice = "LAN companion remains configured, but content sharing is no longer authorized."
        }
        .accessibilityIdentifier("companionConfigurationPanel")
    }

    private var companionStatusColor: Color {
        guard manager.isCompanionConfirmed else {
            return AgentPalette.secondaryText
        }
        return consented ? AgentPalette.green : AgentPalette.warning
    }

    private func save() {
        do {
            try manager.confirmCompanion(endpointText: endpointText)
            endpointText = manager.companionEndpointText
            CompanionPrivacyStore.grant()
            manager.refreshStatus()
            notice = "Saved. NovaForge will attest the pinned model and revision before sending a prompt."
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            notice = error.localizedDescription
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
}

// MARK: - Power streamed research lane

struct PowerOutOfCorePanel: View {
    private enum Phase: Equatable {
        case idle
        case running(String)
        case finished(String)
        case failed(String)
    }

    @State private var importingExternalModel = false
    @State private var phase: Phase = .idle
    @State private var latest: OutOfCoreStorageBenchmarkReceipt?
    @State private var candidateID = LocalModelCatalog.powerOnDeviceExperimentID

    private var candidates: [LocalModelVariant] {
        LocalModelCatalog.presentationOrder.filter {
            LocalModelCatalog.powerOnDeviceExperimentIDs.contains($0.id)
        }
    }

    private var variant: LocalModelVariant? {
        LocalModelCatalog.variant(for: candidateID)
    }

    private var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "internaldrive.fill")
                    .foregroundStyle(AgentPalette.cyan)
                Text("Power · on-device streamed")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(AgentPalette.ink)
                Spacer()
                Text("EXPERIMENTAL")
                    .font(.caption2.weight(.black))
                    .foregroundStyle(AgentPalette.warning)
            }

            Text("Pinned text-only candidates: UD-IQ1_S 6.19 GB, UD-IQ2_XXS 9.01 GB, and Q3_K_M 13.82 GB · 1.5 GB stage-window budget. This route never falls back to LAN. Each quant needs its own measured storage, TTFT, 128 useful tokens, peak footprint, thermal/battery, and lifecycle receipt.")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AgentPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Candidate quant", selection: $candidateID) {
                ForEach(candidates) { candidate in
                    Text("\(candidate.quantization) · \(candidate.expectedSizeLabel)")
                        .tag(candidate.id)
                }
            }
            .pickerStyle(.menu)
            .tint(AgentPalette.cyan)
            .accessibilityIdentifier("powerOutOfCoreCandidatePicker")

            if let latest {
                Text(
                    "\(latest.storageLocation) · uncached \(latest.uncachedSequentialMBps, format: .number.precision(.fractionLength(1))) MB/s · random \(latest.randomMBps, format: .number.precision(.fractionLength(1))) MB/s · thermal \(latest.thermalBefore)→\(latest.thermalAfter)"
                )
                .font(.caption2.monospaced().weight(.semibold))
                .foregroundStyle(AgentPalette.ink)
                .fixedSize(horizontal: false, vertical: true)
            }

            switch phase {
            case .idle:
                Text("No storage benchmark is an inference-speed claim.")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AgentPalette.tertiaryText)
            case .running(let label):
                Label("Measuring \(label)…", systemImage: "gauge.with.dots.needle.67percent")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AgentPalette.cyan)
            case .finished(let message):
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AgentPalette.green)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AgentPalette.rose)
            }

            HStack(spacing: 8) {
                SettingsActionButton(
                    title: "Internal storage",
                    symbol: "iphone",
                    tint: AgentPalette.cyan,
                    prominent: false
                ) {
                    benchmarkInternal()
                }
                .disabled(isRunning)
                SettingsActionButton(
                    title: "Connected SSD…",
                    symbol: "externaldrive.fill",
                    tint: AgentPalette.lilac,
                    prominent: false
                ) {
                    importingExternalModel = true
                }
                .disabled(isRunning)
            }
        }
        .padding(12)
        .agentSurface(radius: 16, tint: AgentPalette.cyan.opacity(0.05))
        .accessibilityIdentifier("powerOutOfCorePanel")
        .task { latest = try? OutOfCoreStorageBenchmark.latest() }
        .fileImporter(
            isPresented: $importingExternalModel,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                benchmark(url: url, location: "external-security-scoped")
            case .failure(let error):
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func benchmarkInternal() {
        guard let variant,
              let url = try? LocalModelCatalog.fileURL(for: variant),
              FileManager.default.fileExists(atPath: url.path) else {
            phase = .failed("Download the selected pinned streamed Power artifact first.")
            return
        }
        benchmark(url: url, location: "internal-app-container")
    }

    private func benchmark(url: URL, location: String) {
        guard let variant else { return }
        phase = .running(location)
        let securityScoped = location == "external-security-scoped"
        let didAccess = securityScoped
            ? url.startAccessingSecurityScopedResource()
            : false
        Task {
            defer {
                if didAccess { url.stopAccessingSecurityScopedResource() }
            }
            do {
                try await Task.detached(priority: .userInitiated) {
                    let attributes = try FileManager.default
                        .attributesOfItem(atPath: url.path)
                    let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
                    guard size == variant.expectedBytes else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    try LocalModelDownloader.validateSHA256(
                        variant: variant,
                        fileURL: url
                    )
                }.value
                let receipt = try await Task.detached(priority: .userInitiated) {
                    try OutOfCoreStorageBenchmark.run(
                        modelID: variant.id,
                        url: url,
                        storageLocation: location
                    )
                }.value
                latest = receipt
                phase = .finished("Storage receipt saved; inference admission is still pending.")
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }
}

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
        for variant in LocalModelCatalog.all where variant.isDownloadable {
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
    @State private var latestReceipt: LocalBenchmarkReceipt?

    private var canRun: Bool {
        settings.provider == .local && runtime.localModels.isDownloaded && phase != .running && !runtime.isWorking
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(AgentPalette.cyan)
                Text("\(selectedLocation) Benchmark")
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
                Text("\(result.modelName) · \(result.generatedCharacters) characters · estimated tokens · receipt \(result.receiptID.uuidString.prefix(8))")
                    .font(.system(size: 9, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.tertiaryText)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10.5, weight: .bold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.rose)
                    .lineLimit(2)
            }

            if let receipt = latestReceipt,
               receipt.modelID == settings.modelID {
                Text(receiptEvidence(receipt))
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(AgentPalette.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .agentSurface(radius: 16, tint: AgentPalette.cyan.opacity(0.06))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("modelBenchmarkPanel")
        .task { await loadLatestReceipt() }
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

    private var selectedLocation: String {
        LocalModelCatalog.variant(for: settings.modelID)?.executionLocation.title ?? "Local"
    }

    private func receiptEvidence(_ receipt: LocalBenchmarkReceipt) -> String {
        let peak = receipt.peakPhysicalFootprintBytes.map {
            ByteCountFormatter.string(
                fromByteCount: Int64(clamping: $0),
                countStyle: .memory
            )
        } ?? "not sampled"
        return "Peak \(peak) · thermal \(receipt.thermalStateBefore)→\(receipt.thermalStateAfter) · \(receipt.isPhysicalDevice ? "physical" : "simulator")"
    }

    @MainActor
    private func loadLatestReceipt() async {
        latestReceipt = try? await LocalBenchmarkReceiptStore.shared.latest()
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
                await loadLatestReceipt()
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            case .failure(let error):
                phase = .failed(error.localizedDescription)
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }
}
