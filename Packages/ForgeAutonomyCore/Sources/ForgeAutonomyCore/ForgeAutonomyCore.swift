import Foundation

public enum ForgeAutonomyValidationError: Error, Equatable, Sendable {
    case invalidIdentifier(field: String)
    case invalidBudget(field: String)
    case invalidCheckpointLead(field: String)
    case forgedDecision
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

/// Stable authority supplied by the canonical Mission Engine adapter.
/// This type binds a policy decision to one exact accepted mission state; it does not mint mission truth.
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

    private static func validateIdentifier(_ value: String, field: String) throws {
        guard !value.isEmpty,
              value.count <= 128,
              value.trimmingCharacters(in: .whitespacesAndNewlines) == value,
              value.unicodeScalars.allSatisfy({ scalar in
                  CharacterSet.alphanumerics.contains(scalar) || "-_.".unicodeScalars.contains(scalar)
              }) else {
            throw ForgeAutonomyValidationError.invalidIdentifier(field: field)
        }
    }
}

/// User/host-owned hard bounds for one autonomous mission authority epoch.
/// Values are deliberately host-observed counters rather than invented wall-clock/device facts.
public struct ForgeAutonomyBudget: Codable, Equatable, Sendable {
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
        guard maximumElapsedMilliseconds > 0 else {
            throw ForgeAutonomyValidationError.invalidBudget(field: "maximumElapsedMilliseconds")
        }
        guard maximumActions > 0 else {
            throw ForgeAutonomyValidationError.invalidBudget(field: "maximumActions")
        }
        guard maximumRepairAttemptsPerDefect > 0 else {
            throw ForgeAutonomyValidationError.invalidBudget(field: "maximumRepairAttemptsPerDefect")
        }
        guard maximumConsecutiveNonProgressActions > 0 else {
            throw ForgeAutonomyValidationError.invalidBudget(field: "maximumConsecutiveNonProgressActions")
        }
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
}

/// One host-observed snapshot immediately before NovaForge schedules another autonomous action.
public struct ForgeAutonomyObservation: Codable, Equatable, Sendable {
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
    public let hasFreshCheckpointForCurrentAuthority: Bool

    public init(
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
        hasFreshCheckpointForCurrentAuthority: Bool
    ) {
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
        self.hasFreshCheckpointForCurrentAuthority = hasFreshCheckpointForCurrentAuthority
    }
}

public enum ForgeAutonomyDisposition: String, Codable, CaseIterable, Sendable {
    /// Another bounded action may be scheduled immediately.
    case proceed
    /// Persist the current accepted state before scheduling another action.
    case checkpointThenProceed
    /// Reduce optional work/resource intensity and checkpoint before continuing.
    case degradeThenProceed
    /// Autonomous work must stop until a user/policy/dependency/resource condition changes.
    case pause
    /// User cancellation is terminal for this scheduling request.
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

/// Deterministic policy projection. A decoded decision re-runs the evaluator and rejects forged verdicts.
public struct ForgeAutonomyDecision: Codable, Equatable, Sendable {
    public let authority: ForgeAutonomyAuthority
    public let budget: ForgeAutonomyBudget
    public let observation: ForgeAutonomyObservation
    public let disposition: ForgeAutonomyDisposition
    public let reason: ForgeAutonomyReason
    public let requiresCheckpoint: Bool

    private init(
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
    }

    public static func evaluate(
        authority: ForgeAutonomyAuthority,
        budget: ForgeAutonomyBudget,
        observation: ForgeAutonomyObservation
    ) -> ForgeAutonomyDecision {
        let projection = ForgeAutonomyGate.project(budget: budget, observation: observation)
        return ForgeAutonomyDecision(
            authority: authority,
            budget: budget,
            observation: observation,
            disposition: projection.disposition,
            reason: projection.reason,
            requiresCheckpoint: projection.requiresCheckpoint
        )
    }

    private enum CodingKeys: String, CodingKey {
        case authority, budget, observation, disposition, reason, requiresCheckpoint
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let authority = try container.decode(ForgeAutonomyAuthority.self, forKey: .authority)
        let budget = try container.decode(ForgeAutonomyBudget.self, forKey: .budget)
        let observation = try container.decode(ForgeAutonomyObservation.self, forKey: .observation)
        let disposition = try container.decode(ForgeAutonomyDisposition.self, forKey: .disposition)
        let reason = try container.decode(ForgeAutonomyReason.self, forKey: .reason)
        let requiresCheckpoint = try container.decode(Bool.self, forKey: .requiresCheckpoint)

        let expected = Self.evaluate(authority: authority, budget: budget, observation: observation)
        guard disposition == expected.disposition,
              reason == expected.reason,
              requiresCheckpoint == expected.requiresCheckpoint else {
            throw ForgeAutonomyValidationError.forgedDecision
        }

