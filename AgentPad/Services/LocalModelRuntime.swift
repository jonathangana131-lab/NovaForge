import CryptoKit
import Darwin
import Foundation
import Observation
import os
import AgentProviders
#if canImport(UIKit)
import UIKit
#endif

#if canImport(SwiftLlama)
import SwiftLlama
#endif

#if os(iOS) && canImport(CoreAI) && canImport(CoreAILanguageModels) && canImport(FoundationModels)
import CoreAI
import CoreAILanguageModels
import FoundationModels
#endif

enum LocalModelDeviceFit: String, Codable, CaseIterable, Sendable, Hashable {
    case deviceProven
    case ultraLight
    case memorySaver

    var title: String {
        switch self {
        case .deviceProven: "Device proven"
        case .ultraLight: "Ultra light"
        case .memorySaver: "Memory saver"
        }
    }

    var symbol: String {
        switch self {
        case .deviceProven: "checkmark.shield.fill"
        case .ultraLight: "bolt.fill"
        case .memorySaver: "memorychip.fill"
        }
    }
}

enum LocalModelTier: String, Codable, CaseIterable, Sendable, Hashable {
    case instant
    case fast
    case balanced
    case power

    var title: String { rawValue.capitalized }
    var sortOrder: Int {
        switch self {
        case .instant: 0
        case .fast: 1
        case .balanced: 2
        case .power: 3
        }
    }
}

enum LocalInferenceEngineType: String, Codable, CaseIterable, Sendable, Hashable {
    case coreAI
    case llamaCpp
    case companion

    var title: String {
        switch self {
        case .coreAI: "Core AI"
        case .llamaCpp: "GGUF/Metal"
        case .companion: "Companion"
        }
    }
}

enum LocalExecutionLocation: String, Codable, CaseIterable, Sendable, Hashable {
    case local
    case lan
    case cloud

    var title: String {
        switch self {
        case .local: "Local"
        case .lan: "LAN"
        case .cloud: "Cloud"
        }
    }
}

enum LocalModelArtifactKind: String, Codable, Sendable, Hashable {
    case downloadable
    case exportRequired
    case endpointManaged
}

enum LocalPhysicalBenchmarkStatus: String, Codable, Sendable, Hashable {
    case pending
    case unsupported
    case legacyProven
    case companionOnly
}

struct LocalModelVariant: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let displayName: String
    let shortName: String
    let tier: LocalModelTier
    let engineType: LocalInferenceEngineType
    let executionLocation: LocalExecutionLocation
    let artifactKind: LocalModelArtifactKind
    let immutableRevision: String
    let quantization: String
    let compressionDetails: String
    let filename: String
    let downloadURL: URL
    let expectedBytes: Int64
    let expectedSHA256: String
    let minimumPhysicalMemoryBytes: UInt64
    let recommendedFreeDiskBytes: Int64
    let contextTokens: UInt32
    let batchTokens: UInt32
    let maxNewTokens: Int
    let maxGenerationSeconds: Int
    let useGPU: Bool
    let gpuLayerCount: Int32
    let generationThreadCount: Int32
    let batchThreadCount: Int32
    let isIPhone12SafeDefault: Bool
    let releaseDateISO8601: String
    let releaseDateLabel: String
    let parameterLabel: String
    let licenseLabel: String
    let licenseURL: URL
    let licenseNotes: String
    let benchmarkSummary: String
    let capabilitySummary: String
    let deviceFit: LocalModelDeviceFit
    let estimatedPeakMemoryBytes: UInt64
    let measuredPeakMemoryBytes: UInt64?
    let minimumAvailableMemoryBeforeLoadBytes: UInt64
    let sourceURL: URL
    let chatTemplate: String
    let tokenizerRequirements: String
    let supportedDeviceClasses: [String]
    let toolCallingSupport: String
    let speculativeDecoding: String
    let physicalBenchmarkStatus: LocalPhysicalBenchmarkStatus
    let details: String

    var expectedSizeLabel: String {
        ByteCountFormatter.string(fromByteCount: expectedBytes, countStyle: .file)
    }

    var executionLabel: String {
        switch engineType {
        case .coreAI:
            "Core AI"
        case .llamaCpp:
            useGPU ? "GGUF · Metal \(gpuLayerCount)L" : "GGUF · CPU"
        case .companion:
            "LAN companion"
        }
    }

    var estimatedPeakMemoryLabel: String {
        ByteCountFormatter.string(
            fromByteCount: Int64(clamping: estimatedPeakMemoryBytes),
            countStyle: .memory
        )
    }

    var isNewRelease: Bool {
        releaseDateISO8601 >= "2026-07-01"
    }

    var isDownloadable: Bool { artifactKind == .downloadable }
}

/// The Local AI 2.0 charter calls manifest-backed model records descriptors.
/// Preserve the existing concrete name so saved IDs and older call sites stay
/// source-compatible while exposing the architecture's intended vocabulary.
typealias LocalModelDescriptor = LocalModelVariant

extension LocalModelVariant {
    /// Compatibility initializer for focused fixtures and the preserved V1
    /// download tests. Production descriptors always come from the pinned
    /// versioned manifest above this boundary.
    init(
        id: String,
        displayName: String,
        shortName: String,
        quantization: String,
        filename: String,
        downloadURL: URL,
        expectedBytes: Int64,
        expectedSHA256: String,
        minimumPhysicalMemoryBytes: UInt64,
        recommendedFreeDiskBytes: Int64,
        contextTokens: UInt32,
        batchTokens: UInt32,
        maxNewTokens: Int,
        maxGenerationSeconds: Int,
        useGPU: Bool,
        gpuLayerCount: Int32,
        generationThreadCount: Int32,
        batchThreadCount: Int32,
        isIPhone12SafeDefault: Bool,
        releaseDateISO8601: String,
        releaseDateLabel: String,
        parameterLabel: String,
        licenseLabel: String,
        benchmarkSummary: String,
        capabilitySummary: String,
        deviceFit: LocalModelDeviceFit,
        estimatedPeakMemoryBytes: UInt64,
        minimumAvailableMemoryBeforeLoadBytes: UInt64,
        sourceURL: URL,
        details: String
    ) {
        self.init(
            id: id,
            displayName: displayName,
            shortName: shortName,
            tier: .fast,
            engineType: .llamaCpp,
            executionLocation: .local,
            artifactKind: .downloadable,
            immutableRevision: String(repeating: "0", count: 40),
            quantization: quantization,
            compressionDetails: quantization,
            filename: filename,
            downloadURL: downloadURL,
            expectedBytes: expectedBytes,
            expectedSHA256: expectedSHA256,
            minimumPhysicalMemoryBytes: minimumPhysicalMemoryBytes,
            recommendedFreeDiskBytes: recommendedFreeDiskBytes,
            contextTokens: contextTokens,
            batchTokens: batchTokens,
            maxNewTokens: maxNewTokens,
            maxGenerationSeconds: maxGenerationSeconds,
            useGPU: useGPU,
            gpuLayerCount: gpuLayerCount,
            generationThreadCount: generationThreadCount,
            batchThreadCount: batchThreadCount,
            isIPhone12SafeDefault: isIPhone12SafeDefault,
            releaseDateISO8601: releaseDateISO8601,
            releaseDateLabel: releaseDateLabel,
            parameterLabel: parameterLabel,
            licenseLabel: licenseLabel,
            licenseURL: sourceURL,
            licenseNotes: "Unit-test fixture",
            benchmarkSummary: benchmarkSummary,
            capabilitySummary: capabilitySummary,
            deviceFit: deviceFit,
            estimatedPeakMemoryBytes: estimatedPeakMemoryBytes,
            measuredPeakMemoryBytes: nil,
            minimumAvailableMemoryBeforeLoadBytes: minimumAvailableMemoryBeforeLoadBytes,
            sourceURL: sourceURL,
            chatTemplate: "fixture",
            tokenizerRequirements: "fixture",
            supportedDeviceClasses: ["fixture"],
            toolCallingSupport: "fixture",
            speculativeDecoding: "disabled",
            physicalBenchmarkStatus: .pending,
            details: details
        )
    }
}

private struct LocalModelCatalogManifest: Decodable {
    let schemaVersion: Int
    let generatedAt: String
    let models: [LocalModelVariant]
}

private final class LocalModelCatalogBundleMarker: NSObject {}

enum LocalModelCatalog {
    static let manifestSchemaVersion = 2
    static let manifestSHA256 = "d46f4fdeebe03bf4da13ecfaeacd8da8b9ce02c91a8b710bb799a5abdc817e24"
    static let powerOnDeviceExperimentID =
        "unsloth/Qwen3.8-27B-UD-IQ1_S-Power-On-Device"
    static let powerOnDeviceExperimentIDs: Set<String> = [
        powerOnDeviceExperimentID,
        "unsloth/Qwen3.8-27B-UD-IQ2_XXS-Power-On-Device",
        "unsloth/Qwen3.8-27B-Q3_K_M-Power-On-Device",
    ]
    static let repository = "Qwen/Qwen2.5-Coder-1.5B-Instruct-GGUF"
    static let verifiedRevision = "f86cb2c1fa58255f8052cc32aeede1b7482d4361"
    static let all: [LocalModelVariant] = loadManifest().models

