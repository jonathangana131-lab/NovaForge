import Foundation

public enum ForgeCompletionError: Error, Equatable, Sendable {
    case invalidIdentifier(String)
    case invalidText(String)
    case invalidRevision(String)
    case unsupportedSchema(Int)
    case duplicateCriterionID(String)
    case duplicateEvidenceID(String)
    case duplicateEvidenceSlot(String)
    case duplicateDefectID(String)
    case duplicateLimitationID(String)
    case invalidCriterion(String)
    case invalidRequirement(String)
    case targetMismatch(String)
    case unknownCriterion(String)
    case evidenceForWaivedCriterion(String)
    case unexpectedEvidenceClass(String)
    case unexpectedJourney(String)
    case invalidLimitationDefectReference(String)
}

private enum ForgeCompletionValidation {
    static func identifier(_ value: String, field: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= 512,
              !trimmed.contains(where: { $0.isNewline || $0.isControl }) else {
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
}

/// Exact accepted product state that completion evidence must describe.
/// Mission lifecycle authority remains external to this package.
public struct ForgeCompletionTarget: Codable, Equatable, Hashable, Sendable {
    public let projectID: String
    public let sourceRevision: String
    public let acceptanceRevision: Int

    public init(projectID: String, sourceRevision: String, acceptanceRevision: Int) throws {
        self.projectID = try ForgeCompletionValidation.identifier(projectID, field: "target.projectID")
        self.sourceRevision = try ForgeCompletionValidation.identifier(sourceRevision, field: "target.sourceRevision")
        self.acceptanceRevision = try ForgeCompletionValidation.revision(acceptanceRevision, field: "target.acceptanceRevision")
    }

    private enum CodingKeys: String, CodingKey {
        case projectID, sourceRevision, acceptanceRevision
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            projectID: container.decode(String.self, forKey: .projectID),
            sourceRevision: container.decode(String.self, forKey: .sourceRevision),
            acceptanceRevision: container.decode(Int.self, forKey: .acceptanceRevision)
        )
    }
}

public enum ForgeCompletionCriterionKind: String, Codable, CaseIterable, Sendable {
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

public enum ForgeCompletionEvidenceClass: String, Codable, CaseIterable, Sendable {
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
        self.explanation = try ForgeCompletionValidation.text(explanation, field: "waiver.explanation", maximumLength: 4_096)
        self.authorityReceiptID = try ForgeCompletionValidation.identifier(authorityReceiptID, field: "waiver.authorityReceiptID")
    }

    private enum CodingKeys: String, CodingKey {
        case explanation, authorityReceiptID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            explanation: container.decode(String.self, forKey: .explanation),
            authorityReceiptID: container.decode(String.self, forKey: .authorityReceiptID)
        )
    }
}

public enum ForgeCompletionRequirement: Codable, Equatable, Sendable {
    case required
    case waived(ForgeCompletionWaiver)
}

public struct ForgeCompletionCriterion: Codable, Equatable, Sendable {
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
        let normalizedID = try ForgeCompletionValidation.identifier(id, field: "criterion.id")
        let normalizedTitle = try ForgeCompletionValidation.text(title, field: "criterion.title", maximumLength: 1_024)

        guard !requiredEvidenceClasses.isEmpty else {
            throw ForgeCompletionError.invalidCriterion(normalizedID)
        }
        let canonicalEvidenceClasses = Array(Set(requiredEvidenceClasses)).sorted { $0.rawValue < $1.rawValue }
        guard canonicalEvidenceClasses.count == requiredEvidenceClasses.count else {
            throw ForgeCompletionError.invalidCriterion(normalizedID)
        }

