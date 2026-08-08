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

/// Production never auto-admits research-only envelopes. Research mode must be opted into.
public enum ForgeCompactOperatingMode: String, Codable, Hashable, Sendable {
    case production
    case research
}

/// Forge Compact is a local inference governor. Remote compute is represented only so an
/// accidental hosted candidate can be rejected explicitly instead of becoming a fallback.
public enum ForgeCompactComputeLocation: String, Codable, Hashable, Sendable {
    case local
    case remote
}

/// Qualification status is asserted by the external compatibility/evidence authority.
/// ForgeCompactCore does not mint model support, device compatibility, or benchmark truth.
public enum ForgeCompactEvidenceStatus: String, Codable, Hashable, Sendable {
    /// A durable receipt covers this exact execution envelope on this exact device profile.
    case exactDeviceMeasured
    /// Exact-device experiment exists, but the envelope is still research-only.
    case experimentalExactDeviceMeasured
    /// Source metadata, estimates, or missing/stale evidence cannot be treated as measured proof.
    case unverified
}

/// One externally-qualified local execution option. The binding and receipt identifiers are opaque:
/// the authority that creates them owns the exact model/revision/tokenizer/runtime/quant/KV/context/
/// device/OS tuple and its measurement provenance.
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

/// Live inputs for one deterministic governor decision. `memoryBudgetBytes` is the host's
/// current safe process budget after observing memory availability and pressure; it is not a
/// physical-RAM claim and is intentionally compared with measured peak resident usage.
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

/// Headroom is explicit product policy rather than a hidden device claim. Warning pressure may
/// reserve more memory than nominal pressure, causing a measured lower-footprint envelope to win.
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

    fileprivate var isValid: Bool {
        warningReserveBytes >= nominalReserveBytes
    }

    fileprivate func reserveBytes(for pressure: ForgeCompactMemoryPressure) -> UInt64 {
        switch pressure {
        case .nominal:
            nominalReserveBytes
        case .warning, .critical:
            warningReserveBytes
        }
    }
}

public enum ForgeCompactCandidateRejectionReason: String, CaseIterable, Codable, Hashable, Sendable {
    case duplicateEnvelopeID
    case invalidIdentity
    case nonLocalCompute
    case unverifiedEvidence
    case experimentalDisallowed
    case deviceProfileMismatch
    case contextBelowMissionMinimum
    case contextExceedsRequest
    case invalidPeakMemoryMeasurement
    case insufficientMeasuredHeadroom
}

/// Stable per-candidate evidence for why a decision did or did not admit an envelope.
public struct ForgeCompactCandidateVerdict: Codable, Equatable, Sendable {
    public let envelopeID: String
    public let rejectionReasons: [ForgeCompactCandidateRejectionReason]

    public init(
        envelopeID: String,
        rejectionReasons: [ForgeCompactCandidateRejectionReason]
    ) {
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

/// Durable, serializable proof of a deterministic policy decision. It is not a benchmark receipt;
/// it preserves the exact selected envelope and therefore the opaque configuration + qualification
/// receipt bindings that the external evidence authority supplied at decision time.
///
/// Decode replays the selected envelope through the current deterministic governor so persisted
/// bytes cannot swap/remove an accepted evidence binding while leaving the stored action intact.
public struct ForgeCompactDecisionReceipt: Codable, Equatable, Sendable {
    public let snapshot: ForgeCompactRuntimeSnapshot
    public let policy: ForgeCompactGovernorPolicy
    public let action: ForgeCompactDecisionAction
    public let selectedEnvelope: ForgeCompactExecutionEnvelope?
    public let candidateVerdicts: [ForgeCompactCandidateVerdict]

    init(
        snapshot: ForgeCompactRuntimeSnapshot,
        policy: ForgeCompactGovernorPolicy,
        action: ForgeCompactDecisionAction,
        selectedEnvelope: ForgeCompactExecutionEnvelope?,
        candidateVerdicts: [ForgeCompactCandidateVerdict]
    ) {
        self.snapshot = snapshot
        self.policy = policy
        self.action = action
        self.selectedEnvelope = selectedEnvelope
        self.candidateVerdicts = candidateVerdicts
    }

    private enum CodingKeys: String, CodingKey {
        case snapshot, policy, action, selectedEnvelope, candidateVerdicts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
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

        guard Self.isDecodedStateConsistent(
            snapshot: snapshot,
            policy: policy,
            action: action,
            selectedEnvelope: selectedEnvelope,
            candidateVerdicts: candidateVerdicts
        ) else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Forge Compact decision receipt is inconsistent with the deterministic governor."
                )
            )
        }