    static var presentationOrder: [LocalModelVariant] {
        all.sorted {
            if $0.tier != $1.tier {
                return $0.tier.sortOrder < $1.tier.sortOrder
            }
            let lhsIsCompatible = compatibilityMessage(for: $0) == nil
            let rhsIsCompatible = compatibilityMessage(for: $1) == nil
            if lhsIsCompatible != rhsIsCompatible {
                return lhsIsCompatible
            }
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
        let migrated = migratedID(for: id)
        return all.first { $0.id == migrated }
    }

    static func migratedID(for persistedID: String) -> String {
        let trimmed = persistedID.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed {
        case "Siddh07ETH/Atlas-Coder-2-0.5B-Q4_K_M":
            return "LiquidAI/LFM2.5-350M-QAD-Q4_0"
        case "Qwen/Qwen2.5-Coder-1.5B-Instruct-Q2_K":
            return "Qwen/Qwen2.5-Coder-1.5B-Instruct-Q3_K_M"
        default:
            return trimmed
        }
    }

    static func safestVariant(forPhysicalMemory physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> LocalModelVariant {
        all.first { $0.isIPhone12SafeDefault && physicalMemory >= $0.minimumPhysicalMemoryBytes }
            ?? all.first { physicalMemory >= $0.minimumPhysicalMemoryBytes }
            ?? all.last!
    }

    static func compatibilityMessage(
        for variant: LocalModelVariant,
        physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> String? {
        switch variant.engineType {
        case .coreAI:
            guard LocalRuntimeCapabilities.current.supportsCoreAI else {
                return "Core AI requires an iOS 27 / Xcode 27 NovaForge build and a pinned AOT .aimodel asset. This build stays on the GGUF rollback route."
            }
            guard CoreAIModelAssetResolver.resourcesURL(for: variant) != nil else {
                return "Prepare and pin the Core AI AOT asset before selecting this model. Specialization never starts inside chat."
            }
        case .companion:
            return CompanionModelConfigurationStore.compatibilityMessage()
        case .llamaCpp:
            guard variant.isDownloadable else {
                return "This GGUF route has no pinned downloadable artifact."
            }
        }

        if powerOnDeviceExperimentIDs.contains(variant.id) {
            // Launch-only escape hatch for the bounded Xcode 27 physical
            // admission protocol. Normal UI selection remains fail-closed;
            // every quant needs its own exact physical receipt.
            if isPowerOnDeviceAdmissionExperiment(variant) {
                return nil
            }
            return "Power — On-device streamed is experimental and has not passed the iPhone 12 admission matrix for \(variant.quantization). Downloading or selecting it never falls back to LAN."
        }

        if physicalMemory < variant.minimumPhysicalMemoryBytes {
            let needed = ByteCountFormatter.string(fromByteCount: Int64(variant.minimumPhysicalMemoryBytes), countStyle: .memory)
            let current = ByteCountFormatter.string(fromByteCount: Int64(physicalMemory), countStyle: .memory)
            return "\(variant.shortName) needs about \(needed) physical RAM. This device reports \(current). Choose an Ultra light or Memory saver model."
        }

        let safePeakBudget = physicalMemory * 55 / 100
        if variant.estimatedPeakMemoryBytes > safePeakBudget {
            return "\(variant.shortName)'s estimated \(variant.estimatedPeakMemoryLabel) peak is too close to this device's memory ceiling. Choose an Ultra light or Memory saver model."
        }

        return nil
    }

    static func isPowerOnDeviceAdmissionExperiment(
        _ variant: LocalModelVariant,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
        powerOnDeviceExperimentIDs.contains(variant.id) &&
            arguments.contains("--local-power-admission-experiment")
    }

    static func modelDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("LocalModels", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func fileURL(for variant: LocalModelVariant) throws -> URL {
        guard variant.isDownloadable, !variant.filename.isEmpty else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try modelDirectory().appendingPathComponent(variant.filename)
    }

    static func validateManifestData(_ data: Data) throws -> [LocalModelVariant] {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == manifestSHA256 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let manifest = try JSONDecoder().decode(LocalModelCatalogManifest.self, from: data)
        let generatedDay = String(manifest.generatedAt.prefix(10))
        guard manifest.schemaVersion == manifestSchemaVersion,
              ISO8601DateFormatter().date(from: manifest.generatedAt) != nil,
              isValidISODate(generatedDay),
              !manifest.models.isEmpty,
              Set(manifest.models.map(\.id)).count == manifest.models.count,
              manifest.models.allSatisfy({
                  !$0.id.isEmpty && !$0.displayName.isEmpty
              }),
              Set(manifest.models.filter(\.isDownloadable).map(\.filename))
                .count == manifest.models.filter(\.isDownloadable).count,
              manifest.models.filter(\.isIPhone12SafeDefault).count == 1
        else { throw CocoaError(.fileReadCorruptFile) }

        for model in manifest.models {
            guard model.immutableRevision.count == 40,
                  model.immutableRevision.allSatisfy({ $0.isHexDigit }),
                  !model.immutableRevision.allSatisfy({ $0 == "0" }),
                  model.downloadURL.scheme == "https",
                  model.sourceURL.scheme == "https",
                  model.licenseURL.scheme == "https",
                  model.downloadURL.host == model.sourceURL.host,
                  model.licenseURL.host == model.sourceURL.host,
                  isPinnedURL(
                      model.downloadURL,
                      to: model.immutableRevision
                  ),
                  isPinnedURL(
                      model.sourceURL,
                      to: model.immutableRevision
                  ),
                  isPinnedURL(
                      model.licenseURL,
                      to: model.immutableRevision
                  ),
                  isValidISODate(model.releaseDateISO8601),
                  model.releaseDateISO8601 <= generatedDay,
                  model.contextTokens > 0,
                  model.maxNewTokens > 0 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            if model.isDownloadable {
                guard model.expectedBytes > 0,
                      model.expectedSHA256.count == 64,
                      model.expectedSHA256.allSatisfy({ $0.isHexDigit }),
                      !model.filename.isEmpty,
                      isSafeFilename(model.filename) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
            } else {
                guard model.expectedBytes == 0,
                      model.expectedSHA256.isEmpty else {
                    throw CocoaError(.fileReadCorruptFile)
                }
            }
        }
        return manifest.models
    }

    private static func isValidISODate(_ value: String) -> Bool {
        let components = value.split(separator: "-", omittingEmptySubsequences: false)
        guard components.count == 3,
              components[0].count == 4,
              components[1].count == 2,
              components[2].count == 2,
              let year = Int(components[0]),
              let month = Int(components[1]),
              let day = Int(components[2]) else { return false }
        var dateComponents = DateComponents()
        dateComponents.calendar = Calendar(identifier: .gregorian)
        dateComponents.timeZone = TimeZone(secondsFromGMT: 0)
        dateComponents.year = year
        dateComponents.month = month
        dateComponents.day = day
        return dateComponents.date != nil
    }

    private static func isSafeFilename(_ value: String) -> Bool {
        let url = URL(fileURLWithPath: value)
        return value == url.lastPathComponent &&
            !value.isEmpty && value != "." && value != ".." &&
            !value.contains("/") && !value.contains("\\")
    }

    private static func isPinnedURL(_ url: URL, to revision: String) -> Bool {
        let segments = url.path.split(separator: "/")
        return segments.indices.contains { index in
            guard index > segments.startIndex else { return false }
            let marker = String(segments[index - 1])
            return ["resolve", "tree", "blob"].contains(marker) &&
                String(segments[index]) == revision
        }
    }

    private static func loadManifest() -> LocalModelCatalogManifest {
        let bundles = [Bundle(for: LocalModelCatalogBundleMarker.self), .main]
        for bundle in bundles {
            guard let url = bundle.url(
                forResource: "LocalModelCatalog.v2",
                withExtension: "json"
            ), let data = try? Data(contentsOf: url),
              let models = try? validateManifestData(data),
              let manifest = try? JSONDecoder().decode(
                  LocalModelCatalogManifest.self,
                  from: data
              ) else { continue }
            return LocalModelCatalogManifest(
                schemaVersion: manifest.schemaVersion,
                generatedAt: manifest.generatedAt,
                models: models
            )
        }
        preconditionFailure("Pinned LocalModelCatalog.v2.json is missing or invalid")
    }
}

enum CoreAIModelAssetResolver {
    static func resourcesURL(for descriptor: LocalModelVariant) -> URL? {
        guard descriptor.engineType == .coreAI else { return nil }
        let resourceName = URL(fileURLWithPath: descriptor.filename)
            .deletingPathExtension()
            .lastPathComponent
        return Bundle.main.url(
            forResource: resourceName,
            withExtension: nil
        )
    }
}

struct LocalRuntimeCapabilities: Codable, Equatable, Sendable {
    let osVersion: String
    let osMajorVersion: Int
    let deviceIdentifier: String
    let physicalMemoryBytes: UInt64
    let safeProcessCeilingBytes: UInt64
    let supportsCoreAI: Bool
    let supportsLlamaCpp: Bool
    let supportsMetal: Bool
    let llamaBuild: String

    static func isCoreAIHardwareSupported(
        deviceIdentifier: String
    ) -> Bool {
        func majorVersion(after prefix: String) -> Int? {
            guard deviceIdentifier.hasPrefix(prefix) else { return nil }
            return Int(deviceIdentifier.dropFirst(prefix.count).split(separator: ",").first ?? "")
        }
        if let major = majorVersion(after: "iPhone") {
            // iPhone16,1/2 are the A17 Pro iPhone 15 Pro family. iPhone 12 is
            // iPhone13,x and remains on llama.cpp even when running iOS 27.
            return major >= 16
        }
        if let major = majorVersion(after: "iPad") {
            // Conservative allow-list floor. Older identifiers contain a mix
            // of M-series and non-Apple-Intelligence devices.
            return major >= 15
        }
        return false
    }

    static var current: Self {
        var machine = utsname()
        uname(&machine)
        let identifier = withUnsafePointer(to: &machine.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let physical = ProcessInfo.processInfo.physicalMemory
#if os(iOS) && canImport(CoreAI) && canImport(CoreAILanguageModels) && canImport(FoundationModels)
#if targetEnvironment(simulator) || targetEnvironment(macCatalyst)
        let coreAI = false
#else
        let coreAI = version.majorVersion >= 27 &&
            isCoreAIHardwareSupported(deviceIdentifier: identifier)
#endif
#else
        let coreAI = false
        #endif
        #if canImport(SwiftLlama)
        let llama = true
        let llamaBuild = SwiftLlamaBuild.activeIdentifier
        #else
        let llama = false
        let llamaBuild = "unlinked"
        #endif
        #if targetEnvironment(simulator)
        let metal = false
        #else
        let metal = true
        #endif
        return Self(
            osVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            osMajorVersion: version.majorVersion,
            deviceIdentifier: identifier,
            physicalMemoryBytes: physical,
            safeProcessCeilingBytes: physical * 55 / 100,
            supportsCoreAI: coreAI,
            supportsLlamaCpp: llama,
            supportsMetal: metal,
            llamaBuild: llamaBuild
        )
    }

    /// Framework importability is not device admission. Core AI remains a
    /// physical-device, iOS-27-only lane and the GGUF route is the rollback.
    var coreAIUnavailableReason: String? {
        supportsCoreAI
            ? nil
            : "Core AI requires iOS 27 or later on a supported physical device; use the GGUF rollback route."
    }
}

enum LocalLlamaExecutionProfile: String, Codable, CaseIterable, Sendable {
    case catalog
    case cpu
    case partialMetal = "partial-metal"
    case fullMetal = "full-metal"

    static func resolve(arguments: [String]) -> Self {
        let prefix = "--local-llama-profile="
        guard let value = arguments.first(where: { $0.hasPrefix(prefix) })?
            .dropFirst(prefix.count),
              let profile = Self(rawValue: String(value)) else {
            return .catalog
        }
        return profile
    }

    static var current: Self {
        resolve(arguments: ProcessInfo.processInfo.arguments)
    }

    func configuration(
        for variant: LocalModelVariant
    ) -> (useGPU: Bool, gpuLayerCount: Int32) {
        switch self {
        case .catalog:
            (variant.useGPU, variant.gpuLayerCount)
        case .cpu:
            (false, 0)
        case .partialMetal:
            (true, max(1, min(12, variant.gpuLayerCount)))
        case .fullMetal:
            (true, max(variant.gpuLayerCount, 99))
        }
    }
}

struct CompanionModelConfiguration: Codable, Equatable, Sendable {
    let endpoint: URL
    let remoteModelID: String
    let immutableRevision: String
    let userConfirmedAt: Date
}

struct CompanionServerAttestation: Decodable, Equatable, Sendable {
    let modelID: String
    let revision: String
    let runtime: String
    let capabilities: [String]
    let contextLimit: UInt32
    let textOnly: Bool
    let mtpSupported: Bool

    enum CodingKeys: String, CodingKey {
        case modelID = "id"
        case revision
        case runtime
        case capabilities
        case contextLimit = "context_limit"
        case textOnly = "text_only"
        case mtpSupported = "mtp_supported"
    }
}

enum CompanionEndpointPolicy {
    static let companionModelID = "Qwen/Qwen3.8-27B"

    static func normalizedBaseURL(
        from input: String,
        allowLoopbackForSimulatorTesting: Bool = false
    ) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              let host = components.host?.lowercased(),
              isPrivateLANHost(
                  host,
                  allowLoopbackForSimulatorTesting:
                      allowLoopbackForSimulatorTesting
              )
        else { return nil }
        components.scheme = scheme
        let path = components.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = path.isEmpty ? "" : "/\(path)"
        return components.url
    }

    static func completionURL(from base: URL) -> URL {
        apiURL(from: base, suffix: "chat/completions")
    }

    static func modelsURL(from base: URL) -> URL {
        apiURL(from: base, suffix: "models")
    }

    static func isPrivateLANHost(
        _ host: String,
        allowLoopbackForSimulatorTesting: Bool = false
    ) -> Bool {
        let normalizedHost = host
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        if normalizedHost.hasSuffix(".local") {
            return true
        }
        if allowLoopbackForSimulatorTesting,
           normalizedHost == "localhost" || normalizedHost == "127.0.0.1" ||
           normalizedHost == "::1"
        {
            return true
        }
        if normalizedHost == "localhost" || normalizedHost == "127.0.0.1" ||
            normalizedHost == "::1"
        {
            return false
        }
        let octets = normalizedHost.split(separator: ".").compactMap { UInt8($0) }
        if octets.count == 4 {
            if octets[0] == 10 { return true }
            if octets[0] == 192, octets[1] == 168 { return true }
            if octets[0] == 172, (16 ... 31).contains(octets[1]) { return true }
            if octets[0] == 169, octets[1] == 254 { return true }
        }
        var address = in6_addr()
        guard normalizedHost.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else {
            return false
        }
        return withUnsafeBytes(of: address) { bytes in
            let first = bytes[0]
            let second = bytes[1]
            return (first & 0xfe) == 0xfc ||
                (first == 0xfe && (second & 0xc0) == 0x80)
        }
    }

    static func validateAttestation(
        _ attestation: CompanionServerAttestation,
        for descriptor: LocalModelVariant,
        expectedModelID: String = companionModelID,
        expectedRevision: String
    ) -> Bool {
        guard descriptor.engineType == .companion,
              expectedModelID == companionModelID,
              isImmutableRevision(expectedRevision),
              attestation.modelID == expectedModelID,
              attestation.revision == expectedRevision,
              isImmutableRevision(attestation.revision),
              ["mlx", "llama.cpp", "llama-cpp"].contains(
                  attestation.runtime
                      .trimmingCharacters(in: .whitespacesAndNewlines)
                      .lowercased()
              ),
              Set(attestation.capabilities.map { $0.lowercased() })
                .isSuperset(of: ["text", "streaming"]),
              attestation.contextLimit >= descriptor.contextTokens,
              attestation.textOnly
        else { return false }

        // `mtpSupported` is deliberately decoded as required metadata, but
        // advertising it does not enable speculative decoding in the client.
        return true
    }

    static func isImmutableRevision(_ revision: String) -> Bool {
        revision.count == 40 && revision.unicodeScalars.allSatisfy {
            (48 ... 57).contains($0.value) ||
                (97 ... 102).contains($0.value) ||
                (65 ... 70).contains($0.value)
        }
    }

    static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let lhsScheme = lhs.scheme?.lowercased(),
              let rhsScheme = rhs.scheme?.lowercased(),
              let lhsHost = lhs.host?.lowercased(),
              let rhsHost = rhs.host?.lowercased()
        else { return false }
        let lhsPort = lhs.port ?? (lhsScheme == "https" ? 443 : 80)
        let rhsPort = rhs.port ?? (rhsScheme == "https" ? 443 : 80)
        return lhsScheme == rhsScheme && lhsHost == rhsHost && lhsPort == rhsPort
    }

    private static func apiURL(from base: URL, suffix: String) -> URL {
        var url = base
        if !url.pathComponents.contains("v1") {
            url.appendPathComponent("v1")
        }
        for component in suffix.split(separator: "/") {
            url.appendPathComponent(String(component))
        }
        return url
    }
}

enum CompanionModelConfigurationStore {
    private static let endpointKey = "localAI2.companion.endpoint"
    private static let modelKey = "localAI2.companion.model"
    private static let revisionKey = "localAI2.companion.revision"
    private static let confirmationKey = "localAI2.companion.confirmedAt"

    static func snapshot(defaults: UserDefaults = .standard) -> CompanionModelConfiguration? {
        guard let endpointText = defaults.string(forKey: endpointKey),
              let endpoint = CompanionEndpointPolicy.normalizedBaseURL(from: endpointText),
              let modelID = defaults.string(forKey: modelKey),
              modelID == CompanionEndpointPolicy.companionModelID,
              let revision = defaults.string(forKey: revisionKey),
              CompanionEndpointPolicy.isImmutableRevision(revision),
              let confirmedAt = defaults.object(forKey: confirmationKey) as? Date
        else { return nil }
        return CompanionModelConfiguration(
            endpoint: endpoint,
            remoteModelID: modelID,
            immutableRevision: revision,
            userConfirmedAt: confirmedAt
        )
    }

    static func saveConfirmed(
        endpointText: String,
        descriptor: LocalModelVariant,
        defaults: UserDefaults = .standard,
        now: Date = Date()
    ) throws {
        guard descriptor.engineType == .companion,
              descriptor.id == "Qwen/Qwen3.8-27B-Power-Companion",
              CompanionEndpointPolicy.isImmutableRevision(
                  descriptor.immutableRevision
              ),
              let endpoint = CompanionEndpointPolicy.normalizedBaseURL(from: endpointText)
        else { throw LocalModelRuntimeError.invalidCompanionEndpoint }
        CompanionPrivacyStore.revoke(defaults: defaults)
        defaults.set(endpoint.absoluteString, forKey: endpointKey)
        defaults.set(CompanionEndpointPolicy.companionModelID, forKey: modelKey)
        defaults.set(descriptor.immutableRevision, forKey: revisionKey)
        defaults.set(now, forKey: confirmationKey)
    }

    static func revoke(defaults: UserDefaults = .standard) {
        for key in [endpointKey, modelKey, revisionKey, confirmationKey] {
            defaults.removeObject(forKey: key)
        }
        CompanionPrivacyStore.revoke(defaults: defaults)
    }

    static func compatibilityMessage(defaults: UserDefaults = .standard) -> String? {
        guard let configuration = snapshot(defaults: defaults),
              CompanionPrivacyStore.isConsented(
                  configuration,
                  defaults: defaults
              )
        else {
            return "Power — Companion needs a private-LAN endpoint and explicit content-sharing confirmation. NovaForge will not send a prompt until both are saved."
        }
        return nil
    }
}

/// Runtime-owned companion consent. The fingerprint is bound to the exact
/// canonical endpoint, model identity, and immutable revision, so a stale UI
/// toggle cannot authorize a changed LAN destination.
enum CompanionPrivacyStore {
    static let consentFingerprintKey =
        "localAI2.companion.consentFingerprint"

    static func fingerprint(
        _ configuration: CompanionModelConfiguration?
    ) -> String? {
        guard let configuration else { return nil }
        return [
            configuration.endpoint.absoluteString,
            configuration.remoteModelID,
            configuration.immutableRevision,
        ].joined(separator: "\n")
    }

    static func isConsented(
        _ configuration: CompanionModelConfiguration? =
            CompanionModelConfigurationStore.snapshot(),
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard let fingerprint = fingerprint(configuration) else { return false }
        return defaults.string(forKey: consentFingerprintKey) == fingerprint
    }

    static func grant(
        for configuration: CompanionModelConfiguration? =
            CompanionModelConfigurationStore.snapshot(),
        defaults: UserDefaults = .standard
    ) {
        guard let fingerprint = fingerprint(configuration) else { return }
        defaults.set(fingerprint, forKey: consentFingerprintKey)
    }

    static func revoke(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: consentFingerprintKey)
    }
}

enum LocalModelRuntimeMemoryPolicy {
    static func availableMemoryBytes() -> UInt64? {
        #if os(iOS) && !targetEnvironment(simulator)
        UInt64(os_proc_available_memory())
        #else
        nil
        #endif
    }

    static func admissionMessage(
        for variant: LocalModelVariant,
        availableMemory: UInt64? = availableMemoryBytes(),
        thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    ) -> String? {
        switch thermalState {
        case .critical:
            return "The iPhone is too hot to safely load a local model. Let it cool, then try again."
        case .serious where variant.deviceFit != .ultraLight:
            return "The iPhone is running hot. NovaForge held back \(variant.shortName); use the Instant tier or let the phone cool first."
        case .nominal, .fair, .serious:
            break
        @unknown default:
            return "NovaForge could not verify the current thermal state, so it did not load a local model."
        }

        if LocalModelCatalog.isPowerOnDeviceAdmissionExperiment(variant) {
            return nil
        }

        guard let availableMemory else { return nil }
        guard availableMemory >= variant.minimumAvailableMemoryBeforeLoadBytes else {
            let needed = ByteCountFormatter.string(
                fromByteCount: Int64(clamping: variant.minimumAvailableMemoryBeforeLoadBytes),
                countStyle: .memory
            )
            let available = ByteCountFormatter.string(
                fromByteCount: Int64(clamping: availableMemory),
                countStyle: .memory
            )
            return "NovaForge held back \(variant.shortName) before first-prompt allocation. It needs about \(needed) available; iOS reports \(available). Close memory-heavy apps or choose the Instant tier."
        }
        return nil
    }
}

private struct LocalRuntimeExecutionPlan: Sendable {
    let contextTokens: UInt32
    let batchTokens: UInt32
    let useGPU: Bool
    let gpuLayerCount: Int32
    let reducedMemoryMode: Bool

    static func resolve(for variant: LocalModelVariant) -> Self {
        let thermal = ProcessInfo.processInfo.thermalState
        let available = LocalModelRuntimeMemoryPolicy.availableMemoryBytes()
        let reduced = thermal == .serious ||
            (available.map {
                $0 < variant.estimatedPeakMemoryBytes * 125 / 100
            } ?? false)
        guard reduced else {
            let gpu = LocalLlamaExecutionProfile.current.configuration(
                for: variant
            )
            return Self(
                contextTokens: variant.contextTokens,
                batchTokens: variant.batchTokens,
                useGPU: gpu.useGPU,
                gpuLayerCount: gpu.gpuLayerCount,
                reducedMemoryMode: false
            )
        }
        return Self(
            contextTokens: min(variant.contextTokens, 2_048),
            batchTokens: min(variant.batchTokens, 32),
            useGPU: false,
            gpuLayerCount: 0,
            reducedMemoryMode: true
        )
    }
}

private enum LocalInferenceInputPolicy {
    static func boundedMessages(
        _ messages: [AgentLocalModelInferenceMessage],
        contextTokens: UInt32
    ) -> [AgentLocalModelInferenceMessage] {
        let byteBudget = max(4_096, Int(contextTokens) * 4)
        var remaining = byteBudget
        var result: [AgentLocalModelInferenceMessage] = []
        for message in messages.reversed() {
            guard remaining > 0 else { break }
            let content = String(
                decoding: message.content.utf8.prefix(remaining),
                as: UTF8.self
            )
            let bounded = AgentLocalModelInferenceMessage(
                role: message.role,
                content: content
            )
            let cost = bounded.content.utf8.count
            guard cost <= remaining || result.isEmpty else { continue }
            result.append(bounded)
            remaining -= min(cost, remaining)
        }
        return Array(result.reversed())
    }
}

enum LocalModelStatus: Equatable {
    case missing
    case checking
    case partial
    case downloading
    case ready
    case incompatible(String)
    case failed(String)

    var title: String {
        switch self {
        case .missing: "Not Downloaded"
        case .checking: "Checking"
        case .partial: "Paused"
        case .downloading: "Downloading"
        case .ready: "Ready"
        case .incompatible: "Needs Attention"
        case .failed: "Failed"
        }
    }
}

struct LocalModelDownloadProgress: Sendable {
    let receivedBytes: Int64
    let totalBytes: Int64

    var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(receivedBytes) / Double(totalBytes)))
    }
}

#if canImport(UIKit)
/// Process-wide eviction authority for memory, thermal, and background
/// pressure. Its lifetime does not depend on the Control screen's manager.
private final class LocalModelRuntimeLifecycle: @unchecked Sendable {
    static let shared = LocalModelRuntimeLifecycle()
    private var started = false
    private var tokens: [NSObjectProtocol] = []

    func start() {
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        for name in [
            UIApplication.didReceiveMemoryWarningNotification,
            UIApplication.didEnterBackgroundNotification,
            ProcessInfo.thermalStateDidChangeNotification,
        ] {
            tokens.append(center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { _ in
                Task { await LocalModelClient.shared.unload() }
            })
        }
    }

    func unloadForProviderSwitch() {
        Task { await LocalModelClient.shared.unload() }
    }
}
#endif

struct LocalModelBenchmarkResult: Equatable, Sendable {
    let modelName: String
    let timeToFirstToken: TimeInterval
    let totalDuration: TimeInterval
    let generatedCharacters: Int
    let generatedTokens: Int
    let receiptID: UUID

    /// Kept as a compatibility name for existing UI. Canonical usage frames
    /// now provide the exact runtime token count.
    var estimatedTokens: Int { generatedTokens }

    var tokensPerSecond: Double {
        let generation = max(totalDuration - timeToFirstToken, 0.05)
        return Double(estimatedTokens) / generation
    }
}

struct LocalBenchmarkReceipt: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let recordedAt: Date
    let modelID: String
    let immutableRevision: String
    let engineType: LocalInferenceEngineType
    let executionLocation: LocalExecutionLocation
    let deviceIdentifier: String
    let operatingSystem: String
    let isPhysicalDevice: Bool
    let runtimeBuild: String
    let executionConfiguration: String?
    let contextTokens: UInt32
    let maximumOutputTokens: Int
    let timeToFirstTokenSeconds: TimeInterval
    let promptTokensPerSecond: Double?
    let decodeTokensPerSecond: Double
    let totalDurationSeconds: TimeInterval
    let generatedCharacters: Int
    let estimatedGeneratedTokens: Int
    let peakPhysicalFootprintBytes: UInt64?
    let thermalStateBefore: String
    let thermalStateAfter: String
    let batteryLevelBefore: Float?
    let batteryLevelAfter: Float?
    let result: String
}

actor LocalBenchmarkReceiptStore {
    static let shared = LocalBenchmarkReceiptStore()

    private let directoryURL: URL

    init(directoryURL: URL? = nil) {
        if let directoryURL {
            self.directoryURL = directoryURL
        } else {
            let base = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
            self.directoryURL = base
                .appendingPathComponent("LocalAI", isDirectory: true)
                .appendingPathComponent("BenchmarkReceipts", isDirectory: true)
        }
    }

    func save(_ receipt: LocalBenchmarkReceipt) throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(receipt)
        try data.write(
            to: directoryURL.appendingPathComponent("\(receipt.id.uuidString).json"),
            options: .atomic
        )
        try data.write(
            to: directoryURL.appendingPathComponent("latest.json"),
            options: .atomic
        )
    }

    func latest() throws -> LocalBenchmarkReceipt? {
        let url = directoryURL.appendingPathComponent("latest.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try LocalModelReceiptMigration.migrate(
            decoder.decode(
                LocalBenchmarkReceipt.self,
                from: Data(contentsOf: url)
            )
        )
    }
}

