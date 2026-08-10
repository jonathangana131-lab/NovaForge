import Foundation

public enum ForgeAutonomyValidationError: Error, Equatable, Sendable {
    case invalidIdentifier(field: String)
    case invalidRevision(field: String)
    case invalidBudget(field: String)
    case budgetExceedsSafetyEnvelope(field: String)
    case invalidCheckpointLead(field: String)
    case invalidObservationGeneration
    case invalidCheckpointGeneration
    case forgedProjection
}

public enum ForgeThermalPressure: String, Codable, CaseIterable, Sendable {
    case nominal
    case fair
    case serious
    case critical
}

public enum ForgeMemoryPressure: String, Codable, CaseIterable, Sendable {
    case nominal
    case warning
    case critical
}

public enum ForgeUserDirective: String, Codable, CaseIterable, Sendable {
    case none
    case pause
    case cancel
}

/// Candidate identity for one accepted Mission state.
///
/// This public/Codable value is deliberately *not* Mission execution authority. A future canonical
/// adapter must authenticate it against accepted Mission/checkpoint state before any candidate policy
/// projection can influence scheduling.
public struct ForgeAutonomyAuthority: Codable, Equatable, Sendable {
    public let projectID: String
    public let missionID: String
    public let checkpointID: String
    public let missionRevision: UInt64
    public let authorityEpoch: UInt64

    public init(
        projectID: String,
        missionID: String,
        checkpointID: String,
        missionRevision: UInt64,
        authorityEpoch: UInt64
    ) throws {
        try Self.validateIdentifier(projectID, field: "projectID")
        try Self.validateIdentifier(missionID, field: "missionID")
        try Self.validateIdentifier(checkpointID, field: "checkpointID")
        guard missionRevision > 0 else {
            throw ForgeAutonomyValidationError.invalidRevision(field: "missionRevision")
        }
        guard authorityEpoch > 0 else {
            throw ForgeAutonomyValidationError.invalidRevision(field: "authorityEpoch")
        }
        self.projectID = projectID
        self.missionID = missionID
        self.checkpointID = checkpointID
        self.missionRevision = missionRevision
        self.authorityEpoch = authorityEpoch
    }

    private enum CodingKeys: String, CodingKey {
        case projectID, missionID, checkpointID, missionRevision, authorityEpoch
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            projectID: container.decode(String.self, forKey: .projectID),
            missionID: container.decode(String.self, forKey: .missionID),
            checkpointID: container.decode(String.self, forKey: .checkpointID),
            missionRevision: container.decode(UInt64.self, forKey: .missionRevision),
            authorityEpoch: container.decode(UInt64.self, forKey: .authorityEpoch)
        )
    }

    fileprivate static func validateIdentifier(_ value: String, field: String) throws {
        guard !value.isEmpty,
              value.utf8.count <= 128,
              value.trimmingCharacters(in: .whitespacesAndNewlines) == value,
              value.unicodeScalars.allSatisfy({ scalar in
                  CharacterSet.alphanumerics.contains(scalar) || "-_.".unicodeScalars.contains(scalar)
              }) else {
            throw ForgeAutonomyValidationError.invalidIdentifier(field: field)
        }
    }
}

/// User/host policy *candidate* for one autonomous Mission authority epoch.
///
/// Values are bounded twice: by the user's chosen policy and by conservative package safety
/// envelopes. This prevents `UInt64.max` (or similarly giant values) from silently converting a
/// supposedly bounded policy into a practical no-limit policy. The future trusted policy adapter may
/// choose smaller values but may not interpret this public/Codable object as authenticated policy.
public struct ForgeAutonomyBudget: Codable, Equatable, Sendable {
    public static let maximumAllowedElapsedMilliseconds: UInt64 = 86_400_000 // 24 hours / authority epoch
    public static let maximumAllowedActions: UInt64 = 1_000_000
    public static let maximumAllowedRepairAttemptsPerDefect: UInt64 = 10_000
    public static let maximumAllowedConsecutiveNonProgressActions: UInt64 = 100_000