        self.init(
            snapshot: snapshot,
            policy: policy,
            action: action,
            selectedEnvelope: selectedEnvelope,
            candidateVerdicts: candidateVerdicts
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(snapshot, forKey: .snapshot)
        try container.encode(policy, forKey: .policy)
        try container.encode(action, forKey: .action)
        try container.encodeIfPresent(selectedEnvelope, forKey: .selectedEnvelope)
        try container.encode(candidateVerdicts, forKey: .candidateVerdicts)
    }

    private static func isDecodedStateConsistent(
        snapshot: ForgeCompactRuntimeSnapshot,
        policy: ForgeCompactGovernorPolicy,
        action: ForgeCompactDecisionAction,
        selectedEnvelope: ForgeCompactExecutionEnvelope?,
        candidateVerdicts: [ForgeCompactCandidateVerdict]
    ) -> Bool {
        switch action {
        case .keep(let envelopeID), .switchTo(let envelopeID):
            guard let selectedEnvelope,
                  selectedEnvelope.id == envelopeID
            else {
                return false
            }

            let selectedVerdicts = candidateVerdicts.filter { $0.envelopeID == envelopeID }
            guard selectedVerdicts.count == 1,
                  selectedVerdicts[0].isEligible
            else {
                return false
            }

            let replay = ForgeCompactGovernor.decide(
                snapshot: snapshot,
                policy: policy,
                envelopes: [selectedEnvelope]
            )
            return replay.action == action && replay.selectedEnvelope == selectedEnvelope

        case .suspend:
            guard selectedEnvelope == nil,
                  candidateVerdicts.isEmpty
            else {
                return false
            }
            let replay = ForgeCompactGovernor.decide(
                snapshot: snapshot,
                policy: policy,
                envelopes: []
            )
            return replay.action == action

        case .block(let reason):
            guard selectedEnvelope == nil else { return false }
            switch reason {
            case .invalidRuntimeSnapshot, .invalidPolicy:
                guard candidateVerdicts.isEmpty else { return false }
            case .noEligibleLocalEnvelope:
                guard !candidateVerdicts.contains(where: \.isEligible) else { return false }
            }
            let replay = ForgeCompactGovernor.decide(
                snapshot: snapshot,
                policy: policy,
                envelopes: []
            )
            return replay.action == action
        }
    }
}

