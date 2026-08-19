#!/usr/bin/env python3
from pathlib import Path
import re

runtime = Path('AgentPad/Services/LocalModelRuntime.swift')
settings = Path('AgentPad/Views/SettingsView.swift')
provider = Path('AgentPad/Services/AIProvider.swift')

rt = runtime.read_text()
sv = settings.read_text()
pv = provider.read_text()

# 1) Remove the former 3.6 user target completely. It remains available only in
# git history; this branch must never relabel/substitute it for 3.8.
pattern = re.compile(r'''\n        \.init\(\n            id: "unsloth/Qwen3\.6-27B-UD-IQ2_XXS",.*?\n        \)\n    \]''', re.S)
match = pattern.search(rt)
if not match:
    raise SystemExit('Qwen3.6 catalog block not found exactly once')
rt = rt[:match.start()] + '\n    ]' + rt[match.end():]

# 2) Add exact-release discovery. Discovery is deliberately fail-closed: exact
# 3.8 + 27B naming, single GGUF, immutable revision, byte size, and 64-char LFS
# SHA256 are all required before the existing downloader can see a variant.
marker = 'enum LocalModelCatalog {\n'
if rt.count(marker) != 1:
    raise SystemExit('LocalModelCatalog marker mismatch')
discovery = r'''struct Qwen38ReleaseManifest: Codable, Equatable, Sendable {
    let repositoryID: String
    let revision: String
    let filename: String
    let expectedBytes: Int64
    let sha256: String
    let quantization: String
    let lastModified: String
}

enum Qwen38ReleaseDiscoveryError: LocalizedError {
    case invalidResponse
    case invalidManifest

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Hugging Face did not return a valid Qwen 3.8 27B catalog response."
        case .invalidManifest:
            "A candidate was found, but NovaForge could not prove its revision, size, and SHA-256."
        }
    }
}

enum Qwen38ReleaseDiscovery {
    static let unavailableModelID = "qwen3.8-27b-awaiting-verified-open-weights"

    private struct HubModel: Decodable {
        let id: String
        let sha: String?
        let lastModified: String?
        let siblings: [HubSibling]?
    }

    private struct HubSibling: Decodable {
        let rfilename: String
        let size: Int64?
        let lfs: HubLFS?
    }

    private struct HubLFS: Decodable {
        let sha256: String?
        let oid: String?
        let size: Int64?
    }

    private struct Candidate {
        let manifest: Qwen38ReleaseManifest
        let publisherRank: Int
        let quantRank: Int
    }

    static func cachedManifest() -> Qwen38ReleaseManifest? {
        guard let url = try? manifestURL(),
              let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(Qwen38ReleaseManifest.self, from: data),
              validate(manifest)
        else { return nil }
        return manifest
    }

    static func cachedVariant() -> LocalModelVariant? {
        cachedManifest().flatMap(makeVariant)
    }

    static func refresh() async throws -> LocalModelVariant? {
        var components = URLComponents(string: "https://huggingface.co/api/models")!
        components.queryItems = [
            URLQueryItem(name: "search", value: "Qwen3.8 27B GGUF"),
            URLQueryItem(name: "limit", value: "50"),
            URLQueryItem(name: "full", value: "true"),
        ]
        guard let url = components.url else { throw Qwen38ReleaseDiscoveryError.invalidResponse }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw Qwen38ReleaseDiscoveryError.invalidResponse
        }
        let models = try JSONDecoder().decode([HubModel].self, from: data)
        var candidates: [Candidate] = []
        for model in models where exactTargetText(model.id) {
            if let candidate = try await resolveCandidate(modelID: model.id) {
                candidates.append(candidate)
            }
        }
        guard let winner = candidates.sorted(by: candidateSort).first else {
            return nil
        }
        try persist(winner.manifest)
        return makeVariant(winner.manifest)
    }

    private static func resolveCandidate(modelID: String) async throws -> Candidate? {
        guard exactTargetText(modelID) else { return nil }
        var components = URLComponents(string: "https://huggingface.co/api/models/\(modelID)")!
        components.queryItems = [URLQueryItem(name: "blobs", value: "true")]
        guard let url = components.url else { return nil }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        let detail = try JSONDecoder().decode(HubModel.self, from: data)
        guard let revision = detail.sha, revision.count >= 7 else { return nil }

        let files = (detail.siblings ?? []).filter { sibling in
            let lower = sibling.rfilename.lowercased()
            return lower.hasSuffix(".gguf") &&
                !lower.contains("-00001-of-") &&
                !lower.contains("-00002-of-") &&
                exactTargetText("\(modelID)/\(sibling.rfilename)")
        }
        let manifests = files.compactMap { sibling -> Qwen38ReleaseManifest? in
            let bytes = sibling.lfs?.size ?? sibling.size ?? 0
            var digest = sibling.lfs?.sha256 ?? sibling.lfs?.oid ?? ""
            digest = digest.replacingOccurrences(of: "sha256:", with: "")
            guard bytes > 1_000_000_000,
                  digest.count == 64,
                  digest.allSatisfy({ $0.isHexDigit })
            else { return nil }
            let quant = quantization(from: sibling.rfilename)
            let manifest = Qwen38ReleaseManifest(
                repositoryID: modelID,
                revision: revision,
                filename: sibling.rfilename,
                expectedBytes: bytes,
                sha256: digest.lowercased(),
                quantization: quant,
                lastModified: detail.lastModified ?? ""
            )
            return validate(manifest) ? manifest : nil
        }
        guard let best = manifests.sorted(by: manifestSort).first else { return nil }
        return Candidate(
            manifest: best,
            publisherRank: publisherRank(modelID),
            quantRank: quantRank(best.quantization)
        )
    }

    private static func exactTargetText(_ value: String) -> Bool {
        let lower = value.lowercased()
        let hasVersion = lower.contains("qwen3.8") || lower.contains("qwen-3.8") || lower.contains("qwen_3.8") || lower.contains("qwen3_8")
        return hasVersion && lower.contains("27b") &&
            !lower.contains("qwen3.6") && !lower.contains("qwen3.5")
    }

    private static func validate(_ manifest: Qwen38ReleaseManifest) -> Bool {
        exactTargetText("\(manifest.repositoryID)/\(manifest.filename)") &&
            manifest.filename.lowercased().hasSuffix(".gguf") &&
            !manifest.filename.lowercased().contains("-00001-of-") &&
            manifest.expectedBytes > 1_000_000_000 &&
            manifest.sha256.count == 64 &&
            manifest.sha256.allSatisfy { $0.isHexDigit } &&
            manifest.revision.count >= 7
    }

    private static func publisherRank(_ id: String) -> Int {
        let lower = id.lowercased()
        if lower.hasPrefix("qwen/") { return 0 }
        if lower.hasPrefix("unsloth/") { return 1 }
        if lower.hasPrefix("bartowski/") { return 2 }
        return 3
    }

    private static func quantization(from filename: String) -> String {
        let upper = filename.uppercased()
        for marker in ["UD-IQ2_XXS", "IQ2_XXS", "IQ2_XS", "Q2_K_XS", "Q2_K", "Q3_K_XS", "Q3_K_S", "Q3_K_M", "Q4_K_M"] where upper.contains(marker) {
            return marker
        }
        return "GGUF"
    }

    private static func quantRank(_ value: String) -> Int {
        switch value.uppercased() {
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
    }

    private static func manifestSort(_ lhs: Qwen38ReleaseManifest, _ rhs: Qwen38ReleaseManifest) -> Bool {
        let lq = quantRank(lhs.quantization)
        let rq = quantRank(rhs.quantization)
        if lq != rq { return lq < rq }
        return lhs.expectedBytes < rhs.expectedBytes
    }

    private static func candidateSort(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        if lhs.quantRank != rhs.quantRank { return lhs.quantRank < rhs.quantRank }
        if lhs.publisherRank != rhs.publisherRank { return lhs.publisherRank < rhs.publisherRank }
        return lhs.manifest.expectedBytes < rhs.manifest.expectedBytes
    }

    private static func persist(_ manifest: Qwen38ReleaseManifest) throws {
        guard validate(manifest) else { throw Qwen38ReleaseDiscoveryError.invalidManifest }
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: try manifestURL(), options: [.atomic])
    }

    private static func manifestURL() throws -> URL {
        try LocalModelCatalog.modelDirectory().appendingPathComponent("qwen3.8-27b-release.json")
    }

    private static func makeVariant(_ manifest: Qwen38ReleaseManifest) -> LocalModelVariant? {
        guard validate(manifest),
              let downloadURL = URL(string: "https://huggingface.co/\(manifest.repositoryID)/resolve/\(manifest.revision)/\(manifest.filename)?download=true"),
              let sourceURL = URL(string: "https://huggingface.co/\(manifest.repositoryID)/blob/\(manifest.revision)/\(manifest.filename)")
        else { return nil }
        let disk = max(Int64(12_500_000_000), manifest.expectedBytes + manifest.expectedBytes / 3)
        let dateLabel = manifest.lastModified.isEmpty ? "Verified release" : String(manifest.lastModified.prefix(10))
        return LocalModelVariant(
            id: "qwen38:\(manifest.repositoryID)@\(manifest.revision):\(manifest.filename)",
            displayName: "Qwen 3.8 27B — Extreme",
            shortName: "Qwen 3.8 27B",
            quantization: manifest.quantization,
            filename: manifest.filename,
            downloadURL: downloadURL,
            expectedBytes: manifest.expectedBytes,
            expectedSHA256: manifest.sha256,
            minimumPhysicalMemoryBytes: 3_800_000_000,
            recommendedFreeDiskBytes: disk,
            contextTokens: 4_096,
            batchTokens: 24,
            maxNewTokens: 512,
            maxGenerationSeconds: 300,
            useGPU: true,
            gpuLayerCount: 1,
            generationThreadCount: 2,
            batchThreadCount: 4,
            isIPhone12SafeDefault: false,
            releaseDateISO8601: String(manifest.lastModified.prefix(10)),
            releaseDateLabel: dateLabel,
            parameterLabel: "27B",
            licenseLabel: "See pinned model card",
            benchmarkSummary: "Exact Qwen 3.8 27B · device benchmark required after install",
            capabilitySummary: "Long-running coding agent · repository reasoning · project execution",
            deviceFit: .extreme,
            estimatedPeakMemoryBytes: 2_050_000_000,
            minimumAvailableMemoryBeforeLoadBytes: 1_200_000_000,
            sourceURL: sourceURL,
            details: "Exact Qwen 3.8 27B only. NovaForge pinned this GGUF to an immutable Hugging Face revision and LFS SHA-256. Oversized weights stay storage-backed with mmap, tiny hot Metal residency, Q8 KV, cache-stable context projection, and adaptive throughput policy."
        )
    }
}

'''
rt = rt.replace(marker, discovery + marker)

