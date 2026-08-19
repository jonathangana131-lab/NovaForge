import Foundation

public enum ForgeCompletionError: Error, Equatable, Sendable {
    case invalidIdentifier(String)
    case invalidText(String)
    case invalidRevision(String)
    case unsupportedSchema(Int)
    case collectionTooLarge(field: String, maximum: Int)
    case duplicateCriterionID(String)
    case duplicateEvidenceID(String)
    case duplicateEvidenceAuthorityReceiptID(String)
    case duplicateEvidenceSlot(String)
    case duplicateDefectID(String)
    case duplicateLimitationID(String)
    case invalidCriterion(String)
    case targetMismatch(String)
    case unknownCriterion(String)
    case evidenceForWaivedCriterion(String)
    case unexpectedEvidenceClass(String)
    case unexpectedJourney(String)
    case invalidEvidenceAuthority(String)
    case invalidLimitationDefectReference(String)
}

private enum ForgeCompletionValidation {
    static func identifier(_ value: String, field: String, maximumLength: Int = 512) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximumLength else {
            throw ForgeCompletionError.invalidIdentifier(field)
        }
        guard !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ForgeCompletionError.invalidIdentifier(field)
        }
        return trimmed
    }

    static func text(_ value: String, field: String, maximumLength: Int = 16_384) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximumLength else {
            throw ForgeCompletionError.invalidText(field)
        }
        return trimmed
    }

    static func revision(_ value: Int, field: String) throws -> Int {
        guard value >= 0 else {
            throw ForgeCompletionError.invalidRevision(field)
        }
        return value
    }

    static func maximumCount(_ count: Int, field: String, maximum: Int) throws {
        guard count <= maximum else {
            throw ForgeCompletionError.collectionTooLarge(field: field, maximum: maximum)
        }
    }
}

/// Exact accepted mission/product definition that all completion evidence must describe.
/// The constitution receipt is opaque: authenticity belongs to the canonical Mission adapter.
public struct ForgeCompletionTarget: Codable, Equatable, Hashable, Sendable {
    public let missionID: String
    public let projectID: String
    public let sourceRevision: String
    public let constitutionRevision: Int
    public let constitutionReceiptID: String

    public init(
        missionID: String,
        projectID: String,
        sourceRevision: String,
        constitutionRevision: Int,
        constitutionReceiptID: String
    ) throws {
        self.missionID = try ForgeCompletionValidation.identifier(
            missionID,
            field: "target.missionID",
            maximumLength: 256
        )
        self.projectID = try ForgeCompletionValidation.identifier(
            projectID,
            field: "target.projectID",
            maximumLength: 256
        )
        self.sourceRevision = try ForgeCompletionValidation.identifier(
            sourceRevision,
            field: "target.sourceRevision"
        )
        self.constitutionRevision = try ForgeCompletionValidation.revision(
            constitutionRevision,
            field: "target.constitutionRevision"
        )
        self.constitutionReceiptID = try ForgeCompletionValidation.identifier(
            constitutionReceiptID,
            field: "target.constitutionReceiptID"
        )
    }

    private enum CodingKeys: String, CodingKey {
        case missionID
        case projectID
        case sourceRevision
        case constitutionRevision
        case constitutionReceiptID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            missionID: container.decode(String.self, forKey: .missionID),
            projectID: container.decode(String.self, forKey: .projectID),
            sourceRevision: container.decode(String.self, forKey: .sourceRevision),
            constitutionRevision: container.decode(Int.self, forKey: .constitutionRevision),
            constitutionReceiptID: container.decode(String.self, forKey: .constitutionReceiptID)
        )
    }
}

public enum ForgeCompletionCriterionKind: String, Codable, CaseIterable, Hashable, Sendable {
    case build
    case launch
    case runtimeStability
    case controls
    case coreExperience
    case goalPath
    case restart
    case persistence
    case orientationAndSafeArea
    case visualAcceptance
    case accessibility
    case performance
    case custom
}

public enum ForgeCompletionEvidenceClass: String, Codable, CaseIterable, Hashable, Sendable {
    case buildReceipt
    case launchReceipt
    case runtimeJourney
    case semanticPlaytest
    case persistenceReceipt
    case visualQAReceipt
    case accessibilityReceipt
    case performanceReceipt
    case testReceipt
    case acceptedExternalReceipt

