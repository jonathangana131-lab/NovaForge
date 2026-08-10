import Foundation

public struct ContinuityIdentity: Codable, Hashable, Sendable {
    public let missionID: String
    public let projectID: String
    public let checkpointID: String
    public let missionRevision: UInt64

    public init(missionID: String, projectID: String, checkpointID: String, missionRevision: UInt64) {
        self.missionID = missionID
        self.projectID = projectID
        self.checkpointID = checkpointID
        self.missionRevision = missionRevision
    }
}

public enum ContinuityExecutionMode: String, Codable, CaseIterable, Hashable, Sendable {
    case foregroundOnDevice
    case systemManagedOnDevice
    case verifiedCloud
    case verifiedPairedMac
}

public enum ContinuitySuspensionReason: String, Codable, Hashable, Sendable {
    case backgroundExecutionUnavailable
    case systemExpired
    case userPaused
    case recoverableFailure
    case executionEnvironmentLost
    case missionStateRevalidationRequired
}

public enum ContinuityRunState: Codable, Hashable, Sendable {
    case ready
    case executing(ContinuityExecutionMode)
    case suspended(ContinuitySuspensionReason)
    case needsDecision
    case blocked
    case completed
}

/// Fresh host-owned authority. It is intentionally non-Codable and cannot be created by a normal
/// external package consumer. A platform/Mission adapter inside ContinuityCore must mint it only
/// after authenticating the exact execution environment.
public struct ContinuityExecutionGrant: Hashable, Sendable {
    public let identity: ContinuityIdentity
    public let mode: ContinuityExecutionMode
    public let authorityReceiptID: String

    init(identity: ContinuityIdentity, mode: ContinuityExecutionMode, authorityReceiptID: String) {
        self.identity = identity
        self.mode = mode
        self.authorityReceiptID = authorityReceiptID
    }
}

/// Fresh Mission authority used for checkpoint and terminal projections. Persisted/model-authored
/// identity strings are never enough to move continuity across accepted Mission state.
public struct ContinuityMissionAuthority: Hashable, Sendable {
    public let identity: ContinuityIdentity
    public let authorityReceiptID: String

    init(identity: ContinuityIdentity, authorityReceiptID: String) {
        self.identity = identity
        self.authorityReceiptID = authorityReceiptID
    }
}

public struct ContinuityWorkLease: Hashable, Sendable {
    public let identity: ContinuityIdentity
    public let epoch: UInt64
    public let mode: ContinuityExecutionMode
    public let authorityReceiptID: String

    init(identity: ContinuityIdentity, epoch: UInt64, mode: ContinuityExecutionMode, authorityReceiptID: String) {
        self.identity = identity
        self.epoch = epoch
        self.mode = mode
        self.authorityReceiptID = authorityReceiptID
    }
}

/// Live process state. Deliberately non-Codable: relaunch recovery must go through
/// `ContinuityArchive.restore()` and reacquire execution authority rather than revive a lease.
public struct ContinuitySnapshot: Hashable, Sendable {
    public let identity: ContinuityIdentity
    public let state: ContinuityRunState
    public let activeLease: ContinuityWorkLease?
    public let epoch: UInt64

    /// Public construction starts only from neutral ready state. Mission-owned projections and
    /// executing state are reducer/authority outputs and cannot be caller-minted.
    public init(identity: ContinuityIdentity, epoch: UInt64 = 0) {
        self.identity = identity
        self.state = .ready
        self.activeLease = nil
        self.epoch = epoch
    }

