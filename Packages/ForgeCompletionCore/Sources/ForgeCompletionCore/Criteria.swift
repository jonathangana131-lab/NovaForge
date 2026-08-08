import Foundation

public enum ForgeCompletionCriterionKind: String, Codable, CaseIterable, Sendable {
    case build
    case launch
    case runtimeStability
    case controlsReachable
    case coreLoopReachable
    case goalJourney
    case persistence
    case visual
    case accessibility
    case performance
    case defectAudit
    case custom
}

public enum ForgeCompletionEvidenceClass: String, Codable, CaseIterable, Hashable, Sendable {
    case buildReceipt
    case launchReceipt
    case runtimeTest
    case semanticJourney
    case persistenceTest
    case visualInspection
    case accessibilityAudit
    case performanceMeasurement
    case defectAudit
    case userAcceptance
    case modelAssertion
}

public enum ForgeCompletionEvidenceProducer: String, Codable, Sendable {
    case buildSystem
    case runtimeHarness
    case semanticPlaytest
    case persistenceHarness
    case visualQA
    case accessibilityHarness
    case performanceHarness
    case defectTracker
    case user
    case model

    func mayProduce(_ evidenceClass: ForgeCompletionEvidenceClass) -> Bool {
        switch (self, evidenceClass) {
        case (.buildSystem, .buildReceipt),
             (.runtimeHarness, .launchReceipt),
             (.runtimeHarness, .runtimeTest),
             (.semanticPlaytest, .semanticJourney),
             (.persistenceHarness, .persistenceTest),
             (.visualQA, .visualInspection),
             (.accessibilityHarness, .accessibilityAudit),
             (.performanceHarness, .performanceMeasurement),
             (.defectTracker, .defectAudit),
             (.user, .userAcceptance),
             (.model, .modelAssertion):
            true
        default:
            false
        }
    }
}

public enum ForgeCompletionEnvironmentKind: String, Codable, Sendable {
    case deterministicHarness
    case runtimeHost
    case simulator
    case physicalDevice
    case userObservation
    case modelOnly
}

public struct ForgeCompletionEvidenceEnvironment: Codable, Hashable, Sendable {
    public let kind: ForgeCompletionEnvironmentKind
    public let identity: String

    public init(kind: ForgeCompletionEnvironmentKind, identity: String) throws {
        self.kind = kind
        self.identity = try validatedCanonicalID(identity, field: "environment.identity")
    }

    private enum CodingKeys: String, CodingKey { case kind, identity }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            kind: container.decode(ForgeCompletionEnvironmentKind.self, forKey: .kind),
            identity: container.decode(String.self, forKey: .identity)
        )
    }
}

public enum ForgeCompletionEnvironmentRequirement: Codable, Hashable, Sendable {
    case any
    case simulatorOrPhysical
    case physicalDevice
    case exact(ForgeCompletionEvidenceEnvironment)

    func accepts(_ environment: ForgeCompletionEvidenceEnvironment) -> Bool {
        switch self {
        case .any:
            return true
        case .simulatorOrPhysical:
            return environment.kind == .simulator || environment.kind == .physicalDevice
        case .physicalDevice:
            return environment.kind == .physicalDevice
        case let .exact(required):
            return environment == required
        }
    }
}

public struct ForgeCompletionCriterion: Codable, Hashable, Sendable {
    public let id: String
    public let kind: ForgeCompletionCriterionKind
    public let title: String
    public let requiredEvidenceClasses: [ForgeCompletionEvidenceClass]
    public let environmentRequirement: ForgeCompletionEnvironmentRequirement