old_catalog = '''    static var presentationOrder: [LocalModelVariant] {
        all.sorted {
            if $0.releaseDateISO8601 == $1.releaseDateISO8601 {
                return $0.expectedBytes > $1.expectedBytes
            }
            return $0.releaseDateISO8601 > $1.releaseDateISO8601
        }
    }

    static var defaultVariant: LocalModelVariant {
        safestVariant()
    }

    static func variant(for id: String) -> LocalModelVariant? {
        all.first { $0.id == id }
    }
'''
new_catalog = '''    static var exactQwen38Variant: LocalModelVariant? {
        Qwen38ReleaseDiscovery.cachedVariant()
    }

    /// This dedicated branch exposes exactly one user-facing local target. The
    /// older small catalog remains compiled only as an internal recovery/test
    /// resource and is never offered as a substitute for Qwen 3.8 27B.
    static var presentationOrder: [LocalModelVariant] {
        exactQwen38Variant.map { [$0] } ?? []
    }

    static var defaultVariant: LocalModelVariant {
        exactQwen38Variant ?? safestVariant()
    }

    static func variant(for id: String) -> LocalModelVariant? {
        if let target = exactQwen38Variant, target.id == id { return target }
        return all.first { $0.id == id }
    }

    static func isExactQwen38Target(_ variant: LocalModelVariant) -> Bool {
        guard let target = exactQwen38Variant else { return false }
        return target.id == variant.id && target.expectedSHA256 == variant.expectedSHA256
    }
'''
if rt.count(old_catalog) != 1:
    raise SystemExit('catalog presentation marker mismatch')