    fileprivate func permits(_ authority: ForgeCompletionEvidenceAuthority) -> Bool {
        switch self {
        case .buildReceipt:
            return authority == .buildSystem || authority == .testHarness || authority == .acceptedExternal
        case .launchReceipt, .runtimeJourney:
            return authority == .runtimeHarness || authority == .testHarness || authority == .acceptedExternal
        case .semanticPlaytest:
            return authority == .playtestHarness || authority == .acceptedExternal
        case .persistenceReceipt:
            return authority == .persistenceHarness || authority == .runtimeHarness || authority == .testHarness || authority == .acceptedExternal
        case .visualQAReceipt:
            return authority == .visualQA || authority == .acceptedExternal
        case .accessibilityReceipt:
            return authority == .accessibilityHarness || authority == .acceptedExternal
        case .performanceReceipt:
            return authority == .performanceHarness || authority == .acceptedExternal
        case .testReceipt:
            return authority == .testHarness || authority == .acceptedExternal
        case .acceptedExternalReceipt:
            return authority == .userAccepted || authority == .acceptedExternal
        }
    }
}

/// Deliberately has no model/model-observation case. A model statement is not completion evidence.
public enum ForgeCompletionEvidenceAuthority: String, Codable, CaseIterable, Sendable {
    case buildSystem
    case runtimeHarness
    case playtestHarness
    case persistenceHarness
    case visualQA
    case accessibilityHarness
    case performanceHarness
    case testHarness
    case userAccepted
    case acceptedExternal
}

public enum ForgeCompletionEvidenceOutcome: String, Codable, CaseIterable, Sendable {
    case passed
    case failed
    case inconclusive
}

public struct ForgeCompletionWaiver: Codable, Equatable, Sendable {
    public let explanation: String
    public let authorityReceiptID: String

    public init(explanation: String, authorityReceiptID: String) throws {
        self.explanation = try ForgeCompletionValidation.text(
            explanation,
            field: "waiver.explanation",
            maximumLength: 4_096
        )
        self.authorityReceiptID = try ForgeCompletionValidation.identifier(
            authorityReceiptID,
            field: "waiver.authorityReceiptID"
        )
    }

    private enum CodingKeys: String, CodingKey {
        case explanation
        case authorityReceiptID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            explanation: container.decode(String.self, forKey: .explanation),
            authorityReceiptID: container.decode(String.self, forKey: .authorityReceiptID)
        )
    }
}

/// There is no silent optional state. A criterion is either required or explicitly authority-waived.
public enum ForgeCompletionRequirement: Codable, Equatable, Sendable {
    case required
    case waived(ForgeCompletionWaiver)
}

public struct ForgeCompletionCriterion: Codable, Equatable, Sendable {
    public static let maximumJourneyIDs = 128

    public let id: String
    public let kind: ForgeCompletionCriterionKind
    public let title: String
    public let requirement: ForgeCompletionRequirement
    public let requiredEvidenceClasses: [ForgeCompletionEvidenceClass]
    public let journeyIDs: [String]

    public init(
        id: String,
        kind: ForgeCompletionCriterionKind,
        title: String,
        requirement: ForgeCompletionRequirement = .required,
        requiredEvidenceClasses: [ForgeCompletionEvidenceClass],
        journeyIDs: [String] = []
    ) throws {
        let normalizedID = try ForgeCompletionValidation.identifier(
            id,
            field: "criterion.id",
            maximumLength: 256
        )
        let normalizedTitle = try ForgeCompletionValidation.text(
            title,
            field: "criterion.title",
            maximumLength: 1_024
        )
        guard !requiredEvidenceClasses.isEmpty else {
            throw ForgeCompletionError.invalidCriterion(normalizedID)
        }

        let canonicalEvidenceClasses = Array(Set(requiredEvidenceClasses)).sorted { $0.rawValue < $1.rawValue }
        guard canonicalEvidenceClasses.count == requiredEvidenceClasses.count else {
            throw ForgeCompletionError.invalidCriterion(normalizedID)
        }

        try ForgeCompletionValidation.maximumCount(
            journeyIDs.count,
            field: "criterion.journeyIDs",
            maximum: Self.maximumJourneyIDs
        )
        let normalizedJourneys = try journeyIDs.map {
            try ForgeCompletionValidation.identifier(
                $0,
                field: "criterion.journeyID",
                maximumLength: 256
            )
        }
        let canonicalJourneys = Array(Set(normalizedJourneys)).sorted()
        guard canonicalJourneys.count == normalizedJourneys.count else {
            throw ForgeCompletionError.invalidCriterion(normalizedID)
        }

        self.id = normalizedID
        self.kind = kind
        self.title = normalizedTitle
        self.requirement = requirement
        self.requiredEvidenceClasses = canonicalEvidenceClasses
        self.journeyIDs = canonicalJourneys
    }

