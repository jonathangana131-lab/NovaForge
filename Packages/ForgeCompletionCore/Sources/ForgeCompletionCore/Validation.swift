import Foundation

public enum ForgeCompletionValidationError: Error, Equatable, Sendable {
    case blankField(String)
    case nonCanonicalField(String)
    case invalidRevision(String)
    case noCriteria
    case duplicateCriterionID(String)
    case missingDefectAuditCriterion
    case duplicateDefectAuditCriterion
    case noRequiredEvidence(String)
    case duplicateEvidenceClass(String)
    case modelAssertionCannotBeRequired(String)
    case defectAuditMustRequireDefectEvidence(String)
    case evidenceProducerMismatch
    case duplicateReceiptID(String)
    case conflictingCurrentEvidence(String)
    case duplicateDefectID(String)
    case duplicateLimitationID(String)
    case invalidLimitationDefectID
    case unknownSchema(UInt16)
}

@inline(__always)
func validatedNonblank(_ value: String, field: String) throws -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw ForgeCompletionValidationError.blankField(field) }
    return trimmed
}

@inline(__always)
func validatedCanonicalID(_ value: String, field: String) throws -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw ForgeCompletionValidationError.blankField(field) }
    guard trimmed == value else { throw ForgeCompletionValidationError.nonCanonicalField(field) }
    return value
}

public struct ForgeCompletionScope: Codable, Hashable, Sendable {
    public let projectID: String
    public let projectRevision: UInt64
    public let missionID: String
    public let missionRevision: UInt64
    public let checkpointID: String

    public init(
        projectID: String,
        projectRevision: UInt64,
        missionID: String,
        missionRevision: UInt64,
        checkpointID: String
    ) throws {
        self.projectID = try validatedCanonicalID(projectID, field: "projectID")
        guard projectRevision > 0 else { throw ForgeCompletionValidationError.invalidRevision("projectRevision") }
        self.projectRevision = projectRevision
        self.missionID = try validatedCanonicalID(missionID, field: "missionID")
        guard missionRevision > 0 else { throw ForgeCompletionValidationError.invalidRevision("missionRevision") }
        self.missionRevision = missionRevision
        self.checkpointID = try validatedCanonicalID(checkpointID, field: "checkpointID")
    }

    private enum CodingKeys: String, CodingKey {
        case projectID, projectRevision, missionID, missionRevision, checkpointID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            projectID: container.decode(String.self, forKey: .projectID),
            projectRevision: container.decode(UInt64.self, forKey: .projectRevision),
            missionID: container.decode(String.self, forKey: .missionID),
            missionRevision: container.decode(UInt64.self, forKey: .missionRevision),
            checkpointID: container.decode(String.self, forKey: .checkpointID)
        )
    }
}
