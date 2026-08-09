import Foundation

public enum ForgeAccessibilityObservationOutcome: String, Codable, Hashable, Sendable {
    case passed
    case failed
    case inconclusive
    case notRun
}

public enum ForgeAccessibilityProducer: String, Codable, Hashable, Sendable {
    case xctest
    case accessibilityAutomation
    case runtimeHost
    case manualHostAudit
}

public struct ForgeAccessibilityObservation: Codable, Hashable, Sendable {
    public static let maximumFindings = 64

    public let id: ForgeAccessibilityID
    public let target: ForgeAccessibilityTarget
    public let requirementID: ForgeAccessibilityID
    public let category: ForgeAccessibilityCategory
    public let environment: ForgeAccessibilityEnvironment
    public let outcome: ForgeAccessibilityObservationOutcome
    public let producer: ForgeAccessibilityProducer
    public let evidenceReceiptID: ForgeAccessibilityID
    public let findings: [ForgeAccessibilityFinding]

    public init(
        id: ForgeAccessibilityID,
        target: ForgeAccessibilityTarget,
        requirementID: ForgeAccessibilityID,
        category: ForgeAccessibilityCategory,
        environment: ForgeAccessibilityEnvironment,
        outcome: ForgeAccessibilityObservationOutcome,
        producer: ForgeAccessibilityProducer,
        evidenceReceiptID: ForgeAccessibilityID,
        findings: [ForgeAccessibilityFinding] = []
    ) throws {
        guard findings.count <= Self.maximumFindings else {
            throw ForgeAccessibilityError.tooManyFindings(observationID: id.rawValue, count: findings.count)
        }
        if outcome == .failed && findings.isEmpty {
            throw ForgeAccessibilityError.failedObservationRequiresFinding(id.rawValue)
        }
        var findingIDs = Set<ForgeAccessibilityID>()
        for finding in findings {
            guard finding.category == category else {
                throw ForgeAccessibilityError.findingCategoryMismatch(finding.id.rawValue)
            }
            guard findingIDs.insert(finding.id).inserted else {
                throw ForgeAccessibilityError.duplicateFindingID(finding.id.rawValue)
            }
        }
        self.id = id
        self.target = target
        self.requirementID = requirementID
        self.category = category
        self.environment = environment
        self.outcome = outcome
        self.producer = producer
        self.evidenceReceiptID = evidenceReceiptID
        self.findings = findings.sorted { $0.id < $1.id }
    }

    private enum CodingKeys: String, CodingKey {
        case id, target, requirementID, category, environment, outcome, producer, evidenceReceiptID, findings
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: c.decode(ForgeAccessibilityID.self, forKey: .id),
            target: c.decode(ForgeAccessibilityTarget.self, forKey: .target),
            requirementID: c.decode(ForgeAccessibilityID.self, forKey: .requirementID),
            category: c.decode(ForgeAccessibilityCategory.self, forKey: .category),
            environment: c.decode(ForgeAccessibilityEnvironment.self, forKey: .environment),
            outcome: c.decode(ForgeAccessibilityObservationOutcome.self, forKey: .outcome),
            producer: c.decode(ForgeAccessibilityProducer.self, forKey: .producer),
            evidenceReceiptID: c.decode(ForgeAccessibilityID.self, forKey: .evidenceReceiptID),
            findings: c.decode([ForgeAccessibilityFinding].self, forKey: .findings)
        )
    }
}

public struct ForgeAccessibilityAssessment: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1
    public static let maximumObservations = 64

    public let schemaVersion: Int
    public let target: ForgeAccessibilityTarget
    public let policy: ForgeAccessibilityAcceptancePolicy
    public let observations: [ForgeAccessibilityObservation]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        target: ForgeAccessibilityTarget,
        policy: ForgeAccessibilityAcceptancePolicy,
        observations: [ForgeAccessibilityObservation]
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ForgeAccessibilityError.unsupportedSchema(schemaVersion)
        }
        guard observations.count <= Self.maximumObservations else {
            throw ForgeAccessibilityError.tooManyObservations(observations.count)
        }

        let requirementsByID = Dictionary(uniqueKeysWithValues: policy.requirements.map { ($0.id, $0) })
        var observationIDs = Set<ForgeAccessibilityID>()
        var observedRequirements = Set<ForgeAccessibilityID>()
        var receiptIDs = Set<ForgeAccessibilityID>()
        var globalFindingIDs = Set<ForgeAccessibilityID>()

        for observation in observations {
            guard observationIDs.insert(observation.id).inserted else {
                throw ForgeAccessibilityError.duplicateObservationID(observation.id.rawValue)
            }
            guard observation.target == target else {
                throw ForgeAccessibilityError.observationTargetMismatch(observation.id.rawValue)
            }
            guard let requirement = requirementsByID[observation.requirementID] else {
                throw ForgeAccessibilityError.unknownRequirement(observation.requirementID.rawValue)
            }
            guard observedRequirements.insert(observation.requirementID).inserted else {
                throw ForgeAccessibilityError.duplicateObservationForRequirement(observation.requirementID.rawValue)
            }
            guard requirement.category == observation.category else {
                throw ForgeAccessibilityError.observationCategoryMismatch(observation.id.rawValue)
            }
            guard receiptIDs.insert(observation.evidenceReceiptID).inserted else {
                throw ForgeAccessibilityError.duplicateEvidenceReceiptID(observation.evidenceReceiptID.rawValue)
            }
            for finding in observation.findings {
                guard globalFindingIDs.insert(finding.id).inserted else {
                    throw ForgeAccessibilityError.duplicateFindingID(finding.id.rawValue)
                }
            }
        }

        self.schemaVersion = schemaVersion
        self.target = target
        self.policy = policy
        self.observations = observations.sorted { $0.requirementID < $1.requirementID }
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, target, policy, observations }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: c.decode(Int.self, forKey: .schemaVersion),
            target: c.decode(ForgeAccessibilityTarget.self, forKey: .target),
            policy: c.decode(ForgeAccessibilityAcceptancePolicy.self, forKey: .policy),
            observations: c.decode([ForgeAccessibilityObservation].self, forKey: .observations)
        )
    }
}

/// Host code must authenticate the complete observation subject against the canonical producer receipt.
/// Decoding an observation, seeing a known producer enum, or matching a receipt ID is never sufficient.
