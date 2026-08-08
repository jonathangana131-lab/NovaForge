import Foundation
import AgentDomain
import LocalModelQualificationCore

public enum LocalModelFabricTier: Int, CaseIterable, Hashable, Sendable, Comparable {
    case instant = 0
    case core = 1
    case deep = 2
    case experimentalBeyondRAM = 3

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum LocalModelFabricRole: String, CaseIterable, Hashable, Sendable {
    case router
    case retrieval
    case compaction
    case toolAgent
    case codeEditing
    case deepReasoning
    case visualCritique
    case review
}

public enum LocalModelFabricSelectionMode: String, Hashable, Sendable {
    /// Normal product routing. Requires current canonical qualification evidence.
    case mission
    /// Explicit Compatibility Lab routing. May select an unqualified profile only to measure it.
    case qualificationProbe
}

public enum LocalModelFabricPrivacyRequirement: String, Hashable, Sendable {
    /// The selected execution must be local. Physical-device runtime qualification is required.
    case localExecution
    /// In addition to physical-device runtime qualification, the canonical Local Only network audit must pass.
    case localOnly
}

public enum LocalModelFabricValidationError: Error, Equatable, Sendable {
    case blankField(String)
    case duplicatePreferredTier(LocalModelFabricTier)
    case invalidSuccessThreshold
    case invalidMinimumTaskCount
    case invalidMemoryLimit
    case descriptorSubjectMismatch
    case recordSubjectMismatch
}

public struct LocalModelFabricPolicy: Equatable, Sendable {
    public let policyID: String
    public let revision: String
    public let preferredTiers: [LocalModelFabricTier]
    public let allowExperimentalBeyondRAM: Bool
    public let minimumTaskAttempts: Int
    public let minimumTaskPassRate: Double
    public let maximumPeakResidentBytes: UInt64?
    public let maximumMemoryPressure: LocalModelMemoryPressure
    public let maximumThermalState: LocalModelThermalState

    public init(
        policyID: String,
        revision: String,
        preferredTiers: [LocalModelFabricTier],
        allowExperimentalBeyondRAM: Bool = false,
        minimumTaskAttempts: Int,
        minimumTaskPassRate: Double,
        maximumPeakResidentBytes: UInt64?,
        maximumMemoryPressure: LocalModelMemoryPressure,
        maximumThermalState: LocalModelThermalState
    ) throws {
        guard !Self.isBlank(policyID) else { throw LocalModelFabricValidationError.blankField("policyID") }
        guard !Self.isBlank(revision) else { throw LocalModelFabricValidationError.blankField("revision") }
        guard !preferredTiers.isEmpty else { throw LocalModelFabricValidationError.blankField("preferredTiers") }

        var seen = Set<LocalModelFabricTier>()
        for tier in preferredTiers where !seen.insert(tier).inserted {
            throw LocalModelFabricValidationError.duplicatePreferredTier(tier)
        }
        guard minimumTaskAttempts > 0 else {
            throw LocalModelFabricValidationError.invalidMinimumTaskCount
        }
        guard minimumTaskPassRate.isFinite,
              minimumTaskPassRate >= 0,
              minimumTaskPassRate <= 1
        else {
            throw LocalModelFabricValidationError.invalidSuccessThreshold
        }
        if maximumPeakResidentBytes == 0 {
            throw LocalModelFabricValidationError.invalidMemoryLimit
        }

        self.policyID = policyID
        self.revision = revision
        self.preferredTiers = preferredTiers
        self.allowExperimentalBeyondRAM = allowExperimentalBeyondRAM
        self.minimumTaskAttempts = minimumTaskAttempts
        self.minimumTaskPassRate = minimumTaskPassRate
        self.maximumPeakResidentBytes = maximumPeakResidentBytes
        self.maximumMemoryPressure = maximumMemoryPressure
        self.maximumThermalState = maximumThermalState
    }

