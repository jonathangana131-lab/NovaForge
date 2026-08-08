import Foundation

/// Runtime memory pressure observed by the host. The governor never invents this signal.
public enum ForgeCompactMemoryPressure: String, CaseIterable, Codable, Hashable, Sendable {
    case nominal
    case warning
    case critical

    fileprivate var rank: Int {
        switch self {
        case .nominal: 0
        case .warning: 1
        case .critical: 2
        }
    }
}

/// Thermal pressure observed by the host. Exact thresholds remain host policy inputs.
public enum ForgeCompactThermalPressure: String, CaseIterable, Codable, Hashable, Sendable {
    case nominal
    case fair
    case serious
    case critical

    fileprivate var rank: Int {
        switch self {
        case .nominal: 0
        case .fair: 1
        case .serious: 2
        case .critical: 3
        }
    }
}

public enum ForgeCompactOperatingMode: String, Codable, Hashable, Sendable {
    case production
    case research
}

public enum ForgeCompactComputeLocation: String, Codable, Hashable, Sendable {
    case local
    case remote
}

/// Candidate metadata only. A current host grant is required before measured evidence can be used.
public enum ForgeCompactEvidenceStatus: String, Codable, Hashable, Sendable {
    case exactDeviceMeasured
    case experimentalExactDeviceMeasured
    case unverified
}

public struct ForgeCompactExecutionEnvelope: Codable, Hashable, Sendable {
    public let id: String
    public let profileID: String
    public let configurationBindingID: String
    public let deviceProfileID: String
    public let evidenceReceiptID: String
    public let computeLocation: ForgeCompactComputeLocation
    public let evidenceStatus: ForgeCompactEvidenceStatus
    public let contextTokens: UInt64
    public let observedPeakResidentBytes: UInt64

    public init(
        id: String,
        profileID: String,
        configurationBindingID: String,
        deviceProfileID: String,
        evidenceReceiptID: String,
        computeLocation: ForgeCompactComputeLocation = .local,
        evidenceStatus: ForgeCompactEvidenceStatus,
        contextTokens: UInt64,
        observedPeakResidentBytes: UInt64
    ) {
        self.id = id
        self.profileID = profileID
        self.configurationBindingID = configurationBindingID
        self.deviceProfileID = deviceProfileID
        self.evidenceReceiptID = evidenceReceiptID
        self.computeLocation = computeLocation
        self.evidenceStatus = evidenceStatus
        self.contextTokens = contextTokens
        self.observedPeakResidentBytes = observedPeakResidentBytes
    }
}

/// Transient host acceptance for one exact execution envelope. It is deliberately non-Codable and
/// package-internal to create, so candidate bytes cannot mint their own qualification authority.
/// The future LocalModelQualificationCore adapter must live at this package boundary and create
/// grants only after resolving current accepted evidence.
public struct ForgeCompactQualificationGrant: Hashable, Sendable {
    public let acceptedEnvelope: ForgeCompactExecutionEnvelope

    init(acceptedEnvelope: ForgeCompactExecutionEnvelope) throws {
        guard ForgeCompactGovernor.hasCanonicalIdentity(acceptedEnvelope),
              acceptedEnvelope.computeLocation == .local,
              acceptedEnvelope.evidenceStatus != .unverified
        else {
            throw ForgeCompactError.invalidIdentifier(field: "qualificationGrant")
        }
        self.acceptedEnvelope = acceptedEnvelope
    }

    fileprivate func matches(_ envelope: ForgeCompactExecutionEnvelope) -> Bool {
        acceptedEnvelope == envelope
    }
}

public struct ForgeCompactRuntimeSnapshot: Codable, Equatable, Sendable {
    public let deviceProfileID: String
    public let requestedContextTokens: UInt64
    public let minimumMissionContextTokens: UInt64
    public let memoryBudgetBytes: UInt64
    public let activeEnvelopeID: String?
    public let memoryPressure: ForgeCompactMemoryPressure
    public let thermalPressure: ForgeCompactThermalPressure