/// Migrate only stable IDs. Historical revision/hash evidence remains intact;
/// rewriting provenance would turn a compatibility migration into a false
/// benchmark claim.
enum LocalModelReceiptMigration {
    static func migrate(
        _ receipt: LocalBenchmarkReceipt
    ) -> LocalBenchmarkReceipt {
        let modelID = LocalModelCatalog.migratedID(for: receipt.modelID)
        guard modelID != receipt.modelID else { return receipt }
        return LocalBenchmarkReceipt(
            id: receipt.id,
            recordedAt: receipt.recordedAt,
            modelID: modelID,
            immutableRevision: receipt.immutableRevision,
            engineType: receipt.engineType,
            executionLocation: receipt.executionLocation,
            deviceIdentifier: receipt.deviceIdentifier,
            operatingSystem: receipt.operatingSystem,
            isPhysicalDevice: receipt.isPhysicalDevice,
            runtimeBuild: receipt.runtimeBuild,
            executionConfiguration: receipt.executionConfiguration,
            contextTokens: receipt.contextTokens,
            maximumOutputTokens: receipt.maximumOutputTokens,
            timeToFirstTokenSeconds: receipt.timeToFirstTokenSeconds,
            promptTokensPerSecond: receipt.promptTokensPerSecond,
            decodeTokensPerSecond: receipt.decodeTokensPerSecond,
            totalDurationSeconds: receipt.totalDurationSeconds,
            generatedCharacters: receipt.generatedCharacters,
            estimatedGeneratedTokens: receipt.estimatedGeneratedTokens,
            peakPhysicalFootprintBytes: receipt.peakPhysicalFootprintBytes,
            thermalStateBefore: receipt.thermalStateBefore,
            thermalStateAfter: receipt.thermalStateAfter,
            batteryLevelBefore: receipt.batteryLevelBefore,
            batteryLevelAfter: receipt.batteryLevelAfter,
            result: receipt.result
        )
    }

    static func migrate(
        _ receipt: LocalAIEvaluationReceipt
    ) -> LocalAIEvaluationReceipt {
        let modelID = LocalModelCatalog.migratedID(for: receipt.modelID)
        guard modelID != receipt.modelID else { return receipt }
        return LocalAIEvaluationReceipt(
            id: receipt.id,
            runID: receipt.runID,
            recordedAt: receipt.recordedAt,
            corpusSHA256: receipt.corpusSHA256,
            modelID: modelID,
            modelSHA256: receipt.modelSHA256,
            immutableRevision: receipt.immutableRevision,
            executionConfiguration: receipt.executionConfiguration,
            deviceIdentifier: receipt.deviceIdentifier,
            operatingSystem: receipt.operatingSystem,
            isPhysicalDevice: receipt.isPhysicalDevice,
            passedCaseCount: receipt.passedCaseCount,
            totalCaseCount: receipt.totalCaseCount,
            score: receipt.score,
            cases: receipt.cases
        )
    }
}

struct LocalAIEvaluationCorpus: Codable, Equatable, Sendable {
    static let expectedSHA256 = "75fd1e718c227ee71f350c336522074a0dc66d56b144a1eed028c79cc35519e4"

    struct Scoring: Codable, Equatable, Sendable {
        let toolDecisionMustParse: Bool
        let inventedToolFailsCorpus: Bool
        let repetitionWindow: Int
        let maximumRepeatedWindowCount: Int
    }

    struct Message: Codable, Equatable, Sendable {
        let role: String
        let content: String
    }

    struct EvaluationCase: Codable, Equatable, Sendable {
        let id: String
        let category: String
        let prompt: String?
        let system: String?
        let context: String?
        let messages: [Message]?
        let availableTools: [String]?
        let expectedTool: String?
        let mustContain: [String]?
        let mustContainAny: [String]?
        let mustNotContain: [String]?
        let exactOutput: String?
        let maximumOutputTokens: Int?
        let minimumUsefulOutputTokens: Int?
        let rejectRepeatedNGramSize: Int?
        let rejectRepeatedNGramCount: Int?
        let record: [String]?
    }

    let schemaVersion: Int
    let name: String
    let createdAt: String
    let scoring: Scoring
    let cases: [EvaluationCase]

    static func load(bundle: Bundle = .main) throws -> Self {
        guard let url = bundle.url(
            forResource: "LocalAI2Corpus.v1",
            withExtension: "json"
        ) else { throw LocalAIEvaluationError.corpusMissing }
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
        guard digest == expectedSHA256 else {
            throw LocalAIEvaluationError.corpusDigestMismatch(
                expected: expectedSHA256,
                actual: digest
            )
        }
        let corpus = try JSONDecoder().decode(Self.self, from: data)
        guard corpus.schemaVersion == 1,
              !corpus.cases.isEmpty,
              Set(corpus.cases.map(\.id)).count == corpus.cases.count,
              corpus.cases.allSatisfy({ !$0.id.isEmpty && !$0.category.isEmpty })
        else { throw LocalAIEvaluationError.invalidCorpus }
        return corpus
    }
}

enum LocalAIEvaluationError: Error, Equatable, Sendable {
    case corpusMissing
    case corpusDigestMismatch(expected: String, actual: String)
    case invalidCorpus
    case emptyOutput(String)
    case receiptMissing
}

struct LocalAIEvaluationCaseReceipt: Codable, Equatable, Sendable {
    let id: String
    let category: String
    let passed: Bool
    let failureReasons: [String]
    let output: String
    let selectedAction: String?
    let generatedTokens: UInt64?
    let timeToFirstTokenSeconds: TimeInterval?
    let totalDurationSeconds: TimeInterval
    let decodeTokensPerSecond: Double?
    let peakPhysicalFootprintBytes: UInt64?
    let thermalStateBefore: String
    let thermalStateAfter: String
    let batteryLevelBefore: Float?
    let batteryLevelAfter: Float?
}

struct LocalAIEvaluationReceipt: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let runID: String
    let recordedAt: Date
    let corpusSHA256: String
    let modelID: String
    let modelSHA256: String
    let immutableRevision: String
    let executionConfiguration: String
    let deviceIdentifier: String
    let operatingSystem: String
    let isPhysicalDevice: Bool
    let passedCaseCount: Int
    let totalCaseCount: Int
    let score: Double
    let cases: [LocalAIEvaluationCaseReceipt]
}

actor LocalAIEvaluationReceiptStore {
    static let shared = LocalAIEvaluationReceiptStore()

    private let directoryURL: URL

    init(directoryURL: URL? = nil) {
        if let directoryURL {
            self.directoryURL = directoryURL
        } else {
            let base = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
            self.directoryURL = base
                .appendingPathComponent("LocalAI", isDirectory: true)
                .appendingPathComponent("EvaluationReceipts", isDirectory: true)
        }
    }

    func save(_ receipt: LocalAIEvaluationReceipt) throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(receipt)
        try data.write(
            to: directoryURL.appendingPathComponent("\(receipt.id.uuidString).json"),
            options: .atomic
        )
        try data.write(
            to: directoryURL.appendingPathComponent("latest.json"),
            options: .atomic
        )
    }

    func latest() throws -> LocalAIEvaluationReceipt? {
        let url = directoryURL.appendingPathComponent("latest.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try LocalModelReceiptMigration.migrate(
            decoder.decode(
                LocalAIEvaluationReceipt.self,
                from: Data(contentsOf: url)
            )
        )
    }
}

private actor LocalAIEvaluationStreamCapture {
    private let startedAt = Date()
    private var firstTextAt: Date?
    private var output = ""
    private var generatedTokens: UInt64?
    private var peakFootprint = LocalBenchmarkEvidence.physicalFootprintBytes()

    func record(_ event: AgentLocalModelInferenceEvent) {
        if let footprint = LocalBenchmarkEvidence.physicalFootprintBytes() {
            peakFootprint = max(peakFootprint ?? 0, footprint)
        }
        switch event {
        case .text(let text):
            if firstTextAt == nil, !text.isEmpty { firstTextAt = Date() }
            output += text
        case .usage(let count):
            generatedTokens = count
        case .completed:
            break
        }
    }

    func snapshot() -> (
        output: String,
        tokens: UInt64?,
        ttft: TimeInterval?,
        total: TimeInterval,
        peak: UInt64?
    ) {
        let finished = Date()
        return (
            output,
            generatedTokens,
            firstTextAt?.timeIntervalSince(startedAt),
            finished.timeIntervalSince(startedAt),
            peakFootprint
        )
    }
}

actor LocalAIEvaluationRunner {
    static let shared = LocalAIEvaluationRunner()

    private let client: LocalModelClient
    private let store: LocalAIEvaluationReceiptStore

    init(
        client: LocalModelClient = .shared,
        store: LocalAIEvaluationReceiptStore = .shared
    ) {
        self.client = client
        self.store = store
    }

    func run(modelID: String) async throws -> LocalAIEvaluationReceipt {
        let corpus = try LocalAIEvaluationCorpus.load()
        guard let variant = LocalModelCatalog.variant(for: modelID) else {
            throw LocalModelRuntimeError.modelNotDownloaded(modelID)
        }
        try await client.verifyLocalModelArtifact(modelID: modelID)
        await client.unload()

        #if canImport(UIKit)
        let previousBatteryMonitoring = await MainActor.run {
            let previous = UIDevice.current.isBatteryMonitoringEnabled
            UIDevice.current.isBatteryMonitoringEnabled = true
            return previous
        }
        #endif

        do {
            var results: [LocalAIEvaluationCaseReceipt] = []
            for evaluationCase in corpus.cases {
                try Task.checkCancellation()
                do {
                    results.append(
                        try await runCase(evaluationCase, variant: variant)
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    results.append(
                        failedCaseReceipt(evaluationCase, error: error)
                    )
                }
            }
            let passed = results.filter(\.passed).count
            let capabilities = LocalRuntimeCapabilities.current
            #if targetEnvironment(simulator)
            let isPhysicalDevice = false
            #else
            let isPhysicalDevice = true
            #endif
            let receipt = LocalAIEvaluationReceipt(
                id: UUID(),
                runID: ProcessInfo.processInfo.arguments
                    .first(where: { $0.hasPrefix("--local-evaluation-run-id=") })
                    .map {
                        String($0.dropFirst("--local-evaluation-run-id=".count))
                    } ?? UUID().uuidString,
                recordedAt: Date(),
                corpusSHA256: LocalAIEvaluationCorpus.expectedSHA256,
                modelID: variant.id,
                modelSHA256: variant.expectedSHA256,
                immutableRevision: variant.immutableRevision,
                executionConfiguration: LocalLlamaExecutionProfile.current.rawValue,
                deviceIdentifier: capabilities.deviceIdentifier,
                operatingSystem: capabilities.osVersion,
                isPhysicalDevice: isPhysicalDevice,
                passedCaseCount: passed,
                totalCaseCount: results.count,
                score: results.isEmpty ? 0 : Double(passed) / Double(results.count),
                cases: results
            )
            try await store.save(receipt)
            #if canImport(UIKit)
            await MainActor.run {
                UIDevice.current.isBatteryMonitoringEnabled = previousBatteryMonitoring
            }
            #endif
            return receipt
        } catch {
            #if canImport(UIKit)
            await MainActor.run {
                UIDevice.current.isBatteryMonitoringEnabled = previousBatteryMonitoring
            }
            #endif
            throw error
        }
    }

    private func runCase(
        _ evaluationCase: LocalAIEvaluationCorpus.EvaluationCase,
        variant: LocalModelVariant
    ) async throws -> LocalAIEvaluationCaseReceipt {
        let thermalBefore = LocalBenchmarkEvidence.thermalStateLabel()
        let batteryBefore = await batteryLevel()
        let startedAt = Date()

        if evaluationCase.category == "tool_selection" ||
            evaluationCase.category == "tool_refusal" {
            let request = inferenceRequest(
                for: evaluationCase,
                variant: variant,
                maximumOutputTokens: min(192, variant.maxNewTokens)
            )
            let decision = try await client.decideLocalAgentTurn(
                request: request,
                completedToolCallCount: 0
            )
            _ = try LocalAgentModelGrammar.compile(decision)
            let combined = "\(decision.action) \(decision.response)"
            var reasons = scoreText(combined, evaluationCase: evaluationCase)
            if let expectedTool = evaluationCase.expectedTool {
                if decision.action != expectedTool {
                    reasons.append("Expected tool \(expectedTool), got \(decision.action).")
                }
            } else if decision.action != "respond" {
                reasons.append("Expected a safe refusal/response, got \(decision.action).")
            }
            if let available = evaluationCase.availableTools,
               decision.action != "respond",
               !available.contains(decision.action) {
                reasons.append("Selected an unavailable tool: \(decision.action).")
            }
            return LocalAIEvaluationCaseReceipt(
                id: evaluationCase.id,
                category: evaluationCase.category,
                passed: reasons.isEmpty,
                failureReasons: reasons,
                output: String(combined.prefix(4_000)),
                selectedAction: decision.action,
                generatedTokens: nil,
                timeToFirstTokenSeconds: nil,
                totalDurationSeconds: Date().timeIntervalSince(startedAt),
                decodeTokensPerSecond: nil,
                peakPhysicalFootprintBytes: LocalBenchmarkEvidence.physicalFootprintBytes(),
                thermalStateBefore: thermalBefore,
                thermalStateAfter: LocalBenchmarkEvidence.thermalStateLabel(),
                batteryLevelBefore: batteryBefore,
                batteryLevelAfter: await batteryLevel()
            )
        }

        let maximum = min(
            evaluationCase.maximumOutputTokens ??
                max(evaluationCase.minimumUsefulOutputTokens ?? 160, 160),
            variant.maxNewTokens
        )
        let request = inferenceRequest(
            for: evaluationCase,
            variant: variant,
            maximumOutputTokens: maximum
        )
        let capture = LocalAIEvaluationStreamCapture()
        try await client.stream(request: request) { event in
            await capture.record(event)
        }
        let snapshot = await capture.snapshot()
        var reasons = scoreText(snapshot.output, evaluationCase: evaluationCase)
        if snapshot.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            reasons.append("Generated output was empty.")
        }
        if let minimum = evaluationCase.minimumUsefulOutputTokens,
           Int(snapshot.tokens ?? 0) < minimum {
            reasons.append(
                "Generated \(snapshot.tokens ?? 0) tokens; expected at least \(minimum)."
            )
        }
        if let size = evaluationCase.rejectRepeatedNGramSize,
           let count = evaluationCase.rejectRepeatedNGramCount,
           Self.containsRepeatedNGram(snapshot.output, size: size, count: count) {
            reasons.append("Output repeated a \(size)-word window \(count) or more times.")
        }
        let decodeDuration = max(
            snapshot.total - (snapshot.ttft ?? snapshot.total),
            0.001
        )
        let decodeRate = snapshot.tokens.map { Double($0) / decodeDuration }
        return LocalAIEvaluationCaseReceipt(
            id: evaluationCase.id,
            category: evaluationCase.category,
            passed: reasons.isEmpty,
            failureReasons: reasons,
            output: String(snapshot.output.prefix(4_000)),
            selectedAction: nil,
            generatedTokens: snapshot.tokens,
            timeToFirstTokenSeconds: snapshot.ttft,
            totalDurationSeconds: snapshot.total,
            decodeTokensPerSecond: decodeRate,
            peakPhysicalFootprintBytes: snapshot.peak,
            thermalStateBefore: thermalBefore,
            thermalStateAfter: LocalBenchmarkEvidence.thermalStateLabel(),
            batteryLevelBefore: batteryBefore,
            batteryLevelAfter: await batteryLevel()
        )
    }

    private func failedCaseReceipt(
        _ evaluationCase: LocalAIEvaluationCorpus.EvaluationCase,
        error: any Error
    ) -> LocalAIEvaluationCaseReceipt {
        LocalAIEvaluationCaseReceipt(
            id: evaluationCase.id,
            category: evaluationCase.category,
            passed: false,
            failureReasons: ["Inference failed: \(String(describing: error))"],
            output: "",
            selectedAction: nil,
            generatedTokens: nil,
            timeToFirstTokenSeconds: nil,
            totalDurationSeconds: 0,
            decodeTokensPerSecond: nil,
            peakPhysicalFootprintBytes: LocalBenchmarkEvidence.physicalFootprintBytes(),
            thermalStateBefore: LocalBenchmarkEvidence.thermalStateLabel(),
            thermalStateAfter: LocalBenchmarkEvidence.thermalStateLabel(),
            batteryLevelBefore: nil,
            batteryLevelAfter: nil
        )
    }

    private func inferenceRequest(
        for evaluationCase: LocalAIEvaluationCorpus.EvaluationCase,
        variant: LocalModelVariant,
        maximumOutputTokens: Int
    ) -> AgentLocalModelInferenceRequest {
        var messages: [AgentLocalModelInferenceMessage] = []
        let systemParts = [
            evaluationCase.system,
            evaluationCase.context.map { "Context:\n\($0)" },
        ].compactMap { $0 }
        if !systemParts.isEmpty {
            messages.append(.init(role: .system, content: systemParts.joined(separator: "\n\n")))
        }
        for message in evaluationCase.messages ?? [] {
            let role: AgentLocalModelInferenceRole = switch message.role {
            case "system": .system
            case "developer": .developer
            case "assistant": .assistant
            default: .user
            }
            messages.append(.init(role: role, content: message.content))
        }
        if let prompt = evaluationCase.prompt {
            messages.append(.init(role: .user, content: prompt))
        }
        let requestID = "local-eval-\(evaluationCase.id)-\(UUID().uuidString)"
        return AgentLocalModelInferenceRequest(
            scope: ProviderAttemptScope(
                requestID: requestID,
                attemptID: .init(rawValue: "\(requestID):attempt:1")
            ),
            modelID: variant.id,
            messages: messages,
            temperature: 0,
            maximumOutputTokens: UInt64(max(1, maximumOutputTokens))
        )
    }

    private func scoreText(
        _ output: String,
        evaluationCase: LocalAIEvaluationCorpus.EvaluationCase
    ) -> [String] {
        var reasons: [String] = []
        let folded = output.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        for required in evaluationCase.mustContain ?? [] {
            let needle = required.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            if !folded.contains(needle) {
                reasons.append("Missing required text: \(required).")
            }
        }
        if let alternatives = evaluationCase.mustContainAny,
           !alternatives.isEmpty,
           !alternatives.contains(where: {
               folded.contains($0.folding(
                   options: [.caseInsensitive, .diacriticInsensitive],
                   locale: .current
               ))
           }) {
            reasons.append("Missing every required alternative.")
        }
        for forbidden in evaluationCase.mustNotContain ?? [] {
            let needle = forbidden.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            if folded.contains(needle) {
                reasons.append("Contained forbidden text: \(forbidden).")
            }
        }
        if let exact = evaluationCase.exactOutput,
           output.trimmingCharacters(in: .whitespacesAndNewlines) != exact {
            reasons.append("Output did not exactly match the required value.")
        }
        return reasons
    }

    private static func containsRepeatedNGram(
        _ output: String,
        size: Int,
        count: Int
    ) -> Bool {
        guard size > 0, count > 1 else { return false }
        let words = output.lowercased().split(whereSeparator: { $0.isWhitespace })
        guard words.count >= size else { return false }
        var frequencies: [String: Int] = [:]
        for index in 0...(words.count - size) {
            let key = words[index..<(index + size)].joined(separator: " ")
            frequencies[key, default: 0] += 1
            if frequencies[key, default: 0] >= count { return true }
        }
        return false
    }

    private func batteryLevel() async -> Float? {
        #if canImport(UIKit)
        return await MainActor.run {
            let value = UIDevice.current.batteryLevel
            return value >= 0 ? value : nil
        }
        #else
        return nil
        #endif
    }
}

