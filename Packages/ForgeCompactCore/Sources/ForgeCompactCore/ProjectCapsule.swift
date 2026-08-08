import Foundation

public struct ForgeCompactCapsuleReference: Hashable, Codable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Hashable, Sendable {
        case missionConstitution
        case currentObjective
        case currentStage
        case privacyPolicy
        case acceptedDecision
        case designDNA
        case sourceSymbol
        case testReceipt
        case runtimeReceipt
        case visualReceipt
        case defect
        case knownLimitation
    }

    public let id: String
    public let kind: Kind
    public let authorityRevision: String
    public let estimatedPromptBytes: Int

    public init(id: String, kind: Kind, authorityRevision: String, estimatedPromptBytes: Int) throws {
        guard estimatedPromptBytes >= 0 else {
            throw ForgeCompactValidationError.invalidMetric("estimatedPromptBytes")
        }
        self.id = try validatedText(id, field: "capsuleReference.id")
        self.kind = kind
        self.authorityRevision = try validatedText(authorityRevision, field: "capsuleReference.authorityRevision")
        self.estimatedPromptBytes = estimatedPromptBytes
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: values.decode(String.self, forKey: .id),
            kind: values.decode(Kind.self, forKey: .kind),
            authorityRevision: values.decode(String.self, forKey: .authorityRevision),
            estimatedPromptBytes: values.decode(Int.self, forKey: .estimatedPromptBytes)
        )
    }
}

public struct ForgeCompactProjectCapsule: Hashable, Codable, Sendable {
    public static let requiredReferenceKinds: Set<ForgeCompactCapsuleReference.Kind> = [
        .missionConstitution,
        .currentObjective,
        .currentStage,
        .privacyPolicy
    ]

    public let capsuleID: String
    public let projectID: String
    public let sourceRevision: String
    public let schemaVersion: Int
    public let maximumPromptBytes: Int
    public let references: [ForgeCompactCapsuleReference]

    public init(
        capsuleID: String,
        projectID: String,
        sourceRevision: String,
        schemaVersion: Int = 1,
        maximumPromptBytes: Int,
        references: [ForgeCompactCapsuleReference]
    ) throws {
        guard schemaVersion == 1 else {
            throw ForgeCompactValidationError.invalidQualification("unsupported capsule schema")
        }
        guard maximumPromptBytes > 0 else {
            throw ForgeCompactValidationError.invalidMetric("maximumPromptBytes")
        }

        var seenIDs = Set<String>()
        for reference in references {
            let key = reference.id.lowercased()
            guard seenIDs.insert(key).inserted else {
                throw ForgeCompactValidationError.duplicateReference(reference.id)
            }
        }
        let kinds = Set(references.map(\.kind))
        for requiredKind in Self.requiredReferenceKinds where !kinds.contains(requiredKind) {
            throw ForgeCompactValidationError.missingRequiredReference(requiredKind)
        }
        let totalBytes = references.reduce(0) { partial, reference in
            partial + reference.estimatedPromptBytes
        }
        guard totalBytes <= maximumPromptBytes else {
            throw ForgeCompactValidationError.capsuleBudgetExceeded
        }

        self.capsuleID = try validatedText(capsuleID, field: "capsuleID")
        self.projectID = try validatedText(projectID, field: "projectID")
        self.sourceRevision = try validatedText(sourceRevision, field: "sourceRevision")
        self.schemaVersion = schemaVersion
        self.maximumPromptBytes = maximumPromptBytes
        self.references = references.sorted {
            if $0.kind.rawValue == $1.kind.rawValue { return $0.id < $1.id }
            return $0.kind.rawValue < $1.kind.rawValue
        }
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            capsuleID: values.decode(String.self, forKey: .capsuleID),
            projectID: values.decode(String.self, forKey: .projectID),
            sourceRevision: values.decode(String.self, forKey: .sourceRevision),
            schemaVersion: values.decode(Int.self, forKey: .schemaVersion),
            maximumPromptBytes: values.decode(Int.self, forKey: .maximumPromptBytes),
            references: values.decode([ForgeCompactCapsuleReference].self, forKey: .references)
        )
    }

    public var estimatedPromptBytes: Int {
        references.reduce(0) { $0 + $1.estimatedPromptBytes }
    }
}