    public init(
        deviceProfileID: String,
        requestedContextTokens: UInt64,
        minimumMissionContextTokens: UInt64,
        memoryBudgetBytes: UInt64,
        activeEnvelopeID: String? = nil,
        memoryPressure: ForgeCompactMemoryPressure,
        thermalPressure: ForgeCompactThermalPressure
    ) {
        self.deviceProfileID = deviceProfileID
        self.requestedContextTokens = requestedContextTokens
        self.minimumMissionContextTokens = minimumMissionContextTokens
        self.memoryBudgetBytes = memoryBudgetBytes
        self.activeEnvelopeID = activeEnvelopeID
        self.memoryPressure = memoryPressure
        self.thermalPressure = thermalPressure
    }
}

public struct ForgeCompactGovernorPolicy: Codable, Equatable, Sendable {
    public let operatingMode: ForgeCompactOperatingMode
    public let nominalReserveBytes: UInt64
    public let warningReserveBytes: UInt64
    public let suspendAtMemoryPressure: ForgeCompactMemoryPressure
    public let suspendAtThermalPressure: ForgeCompactThermalPressure

    public init(
        operatingMode: ForgeCompactOperatingMode = .production,
        nominalReserveBytes: UInt64,
        warningReserveBytes: UInt64,
        suspendAtMemoryPressure: ForgeCompactMemoryPressure = .critical,
        suspendAtThermalPressure: ForgeCompactThermalPressure = .critical
    ) {
        self.operatingMode = operatingMode
        self.nominalReserveBytes = nominalReserveBytes
        self.warningReserveBytes = warningReserveBytes
        self.suspendAtMemoryPressure = suspendAtMemoryPressure
        self.suspendAtThermalPressure = suspendAtThermalPressure
    }

    fileprivate var isValid: Bool { warningReserveBytes >= nominalReserveBytes }

    fileprivate func reserveBytes(for pressure: ForgeCompactMemoryPressure) -> UInt64 {
        switch pressure {
        case .nominal: nominalReserveBytes
        case .warning, .critical: warningReserveBytes
        }
    }
}

public enum ForgeCompactCandidateRejectionReason: String, CaseIterable, Codable, Hashable, Sendable {
    case duplicateEnvelopeID
    case invalidIdentity
    case nonLocalCompute
    case unverifiedEvidence
    case qualificationGrantMissing
    case experimentalDisallowed
    case deviceProfileMismatch
    case contextBelowMissionMinimum
    case contextExceedsRequest
    case invalidPeakMemoryMeasurement
    case insufficientMeasuredHeadroom
}

public struct ForgeCompactCandidateVerdict: Codable, Equatable, Sendable {
    public let envelopeID: String
    public let rejectionReasons: [ForgeCompactCandidateRejectionReason]

    public init(envelopeID: String, rejectionReasons: [ForgeCompactCandidateRejectionReason]) {
        self.envelopeID = envelopeID
        self.rejectionReasons = rejectionReasons
    }

    public var isEligible: Bool { rejectionReasons.isEmpty }
}

public enum ForgeCompactStopReason: String, Codable, Hashable, Sendable {
    case memoryPressureThresholdReached
    case thermalPressureThresholdReached
}

public enum ForgeCompactBlockReason: String, Codable, Hashable, Sendable {
    case invalidRuntimeSnapshot
    case invalidPolicy
    case noEligibleLocalEnvelope
}

public enum ForgeCompactDecisionAction: Codable, Equatable, Sendable {
    case keep(envelopeID: String)
    case switchTo(envelopeID: String)
    case suspend(reason: ForgeCompactStopReason)
    case block(reason: ForgeCompactBlockReason)
}

/// Fresh derived decision. This type is intentionally non-Codable: durable bytes are represented
/// by `ForgeCompactDecisionArchive`, which must be restored through fresh qualification grants.
public struct ForgeCompactDecisionReceipt: Equatable, Sendable {
    public let snapshot: ForgeCompactRuntimeSnapshot
    public let policy: ForgeCompactGovernorPolicy
    public let action: ForgeCompactDecisionAction
    public let selectedEnvelope: ForgeCompactExecutionEnvelope?
    public let candidateVerdicts: [ForgeCompactCandidateVerdict]
    public let evaluatedEnvelopes: [ForgeCompactExecutionEnvelope]