enum LocalBenchmarkEvidence {
    static func physicalFootprintBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size /
                MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(
                to: integer_t.self,
                capacity: Int(count)
            ) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    $0,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt64(info.phys_footprint)
    }

    static func thermalStateLabel(
        _ state: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    ) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}

struct OutOfCoreStorageBenchmarkReceipt: Codable, Sendable {
    let schemaVersion: Int
    let receiptID: UUID
    let recordedAt: Date
    let modelID: String
    let storageLocation: String
    let fileBytes: UInt64
    let sampleBytes: UInt64
    let sequentialReadBytes: Int
    let uncachedSequentialMBps: Double
    let firstCachedSequentialMBps: Double
    let repeatedCachedSequentialMBps: Double
    let randomReadBytes: Int
    let randomReadCount: Int
    let randomMBps: Double
    let peakPhysicalFootprintBytes: UInt64?
    let thermalBefore: String
    let thermalAfter: String
    let cacheControls: String
}

enum OutOfCoreStorageBenchmark {
    static let receiptRelativePath =
        "LocalAI/OutOfCore/storage-benchmark-latest.json"

    static func run(
        modelID: String,
        url: URL,
        storageLocation: String
    ) throws -> OutOfCoreStorageBenchmarkReceipt {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoPermission) }
        defer { close(descriptor) }
        let attributes = try FileManager.default.attributesOfItem(
            atPath: url.path
        )
        guard let fileSize = (attributes[.size] as? NSNumber)?.uint64Value,
              fileSize > 0 else { throw CocoaError(.fileReadCorruptFile) }

        let sequentialReadBytes = 1_048_576
        let randomReadBytes = 65_536
        let randomReadCount = 256
        let sampleBytes = min(fileSize, 268_435_456)
        let thermalBefore = LocalBenchmarkEvidence.thermalStateLabel()
        var peak = LocalBenchmarkEvidence.physicalFootprintBytes()

        let uncached = try sequentialRate(
            descriptor: descriptor,
            sampleBytes: sampleBytes,
            readBytes: sequentialReadBytes,
            disableCache: true,
            peak: &peak
        )
        let firstCached = try sequentialRate(
            descriptor: descriptor,
            sampleBytes: sampleBytes,
            readBytes: sequentialReadBytes,
            disableCache: false,
            peak: &peak
        )
        let repeatedCached = try sequentialRate(
            descriptor: descriptor,
            sampleBytes: sampleBytes,
            readBytes: sequentialReadBytes,
            disableCache: false,
            peak: &peak
        )
        let random = try randomRate(
            descriptor: descriptor,
            fileBytes: fileSize,
            readBytes: randomReadBytes,
            readCount: randomReadCount,
            peak: &peak
        )
        let receipt = OutOfCoreStorageBenchmarkReceipt(
            schemaVersion: 1,
            receiptID: UUID(),
            recordedAt: Date(),
            modelID: modelID,
            storageLocation: storageLocation,
            fileBytes: fileSize,
            sampleBytes: sampleBytes,
            sequentialReadBytes: sequentialReadBytes,
            uncachedSequentialMBps: uncached,
            firstCachedSequentialMBps: firstCached,
            repeatedCachedSequentialMBps: repeatedCached,
            randomReadBytes: randomReadBytes,
            randomReadCount: randomReadCount,
            randomMBps: random,
            peakPhysicalFootprintBytes: peak,
            thermalBefore: thermalBefore,
            thermalAfter: LocalBenchmarkEvidence.thermalStateLabel(),
            cacheControls: "F_NOCACHE first pass; deterministic pread; cached repeat is labeled warm, not cold"
        )
        try write(receipt)
        return receipt
    }

    static func latest() throws -> OutOfCoreStorageBenchmarkReceipt? {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let url = base.appendingPathComponent(receiptRelativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            OutOfCoreStorageBenchmarkReceipt.self,
            from: Data(contentsOf: url)
        )
    }

    private static func sequentialRate(
        descriptor: Int32,
        sampleBytes: UInt64,
        readBytes: Int,
        disableCache: Bool,
        peak: inout UInt64?
    ) throws -> Double {
        _ = fcntl(descriptor, F_NOCACHE, disableCache ? 1 : 0)
        var buffer = [UInt8](repeating: 0, count: readBytes)
        var offset: UInt64 = 0
        let started = ContinuousClock.now
        while offset < sampleBytes {
            let length = min(readBytes, Int(sampleBytes - offset))
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                pread(
                    descriptor,
                    rawBuffer.baseAddress,
                    length,
                    off_t(offset)
                )
            }
            guard count == length else { throw CocoaError(.fileReadUnknown) }
            offset += UInt64(count)
            if offset.isMultiple(of: 16 * 1_048_576),
               let current = LocalBenchmarkEvidence.physicalFootprintBytes() {
                peak = max(peak ?? 0, current)
            }
        }
        let seconds = max(
            0.000_001,
            Double(started.duration(to: .now).components.attoseconds) / 1e18 +
                Double(started.duration(to: .now).components.seconds)
        )
        return (Double(offset) / 1_048_576) / seconds
    }

    private static func randomRate(
        descriptor: Int32,
        fileBytes: UInt64,
        readBytes: Int,
        readCount: Int,
        peak: inout UInt64?
    ) throws -> Double {
        _ = fcntl(descriptor, F_NOCACHE, 1)
        var buffer = [UInt8](repeating: 0, count: readBytes)
        var state: UInt64 = 0x4E_6F_76_61_46_6F_72_67
        let maximumOffset = max(UInt64(1), fileBytes - UInt64(readBytes))
        let started = ContinuousClock.now
        for index in 0..<readCount {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            let offset = (state % maximumOffset) & ~UInt64(4_095)
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                pread(
                    descriptor,
                    rawBuffer.baseAddress,
                    readBytes,
                    off_t(offset)
                )
            }
            guard count == readBytes else { throw CocoaError(.fileReadUnknown) }
            if index.isMultiple(of: 32),
               let current = LocalBenchmarkEvidence.physicalFootprintBytes() {
                peak = max(peak ?? 0, current)
            }
        }
        let duration = started.duration(to: .now).components
        let seconds = max(
            0.000_001,
            Double(duration.seconds) + Double(duration.attoseconds) / 1e18
        )
        return (Double(readBytes * readCount) / 1_048_576) / seconds
    }

    private static func write(
        _ receipt: OutOfCoreStorageBenchmarkReceipt
    ) throws {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let url = base.appendingPathComponent(receiptRelativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(receipt).write(to: url, options: .atomic)
    }
}

enum LocalModelRuntimeError: LocalizedError {
    case modelNotDownloaded(String)
    case runtimeUnavailable
    case engineUnavailable(LocalInferenceEngineType)
    case incompatibleDevice(String)
    case downloadFailed(String)
    case invalidCompanionEndpoint
    case companionConsentRequired
    case companionAttestationFailed(String)
    case invalidCompanionResponse
    case invalidAgentDecision
    case invalidAgentDecisionOutput(String)

    var errorDescription: String? {
        switch self {
        case .modelNotDownloaded(let name):
            "\(name) is not downloaded yet. Open Settings, choose Local, and download the model first."
        case .runtimeUnavailable:
            "The local llama.cpp runtime is not linked in this build yet."
        case .engineUnavailable(let engine):
            "The \(engine.title) engine is unavailable in this NovaForge build."
        case .incompatibleDevice(let message):
            message
        case .downloadFailed(let message):
            message
        case .invalidCompanionEndpoint:
            "Use an HTTP or HTTPS endpoint on a private LAN address or .local host. Public internet hosts are rejected."
        case .companionConsentRequired:
            "Confirm the LAN companion endpoint before NovaForge sends any prompt content."
        case .companionAttestationFailed(let message):
            "The LAN companion did not attest the pinned model: \(message)"
        case .invalidCompanionResponse:
            "The LAN companion returned an invalid or oversized response."
        case .invalidAgentDecision, .invalidAgentDecisionOutput:
            "The local model could not produce a valid constrained agent decision. Nothing was executed."
        }
    }
}

@MainActor
@Observable
final class LocalModelManager {
    var selectedVariantID = LocalModelCatalog.defaultVariant.id {
        didSet { refreshStatus() }
    }
    private(set) var status: LocalModelStatus = .checking
    private(set) var progress = LocalModelDownloadProgress(receivedBytes: 0, totalBytes: LocalModelCatalog.defaultVariant.expectedBytes)
    private(set) var downloadedBytes: Int64 = 0
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var preparationTask: Task<Void, Never>?
    #if DEBUG || targetEnvironment(simulator)
    @ObservationIgnored private var debugStatusOverride: (variantID: String, status: LocalModelStatus, receivedBytes: Int64?)?
    #endif

    var selectedVariant: LocalModelVariant {
        LocalModelCatalog.variant(for: selectedVariantID) ?? LocalModelCatalog.defaultVariant
    }

    var isDownloaded: Bool {
        if case .ready = status { return true }
        return false
    }

    var isDownloading: Bool {
        if case .downloading = status { return true }
        return false
    }

    var isPartial: Bool {
        if case .partial = status { return true }
        return false
    }

    var compatibilityMessage: String? {
        compatibilityMessage(for: selectedVariant)
    }

    init() {
        #if canImport(UIKit)
        LocalModelRuntimeLifecycle.shared.start()
        #endif
        refreshStatus()
    }

    deinit {
        downloadTask?.cancel()
        statusTask?.cancel()
        preparationTask?.cancel()
    }

