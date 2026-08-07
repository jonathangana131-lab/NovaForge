import Foundation

public struct ContinuityIdentity: Codable, Hashable, Sendable {
    public let missionID: String
    public let projectID: String
    public let checkpointID: String
    public let missionRevision: UInt64

    public init(
        missionID: String,
        projectID: String,
        checkpointID: String,
        missionRevision: UInt64
    ) {
        self.missionID = missionID
        self.projectID = projectID
        self.checkpointID = checkpointID
        self.missionRevision = missionRevision
    }
}

/// Describes where a real worker is executing. No case means “runs forever on iPhone”.
public enum ContinuityExecutionMode: String, Codable, CaseIterable, Hashable, Sendable {
    case foregroundOnDevice
    case systemManagedOnDevice
    case verifiedCloud
    case verifiedPairedMac
}

public enum OnDeviceContinuationCapability: String, Codable, Hashable, Sendable {
    case unavailable
    /// The OS says this work is eligible for a system-managed continuation mechanism.
    /// This is explicitly not a guarantee that the process runs forever while closed.
    case eligibleSystemManaged
}

public enum RemoteWorkerCapability: String, Codable, Hashable, Sendable {
    case unavailable
    case discoveredUnverified
    case verifiedNotAuthorized
    case verifiedAuthorized
}

public struct ContinuityCapabilities: Codable, Hashable, Sendable {
    public let onDeviceContinuation: OnDeviceContinuationCapability
    public let cloud: RemoteWorkerCapability
    public let pairedMac: RemoteWorkerCapability

    public init(
        onDeviceContinuation: OnDeviceContinuationCapability = .unavailable,
        cloud: RemoteWorkerCapability = .unavailable,
        pairedMac: RemoteWorkerCapability = .unavailable
    ) {
        self.onDeviceContinuation = onDeviceContinuation
        self.cloud = cloud
        self.pairedMac = pairedMac
    }
}

public enum ContinuitySuspensionReason: String, Codable, Hashable, Sendable {
    case backgroundExecutionUnavailable
    case systemExpired
    case userPaused
    case recoverableFailure
    case executionEnvironmentLost
}

/// A continuity projection of canonical Mission Engine state. This module does not own mission
/// completion, decisions, or blockers; adapters reflect those states here so background/system UI
/// cannot drift from the authoritative mission.
public enum ContinuityRunState: Codable, Hashable, Sendable {
    case ready
    case executing(ContinuityExecutionMode)
    case suspended(ContinuitySuspensionReason)
    case needsDecision
    case blocked
    case completed
}

public struct ContinuityWorkLease: Codable, Hashable, Sendable {
    public let identity: ContinuityIdentity
    public let epoch: UInt64
    public let mode: ContinuityExecutionMode

    public init(identity: ContinuityIdentity, epoch: UInt64, mode: ContinuityExecutionMode) {
        self.identity = identity
        self.epoch = epoch
        self.mode = mode
    }
}

public struct ContinuitySnapshot: Codable, Hashable, Sendable {
    public let identity: ContinuityIdentity
    public let state: ContinuityRunState
    public let activeLease: ContinuityWorkLease?
    public let epoch: UInt64

    public init(
        identity: ContinuityIdentity,
        state: ContinuityRunState = .ready,
        activeLease: ContinuityWorkLease? = nil,
        epoch: UInt64 = 0
    ) {
        self.identity = identity
        self.state = state
        self.activeLease = activeLease
        self.epoch = epoch
    }
}

public enum ContinuityWorkOutcome: String, Codable, Hashable, Sendable {
    case succeeded
    case needsDecision
    case blocked
    case failedRecoverably
}

public struct ContinuityWorkResult: Codable, Hashable, Sendable {
    public let lease: ContinuityWorkLease
    public let outcome: ContinuityWorkOutcome
    /// Concise durable result summary; never hidden chain-of-thought.
    public let summary: String
    public let evidenceIDs: [String]

    public init(
        lease: ContinuityWorkLease,
        outcome: ContinuityWorkOutcome,
        summary: String,
        evidenceIDs: [String] = []
    ) {
        self.lease = lease
        self.outcome = outcome
        self.summary = summary
        self.evidenceIDs = evidenceIDs
    }
}

public struct ContinuityAcceptedResult: Codable, Hashable, Sendable {
    public let identity: ContinuityIdentity
    public let executionMode: ContinuityExecutionMode
    public let outcome: ContinuityWorkOutcome
    public let summary: String
    public let evidenceIDs: [String]

    public init(
        identity: ContinuityIdentity,
        executionMode: ContinuityExecutionMode,
        outcome: ContinuityWorkOutcome,
        summary: String,
        evidenceIDs: [String]
    ) {
        self.identity = identity
        self.executionMode = executionMode
        self.outcome = outcome
        self.summary = summary
        self.evidenceIDs = evidenceIDs
    }
}