    public var isRequired: Bool {
        if case .required = requirement { return true }
        return false
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case title
        case requirement
        case requiredEvidenceClasses
        case journeyIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(String.self, forKey: .id),
            kind: container.decode(ForgeCompletionCriterionKind.self, forKey: .kind),
            title: container.decode(String.self, forKey: .title),
            requirement: container.decode(ForgeCompletionRequirement.self, forKey: .requirement),
            requiredEvidenceClasses: container.decode([ForgeCompletionEvidenceClass].self, forKey: .requiredEvidenceClasses),
            journeyIDs: container.decode([String].self, forKey: .journeyIDs)
        )
    }
}

public struct ForgeCompletionConstitution: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let maximumCriteria = 128
    public static let maximumRequiredEvidenceSlots = 4_096

    public let schemaVersion: Int
    public let target: ForgeCompletionTarget
    public let criteria: [ForgeCompletionCriterion]

    public init(target: ForgeCompletionTarget, criteria: [ForgeCompletionCriterion]) throws {
        guard !criteria.isEmpty else {
            throw ForgeCompletionError.invalidCriterion("constitution.criteria")
        }
        try ForgeCompletionValidation.maximumCount(
            criteria.count,
            field: "constitution.criteria",
            maximum: Self.maximumCriteria
        )

        var seen = Set<String>()
        var requiredEvidenceSlots = 0
        for criterion in criteria {
            guard seen.insert(criterion.id).inserted else {
                throw ForgeCompletionError.duplicateCriterionID(criterion.id)
            }
            guard criterion.isRequired else { continue }

            requiredEvidenceSlots = try Self.checkedRequiredEvidenceSlotCount(
                evidenceClassCount: criterion.requiredEvidenceClasses.count,
                journeyCount: criterion.journeyIDs.isEmpty ? 1 : criterion.journeyIDs.count,
                currentCount: requiredEvidenceSlots
            )
        }

        self.schemaVersion = Self.currentSchemaVersion
        self.target = target
        self.criteria = criteria.sorted { $0.id < $1.id }
    }

    static func checkedRequiredEvidenceSlotCount(
        evidenceClassCount: Int,
        journeyCount: Int,
        currentCount: Int
    ) throws -> Int {
        guard evidenceClassCount >= 0, journeyCount >= 0, currentCount >= 0 else {
            throw ForgeCompletionError.collectionTooLarge(
                field: "constitution.requiredEvidenceSlots",
                maximum: Self.maximumRequiredEvidenceSlots
            )
        }

        let (criterionSlots, multiplyOverflow) = evidenceClassCount.multipliedReportingOverflow(by: journeyCount)
        guard !multiplyOverflow else {
            throw ForgeCompletionError.collectionTooLarge(
                field: "constitution.requiredEvidenceSlots",
                maximum: Self.maximumRequiredEvidenceSlots
            )
        }

        let (total, addOverflow) = currentCount.addingReportingOverflow(criterionSlots)
        guard !addOverflow, total <= Self.maximumRequiredEvidenceSlots else {
            throw ForgeCompletionError.collectionTooLarge(
                field: "constitution.requiredEvidenceSlots",
                maximum: Self.maximumRequiredEvidenceSlots
            )
        }
        return total
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case target
        case criteria
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ForgeCompletionError.unsupportedSchema(schemaVersion)
        }
        try self.init(
            target: container.decode(ForgeCompletionTarget.self, forKey: .target),
            criteria: container.decode([ForgeCompletionCriterion].self, forKey: .criteria)
        )
    }
}