        let normalizedJourneys = try journeyIDs.map {
            try ForgeCompletionValidation.identifier($0, field: "criterion.journeyID")
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
        case id, kind, title, requirement, requiredEvidenceClasses, journeyIDs
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

    public let schemaVersion: Int
    public let target: ForgeCompletionTarget
    public let authorityReceiptID: String
    public let criteria: [ForgeCompletionCriterion]

    public init(
        target: ForgeCompletionTarget,
        authorityReceiptID: String,
        criteria: [ForgeCompletionCriterion]
    ) throws {
        let normalizedReceipt = try ForgeCompletionValidation.identifier(authorityReceiptID, field: "constitution.authorityReceiptID")
        guard !criteria.isEmpty else {
            throw ForgeCompletionError.invalidCriterion("constitution.criteria")
        }

        var seen = Set<String>()
        for criterion in criteria {
            guard seen.insert(criterion.id).inserted else {
                throw ForgeCompletionError.duplicateCriterionID(criterion.id)
            }
        }

        self.schemaVersion = Self.currentSchemaVersion
        self.target = target
        self.authorityReceiptID = normalizedReceipt
        self.criteria = criteria.sorted { $0.id < $1.id }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, target, authorityReceiptID, criteria
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ForgeCompletionError.unsupportedSchema(schemaVersion)
        }
        try self.init(
            target: container.decode(ForgeCompletionTarget.self, forKey: .target),
            authorityReceiptID: container.decode(String.self, forKey: .authorityReceiptID),
            criteria: container.decode([ForgeCompletionCriterion].self, forKey: .criteria)
        )
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
        self.id = try ForgeCompletionValidation.identifier(id, field: "evidence.id")
        self.target = target
        self.criterionID = try ForgeCompletionValidation.identifier(criterionID, field: "evidence.criterionID")
        self.evidenceClass = evidenceClass
        if let journeyID {
            self.journeyID = try ForgeCompletionValidation.identifier(journeyID, field: "evidence.journeyID")
        } else {
            self.journeyID = nil
        }
        self.authority = authority
        self.authorityReceiptID = try ForgeCompletionValidation.identifier(authorityReceiptID, field: "evidence.authorityReceiptID")
        self.outcome = outcome
    }

    fileprivate var slotKey: String {
        "\(criterionID)|\(evidenceClass.rawValue)|\(journeyID ?? "-")"
    }

    private enum CodingKeys: String, CodingKey {
        case id, target, criterionID, evidenceClass, journeyID, authority, authorityReceiptID, outcome
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
        self.id = try ForgeCompletionValidation.identifier(id, field: "defect.id")
        self.severity = severity
        self.status = status
        self.summary = try ForgeCompletionValidation.text(summary, field: "defect.summary", maximumLength: 4_096)
    }

    private enum CodingKeys: String, CodingKey {
        case id, severity, status, summary
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
    public let target: ForgeCompletionTarget
    public let authorityReceiptID: String
    public let defects: [ForgeCompletionDefect]

    public init(
        target: ForgeCompletionTarget,
        authorityReceiptID: String,
        defects: [ForgeCompletionDefect]
    ) throws {
        self.target = target
        self.authorityReceiptID = try ForgeCompletionValidation.identifier(authorityReceiptID, field: "defectInventory.authorityReceiptID")
        var seen = Set<String>()
        for defect in defects {
            guard seen.insert(defect.id).inserted else {
                throw ForgeCompletionError.duplicateDefectID(defect.id)
            }
        }
        self.defects = defects.sorted { $0.id < $1.id }
    }

    private enum CodingKeys: String, CodingKey {
        case target, authorityReceiptID, defects
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
        self.id = try ForgeCompletionValidation.identifier(id, field: "limitation.id")
        self.target = target
        self.text = try ForgeCompletionValidation.text(text, field: "limitation.text", maximumLength: 8_192)
        let normalizedDefectIDs = try coveredDefectIDs.map {
            try ForgeCompletionValidation.identifier($0, field: "limitation.coveredDefectID")
        }
        let canonicalDefectIDs = Array(Set(normalizedDefectIDs)).sorted()
        guard canonicalDefectIDs.count == normalizedDefectIDs.count else {
            throw ForgeCompletionError.invalidLimitationDefectReference(self.id)
        }
        self.coveredDefectIDs = canonicalDefectIDs
        self.authorityReceiptID = try ForgeCompletionValidation.identifier(authorityReceiptID, field: "limitation.authorityReceiptID")
    }

