import Foundation

public struct ProjectCapsuleArchive: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1
    /// Generous outer safety envelopes. They prevent unbounded retained archive work but are not
    /// recommended product defaults or physical-device performance claims.
    public static let maximumCapsules = 1_024
    public static let maximumTotalSourceItems = 65_536
    public static let maximumRenderedUTF8Bytes = 64_000_000

    public let schemaVersion: Int
    public let projectID: String
    public let missionID: String
    public let capsules: [ProjectCapsule]

    public init(projectID: String, missionID: String, capsules: [ProjectCapsule]) throws {
        self.schemaVersion = Self.currentSchemaVersion
        self.projectID = try ForgeCompactValidation.identifier(projectID, field: "archive.projectID")
        self.missionID = try ForgeCompactValidation.identifier(missionID, field: "archive.missionID")
        self.capsules = capsules
        try validate()
    }

    private init(schemaVersion: Int, projectID: String, missionID: String, capsules: [ProjectCapsule]) throws {
        self.schemaVersion = schemaVersion
        self.projectID = try ForgeCompactValidation.identifier(projectID, field: "archive.projectID")
        self.missionID = try ForgeCompactValidation.identifier(missionID, field: "archive.missionID")
        self.capsules = capsules
        try validate()
    }

    static func checkedArchiveTotals(
        currentSourceItems: Int,
        addingSourceItems: Int,
        currentRenderedUTF8Bytes: Int,
        addingRenderedUTF8Bytes: Int
    ) throws -> (sourceItems: Int, renderedUTF8Bytes: Int) {
        guard currentSourceItems >= 0,
              addingSourceItems >= 0,
              currentRenderedUTF8Bytes >= 0,
              addingRenderedUTF8Bytes >= 0
        else {
            throw ForgeCompactError.invalidCapsuleShape
        }

        let (sourceItems, sourceOverflow) = currentSourceItems.addingReportingOverflow(addingSourceItems)
        guard !sourceOverflow, sourceItems <= Self.maximumTotalSourceItems else {
            throw ForgeCompactError.collectionTooLarge(
                field: "archive.sourceItems",
                maximum: Self.maximumTotalSourceItems
            )
        }

        let (renderedUTF8Bytes, byteOverflow) = currentRenderedUTF8Bytes.addingReportingOverflow(addingRenderedUTF8Bytes)
        guard !byteOverflow, renderedUTF8Bytes <= Self.maximumRenderedUTF8Bytes else {
            throw ForgeCompactError.collectionTooLarge(
                field: "archive.renderedUTF8Bytes",
                maximum: Self.maximumRenderedUTF8Bytes
            )
        }

        return (sourceItems, renderedUTF8Bytes)
    }

    private func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ForgeCompactError.invalidArchiveSchema(schemaVersion)
        }
        guard !projectID.isEmpty, !missionID.isEmpty else {
            throw ForgeCompactError.archiveIdentityMismatch
        }
        try ForgeCompactValidation.maximumCount(
            capsules.count,
            field: "archive.capsules",
            maximum: Self.maximumCapsules
        )

        var previousCapsuleRevision: Int?
        var previousMissionRevision: Int?
        var previousAuthorityEpoch: Int?
        var totalSourceItems = 0
        var totalRenderedUTF8Bytes = 0

        for capsule in capsules {
            let authority = capsule.authority
            guard authority.projectID == projectID, authority.missionID == missionID else {
                throw ForgeCompactError.archiveIdentityMismatch
            }

            let totals = try Self.checkedArchiveTotals(
                currentSourceItems: totalSourceItems,
                addingSourceItems: capsule.sourceItemCount,
                currentRenderedUTF8Bytes: totalRenderedUTF8Bytes,
                addingRenderedUTF8Bytes: capsule.renderedUTF8Bytes
            )
            totalSourceItems = totals.sourceItems
            totalRenderedUTF8Bytes = totals.renderedUTF8Bytes

            if let previousCapsuleRevision, authority.capsuleRevision <= previousCapsuleRevision {
                throw ForgeCompactError.archiveRevisionRegression
            }
            if let previousMissionRevision, authority.missionRevision < previousMissionRevision {
                throw ForgeCompactError.archiveRevisionRegression
            }
            if let previousAuthorityEpoch, authority.authorityEpoch < previousAuthorityEpoch {
                throw ForgeCompactError.archiveRevisionRegression
            }
            previousCapsuleRevision = authority.capsuleRevision
            previousMissionRevision = authority.missionRevision
            previousAuthorityEpoch = authority.authorityEpoch
        }
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, projectID, missionID, capsules }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: c.decode(Int.self, forKey: .schemaVersion),
            projectID: c.decode(String.self, forKey: .projectID),
            missionID: c.decode(String.self, forKey: .missionID),
            capsules: c.decode([ProjectCapsule].self, forKey: .capsules)
        )
    }
}