fileprivate struct ForgeCompletionEvidenceSlot: Hashable, Sendable {
    let criterionID: String
    let evidenceClass: ForgeCompletionEvidenceClass
    let journeyID: String?

    var diagnosticKey: String {
        "\(criterionID)|\(evidenceClass.rawValue)|\(journeyID ?? "-")"
    }
}

public struct ForgeCompletionEvidence: Codable, Equatable, Sendable {
    public let id: String
    public let target: ForgeCompletionTarget
    public let criterionID: String
    public let evidenceClass: ForgeCompletionEvidenceClass
    public let journeyID: String?
    public let authority: ForgeCompletionEvidenceAuthority
    public let authorityReceiptID: String
    public let outcome: ForgeCompletionEvidenceOutcome

    public init(
        id: String,
        target: ForgeCompletionTarget,
        criterionID: String,
        evidenceClass: ForgeCompletionEvidenceClass,
        journeyID: String? = nil,
        authority: ForgeCompletionEvidenceAuthority,
        authorityReceiptID: String,
        outcome: ForgeCompletionEvidenceOutcome
    ) throws {
        let normalizedID = try ForgeCompletionValidation.identifier(
            id,
            field: "evidence.id",
            maximumLength: 256
        )
        guard evidenceClass.permits(authority) else {
            throw ForgeCompletionError.invalidEvidenceAuthority(normalizedID)
        }

        self.id = normalizedID
        self.target = target
        self.criterionID = try ForgeCompletionValidation.identifier(
            criterionID,
            field: "evidence.criterionID",
            maximumLength: 256
        )
        self.evidenceClass = evidenceClass
        if let journeyID {
            self.journeyID = try ForgeCompletionValidation.identifier(
                journeyID,
                field: "evidence.journeyID",
                maximumLength: 256
            )
        } else {
            self.journeyID = nil
        }
        self.authority = authority
        self.authorityReceiptID = try ForgeCompletionValidation.identifier(
            authorityReceiptID,
            field: "evidence.authorityReceiptID"
        )
        self.outcome = outcome
    }

    fileprivate var slot: ForgeCompletionEvidenceSlot {
        .init(
            criterionID: criterionID,
            evidenceClass: evidenceClass,
            journeyID: journeyID
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case target
        case criterionID
        case evidenceClass
        case journeyID
        case authority
        case authorityReceiptID
        case outcome
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(String.self, forKey: .id),
            target: container.decode(ForgeCompletionTarget.self, forKey: .target),
            criterionID: container.decode(String.self, forKey: .criterionID),
            evidenceClass: container.decode(ForgeCompletionEvidenceClass.self, forKey: .evidenceClass),
            journeyID: container.decodeIfPresent(String.self, forKey: .journeyID),
            authority: container.decode(ForgeCompletionEvidenceAuthority.self, forKey: .authority),
            authorityReceiptID: container.decode(String.self, forKey: .authorityReceiptID),
            outcome: container.decode(ForgeCompletionEvidenceOutcome.self, forKey: .outcome)
        )
    }
}

public enum ForgeCompletionDefectSeverity: Int, Codable, CaseIterable, Comparable, Sendable {
    case low = 0
    case medium = 1
    case high = 2
    case critical = 3

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum ForgeCompletionDefectStatus: String, Codable, CaseIterable, Sendable {
    case open
    case resolved
}

public struct ForgeCompletionDefect: Codable, Equatable, Sendable {
    public let id: String
    public let severity: ForgeCompletionDefectSeverity
    public let status: ForgeCompletionDefectStatus
    public let summary: String

    public init(
        id: String,
        severity: ForgeCompletionDefectSeverity,
        status: ForgeCompletionDefectStatus,
        summary: String
    ) throws {
        self.id = try ForgeCompletionValidation.identifier(
            id,
            field: "defect.id",
            maximumLength: 256
        )
        self.severity = severity
        self.status = status
        self.summary = try ForgeCompletionValidation.text(
            summary,
            field: "defect.summary",
            maximumLength: 4_096
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case severity
        case status
        case summary
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(String.self, forKey: .id),
            severity: container.decode(ForgeCompletionDefectSeverity.self, forKey: .severity),
            status: container.decode(ForgeCompletionDefectStatus.self, forKey: .status),
            summary: container.decode(String.self, forKey: .summary)
        )
    }
}

public struct ForgeCompletionDefectInventory: Codable, Equatable, Sendable {
    public static let maximumDefects = 1_024