    fileprivate init(
        snapshot: ForgeCompactRuntimeSnapshot,
        policy: ForgeCompactGovernorPolicy,
        action: ForgeCompactDecisionAction,
        selectedEnvelope: ForgeCompactExecutionEnvelope?,
        candidateVerdicts: [ForgeCompactCandidateVerdict],
        evaluatedEnvelopes: [ForgeCompactExecutionEnvelope]
    ) {
        self.snapshot = snapshot
        self.policy = policy
        self.action = action
        self.selectedEnvelope = selectedEnvelope
        self.candidateVerdicts = candidateVerdicts
        self.evaluatedEnvelopes = evaluatedEnvelopes
    }

    public func archive() -> ForgeCompactDecisionArchive {
        ForgeCompactDecisionArchive(receipt: self)
    }
}

public enum ForgeCompactDecisionArchiveError: Error, Equatable, Sendable {
    case invalidSchema(Int)
    case invalidShape
    case freshQualificationRequired
}

/// Durable, serializable historical inputs + output. Decoding this type never restores execution
/// authority. Call `restore(qualificationGrants:)` to re-run the governor against current host trust.
public struct ForgeCompactDecisionArchive: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let snapshot: ForgeCompactRuntimeSnapshot
    public let policy: ForgeCompactGovernorPolicy
    public let action: ForgeCompactDecisionAction
    public let selectedEnvelope: ForgeCompactExecutionEnvelope?
    public let candidateVerdicts: [ForgeCompactCandidateVerdict]
    public let evaluatedEnvelopes: [ForgeCompactExecutionEnvelope]

    fileprivate init(receipt: ForgeCompactDecisionReceipt) {
        schemaVersion = Self.currentSchemaVersion
        snapshot = receipt.snapshot
        policy = receipt.policy
        action = receipt.action
        selectedEnvelope = receipt.selectedEnvelope
        candidateVerdicts = receipt.candidateVerdicts
        evaluatedEnvelopes = receipt.evaluatedEnvelopes
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, snapshot, policy, action, selectedEnvelope, candidateVerdicts, evaluatedEnvelopes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ForgeCompactDecisionArchiveError.invalidSchema(schemaVersion)
        }

        let snapshot = try container.decode(ForgeCompactRuntimeSnapshot.self, forKey: .snapshot)
        let policy = try container.decode(ForgeCompactGovernorPolicy.self, forKey: .policy)
        let action = try container.decode(ForgeCompactDecisionAction.self, forKey: .action)
        let selectedEnvelope = try container.decodeIfPresent(
            ForgeCompactExecutionEnvelope.self,
            forKey: .selectedEnvelope
        )
        let candidateVerdicts = try container.decode(
            [ForgeCompactCandidateVerdict].self,
            forKey: .candidateVerdicts
        )
        let evaluatedEnvelopes = try container.decode(
            [ForgeCompactExecutionEnvelope].self,
            forKey: .evaluatedEnvelopes
        )

        guard Self.hasBasicActionShape(action: action, selectedEnvelope: selectedEnvelope) else {
            throw ForgeCompactDecisionArchiveError.invalidShape
        }

        self.schemaVersion = schemaVersion
        self.snapshot = snapshot
        self.policy = policy
        self.action = action
        self.selectedEnvelope = selectedEnvelope
        self.candidateVerdicts = candidateVerdicts
        self.evaluatedEnvelopes = evaluatedEnvelopes
    }

    public func restore(
        qualificationGrants: Set<ForgeCompactQualificationGrant>
    ) throws -> ForgeCompactDecisionReceipt {
        let refreshed = ForgeCompactGovernor.decide(
            snapshot: snapshot,
            policy: policy,
            envelopes: evaluatedEnvelopes,
            qualificationGrants: qualificationGrants
        )
        guard refreshed.action == action,
              refreshed.selectedEnvelope == selectedEnvelope,
              refreshed.candidateVerdicts == candidateVerdicts,
              refreshed.evaluatedEnvelopes == evaluatedEnvelopes
        else {
            throw ForgeCompactDecisionArchiveError.freshQualificationRequired
        }
        return refreshed
    }

    private static func hasBasicActionShape(
        action: ForgeCompactDecisionAction,
        selectedEnvelope: ForgeCompactExecutionEnvelope?
    ) -> Bool {
        switch action {
        case .keep(let envelopeID), .switchTo(let envelopeID):
            return selectedEnvelope?.id == envelopeID
        case .suspend, .block:
            return selectedEnvelope == nil
        }
    }
}