public enum ContinuityMutationError: Error, Equatable, Sendable {
    case invalidIdentity
    case invalidSnapshot
    case epochOverflow
    case noActiveExecution
    case unsupportedTransition
    case cloudUnavailableOrUnauthorized
    case pairedMacUnavailableOrUnauthorized
    case staleWorkerResult
    case checkpointRegression
    case checkpointIdentityMismatch
    case missionCompletionIdentityMismatch
}

public enum ContinuityReducer {
    public static func validate(_ snapshot: ContinuitySnapshot) throws {
        guard isValidIdentity(snapshot.identity) else {
            throw ContinuityMutationError.invalidIdentity
        }

        switch snapshot.state {
        case let .executing(mode):
            guard let lease = snapshot.activeLease,
                  lease.identity == snapshot.identity,
                  lease.epoch == snapshot.epoch,
                  lease.mode == mode else {
                throw ContinuityMutationError.invalidSnapshot
            }
        case .ready, .suspended, .needsDecision, .blocked, .completed:
            guard snapshot.activeLease == nil else {
                throw ContinuityMutationError.invalidSnapshot
            }
        }
    }

    public static func startForeground(
        from snapshot: ContinuitySnapshot
    ) throws -> (ContinuitySnapshot, ContinuityWorkLease) {
        try validate(snapshot)
        switch snapshot.state {
        case .ready, .suspended:
            return try mintExecution(.foregroundOnDevice, from: snapshot)
        case .needsDecision, .blocked, .completed, .executing:
            throw ContinuityMutationError.unsupportedTransition
        }
    }

    /// Applies the truthful app-background boundary. Eligible system-managed work gets a fresh
    /// lease; otherwise the on-device worker is considered stopped and its old lease is stale.
    public static func enterBackground(
        from snapshot: ContinuitySnapshot,
        capabilities: ContinuityCapabilities
    ) throws -> (ContinuitySnapshot, ContinuityWorkLease?) {
        try validate(snapshot)
        guard case .executing(.foregroundOnDevice) = snapshot.state else {
            throw ContinuityMutationError.noActiveExecution
        }

        switch capabilities.onDeviceContinuation {
        case .eligibleSystemManaged:
            let (next, lease) = try mintExecution(.systemManagedOnDevice, from: snapshot)
            return (next, lease)
        case .unavailable:
            return (try suspend(snapshot, reason: .backgroundExecutionUnavailable), nil)
        }
    }

    public static func systemContinuationExpired(
        in snapshot: ContinuitySnapshot
    ) throws -> ContinuitySnapshot {
        try validate(snapshot)
        guard case .executing(.systemManagedOnDevice) = snapshot.state else {
            throw ContinuityMutationError.noActiveExecution
        }
        return try suspend(snapshot, reason: .systemExpired)
    }

    public static func pauseByUser(
        _ snapshot: ContinuitySnapshot
    ) throws -> ContinuitySnapshot {
        try validate(snapshot)
        guard case .executing = snapshot.state else {
            throw ContinuityMutationError.noActiveExecution
        }
        return try suspend(snapshot, reason: .userPaused)
    }

    /// Revokes work when the environment that owned the active lease disappears or becomes
    /// unusable. Adapters call this for real worker/process loss; it must never leave `working` UI.
    public static func executionEnvironmentLost(
        in snapshot: ContinuitySnapshot
    ) throws -> ContinuitySnapshot {
        try validate(snapshot)
        guard case .executing = snapshot.state else {
            throw ContinuityMutationError.noActiveExecution
        }
        return try suspend(snapshot, reason: .executionEnvironmentLost)
    }

    public static func handoffToCloud(
        from snapshot: ContinuitySnapshot,
        capabilities: ContinuityCapabilities
    ) throws -> (ContinuitySnapshot, ContinuityWorkLease) {
        try validate(snapshot)
        guard capabilities.cloud == .verifiedAuthorized else {
            throw ContinuityMutationError.cloudUnavailableOrUnauthorized
        }
        switch snapshot.state {
        case .ready, .suspended, .executing:
            return try mintExecution(.verifiedCloud, from: snapshot)
        case .needsDecision, .blocked, .completed:
            throw ContinuityMutationError.unsupportedTransition
        }
    }

    public static func handoffToPairedMac(
        from snapshot: ContinuitySnapshot,
        capabilities: ContinuityCapabilities
    ) throws -> (ContinuitySnapshot, ContinuityWorkLease) {
        try validate(snapshot)
        guard capabilities.pairedMac == .verifiedAuthorized else {
            throw ContinuityMutationError.pairedMacUnavailableOrUnauthorized
        }
        switch snapshot.state {
        case .ready, .suspended, .executing:
            return try mintExecution(.verifiedPairedMac, from: snapshot)
        case .needsDecision, .blocked, .completed:
            throw ContinuityMutationError.unsupportedTransition
        }
    }