    public init(
        id: String,
        kind: ForgeCompletionCriterionKind,
        title: String,
        requiredEvidenceClasses: [ForgeCompletionEvidenceClass],
        environmentRequirement: ForgeCompletionEnvironmentRequirement = .any
    ) throws {
        self.id = try validatedCanonicalID(id, field: "criterion.id")
        self.kind = kind
        self.title = try validatedNonblank(title, field: "criterion.title")
        guard !requiredEvidenceClasses.isEmpty else {
            throw ForgeCompletionValidationError.noRequiredEvidence(self.id)
        }
        var seen = Set<ForgeCompletionEvidenceClass>()
        for evidenceClass in requiredEvidenceClasses {
            guard evidenceClass != .modelAssertion else {
                throw ForgeCompletionValidationError.modelAssertionCannotBeRequired(self.id)
            }
            guard seen.insert(evidenceClass).inserted else {
                throw ForgeCompletionValidationError.duplicateEvidenceClass(self.id)
            }
        }
        if kind == .defectAudit && !seen.contains(.defectAudit) {
            throw ForgeCompletionValidationError.defectAuditMustRequireDefectEvidence(self.id)
        }
        self.requiredEvidenceClasses = requiredEvidenceClasses.sorted { $0.rawValue < $1.rawValue }
        self.environmentRequirement = environmentRequirement
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, title, requiredEvidenceClasses, environmentRequirement
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(String.self, forKey: .id),
            kind: container.decode(ForgeCompletionCriterionKind.self, forKey: .kind),
            title: container.decode(String.self, forKey: .title),
            requiredEvidenceClasses: container.decode([ForgeCompletionEvidenceClass].self, forKey: .requiredEvidenceClasses),
            environmentRequirement: container.decode(ForgeCompletionEnvironmentRequirement.self, forKey: .environmentRequirement)
        )
    }
}

/// A machine-readable definition of done. It references the canonical Mission identity but does not own mission state.
public struct ForgeCompletionConstitution: Codable, Sendable {
    public static let currentSchemaVersion: UInt16 = 1

    public let schemaVersion: UInt16
    public let constitutionID: String
    public let constitutionRevision: UInt64
    public let scope: ForgeCompletionScope
    public let criteria: [ForgeCompletionCriterion]
    public let allowsKnownLimitations: Bool

    public init(
        schemaVersion: UInt16 = Self.currentSchemaVersion,
        constitutionID: String,
        constitutionRevision: UInt64,
        scope: ForgeCompletionScope,
        criteria: [ForgeCompletionCriterion],
        allowsKnownLimitations: Bool
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ForgeCompletionValidationError.unknownSchema(schemaVersion)
        }
        self.schemaVersion = schemaVersion
        self.constitutionID = try validatedCanonicalID(constitutionID, field: "constitutionID")
        guard constitutionRevision > 0 else {
            throw ForgeCompletionValidationError.invalidRevision("constitutionRevision")
        }
        self.constitutionRevision = constitutionRevision
        self.scope = scope
        guard !criteria.isEmpty else { throw ForgeCompletionValidationError.noCriteria }
        var seen = Set<String>()
        var defectAuditCount = 0
        for criterion in criteria {
            guard seen.insert(criterion.id).inserted else {
                throw ForgeCompletionValidationError.duplicateCriterionID(criterion.id)
            }
            if criterion.kind == .defectAudit { defectAuditCount += 1 }
        }
        guard defectAuditCount > 0 else { throw ForgeCompletionValidationError.missingDefectAuditCriterion }
        guard defectAuditCount == 1 else { throw ForgeCompletionValidationError.duplicateDefectAuditCriterion }
        self.criteria = criteria.sorted { $0.id < $1.id }
        self.allowsKnownLimitations = allowsKnownLimitations
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, constitutionID, constitutionRevision, scope, criteria, allowsKnownLimitations
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(UInt16.self, forKey: .schemaVersion),
            constitutionID: container.decode(String.self, forKey: .constitutionID),
            constitutionRevision: container.decode(UInt64.self, forKey: .constitutionRevision),
            scope: container.decode(ForgeCompletionScope.self, forKey: .scope),
            criteria: container.decode([ForgeCompletionCriterion].self, forKey: .criteria),
            allowsKnownLimitations: container.decode(Bool.self, forKey: .allowsKnownLimitations)
        )
    }
}