public enum ForgeCompactGovernor {
    public static func decide(
        snapshot: ForgeCompactRuntimeSnapshot,
        policy: ForgeCompactGovernorPolicy,
        envelopes: [ForgeCompactExecutionEnvelope],
        qualificationGrants: Set<ForgeCompactQualificationGrant>
    ) -> ForgeCompactDecisionReceipt {
        if !isValid(snapshot) {
            return .init(
                snapshot: snapshot,
                policy: policy,
                action: .block(reason: .invalidRuntimeSnapshot),
                selectedEnvelope: nil,
                candidateVerdicts: [],
                evaluatedEnvelopes: envelopes
            )
        }

        if !policy.isValid {
            return .init(
                snapshot: snapshot,
                policy: policy,
                action: .block(reason: .invalidPolicy),
                selectedEnvelope: nil,
                candidateVerdicts: [],
                evaluatedEnvelopes: envelopes
            )
        }

        if snapshot.memoryPressure.rank >= policy.suspendAtMemoryPressure.rank {
            return .init(
                snapshot: snapshot,
                policy: policy,
                action: .suspend(reason: .memoryPressureThresholdReached),
                selectedEnvelope: nil,
                candidateVerdicts: [],
                evaluatedEnvelopes: envelopes
            )
        }

        if snapshot.thermalPressure.rank >= policy.suspendAtThermalPressure.rank {
            return .init(
                snapshot: snapshot,
                policy: policy,
                action: .suspend(reason: .thermalPressureThresholdReached),
                selectedEnvelope: nil,
                candidateVerdicts: [],
                evaluatedEnvelopes: envelopes
            )
        }

        let duplicateIDs = duplicateEnvelopeIDs(in: envelopes)
        let reserveBytes = policy.reserveBytes(for: snapshot.memoryPressure)
        let verdicts = envelopes
            .map { envelope in
                verdict(
                    for: envelope,
                    snapshot: snapshot,
                    policy: policy,
                    reserveBytes: reserveBytes,
                    isDuplicate: duplicateIDs.contains(envelope.id),
                    qualificationGrants: qualificationGrants
                )
            }
            .sorted { lhs, rhs in
                if lhs.envelopeID != rhs.envelopeID { return lhs.envelopeID < rhs.envelopeID }
                return lhs.rejectionReasons.lexicographicallyPrecedes(rhs.rejectionReasons) {
                    $0.rawValue < $1.rawValue
                }
            }

        let eligibleIDs = Set(verdicts.filter(\.isEligible).map(\.envelopeID))
        let eligible = envelopes.filter { eligibleIDs.contains($0.id) }

        if let activeEnvelopeID = snapshot.activeEnvelopeID,
           let active = eligible.first(where: { $0.id == activeEnvelopeID }) {
            return .init(
                snapshot: snapshot,
                policy: policy,
                action: .keep(envelopeID: activeEnvelopeID),
                selectedEnvelope: active,
                candidateVerdicts: verdicts,
                evaluatedEnvelopes: envelopes
            )
        }

        guard let selected = eligible.sorted(by: preferredEnvelopeOrder).first else {
            return .init(
                snapshot: snapshot,
                policy: policy,
                action: .block(reason: .noEligibleLocalEnvelope),
                selectedEnvelope: nil,
                candidateVerdicts: verdicts,
                evaluatedEnvelopes: envelopes
            )
        }

        return .init(
            snapshot: snapshot,
            policy: policy,
            action: .switchTo(envelopeID: selected.id),
            selectedEnvelope: selected,
            candidateVerdicts: verdicts,
            evaluatedEnvelopes: envelopes
        )
    }

    private static func isValid(_ snapshot: ForgeCompactRuntimeSnapshot) -> Bool {
        hasCanonicalIdentity(snapshot.deviceProfileID)
            && (snapshot.activeEnvelopeID.map(hasCanonicalIdentity) ?? true)
            && snapshot.requestedContextTokens > 0
            && snapshot.minimumMissionContextTokens > 0
            && snapshot.minimumMissionContextTokens <= snapshot.requestedContextTokens
            && snapshot.memoryBudgetBytes > 0
    }