rt = rt.replace(old_catalog, new_catalog)

# Remove copy that tells giant-model users to choose Atlas, because this branch
# intentionally has no user-facing fallback model.
rt = rt.replace('use Atlas 2 or let the phone cool first.', 'let the phone cool, then retry Qwen 3.8 27B.')
rt = rt.replace('Close memory-heavy apps or choose Atlas 2.', 'Close memory-heavy apps, then retry Qwen 3.8 27B.')
rt = rt.replace('Choose an Ultra light or Memory saver model.', 'This Qwen 3.8-only build cannot substitute a smaller model.')

# 3) The provider's default local identity must be the exact target (or an
# explicit unavailable sentinel), never the hidden internal catalog.
old_default = '''    var defaultModel: String {
        modelOptions.first ?? ""
    }
'''
new_default = '''    var defaultModel: String {
        if self == .local {
            return LocalModelCatalog.exactQwen38Variant?.id
                ?? Qwen38ReleaseDiscovery.unavailableModelID
        }
        return modelOptions.first ?? ""
    }
'''
if pv.count(old_default) != 1:
    raise SystemExit('provider defaultModel marker mismatch')
pv = pv.replace(old_default, new_default)
pv = pv.replace('''        case .local:
            LocalModelCatalog.all.map(\\.id)
''', '''        case .local:
            LocalModelCatalog.presentationOrder.map(\\.id)
''')
pv = pv.replace('''        case .local:
            "On-device Qwen Coder agent"
''', '''        case .local:
            "Qwen 3.8 27B · on-device only"
''')