    public let policyRevision: UInt64
    public let maximumElapsedMilliseconds: UInt64
    public let maximumActions: UInt64
    public let maximumRepairAttemptsPerDefect: UInt64
    public let maximumConsecutiveNonProgressActions: UInt64
    public let checkpointLeadMilliseconds: UInt64
    public let checkpointLeadActions: UInt64

    public init(
        policyRevision: UInt64,
        maximumElapsedMilliseconds: UInt64,
        maximumActions: UInt64,
        maximumRepairAttemptsPerDefect: UInt64,
        maximumConsecutiveNonProgressActions: UInt64,
        checkpointLeadMilliseconds: UInt64,
        checkpointLeadActions: UInt64
    ) throws {
        guard policyRevision > 0 else {
            throw ForgeAutonomyValidationError.invalidRevision(field: "policyRevision")
        }
        try Self.validatePositiveBound(
            maximumElapsedMilliseconds,
            maximum: Self.maximumAllowedElapsedMilliseconds,
            field: "maximumElapsedMilliseconds"
        )
        try Self.validatePositiveBound(
            maximumActions,
            maximum: Self.maximumAllowedActions,
            field: "maximumActions"
        )
        try Self.validatePositiveBound(
            maximumRepairAttemptsPerDefect,
            maximum: Self.maximumAllowedRepairAttemptsPerDefect,
            field: "maximumRepairAttemptsPerDefect"
        )
        try Self.validatePositiveBound(
            maximumConsecutiveNonProgressActions,
            maximum: Self.maximumAllowedConsecutiveNonProgressActions,
            field: "maximumConsecutiveNonProgressActions"
        )
        guard checkpointLeadMilliseconds < maximumElapsedMilliseconds else {
            throw ForgeAutonomyValidationError.invalidCheckpointLead(field: "checkpointLeadMilliseconds")
        }
        guard checkpointLeadActions < maximumActions else {
            throw ForgeAutonomyValidationError.invalidCheckpointLead(field: "checkpointLeadActions")
        }

        self.policyRevision = policyRevision
        self.maximumElapsedMilliseconds = maximumElapsedMilliseconds
        self.maximumActions = maximumActions
        self.maximumRepairAttemptsPerDefect = maximumRepairAttemptsPerDefect
        self.maximumConsecutiveNonProgressActions = maximumConsecutiveNonProgressActions
        self.checkpointLeadMilliseconds = checkpointLeadMilliseconds
        self.checkpointLeadActions = checkpointLeadActions
    }

    private enum CodingKeys: String, CodingKey {
        case policyRevision
        case maximumElapsedMilliseconds
        case maximumActions
        case maximumRepairAttemptsPerDefect
        case maximumConsecutiveNonProgressActions
        case checkpointLeadMilliseconds
        case checkpointLeadActions
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            policyRevision: container.decode(UInt64.self, forKey: .policyRevision),
            maximumElapsedMilliseconds: container.decode(UInt64.self, forKey: .maximumElapsedMilliseconds),
            maximumActions: container.decode(UInt64.self, forKey: .maximumActions),
            maximumRepairAttemptsPerDefect: container.decode(UInt64.self, forKey: .maximumRepairAttemptsPerDefect),
            maximumConsecutiveNonProgressActions: container.decode(UInt64.self, forKey: .maximumConsecutiveNonProgressActions),
            checkpointLeadMilliseconds: container.decode(UInt64.self, forKey: .checkpointLeadMilliseconds),
            checkpointLeadActions: container.decode(UInt64.self, forKey: .checkpointLeadActions)
        )
    }

    private static func validatePositiveBound(
        _ value: UInt64,
        maximum: UInt64,
        field: String
    ) throws {
        guard value > 0 else {
            throw ForgeAutonomyValidationError.invalidBudget(field: field)
        }
        guard value <= maximum else {
            throw ForgeAutonomyValidationError.budgetExceedsSafetyEnvelope(field: field)
        }
    }
}

/// Exact durable-checkpoint identity observed by the host candidate feed.
///
/// This value replaces the former bare `hasFreshCheckpoint` Bool. It is still public/Codable
/// candidate data, so the evaluator only compares identities; it does not authenticate the receipt.
public struct ForgeAutonomyCheckpointObservation: Codable, Equatable, Sendable {
    public let projectID: String
    public let missionID: String
    public let checkpointID: String
    public let missionRevision: UInt64
    public let authorityEpoch: UInt64
    public let capturedAtObservationGeneration: UInt64

