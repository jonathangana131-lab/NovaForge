import Foundation
import AgentDomain

public enum LocalModelFabricTier: Int, Codable, CaseIterable, Hashable, Sendable, Comparable {
    case instant = 0
    case core = 1
    case deep = 2
    case experimentalBeyondRAM = 3

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum LocalModelFabricRole: String, Codable, CaseIterable, Hashable, Sendable {
    case router
    case retrieval
    case compaction
    case toolAgent
    case codeEditing
    case deepReasoning
    case visualCritique
    case review
}

public enum LocalModelFabricSelectionMode: String, Codable, Hashable, Sendable {
    /// Normal mission routing. Requires exact measured compatibility plus a current role qualification.
    case mission
    /// Explicit compatibility-lab routing. May select an untested but preflight-eligible profile only to measure it.
    case qualificationProbe
}

public enum LocalModelFabricThermalState: Int, Codable, CaseIterable, Hashable, Sendable, Comparable {
    case nominal = 0
    case fair = 1
    case serious = 2
    case critical = 3

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum LocalModelFabricValidationError: Error, Equatable, Sendable {
    case blankField(String)
    case invalidArtifactSHA256
    case invalidContextTokens
    case invalidMetric(String)
    case invalidTaskCounts
    case duplicatePreferredTier(LocalModelFabricTier)
    case invalidSuccessThreshold
    case invalidMinimumTaskCount
    case descriptorIdentityMismatch(String)
}

public struct LocalModelRuntimeIdentity: Codable, Equatable, Hashable, Sendable {
    public let modelID: String
    public let revision: String
    public let artifactID: String
    public let artifactSHA256: String
    public let tokenizerID: String
    public let tokenizerRevision: String
    public let runtimeID: String
    public let runtimeRevision: String
    public let quantization: String?
    public let kvCacheType: String
    public let contextTokens: UInt64
    public let deviceProfileID: String
    public let osBuild: String

    public init(
        modelID: String,
        revision: String,
        artifactID: String,
        artifactSHA256: String,
        tokenizerID: String,
        tokenizerRevision: String,
        runtimeID: String,
        runtimeRevision: String,
        quantization: String?,
        kvCacheType: String,
        contextTokens: UInt64,
        deviceProfileID: String,
        osBuild: String
    ) throws {
        let requiredFields = [
            ("modelID", modelID),
            ("revision", revision),
            ("artifactID", artifactID),
            ("tokenizerID", tokenizerID),
            ("tokenizerRevision", tokenizerRevision),
            ("runtimeID", runtimeID),
            ("runtimeRevision", runtimeRevision),
            ("kvCacheType", kvCacheType),
            ("deviceProfileID", deviceProfileID),
            ("osBuild", osBuild),
        ]
        for (name, value) in requiredFields where Self.isBlank(value) {
            throw LocalModelFabricValidationError.blankField(name)
        }
        guard Self.isCanonicalSHA256(artifactSHA256) else {
            throw LocalModelFabricValidationError.invalidArtifactSHA256
        }
        guard contextTokens > 0 else {
            throw LocalModelFabricValidationError.invalidContextTokens
        }
        if let quantization, Self.isBlank(quantization) {
            throw LocalModelFabricValidationError.blankField("quantization")
        }

        self.modelID = modelID
        self.revision = revision
        self.artifactID = artifactID
        self.artifactSHA256 = artifactSHA256
        self.tokenizerID = tokenizerID
        self.tokenizerRevision = tokenizerRevision
        self.runtimeID = runtimeID
        self.runtimeRevision = runtimeRevision
        self.quantization = quantization
        self.kvCacheType = kvCacheType
        self.contextTokens = contextTokens
        self.deviceProfileID = deviceProfileID
        self.osBuild = osBuild
    }