    init(identity: ContinuityIdentity, state: ContinuityRunState, activeLease: ContinuityWorkLease?, epoch: UInt64) {
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

public struct ContinuityWorkResult: Hashable, Sendable {
    public let lease: ContinuityWorkLease
    public let outcome: ContinuityWorkOutcome
    public let summary: String
    public let evidenceIDs: [String]

    public init(lease: ContinuityWorkLease, outcome: ContinuityWorkOutcome, summary: String, evidenceIDs: [String] = []) {
        self.lease = lease
        self.outcome = outcome
        self.summary = summary
        self.evidenceIDs = evidenceIDs
    }
}

public struct ContinuityAcceptedResult: Hashable, Sendable {
    public let identity: ContinuityIdentity
    public let executionMode: ContinuityExecutionMode
    public let outcome: ContinuityWorkOutcome
    public let summary: String
    public let evidenceIDs: [String]
}

public enum ContinuityMutationError: Error, Equatable, Sendable {
    case invalidIdentity
    case invalidAuthority
    case invalidSnapshot
    case invalidWorkResult
    case epochOverflow
    case noActiveExecution
    case unsupportedTransition
    case executionGrantMissing
    case staleWorkerResult
    case checkpointRegression
    case checkpointIdentityMismatch
    case missionCompletionIdentityMismatch
}

public enum ContinuityReducer {
    private static let maximumEvidenceIDs = 128
    private static let maximumSummaryUTF8Bytes = 16 * 1024

    public static func validate(_ snapshot: ContinuitySnapshot) throws {
        guard isValidIdentity(snapshot.identity) else { throw ContinuityMutationError.invalidIdentity }
        switch snapshot.state {
        case let .executing(mode):
            guard let lease = snapshot.activeLease,
                  lease.identity == snapshot.identity,
                  lease.epoch == snapshot.epoch,
                  lease.mode == mode,
                  isCanonicalID(lease.authorityReceiptID) else {
                throw ContinuityMutationError.invalidSnapshot
            }
        case .ready, .suspended, .needsDecision, .blocked, .completed:
            guard snapshot.activeLease == nil else { throw ContinuityMutationError.invalidSnapshot }
        }
    }

    public static func startForeground(from snapshot: ContinuitySnapshot, grant: ContinuityExecutionGrant) throws -> (ContinuitySnapshot, ContinuityWorkLease) {
        try validate(snapshot)
        try validate(grant: grant, for: snapshot.identity, mode: .foregroundOnDevice)
        switch snapshot.state {
        case .ready, .suspended:
            return try mintExecution(.foregroundOnDevice, from: snapshot, grant: grant)
        case .needsDecision, .blocked, .completed, .executing:
            throw ContinuityMutationError.unsupportedTransition
        }
    }

    /// Background continuation is authorized only by a fresh host grant. Candidate capability
    /// metadata is intentionally insufficient. Without a matching grant, the foreground lease is
    /// revoked and continuity projects a truthful suspended state.
    public static func enterBackground(from snapshot: ContinuitySnapshot, systemGrant: ContinuityExecutionGrant?) throws -> (ContinuitySnapshot, ContinuityWorkLease?) {
        try validate(snapshot)
        guard case .executing(.foregroundOnDevice) = snapshot.state else { throw ContinuityMutationError.noActiveExecution }
        guard let systemGrant else {
            return (try suspend(snapshot, reason: .backgroundExecutionUnavailable), nil)
        }
        try validate(grant: systemGrant, for: snapshot.identity, mode: .systemManagedOnDevice)
        let (next, lease) = try mintExecution(.systemManagedOnDevice, from: snapshot, grant: systemGrant)
        return (next, lease)
    }

    public static func systemContinuationExpired(in snapshot: ContinuitySnapshot) throws -> ContinuitySnapshot {
        try validate(snapshot)
        guard case .executing(.systemManagedOnDevice) = snapshot.state else { throw ContinuityMutationError.noActiveExecution }
        return try suspend(snapshot, reason: .systemExpired)
    }

    public static func pauseByUser(_ snapshot: ContinuitySnapshot) throws -> ContinuitySnapshot {
        try validate(snapshot)
        guard case .executing = snapshot.state else { throw ContinuityMutationError.noActiveExecution }
        return try suspend(snapshot, reason: .userPaused)
    }

    public static func executionEnvironmentLost(in snapshot: ContinuitySnapshot) throws -> ContinuitySnapshot {
        try validate(snapshot)
        guard case .executing = snapshot.state else { throw ContinuityMutationError.noActiveExecution }
        return try suspend(snapshot, reason: .executionEnvironmentLost)
    }

    public static func handoffToCloud(from snapshot: ContinuitySnapshot, grant: ContinuityExecutionGrant) throws -> (ContinuitySnapshot, ContinuityWorkLease) {
        try validate(snapshot)
        try validate(grant: grant, for: snapshot.identity, mode: .verifiedCloud)
        guard allowsHandoff(snapshot.state) else { throw ContinuityMutationError.unsupportedTransition }
        return try mintExecution(.verifiedCloud, from: snapshot, grant: grant)
    }

    public static func handoffToPairedMac(from snapshot: ContinuitySnapshot, grant: ContinuityExecutionGrant) throws -> (ContinuitySnapshot, ContinuityWorkLease) {
        try validate(snapshot)
        try validate(grant: grant, for: snapshot.identity, mode: .verifiedPairedMac)
        guard allowsHandoff(snapshot.state) else { throw ContinuityMutationError.unsupportedTransition }
        return try mintExecution(.verifiedPairedMac, from: snapshot, grant: grant)
    }

    public static func advanceCheckpoint(authority: ContinuityMissionAuthority, in snapshot: ContinuitySnapshot) throws -> ContinuitySnapshot {
        try validate(snapshot)
        try validate(authority: authority)
        let identity = authority.identity
        guard identity.missionID == snapshot.identity.missionID, identity.projectID == snapshot.identity.projectID else {
            throw ContinuityMutationError.checkpointIdentityMismatch
        }
        guard identity.missionRevision > snapshot.identity.missionRevision else { throw ContinuityMutationError.checkpointRegression }
        let epoch = try successor(snapshot.epoch)
        let nextState: ContinuityRunState = switch snapshot.state {
        case .executing: .ready
        case .ready, .suspended, .needsDecision, .blocked, .completed: snapshot.state
        }
        return ContinuitySnapshot(identity: identity, state: nextState, activeLease: nil, epoch: epoch)
    }

    public static func accepts(_ lease: ContinuityWorkLease, in snapshot: ContinuitySnapshot) -> Bool {
        guard (try? validate(snapshot)) != nil else { return false }
        return snapshot.activeLease == lease
    }

    public static func accept(_ result: ContinuityWorkResult, in snapshot: ContinuitySnapshot) throws -> (ContinuitySnapshot, ContinuityAcceptedResult) {
        try validate(snapshot)
        guard snapshot.activeLease == result.lease else { throw ContinuityMutationError.staleWorkerResult }
        guard isValidWorkResult(result) else { throw ContinuityMutationError.invalidWorkResult }
        let nextEpoch = try successor(snapshot.epoch)
        let state: ContinuityRunState = switch result.outcome {
        case .succeeded: .ready
        case .needsDecision: .needsDecision
        case .blocked: .blocked
        case .failedRecoverably: .suspended(.recoverableFailure)
        }
        let next = ContinuitySnapshot(identity: snapshot.identity, state: state, activeLease: nil, epoch: nextEpoch)
        let accepted = ContinuityAcceptedResult(
            identity: snapshot.identity,
            executionMode: result.lease.mode,
            outcome: result.outcome,
            summary: result.summary,
            evidenceIDs: result.evidenceIDs
        )
        return (next, accepted)
    }

    public static func reflectMissionCompletion(authority: ContinuityMissionAuthority, in snapshot: ContinuitySnapshot) throws -> ContinuitySnapshot {
        try validate(snapshot)
        try validate(authority: authority)
        guard authority.identity == snapshot.identity else { throw ContinuityMutationError.missionCompletionIdentityMismatch }
        guard snapshot.activeLease == nil else { throw ContinuityMutationError.unsupportedTransition }
        return ContinuitySnapshot(identity: snapshot.identity, state: .completed, activeLease: nil, epoch: try successor(snapshot.epoch))
    }

    private static func allowsHandoff(_ state: ContinuityRunState) -> Bool {
        switch state {
        case .ready, .suspended, .executing: true
        case .needsDecision, .blocked, .completed: false
        }
    }

    private static func mintExecution(_ mode: ContinuityExecutionMode, from snapshot: ContinuitySnapshot, grant: ContinuityExecutionGrant) throws -> (ContinuitySnapshot, ContinuityWorkLease) {
        let epoch = try successor(snapshot.epoch)
        let lease = ContinuityWorkLease(identity: snapshot.identity, epoch: epoch, mode: mode, authorityReceiptID: grant.authorityReceiptID)
        return (ContinuitySnapshot(identity: snapshot.identity, state: .executing(mode), activeLease: lease, epoch: epoch), lease)
    }

    private static func suspend(_ snapshot: ContinuitySnapshot, reason: ContinuitySuspensionReason) throws -> ContinuitySnapshot {
        ContinuitySnapshot(identity: snapshot.identity, state: .suspended(reason), activeLease: nil, epoch: try successor(snapshot.epoch))
    }

    private static func validate(grant: ContinuityExecutionGrant, for identity: ContinuityIdentity, mode: ContinuityExecutionMode) throws {
        guard isValidIdentity(grant.identity), grant.identity == identity, grant.mode == mode, isCanonicalID(grant.authorityReceiptID) else {
            throw ContinuityMutationError.executionGrantMissing
        }
    }

    private static func validate(authority: ContinuityMissionAuthority) throws {
        guard isValidIdentity(authority.identity), isCanonicalID(authority.authorityReceiptID) else {
            throw ContinuityMutationError.invalidAuthority
        }
    }

    private static func isValidWorkResult(_ result: ContinuityWorkResult) -> Bool {
        guard !result.summary.isEmpty, result.summary.utf8.count <= maximumSummaryUTF8Bytes,
              result.evidenceIDs.count <= maximumEvidenceIDs else { return false }
        var seen = Set<String>()
        for id in result.evidenceIDs {
            guard isCanonicalID(id), seen.insert(id).inserted else { return false }
        }
        return true
    }

    private static func successor(_ epoch: UInt64) throws -> UInt64 {
        guard epoch < .max else { throw ContinuityMutationError.epochOverflow }
        return epoch + 1
    }

    static func isValidIdentity(_ identity: ContinuityIdentity) -> Bool {
        isCanonicalID(identity.missionID) && isCanonicalID(identity.projectID) && isCanonicalID(identity.checkpointID)
    }

    static func isCanonicalID(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 512,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}