    public init(
        projectID: String,
        missionID: String,
        checkpointID: String,
        missionRevision: UInt64,
        authorityEpoch: UInt64,
        capturedAtObservationGeneration: UInt64
    ) throws {
        try ForgeAutonomyAuthority.validateIdentifier(projectID, field: "checkpoint.projectID")
        try ForgeAutonomyAuthority.validateIdentifier(missionID, field: "checkpoint.missionID")
        try ForgeAutonomyAuthority.validateIdentifier(checkpointID, field: "checkpoint.checkpointID")
        guard missionRevision > 0 else {
            throw ForgeAutonomyValidationError.invalidRevision(field: "checkpoint.missionRevision")
        }
        guard authorityEpoch > 0 else {
            throw ForgeAutonomyValidationError.invalidRevision(field: "checkpoint.authorityEpoch")
        }
        guard capturedAtObservationGeneration > 0 else {
            throw ForgeAutonomyValidationError.invalidCheckpointGeneration
        }
        self.projectID = projectID
        self.missionID = missionID
        self.checkpointID = checkpointID
        self.missionRevision = missionRevision
        self.authorityEpoch = authorityEpoch
        self.capturedAtObservationGeneration = capturedAtObservationGeneration
    }

    private enum CodingKeys: String, CodingKey {
        case projectID, missionID, checkpointID, missionRevision, authorityEpoch
        case capturedAtObservationGeneration
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            projectID: container.decode(String.self, forKey: .projectID),
            missionID: container.decode(String.self, forKey: .missionID),
            checkpointID: container.decode(String.self, forKey: .checkpointID),
            missionRevision: container.decode(UInt64.self, forKey: .missionRevision),
            authorityEpoch: container.decode(UInt64.self, forKey: .authorityEpoch),
            capturedAtObservationGeneration: container.decode(UInt64.self, forKey: .capturedAtObservationGeneration)
        )
    }

    fileprivate func exactlyMatches(
        _ authority: ForgeAutonomyAuthority,
        at observationGeneration: UInt64
    ) -> Bool {
        projectID == authority.projectID
            && missionID == authority.missionID
            && checkpointID == authority.checkpointID
            && missionRevision == authority.missionRevision
            && authorityEpoch == authority.authorityEpoch
            && capturedAtObservationGeneration == observationGeneration
    }
}

/// One public/Codable host-observation *candidate* sampled immediately before another possible action.
///
/// `observationGeneration` and `lastConsumedObservationGeneration` provide explicit monotonic cursor
/// semantics. The candidate evaluator rejects replay/already-consumed generations. A production
/// scheduler must still obtain both values from trusted host state; callers can forge this public
/// transport, which is why the result of this package is never execution authority.
public struct ForgeAutonomyObservation: Codable, Equatable, Sendable {
    public let observationGeneration: UInt64
    public let lastConsumedObservationGeneration: UInt64
    public let elapsedMilliseconds: UInt64
    public let actionsUsed: UInt64
    public let repairAttemptsForCurrentDefect: UInt64
    public let consecutiveNonProgressActions: UInt64
    public let thermalPressure: ForgeThermalPressure
    public let memoryPressure: ForgeMemoryPressure
    public let userDirective: ForgeUserDirective
    public let hasUnresolvedMaterialDecision: Bool
    public let hasPendingPolicyApproval: Bool
    public let hasExternalBlocker: Bool
    public let latestDurableCheckpoint: ForgeAutonomyCheckpointObservation?