    public init(
        descriptor: LocalModelCatalogDescriptor,
        tokenizerID: String,
        tokenizerRevision: String,
        runtimeID: String,
        runtimeRevision: String,
        kvCacheType: String,
        contextTokens: UInt64,
        deviceProfileID: String,
        osBuild: String
    ) throws {
        if let reportedContext = descriptor.contextWindowTokens, contextTokens > reportedContext {
            throw LocalModelFabricValidationError.descriptorIdentityMismatch("contextTokens")
        }
        try self.init(
            modelID: descriptor.modelID,
            revision: descriptor.revision,
            artifactID: descriptor.artifactID,
            artifactSHA256: descriptor.artifactSHA256,
            tokenizerID: tokenizerID,
            tokenizerRevision: tokenizerRevision,
            runtimeID: runtimeID,
            runtimeRevision: runtimeRevision,
            quantization: descriptor.quantization,
            kvCacheType: kvCacheType,
            contextTokens: contextTokens,
            deviceProfileID: deviceProfileID,
            osBuild: osBuild
        )
    }

    public func matches(
        descriptor: LocalModelCatalogDescriptor,
        deviceProfileID: String
    ) -> Bool {
        modelID == descriptor.modelID
            && revision == descriptor.revision
            && artifactID == descriptor.artifactID
            && artifactSHA256 == descriptor.artifactSHA256
            && quantization == descriptor.quantization
            && self.deviceProfileID == deviceProfileID
            && (descriptor.contextWindowTokens.map { contextTokens <= $0 } ?? true)
    }

    private enum CodingKeys: String, CodingKey {
        case modelID, revision, artifactID, artifactSHA256
        case tokenizerID, tokenizerRevision, runtimeID, runtimeRevision
        case quantization, kvCacheType, contextTokens, deviceProfileID, osBuild
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            modelID: c.decode(String.self, forKey: .modelID),
            revision: c.decode(String.self, forKey: .revision),
            artifactID: c.decode(String.self, forKey: .artifactID),
            artifactSHA256: c.decode(String.self, forKey: .artifactSHA256),
            tokenizerID: c.decode(String.self, forKey: .tokenizerID),
            tokenizerRevision: c.decode(String.self, forKey: .tokenizerRevision),
            runtimeID: c.decode(String.self, forKey: .runtimeID),
            runtimeRevision: c.decode(String.self, forKey: .runtimeRevision),
            quantization: c.decodeIfPresent(String.self, forKey: .quantization),
            kvCacheType: c.decode(String.self, forKey: .kvCacheType),
            contextTokens: c.decode(UInt64.self, forKey: .contextTokens),
            deviceProfileID: c.decode(String.self, forKey: .deviceProfileID),
            osBuild: c.decode(String.self, forKey: .osBuild)
        )
    }

    fileprivate var stableKey: String {
        [
            modelID, revision, artifactID, artifactSHA256, tokenizerID, tokenizerRevision,
            runtimeID, runtimeRevision, quantization ?? "<none>", kvCacheType,
            String(contextTokens), deviceProfileID, osBuild,
        ].joined(separator: "|")
    }

    private static func isBlank(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func isCanonicalSHA256(_ value: String) -> Bool {
        guard value.utf8.count == 64 else { return false }
        return value.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }
    }
}

public struct LocalModelRoleQualification: Codable, Equatable, Sendable {
    public let identity: LocalModelRuntimeIdentity
    public let role: LocalModelFabricRole
    public let suiteID: String
    public let suiteRevision: String
    public let measuredAt: AgentInstant
    public let successfulTasks: UInt16
    public let failedTasks: UInt16
    public let peakResidentMemoryBytes: UInt64
    public let memoryPressureEvents: UInt16
    public let peakThermalState: LocalModelFabricThermalState
    public let ttftMilliseconds: Double?
    public let prefillTokensPerSecond: Double?
    public let decodeTokensPerSecond: Double?
    public let energyMilliwattHours: Double?