    /// Rebinds continuity to a newer accepted mission checkpoint. Any in-flight worker is revoked.
    /// The adapter must supply the authoritative mission/project/checkpoint identity from Mission Engine.
    public static func advanceCheckpoint(
        to identity: ContinuityIdentity,
        in snapshot: ContinuitySnapshot
    ) throws -> ContinuitySnapshot {
        try validate(snapshot)
        guard identity.missionID == snapshot.identity.missionID,
              identity.projectID == snapshot.identity.projectID else {
            throw ContinuityMutationError.checkpointIdentityMismatch
        }
        guard identity.missionRevision > snapshot.identity.missionRevision else {
            throw ContinuityMutationError.checkpointRegression
        }
        guard isValidIdentity(identity) else {
            throw ContinuityMutationError.invalidIdentity
        }
        let epoch = try successor(snapshot.epoch)
        let nextState: ContinuityRunState
        switch snapshot.state {
        case .executing:
            // A checkpoint boundary revokes the old worker lease. Mission Engine decides what
            // executes next, so continuity returns to ready rather than keeping stale activity.
            nextState = .ready
        case .ready, .suspended, .needsDecision, .blocked, .completed:
            // Checkpoint movement must never silently clear a decision, blocker, suspension, or
            // terminal projection owned by Mission Engine.
            nextState = snapshot.state
        }
        return ContinuitySnapshot(identity: identity, state: nextState, activeLease: nil, epoch: epoch)
    }

    public static func accepts(
        _ lease: ContinuityWorkLease,
        in snapshot: ContinuitySnapshot
    ) -> Bool {
        guard (try? validate(snapshot)) != nil else { return false }
        return snapshot.activeLease == lease
    }

    public static func accept(
        _ result: ContinuityWorkResult,
        in snapshot: ContinuitySnapshot
    ) throws -> (ContinuitySnapshot, ContinuityAcceptedResult) {
        try validate(snapshot)
        guard snapshot.activeLease == result.lease else {
            throw ContinuityMutationError.staleWorkerResult
        }
        let nextEpoch = try successor(snapshot.epoch)
        let state: ContinuityRunState
        switch result.outcome {
        case .succeeded:
            state = .ready
        case .needsDecision:
            state = .needsDecision
        case .blocked:
            state = .blocked
        case .failedRecoverably:
            state = .suspended(.recoverableFailure)
        }
        let next = ContinuitySnapshot(
            identity: snapshot.identity,
            state: state,
            activeLease: nil,
            epoch: nextEpoch
        )
        return (
            next,
            ContinuityAcceptedResult(
                identity: snapshot.identity,
                executionMode: result.lease.mode,
                outcome: result.outcome,
                summary: result.summary,
                evidenceIDs: result.evidenceIDs
            )
        )
    }

    /// Reflects a terminal state only after the canonical Mission Engine supplies the exact accepted
    /// mission/checkpoint identity. Continuity cannot independently decide that a mission is done.
    public static func reflectMissionCompletion(
        authoritativeIdentity: ContinuityIdentity,
        in snapshot: ContinuitySnapshot
    ) throws -> ContinuitySnapshot {
        try validate(snapshot)
        guard authoritativeIdentity == snapshot.identity else {
            throw ContinuityMutationError.missionCompletionIdentityMismatch
        }
        guard snapshot.activeLease == nil else {
            throw ContinuityMutationError.unsupportedTransition
        }
        let epoch = try successor(snapshot.epoch)
        return ContinuitySnapshot(identity: snapshot.identity, state: .completed, activeLease: nil, epoch: epoch)
    }

    private static func mintExecution(
        _ mode: ContinuityExecutionMode,
        from snapshot: ContinuitySnapshot
    ) throws -> (ContinuitySnapshot, ContinuityWorkLease) {
        let epoch = try successor(snapshot.epoch)
        let lease = ContinuityWorkLease(identity: snapshot.identity, epoch: epoch, mode: mode)
        let next = ContinuitySnapshot(
            identity: snapshot.identity,
            state: .executing(mode),
            activeLease: lease,
            epoch: epoch
        )
        return (next, lease)
    }

    private static func suspend(
        _ snapshot: ContinuitySnapshot,
        reason: ContinuitySuspensionReason
    ) throws -> ContinuitySnapshot {
        let epoch = try successor(snapshot.epoch)
        return ContinuitySnapshot(
            identity: snapshot.identity,
            state: .suspended(reason),
            activeLease: nil,
            epoch: epoch
        )
    }

    private static func successor(_ epoch: UInt64) throws -> UInt64 {
        guard epoch < UInt64.max else { throw ContinuityMutationError.epochOverflow }
        return epoch + 1
    }

    private static func isValidIdentity(_ identity: ContinuityIdentity) -> Bool {
        !identity.missionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !identity.projectID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !identity.checkpointID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
