import Foundation

public enum BackgroundTransferState: String, Codable, Hashable, Sendable { case queued, running, suspended, completed, failed }

public struct BackgroundTransferSnapshot: Codable, Hashable, Sendable {
    public let transferID: String
    public let assetID: String
    public let state: BackgroundTransferState
    public let receivedBytes: Int64
    public let expectedBytes: Int64?
    public let resumeOpaqueToken: String?

    public init(transferID: String, assetID: String, state: BackgroundTransferState = .queued, receivedBytes: Int64 = 0, expectedBytes: Int64? = nil, resumeOpaqueToken: String? = nil) {
        self.transferID = transferID
        self.assetID = assetID
        self.state = state
        self.receivedBytes = receivedBytes
        self.expectedBytes = expectedBytes
        self.resumeOpaqueToken = resumeOpaqueToken
    }

    public var canResume: Bool { state == .suspended && resumeOpaqueToken != nil }

    private enum CodingKeys: String, CodingKey { case transferID, assetID, state, receivedBytes, expectedBytes, resumeOpaqueToken }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            transferID: try c.decode(String.self, forKey: .transferID),
            assetID: try c.decode(String.self, forKey: .assetID),
            state: try c.decode(BackgroundTransferState.self, forKey: .state),
            receivedBytes: try c.decode(Int64.self, forKey: .receivedBytes),
            expectedBytes: try c.decodeIfPresent(Int64.self, forKey: .expectedBytes),
            resumeOpaqueToken: try c.decodeIfPresent(String.self, forKey: .resumeOpaqueToken)
        )
        do { try BackgroundTransferReducer.validate(self) }
        catch { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid background transfer snapshot.", underlyingError: error)) }
    }
}

public enum BackgroundTransferError: Error, Equatable, Sendable {
    case invalidIdentity, invalidByteCount, byteCountRegression, expectedSizeExceeded, invalidStateTransition, missingResumeToken
}

public enum BackgroundTransferReducer {
    public static func validate(_ snapshot: BackgroundTransferSnapshot) throws {
        guard ContinuityReducer.isCanonicalID(snapshot.transferID), ContinuityReducer.isCanonicalID(snapshot.assetID) else { throw BackgroundTransferError.invalidIdentity }
        guard snapshot.receivedBytes >= 0 else { throw BackgroundTransferError.invalidByteCount }
        if let expected = snapshot.expectedBytes {
            guard expected >= 0 else { throw BackgroundTransferError.invalidByteCount }
            guard snapshot.receivedBytes <= expected else { throw BackgroundTransferError.expectedSizeExceeded }
        }
        if snapshot.state == .suspended {
            guard let token = snapshot.resumeOpaqueToken, ContinuityReducer.isCanonicalID(token) else { throw BackgroundTransferError.missingResumeToken }
        } else if snapshot.resumeOpaqueToken != nil { throw BackgroundTransferError.invalidStateTransition }
    }

    public static func start(_ s: BackgroundTransferSnapshot) throws -> BackgroundTransferSnapshot {
        try validate(s); guard s.state == .queued else { throw BackgroundTransferError.invalidStateTransition }
        return BackgroundTransferSnapshot(transferID: s.transferID, assetID: s.assetID, state: .running, receivedBytes: s.receivedBytes, expectedBytes: s.expectedBytes)
    }
    public static func recordProgress(receivedBytes: Int64, expectedBytes: Int64?, in s: BackgroundTransferSnapshot) throws -> BackgroundTransferSnapshot {
        try validate(s); guard s.state == .running else { throw BackgroundTransferError.invalidStateTransition }
        guard receivedBytes >= s.receivedBytes else { throw BackgroundTransferError.byteCountRegression }
        if let old = s.expectedBytes, let new = expectedBytes, old != new { throw BackgroundTransferError.invalidByteCount }
        let next = BackgroundTransferSnapshot(transferID: s.transferID, assetID: s.assetID, state: .running, receivedBytes: receivedBytes, expectedBytes: expectedBytes ?? s.expectedBytes)
        try validate(next); return next
    }
    public static func suspend(resumeOpaqueToken: String, in s: BackgroundTransferSnapshot) throws -> BackgroundTransferSnapshot {
        try validate(s); guard s.state == .running, ContinuityReducer.isCanonicalID(resumeOpaqueToken) else { throw BackgroundTransferError.missingResumeToken }
        return BackgroundTransferSnapshot(transferID: s.transferID, assetID: s.assetID, state: .suspended, receivedBytes: s.receivedBytes, expectedBytes: s.expectedBytes, resumeOpaqueToken: resumeOpaqueToken)
    }
    public static func resume(_ s: BackgroundTransferSnapshot) throws -> BackgroundTransferSnapshot {
        try validate(s); guard s.canResume else { throw BackgroundTransferError.missingResumeToken }
        return BackgroundTransferSnapshot(transferID: s.transferID, assetID: s.assetID, state: .running, receivedBytes: s.receivedBytes, expectedBytes: s.expectedBytes)
    }
    public static func fail(_ s: BackgroundTransferSnapshot) throws -> BackgroundTransferSnapshot {
        try validate(s); guard s.state == .running else { throw BackgroundTransferError.invalidStateTransition }
        return BackgroundTransferSnapshot(transferID: s.transferID, assetID: s.assetID, state: .failed, receivedBytes: s.receivedBytes, expectedBytes: s.expectedBytes)
    }
    public static func restartFromBeginning(_ s: BackgroundTransferSnapshot) throws -> BackgroundTransferSnapshot {
        try validate(s); guard s.state == .failed else { throw BackgroundTransferError.invalidStateTransition }
        return BackgroundTransferSnapshot(transferID: s.transferID, assetID: s.assetID, state: .running, receivedBytes: 0, expectedBytes: s.expectedBytes)
    }
    public static func complete(_ s: BackgroundTransferSnapshot) throws -> BackgroundTransferSnapshot {
        try validate(s); guard s.state == .running else { throw BackgroundTransferError.invalidStateTransition }
        if let expected = s.expectedBytes, s.receivedBytes != expected { throw BackgroundTransferError.invalidByteCount }
        return BackgroundTransferSnapshot(transferID: s.transferID, assetID: s.assetID, state: .completed, receivedBytes: s.receivedBytes, expectedBytes: s.expectedBytes)
    }
}