/// Pure policy engine for pressure-aware local execution selection.
///
/// Safety boundaries:
/// - remote compute is never selected;
/// - production accepts only externally asserted exact-device measured evidence;
/// - context never drops below the mission minimum;
/// - critical/configured pressure fails closed by suspending;
/// - no eligible envelope blocks rather than guessing or silently escalating to cloud.
public enum ForgeCompactGovernor {
    public static func decide(
        snapshot: ForgeCompactRuntimeSnapshot,
        policy: ForgeCompactGovernorPolicy,
        envelopes: [ForgeCompactExecutionEnvelope]
    ) -> ForgeCompactDecisionReceipt {
        guard isValid(snapshot) else {
            return .init(
                snapshot: snapshot,
                policy: policy,
                action: .block(reason: .invalidRuntimeSnapshot),
                selectedEnvelope: nil,
                candidateVerdicts: []
            )
        }

        guard policy.isValid else {
            return .init(
                snapshot: snapshot,
                policy: policy,
                action: .block(reason: .invalidPolicy),
                selectedEnvelope: nil,
                candidateVerdicts: []
            )
        }

        if snapshot.memoryPressure.rank >= policy.suspendAtMemoryPressure.rank {
            return .init(
                snapshot: snapshot,
                policy: policy,
                action: .suspend(reason: .memoryPressureThresholdReached),
                selectedEnvelope: nil,
                candidateVerdicts: []
            )
        }

        if snapshot.thermalPressure.rank >= policy.suspendAtThermalPressure.rank {
            return .init(
                snapshot: snapshot,
                policy: policy,
                action: .suspend(reason: .thermalPressureThresholdReached),
                selectedEnvelope: nil,
                candidateVerdicts: []
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
                    isDuplicate: duplicateIDs.contains(envelope.id)
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
           let activeEnvelope = eligible.first(where: { $0.id == activeEnvelopeID })
        {
            return .init(
                snapshot: snapshot,
                policy: policy,
                action: .keep(envelopeID: activeEnvelopeID),
                selectedEnvelope: activeEnvelope,
                candidateVerdicts: verdicts
            )
        }

        guard let selected = eligible.sorted(by: preferredEnvelopeOrder).first else {
            return .init(
                snapshot: snapshot,
                policy: policy,
                action: .block(reason: .noEligibleLocalEnvelope),
                selectedEnvelope: nil,
                candidateVerdicts: verdicts
            )
        }

        return .init(
            snapshot: snapshot,
            policy: policy,
            action: .switchTo(envelopeID: selected.id),
            selectedEnvelope: selected,
            candidateVerdicts: verdicts
        )
    }

    private static func isValid(_ snapshot: ForgeCompactRuntimeSnapshot) -> Bool {
        isCanonicalIdentity(snapshot.deviceProfileID)
            && snapshot.activeEnvelopeID.map(isCanonicalIdentity) ?? true
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
        for envelope in envelopes {
            if !seen.insert(envelope.id).inserted {
                duplicates.insert(envelope.id)
            }
        }
        return duplicates
    }

    private static func verdict(
        for envelope: ForgeCompactExecutionEnvelope,
        snapshot: ForgeCompactRuntimeSnapshot,
        policy: ForgeCompactGovernorPolicy,
        reserveBytes: UInt64,
        isDuplicate: Bool
    ) -> ForgeCompactCandidateVerdict {
        var reasons: [ForgeCompactCandidateRejectionReason] = []

        if isDuplicate {
            reasons.append(.duplicateEnvelopeID)
        }

        if !isCanonicalIdentity(envelope.id)
            || !isCanonicalIdentity(envelope.profileID)
            || !isCanonicalIdentity(envelope.configurationBindingID)
            || !isCanonicalIdentity(envelope.deviceProfileID)
            || !isCanonicalIdentity(envelope.evidenceReceiptID)
        {
            reasons.append(.invalidIdentity)
        }

        if envelope.computeLocation != .local {
            reasons.append(.nonLocalCompute)
        }

        switch envelope.evidenceStatus {
        case .exactDeviceMeasured:
            break
        case .experimentalExactDeviceMeasured:
            if policy.operatingMode != .research {
                reasons.append(.experimentalDisallowed)
            }
        case .unverified:
            reasons.append(.unverifiedEvidence)
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
        if lhs.contextTokens != rhs.contextTokens {
            return lhs.contextTokens > rhs.contextTokens
        }
        if lhs.observedPeakResidentBytes != rhs.observedPeakResidentBytes {
            return lhs.observedPeakResidentBytes < rhs.observedPeakResidentBytes
        }
        return lhs.id < rhs.id
    }

    private static func isCanonicalIdentity(_ value: String) -> Bool {
        guard let normalized = normalized(value) else { return false }
        return normalized == value
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}