    private static func isBlank(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// A configured exact local profile. `qualificationRecord` is optional so an unqualified profile can be
/// selected only in explicit Compatibility Lab probe mode. The selector never manufactures host trust.
public struct LocalModelFabricCandidate: Sendable {
    public let tier: LocalModelFabricTier
    public let descriptor: LocalModelCatalogDescriptor
    public let deviceProfile: LocalModelDeviceProfile
    public let legacyBenchmark: LocalModelBenchmarkObservation?
    public let subject: LocalModelQualificationSubject
    public let qualificationRecord: LocalModelQualificationRecord?
    public let trustedEvidence: Set<LocalModelQualificationEvidence>

    public init(
        tier: LocalModelFabricTier,
        descriptor: LocalModelCatalogDescriptor,
        deviceProfile: LocalModelDeviceProfile,
        legacyBenchmark: LocalModelBenchmarkObservation?,
        subject: LocalModelQualificationSubject,
        qualificationRecord: LocalModelQualificationRecord?,
        trustedEvidence: Set<LocalModelQualificationEvidence>
    ) throws {
        guard Self.matches(descriptor: descriptor, subject: subject) else {
            throw LocalModelFabricValidationError.descriptorSubjectMismatch
        }
        if let qualificationRecord, qualificationRecord.subject != subject {
            throw LocalModelFabricValidationError.recordSubjectMismatch
        }

        self.tier = tier
        self.descriptor = descriptor
        self.deviceProfile = deviceProfile
        self.legacyBenchmark = legacyBenchmark
        self.subject = subject
        self.qualificationRecord = qualificationRecord
        self.trustedEvidence = trustedEvidence
    }

    private static func matches(
        descriptor: LocalModelCatalogDescriptor,
        subject: LocalModelQualificationSubject
    ) -> Bool {
        descriptor.modelID == subject.artifact.modelID
            && descriptor.revision == subject.artifact.modelRevision
            && descriptor.artifactSHA256 == subject.artifact.artifactSHA256
            && descriptor.quantization == subject.execution.quantization
            && (descriptor.contextWindowTokens.map { subject.execution.contextTokens <= $0 } ?? true)
    }
}

public struct LocalModelFabricRequest: Sendable {
    public let role: LocalModelFabricRole
    public let mode: LocalModelFabricSelectionMode
    public let privacy: LocalModelFabricPrivacyRequirement
    public let currentDevice: LocalDeviceIdentity
    public let deviceProfileID: String
    public let requirements: LocalModelMissionRequirements
    public let taskSuiteID: String
    public let taskSuiteRevision: String
    public let policy: LocalModelFabricPolicy
    public let compatibilityPolicy: LocalModelCompatibilityPolicy

    public init(
        role: LocalModelFabricRole,
        mode: LocalModelFabricSelectionMode = .mission,
        privacy: LocalModelFabricPrivacyRequirement,
        currentDevice: LocalDeviceIdentity,
        deviceProfileID: String,
        requirements: LocalModelMissionRequirements = .init(),
        taskSuiteID: String,
        taskSuiteRevision: String,
        policy: LocalModelFabricPolicy,
        compatibilityPolicy: LocalModelCompatibilityPolicy = .conservativeV1
    ) throws {
        guard !Self.isBlank(deviceProfileID) else { throw LocalModelFabricValidationError.blankField("deviceProfileID") }
        guard !Self.isBlank(taskSuiteID) else { throw LocalModelFabricValidationError.blankField("taskSuiteID") }
        guard !Self.isBlank(taskSuiteRevision) else { throw LocalModelFabricValidationError.blankField("taskSuiteRevision") }

        self.role = role
        self.mode = mode
        self.privacy = privacy
        self.currentDevice = currentDevice
        self.deviceProfileID = deviceProfileID
        self.requirements = requirements
        self.taskSuiteID = taskSuiteID
        self.taskSuiteRevision = taskSuiteRevision
        self.policy = policy
        self.compatibilityPolicy = compatibilityPolicy
    }

    private static func isBlank(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public enum LocalModelFabricRejectionReason: String, Hashable, Sendable {
    case tierNotPreferred
    case experimentalOptInRequired
    case deviceProfileMismatch
    case exactDeviceMismatch
    case contextInsufficient
    case preflightIneligible
    case qualificationRecordMissing
    case canonicalQualificationRejected
    case taskSuiteMissing
    case taskSuiteMismatch
    case taskCountInsufficient
    case taskSuccessBelowThreshold
    case measuredMemoryExceeded
    case measuredMemoryPressureExceeded
    case measuredThermalExceeded
    case canonicalSubjectEncodingFailed
}

public struct LocalModelFabricCandidateRejection: Equatable, Sendable {
    public let candidateKey: String
    public let reasons: [LocalModelFabricRejectionReason]
    public let canonicalBlockingReasons: [String]

    public init(
        candidateKey: String,
        reasons: [LocalModelFabricRejectionReason],
        canonicalBlockingReasons: [String]
    ) {
        self.candidateKey = candidateKey
        self.reasons = reasons
        self.canonicalBlockingReasons = canonicalBlockingReasons
    }
}

public enum LocalModelFabricSelectionBasis: String, Hashable, Sendable {
    case canonicalDeviceQualification
    case qualificationProbePreflight
}

/// Transient derived decision evidence. This is intentionally not Codable and must never be treated as a
/// persisted authorization token; mission selection recomputes canonical qualification readiness each time.
public struct LocalModelFabricSelectionReceipt: Equatable, Sendable {
    public let subject: LocalModelQualificationSubject
    public let qualificationRecordRevision: Int?
    public let role: LocalModelFabricRole
    public let tier: LocalModelFabricTier
    public let mode: LocalModelFabricSelectionMode
    public let privacy: LocalModelFabricPrivacyRequirement
    public let policyID: String
    public let policyRevision: String
    public let taskSuiteID: String
    public let taskSuiteRevision: String
    public let qualificationClaim: LocalModelQualificationClaim?
    public let basis: LocalModelFabricSelectionBasis

    public init(
        subject: LocalModelQualificationSubject,
        qualificationRecordRevision: Int?,
        role: LocalModelFabricRole,
        tier: LocalModelFabricTier,
        mode: LocalModelFabricSelectionMode,
        privacy: LocalModelFabricPrivacyRequirement,
        policyID: String,
        policyRevision: String,
        taskSuiteID: String,
        taskSuiteRevision: String,
        qualificationClaim: LocalModelQualificationClaim?,
        basis: LocalModelFabricSelectionBasis
    ) {
        self.subject = subject
        self.qualificationRecordRevision = qualificationRecordRevision
        self.role = role
        self.tier = tier
        self.mode = mode
        self.privacy = privacy
        self.policyID = policyID
        self.policyRevision = policyRevision
        self.taskSuiteID = taskSuiteID
        self.taskSuiteRevision = taskSuiteRevision
        self.qualificationClaim = qualificationClaim
        self.basis = basis
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
        var accepted: [Evaluation] = []
        var rejections: [LocalModelFabricCandidateRejection] = []

        for candidate in candidates {
            let evaluation = evaluate(candidate: candidate, request: request)
            if evaluation.reasons.isEmpty {
                accepted.append(evaluation)
            } else {
                rejections.append(
                    .init(
                        candidateKey: evaluation.candidateKey,
                        reasons: evaluation.reasons,
                        canonicalBlockingReasons: evaluation.canonicalBlockingReasons
                    )
                )
            }
        }

        for tier in request.policy.preferredTiers {
            let tierCandidates = accepted.filter { $0.candidate.tier == tier }
            guard !tierCandidates.isEmpty else { continue }
            let best = tierCandidates.sorted(by: preferred)[0]

            let claim: LocalModelQualificationClaim? = request.mode == .mission
                ? qualificationClaim(for: request.privacy)
                : nil
            let basis: LocalModelFabricSelectionBasis = request.mode == .mission
                ? .canonicalDeviceQualification
                : .qualificationProbePreflight

            return .init(
                selection: .init(
                    subject: best.candidate.subject,
                    qualificationRecordRevision: best.candidate.qualificationRecord?.revision,
                    role: request.role,
                    tier: best.candidate.tier,
                    mode: request.mode,
                    privacy: request.privacy,
                    policyID: request.policy.policyID,
                    policyRevision: request.policy.revision,
                    taskSuiteID: request.taskSuiteID,
                    taskSuiteRevision: request.taskSuiteRevision,
                    qualificationClaim: claim,
                    basis: basis
                ),
                rejections: canonicalRejections(rejections)
            )
        }

        return .init(selection: nil, rejections: canonicalRejections(rejections))
    }

    private struct Evaluation {
        let candidate: LocalModelFabricCandidate
        let candidateKey: String
        var reasons: [LocalModelFabricRejectionReason]
        var canonicalBlockingReasons: [String]
        var taskPassRate: Double?
        var peakResidentBytes: UInt64?
        var ttftMilliseconds: Double?
        var decodeTokensPerSecond: Double?
    }

    private static func evaluate(
        candidate: LocalModelFabricCandidate,
        request: LocalModelFabricRequest
    ) -> Evaluation {
        let key = canonicalSubjectKey(candidate.subject)
        var result = Evaluation(
            candidate: candidate,
            candidateKey: key ?? "<unencodable-subject>",
            reasons: [],
            canonicalBlockingReasons: [],
            taskPassRate: nil,
            peakResidentBytes: nil,
            ttftMilliseconds: nil,
            decodeTokensPerSecond: nil
        )

        if key == nil { result.reasons.append(.canonicalSubjectEncodingFailed) }
        if !request.policy.preferredTiers.contains(candidate.tier) {
            result.reasons.append(.tierNotPreferred)
        }
        if candidate.tier == .experimentalBeyondRAM && !request.policy.allowExperimentalBeyondRAM {
            result.reasons.append(.experimentalOptInRequired)
        }
        if candidate.deviceProfile.profileID != request.deviceProfileID {
            result.reasons.append(.deviceProfileMismatch)
        }
        if candidate.subject.device != request.currentDevice {
            result.reasons.append(.exactDeviceMismatch)
        }
        if let minimumContextTokens = request.requirements.minimumContextTokens,
           candidate.subject.execution.contextTokens < minimumContextTokens {
            result.reasons.append(.contextInsufficient)
        }

        let compatibility = LocalModelCompatibilityEvaluator.evaluate(
            descriptor: candidate.descriptor,
            device: candidate.deviceProfile,
            requirements: request.requirements,
            benchmark: candidate.legacyBenchmark,
            policy: request.compatibilityPolicy
        )
        if !compatibility.isPreflightEligible {
            result.reasons.append(.preflightIneligible)
        }

        guard request.mode == .mission else {
            result.reasons = unique(result.reasons)
            return result
        }

        guard let record = candidate.qualificationRecord else {
            result.reasons.append(.qualificationRecordMissing)
            result.reasons = unique(result.reasons)
            return result
        }

        let claim = qualificationClaim(for: request.privacy)
        let readiness = record.readiness(for: claim, trustedEvidence: candidate.trustedEvidence)
        if !readiness.isQualified {
            result.reasons.append(.canonicalQualificationRejected)
            result.canonicalBlockingReasons = readiness.blockingReasons
        }

        let taskEvidence = record.evidence.first { $0.evidenceClass == .taskSuite }
        guard let taskEvidence,
              case .taskSuite(let taskSuite) = taskEvidence.payload
        else {
            result.reasons.append(.taskSuiteMissing)
            result.reasons = unique(result.reasons)
            return result
        }

        result.taskPassRate = taskSuite.passRate
        if taskSuite.suiteID != request.taskSuiteID || taskSuite.suiteRevision != request.taskSuiteRevision {
            result.reasons.append(.taskSuiteMismatch)
        }
        if taskSuite.attempted < request.policy.minimumTaskAttempts {
            result.reasons.append(.taskCountInsufficient)
        }
        if taskSuite.passRate < request.policy.minimumTaskPassRate {
            result.reasons.append(.taskSuccessBelowThreshold)
        }

        let performance = record.evidence.compactMap { evidence -> LocalModelPerformanceMeasurement? in
            guard case .performance(let measurement) = evidence.payload else { return nil }
            return measurement
        }
        if let maxPeak = performance.map(\ .peakResidentBytes).max() {
            result.peakResidentBytes = maxPeak
            if let limit = request.policy.maximumPeakResidentBytes, maxPeak > limit {
                result.reasons.append(.measuredMemoryExceeded)
            }
        }
        if performance.contains(where: {
            memoryPressureRank($0.peakMemoryPressure) > memoryPressureRank(request.policy.maximumMemoryPressure)
        }) {
            result.reasons.append(.measuredMemoryPressureExceeded)
        }

        if let thermalEvidence = record.evidence.first(where: { $0.evidenceClass == .thermal }),
           case .thermal(let thermal) = thermalEvidence.payload,
           thermalRank(thermal) > thermalRank(request.policy.maximumThermalState) {
            result.reasons.append(.measuredThermalExceeded)
        }

        if let firstToken = record.evidence.first(where: { $0.evidenceClass == .firstToken }),
           case .performance(let measurement) = firstToken.payload {
            result.ttftMilliseconds = measurement.timeToFirstTokenMilliseconds
        }
        if let throughput = record.evidence.first(where: { $0.evidenceClass == .throughput }),
           case .performance(let measurement) = throughput.payload {
            result.decodeTokensPerSecond = measurement.decodeTokensPerSecond
        }

        result.reasons = unique(result.reasons)
        return result
    }

    private static func preferred(_ lhs: Evaluation, _ rhs: Evaluation) -> Bool {
        let leftSuccess = lhs.taskPassRate ?? -1
        let rightSuccess = rhs.taskPassRate ?? -1
        if leftSuccess != rightSuccess { return leftSuccess > rightSuccess }

        let leftMemory = lhs.peakResidentBytes ?? .max
        let rightMemory = rhs.peakResidentBytes ?? .max
        if leftMemory != rightMemory { return leftMemory < rightMemory }

        let leftTTFT = lhs.ttftMilliseconds ?? .greatestFiniteMagnitude
        let rightTTFT = rhs.ttftMilliseconds ?? .greatestFiniteMagnitude
        if leftTTFT != rightTTFT { return leftTTFT < rightTTFT }

        let leftDecode = lhs.decodeTokensPerSecond ?? -1
        let rightDecode = rhs.decodeTokensPerSecond ?? -1
        if leftDecode != rightDecode { return leftDecode > rightDecode }

        return lhs.candidateKey < rhs.candidateKey
    }

    private static func qualificationClaim(
        for privacy: LocalModelFabricPrivacyRequirement
    ) -> LocalModelQualificationClaim {
        switch privacy {
        case .localExecution: .deviceRuntimeQualified
        case .localOnly: .localOnlyDeviceQualified
        }
    }

    /// Sorted-key JSON keeps the tie-break/rejection identity coupled to every Codable field on the canonical
    /// qualification subject. Future exact-subject fields therefore join the key without another manual field list.
    private static func canonicalSubjectKey(_ subject: LocalModelQualificationSubject) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(subject).base64EncodedString()
    }

    private static func canonicalRejections(
        _ rejections: [LocalModelFabricCandidateRejection]
    ) -> [LocalModelFabricCandidateRejection] {
        rejections.sorted { lhs, rhs in
            if lhs.candidateKey == rhs.candidateKey {
                return lhs.reasons.map(\ .rawValue).joined(separator: "|")
                    < rhs.reasons.map(\ .rawValue).joined(separator: "|")
            }
            return lhs.candidateKey < rhs.candidateKey
        }
    }

    private static func unique(
        _ reasons: [LocalModelFabricRejectionReason]
    ) -> [LocalModelFabricRejectionReason] {
        var seen = Set<LocalModelFabricRejectionReason>()
        return reasons.filter { seen.insert($0).inserted }
    }

    private static func memoryPressureRank(_ value: LocalModelMemoryPressure) -> Int {
        switch value {
        case .nominal: 0
        case .warning: 1
        case .critical: 2
        case .terminated: 3
        case .unknown: 4
        }
    }

    private static func thermalRank(_ value: LocalModelThermalState) -> Int {
        switch value {
        case .nominal: 0
        case .fair: 1
        case .serious: 2
        case .critical: 3
        case .unknown: 4
        }
    }
}