    private static func duplicateEnvelopeIDs(
        in envelopes: [ForgeCompactExecutionEnvelope]
    ) -> Set<String> {
        var seen = Set<String>()
        var duplicates = Set<String>()
        for envelope in envelopes where !seen.insert(envelope.id).inserted {
            duplicates.insert(envelope.id)
        }
        return duplicates
    }

    private static func verdict(
        for envelope: ForgeCompactExecutionEnvelope,
        snapshot: ForgeCompactRuntimeSnapshot,
        policy: ForgeCompactGovernorPolicy,
        reserveBytes: UInt64,
        isDuplicate: Bool,
        qualificationGrants: Set<ForgeCompactQualificationGrant>
    ) -> ForgeCompactCandidateVerdict {
        var reasons: [ForgeCompactCandidateRejectionReason] = []
        let canonicalIdentity = hasCanonicalIdentity(envelope)

        if isDuplicate { reasons.append(.duplicateEnvelopeID) }
        if !canonicalIdentity { reasons.append(.invalidIdentity) }
        if envelope.computeLocation != .local { reasons.append(.nonLocalCompute) }

        switch envelope.evidenceStatus {
        case .exactDeviceMeasured:
            break
        case .experimentalExactDeviceMeasured:
            if policy.operatingMode != .research { reasons.append(.experimentalDisallowed) }
        case .unverified:
            reasons.append(.unverifiedEvidence)
        }

        if canonicalIdentity,
           envelope.computeLocation == .local,
           envelope.evidenceStatus != .unverified,
           !qualificationGrants.contains(where: { $0.matches(envelope) }) {
            reasons.append(.qualificationGrantMissing)
        }

        if envelope.deviceProfileID != snapshot.deviceProfileID {
            reasons.append(.deviceProfileMismatch)
        }
        if envelope.contextTokens < snapshot.minimumMissionContextTokens {
            reasons.append(.contextBelowMissionMinimum)
        }
        if envelope.contextTokens > snapshot.requestedContextTokens {
            reasons.append(.contextExceedsRequest)
        }
        if envelope.observedPeakResidentBytes == 0 {
            reasons.append(.invalidPeakMemoryMeasurement)
        } else if !hasMeasuredHeadroom(
            peakResidentBytes: envelope.observedPeakResidentBytes,
            memoryBudgetBytes: snapshot.memoryBudgetBytes,
            reserveBytes: reserveBytes
        ) {
            reasons.append(.insufficientMeasuredHeadroom)
        }

        return .init(
            envelopeID: envelope.id,
            rejectionReasons: Array(Set(reasons)).sorted { $0.rawValue < $1.rawValue }
        )
    }

    private static func hasMeasuredHeadroom(
        peakResidentBytes: UInt64,
        memoryBudgetBytes: UInt64,
        reserveBytes: UInt64
    ) -> Bool {
        guard memoryBudgetBytes >= reserveBytes else { return false }
        return peakResidentBytes <= memoryBudgetBytes - reserveBytes
    }

    private static func preferredEnvelopeOrder(
        _ lhs: ForgeCompactExecutionEnvelope,
        _ rhs: ForgeCompactExecutionEnvelope
    ) -> Bool {
        if lhs.contextTokens != rhs.contextTokens { return lhs.contextTokens > rhs.contextTokens }
        if lhs.observedPeakResidentBytes != rhs.observedPeakResidentBytes {
            return lhs.observedPeakResidentBytes < rhs.observedPeakResidentBytes
        }
        return lhs.id < rhs.id
    }

    fileprivate static func hasCanonicalIdentity(_ envelope: ForgeCompactExecutionEnvelope) -> Bool {
        hasCanonicalIdentity(envelope.id)
            && hasCanonicalIdentity(envelope.profileID)
            && hasCanonicalIdentity(envelope.configurationBindingID)
            && hasCanonicalIdentity(envelope.deviceProfileID)
            && hasCanonicalIdentity(envelope.evidenceReceiptID)
    }

    fileprivate static func hasCanonicalIdentity(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 512
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
}