# 4) Make Settings a single-target release/download surface.
state_marker = '    @State private var providerModelError: String? = nil\n'
if sv.count(state_marker) != 1:
    raise SystemExit('settings state marker mismatch')
sv = sv.replace(state_marker, state_marker + '''    @State private var qwen38DiscoveryTask: Task<Void, Never>?\n    @State private var checkingQwen38Release = false\n    @State private var qwen38DiscoveryMessage: String?\n''')
sv = sv.replace('''            connectionTestTask?.cancel()
            workspaceResetTask?.cancel()
''', '''            connectionTestTask?.cancel()
            qwen38DiscoveryTask?.cancel()
            workspaceResetTask?.cancel()
''')

old_title = '''        if settings.provider == .local {
            switch runtime.localModels.status {
'''
new_title = '''        if settings.provider == .local {
            guard LocalModelCatalog.exactQwen38Variant != nil else {
                return "Qwen 3.8 27B unavailable"
            }
            switch runtime.localModels.status {
'''
# Only first occurrence is settingsReadinessTitle; later symbol/tint are patched separately.
idx = sv.find(old_title)
if idx < 0: raise SystemExit('readiness title marker missing')
sv = sv[:idx] + sv[idx:].replace(old_title, new_title, 1)

# Symbol and tint local switches occur later; prepend exact-target guard to each.
sv = sv.replace('''    private var settingsReadinessSymbol: String {
        if settings.provider == .local {
            switch runtime.localModels.status {
''', '''    private var settingsReadinessSymbol: String {
        if settings.provider == .local {
            guard LocalModelCatalog.exactQwen38Variant != nil else { return "externaldrive.badge.questionmark" }
            switch runtime.localModels.status {
''')
sv = sv.replace('''    private var settingsReadinessTint: Color {
        if settings.provider == .local {
            switch runtime.localModels.status {
''', '''    private var settingsReadinessTint: Color {
        if settings.provider == .local {
            guard LocalModelCatalog.exactQwen38Variant != nil else { return AgentPalette.warning }
            switch runtime.localModels.status {
''')

sv = sv.replace('''    private var modelReadinessDetail: String {
        if let variant = LocalModelCatalog.variant(for: settings.modelID) {
''', '''    private var modelReadinessDetail: String {
        if settings.provider == .local, LocalModelCatalog.exactQwen38Variant == nil {
            return "No verified open-weight Qwen 3.8 27B GGUF is published yet · NovaForge will not substitute 3.6"
        }
        if let variant = LocalModelCatalog.variant(for: settings.modelID) {
''')
sv = sv.replace('''    private var localModelStatusDetail: String {
        let variant = runtime.localModels.selectedVariant
''', '''    private var localModelStatusDetail: String {
        guard let target = LocalModelCatalog.exactQwen38Variant else {
            return qwen38DiscoveryMessage ?? "Check Hugging Face for an exact Qwen 3.8 27B GGUF. Download stays locked until revision, size, and SHA-256 are verified."
        }
        let variant = target
''')

# Local Model picker is meaningless for a single-target appliance.
old_picker = '''                SettingsModelPickerButton(
                    provider: settings.provider,
                    model: modelDisplayName(settings.modelID),
                    count: modelChoices.count,
                    isLoading: loadingProviderModels
                ) {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    showingModelPicker = true
                    if providerModels.isEmpty && !loadingProviderModels {
                        loadProviderModels()
                    }
                }
'''
new_picker = '''                if settings.provider != .local {
                    SettingsModelPickerButton(
                        provider: settings.provider,
                        model: modelDisplayName(settings.modelID),
                        count: modelChoices.count,
                        isLoading: loadingProviderModels
                    ) {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        showingModelPicker = true
                        if providerModels.isEmpty && !loadingProviderModels {
                            loadProviderModels()
                        }
                    }
                }
'''
if sv.count(old_picker) != 1: raise SystemExit('model picker marker mismatch')
sv = sv.replace(old_picker, new_picker)