    public let target: ForgeCompletionTarget
    public let authorityReceiptID: String
    public let defects: [ForgeCompletionDefect]

    public init(
        target: ForgeCompletionTarget,
        authorityReceiptID: String,
        defects: [ForgeCompletionDefect]
    ) throws {
        try ForgeCompletionValidation.maximumCount(
            defects.count,
            field: "defectInventory.defects",
            maximum: Self.maximumDefects
        )
        self.target = target
        self.authorityReceiptID = try ForgeCompletionValidation.identifier(
            authorityReceiptID,
            field: "defectInventory.authorityReceiptID"
        )

        var seen = Set<String>()
        for defect in defects {
            guard seen.insert(defect.id).inserted else {
                throw ForgeCompletionError.duplicateDefectID(defect.id)
            }
        }
        self.defects = defects.sorted { $0.id < $1.id }
    }

    private enum CodingKeys: String, CodingKey {
        case target
        case authorityReceiptID
        case defects
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            target: container.decode(ForgeCompletionTarget.self, forKey: .target),
            authorityReceiptID: container.decode(String.self, forKey: .authorityReceiptID),
            defects: container.decode([ForgeCompletionDefect].self, forKey: .defects)
        )
    }
}

public struct ForgeCompletionKnownLimitation: Codable, Equatable, Sendable {
    public static let maximumCoveredDefects = 256
    public let id: String
    public let target: ForgeCompletionTarget
    public let text: String
    public let coveredDefectIDs: [String]
    public let authorityReceiptID: String

    public init(
        id: String,
        target: ForgeCompletionTarget,
        text: String,
        coveredDefectIDs: [String] = [],
        authorityReceiptID: String
    ) throws {
        self.id = try ForgeCompletionValidation.identifier(
            id,
            field: "limitation.id",
            maximumLength: 256
        )
        self.target = target
        self.text = try ForgeCompletionValidation.text(
            text,
            field: "limitation.text",
            maximumLength: 8_192
        )
        try ForgeCompletionValidation.maximumCount(
            coveredDefectIDs.count,
            field: "limitation.coveredDefectIDs",
            maximum: Self.maximumCoveredDefects
        )
        let normalizedDefectIDs = try coveredDefectIDs.map {
            try ForgeCompletionValidation.identifier(
                $0,
                field: "limitation.coveredDefectID",
                maximumLength: 256
            )
        }
        let canonicalDefectIDs = Array(Set(normalizedDefectIDs)).sorted()
        guard canonicalDefectIDs.count == normalizedDefectIDs.count else {
            throw ForgeCompletionError.invalidLimitationDefectReference(self.id)
        }
        self.coveredDefectIDs = canonicalDefectIDs
        self.authorityReceiptID = try ForgeCompletionValidation.identifier(
            authorityReceiptID,
            field: "limitation.authorityReceiptID"
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case target
        case text
        case coveredDefectIDs
        case authorityReceiptID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(String.self, forKey: .id),
            target: container.decode(ForgeCompletionTarget.self, forKey: .target),
            text: container.decode(String.self, forKey: .text),
            coveredDefectIDs: container.decode([String].self, forKey: .coveredDefectIDs),
            authorityReceiptID: container.decode(String.self, forKey: .authorityReceiptID)
        )
    }
}

public enum ForgeCompletionBlocker: Equatable, Sendable {
    case missingEvidence(
        criterionID: String,
        evidenceClass: ForgeCompletionEvidenceClass,
        journeyID: String?
    )
    case evidenceNotPassed(
        criterionID: String,
        evidenceClass: ForgeCompletionEvidenceClass,
        journeyID: String?,
        outcome: ForgeCompletionEvidenceOutcome
    )
    case missingDefectInventory
    case unresolvedSevereDefect(defectID: String, severity: ForgeCompletionDefectSeverity)
    case undocumentedKnownDefect(defectID: String)