    public init(
        observationGeneration: UInt64,
        lastConsumedObservationGeneration: UInt64,
        elapsedMilliseconds: UInt64,
        actionsUsed: UInt64,
        repairAttemptsForCurrentDefect: UInt64,
        consecutiveNonProgressActions: UInt64,
        thermalPressure: ForgeThermalPressure,
        memoryPressure: ForgeMemoryPressure,
        userDirective: ForgeUserDirective,
        hasUnresolvedMaterialDecision: Bool,
        hasPendingPolicyApproval: Bool,
        hasExternalBlocker: Bool,
        latestDurableCheckpoint: ForgeAutonomyCheckpointObservation?
    ) throws {
        guard observationGeneration > 0,
              observationGeneration > lastConsumedObservationGeneration else {
            throw ForgeAutonomyValidationError.invalidObservationGeneration
        }
        if let latestDurableCheckpoint,
           latestDurableCheckpoint.capturedAtObservationGeneration > observationGeneration {
            throw ForgeAutonomyValidationError.invalidCheckpointGeneration
        }
        self.observationGeneration = observationGeneration
        self.lastConsumedObservationGeneration = lastConsumedObservationGeneration
        self.elapsedMilliseconds = elapsedMilliseconds
        self.actionsUsed = actionsUsed
        self.repairAttemptsForCurrentDefect = repairAttemptsForCurrentDefect
        self.consecutiveNonProgressActions = consecutiveNonProgressActions
        self.thermalPressure = thermalPressure
        self.memoryPressure = memoryPressure
        self.userDirective = userDirective
        self.hasUnresolvedMaterialDecision = hasUnresolvedMaterialDecision
        self.hasPendingPolicyApproval = hasPendingPolicyApproval
        self.hasExternalBlocker = hasExternalBlocker
        self.latestDurableCheckpoint = latestDurableCheckpoint
    }

    private enum CodingKeys: String, CodingKey {
        case observationGeneration, lastConsumedObservationGeneration
        case elapsedMilliseconds, actionsUsed, repairAttemptsForCurrentDefect
        case consecutiveNonProgressActions, thermalPressure, memoryPressure, userDirective
        case hasUnresolvedMaterialDecision, hasPendingPolicyApproval, hasExternalBlocker
        case latestDurableCheckpoint
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            observationGeneration: container.decode(UInt64.self, forKey: .observationGeneration),
            lastConsumedObservationGeneration: container.decode(UInt64.self, forKey: .lastConsumedObservationGeneration),
            elapsedMilliseconds: container.decode(UInt64.self, forKey: .elapsedMilliseconds),
            actionsUsed: container.decode(UInt64.self, forKey: .actionsUsed),
            repairAttemptsForCurrentDefect: container.decode(UInt64.self, forKey: .repairAttemptsForCurrentDefect),
            consecutiveNonProgressActions: container.decode(UInt64.self, forKey: .consecutiveNonProgressActions),
            thermalPressure: container.decode(ForgeThermalPressure.self, forKey: .thermalPressure),
            memoryPressure: container.decode(ForgeMemoryPressure.self, forKey: .memoryPressure),
            userDirective: container.decode(ForgeUserDirective.self, forKey: .userDirective),
            hasUnresolvedMaterialDecision: container.decode(Bool.self, forKey: .hasUnresolvedMaterialDecision),
            hasPendingPolicyApproval: container.decode(Bool.self, forKey: .hasPendingPolicyApproval),
            hasExternalBlocker: container.decode(Bool.self, forKey: .hasExternalBlocker),
            latestDurableCheckpoint: container.decodeIfPresent(ForgeAutonomyCheckpointObservation.self, forKey: .latestDurableCheckpoint)
        )
    }

    fileprivate func hasExactFreshCheckpoint(for authority: ForgeAutonomyAuthority) -> Bool {
        latestDurableCheckpoint?.exactlyMatches(
            authority,
            at: observationGeneration
        ) == true
    }
}

public enum ForgeAutonomyDisposition: String, Codable, CaseIterable, Sendable {
    /// Candidate policy says another bounded action could be considered.
    case proceed
    /// Candidate policy says checkpoint before considering another action.
    case checkpointThenProceed
    /// Candidate policy says reduce optional work/resource intensity and checkpoint first.
    case degradeThenProceed
    /// Candidate policy says autonomous work should stop until the blocking condition changes.
    case pause
    /// Candidate policy reflects an observed user cancellation request.
    case cancel
}

public enum ForgeAutonomyReason: String, Codable, CaseIterable, Sendable {
    case withinBudget
    case userCancelled
    case userPaused
    case unresolvedMaterialDecision
    case pendingPolicyApproval
    case externalBlocker
    case thermalCritical
    case memoryCritical
    case elapsedBudgetExhausted
    case actionBudgetExhausted
    case repairEscalationRequired
    case noProgressEscalationRequired
    case thermalSerious
    case memoryWarning
    case elapsedBudgetNearLimit
    case actionBudgetNearLimit
}