old_local_section = '''    private var localModelSection: some View {
        SettingsSection(
            title: "On-Device Models",
            subtitle: "Fresh coding models, pinned provenance, and fail-closed iPhone memory gates"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 7) {
                    Label("Built for iPhone 12—not a desktop model list", systemImage: "iphone.gen3.radiowaves.left.and.right")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(AgentPalette.ink)

                    Text("NovaForge loads one model at a time, unloads it in the background or under memory pressure, and refuses first-prompt allocation when iOS headroom is unsafe.")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AgentPalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    Label("Release date, benchmark source, license, artifact size, context cap, and estimated peak are visible on every card.", systemImage: "checkmark.shield.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(AgentPalette.green)
                }
                .padding(12)
                .agentSurface(radius: 16, tint: AgentPalette.cyan.opacity(0.07))

                ForEach(LocalModelCatalog.presentationOrder) { variant in
                    LocalModelVariantRow(
                        variant: variant,
                        selected: settings.modelID == variant.id,
                        status: runtime.localModels.selectedVariantID == variant.id ? runtime.localModels.status : nil
                    ) {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        let previousVariantID = runtime.localModels.selectedVariantID
                        guard runtime.localModels.select(variant) else {
                            return
                        }
                        persistSettingsChange(
                            rollbackUI: {
                                runtime.localModels.selectedVariantID = previousVariantID
                            }
                        ) {
                            $0.modelID = variant.id
                        }
                    }
                }

                LocalModelDownloadPanel(manager: runtime.localModels)
            }
        }
    }
'''
new_local_section = '''    private var localModelSection: some View {
        SettingsSection(
            title: "Qwen 3.8 27B",
            subtitle: "One exact on-device target · immutable provenance · no model substitution"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 7) {
                    Label("Qwen 3.8 27B only", systemImage: "externaldrive.badge.timemachine")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(AgentPalette.ink)
                    Text("NovaForge searches for an exact Qwen 3.8 27B GGUF, pins its immutable revision and SHA-256, then uses the existing resumable downloader. Qwen 3.6 and smaller models are never offered as replacements.")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AgentPalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .agentSurface(radius: 16, tint: AgentPalette.cyan.opacity(0.07))

                if let target = LocalModelCatalog.exactQwen38Variant {
                    LocalModelVariantRow(
                        variant: target,
                        selected: settings.modelID == target.id,
                        status: runtime.localModels.selectedVariantID == target.id ? runtime.localModels.status : nil
                    ) {
                        selectExactQwen38Target(target)
                    }
                    if runtime.localModels.selectedVariantID == target.id {
                        LocalModelDownloadPanel(manager: runtime.localModels)
                    } else {
                        SettingsActionButton(title: "Use Qwen 3.8 27B", symbol: "checkmark.circle.fill", tint: AgentPalette.green, prominent: true) {
                            selectExactQwen38Target(target)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Image(systemName: "externaldrive.badge.questionmark")
                                .font(.system(size: 18, weight: .black))
                                .foregroundStyle(AgentPalette.warning)
                                .frame(width: 40, height: 40)
                                .agentControlSurface(radius: 12, tint: AgentPalette.warning.opacity(0.12), selected: true)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Verified open weights not found")
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(AgentPalette.ink)
                                Text(qwen38DiscoveryMessage ?? "Download remains locked until an exact 3.8 27B single-file GGUF has a pinned revision, byte size, and LFS SHA-256.")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(AgentPalette.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        SettingsActionButton(
                            title: checkingQwen38Release ? "Checking…" : "Check for Qwen 3.8 27B",
                            symbol: checkingQwen38Release ? "hourglass" : "arrow.clockwise",
                            tint: AgentPalette.cyan,
                            prominent: true
                        ) {
                            refreshQwen38Release()
                        }
                        .disabled(checkingQwen38Release)
                    }
                    .padding(12)
                    .agentSurface(radius: 16, tint: AgentPalette.warning.opacity(0.06))
                    .accessibilityIdentifier("settingsQwen38Unavailable")
                }
            }
        }
    }
'''
if sv.count(old_local_section) != 1: raise SystemExit('local model section marker mismatch')
sv = sv.replace(old_local_section, new_local_section)