    fileprivate var sortKey: String {
        switch self {
        case let .missingEvidence(criterionID, evidenceClass, journeyID):
            return "0|\(criterionID)|\(evidenceClass.rawValue)|\(journeyID ?? "-")"
        case let .evidenceNotPassed(criterionID, evidenceClass, journeyID, outcome):
            return "1|\(criterionID)|\(evidenceClass.rawValue)|\(journeyID ?? "-")|\(outcome.rawValue)"
        case .missingDefectInventory:
            return "2"
        case let .unresolvedSevereDefect(defectID, severity):
            return "3|\(String(format: "%02d", severity.rawValue))|\(defectID)"
        case let .undocumentedKnownDefect(defectID):
            return "4|\(defectID)"
        }
    }
}

public enum ForgeCompletionAcceptanceStatus: String, Sendable {
    case blocked
    case satisfied
    case satisfiedWithKnownLimitations
}

/// Derived product-acceptance result only. Intentionally not Codable: relaunch/restore must
/// recompute acceptance from the current canonical constitution, receipts, and defect inventory.
/// This value is not a Mission Engine terminal-state transition.
public struct ForgeCompletionEvaluation: Equatable, Sendable {
    public let target: ForgeCompletionTarget
    public let status: ForgeCompletionAcceptanceStatus
    public let blockers: [ForgeCompletionBlocker]
    public let acceptedEvidenceIDs: [String]
    public let waivedCriterionIDs: [String]
    public let knownLimitationIDs: [String]

    public var isSatisfied: Bool {
        status != .blocked
    }
}

/// Package-owned acceptance evaluator. Raw candidate receipts remain public/Codable for persistence,
/// but ordinary imports cannot turn caller-shaped authority labels into an authoritative satisfaction result.
enum ForgeCompletionEvaluator {
    public static let maximumEvidence = ForgeCompletionConstitution.maximumRequiredEvidenceSlots
    public static let maximumKnownLimitations = 512