public enum ForgeAutonomyProjectionAuthority: String, Codable, CaseIterable, Sendable {
    /// Public inputs are caller-mintable; this result can never schedule work by itself.
    case candidateOnly
}

/// Deterministic **candidate-only** policy projection over public/Codable inputs.
///
/// This replaces the former public `ForgeAutonomyDecision.evaluate(...)` execution-looking API.
/// A decoded projection re-runs the candidate evaluator for semantic integrity, but even a valid
/// `.proceed` projection is not Mission/policy/host authority and must never schedule an action.
/// Stale serialized projections may be inspected as history; live scheduling must re-observe trusted
/// current state and use a future authority-bearing adapter outside this candidate API.
public struct ForgeAutonomyCandidateProjection: Codable, Equatable, Sendable {
    public let authority: ForgeAutonomyAuthority
    public let budget: ForgeAutonomyBudget
    public let observation: ForgeAutonomyObservation
    public let disposition: ForgeAutonomyDisposition
    public let reason: ForgeAutonomyReason
    public let requiresCheckpoint: Bool
    public let consumesObservationGeneration: UInt64
    public let projectionAuthority: ForgeAutonomyProjectionAuthority

    public var authorizesExecution: Bool { false }

    fileprivate init(
        authority: ForgeAutonomyAuthority,
        budget: ForgeAutonomyBudget,
        observation: ForgeAutonomyObservation,
        disposition: ForgeAutonomyDisposition,
        reason: ForgeAutonomyReason,
        requiresCheckpoint: Bool
    ) {
        self.authority = authority
        self.budget = budget
        self.observation = observation
        self.disposition = disposition
        self.reason = reason
        self.requiresCheckpoint = requiresCheckpoint
        self.consumesObservationGeneration = observation.observationGeneration
        self.projectionAuthority = .candidateOnly
    }

    private enum CodingKeys: String, CodingKey {
        case authority, budget, observation, disposition, reason, requiresCheckpoint
        case consumesObservationGeneration, projectionAuthority
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let authority = try container.decode(ForgeAutonomyAuthority.self, forKey: .authority)
        let budget = try container.decode(ForgeAutonomyBudget.self, forKey: .budget)
        let observation = try container.decode(ForgeAutonomyObservation.self, forKey: .observation)
        let disposition = try container.decode(ForgeAutonomyDisposition.self, forKey: .disposition)
        let reason = try container.decode(ForgeAutonomyReason.self, forKey: .reason)
        let requiresCheckpoint = try container.decode(Bool.self, forKey: .requiresCheckpoint)
        let consumesObservationGeneration = try container.decode(UInt64.self, forKey: .consumesObservationGeneration)
        let projectionAuthority = try container.decode(ForgeAutonomyProjectionAuthority.self, forKey: .projectionAuthority)

        let expected = ForgeAutonomyCandidateEvaluator.project(
            authority: authority,
            budget: budget,
            observation: observation
        )
        guard disposition == expected.disposition,
              reason == expected.reason,
              requiresCheckpoint == expected.requiresCheckpoint,
              consumesObservationGeneration == expected.consumesObservationGeneration,
              projectionAuthority == .candidateOnly else {
            throw ForgeAutonomyValidationError.forgedProjection
        }

        self = expected
    }
}

public enum ForgeAutonomyCandidateEvaluator {
    /// Produce a deterministic policy candidate. This never grants authority to schedule an action.
    public static func project(
        authority: ForgeAutonomyAuthority,
        budget: ForgeAutonomyBudget,
        observation: ForgeAutonomyObservation
    ) -> ForgeAutonomyCandidateProjection {
        let projection = ForgeAutonomyGate.project(
            authority: authority,
            budget: budget,
            observation: observation
        )
        return ForgeAutonomyCandidateProjection(
            authority: authority,
            budget: budget,
            observation: observation,
            disposition: projection.disposition,
            reason: projection.reason,
            requiresCheckpoint: projection.requiresCheckpoint
        )
    }
}