    @discardableResult
    func select(_ variant: LocalModelVariant) -> Bool {
        if isDownloading && selectedVariantID != variant.id {
            return false
        }
        if selectedVariantID == variant.id {
            return true
        }
        if compatibilityMessage(for: variant) != nil {
            return false
        }
        #if canImport(UIKit)
        if selectedVariantID != variant.id {
            LocalModelRuntimeLifecycle.shared.unloadForProviderSwitch()
        }
        #endif
        #if DEBUG || targetEnvironment(simulator)
        debugStatusOverride = nil
        #endif
        preparationTask?.cancel()
        preparationTask = nil
        selectedVariantID = variant.id
        if variant.engineType == .coreAI {
            let selectedID = variant.id
            preparationTask = Task(priority: .utility) { [weak self] in
                do {
                    try await LocalModelClient.shared.prepare(
                        modelID: selectedID
                    )
                } catch is CancellationError {
                    return
                } catch {
                    // Selection remains stable; status/first request exposes
                    // the precise unavailable or missing-artifact reason.
                }
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self,
                          self.selectedVariantID == selectedID
                    else { return }
                    self.preparationTask = nil
                }
            }
        }
        return true
    }

    func refreshStatus() {
        let variant = selectedVariant
        if isDownloading { return }

        #if DEBUG || targetEnvironment(simulator)
        if let debugStatusOverride, debugStatusOverride.variantID == variant.id {
            statusTask?.cancel()
            statusTask = nil
            applyDebugStatusOverride(debugStatusOverride, for: variant)
            return
        }
        #endif

        statusTask?.cancel()
        progress = .init(receivedBytes: 0, totalBytes: variant.expectedBytes)
        status = .checking

        statusTask = Task(priority: .utility) { [weak self, variant] in
            let result = await Task.detached(priority: .utility) {
                await LocalModelStatusProbe.probe(variant: variant)
            }.value
            await MainActor.run {
                guard let self, self.selectedVariantID == variant.id, !Task.isCancelled else { return }
                self.downloadedBytes = result.downloadedBytes
                self.progress = result.progress
                self.status = result.status
                self.statusTask = nil
            }
        }
    }

    func downloadSelected() {
        let variant = selectedVariant
        guard !isDownloading else { return }
        guard variant.isDownloadable else {
            refreshStatus()
            return
        }
        if let message = compatibilityMessage(for: variant) {
            status = .incompatible(message)
            return
        }

        #if DEBUG || targetEnvironment(simulator)
        debugStatusOverride = nil
        #endif
        status = .downloading
        let existingBytes = (try? LocalModelCatalog.fileURL(for: variant))
            .flatMap { fileSize(at: LocalModelDownloader.temporaryURL(for: $0)) }
            ?? 0
        downloadedBytes = existingBytes
        progress = .init(receivedBytes: existingBytes, totalBytes: variant.expectedBytes)
        downloadTask?.cancel()
        downloadTask = Task(priority: .utility) { [weak self, variant] in
            do {
                let outputURL = try LocalModelCatalog.fileURL(for: variant)
                try await LocalModelDownloader.download(variant: variant, destination: outputURL) { progress in
                    await MainActor.run {
                        guard self?.selectedVariantID == variant.id else { return }
                        self?.progress = progress
                        self?.downloadedBytes = progress.receivedBytes
                    }
                }
                await MainActor.run {
                    guard self?.selectedVariantID == variant.id else {
                        self?.downloadTask = nil
                        return
                    }
                    self?.downloadedBytes = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber)?.int64Value ?? variant.expectedBytes
                    self?.status = .ready
                    self?.downloadTask = nil
                }
            } catch is CancellationError {
                await MainActor.run {
                    self?.downloadTask = nil
                    self?.refreshStatus()
                }
            } catch {
                await MainActor.run {
                    self?.downloadTask = nil
                    self?.refreshStatus()
                    if case .partial = self?.status {
                        return
                    }
                    self?.status = .failed(error.localizedDescription)
                }
            }
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        refreshStatus()
    }

    func verifySelected() {
        let variant = selectedVariant
        guard !isDownloading else { return }
        statusTask?.cancel()
        status = .checking
        statusTask = Task(priority: .utility) { [weak self, variant] in
            do {
                try await LocalModelClient.shared.verifyLocalModelArtifact(
                    modelID: variant.id
                )
                await MainActor.run {
                    guard let self,
                          self.selectedVariantID == variant.id else { return }
                    self.status = .ready
                    self.statusTask = nil
                }
            } catch {
                await MainActor.run {
                    guard let self,
                          self.selectedVariantID == variant.id else { return }
                    self.status = .failed(error.localizedDescription)
                    self.statusTask = nil
                }
            }
        }
    }

    func unloadSelected() {
        let variantID = selectedVariant.id
        Task {
            await LocalModelClient.shared.unload(modelID: variantID)
            guard selectedVariantID == variantID else { return }
            refreshStatus()
        }
    }

    #if DEBUG || targetEnvironment(simulator)
    func debugOverrideStatusForUITest(_ status: LocalModelStatus, receivedBytes: Int64? = nil) {
        downloadTask?.cancel()
        statusTask?.cancel()
        downloadTask = nil
        statusTask = nil
        let override = (variantID: selectedVariant.id, status: status, receivedBytes: receivedBytes)
        debugStatusOverride = override
        applyDebugStatusOverride(override, for: selectedVariant)
    }

    private func applyDebugStatusOverride(
        _ override: (variantID: String, status: LocalModelStatus, receivedBytes: Int64?),
        for variant: LocalModelVariant
    ) {
        guard override.variantID == variant.id else { return }
        let bytes = override.receivedBytes ?? variant.expectedBytes
        downloadedBytes = bytes
        progress = .init(receivedBytes: bytes, totalBytes: variant.expectedBytes)
        status = override.status
    }
    #endif

    func deleteSelectedModel() {
        let variant = selectedVariant
        guard variant.isDownloadable else {
            refreshStatus()
            return
        }
        downloadTask?.cancel()
        statusTask?.cancel()
        #if DEBUG || targetEnvironment(simulator)
        debugStatusOverride = nil
        #endif
        status = .checking
        Task(priority: .utility) { [weak self, variant] in
            await LocalModelClient.shared.unload(modelID: variant.id)
            let deleteError = await Task.detached(priority: .utility) { () -> String? in
                do {
                    let url = try LocalModelCatalog.fileURL(for: variant)
                    if FileManager.default.fileExists(atPath: url.path) {
                        try FileManager.default.removeItem(at: url)
                    }
                    let partialURL = LocalModelDownloader.temporaryURL(for: url)
                    if FileManager.default.fileExists(atPath: partialURL.path) {
                        try FileManager.default.removeItem(at: partialURL)
                    }
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            await LocalModelArtifactVerifier.shared.invalidate(
                variantID: variant.id
            )
            await MainActor.run {
                guard self?.selectedVariantID == variant.id else { return }
                if let deleteError {
                    self?.status = .failed("Could not delete \(variant.shortName): \(deleteError)")
                } else {
                    self?.refreshStatus()
                }
            }
        }
    }

    func localFileURL(
        for variant: LocalModelVariant? = nil
    ) async throws -> URL {
        let variant = variant ?? selectedVariant
        guard variant.isDownloadable else {
            throw LocalModelRuntimeError.modelNotDownloaded(variant.displayName)
        }
        return try await LocalModelArtifactVerifier.shared.verifiedURL(
            for: variant
        )
    }

    var companionEndpointText: String {
        CompanionModelConfigurationStore.snapshot()?.endpoint.absoluteString ?? ""
    }

    var isCompanionConfirmed: Bool {
        CompanionModelConfigurationStore.snapshot() != nil
    }

    func confirmCompanion(endpointText: String) throws {
        guard let descriptor = LocalModelCatalog.all.first(where: {
            $0.engineType == .companion
        }) else { throw LocalModelRuntimeError.invalidCompanionEndpoint }
        try CompanionModelConfigurationStore.saveConfirmed(
            endpointText: endpointText,
            descriptor: descriptor
        )
        if selectedVariantID == descriptor.id { refreshStatus() }
    }

    func revokeCompanion() {
        CompanionModelConfigurationStore.revoke()
        if selectedVariant.engineType == .companion { refreshStatus() }
        Task { await LocalModelClient.shared.unload() }
    }

    private func compatibilityMessage(for variant: LocalModelVariant) -> String? {
        if let message = LocalModelCatalog.compatibilityMessage(for: variant) {
            return message
        }

        if LocalModelCatalog.isPowerOnDeviceAdmissionExperiment(variant) {
            return nil
        }

        if let available = availableDiskBytes(), available < variant.recommendedFreeDiskBytes {
            let needed = ByteCountFormatter.string(fromByteCount: variant.recommendedFreeDiskBytes, countStyle: .file)
            let current = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
            return "Free up storage before downloading. \(variant.shortName) wants about \(needed) free; this device reports \(current)."
        }

        return nil
    }

    private func availableDiskBytes() -> Int64? {
        do {
            let directory = try LocalModelCatalog.modelDirectory()
            let values = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            return values.volumeAvailableCapacityForImportantUsage.map { Int64($0) }
        } catch {
            return nil
        }
    }

    private func fileSize(at url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }
}

private struct LocalModelStatusProbeResult: Sendable {
    let status: LocalModelStatus
    let progress: LocalModelDownloadProgress
    let downloadedBytes: Int64
}

private enum LocalModelStatusProbe {
    static func probe(
        variant: LocalModelVariant
    ) async -> LocalModelStatusProbeResult {
        let emptyProgress = LocalModelDownloadProgress(receivedBytes: 0, totalBytes: variant.expectedBytes)
        if let message = compatibilityMessage(for: variant) {
            return .init(status: .incompatible(message), progress: emptyProgress, downloadedBytes: 0)
        }

        if variant.engineType == .companion {
            return .init(
                status: .ready,
                progress: .init(receivedBytes: 0, totalBytes: 0),
                downloadedBytes: 0
            )
        }

        if variant.engineType == .coreAI {
            return .init(
                status: CoreAIModelAssetResolver.resourcesURL(for: variant) == nil
                    ? .incompatible("The pinned Core AI AOT resource bundle is not installed in this build.")
                    : .ready,
                progress: .init(receivedBytes: 0, totalBytes: 0),
                downloadedBytes: 0
            )
        }

        do {
            let url = try LocalModelCatalog.fileURL(for: variant)
            let partialURL = LocalModelDownloader.temporaryURL(for: url)
            if let size = fileSize(at: url),
               size == LocalModelDownloader.minimumCompleteBytes(for: variant)
            {
                _ = try await LocalModelArtifactVerifier.shared.verifiedURL(
                    for: variant
                )
                return .init(
                    status: .ready,
                    progress: .init(receivedBytes: size, totalBytes: max(size, variant.expectedBytes)),
                    downloadedBytes: size
                )
            } else if fileSize(at: url) != nil {
                let preservedSize = LocalModelDownloader.preserveLargestPartialDownload(finalURL: url, partialURL: partialURL)
                if preservedSize > 0 {
                    return .init(
                        status: .partial,
                        progress: .init(receivedBytes: preservedSize, totalBytes: variant.expectedBytes),
                        downloadedBytes: preservedSize
                    )
                }
            } else if let partialSize = fileSize(at: partialURL), partialSize > 0 {
                return .init(
                    status: .partial,
                    progress: .init(receivedBytes: partialSize, totalBytes: variant.expectedBytes),
                    downloadedBytes: partialSize
                )
            }
            return .init(status: .missing, progress: emptyProgress, downloadedBytes: 0)
        } catch {
            return .init(status: .failed(error.localizedDescription), progress: emptyProgress, downloadedBytes: 0)
        }
    }

    private static func compatibilityMessage(for variant: LocalModelVariant) -> String? {
        if let message = LocalModelCatalog.compatibilityMessage(for: variant) { return message }
        if let available = availableDiskBytes(), available < variant.recommendedFreeDiskBytes {
            let needed = ByteCountFormatter.string(fromByteCount: variant.recommendedFreeDiskBytes, countStyle: .file)
            let current = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
            return "Free up storage before downloading. \(variant.shortName) wants about \(needed) free; this device reports \(current)."
        }
        return nil
    }

    private static func availableDiskBytes() -> Int64? {
        do {
            let directory = try LocalModelCatalog.modelDirectory()
            let values = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            return values.volumeAvailableCapacityForImportantUsage.map { Int64($0) }
        } catch {
            return nil
        }
    }

    private static func fileSize(at url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }
}

enum LocalModelDownloader {
    enum PartialPreparation: Equatable, Sendable {
        case promoted(receivedBytes: Int64)
        case resume(startingBytes: Int64)
    }

    static func temporaryURL(for destination: URL) -> URL {
        destination.appendingPathExtension("download")
    }

    static func minimumCompleteBytes(for variant: LocalModelVariant) -> Int64 {
        variant.expectedBytes
    }

    static func preserveLargestPartialDownload(finalURL: URL, partialURL: URL) -> Int64 {
        let finalSize = fileSize(at: finalURL)
        let partialSize = fileSize(at: partialURL)

        guard finalSize > 0 else {
            return partialSize
        }

        guard finalSize > partialSize else {
            try? FileManager.default.removeItem(at: finalURL)
            return partialSize
        }

        try? FileManager.default.removeItem(at: partialURL)
        do {
            try FileManager.default.moveItem(at: finalURL, to: partialURL)
            return finalSize
        } catch {
            return max(fileSize(at: partialURL), fileSize(at: finalURL), finalSize)
        }
    }

    static func download(
        variant: LocalModelVariant,
        destination: URL,
        progress: @escaping @Sendable (LocalModelDownloadProgress) async -> Void
    ) async throws {
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporaryURL = temporaryURL(for: destination)
        let preparation = try await prepareExistingPartial(
            variant: variant,
            destination: destination
        )
        let startingBytes: Int64
        switch preparation {
        case let .promoted(receivedBytes):
            await progress(.init(
                receivedBytes: receivedBytes,
                totalBytes: variant.expectedBytes
            ))
            return
        case let .resume(bytes):
            startingBytes = bytes
        }

        var request = URLRequest(url: variant.downloadURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if startingBytes > 0 {
            request.setValue("bytes=\(startingBytes)-", forHTTPHeaderField: "Range")
        }

        let transfer = LocalModelDownloadTransfer(
            request: request,
            partialURL: temporaryURL,
            startingBytes: startingBytes,
            expectedBytes: variant.expectedBytes,
            progress: progress
        )
        let totalBytes = try await withTaskCancellationHandler {
            try await transfer.start()
        } onCancel: {
            transfer.cancel()
        }
        try Task.checkCancellation()
        let received = fileSize(at: temporaryURL)
        await progress(.init(receivedBytes: received, totalBytes: max(received, totalBytes)))

        if totalBytes > 0, received < totalBytes {
            throw LocalModelRuntimeError.downloadFailed("Download stopped early at \(ByteCountFormatter.string(fromByteCount: received, countStyle: .file)). Tap Resume to continue.")
        }

        try validateCompleteDownload(variant: variant, receivedBytes: received)
        try validateSHA256(variant: variant, fileURL: temporaryURL)

        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        await LocalModelArtifactVerifier.shared.recordVerified(
            variant: variant,
            fileURL: destination
        )
        await progress(.init(receivedBytes: received, totalBytes: max(received, totalBytes)))
    }

    /// Resolves the crash-at-100% edge before issuing any network request. A
    /// complete verified partial is promoted immediately. A same-size corrupt
    /// partial is discarded and restarted from byte zero; cancellation never
    /// deletes resumable data.
    static func prepareExistingPartial(
        variant: LocalModelVariant,
        destination: URL
    ) async throws -> PartialPreparation {
        let partialURL = temporaryURL(for: destination)
        let existingBytes = fileSize(at: partialURL)
        guard existingBytes > 0 else {
            return .resume(startingBytes: 0)
        }
        guard existingBytes <= variant.expectedBytes else {
            try FileManager.default.removeItem(at: partialURL)
            return .resume(startingBytes: 0)
        }
        guard existingBytes == variant.expectedBytes else {
            return .resume(startingBytes: existingBytes)
        }

        do {
            try validateSHA256(variant: variant, fileURL: partialURL)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as LocalModelRuntimeError {
            guard case .downloadFailed = error else { throw error }
            try FileManager.default.removeItem(at: partialURL)
            await LocalModelArtifactVerifier.shared.invalidate(
                variantID: variant.id
            )
            return .resume(startingBytes: 0)
        }

        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partialURL, to: destination)
        await LocalModelArtifactVerifier.shared.recordVerified(
            variant: variant,
            fileURL: destination
        )
        return .promoted(receivedBytes: existingBytes)
    }

    static func validateCompleteDownload(variant: LocalModelVariant, receivedBytes: Int64) throws {
        let expectedBytes = variant.expectedBytes
        guard receivedBytes == expectedBytes else {
            let receivedLabel = ByteCountFormatter.string(fromByteCount: receivedBytes, countStyle: .file)
            let expectedLabel = ByteCountFormatter.string(fromByteCount: expectedBytes, countStyle: .file)
            throw LocalModelRuntimeError.downloadFailed("\(variant.shortName) is incomplete (\(receivedLabel) of \(expectedLabel)). Tap Resume to continue.")
        }
    }

    static func validateSHA256(
        variant: LocalModelVariant,
        fileURL: URL
    ) throws {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: 4 * 1_024 * 1_024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == variant.expectedSHA256 else {
            throw LocalModelRuntimeError.downloadFailed(
                "\(variant.shortName) did not pass its integrity check. Delete the download and try again."
            )
        }
    }

    private static func fileSize(at url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }
}

/// Process-wide proof that the bytes loaded by llama.cpp match the catalog's
/// immutable digest. The fingerprint cache prevents re-hashing a 1+ GB model
/// on every provider turn while still invalidating when the file changes.
actor LocalModelArtifactVerifier {
    static let shared = LocalModelArtifactVerifier()

    private struct Fingerprint: Equatable, Sendable {
        let byteCount: Int64
        let modificationTime: TimeInterval
    }

    private var verified: [String: Fingerprint] = [:]
    private var inFlight: [String: Task<(URL, Fingerprint), any Error>] = [:]

    func verifiedURL(for variant: LocalModelVariant) async throws -> URL {
        let fileURL = try LocalModelCatalog.fileURL(for: variant)
        let fingerprint = try Self.fingerprint(
            fileURL: fileURL,
            variant: variant
        )
        if verified[variant.id] == fingerprint {
            return fileURL
        }
        if let task = inFlight[variant.id] {
            let (url, observed) = try await task.value
            verified[variant.id] = observed
            return url
        }

        let task = Task.detached(priority: .utility) {
            try LocalModelDownloader.validateSHA256(
                variant: variant,
                fileURL: fileURL
            )
            let after = try Self.fingerprint(
                fileURL: fileURL,
                variant: variant
            )
            guard after == fingerprint else {
                throw LocalModelRuntimeError.downloadFailed(
                    "\(variant.shortName) changed during its integrity check. Try again."
                )
            }
            return (fileURL, after)
        }
        inFlight[variant.id] = task
        do {
            let (url, observed) = try await task.value
            inFlight[variant.id] = nil
            verified[variant.id] = observed
            return url
        } catch {
            inFlight[variant.id] = nil
            verified[variant.id] = nil
            throw error
        }
    }

    func recordVerified(variant: LocalModelVariant, fileURL: URL) {
        guard let fingerprint = try? Self.fingerprint(
            fileURL: fileURL,
            variant: variant
        ) else {
            verified[variant.id] = nil
            return
        }
        verified[variant.id] = fingerprint
    }

    func invalidate(variantID: String) {
        inFlight[variantID]?.cancel()
        inFlight[variantID] = nil
        verified[variantID] = nil
    }

    private static func fingerprint(
        fileURL: URL,
        variant: LocalModelVariant
    ) throws -> Fingerprint {
        let values = try fileURL.resourceValues(forKeys: [
            .contentModificationDateKey,
            .fileSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              Int64(values.fileSize ?? 0) == variant.expectedBytes,
              let modified = values.contentModificationDate else {
            throw LocalModelRuntimeError.modelNotDownloaded(
                variant.displayName
            )
        }
        return Fingerprint(
            byteCount: variant.expectedBytes,
            modificationTime: modified.timeIntervalSinceReferenceDate
        )
    }
}

/// A single resumable transfer. URLSession delivers bounded Data chunks on a
/// private serial delegate queue, so the model is persisted incrementally and
/// cancellation leaves a usable `.download` file instead of losing a 1+ GB
/// temporary system download.
private final class LocalModelDownloadTransfer: NSObject, URLSessionDataDelegate,
    URLSessionTaskDelegate, @unchecked Sendable
{
    private let request: URLRequest
    private let partialURL: URL
    private let initialStartingBytes: Int64
    private let expectedBytes: Int64
    private let progress: @Sendable (LocalModelDownloadProgress) async -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Int64, any Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var handle: FileHandle?
    private var receivedBytes: Int64
    private var totalBytes: Int64
    private var lastReportedBytes: Int64
    private var didFinish = false

    init(
        request: URLRequest,
        partialURL: URL,
        startingBytes: Int64,
        expectedBytes: Int64,
        progress: @escaping @Sendable (LocalModelDownloadProgress) async -> Void
    ) {
        self.request = request
        self.partialURL = partialURL
        initialStartingBytes = startingBytes
        self.expectedBytes = expectedBytes
        self.progress = progress
        receivedBytes = startingBytes
        totalBytes = expectedBytes
        lastReportedBytes = startingBytes
    }

    func start() async throws -> Int64 {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            guard !didFinish else {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return
            }
            self.continuation = continuation
            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.timeoutIntervalForRequest = 120
            configuration.timeoutIntervalForResource = 60 * 60 * 4
            configuration.waitsForConnectivity = true
            let session = URLSession(
                configuration: configuration,
                delegate: self,
                delegateQueue: Self.serialDelegateQueue()
            )
            let task = session.dataTask(with: request)
            self.session = session
            self.task = task
            lock.unlock()
            task.resume()
        }
    }

    func cancel() {
        lock.lock()
        task?.cancel()
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        do {
            guard let http = response as? HTTPURLResponse,
                  (200 ..< 300).contains(http.statusCode)
            else {
                throw LocalModelRuntimeError.downloadFailed(
                    "The local model host returned an invalid response."
                )
            }

            let resumesExisting = initialStartingBytes > 0 && http.statusCode == 206
            if resumesExisting {
                guard Self.contentRangeStart(http) == initialStartingBytes else {
                    throw LocalModelRuntimeError.downloadFailed(
                        "The model host returned an invalid resume range. Tap Resume to retry."
                    )
                }
            } else {
                try? FileManager.default.removeItem(at: partialURL)
                receivedBytes = 0
                lastReportedBytes = 0
            }

            if !FileManager.default.fileExists(atPath: partialURL.path) {
                guard FileManager.default.createFile(
                    atPath: partialURL.path,
                    contents: nil
                ) else {
                    throw LocalModelRuntimeError.downloadFailed(
                        "NovaForge could not create the local model download file."
                    )
                }
            }
            let handle = try FileHandle(forWritingTo: partialURL)
            try handle.seekToEnd()
            self.handle = handle
            totalBytes = Self.totalBytes(
                from: http,
                startingBytes: receivedBytes,
                fallback: expectedBytes
            )
            completionHandler(.allow)
        } catch {
            completionHandler(.cancel)
            finish(throwing: error)
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        do {
            try handle?.write(contentsOf: data)
            receivedBytes += Int64(data.count)
            if receivedBytes - lastReportedBytes >= 1_024 * 1_024 ||
                receivedBytes >= totalBytes
            {
                lastReportedBytes = receivedBytes
                let snapshot = LocalModelDownloadProgress(
                    receivedBytes: receivedBytes,
                    totalBytes: max(totalBytes, receivedBytes)
                )
                Task(priority: .utility) { [progress] in
                    await progress(snapshot)
                }
            }
        } catch {
            dataTask.cancel()
            finish(throwing: error)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        if let error {
            if (error as? URLError)?.code == .cancelled {
                finish(throwing: CancellationError())
            } else {
                finish(throwing: error)
            }
        } else {
            finish(returning: totalBytes)
        }
    }

    private func finish(returning value: Int64) {
        finish(.success(value))
    }

    private func finish(throwing error: any Error) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<Int64, any Error>) {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        didFinish = true
        let continuation = continuation
        self.continuation = nil
        let session = session
        self.session = nil
        self.task = nil
        lock.unlock()

        try? handle?.synchronize()
        try? handle?.close()
        handle = nil
        session?.finishTasksAndInvalidate()
        continuation?.resume(with: result)
    }

    private static func serialDelegateQueue() -> OperationQueue {
        let queue = OperationQueue()
        queue.name = "com.joey.NovaForge.local-model-download"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return queue
    }

    private static func contentRangeStart(_ response: HTTPURLResponse) -> Int64? {
        guard let value = response.value(forHTTPHeaderField: "Content-Range"),
              let rangePart = value.split(separator: " ").last?.split(separator: "/").first,
              let startPart = rangePart.split(separator: "-").first
        else { return nil }
        return Int64(startPart)
    }

    private static func totalBytes(
        from response: HTTPURLResponse,
        startingBytes: Int64,
        fallback: Int64
    ) -> Int64 {
        if let contentRange = response.value(forHTTPHeaderField: "Content-Range"),
           let totalText = contentRange.split(separator: "/").last,
           let total = Int64(totalText) {
            return total
        }
        if response.expectedContentLength > 0 {
            return response.expectedContentLength + startingBytes
        }
        return fallback
    }
}

/// A single process-wide generation lease prevents two workspaces from
/// loading or driving llama.cpp concurrently on memory-constrained phones.
/// Waiting is cancellation-aware and does not cancel the current owner's run.
private actor LocalModelInferenceGate {
    static let shared = LocalModelInferenceGate()
    private var isHeld = false

    func acquire() async throws {
        while isHeld {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(50))
        }
        isHeld = true
    }

    func release() {
        isHeld = false
    }
}

/// A task-local marker lets the router hold the one process-wide generation
/// lease while it unloads the previous engine. Concrete engines reuse that
/// ownership, while direct test/service calls still acquire the same gate.
private enum LocalInferenceLeaseContext {
    @TaskLocal static var ownsProcessLease = false

    static func withLease<T>(
        _ operation: () async throws -> T,
        isolation: isolated (any Actor)? = #isolation
    ) async throws -> T {
        if ownsProcessLease {
            return try await operation()
        }
        try await LocalModelInferenceGate.shared.acquire()
        do {
            let result = try await $ownsProcessLease.withValue(
                true,
                operation: operation,
                isolation: isolation
            )
            await LocalModelInferenceGate.shared.release()
            return result
        } catch {
            await LocalModelInferenceGate.shared.release()
            throw error
        }
    }
}

private actor LocalStreamAccumulator {
    private var storage = ""

    func append(_ text: String) {
        storage += text
    }

    var value: String { storage }
}

protocol LocalInferenceEngine: AgentLocalModelInferenceStreaming,
    AgentLocalModelActionPlanning,
    AgentLocalModelArtifactVerifying
{
    var engineType: LocalInferenceEngineType { get }
    func unload(modelID: String?) async
}

/// Optional cold-load hook. Preparing is separate from chat so an AOT/Core AI
/// asset can be specialized without freezing the first streamed turn.
protocol LocalInferencePreparing: Sendable {
    func prepare(modelID: String) async throws
}

actor LlamaCppInferenceEngine: LocalInferenceEngine,
    AgentLocalModelActionPlanning,
    AgentLocalModelArtifactVerifying
{
    static let shared = LlamaCppInferenceEngine()
    nonisolated let engineType = LocalInferenceEngineType.llamaCpp

    #if canImport(SwiftLlama)
    private var loadedService: (variantID: String, service: LlamaService)?
    #endif

    func stop(model: String) async {
        #if canImport(SwiftLlama)
        let variant = LocalModelCatalog.variant(for: model) ?? LocalModelCatalog.defaultVariant
        if loadedService?.variantID == variant.id,
           let service = loadedService?.service {
            await service.stopCompletion()
        }
        #endif
    }

    func unload(modelID: String? = nil) async {
        #if canImport(SwiftLlama)
        guard let loadedService,
              modelID == nil || loadedService.variantID == modelID else { return }
        await loadedService.service.stopCompletion()
        self.loadedService = nil
        #endif
    }

    #if canImport(SwiftLlama)
    private func service(
        for variant: LocalModelVariant,
        modelURL: URL
    ) async throws -> LlamaService {
        if let loadedService, loadedService.variantID == variant.id {
            if let message = LocalModelRuntimeMemoryPolicy.admissionMessage(
                for: variant,
                availableMemory: nil
            ) {
                await unload(modelID: variant.id)
                throw LocalModelRuntimeError.incompatibleDevice(message)
            }
            return loadedService.service
        }

        await unload()
        try await Task.sleep(for: .milliseconds(80))
        if let message = LocalModelRuntimeMemoryPolicy.admissionMessage(for: variant) {
            throw LocalModelRuntimeError.incompatibleDevice(message)
        }

        let plan = LocalRuntimeExecutionPlan.resolve(for: variant)
        let service = LlamaService(
            modelUrl: modelURL,
            config: .init(
                batchSize: plan.batchTokens,
                maxTokenCount: plan.contextTokens,
                useGPU: plan.useGPU,
                gpuLayerCount: plan.gpuLayerCount,
                generationThreadCount: variant.generationThreadCount,
                batchThreadCount: variant.batchThreadCount,
                yieldEveryTokenCount: 1,
                maxOutputTokenCount: UInt32(clamping: variant.maxNewTokens),
                reducedMemoryMode: plan.reducedMemoryMode,
                kvCacheType: plan.reducedMemoryMode ? .q8_0 : .f16,
                flashAttention: plan.useGPU && !plan.reducedMemoryMode,
                outOfCoreResidentBudgetBytes:
                    LocalModelCatalog.powerOnDeviceExperimentIDs.contains(
                        variant.id
                    )
                    ? 1_500_000_000
                    : 0
            )
        )
        loadedService = (variant.id, service)
        return service
    }
    #endif

    func verifyLocalModelArtifact(modelID: String) async throws {
        guard let variant = LocalModelCatalog.variant(for: modelID) else {
            throw LocalModelRuntimeError.modelNotDownloaded(modelID)
        }
        _ = try await LocalModelArtifactVerifier.shared.verifiedURL(
            for: variant
        )
    }

    /// Runs the tool-trained checkpoint behind the exact GBNF bound into
    /// `LocalToolsAuthority`. The model may choose one action, but it cannot
    /// invent a tool name or argument shape; the transport validates the
    /// decoded decision again before publishing a canonical tool call.
    func decideLocalAgentTurn(
        request: AgentLocalModelInferenceRequest,
        completedToolCallCount: Int
    ) async throws -> LocalAgentModelDecision {
        try await LocalInferenceLeaseContext.withLease {
            try await performLocalAgentDecision(
                request: request,
                completedToolCallCount: completedToolCallCount
            )
        }
    }

    private func performLocalAgentDecision(
        request: AgentLocalModelInferenceRequest,
        completedToolCallCount: Int
    ) async throws -> LocalAgentModelDecision {
        guard let variant = LocalModelCatalog.variant(for: request.modelID),
              completedToolCallCount >= 0,
              completedToolCallCount <
                LocalAgentModelGrammar.maximumModelPlannedToolCalls
        else { throw LocalModelRuntimeError.invalidAgentDecision }
        guard variant.toolCallingSupport !=
            "disabled until the full physical quality and safety corpus passes"
        else {
            throw LocalModelRuntimeError.invalidAgentDecision
        }
        if let message = LocalModelCatalog.compatibilityMessage(for: variant) {
            throw LocalModelRuntimeError.incompatibleDevice(message)
        }

        let modelURL = try await LocalModelArtifactVerifier.shared
            .verifiedURL(for: variant)

        #if canImport(SwiftLlama)
        let service = try await service(for: variant, modelURL: modelURL)

        let latestUserIndex = request.messages.lastIndex(where: {
            $0.role == .user
        })
        let latestUser = latestUserIndex.map {
            request.messages[$0].content
        } ?? ""
        let recentContext = latestUserIndex.map { index in
            Self.boundedPlannerTranscript(
                Array(request.messages.dropFirst(index + 1))
            )
        } ?? ""
        let contextLine = recentContext.isEmpty
            ? ""
            : "\nRecent validated actions and results:\n\(recentContext)"
        let messages: [LlamaChatMessage] = [
            .init(
                role: .system,
                content: LocalAgentModelGrammar.routerPrompt
            ),
            .init(
                role: .user,
                content: "Request: \(Self.boundedPlannerText(latestUser, limit: 600))\(contextLine)\nCompleted actions: \(completedToolCallCount)"
            ),
        ]
        let sampling = LlamaSamplingConfig(
            temperature: 0,
            seed: 42,
            topP: 1,
            topK: 8,
            grammarConfig: LlamaGrammarConfig(
                grammar: LocalAgentModelGrammar.gbnf,
                grammarRoot: "root"
            ),
            repetitionPenaltyConfig: nil
        )
        let stream = try await service.streamCompletion(
            of: messages,
            samplingConfig: sampling
        )
        let decoder = JSONDecoder()
        let startedAt = ContinuousClock.now
        let maximumTokens = min(192, variant.maxNewTokens)
        var output = ""
        var tokenCount = 0

        do {
            for try await token in stream {
                try Task.checkCancellation()
                output += token
                tokenCount += 1
                if let data = output.data(using: .utf8),
                   let decision = try? decoder.decode(
                       LocalAgentModelDecision.self,
                       from: data
                   ) {
                    await service.stopCompletion()
                    return decision
                }
                if tokenCount >= maximumTokens ||
                    startedAt.duration(to: .now) >= .seconds(60)
                {
                    await service.stopCompletion()
                    break
                }
            }
        } catch is CancellationError {
            await service.stopCompletion()
            throw CancellationError()
        } catch {
            await service.stopCompletion()
            throw error
        }

        guard let data = output.data(using: .utf8),
              let decision = try? decoder.decode(
                  LocalAgentModelDecision.self,
                  from: data
              ) else {
            throw LocalModelRuntimeError.invalidAgentDecisionOutput(
                Self.boundedPlannerText(output, limit: 1_500)
            )
        }
        return decision
        #else
        throw LocalModelRuntimeError.runtimeUnavailable
        #endif
    }

    private static func boundedPlannerText(
        _ value: String,
        limit: Int
    ) -> String {
        let compact = value
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard compact.count > limit else { return compact }
        return String(compact.prefix(limit))
    }

    private static func boundedPlannerTranscript(
        _ messages: [AgentLocalModelInferenceMessage]
    ) -> String {
        var remaining = 1_100
        var lines: [String] = []
        for message in messages.suffix(6) {
            guard remaining > 0 else { break }
            let prefix = message.role == .assistant ? "assistant" : message.role.rawValue
            let available = max(0, remaining - prefix.count - 2)
            guard available > 0 else { break }
            let text = boundedPlannerText(
                message.content,
                limit: min(available, 500)
            )
            let line = "\(prefix): \(text)"
            lines.append(line)
            remaining -= line.count + 1
        }
        return lines.joined(separator: "\n")
    }

    /// Canonical V2 text stream. The existing `streamingResponse` method below
    /// remains untouched for V1 parity and rollback until the V2 route ships.
    func stream(
        request: AgentLocalModelInferenceRequest,
        onEvent: @escaping @Sendable (AgentLocalModelInferenceEvent) async throws -> Void
    ) async throws {
        try await LocalInferenceLeaseContext.withLease {
            try await performStream(request: request, onEvent: onEvent)
        }
    }

    private func performStream(
        request: AgentLocalModelInferenceRequest,
        onEvent: @escaping @Sendable (AgentLocalModelInferenceEvent) async throws -> Void
    ) async throws {
        guard let variant = LocalModelCatalog.variant(for: request.modelID),
              request.maximumOutputTokens > 0,
              request.maximumOutputTokens <= UInt64(variant.maxNewTokens),
              request.temperature.isFinite,
              (0 ... 2).contains(request.temperature),
              !request.messages.isEmpty
        else { throw LocalModelRuntimeError.runtimeUnavailable }
        if let message = LocalModelCatalog.compatibilityMessage(for: variant) {
            throw LocalModelRuntimeError.incompatibleDevice(message)
        }

        let modelURL = try await LocalModelArtifactVerifier.shared
            .verifiedURL(for: variant)

        #if canImport(SwiftLlama)
        let service = try await service(for: variant, modelURL: modelURL)

        let plan = LocalRuntimeExecutionPlan.resolve(for: variant)
        let boundedMessages = LocalInferenceInputPolicy.boundedMessages(
            request.messages,
            contextTokens: plan.contextTokens
        )
        let llamaMessages = boundedMessages.map { message in
            let role: LlamaChatMessage.Role = switch message.role {
            case .system, .developer: .system
            case .user: .user
            case .assistant: .assistant
            }
            return LlamaChatMessage(role: role, content: message.content)
        }
        let sampling = LlamaSamplingConfig(
            temperature: CFloat(request.temperature),
            seed: 42,
            topP: 0.72,
            topK: 12,
            repetitionPenaltyConfig: LlamaRepetitionPenaltyConfig(
                lastN: 48,
                repeatPenalty: 1.22,
                freqPenalty: 0.08
            )
        )
        let stream = try await service.streamCompletion(
            of: llamaMessages,
            samplingConfig: sampling
        )
        var generatedTokenCount: UInt64 = 0
        var lastChunkWasEmpty = false
        var suppressingHiddenReasoning = false
        var stoppedEarly = false
        var finishReason: AgentLocalModelInferenceFinishReason = .completed
        let generationStartedAt = ContinuousClock.now

        do {
            for try await token in stream {
                try Task.checkCancellation()
                generatedTokenCount += 1
                lastChunkWasEmpty = token.isEmpty

                if Self.isObviouslyUnstableToken(
                    token,
                    after: Int(clamping: generatedTokenCount)
                ) {
                    stoppedEarly = true
                    finishReason = .length
                    await service.stopCompletion()
                    break
                }

                let visibleToken = Self.visibleLocalToken(
                    from: token,
                    suppressingHiddenReasoning: &suppressingHiddenReasoning
                )
                if !visibleToken.isEmpty {
                    try await onEvent(.text(visibleToken))
                }

                if !token.isEmpty,
                   (generatedTokenCount >= request.maximumOutputTokens ||
                    generationStartedAt.duration(to: .now) >=
                    .seconds(variant.maxGenerationSeconds)) {
                    stoppedEarly = true
                    finishReason = .length
                    await service.stopCompletion()
                    break
                }
            }
        } catch is CancellationError {
            await service.stopCompletion()
            throw CancellationError()
        } catch {
            await service.stopCompletion()
            throw error
        }

        // SwiftLlama emits one String per generated llama token, followed by
        // one empty EOS flush. Remove only that known natural-terminal flush;
        // early stops do not receive it.
        if !stoppedEarly, lastChunkWasEmpty, generatedTokenCount > 0 {
            generatedTokenCount -= 1
        }
        try Task.checkCancellation()
        try await onEvent(.usage(generatedTokenCount: generatedTokenCount))
        try await onEvent(.completed(reason: finishReason))
        #else
        throw LocalModelRuntimeError.runtimeUnavailable
        #endif
    }

    func stop(request: AgentLocalModelInferenceRequest) async {
        await stop(model: request.modelID)
    }

    func streamingResponse(
        messages: [ProviderMessageInput],
        model: String,
        temperature: Double,
        customSystemPrompt: String?,
        workspaceSummary: String,
        onContentBatch: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> ProviderResponse {
        try await LocalInferenceLeaseContext.withLease {
            try await performStreamingResponse(
                messages: messages,
                model: model,
                temperature: temperature,
                customSystemPrompt: customSystemPrompt,
                workspaceSummary: workspaceSummary,
                onContentBatch: onContentBatch
            )
        }
    }

    private func performStreamingResponse(
        messages: [ProviderMessageInput],
        model: String,
        temperature: Double,
        customSystemPrompt: String?,
        workspaceSummary: String,
        onContentBatch: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> ProviderResponse {
        let variant = LocalModelCatalog.variant(for: model) ?? LocalModelCatalog.defaultVariant
        if let message = LocalModelCatalog.compatibilityMessage(for: variant) {
            throw LocalModelRuntimeError.incompatibleDevice(message)
        }

        let modelURL = try await LocalModelArtifactVerifier.shared
            .verifiedURL(for: variant)

        #if canImport(SwiftLlama)
        let service = try await service(for: variant, modelURL: modelURL)

        let systemPrompt = localSystemPrompt(customSystemPrompt: customSystemPrompt, workspaceSummary: workspaceSummary)
        let sanitizedTranscript = ProviderMessageSanitizer.sanitize(systemPrompt: systemPrompt, history: messages)
        let llamaMessages = localMessages(from: sanitizedTranscript.messages)
        let sampling = LlamaSamplingConfig(
            temperature: 0.05,
            seed: 42,
            topP: 0.72,
            topK: 12,
            repetitionPenaltyConfig: LlamaRepetitionPenaltyConfig(lastN: 48, repeatPenalty: 1.22, freqPenalty: 0.08)
        )

        let stream = try await service.streamCompletion(of: llamaMessages, samplingConfig: sampling)
        var output = ""
        var generatedTokenCount = 0
        var pending = ""
        var suppressingHiddenReasoning = false
        var stoppedForUnstableOutput = false
        var lastDelivery = ContinuousClock.now
        let generationStartedAt = ContinuousClock.now

        do {
            for try await token in stream {
                try Task.checkCancellation()
                output += token
                generatedTokenCount += 1

                if Self.isObviouslyUnstableToken(token, after: generatedTokenCount) ||
                    (generatedTokenCount >= 4 && Self.looksLikeUnstableLiveOutput(output)) ||
                    (suppressingHiddenReasoning && generatedTokenCount >= 10 && pending.isEmpty) {
                    stoppedForUnstableOutput = true
                    pending.removeAll(keepingCapacity: true)
                    await service.stopCompletion()
                    break
                }

                let visibleToken = Self.visibleLocalToken(
                    from: token,
                    suppressingHiddenReasoning: &suppressingHiddenReasoning
                )
                if !visibleToken.isEmpty {
                    pending += visibleToken
                }

                let elapsed = lastDelivery.duration(to: .now)
                if !pending.isEmpty,
                   elapsed >= .milliseconds(180) || pending.count >= 180 || pending.contains("\n\n") {
                    await onContentBatch(pending)
                    pending.removeAll(keepingCapacity: true)
                    lastDelivery = .now
                }

                let generationElapsed = generationStartedAt.duration(to: .now)
                if generatedTokenCount >= variant.maxNewTokens ||
                    (generatedTokenCount > 0 && generationElapsed >= .seconds(variant.maxGenerationSeconds)) {
                    await service.stopCompletion()
                    break
                }
            }
        } catch is CancellationError {
            await service.stopCompletion()
            throw CancellationError()
        }

        if !pending.isEmpty {
            await onContentBatch(pending)
        }

        let cleanedOutput = stoppedForUnstableOutput
            ? "Local output became unstable, so NovaForge stopped it safely."
            : Self.cleanLocalOutput(output)
        let message = ChatCompletionsResponse.Choice.Message(
            role: "assistant",
            content: cleanedOutput.isEmpty ? nil : cleanedOutput,
            tool_calls: nil
        )
        return ProviderResponse(message: message, roleLog: sanitizedTranscript.roleLog)
        #else
        throw LocalModelRuntimeError.runtimeUnavailable
        #endif
    }

    private func localSystemPrompt(customSystemPrompt: String?, workspaceSummary: String) -> String {
        let styleNote = customSystemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        let customLine = styleNote.map { "\nStyle preference: \(String($0.prefix(140)))" } ?? ""

        return """
        You are NovaForge Local on iPhone.
        Reply in plain English, max 4 short sentences.
        Do not greet, restate the request, or narrate obvious preparation.
        No hidden reasoning. No code blocks unless asked. No XML, JSON, logs, numbered dumps, or tool-call text.
        If you are unsure, say one short helpful sentence and stop.
        Native NovaForge code handles simple local file, search, command, and artifact actions before your reply.
        You should answer only short offline questions. Do not invent tool calls or pretend to edit files yourself.
        \(customLine)

        Workspace files:
        \(workspaceSummary)
        """
    }

    #if canImport(SwiftLlama)
    private func localMessages(from messages: [ProviderChatMessage]) -> [LlamaChatMessage] {
        let system = messages.last(where: { $0.role == "system" })
        let latestUser = messages.last { message in
            guard message.role == "user" else { return false }
            guard let content = message.content?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else { return false }
            return !Self.isBoilerplateLocalWelcome(content)
        }

        return ([system, latestUser].compactMap { $0 }).map { message in
            switch message.role {
            case "system":
                return LlamaChatMessage(role: .system, content: message.content ?? "")
            default:
                let content = String((message.content ?? "").prefix(420))
                return LlamaChatMessage(role: .user, content: content)
            }
        }
    }
    #endif

    private func fileSize(at url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func isBoilerplateLocalWelcome(_ content: String) -> Bool {
        let lower = content.lowercased()
        return lower.contains("fresh novaforge session ready") ||
            lower.contains("novaforge is ready. existing chats") ||
            lower.contains("tell me what to build, inspect")
    }

    private static func visibleLocalToken(
        from token: String,
        suppressingHiddenReasoning: inout Bool
    ) -> String {
        var text = token
        var visible = ""

        while !text.isEmpty {
            if suppressingHiddenReasoning {
                guard let end = text.range(of: "</think>", options: .caseInsensitive) else {
                    return visible
                }
                text = String(text[end.upperBound...])
                suppressingHiddenReasoning = false
                continue
            }

            guard let start = text.range(of: "<think", options: .caseInsensitive) else {
                visible += text
                break
            }

            visible += String(text[..<start.lowerBound])
            if let end = text.range(
                of: "</think>",
                options: .caseInsensitive,
                range: start.lowerBound..<text.endIndex
            ) {
                text = String(text[end.upperBound...])
            } else {
                suppressingHiddenReasoning = true
                break
            }
        }

        for marker in ["<tool_call", "<tool_response", "Tool call:", "tool_call:"] {
            if let range = visible.range(of: marker, options: .caseInsensitive) {
                visible = String(visible[..<range.lowerBound])
            }
        }

        return visible
    }

    private static func cleanLocalOutput(_ output: String) -> String {
        var text = output

        let removalPatterns = [
            #"<think>.*?</think>"#,
            #"<tool_call>.*?</tool_call>"#,
            #"<tool_response>.*?</tool_response>"#
        ]

        for pattern in removalPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        }

        let stopMarkers = ["<tool_call", "<tool_response", "Tool call:", "tool_call:"]
        for marker in stopMarkers {
            if let range = text.range(of: marker, options: [.caseInsensitive]) {
                text = String(text[..<range.lowerBound])
            }
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if looksLikeLowQualityLocalOutput(trimmed) {
            return "Local output became unstable, so NovaForge stopped it safely."
        }

        guard !trimmed.isEmpty else {
            return "I’m ready locally. Ask a shorter prompt, or switch to a cloud agent mode for real workspace tool work."
        }
        return trimmed
    }

    private static func looksLikeUnstableLiveOutput(_ text: String) -> Bool {
        let sample = String(text.suffix(180)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard sample.count >= 24 else { return false }
        if sample.range(of: "<tool_call", options: .caseInsensitive) != nil { return true }
        if sample.range(of: "<tool_response", options: .caseInsensitive) != nil { return true }
        if sample.localizedCaseInsensitiveContains("assistantassistant") { return true }

        let scalars = sample.unicodeScalars
        let letters = scalars.filter { CharacterSet.letters.contains($0) }.count
        let digits = scalars.filter { CharacterSet.decimalDigits.contains($0) }.count
        let punctuationNoise = sample.filter { "{}[]<>\\/|=_".contains($0) }.count

        if digits >= 8, digits > max(letters, 10) { return true }
        if punctuationNoise > max(14, sample.count / 3) { return true }
        if sample.range(of: #"(?:\d[\s,.;:_-]*){8,}"#, options: .regularExpression) != nil { return true }
        return false
    }

    private static func isObviouslyUnstableToken(_ token: String, after generatedTokenCount: Int) -> Bool {
        guard generatedTokenCount >= 3 else { return false }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return false }

        let scalars = trimmed.unicodeScalars
        let letters = scalars.filter { CharacterSet.letters.contains($0) }.count
        let digits = scalars.filter { CharacterSet.decimalDigits.contains($0) }.count
        let symbolNoise = trimmed.filter { "{}[]<>\\/|=_#`".contains($0) }.count

        if letters == 0, digits >= 2 { return true }
        if symbolNoise >= 3, symbolNoise >= letters + digits { return true }
        return false
    }

    private static func looksLikeLowQualityLocalOutput(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let scalars = text.unicodeScalars
        let letters = scalars.filter { CharacterSet.letters.contains($0) }.count
        let digits = scalars.filter { CharacterSet.decimalDigits.contains($0) }.count
        let punctuationNoise = text.filter { "{}[]<>\\/|=_".contains($0) }.count

        if text.count >= 12, letters == 0 { return true }
        if digits > max(18, letters * 2) { return true }
        if punctuationNoise > max(12, text.count / 4) { return true }
        if text.localizedCaseInsensitiveContains("assistantassistant") { return true }
        return false
    }

    static func extractToolCalls(from output: String) -> (content: String, toolCalls: [APIToolCall]) {
        guard let regex = try? NSRegularExpression(
            pattern: #"<tool_call>\s*(\{.*?\})\s*</tool_call>"#,
            options: [.dotMatchesLineSeparators]
        ) else {
            return (output.trimmingCharacters(in: .whitespacesAndNewlines), [])
        }

        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        let matches = regex.matches(in: output, range: range)
        let toolCalls = matches.enumerated().compactMap { index, match -> APIToolCall? in
            guard match.numberOfRanges > 1,
                  let jsonRange = Range(match.range(at: 1), in: output) else { return nil }
            return decodeToolCallJSON(String(output[jsonRange]), index: index)
        }

        let content = regex
            .stringByReplacingMatches(in: output, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return (content, toolCalls)
    }

    private static func decodeToolCallJSON(_ json: String, index: Int) -> APIToolCall? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = object["name"] as? String else { return nil }

        guard let argumentsData = normalizedArgumentsData(from: object["arguments"]) else {
            return nil
        }

        let argumentsJSON = String(data: argumentsData, encoding: .utf8) ?? "{}"
        return APIToolCall(
            id: "local-tool-\(index)-\(UUID().uuidString.prefix(8))",
            type: "function",
            function: APIFunctionCall(name: name, arguments: argumentsJSON)
        )
    }

    private static func normalizedArgumentsData(from value: Any?) -> Data? {
        guard let value else { return nil }

        let data: Data
        if let argumentsString = value as? String {
            guard let stringData = argumentsString.data(using: .utf8),
                  let decoded = try? JSONSerialization.jsonObject(with: stringData, options: [.fragmentsAllowed]) else {
                return nil
            }
            do {
                try ToolCallArgumentValidator.validateFlatArgumentObject(
                    decoded,
                    sourceDescription: "local model response"
                )
            } catch {
                return nil
            }
            guard JSONSerialization.isValidJSONObject(decoded) else { return nil }
            data = (try? JSONSerialization.data(withJSONObject: decoded, options: [.sortedKeys])) ?? Data()
        } else {
            guard JSONSerialization.isValidJSONObject(value),
                  let objectData = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
                  let decoded = try? JSONSerialization.jsonObject(with: objectData, options: [.fragmentsAllowed]) else {
                return nil
            }
            do {
                try ToolCallArgumentValidator.validateFlatArgumentObject(
                    decoded,
                    sourceDescription: "local model response"
                )
            } catch {
                return nil
            }
            data = objectData
        }

        return data.isEmpty ? nil : data
    }
}

actor CoreAIInferenceEngine: LocalInferenceEngine, LocalInferencePreparing {
    nonisolated let engineType = LocalInferenceEngineType.coreAI
    #if os(iOS) && canImport(CoreAI) && canImport(CoreAILanguageModels) && canImport(FoundationModels)
    private var loadedModel: (id: String, model: CoreAILanguageModel)?
    private var activeSession: (
        modelID: String,
        instructions: String,
        session: LanguageModelSession,
        messages: [AgentLocalModelInferenceMessage],
        lastResponse: String
    )?
    #endif

    func prepare(modelID: String) async throws {
        #if os(iOS) && canImport(CoreAI) && canImport(CoreAILanguageModels) && canImport(FoundationModels)
        guard #available(iOS 27.0, *) else {
            throw LocalModelRuntimeError.engineUnavailable(.coreAI)
        }
        try await LocalInferenceLeaseContext.withLease {
            try await verifyLocalModelArtifact(modelID: modelID)
            guard let descriptor = LocalModelCatalog.variant(for: modelID),
                  let resourcesURL = CoreAIModelAssetResolver.resourcesURL(
                      for: descriptor
                  )
            else {
                throw LocalModelRuntimeError.modelNotDownloaded(modelID)
            }
            _ = try await loadModel(
                for: descriptor,
                resourcesURL: resourcesURL
            )
        }
        #else
        throw LocalModelRuntimeError.engineUnavailable(.coreAI)
        #endif
    }

    func verifyLocalModelArtifact(modelID: String) async throws {
        guard let descriptor = LocalModelCatalog.variant(for: modelID),
              descriptor.engineType == .coreAI else {
            throw LocalModelRuntimeError.modelNotDownloaded(modelID)
        }
        #if os(iOS)
        guard #available(iOS 27.0, *) else {
            throw LocalModelRuntimeError.engineUnavailable(.coreAI)
        }
        #endif
        guard LocalRuntimeCapabilities.current.supportsCoreAI else {
            throw LocalModelRuntimeError.engineUnavailable(.coreAI)
        }
        guard CoreAIModelAssetResolver.resourcesURL(for: descriptor) != nil else {
            throw LocalModelRuntimeError.modelNotDownloaded(descriptor.displayName)
        }
    }

    func stream(
        request: AgentLocalModelInferenceRequest,
        onEvent: @escaping @Sendable (AgentLocalModelInferenceEvent) async throws -> Void
    ) async throws {
        #if os(iOS) && canImport(CoreAI) && canImport(CoreAILanguageModels) && canImport(FoundationModels)
        try await LocalInferenceLeaseContext.withLease {
            let generatedTokens = try await generate(request: request) { text in
                try await onEvent(.text(text))
            }
            try await onEvent(.usage(generatedTokenCount: generatedTokens))
            try await onEvent(.completed(
                reason: generatedTokens >= request.maximumOutputTokens
                    ? .length
                    : .completed
            ))
        }
        #else
        throw LocalModelRuntimeError.engineUnavailable(.coreAI)
        #endif
    }

    func decideLocalAgentTurn(
        request: AgentLocalModelInferenceRequest,
        completedToolCallCount: Int
    ) async throws -> LocalAgentModelDecision {
        #if os(iOS) && canImport(CoreAI) && canImport(CoreAILanguageModels) && canImport(FoundationModels)
        guard completedToolCallCount >= 0,
              completedToolCallCount < LocalAgentModelGrammar.maximumModelPlannedToolCalls
        else { throw LocalModelRuntimeError.invalidAgentDecision }
        return try await LocalInferenceLeaseContext.withLease {
            let decisionRequest = AgentLocalModelInferenceRequest(
                scope: request.scope,
                modelID: request.modelID,
                messages: [
                    .init(role: .system, content: LocalAgentModelGrammar.routerPrompt),
                    .init(
                        role: .user,
                        content: "Request: \(String((request.messages.last?.content ?? "").prefix(1_200)))\nCompleted actions: \(completedToolCallCount)"
                    ),
                ],
                temperature: 0,
                maximumOutputTokens: min(192, request.maximumOutputTokens)
            )
            let output = LocalStreamAccumulator()
            _ = try await generate(request: decisionRequest) { text in
                await output.append(text)
            }
            let text = await output.value
            guard let data = text.data(using: .utf8),
                  let decision = try? JSONDecoder().decode(
                    LocalAgentModelDecision.self,
                    from: data
                  ) else {
                throw LocalModelRuntimeError.invalidAgentDecisionOutput(
                    String(text.prefix(1_500))
                )
            }
            return decision
        }
        #else
        throw LocalModelRuntimeError.engineUnavailable(.coreAI)
        #endif
    }

    func stop(request: AgentLocalModelInferenceRequest) async {
        await unload(modelID: request.modelID)
    }

    func unload(modelID: String?) async {
        #if os(iOS) && canImport(CoreAI) && canImport(CoreAILanguageModels) && canImport(FoundationModels)
        guard #available(iOS 27.0, *) else { return }
        guard let loadedModel,
              modelID == nil || loadedModel.id == modelID else { return }
        activeSession = nil
        loadedModel.model.unload()
        self.loadedModel = nil
        #endif
    }

    #if os(iOS) && canImport(CoreAI) && canImport(CoreAILanguageModels) && canImport(FoundationModels)
    private func generate(
        request: AgentLocalModelInferenceRequest,
        onText: @escaping (String) async throws -> Void
    ) async throws -> UInt64 {
        guard #available(iOS 27.0, *) else {
            throw LocalModelRuntimeError.engineUnavailable(.coreAI)
        }
        try await verifyLocalModelArtifact(modelID: request.modelID)
        guard let descriptor = LocalModelCatalog.variant(for: request.modelID),
              request.maximumOutputTokens > 0,
              request.maximumOutputTokens <= UInt64(descriptor.maxNewTokens),
              let resourcesURL = CoreAIModelAssetResolver.resourcesURL(for: descriptor)
        else { throw LocalModelRuntimeError.engineUnavailable(.coreAI) }

        let model = try await loadModel(
            for: descriptor,
            resourcesURL: resourcesURL
        )
        let boundedMessages = LocalInferenceInputPolicy.boundedMessages(
            request.messages,
            contextTokens: descriptor.contextTokens
        )
        let instructions = boundedMessages
            .filter { $0.role == .system || $0.role == .developer }
            .map(\.content)
            .joined(separator: "\n")
        let conversationMessages = boundedMessages
            .filter { $0.role != .system && $0.role != .developer }
            .suffix(12)
        let promptBudget = max(4_096, Int(descriptor.contextTokens) * 4)
        guard !conversationMessages.isEmpty else {
            throw LocalModelRuntimeError.invalidCompanionResponse
        }
        let session: LanguageModelSession
        let sessionMessages: [AgentLocalModelInferenceMessage]
        if let activeSession,
           activeSession.modelID == descriptor.id,
           activeSession.instructions == instructions,
           conversationMessages.starts(with: activeSession.messages)
        {
            session = activeSession.session
            let delta = Array(
                conversationMessages.dropFirst(activeSession.messages.count)
            )
            if let first = delta.first,
               first.role == .assistant,
               first.content == activeSession.lastResponse
            {
                sessionMessages = Array(delta.dropFirst())
            } else {
                sessionMessages = delta
            }
        } else {
            session = LanguageModelSession(
                model: model,
                instructions: instructions.isEmpty ? nil : instructions
            )
            activeSession = nil
            sessionMessages = Array(conversationMessages)
        }
        let effectiveMessages = sessionMessages.isEmpty
            ? Array(conversationMessages.suffix(1))
            : sessionMessages
        let prompt = effectiveMessages
            .map { "\($0.role.rawValue): \($0.content)" }
            .joined(separator: "\n")
        guard !prompt.isEmpty, prompt.utf8.count <= promptBudget else {
            throw LocalModelRuntimeError.invalidCompanionResponse
        }
        let options = GenerationOptions(
            temperature: request.temperature,
            maximumResponseTokens: Int(request.maximumOutputTokens)
        )
        var previous = ""
        var estimatedTokens: UInt64 = 0
        var completed = false
        defer {
            if completed {
                activeSession = (
                    modelID: descriptor.id,
                    instructions: instructions,
                    session: session,
                    messages: Array(conversationMessages),
                    lastResponse: previous
                )
            } else {
                activeSession = nil
            }
        }
        for try await partial in session.streamResponse(to: prompt, options: options) {
            try Task.checkCancellation()
            let snapshot = partial.content
            let delta = snapshot.hasPrefix(previous)
                ? String(snapshot.dropFirst(previous.count))
                : snapshot
            if !delta.isEmpty {
                try await onText(delta)
                estimatedTokens += UInt64(max(1, Int(Double(delta.count) / 3.8)))
            }
            previous = snapshot
        }
        completed = true
        return min(estimatedTokens, request.maximumOutputTokens)
    }

    private func loadModel(
        for descriptor: LocalModelVariant,
        resourcesURL: URL
    ) async throws -> CoreAILanguageModel {
        guard #available(iOS 27.0, *) else {
            throw LocalModelRuntimeError.engineUnavailable(.coreAI)
        }
        if let loadedModel, loadedModel.id == descriptor.id {
            return loadedModel.model
        }
        activeSession = nil
        if let loadedModel { loadedModel.model.unload() }
        let model = try await CoreAILanguageModel(
            resourcesAt: resourcesURL,
            mode: .eager,
            kvCacheStrategy: .fixedSize
        )
        loadedModel = (descriptor.id, model)
        return model
    }
    #endif
}

private final class CompanionURLSessionDelegate: NSObject,
    URLSessionTaskDelegate, @unchecked Sendable
{
    private let allowedOrigin: URL

    init(allowedOrigin: URL) {
        self.allowedOrigin = allowedOrigin
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let redirectedURL = request.url,
              CompanionEndpointPolicy.normalizedBaseURL(
                  from: redirectedURL.absoluteString
              ) != nil,
              CompanionEndpointPolicy.sameOrigin(
                  allowedOrigin,
                  redirectedURL
              )
        else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

actor CompanionInferenceEngine: LocalInferenceEngine {
    nonisolated let engineType = LocalInferenceEngineType.companion
    private var activeSession: URLSession?

    private struct ModelsEnvelope: Decodable {
        let data: [CompanionServerAttestation]
    }

    private struct CompletionRequest: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }
        let model: String
        let messages: [Message]
        let temperature: Double
        let max_tokens: UInt64
        let stream: Bool
    }

    private struct CompletionEnvelope: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable { let content: String? }
            struct Message: Decodable { let content: String? }
            let delta: Delta?
            let message: Message?
            let tool_calls: [ToolCall]?
        }
        struct ToolCall: Decodable {
            let id: String?
            let type: String?
            let function: Function?

            struct Function: Decodable {
                let name: String?
                let arguments: String?
            }
        }
        struct Usage: Decodable { let completion_tokens: UInt64? }
        let choices: [Choice]
        let usage: Usage?
    }

    /// Strict, bounded OpenAI-compatible SSE framing. A malformed or
    /// truncated event is fatal and cannot become an apparently successful
    /// empty completion.
    struct SSEParser {
        struct Event {
            let data: Data?
            let done: Bool
        }

        let maximumLineBytes = 512 * 1_024
        let maximumEventBytes = 1 * 1_024 * 1_024
        private var dataLines: [String] = []
        private var eventBytes = 0

        mutating func consume(_ line: String) throws -> Event? {
            guard line.utf8.count <= maximumLineBytes else {
                throw LocalModelRuntimeError.invalidCompanionResponse
            }
            if line.isEmpty { return try finishEvent() }
            if line.hasPrefix(":") { return nil }
            guard line.hasPrefix("data:") else {
                throw LocalModelRuntimeError.invalidCompanionResponse
            }
            var value = String(line.dropFirst(5))
            if value.first == " " { value.removeFirst() }
            if value == "[DONE]" {
                guard dataLines.isEmpty else {
                    throw LocalModelRuntimeError.invalidCompanionResponse
                }
                return Event(data: nil, done: true)
            }
            eventBytes += value.utf8.count
            guard eventBytes <= maximumEventBytes else {
                throw LocalModelRuntimeError.invalidCompanionResponse
            }
            dataLines.append(value)
            return nil
        }

        mutating func finishAtEOF() throws -> Event? {
            try finishEvent()
        }

        private mutating func finishEvent() throws -> Event? {
            guard !dataLines.isEmpty else { return nil }
            let payload = dataLines.joined(separator: "\n")
            dataLines.removeAll(keepingCapacity: true)
            eventBytes = 0
            guard let data = payload.data(using: .utf8), !data.isEmpty else {
                throw LocalModelRuntimeError.invalidCompanionResponse
            }
            return Event(data: data, done: false)
        }
    }

    func verifyLocalModelArtifact(modelID: String) async throws {
        let descriptor = try companionDescriptor(modelID: modelID)
        let configuration = try configuration(for: descriptor)
        let session = makeSession(configuration.endpoint)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(
            url: CompanionEndpointPolicy.modelsURL(from: configuration.endpoint)
        )
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              data.count <= 512 * 1_024,
              let envelope = try? JSONDecoder().decode(ModelsEnvelope.self, from: data),
              let attested = envelope.data.first(where: {
                  $0.modelID == configuration.remoteModelID
              }),
              CompanionEndpointPolicy.validateAttestation(
                  attested,
                  for: descriptor,
                  expectedModelID: configuration.remoteModelID,
                  expectedRevision: configuration.immutableRevision
              )
        else {
            throw LocalModelRuntimeError.companionAttestationFailed(
                "expected \(configuration.remoteModelID) at \(configuration.immutableRevision.prefix(12))…"
            )
        }
    }

    func stream(
        request: AgentLocalModelInferenceRequest,
        onEvent: @escaping @Sendable (AgentLocalModelInferenceEvent) async throws -> Void
    ) async throws {
        try await LocalInferenceLeaseContext.withLease {
            let result = try await completion(request: request, stream: true) { text in
                try await onEvent(.text(text))
            }
            try await onEvent(.usage(generatedTokenCount: result.generatedTokens))
            try await onEvent(.completed(reason: result.wasCapped ? .length : .completed))
        }
    }

    func decideLocalAgentTurn(
        request: AgentLocalModelInferenceRequest,
        completedToolCallCount: Int
    ) async throws -> LocalAgentModelDecision {
        guard completedToolCallCount >= 0,
              completedToolCallCount < LocalAgentModelGrammar.maximumModelPlannedToolCalls
        else { throw LocalModelRuntimeError.invalidAgentDecision }
        return try await LocalInferenceLeaseContext.withLease {
            let boundedUser = request.messages.last(where: { $0.role == .user })?.content ?? ""
            let decisionRequest = AgentLocalModelInferenceRequest(
                scope: request.scope,
                modelID: request.modelID,
                messages: [
                    .init(role: .system, content: LocalAgentModelGrammar.routerPrompt),
                    .init(
                        role: .user,
                        content: "Request: \(String(boundedUser.prefix(1_200)))\nCompleted actions: \(completedToolCallCount)"
                    ),
                ],
                temperature: 0,
                maximumOutputTokens: min(192, request.maximumOutputTokens)
            )
            let accumulator = LocalStreamAccumulator()
            _ = try await completion(request: decisionRequest, stream: false) {
                await accumulator.append($0)
            }
            let output = await accumulator.value
            guard output.utf8.count <= 32 * 1_024,
                  let data = output.data(using: .utf8),
                  let decision = try? JSONDecoder().decode(LocalAgentModelDecision.self, from: data)
            else {
                throw LocalModelRuntimeError.invalidAgentDecisionOutput(
                    String(output.prefix(1_500))
                )
            }
            return decision
        }
    }

    func stop(request: AgentLocalModelInferenceRequest) async {
        activeSession?.invalidateAndCancel()
        activeSession = nil
    }

    func unload(modelID: String?) async {
        activeSession?.invalidateAndCancel()
        activeSession = nil
    }

    private struct CompletionResult: Sendable {
        let generatedTokens: UInt64
        let wasCapped: Bool
    }

    private func completion(
        request: AgentLocalModelInferenceRequest,
        stream: Bool,
        onText: @escaping @Sendable (String) async throws -> Void
    ) async throws -> CompletionResult {
        let descriptor = try companionDescriptor(modelID: request.modelID)
        guard request.maximumOutputTokens > 0,
              request.maximumOutputTokens <= UInt64(descriptor.maxNewTokens),
              !request.messages.isEmpty else {
            throw LocalModelRuntimeError.invalidCompanionResponse
        }
        let configuration = try configuration(for: descriptor)
        try await verifyLocalModelArtifact(modelID: request.modelID)

        let body = CompletionRequest(
            model: configuration.remoteModelID,
            messages: request.messages.map {
                .init(role: $0.role.rawValue, content: $0.content)
            },
            temperature: request.temperature,
            max_tokens: request.maximumOutputTokens,
            stream: stream
        )
        var urlRequest = URLRequest(
            url: CompanionEndpointPolicy.completionURL(from: configuration.endpoint)
        )
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = TimeInterval(descriptor.maxGenerationSeconds + 20)
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(configuration.immutableRevision, forHTTPHeaderField: "X-NovaForge-Model-Revision")
        urlRequest.httpBody = try JSONEncoder().encode(body)
        guard (urlRequest.httpBody?.count ?? 0) <= 512 * 1_024 else {
            throw LocalModelRuntimeError.invalidCompanionResponse
        }

        let session = makeSession(configuration.endpoint)
        activeSession?.invalidateAndCancel()
        activeSession = session
        defer {
            session.finishTasksAndInvalidate()
            if activeSession === session { activeSession = nil }
        }

        let preflightConfiguration = try self.configuration(for: descriptor)
        guard preflightConfiguration == configuration else {
            throw LocalModelRuntimeError.companionAttestationFailed(
                "the endpoint identity changed during attestation"
            )
        }
        let (bytes, response) = try await session.bytes(for: urlRequest)
        guard let http = response as? HTTPURLResponse,
              (200 ..< 300).contains(http.statusCode) else {
            throw LocalModelRuntimeError.invalidCompanionResponse
        }

        var emittedCharacters = 0
        var usageTokens: UInt64?
        var nonStreamData = Data()
        var parser = SSEParser()
        var sawSSEData = false
        var sawDone = false

        for try await line in bytes.lines {
            try Task.checkCancellation()
            if line.hasPrefix("data:") || line.hasPrefix(":") {
                sawSSEData = sawSSEData || line.hasPrefix("data:")
                if let event = try parser.consume(line) {
                    if event.done {
                        sawDone = true
                        break
                    }
                    guard let data = event.data,
                          data.count <= 256 * 1_024
                    else {
                        throw LocalModelRuntimeError.invalidCompanionResponse
                    }
                    let consumed = try await consume(
                        JSONDecoder().decode(
                            CompletionEnvelope.self,
                            from: data
                        ),
                        currentEmittedCharacters: emittedCharacters,
                        currentUsageTokens: usageTokens,
                        maximumOutputTokens: request.maximumOutputTokens,
                        onText: onText
                    )
                    emittedCharacters = consumed.emittedCharacters
                    usageTokens = consumed.usageTokens
                }
            } else if !line.isEmpty {
                guard !sawSSEData else {
                    throw LocalModelRuntimeError.invalidCompanionResponse
                }
                nonStreamData.append(contentsOf: line.utf8)
                nonStreamData.append(0x0A)
                guard nonStreamData.count <= 2_000_000 else {
                    throw LocalModelRuntimeError.invalidCompanionResponse
                }
            }
        }

        if sawSSEData {
            if let event = try parser.finishAtEOF() {
                guard let data = event.data,
                      data.count <= 256 * 1_024
                else {
                    throw LocalModelRuntimeError.invalidCompanionResponse
                }
                let consumed = try await consume(
                    JSONDecoder().decode(
                        CompletionEnvelope.self,
                        from: data
                    ),
                    currentEmittedCharacters: emittedCharacters,
                    currentUsageTokens: usageTokens,
                    maximumOutputTokens: request.maximumOutputTokens,
                    onText: onText
                )
                emittedCharacters = consumed.emittedCharacters
                usageTokens = consumed.usageTokens
            }
            guard sawDone else {
                throw LocalModelRuntimeError.invalidCompanionResponse
            }
        }

        if emittedCharacters == 0, !nonStreamData.isEmpty {
            let consumed = try await consume(
                JSONDecoder().decode(
                    CompletionEnvelope.self,
                    from: nonStreamData
                ),
                currentEmittedCharacters: emittedCharacters,
                currentUsageTokens: usageTokens,
                maximumOutputTokens: request.maximumOutputTokens,
                onText: onText
            )
            emittedCharacters = consumed.emittedCharacters
            usageTokens = consumed.usageTokens
        }
        guard emittedCharacters > 0 else {
            throw LocalModelRuntimeError.invalidCompanionResponse
        }
        let finalConfiguration = try self.configuration(for: descriptor)
        guard finalConfiguration == configuration else {
            throw LocalModelRuntimeError.companionAttestationFailed(
                "the endpoint identity changed during the request"
            )
        }
        let estimated = UInt64(max(1, Int(Double(emittedCharacters) / 3.8)))
        let tokens = usageTokens ?? estimated
        guard tokens <= request.maximumOutputTokens else {
            throw LocalModelRuntimeError.invalidCompanionResponse
        }
        return CompletionResult(
            generatedTokens: tokens,
            wasCapped: tokens >= request.maximumOutputTokens
        )
    }

    private func consume(
        _ envelope: CompletionEnvelope,
        currentEmittedCharacters: Int,
        currentUsageTokens: UInt64?,
        maximumOutputTokens: UInt64,
        onText: @escaping @Sendable (String) async throws -> Void
    ) async throws -> (emittedCharacters: Int, usageTokens: UInt64?) {
        if envelope.choices.contains(where: {
            $0.tool_calls?.isEmpty == false
        }) {
            // Tool authority remains entirely on-device. Companion output
            // cannot introduce an unvalidated tool call.
            throw LocalModelRuntimeError.invalidCompanionResponse
        }

        var emittedCharacters = currentEmittedCharacters
        if let text = envelope.choices.first?.delta?.content ??
            envelope.choices.first?.message?.content,
           !text.isEmpty
        {
            emittedCharacters += text.count
            guard emittedCharacters <= Int(maximumOutputTokens) * 16 else {
                throw LocalModelRuntimeError.invalidCompanionResponse
            }
            try await onText(text)
        }

        let usageTokens = envelope.usage?.completion_tokens ?? currentUsageTokens
        if let usageTokens,
           usageTokens > maximumOutputTokens
        {
            throw LocalModelRuntimeError.invalidCompanionResponse
        }
        return (emittedCharacters, usageTokens)
    }

    private func companionDescriptor(modelID: String) throws -> LocalModelVariant {
        guard let descriptor = LocalModelCatalog.variant(for: modelID),
              descriptor.engineType == .companion else {
            throw LocalModelRuntimeError.engineUnavailable(.companion)
        }
        return descriptor
    }

    private func configuration(
        for descriptor: LocalModelVariant
    ) throws -> CompanionModelConfiguration {
        guard let configuration = CompanionModelConfigurationStore.snapshot(),
              configuration.immutableRevision == descriptor.immutableRevision,
              configuration.remoteModelID ==
                CompanionEndpointPolicy.companionModelID,
              CompanionPrivacyStore.isConsented(configuration)
        else {
            throw LocalModelRuntimeError.companionConsentRequired
        }
        return configuration
    }

    private func makeSession(_ endpoint: URL) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        return URLSession(
            configuration: configuration,
            delegate: CompanionURLSessionDelegate(
                allowedOrigin: endpoint
            ),
            delegateQueue: nil
        )
    }
}