        self = expected
    }
}

private enum ForgeAutonomyGate {
    struct Projection {
        let disposition: ForgeAutonomyDisposition
        let reason: ForgeAutonomyReason
        let requiresCheckpoint: Bool
    }

    static func project(
        budget: ForgeAutonomyBudget,
        observation: ForgeAutonomyObservation
    ) -> Projection {
        // User intent and unresolved authority always outrank autonomous continuation.
        if observation.userDirective == .cancel {
            return Projection(disposition: .cancel, reason: .userCancelled, requiresCheckpoint: !observation.hasFreshCheckpointForCurrentAuthority)
        }
        if observation.userDirective == .pause {
            return Projection(disposition: .pause, reason: .userPaused, requiresCheckpoint: !observation.hasFreshCheckpointForCurrentAuthority)
        }
        if observation.hasUnresolvedMaterialDecision {
            return Projection(disposition: .pause, reason: .unresolvedMaterialDecision, requiresCheckpoint: !observation.hasFreshCheckpointForCurrentAuthority)
        }
        if observation.hasPendingPolicyApproval {
            return Projection(disposition: .pause, reason: .pendingPolicyApproval, requiresCheckpoint: !observation.hasFreshCheckpointForCurrentAuthority)
        }
        if observation.hasExternalBlocker {
            return Projection(disposition: .pause, reason: .externalBlocker, requiresCheckpoint: !observation.hasFreshCheckpointForCurrentAuthority)
        }

        // Critical host pressure is a hard stop. Serious/warning pressure degrades before the process is at risk.
        if observation.thermalPressure == .critical {
            return Projection(disposition: .pause, reason: .thermalCritical, requiresCheckpoint: !observation.hasFreshCheckpointForCurrentAuthority)
        }
        if observation.memoryPressure == .critical {
            return Projection(disposition: .pause, reason: .memoryCritical, requiresCheckpoint: !observation.hasFreshCheckpointForCurrentAuthority)
        }

        // Exhaustion checks use >= so the gate never authorizes an action beyond a configured hard ceiling.
        if observation.elapsedMilliseconds >= budget.maximumElapsedMilliseconds {
            return Projection(disposition: .pause, reason: .elapsedBudgetExhausted, requiresCheckpoint: !observation.hasFreshCheckpointForCurrentAuthority)
        }
        if observation.actionsUsed >= budget.maximumActions {
            return Projection(disposition: .pause, reason: .actionBudgetExhausted, requiresCheckpoint: !observation.hasFreshCheckpointForCurrentAuthority)
        }
        if observation.repairAttemptsForCurrentDefect >= budget.maximumRepairAttemptsPerDefect {
            return Projection(disposition: .pause, reason: .repairEscalationRequired, requiresCheckpoint: !observation.hasFreshCheckpointForCurrentAuthority)
        }
        if observation.consecutiveNonProgressActions >= budget.maximumConsecutiveNonProgressActions {
            return Projection(disposition: .pause, reason: .noProgressEscalationRequired, requiresCheckpoint: !observation.hasFreshCheckpointForCurrentAuthority)
        }

        if observation.thermalPressure == .serious {
            return Projection(
                disposition: .degradeThenProceed,
                reason: .thermalSerious,
                requiresCheckpoint: !observation.hasFreshCheckpointForCurrentAuthority
            )
        }
        if observation.memoryPressure == .warning {
            return Projection(
                disposition: .degradeThenProceed,
                reason: .memoryWarning,
                requiresCheckpoint: !observation.hasFreshCheckpointForCurrentAuthority
            )
        }

        // Near-limit checks avoid addition/overflow by comparing the already-bounded observation to subtraction thresholds.
        let elapsedCheckpointThreshold = budget.maximumElapsedMilliseconds - budget.checkpointLeadMilliseconds
        if budget.checkpointLeadMilliseconds > 0,
           observation.elapsedMilliseconds >= elapsedCheckpointThreshold,
           !observation.hasFreshCheckpointForCurrentAuthority {
            return Projection(disposition: .checkpointThenProceed, reason: .elapsedBudgetNearLimit, requiresCheckpoint: true)
        }

        let actionCheckpointThreshold = budget.maximumActions - budget.checkpointLeadActions
        if budget.checkpointLeadActions > 0,
           observation.actionsUsed >= actionCheckpointThreshold,
           !observation.hasFreshCheckpointForCurrentAuthority {
            return Projection(disposition: .checkpointThenProceed, reason: .actionBudgetNearLimit, requiresCheckpoint: true)
        }

        return Projection(disposition: .proceed, reason: .withinBudget, requiresCheckpoint: false)
    }
}