private enum ForgeAutonomyGate {
    struct Projection {
        let disposition: ForgeAutonomyDisposition
        let reason: ForgeAutonomyReason
        let requiresCheckpoint: Bool
    }

    static func project(
        authority: ForgeAutonomyAuthority,
        budget: ForgeAutonomyBudget,
        observation: ForgeAutonomyObservation
    ) -> Projection {
        let hasFreshCheckpoint = observation.hasExactFreshCheckpoint(for: authority)

        if observation.userDirective == .cancel {
            return Projection(
                disposition: .cancel,
                reason: .userCancelled,
                requiresCheckpoint: !hasFreshCheckpoint
            )
        }
        if observation.userDirective == .pause {
            return Projection(
                disposition: .pause,
                reason: .userPaused,
                requiresCheckpoint: !hasFreshCheckpoint
            )
        }
        if observation.hasUnresolvedMaterialDecision {
            return Projection(
                disposition: .pause,
                reason: .unresolvedMaterialDecision,
                requiresCheckpoint: !hasFreshCheckpoint
            )
        }
        if observation.hasPendingPolicyApproval {
            return Projection(
                disposition: .pause,
                reason: .pendingPolicyApproval,
                requiresCheckpoint: !hasFreshCheckpoint
            )
        }
        if observation.hasExternalBlocker {
            return Projection(
                disposition: .pause,
                reason: .externalBlocker,
                requiresCheckpoint: !hasFreshCheckpoint
            )
        }

        if observation.thermalPressure == .critical {
            return Projection(
                disposition: .pause,
                reason: .thermalCritical,
                requiresCheckpoint: !hasFreshCheckpoint
            )
        }
        if observation.memoryPressure == .critical {
            return Projection(
                disposition: .pause,
                reason: .memoryCritical,
                requiresCheckpoint: !hasFreshCheckpoint
            )
        }

        if observation.elapsedMilliseconds >= budget.maximumElapsedMilliseconds {
            return Projection(
                disposition: .pause,
                reason: .elapsedBudgetExhausted,
                requiresCheckpoint: !hasFreshCheckpoint
            )
        }
        if observation.actionsUsed >= budget.maximumActions {
            return Projection(
                disposition: .pause,
                reason: .actionBudgetExhausted,
                requiresCheckpoint: !hasFreshCheckpoint
            )
        }
        if observation.repairAttemptsForCurrentDefect >= budget.maximumRepairAttemptsPerDefect {
            return Projection(
                disposition: .pause,
                reason: .repairEscalationRequired,
                requiresCheckpoint: !hasFreshCheckpoint
            )
        }
        if observation.consecutiveNonProgressActions >= budget.maximumConsecutiveNonProgressActions {
            return Projection(
                disposition: .pause,
                reason: .noProgressEscalationRequired,
                requiresCheckpoint: !hasFreshCheckpoint
            )
        }

        if observation.thermalPressure == .serious {
            return Projection(
                disposition: .degradeThenProceed,
                reason: .thermalSerious,
                requiresCheckpoint: !hasFreshCheckpoint
            )
        }
        if observation.memoryPressure == .warning {
            return Projection(
                disposition: .degradeThenProceed,
                reason: .memoryWarning,
                requiresCheckpoint: !hasFreshCheckpoint
            )
        }

        let elapsedCheckpointThreshold = budget.maximumElapsedMilliseconds - budget.checkpointLeadMilliseconds
        if budget.checkpointLeadMilliseconds > 0,
           observation.elapsedMilliseconds >= elapsedCheckpointThreshold,
           !hasFreshCheckpoint {
            return Projection(
                disposition: .checkpointThenProceed,
                reason: .elapsedBudgetNearLimit,
                requiresCheckpoint: true
            )
        }

        let actionCheckpointThreshold = budget.maximumActions - budget.checkpointLeadActions
        if budget.checkpointLeadActions > 0,
           observation.actionsUsed >= actionCheckpointThreshold,
           !hasFreshCheckpoint {
            return Projection(
                disposition: .checkpointThenProceed,
                reason: .actionBudgetNearLimit,
                requiresCheckpoint: true
            )
        }

        return Projection(
            disposition: .proceed,
            reason: .withinBudget,
            requiresCheckpoint: false
        )
    }
}