    public static func evaluate(
        constitution: ForgeCompletionConstitution,
        evidence: [ForgeCompletionEvidence],
        defectInventory: ForgeCompletionDefectInventory?,
        knownLimitations: [ForgeCompletionKnownLimitation] = []
    ) throws -> ForgeCompletionEvaluation {
        try ForgeCompletionValidation.maximumCount(
            evidence.count,
            field: "evaluation.evidence",
            maximum: Self.maximumEvidence
        )
        try ForgeCompletionValidation.maximumCount(
            knownLimitations.count,
            field: "evaluation.knownLimitations",
            maximum: Self.maximumKnownLimitations
        )

        let target = constitution.target
        let criteriaByID = Dictionary(uniqueKeysWithValues: constitution.criteria.map { ($0.id, $0) })

        var evidenceIDs = Set<String>()
        var authorityReceiptIDs = Set<String>()
        var evidenceSlots = Set<ForgeCompletionEvidenceSlot>()
        var evidenceBySlot: [ForgeCompletionEvidenceSlot: ForgeCompletionEvidence] = [:]

        for item in evidence {
            guard item.target == target else {
                throw ForgeCompletionError.targetMismatch("evidence:\(item.id)")
            }
            guard evidenceIDs.insert(item.id).inserted else {
                throw ForgeCompletionError.duplicateEvidenceID(item.id)
            }
            guard authorityReceiptIDs.insert(item.authorityReceiptID).inserted else {
                throw ForgeCompletionError.duplicateEvidenceAuthorityReceiptID(item.authorityReceiptID)
            }
            guard let criterion = criteriaByID[item.criterionID] else {
                throw ForgeCompletionError.unknownCriterion(item.criterionID)
            }
            guard criterion.isRequired else {
                throw ForgeCompletionError.evidenceForWaivedCriterion(item.criterionID)
            }
            guard criterion.requiredEvidenceClasses.contains(item.evidenceClass) else {
                throw ForgeCompletionError.unexpectedEvidenceClass(item.id)
            }
            if criterion.journeyIDs.isEmpty {
                guard item.journeyID == nil else {
                    throw ForgeCompletionError.unexpectedJourney(item.id)
                }
            } else {
                guard let journeyID = item.journeyID,
                      criterion.journeyIDs.contains(journeyID) else {
                    throw ForgeCompletionError.unexpectedJourney(item.id)
                }
            }
            guard evidenceSlots.insert(item.slot).inserted else {
                throw ForgeCompletionError.duplicateEvidenceSlot(item.slot.diagnosticKey)
            }
            evidenceBySlot[item.slot] = item
        }

        var limitationIDs = Set<String>()
        var limitationsByDefectID: [String: String] = [:]
        for limitation in knownLimitations {
            guard limitation.target == target else {
                throw ForgeCompletionError.targetMismatch("limitation:\(limitation.id)")
            }
            guard limitationIDs.insert(limitation.id).inserted else {
                throw ForgeCompletionError.duplicateLimitationID(limitation.id)
            }
            for defectID in limitation.coveredDefectIDs {
                if limitationsByDefectID[defectID] != nil {
                    throw ForgeCompletionError.invalidLimitationDefectReference(defectID)
                }
                limitationsByDefectID[defectID] = limitation.id
            }
        }

        var blockers: [ForgeCompletionBlocker] = []
        var acceptedEvidenceIDs: [String] = []

        for criterion in constitution.criteria where criterion.isRequired {
            let journeys: [String?] = criterion.journeyIDs.isEmpty
                ? [nil]
                : criterion.journeyIDs.map(Optional.some)

            for evidenceClass in criterion.requiredEvidenceClasses {
                for journeyID in journeys {
                    let slot = ForgeCompletionEvidenceSlot(
                        criterionID: criterion.id,
                        evidenceClass: evidenceClass,
                        journeyID: journeyID
                    )
                    guard let item = evidenceBySlot[slot] else {
                        blockers.append(.missingEvidence(
                            criterionID: criterion.id,
                            evidenceClass: evidenceClass,
                            journeyID: journeyID
                        ))
                        continue
                    }
                    if item.outcome == .passed {
                        acceptedEvidenceIDs.append(item.id)
                    } else {
                        blockers.append(.evidenceNotPassed(
                            criterionID: criterion.id,
                            evidenceClass: evidenceClass,
                            journeyID: journeyID,
                            outcome: item.outcome
                        ))
                    }
                }
            }
        }

        if let defectInventory {
            guard defectInventory.target == target else {
                throw ForgeCompletionError.targetMismatch("defectInventory")
            }
            let defectsByID = Dictionary(
                uniqueKeysWithValues: defectInventory.defects.map { ($0.id, $0) }
            )

            for coveredID in limitationsByDefectID.keys {
                guard let defect = defectsByID[coveredID],
                      defect.status == .open,
                      defect.severity < .high else {
                    throw ForgeCompletionError.invalidLimitationDefectReference(coveredID)
                }
            }

            for defect in defectInventory.defects where defect.status == .open {
                if defect.severity >= .high {
                    blockers.append(.unresolvedSevereDefect(
                        defectID: defect.id,
                        severity: defect.severity
                    ))
                } else if limitationsByDefectID[defect.id] == nil {
                    blockers.append(.undocumentedKnownDefect(defectID: defect.id))
                }
            }
        } else {
            if let firstCoveredDefect = limitationsByDefectID.keys.sorted().first {
                throw ForgeCompletionError.invalidLimitationDefectReference(firstCoveredDefect)
            }
            blockers.append(.missingDefectInventory)
        }

        let waivedCriterionIDs = constitution.criteria.compactMap { criterion -> String? in
            if case .waived = criterion.requirement { return criterion.id }
            return nil
        }.sorted()

        let canonicalBlockers = blockers.sorted { $0.sortKey < $1.sortKey }
        let status: ForgeCompletionAcceptanceStatus
        if !canonicalBlockers.isEmpty {
            status = .blocked
        } else if !knownLimitations.isEmpty || !waivedCriterionIDs.isEmpty {
            status = .satisfiedWithKnownLimitations
        } else {
            status = .satisfied
        }

        return ForgeCompletionEvaluation(
            target: target,
            status: status,
            blockers: canonicalBlockers,
            acceptedEvidenceIDs: acceptedEvidenceIDs.sorted(),
            waivedCriterionIDs: waivedCriterionIDs,
            knownLimitationIDs: knownLimitations.map(\.id).sorted()
        )
    }
}