    private enum CodingKeys: String, CodingKey {
        case id, target, text, coveredDefectIDs, authorityReceiptID
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

public enum ForgeCompletionBlocker: Codable, Equatable, Sendable {
    case missingEvidence(criterionID: String, evidenceClass: ForgeCompletionEvidenceClass, journeyID: String?)
    case evidenceNotPassed(criterionID: String, evidenceClass: ForgeCompletionEvidenceClass, journeyID: String?, outcome: ForgeCompletionEvidenceOutcome)
    case missingDefectInventory
    case unresolvedSevereDefect(defectID: String, severity: ForgeCompletionDefectSeverity)
    case undocumentedKnownDefect(defectID: String)
}

public enum ForgeCompletionAcceptanceStatus: String, Codable, Sendable {
    case blocked
    case satisfied
    case satisfiedWithKnownLimitations
}

/// Product-acceptance result only. It is not a Mission Engine terminal-state transition.
public struct ForgeCompletionEvaluation: Codable, Equatable, Sendable {
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

public enum ForgeCompletionEvaluator {
    public static func evaluate(
        constitution: ForgeCompletionConstitution,
        evidence: [ForgeCompletionEvidence],
        defectInventory: ForgeCompletionDefectInventory?,
        knownLimitations: [ForgeCompletionKnownLimitation] = []
    ) throws -> ForgeCompletionEvaluation {
        let target = constitution.target
        let criteriaByID = Dictionary(uniqueKeysWithValues: constitution.criteria.map { ($0.id, $0) })

        var evidenceIDs = Set<String>()
        var evidenceSlots = Set<String>()
        var evidenceBySlot: [String: ForgeCompletionEvidence] = [:]

        for item in evidence {
            guard item.target == target else {
                throw ForgeCompletionError.targetMismatch("evidence:\(item.id)")
            }
            guard evidenceIDs.insert(item.id).inserted else {
                throw ForgeCompletionError.duplicateEvidenceID(item.id)
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
                guard let journeyID = item.journeyID, criterion.journeyIDs.contains(journeyID) else {
                    throw ForgeCompletionError.unexpectedJourney(item.id)
                }
            }
            guard evidenceSlots.insert(item.slotKey).inserted else {
                throw ForgeCompletionError.duplicateEvidenceSlot(item.slotKey)
            }
            evidenceBySlot[item.slotKey] = item
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
            let journeys: [String?] = criterion.journeyIDs.isEmpty ? [nil] : criterion.journeyIDs.map(Optional.some)
            for evidenceClass in criterion.requiredEvidenceClasses {
                for journeyID in journeys {
                    let slot = "\(criterion.id)|\(evidenceClass.rawValue)|\(journeyID ?? "-")"
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
            let defectsByID = Dictionary(uniqueKeysWithValues: defectInventory.defects.map { ($0.id, $0) })

            for coveredID in limitationsByDefectID.keys {
                guard let defect = defectsByID[coveredID],
                      defect.status == .open,
                      defect.severity < .high else {
                    throw ForgeCompletionError.invalidLimitationDefectReference(coveredID)
                }
            }

            for defect in defectInventory.defects where defect.status == .open {
                if defect.severity >= .high {
                    blockers.append(.unresolvedSevereDefect(defectID: defect.id, severity: defect.severity))
                } else if limitationsByDefectID[defect.id] == nil {
                    blockers.append(.undocumentedKnownDefect(defectID: defect.id))
                }
            }
        } else {
            if !limitationsByDefectID.isEmpty {
                throw ForgeCompletionError.invalidLimitationDefectReference(limitationsByDefectID.keys.sorted().first ?? "unknown")
            }
            blockers.append(.missingDefectInventory)
        }

        let waivedCriterionIDs = constitution.criteria.compactMap { criterion -> String? in
            if case .waived = criterion.requirement { return criterion.id }
            return nil
        }.sorted()

        let canonicalBlockers = blockers.sorted { String(describing: $0) < String(describing: $1) }
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
