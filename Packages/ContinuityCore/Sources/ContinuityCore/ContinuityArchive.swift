import Foundation

public enum ContinuityArchiveError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case invalidSnapshot
    case duplicateTransferID(String)
    case tooManyTransfers
    case invalidTransfer(String)
}

public struct ContinuityArchivedSnapshot: Codable, Hashable, Sendable {
    public let identity: ContinuityIdentity
    public let state: ContinuityRunState
    public let epoch: UInt64

    init(live snapshot: ContinuitySnapshot) throws {
        try ContinuityReducer.validate(snapshot)
        identity = snapshot.identity
        epoch = snapshot.epoch
        state = switch snapshot.state {
        case .executing:
            .suspended(.executionEnvironmentLost)
        case .needsDecision, .blocked, .completed:
            // These projections belong to the canonical Mission Engine. Persistence must not
            // become a second authority after relaunch; require fresh Mission revalidation.
            .suspended(.missionStateRevalidationRequired)
        case .ready, .suspended:
            snapshot.state
        }
    }

    public func restore() throws -> ContinuitySnapshot {
        let restored = ContinuitySnapshot(identity: identity, state: state, activeLease: nil, epoch: epoch)
        try ContinuityReducer.validate(restored)
        return restored
    }

    private enum CodingKeys: String, CodingKey { case identity, state, epoch }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        identity = try c.decode(ContinuityIdentity.self, forKey: .identity)
        state = try c.decode(ContinuityRunState.self, forKey: .state)
        epoch = try c.decode(UInt64.self, forKey: .epoch)
        switch state {
        case .ready, .suspended:
            let restored = ContinuitySnapshot(identity: identity, state: state, activeLease: nil, epoch: epoch)
            do { try ContinuityReducer.validate(restored) }
            catch { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid archived continuity snapshot.", underlyingError: error)) }
        case .executing, .needsDecision, .blocked, .completed:
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Live execution and Mission-owned projections cannot be restored as authority from a continuity archive."
            ))
        }
    }
}

public struct ContinuityArchive: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 2
    public static let maximumTransfers = 128

    public let schemaVersion: Int
    public let snapshot: ContinuityArchivedSnapshot
    public let transfers: [BackgroundTransferSnapshot]

    public init(snapshot: ContinuitySnapshot, transfers: [BackgroundTransferSnapshot] = []) throws {
        guard transfers.count <= Self.maximumTransfers else { throw ContinuityArchiveError.tooManyTransfers }
        self.schemaVersion = Self.currentSchemaVersion
        self.snapshot = try ContinuityArchivedSnapshot(live: snapshot)
        self.transfers = try Self.validatedTransfers(transfers)
    }

    public func restore() throws -> ContinuitySnapshot { try snapshot.restore() }

    private enum CodingKeys: String, CodingKey { case schemaVersion, snapshot, transfers }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: c, debugDescription: "Unsupported continuity archive schema version \(version).")
        }
        let snapshot = try c.decode(ContinuityArchivedSnapshot.self, forKey: .snapshot)
        let transfers = try c.decode([BackgroundTransferSnapshot].self, forKey: .transfers)
        guard transfers.count <= Self.maximumTransfers else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Too many continuity transfers."))
        }
        do {
            _ = try snapshot.restore()
            self.transfers = try Self.validatedTransfers(transfers)
        } catch {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid continuity archive.", underlyingError: error))
        }
        self.schemaVersion = version
        self.snapshot = snapshot
    }

    private static func validatedTransfers(_ transfers: [BackgroundTransferSnapshot]) throws -> [BackgroundTransferSnapshot] {
        var ids = Set<String>()
        for transfer in transfers {
            guard ids.insert(transfer.transferID).inserted else { throw ContinuityArchiveError.duplicateTransferID(transfer.transferID) }
            do { try BackgroundTransferReducer.validate(transfer) }
            catch { throw ContinuityArchiveError.invalidTransfer(transfer.transferID) }
        }
        return transfers.sorted { $0.transferID < $1.transferID }
    }
}
