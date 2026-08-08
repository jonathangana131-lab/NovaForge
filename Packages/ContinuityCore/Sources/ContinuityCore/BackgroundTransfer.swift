import Foundation

public enum BackgroundTransferState: String, Codable, Hashable, Sendable {
    case queued
    case running
    case suspended
    case completed
    case failed
}

/// Domain truth for a background URLSession-backed transfer. `resumeOpaqueToken` is an opaque
/// persistence reference supplied by the platform adapter; it must not contain credentials.
public struct BackgroundTransferSnapshot: Codable, Hashable, Sendable {
    public let transferID: String
    public let assetID: String
    public let state: BackgroundTransferState
    public let receivedBytes: Int64
    public let expectedBytes: Int64?
    public let resumeOpaqueToken: String?

    public init(
        transferID: String,
        assetID: String,
        state: BackgroundTransferState = .queued,
        receivedBytes: Int64 = 0,
        expectedBytes: Int64? = nil,
        resumeOpaqueToken: String? = nil
    ) {
        self.transferID = transferID
        self.assetID = assetID
        self.state = state
        self.receivedBytes = receivedBytes
        self.expectedBytes = expectedBytes
        self.resumeOpaqueToken = resumeOpaqueToken
    }

    public var canResume: Bool {
        state == .suspended && resumeOpaqueToken?.isEmpty == false
    }
}

public enum BackgroundTransferError: Error, Equatable, Sendable {
    case invalidIdentity
    case invalidByteCount
    case byteCountRegression
    case expectedSizeExceeded
    case invalidStateTransition
    case missingResumeToken
}

public enum BackgroundTransferReducer {
    public static func validate(_ snapshot: BackgroundTransferSnapshot) throws {
        guard !snapshot.transferID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !snapshot.assetID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BackgroundTransferError.invalidIdentity
        }
        guard snapshot.receivedBytes >= 0 else {
            throw BackgroundTransferError.invalidByteCount
        }
        if let expected = snapshot.expectedBytes {
            guard expected >= 0 else { throw BackgroundTransferError.invalidByteCount }
            guard snapshot.receivedBytes <= expected else {
                throw BackgroundTransferError.expectedSizeExceeded
            }
        }
        if snapshot.state == .suspended {
            guard snapshot.resumeOpaqueToken?.isEmpty == false else {
                throw BackgroundTransferError.missingResumeToken
            }
        } else if snapshot.resumeOpaqueToken != nil {
            throw BackgroundTransferError.invalidStateTransition
        }
    }

    public static func start(_ snapshot: BackgroundTransferSnapshot) throws -> BackgroundTransferSnapshot {
        try validate(snapshot)
        guard snapshot.state == .queued else {
            throw BackgroundTransferError.invalidStateTransition
        }
        return BackgroundTransferSnapshot(
            transferID: snapshot.transferID,
            assetID: snapshot.assetID,
            state: .running,
            receivedBytes: snapshot.receivedBytes,
            expectedBytes: snapshot.expectedBytes
        )
    }

    public static func recordProgress(
        receivedBytes: Int64,
        expectedBytes: Int64?,
        in snapshot: BackgroundTransferSnapshot
    ) throws -> BackgroundTransferSnapshot {
        try validate(snapshot)
        guard snapshot.state == .running else {
            throw BackgroundTransferError.invalidStateTransition
        }
        guard receivedBytes >= snapshot.receivedBytes else {
            throw BackgroundTransferError.byteCountRegression
        }
        if let oldExpected = snapshot.expectedBytes,
           let newExpected = expectedBytes,
           oldExpected != newExpected {
            throw BackgroundTransferError.invalidByteCount
        }
        let resolvedExpected = expectedBytes ?? snapshot.expectedBytes
        let next = BackgroundTransferSnapshot(
            transferID: snapshot.transferID,
            assetID: snapshot.assetID,
            state: .running,
            receivedBytes: receivedBytes,
            expectedBytes: resolvedExpected
        )
        try validate(next)
        return next
    }

    public static func suspend(
        resumeOpaqueToken: String,
        in snapshot: BackgroundTransferSnapshot
    ) throws -> BackgroundTransferSnapshot {
        try validate(snapshot)
        guard snapshot.state == .running else {
            throw BackgroundTransferError.invalidStateTransition
        }
        guard !resumeOpaqueToken.isEmpty else {
            throw BackgroundTransferError.missingResumeToken
        }
        return BackgroundTransferSnapshot(
            transferID: snapshot.transferID,
            assetID: snapshot.assetID,
            state: .suspended,
            receivedBytes: snapshot.receivedBytes,
            expectedBytes: snapshot.expectedBytes,
            resumeOpaqueToken: resumeOpaqueToken
        )
    }

    public static func resume(_ snapshot: BackgroundTransferSnapshot) throws -> BackgroundTransferSnapshot {
        try validate(snapshot)
        guard snapshot.canResume else { throw BackgroundTransferError.missingResumeToken }
        return BackgroundTransferSnapshot(
            transferID: snapshot.transferID,
            assetID: snapshot.assetID,
            state: .running,
            receivedBytes: snapshot.receivedBytes,
            expectedBytes: snapshot.expectedBytes
        )
    }

    public static func fail(_ snapshot: BackgroundTransferSnapshot) throws -> BackgroundTransferSnapshot {
        try validate(snapshot)
        guard snapshot.state == .running else {
            throw BackgroundTransferError.invalidStateTransition
        }
        return BackgroundTransferSnapshot(
            transferID: snapshot.transferID,
            assetID: snapshot.assetID,
            state: .failed,
            receivedBytes: snapshot.receivedBytes,
            expectedBytes: snapshot.expectedBytes
        )
    }

    /// A non-resumable failed download restarts from zero rather than pretending partial bytes are usable.
    public static func restartFromBeginning(_ snapshot: BackgroundTransferSnapshot) throws -> BackgroundTransferSnapshot {
        try validate(snapshot)
        guard snapshot.state == .failed else {
            throw BackgroundTransferError.invalidStateTransition
        }
        return BackgroundTransferSnapshot(
            transferID: snapshot.transferID,
            assetID: snapshot.assetID,
            state: .running,
            receivedBytes: 0,
            expectedBytes: snapshot.expectedBytes
        )
    }

    public static func complete(_ snapshot: BackgroundTransferSnapshot) throws -> BackgroundTransferSnapshot {
        try validate(snapshot)
        guard snapshot.state == .running else {
            throw BackgroundTransferError.invalidStateTransition
        }
        if let expected = snapshot.expectedBytes,
           snapshot.receivedBytes != expected {
            throw BackgroundTransferError.invalidByteCount
        }
        return BackgroundTransferSnapshot(
            transferID: snapshot.transferID,
            assetID: snapshot.assetID,
            state: .completed,
            receivedBytes: snapshot.receivedBytes,
            expectedBytes: snapshot.expectedBytes
        )
    }
}