actor LocalInferenceRouter: LocalInferenceEngine {
    static let shared = LocalInferenceRouter()
    nonisolated let engineType = LocalInferenceEngineType.llamaCpp

    private let llama: any LocalInferenceEngine
    private let coreAI: any LocalInferenceEngine
    private let companion: any LocalInferenceEngine

    init(
        llama: any LocalInferenceEngine = LlamaCppInferenceEngine.shared,
        coreAI: any LocalInferenceEngine = CoreAIInferenceEngine(),
        companion: any LocalInferenceEngine = CompanionInferenceEngine()
    ) {
        self.llama = llama
        self.coreAI = coreAI
        self.companion = companion
    }

    func prepare(modelID: String) async throws {
        let target = try engine(for: modelID)
        try await LocalInferenceLeaseContext.withLease {
            await unloadOtherEngines(except: target)
            if let preparing = target as? any LocalInferencePreparing {
                try await preparing.prepare(modelID: modelID)
            } else {
                try await target.verifyLocalModelArtifact(modelID: modelID)
            }
        }
    }

    func verifyLocalModelArtifact(modelID: String) async throws {
        try await engine(for: modelID).verifyLocalModelArtifact(modelID: modelID)
    }

    func stream(
        request: AgentLocalModelInferenceRequest,
        onEvent: @escaping @Sendable (AgentLocalModelInferenceEvent) async throws -> Void
    ) async throws {
        let target = try engine(for: request.modelID)
        try await LocalInferenceLeaseContext.withLease {
            await unloadOtherEngines(except: target)
            try await target.stream(request: request, onEvent: onEvent)
        }
    }

    func decideLocalAgentTurn(
        request: AgentLocalModelInferenceRequest,
        completedToolCallCount: Int
    ) async throws -> LocalAgentModelDecision {
        let target = try engine(for: request.modelID)
        return try await LocalInferenceLeaseContext.withLease {
            await unloadOtherEngines(except: target)
            return try await target.decideLocalAgentTurn(
                request: request,
                completedToolCallCount: completedToolCallCount
            )
        }
    }

    func stop(request: AgentLocalModelInferenceRequest) async {
        guard let target = engineForKnownModelID(request.modelID) else { return }
        await target.stop(request: request)
    }

    func unload(modelID: String?) async {
        if let modelID, let target = engineForKnownModelID(modelID) {
            await target.unload(modelID: modelID)
            return
        }
        await llama.unload(modelID: nil)
        await coreAI.unload(modelID: nil)
        await companion.unload(modelID: nil)
    }

    func streamingResponse(
        messages: [ProviderMessageInput],
        model: String,
        temperature: Double,
        customSystemPrompt: String?,
        workspaceSummary: String,
        onContentBatch: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> ProviderResponse {
        let target = try engine(for: model)
        return try await LocalInferenceLeaseContext.withLease {
            await unloadOtherEngines(except: target)
            return try await streamingResponse(
                using: target,
                messages: messages,
                model: model,
                temperature: temperature,
                customSystemPrompt: customSystemPrompt,
                workspaceSummary: workspaceSummary,
                onContentBatch: onContentBatch
            )
        }
    }

    private func streamingResponse(
        using target: any LocalInferenceEngine,
        messages: [ProviderMessageInput],
        model: String,
        temperature: Double,
        customSystemPrompt: String?,
        workspaceSummary: String,
        onContentBatch: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> ProviderResponse {
        if let llama = target as? LlamaCppInferenceEngine {
            return try await llama.streamingResponse(
                messages: messages,
                model: model,
                temperature: temperature,
                customSystemPrompt: customSystemPrompt,
                workspaceSummary: workspaceSummary,
                onContentBatch: onContentBatch
            )
        }

        let systemPrompt = [
            "You are NovaForge Local. Reply concisely and do not expose hidden reasoning.",
            customSystemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
            workspaceSummary.isEmpty ? nil : "Workspace files:\n\(workspaceSummary)",
        ]
        .compactMap { $0 }
        .joined(separator: "\n\n")
        let sanitized = ProviderMessageSanitizer.sanitize(
            systemPrompt: systemPrompt,
            history: messages
        )
        let inferenceMessages = sanitized.messages.compactMap { message -> AgentLocalModelInferenceMessage? in
            guard let content = message.content, !content.isEmpty else { return nil }
            let role: AgentLocalModelInferenceRole
            switch message.role {
            case "system": role = .system
            case "assistant": role = .assistant
            case "tool": role = .user
            default: role = .user
            }
            return .init(role: role, content: content)
        }
        let descriptor = LocalModelCatalog.variant(for: model) ?? LocalModelCatalog.defaultVariant
        let requestID = "local-legacy-\(UUID().uuidString)"
        let request = AgentLocalModelInferenceRequest(
            scope: ProviderAttemptScope(
                requestID: requestID,
                attemptID: .init(rawValue: "\(requestID):attempt:1")
            ),
            modelID: model,
            messages: inferenceMessages,
            temperature: temperature,
            maximumOutputTokens: UInt64(descriptor.maxNewTokens)
        )
        let output = LocalStreamAccumulator()
        try await target.stream(request: request) { event in
            if case let .text(text) = event {
                await output.append(text)
                await onContentBatch(text)
            }
        }
        let responseText = await output.value
        let message = ChatCompletionsResponse.Choice.Message(
            role: "assistant",
            content: responseText.isEmpty ? nil : responseText,
            tool_calls: nil
        )
        return ProviderResponse(message: message, roleLog: sanitized.roleLog)
    }

    func stop(modelID: String) async {
        guard let target = engineForKnownModelID(modelID) else { return }
        let requestID = "local-stop-\(UUID().uuidString)"
        await target.stop(
            request: AgentLocalModelInferenceRequest(
                scope: ProviderAttemptScope(
                    requestID: requestID,
                    attemptID: .init(rawValue: "\(requestID):attempt:1")
                ),
                modelID: modelID,
                messages: [.init(role: .user, content: "stop")],
                temperature: 0,
                maximumOutputTokens: 1
            )
        )
    }

    private func engineForKnownModelID(
        _ modelID: String
    ) -> (any LocalInferenceEngine)? {
        guard let descriptor = LocalModelCatalog.variant(for: modelID) else {
            return nil
        }
        switch descriptor.engineType {
        case .llamaCpp: return llama
        case .coreAI: return coreAI
        case .companion: return companion
        }
    }

    private func engine(for modelID: String) throws -> any LocalInferenceEngine {
        guard let descriptor = LocalModelCatalog.variant(for: modelID) else {
            throw LocalModelRuntimeError.modelNotDownloaded(modelID)
        }
        if let message = LocalModelCatalog.compatibilityMessage(for: descriptor) {
            throw LocalModelRuntimeError.incompatibleDevice(message)
        }
        switch descriptor.engineType {
        case .llamaCpp: return llama
        case .coreAI: return coreAI
        case .companion: return companion
        }
    }

    private func unloadOtherEngines(
        except target: any LocalInferenceEngine
    ) async {
        if target.engineType != .llamaCpp {
            await llama.unload(modelID: nil)
        }
        if target.engineType != .coreAI {
            await coreAI.unload(modelID: nil)
        }
        if target.engineType != .companion {
            await companion.unload(modelID: nil)
        }
    }
}

/// Stable app-facing facade. AgentSystem and provider transports depend only
/// on the narrow inference protocols; concrete engine selection remains in
/// LocalInferenceRouter and never widens tool authority.
actor LocalModelClient: LocalInferenceEngine {
    static let shared = LocalModelClient()
    nonisolated let engineType = LocalInferenceEngineType.llamaCpp
    private let router: LocalInferenceRouter

    init(router: LocalInferenceRouter = LocalInferenceRouter.shared) {
        self.router = router
    }

    func prepare(modelID: String) async throws {
        try await router.prepare(modelID: modelID)
    }

    func verifyLocalModelArtifact(modelID: String) async throws {
        try await router.verifyLocalModelArtifact(modelID: modelID)
    }

    func stream(
        request: AgentLocalModelInferenceRequest,
        onEvent: @escaping @Sendable (AgentLocalModelInferenceEvent) async throws -> Void
    ) async throws {
        try await router.stream(request: request, onEvent: onEvent)
    }

    func decideLocalAgentTurn(
        request: AgentLocalModelInferenceRequest,
        completedToolCallCount: Int
    ) async throws -> LocalAgentModelDecision {
        try await router.decideLocalAgentTurn(
            request: request,
            completedToolCallCount: completedToolCallCount
        )
    }

    func stop(request: AgentLocalModelInferenceRequest) async {
        await router.stop(request: request)
    }

    func unload(modelID: String? = nil) async {
        await router.unload(modelID: modelID)
    }

    func streamingResponse(
        messages: [ProviderMessageInput],
        model: String,
        temperature: Double,
        customSystemPrompt: String?,
        workspaceSummary: String,
        onContentBatch: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> ProviderResponse {
        try await router.streamingResponse(
            messages: messages,
            model: model,
            temperature: temperature,
            customSystemPrompt: customSystemPrompt,
            workspaceSummary: workspaceSummary,
            onContentBatch: onContentBatch
        )
    }

    func stop(model: String) async {
        await router.stop(modelID: model)
    }

    static func extractToolCalls(
        from output: String
    ) -> (content: String, toolCalls: [APIToolCall]) {
        LlamaCppInferenceEngine.extractToolCalls(from: output)
    }
}