# Local command-deck title and stats must never display a hidden fallback.
sv = sv.replace('''    private func modelDisplayName(_ model: String) -> String {
        LocalModelCatalog.variant(for: model)?.shortName
''', '''    private func modelDisplayName(_ model: String) -> String {
        if settings.provider == .local {
            return LocalModelCatalog.exactQwen38Variant?.shortName ?? "Qwen 3.8 27B"
        }
        return LocalModelCatalog.variant(for: model)?.shortName
''')
sv = sv.replace('''    private var modelReadinessStats: [SettingsMiniStat] {
        if let variant = LocalModelCatalog.variant(for: settings.modelID) {
''', '''    private var modelReadinessStats: [SettingsMiniStat] {
        if settings.provider == .local, let variant = LocalModelCatalog.exactQwen38Variant {
            return [
                SettingsMiniStat(label: "Context", value: "\\(variant.contextTokens)"),
                SettingsMiniStat(label: "Size", value: variant.expectedSizeLabel),
                SettingsMiniStat(label: "Engine", value: "mmap + Metal")
            ]
        }
        if settings.provider == .local {
            return [
                SettingsMiniStat(label: "Target", value: "27B"),
                SettingsMiniStat(label: "Weights", value: "Waiting"),
                SettingsMiniStat(label: "Policy", value: "Exact only")
            ]
        }
        if let variant = LocalModelCatalog.variant(for: settings.modelID) {
''')

# Provider readiness must key off exact target availability, not the hidden
# LocalModelManager fallback used by old tests/recovery code.
sv = sv.replace('''        if provider == .local {
            switch runtime.localModels.status {
''', '''        if provider == .local {
            guard let target = LocalModelCatalog.exactQwen38Variant else {
                return ("3.8 waiting", AgentPalette.warning)
            }
            guard runtime.localModels.selectedVariantID == target.id else {
                return ("Select 3.8", AgentPalette.cyan)
            }
            switch runtime.localModels.status {
''')

# Selection/discovery helpers before keyPlaceholder.
helper_marker = '    private var keyPlaceholder: String {\n'
if sv.count(helper_marker) != 1: raise SystemExit('helper insertion marker mismatch')
helpers = '''    private func selectExactQwen38Target(_ target: LocalModelVariant) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let previousVariantID = runtime.localModels.selectedVariantID
        guard runtime.localModels.select(target) else { return }
        persistSettingsChange(
            rollbackUI: { runtime.localModels.selectedVariantID = previousVariantID }
        ) { $0.modelID = target.id }
    }

    private func refreshQwen38Release() {
        guard !checkingQwen38Release else { return }
        checkingQwen38Release = true
        qwen38DiscoveryMessage = nil
        qwen38DiscoveryTask?.cancel()
        qwen38DiscoveryTask = Task { @MainActor in
            defer {
                checkingQwen38Release = false
                qwen38DiscoveryTask = nil
            }
            do {
                let target = try await Qwen38ReleaseDiscovery.refresh()
                try Task.checkCancellation()
                guard let target else {
                    qwen38DiscoveryMessage = "No exact Qwen 3.8 27B single-file GGUF with immutable revision + SHA-256 was found. NovaForge did not substitute another model."
                    return
                }
                qwen38DiscoveryMessage = "Verified \\(target.quantization) · \\(target.expectedSizeLabel) · revision pinned."
                selectExactQwen38Target(target)
                runtime.localModels.refreshStatus()
            } catch is CancellationError {
                return
            } catch {
                qwen38DiscoveryMessage = "Could not verify the Qwen 3.8 release catalog: \\(error.localizedDescription)"
            }
        }
    }

'''
sv = sv.replace(helper_marker, helpers + helper_marker)

# When Settings opens and a cached exact target exists, migrate an old local
# selection to it. Never migrate to an internal fallback.
sv = sv.replace('''        if let variant = LocalModelCatalog.variant(for: settings.modelID) {
            runtime.localModels.select(variant)
        }

        #if DEBUG || targetEnvironment(simulator)
''', '''        if settings.provider == .local, let target = LocalModelCatalog.exactQwen38Variant {
            runtime.localModels.select(target)
            if settings.modelID != target.id {
                _ = persistSettingsChange { $0.modelID = target.id }
            }
        } else if settings.provider != .local,
                  let variant = LocalModelCatalog.variant(for: settings.modelID) {
            runtime.localModels.select(variant)
        }

        #if DEBUG || targetEnvironment(simulator)
''')

runtime.write_text(rt)
settings.write_text(sv)
provider.write_text(pv)
print('patched strict Qwen 3.8 27B product path')
