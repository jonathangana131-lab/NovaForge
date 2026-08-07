import Foundation

public enum ContinuityArchiveError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case invalidSnapshot
    case duplicateTransferID(String)
    case invalidTransfer(String)
}

public struct ContinuityArchive: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let snapshot: ContinuitySnapshot
    public let transfers: [BackgroundTransferSnapshot]

    public init(snapshot: ContinuitySnapshot, transfers: [BackgroundTransferSnapshot] = []) throws {
        try Self.validate(snapshot: snapshot, transfers: transfers)
        self.schemaVersion = Self.currentSchemaVersion
        self.snapshot = snapshot
        self.transfers = transfers.sorted { $0.transferID < $1.transferID }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case snapshot
        case transfers
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported continuity archive schema version \(schemaVersion)."
            )
        }
        let snapshot = try container.decode(ContinuitySnapshot.self, forKey: .snapshot)
        let transfers = try container.decode([BackgroundTransferSnapshot].self, forKey: .transfers)
        do {
            try Self.validate(snapshot: snapshot, transfers: transfers)
        } catch {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid persisted continuity archive.",
                    underlyingError: error
                )
            )
        }
        self.schemaVersion = schemaVersion
        self.snapshot = snapshot
        self.transfers = transfers.sorted { $0.transferID < $1.transferID }
    }

    public func encode(to encoder: any Encoder) throws {
        try Self.validate(snapshot: snapshot, transfers: transfers)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(snapshot, forKey: .snapshot)
        try container.encode(transfers.sorted { $0.transferID < $1.transferID }, forKey: .transfers)
    }

    public static func validate(
        snapshot: ContinuitySnapshot,
        transfers: [BackgroundTransferSnapshot]
    ) throws {
        do {
            try ContinuityReducer.validate(snapshot)
        } catch {
            throw ContinuityArchiveError.invalidSnapshot
        }
        var transferIDs = Set<String>()
        for transfer in transfers {
            guard transferIDs.insert(transfer.transferID).inserted else {
                throw ContinuityArchiveError.duplicateTransferID(transfer.transferID)
            }
            do {
                try BackgroundTransferReducer.validate(transfer)
            } catch {
                throw ContinuityArchiveError.invalidTransfer(transfer.transferID)
            }
        }
    }
}