    public init(
        identity: LocalModelRuntimeIdentity,
        role: LocalModelFabricRole,
        suiteID: String,
        suiteRevision: String,
        measuredAt: AgentInstant,
        successfulTasks: UInt16,
        failedTasks: UInt16,
        peakResidentMemoryBytes: UInt64,
        memoryPressureEvents: UInt16,
        peakThermalState: LocalModelFabricThermalState,
        ttftMilliseconds: Double? = nil,
        prefillTokensPerSecond: Double? = nil,
        decodeTokensPerSecond: Double? = nil,
        energyMilliwattHours: Double? = nil
    ) throws {
        guard !Self.isBlank(suiteID) else { throw LocalModelFabricValidationError.blankField("suiteID") }
        guard !Self.isBlank(suiteRevision) else { throw LocalModelFabricValidationError.blankField("suiteRevision") }
        guard UInt32(successfulTasks) + UInt32(failedTasks) > 0 else {
            throw LocalModelFabricValidationError.invalidTaskCounts
        }
        guard peakResidentMemoryBytes > 0 else {
            throw LocalModelFabricValidationError.invalidMetric("peakResidentMemoryBytes")
        }
        try Self.validateOptionalMetric(ttftMilliseconds, name: "ttftMilliseconds", allowsZero: false)
        try Self.validateOptionalMetric(prefillTokensPerSecond, name: "prefillTokensPerSecond")
        try Self.validateOptionalMetric(decodeTokensPerSecond, name: "decodeTokensPerSecond")
        try Self.validateOptionalMetric(energyMilliwattHours, name: "energyMilliwattHours")

        self.identity = identity
        self.role = role
        self.suiteID = suiteID
        self.suiteRevision = suiteRevision
        self.measuredAt = measuredAt
        self.successfulTasks = successfulTasks
        self.failedTasks = failedTasks
        self.peakResidentMemoryBytes = peakResidentMemoryBytes
        self.memoryPressureEvents = memoryPressureEvents
        self.peakThermalState = peakThermalState
        self.ttftMilliseconds = ttftMilliseconds
        self.prefillTokensPerSecond = prefillTokensPerSecond
        self.decodeTokensPerSecond = decodeTokensPerSecond
        self.energyMilliwattHours = energyMilliwattHours
    }

    public var completedTasks: UInt32 { UInt32(successfulTasks) + UInt32(failedTasks) }
    public var taskSuccessRate: Double { Double(successfulTasks) / Double(completedTasks) }

    private enum CodingKeys: String, CodingKey {
        case identity, role, suiteID, suiteRevision, measuredAt, successfulTasks, failedTasks
        case peakResidentMemoryBytes, memoryPressureEvents, peakThermalState
        case ttftMilliseconds, prefillTokensPerSecond, decodeTokensPerSecond, energyMilliwattHours
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            identity: c.decode(LocalModelRuntimeIdentity.self, forKey: .identity),
            role: c.decode(LocalModelFabricRole.self, forKey: .role),
            suiteID: c.decode(String.self, forKey: .suiteID),
            suiteRevision: c.decode(String.self, forKey: .suiteRevision),
            measuredAt: c.decode(AgentInstant.self, forKey: .measuredAt),
            successfulTasks: c.decode(UInt16.self, forKey: .successfulTasks),
            failedTasks: c.decode(UInt16.self, forKey: .failedTasks),
            peakResidentMemoryBytes: c.decode(UInt64.self, forKey: .peakResidentMemoryBytes),
            memoryPressureEvents: c.decode(UInt16.self, forKey: .memoryPressureEvents),
            peakThermalState: c.decode(LocalModelFabricThermalState.self, forKey: .peakThermalState),
            ttftMilliseconds: c.decodeIfPresent(Double.self, forKey: .ttftMilliseconds),
            prefillTokensPerSecond: c.decodeIfPresent(Double.self, forKey: .prefillTokensPerSecond),
            decodeTokensPerSecond: c.decodeIfPresent(Double.self, forKey: .decodeTokensPerSecond),
            energyMilliwattHours: c.decodeIfPresent(Double.self, forKey: .energyMilliwattHours)
        )
    }

    private static func isBlank(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func validateOptionalMetric(
        _ value: Double?,
        name: String,
        allowsZero: Bool = true
    ) throws {
        guard let value else { return }
        guard value.isFinite, allowsZero ? value >= 0 : value > 0 else {
            throw LocalModelFabricValidationError.invalidMetric(name)
        }
    }
}

public struct LocalModelFabricCandidate: Equatable, Sendable {
    public let tier: LocalModelFabricTier
    public let descriptor: LocalModelCatalogDescriptor
    public let device: LocalModelDeviceProfile
    public let benchmark: LocalModelBenchmarkObservation?
    public let runtimeIdentity: LocalModelRuntimeIdentity
    public let qualifications: [LocalModelRoleQualification]

