import Foundation

public struct ProjectCapsuleArchive: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

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

    private func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ForgeCompactError.invalidArchiveSchema(schemaVersion)
        }
        guard !projectID.isEmpty, !missionID.isEmpty else {
            throw ForgeCompactError.archiveIdentityMismatch
        }

        var previousCapsuleRevision: Int?
        var previousMissionRevision: Int?
        var previousAuthorityEpoch: Int?

        for capsule in capsules {
            let authority = capsule.authority
            guard authority.projectID == projectID, authority.missionID == missionID else {
                throw ForgeCompactError.archiveIdentityMismatch
            }
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
