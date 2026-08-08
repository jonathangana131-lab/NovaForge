import Foundation

public enum ForgeCompactResumeError: Error, Equatable, Sendable {
    case invalidIdentifier(field: String)
    case invalidMissionRevision
    case unsupportedSchema(Int)
}

private func validatedResumeIdentifier(_ value: String, field: String) throws -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          trimmed == value,
          value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
        throw ForgeCompactResumeError.invalidIdentifier(field: field)
    }
    return value
}

private func validatedOptionalResumeIdentifier(
    _ value: String?,
    field: String
) throws -> String? {
    guard let value else {
        return nil
    }
    return try validatedResumeIdentifier(value, field: field)
}

/// Opaque authority references required to resume a compacted mission safely.
///
/// This type deliberately references canonical Mission Engine / Project Brain
/// truth instead of copying their state. The referenced receipts/revisions must
/// be resolved by the integration layer before work resumes.
public struct ForgeCompactResumeAuthority: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let capsule: ForgeProjectCapsule
    public let currentStageID: String
    public let projectBrainRevisionID: String
    public let acceptedCheckpointReceiptID: String
    public let missionPolicyReceiptID: String
    public let modelPolicyReceiptID: String
    public let designDNARevisionID: String?

    public init(
        schemaVersion: Int = ForgeCompactResumeAuthority.currentSchemaVersion,
        capsule: ForgeProjectCapsule,
        currentStageID: String,
        projectBrainRevisionID: String,
        acceptedCheckpointReceiptID: String,
        missionPolicyReceiptID: String,
        modelPolicyReceiptID: String,
        designDNARevisionID: String? = nil
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ForgeCompactResumeError.unsupportedSchema(schemaVersion)
        }

        self.schemaVersion = schemaVersion
        self.capsule = capsule
        self.currentStageID = try validatedResumeIdentifier(
            currentStageID,
            field: "resume.currentStageID"
        )
        self.projectBrainRevisionID = try validatedResumeIdentifier(
            projectBrainRevisionID,
            field: "resume.projectBrainRevisionID"
        )
        self.acceptedCheckpointReceiptID = try validatedResumeIdentifier(
            acceptedCheckpointReceiptID,
            field: "resume.acceptedCheckpointReceiptID"
        )
        self.missionPolicyReceiptID = try validatedResumeIdentifier(
            missionPolicyReceiptID,
            field: "resume.missionPolicyReceiptID"
        )
        self.modelPolicyReceiptID = try validatedResumeIdentifier(
            modelPolicyReceiptID,
            field: "resume.modelPolicyReceiptID"
        )
        self.designDNARevisionID = try validatedOptionalResumeIdentifier(
            designDNARevisionID,
            field: "resume.designDNARevisionID"
        )
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case capsule
        case currentStageID
        case projectBrainRevisionID
        case acceptedCheckpointReceiptID
        case missionPolicyReceiptID
        case modelPolicyReceiptID
        case designDNARevisionID
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
            capsule: container.decode(ForgeProjectCapsule.self, forKey: .capsule),
            currentStageID: container.decode(String.self, forKey: .currentStageID),
            projectBrainRevisionID: container.decode(String.self, forKey: .projectBrainRevisionID),
            acceptedCheckpointReceiptID: container.decode(
                String.self,
                forKey: .acceptedCheckpointReceiptID
            ),
            missionPolicyReceiptID: container.decode(String.self, forKey: .missionPolicyReceiptID),
            modelPolicyReceiptID: container.decode(String.self, forKey: .modelPolicyReceiptID),
            designDNARevisionID: container.decodeIfPresent(String.self, forKey: .designDNARevisionID)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(capsule, forKey: .capsule)
        try container.encode(currentStageID, forKey: .currentStageID)
        try container.encode(projectBrainRevisionID, forKey: .projectBrainRevisionID)
        try container.encode(acceptedCheckpointReceiptID, forKey: .acceptedCheckpointReceiptID)
        try container.encode(missionPolicyReceiptID, forKey: .missionPolicyReceiptID)
        try container.encode(modelPolicyReceiptID, forKey: .modelPolicyReceiptID)
        try container.encodeIfPresent(designDNARevisionID, forKey: .designDNARevisionID)
    }
}

public struct ForgeCompactResumeTarget: Equatable, Sendable {
    public let projectID: String
    public let missionID: String
    public let sourceRevision: String
    public let missionRevision: Int

    public init(
        projectID: String,
        missionID: String,
        sourceRevision: String,
        missionRevision: Int
    ) throws {
        guard missionRevision > 0 else {
            throw ForgeCompactResumeError.invalidMissionRevision
        }
        self.projectID = try validatedResumeIdentifier(projectID, field: "target.projectID")
        self.missionID = try validatedResumeIdentifier(missionID, field: "target.missionID")
        self.sourceRevision = try validatedResumeIdentifier(
            sourceRevision,
            field: "target.sourceRevision"
        )
        self.missionRevision = missionRevision
    }
}

public enum ForgeCompactResumeGate {
    /// Fails closed on any project, mission, source, or mission-revision drift.
    /// Receipt existence/validity is checked by the canonical integration layer.
    public static func canResume(
        authority: ForgeCompactResumeAuthority,
        target: ForgeCompactResumeTarget
    ) -> Bool {
        let capsule = authority.capsule
        return capsule.projectID == target.projectID
            && capsule.missionID == target.missionID
            && capsule.sourceRevision == target.sourceRevision
            && capsule.missionRevision == target.missionRevision
    }
}