    public init(
        tier: LocalModelFabricTier,
        descriptor: LocalModelCatalogDescriptor,
        device: LocalModelDeviceProfile,
        benchmark: LocalModelBenchmarkObservation?,
        runtimeIdentity: LocalModelRuntimeIdentity,
        qualifications: [LocalModelRoleQualification]
    ) throws {
        guard runtimeIdentity.matches(descriptor: descriptor, deviceProfileID: device.profileID) else {
            throw LocalModelFabricValidationError.descriptorIdentityMismatch("runtimeIdentity")
        }
        self.tier = tier
        self.descriptor = descriptor
        self.device = device
        self.benchmark = benchmark
        self.runtimeIdentity = runtimeIdentity
        self.qualifications = qualifications
    }
}

public struct LocalModelFabricPolicy: Equatable, Sendable {
    public let policyID: String
    public let revision: String
    public let preferredTiers: [LocalModelFabricTier]
    public let allowExperimentalBeyondRAM: Bool
    public let minimumCompletedTasks: UInt16
    public let minimumTaskSuccessRate: Double
    public let maximumPeakResidentMemoryBytes: UInt64?
    public let maximumMemoryPressureEvents: UInt16?
    public let maximumThermalState: LocalModelFabricThermalState?

    public init(
        policyID: String,
        revision: String,
        preferredTiers: [LocalModelFabricTier],
        allowExperimentalBeyondRAM: Bool = false,
        minimumCompletedTasks: UInt16 = 2,
        minimumTaskSuccessRate: Double = 1,
        maximumPeakResidentMemoryBytes: UInt64? = nil,
        maximumMemoryPressureEvents: UInt16? = nil,
        maximumThermalState: LocalModelFabricThermalState? = nil
    ) throws {
        guard !Self.isBlank(policyID) else { throw LocalModelFabricValidationError.blankField("policyID") }
        guard !Self.isBlank(revision) else { throw LocalModelFabricValidationError.blankField("revision") }
        guard !preferredTiers.isEmpty else { throw LocalModelFabricValidationError.blankField("preferredTiers") }
        var seen = Set<LocalModelFabricTier>()
        for tier in preferredTiers where !seen.insert(tier).inserted {
            throw LocalModelFabricValidationError.duplicatePreferredTier(tier)
        }
        guard minimumCompletedTasks > 0 else { throw LocalModelFabricValidationError.invalidMinimumTaskCount }
        guard minimumTaskSuccessRate.isFinite,
              minimumTaskSuccessRate >= 0,
              minimumTaskSuccessRate <= 1
        else {
            throw LocalModelFabricValidationError.invalidSuccessThreshold
        }
        if maximumPeakResidentMemoryBytes == 0 {
            throw LocalModelFabricValidationError.invalidMetric("maximumPeakResidentMemoryBytes")
        }

        self.policyID = policyID
        self.revision = revision
        self.preferredTiers = preferredTiers
        self.allowExperimentalBeyondRAM = allowExperimentalBeyondRAM
        self.minimumCompletedTasks = minimumCompletedTasks
        self.minimumTaskSuccessRate = minimumTaskSuccessRate
        self.maximumPeakResidentMemoryBytes = maximumPeakResidentMemoryBytes
        self.maximumMemoryPressureEvents = maximumMemoryPressureEvents
        self.maximumThermalState = maximumThermalState
    }

    private static func isBlank(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public struct LocalModelFabricRequest: Equatable, Sendable {
    public let role: LocalModelFabricRole
    public let mode: LocalModelFabricSelectionMode
    public let deviceProfileID: String
    public let osBuild: String
    public let requirements: LocalModelMissionRequirements
    public let qualificationSuiteID: String
    public let qualificationSuiteRevision: String
    public let policy: LocalModelFabricPolicy
    public let compatibilityPolicy: LocalModelCompatibilityPolicy

    public init(
        role: LocalModelFabricRole,
        mode: LocalModelFabricSelectionMode = .mission,
        deviceProfileID: String,
        osBuild: String,
        requirements: LocalModelMissionRequirements = .init(),
        qualificationSuiteID: String,
        qualificationSuiteRevision: String,
        policy: LocalModelFabricPolicy,
        compatibilityPolicy: LocalModelCompatibilityPolicy = .conservativeV1
    ) throws {
        guard !Self.isBlank(deviceProfileID) else { throw LocalModelFabricValidationError.blankField("deviceProfileID") }
        guard !Self.isBlank(osBuild) else { throw LocalModelFabricValidationError.blankField("osBuild") }
        guard !Self.isBlank(qualificationSuiteID) else { throw LocalModelFabricValidationError.blankField("qualificationSuiteID") }
        guard !Self.isBlank(qualificationSuiteRevision) else { throw LocalModelFabricValidationError.blankField("qualificationSuiteRevision") }
        self.role = role
        self.mode = mode
        self.deviceProfileID = deviceProfileID
        self.osBuild = osBuild
        self.requirements = requirements
        self.qualificationSuiteID = qualificationSuiteID
        self.qualificationSuiteRevision = qualificationSuiteRevision
        self.policy = policy
        self.compatibilityPolicy = compatibilityPolicy
    }

    private static func isBlank(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public enum LocalModelFabricRejectionReason: String, Codable, Hashable, Sendable {
    case tierNotPreferred
    case experimentalOptInRequired
    case deviceProfileMismatch
    case osBuildMismatch
    case runtimeIdentityMismatch
    case contextInsufficient
    case preflightIneligible
    case measuredCompatibilityRequired
    case qualificationMissing
    case qualificationSuiteMismatch
    case qualificationInsufficientTasks
    case qualificationSuccessBelowThreshold
    case measuredMemoryExceeded
    case measuredMemoryPressureExceeded
    case measuredThermalExceeded
}

public struct LocalModelFabricCandidateRejection: Equatable, Sendable {
    public let candidateKey: String
    public let reasons: [LocalModelFabricRejectionReason]

    public init(candidateKey: String, reasons: [LocalModelFabricRejectionReason]) {
        self.candidateKey = candidateKey
        self.reasons = reasons
    }
}

public enum LocalModelFabricSelectionBasis: String, Codable, Hashable, Sendable {
    case measuredRoleQualification
    case qualificationProbePreflight
}

public struct LocalModelFabricSelectionReceipt: Codable, Equatable, Sendable {
    public let runtimeIdentity: LocalModelRuntimeIdentity
    public let role: LocalModelFabricRole
    public let tier: LocalModelFabricTier
    public let mode: LocalModelFabricSelectionMode
    public let policyID: String
    public let policyRevision: String
    public let compatibilityLabel: LocalModelCompatibilityLabel
    public let basis: LocalModelFabricSelectionBasis
    public let qualificationSuiteID: String?
    public let qualificationSuiteRevision: String?
    public let qualificationMeasuredAt: AgentInstant?

    public init(
        runtimeIdentity: LocalModelRuntimeIdentity,
        role: LocalModelFabricRole,
        tier: LocalModelFabricTier,
        mode: LocalModelFabricSelectionMode,
        policyID: String,
        policyRevision: String,
        compatibilityLabel: LocalModelCompatibilityLabel,
        basis: LocalModelFabricSelectionBasis,
        qualificationSuiteID: String?,
        qualificationSuiteRevision: String?,
        qualificationMeasuredAt: AgentInstant?
    ) {
        self.runtimeIdentity = runtimeIdentity
        self.role = role
        self.tier = tier
        self.mode = mode
        self.policyID = policyID
        self.policyRevision = policyRevision
        self.compatibilityLabel = compatibilityLabel
        self.basis = basis
        self.qualificationSuiteID = qualificationSuiteID
        self.qualificationSuiteRevision = qualificationSuiteRevision
        self.qualificationMeasuredAt = qualificationMeasuredAt
    }
}

public struct LocalModelFabricSelectionDecision: Equatable, Sendable {
    public let selection: LocalModelFabricSelectionReceipt?
    public let rejections: [LocalModelFabricCandidateRejection]

    public init(
        selection: LocalModelFabricSelectionReceipt?,
        rejections: [LocalModelFabricCandidateRejection]
    ) {
        self.selection = selection
        self.rejections = rejections
    }
}

public enum LocalModelFabricSelector {
    public static func select(
        candidates: [LocalModelFabricCandidate],
        request: LocalModelFabricRequest
    ) -> LocalModelFabricSelectionDecision {
        var rejections: [LocalModelFabricCandidateRejection] = []
        var accepted: [(candidate: LocalModelFabricCandidate, compatibility: LocalModelCompatibilityResult, qualification: LocalModelRoleQualification?)] = []

        for candidate in candidates {
            let result = evaluate(candidate: candidate, request: request)
            if result.reasons.isEmpty {
                accepted.append((candidate, result.compatibility, result.qualification))
            } else {
                rejections.append(.init(candidateKey: candidate.runtimeIdentity.stableKey, reasons: result.reasons))
            }
        }

        for tier in request.policy.preferredTiers {
            let tierCandidates = accepted.filter { $0.candidate.tier == tier }
            guard !tierCandidates.isEmpty else { continue }
            let best = tierCandidates.sorted { lhs, rhs in
                isPreferred(lhs, over: rhs, mode: request.mode)
            }[0]

            let basis: LocalModelFabricSelectionBasis = request.mode == .mission
                ? .measuredRoleQualification
                : .qualificationProbePreflight
            return .init(
                selection: .init(
                    runtimeIdentity: best.candidate.runtimeIdentity,
                    role: request.role,
                    tier: best.candidate.tier,
                    mode: request.mode,
                    policyID: request.policy.policyID,
                    policyRevision: request.policy.revision,
                    compatibilityLabel: best.compatibility.label,
                    basis: basis,
                    qualificationSuiteID: best.qualification?.suiteID,
                    qualificationSuiteRevision: best.qualification?.suiteRevision,
                    qualificationMeasuredAt: best.qualification?.measuredAt
                ),
                rejections: rejections.sorted { $0.candidateKey < $1.candidateKey }
            )
        }

        return .init(
            selection: nil,
            rejections: rejections.sorted { $0.candidateKey < $1.candidateKey }
        )
    }

    private static func evaluate(
        candidate: LocalModelFabricCandidate,
        request: LocalModelFabricRequest
    ) -> (
        reasons: [LocalModelFabricRejectionReason],
        compatibility: LocalModelCompatibilityResult,
        qualification: LocalModelRoleQualification?
    ) {
        var reasons: [LocalModelFabricRejectionReason] = []

        if !request.policy.preferredTiers.contains(candidate.tier) {
            reasons.append(.tierNotPreferred)
        }
        if candidate.tier == .experimentalBeyondRAM && !request.policy.allowExperimentalBeyondRAM {
            reasons.append(.experimentalOptInRequired)
        }
        if candidate.device.profileID != request.deviceProfileID {
            reasons.append(.deviceProfileMismatch)
        }
        if candidate.runtimeIdentity.osBuild != request.osBuild {
            reasons.append(.osBuildMismatch)
        }
        if !candidate.runtimeIdentity.matches(descriptor: candidate.descriptor, deviceProfileID: request.deviceProfileID) {
            reasons.append(.runtimeIdentityMismatch)
        }
        if let minimumContextTokens = request.requirements.minimumContextTokens,
           candidate.runtimeIdentity.contextTokens < minimumContextTokens {
            reasons.append(.contextInsufficient)
        }

        let compatibility = LocalModelCompatibilityEvaluator.evaluate(
            descriptor: candidate.descriptor,
            device: candidate.device,
            requirements: request.requirements,
            benchmark: candidate.benchmark,
            policy: request.compatibilityPolicy
        )

        if !compatibility.isPreflightEligible {
            reasons.append(.preflightIneligible)
        }

        switch request.mode {
        case .qualificationProbe:
            return (Self.unique(reasons), compatibility, nil)
        case .mission:
            guard compatibility.hasMeasuredEvidence,
                  compatibility.label == .excellent || compatibility.label == .good || compatibility.label == .slow
            else {
                reasons.append(.measuredCompatibilityRequired)
                return (Self.unique(reasons), compatibility, nil)
            }
        }

        let exactRoleQualifications = candidate.qualifications.filter {
            $0.role == request.role && $0.identity == candidate.runtimeIdentity
        }
        guard !exactRoleQualifications.isEmpty else {
            reasons.append(.qualificationMissing)
            return (Self.unique(reasons), compatibility, nil)
        }

        let exactSuite = exactRoleQualifications.filter {
            $0.suiteID == request.qualificationSuiteID
                && $0.suiteRevision == request.qualificationSuiteRevision
        }
        guard !exactSuite.isEmpty else {
            reasons.append(.qualificationSuiteMismatch)
            return (Self.unique(reasons), compatibility, nil)
        }

        let ordered = exactSuite.sorted { lhs, rhs in
            if lhs.measuredAt != rhs.measuredAt { return lhs.measuredAt > rhs.measuredAt }
            if lhs.taskSuccessRate != rhs.taskSuccessRate { return lhs.taskSuccessRate > rhs.taskSuccessRate }
            return lhs.peakResidentMemoryBytes < rhs.peakResidentMemoryBytes
        }
        let qualification = ordered[0]

        if qualification.completedTasks < UInt32(request.policy.minimumCompletedTasks) {
            reasons.append(.qualificationInsufficientTasks)
        }
        if qualification.taskSuccessRate < request.policy.minimumTaskSuccessRate {
            reasons.append(.qualificationSuccessBelowThreshold)
        }
        if let maxMemory = request.policy.maximumPeakResidentMemoryBytes,
           qualification.peakResidentMemoryBytes > maxMemory {
            reasons.append(.measuredMemoryExceeded)
        }
        if let maxPressure = request.policy.maximumMemoryPressureEvents,
           qualification.memoryPressureEvents > maxPressure {
            reasons.append(.measuredMemoryPressureExceeded)
        }
        if let maxThermal = request.policy.maximumThermalState,
           qualification.peakThermalState > maxThermal {
            reasons.append(.measuredThermalExceeded)
        }

        return (Self.unique(reasons), compatibility, qualification)
    }

    private static func isPreferred(
        _ lhs: (candidate: LocalModelFabricCandidate, compatibility: LocalModelCompatibilityResult, qualification: LocalModelRoleQualification?),
        over rhs: (candidate: LocalModelFabricCandidate, compatibility: LocalModelCompatibilityResult, qualification: LocalModelRoleQualification?),
        mode: LocalModelFabricSelectionMode
    ) -> Bool {
        if mode == .mission, let lq = lhs.qualification, let rq = rhs.qualification {
            if lq.taskSuccessRate != rq.taskSuccessRate { return lq.taskSuccessRate > rq.taskSuccessRate }
            if lq.peakResidentMemoryBytes != rq.peakResidentMemoryBytes {
                return lq.peakResidentMemoryBytes < rq.peakResidentMemoryBytes
            }
            let lttft = lq.ttftMilliseconds ?? .greatestFiniteMagnitude
            let rttft = rq.ttftMilliseconds ?? .greatestFiniteMagnitude
            if lttft != rttft { return lttft < rttft }
            let ldecode = lq.decodeTokensPerSecond ?? -1
            let rdecode = rq.decodeTokensPerSecond ?? -1
            if ldecode != rdecode { return ldecode > rdecode }
        }
        return lhs.candidate.runtimeIdentity.stableKey < rhs.candidate.runtimeIdentity.stableKey
    }

    private static func unique(
        _ reasons: [LocalModelFabricRejectionReason]
    ) -> [LocalModelFabricRejectionReason] {
        var seen = Set<LocalModelFabricRejectionReason>()
        return reasons.filter { seen.insert($0).inserted }
    }
}
