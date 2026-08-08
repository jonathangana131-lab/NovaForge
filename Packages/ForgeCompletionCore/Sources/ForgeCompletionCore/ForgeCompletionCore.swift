import Foundation

public enum ForgeCompletionValidationError: Error, Equatable, Sendable {
    case invalidIdentifier
    case unsupportedSchema(Int)
    case invalidConstitutionRevision(Int)
    case invalidRequirementCount(Int)
    case duplicateRequirementID(String)
    case invalidMinimumPassingReceipts(Int)
    case identityMismatch(String)
    case unknownRequirement(String)
    case evidenceClassMismatch(requirementID: String)
    case unsupportedAuthority(requirementID: String)
    case duplicateEvidenceReceiptID(String)
    case duplicateDefectID(String)
    case duplicateLimitationID(String)
    case duplicateRelatedDefectID(String)
    case unknownRelatedDefectID(String)
    case invalidLimitationSummary
}

public struct ForgeCompletionIdentifier: Hashable, Codable, Sendable, Comparable {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 160 else {
            throw ForgeCompletionValidationError.invalidIdentifier
        }
        guard !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ForgeCompletionValidationError.invalidIdentifier
        }
        self.rawValue = value
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum ForgeCompletionEvidenceClass: String, Codable, CaseIterable, Sendable {
    case build
    case launch
    case runtimeStability
    case controls
    case gameplayGoal
    case persistenceRecovery
    case safeAreaOrientation
    case visual
    case accessibility
    case performance
    case defectAudit
}

public enum ForgeCompletionEvidenceAuthority: String, Codable, CaseIterable, Sendable {
    case buildSystem
    case runtimeHost
    case playtestGate
    case visualQA
    case accessibilityAudit
    case performanceAudit
    case defectAudit
    case userAcceptance

    fileprivate func supports(_ evidenceClass: ForgeCompletionEvidenceClass) -> Bool {
        switch self {
        case .buildSystem:
            return evidenceClass == .build
        case .runtimeHost:
            return [.launch, .runtimeStability, .controls, .gameplayGoal, .persistenceRecovery, .safeAreaOrientation].contains(evidenceClass)
        case .playtestGate:
            return [.runtimeStability, .controls, .gameplayGoal, .persistenceRecovery, .safeAreaOrientation].contains(evidenceClass)
        case .visualQA:
            return [.safeAreaOrientation, .visual].contains(evidenceClass)
        case .accessibilityAudit:
            return evidenceClass == .accessibility
        case .performanceAudit:
            return evidenceClass == .performance
        case .defectAudit:
            return evidenceClass == .defectAudit
        case .userAcceptance:
            return evidenceClass == .visual
        }
    }
}

public struct ForgeCompletionRequirement: Hashable, Codable, Sendable {
    public let id: ForgeCompletionIdentifier
    public let evidenceClass: ForgeCompletionEvidenceClass
    public let isRequired: Bool
    public let minimumPassingReceipts: Int

    public init(
        id: ForgeCompletionIdentifier,
        evidenceClass: ForgeCompletionEvidenceClass,
        isRequired: Bool = true,
        minimumPassingReceipts: Int = 1
    ) throws {
        guard (1...32).contains(minimumPassingReceipts) else {
            throw ForgeCompletionValidationError.invalidMinimumPassingReceipts(minimumPassingReceipts)
        }
        self.id = id
        self.evidenceClass = evidenceClass
        self.isRequired = isRequired
        self.minimumPassingReceipts = minimumPassingReceipts
    }

    private enum CodingKeys: String, CodingKey {
        case id, evidenceClass, isRequired, minimumPassingReceipts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(ForgeCompletionIdentifier.self, forKey: .id),
            evidenceClass: container.decode(ForgeCompletionEvidenceClass.self, forKey: .evidenceClass),
            isRequired: container.decode(Bool.self, forKey: .isRequired),
            minimumPassingReceipts: container.decode(Int.self, forKey: .minimumPassingReceipts)
        )
    }
}

public enum ForgeCompletionKnownLimitationsPolicy: String, Codable, Sendable {
    case forbid
    case allowExplicitAccepted
}

public struct ForgeCompletionConstitution: Hashable, Codable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let projectID: ForgeCompletionIdentifier
    public let sourceRevision: ForgeCompletionIdentifier
    public let missionID: ForgeCompletionIdentifier
    public let constitutionRevision: Int
    public let requirements: [ForgeCompletionRequirement]
    public let knownLimitationsPolicy: ForgeCompletionKnownLimitationsPolicy

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        projectID: ForgeCompletionIdentifier,
        sourceRevision: ForgeCompletionIdentifier,
        missionID: ForgeCompletionIdentifier,
        constitutionRevision: Int,
        requirements: [ForgeCompletionRequirement],
        knownLimitationsPolicy: ForgeCompletionKnownLimitationsPolicy
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ForgeCompletionValidationError.unsupportedSchema(schemaVersion)
        }
        guard constitutionRevision > 0 else {
            throw ForgeCompletionValidationError.invalidConstitutionRevision(constitutionRevision)
        }
        guard (1...64).contains(requirements.count) else {
            throw ForgeCompletionValidationError.invalidRequirementCount(requirements.count)
        }

        var requirementIDs = Set<ForgeCompletionIdentifier>()
        for requirement in requirements where !requirementIDs.insert(requirement.id).inserted {
            throw ForgeCompletionValidationError.duplicateRequirementID(requirement.id.rawValue)
        }

        self.schemaVersion = schemaVersion
        self.projectID = projectID
        self.sourceRevision = sourceRevision
        self.missionID = missionID
        self.constitutionRevision = constitutionRevision
        self.requirements = requirements
        self.knownLimitationsPolicy = knownLimitationsPolicy
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, projectID, sourceRevision, missionID, constitutionRevision, requirements, knownLimitationsPolicy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
            projectID: container.decode(ForgeCompletionIdentifier.self, forKey: .projectID),
            sourceRevision: container.decode(ForgeCompletionIdentifier.self, forKey: .sourceRevision),
            missionID: container.decode(ForgeCompletionIdentifier.self, forKey: .missionID),
            constitutionRevision: container.decode(Int.self, forKey: .constitutionRevision),
            requirements: container.decode([ForgeCompletionRequirement].self, forKey: .requirements),
            knownLimitationsPolicy: container.decode(ForgeCompletionKnownLimitationsPolicy.self, forKey: .knownLimitationsPolicy)
        )
    }
}

public enum ForgeCompletionEvidenceOutcome: String, Codable, Sendable {
    case passed
    case failed
}

public struct ForgeCompletionEvidenceBinding: Hashable, Codable, Sendable {
    public let acceptedReceiptID: ForgeCompletionIdentifier
    public let projectID: ForgeCompletionIdentifier
    public let sourceRevision: ForgeCompletionIdentifier
    public let missionID: ForgeCompletionIdentifier
    public let constitutionRevision: Int
    public let requirementID: ForgeCompletionIdentifier
    public let evidenceClass: ForgeCompletionEvidenceClass
    public let authority: ForgeCompletionEvidenceAuthority
    public let outcome: ForgeCompletionEvidenceOutcome

    public init(
        acceptedReceiptID: ForgeCompletionIdentifier,
        projectID: ForgeCompletionIdentifier,
        sourceRevision: ForgeCompletionIdentifier,
        missionID: ForgeCompletionIdentifier,
        constitutionRevision: Int,
        requirementID: ForgeCompletionIdentifier,
        evidenceClass: ForgeCompletionEvidenceClass,
        authority: ForgeCompletionEvidenceAuthority,
        outcome: ForgeCompletionEvidenceOutcome
    ) throws {
        guard constitutionRevision > 0 else {
            throw ForgeCompletionValidationError.invalidConstitutionRevision(constitutionRevision)
        }
        self.acceptedReceiptID = acceptedReceiptID
        self.projectID = projectID
        self.sourceRevision = sourceRevision
        self.missionID = missionID
        self.constitutionRevision = constitutionRevision
        self.requirementID = requirementID
        self.evidenceClass = evidenceClass
        self.authority = authority
        self.outcome = outcome
    }

    private enum CodingKeys: String, CodingKey {
        case acceptedReceiptID, projectID, sourceRevision, missionID, constitutionRevision, requirementID, evidenceClass, authority, outcome
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            acceptedReceiptID: container.decode(ForgeCompletionIdentifier.self, forKey: .acceptedReceiptID),
            projectID: container.decode(ForgeCompletionIdentifier.self, forKey: .projectID),
            sourceRevision: container.decode(ForgeCompletionIdentifier.self, forKey: .sourceRevision),
            missionID: container.decode(ForgeCompletionIdentifier.self, forKey: .missionID),
            constitutionRevision: container.decode(Int.self, forKey: .constitutionRevision),
            requirementID: container.decode(ForgeCompletionIdentifier.self, forKey: .requirementID),
            evidenceClass: container.decode(ForgeCompletionEvidenceClass.self, forKey: .evidenceClass),
            authority: container.decode(ForgeCompletionEvidenceAuthority.self, forKey: .authority),
            outcome: container.decode(ForgeCompletionEvidenceOutcome.self, forKey: .outcome)
        )
    }
}

public enum ForgeCompletionDefectSeverity: Int, Codable, Comparable, Sendable {
    case low = 0
    case medium = 1
    case high = 2
    case critical = 3

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum ForgeCompletionDefectStatus: String, Codable, Sendable {
    case open
    case resolved
}

public struct ForgeCompletionDefect: Hashable, Codable, Sendable {
    public let id: ForgeCompletionIdentifier
    public let projectID: ForgeCompletionIdentifier
    public let sourceRevision: ForgeCompletionIdentifier
    public let severity: ForgeCompletionDefectSeverity
    public let status: ForgeCompletionDefectStatus

    public init(
        id: ForgeCompletionIdentifier,
        projectID: ForgeCompletionIdentifier,
        sourceRevision: ForgeCompletionIdentifier,
        severity: ForgeCompletionDefectSeverity,
        status: ForgeCompletionDefectStatus
    ) {
        self.id = id
        self.projectID = projectID
        self.sourceRevision = sourceRevision
        self.severity = severity
        self.status = status
    }
}

public struct ForgeCompletionKnownLimitation: Hashable, Codable, Sendable {
    public let id: ForgeCompletionIdentifier
    public let projectID: ForgeCompletionIdentifier
    public let sourceRevision: ForgeCompletionIdentifier
    public let missionID: ForgeCompletionIdentifier
    public let constitutionRevision: Int
    public let summary: String
    public let acceptedReceiptID: ForgeCompletionIdentifier
    public let relatedDefectIDs: [ForgeCompletionIdentifier]

    public init(
        id: ForgeCompletionIdentifier,
        projectID: ForgeCompletionIdentifier,
        sourceRevision: ForgeCompletionIdentifier,
        missionID: ForgeCompletionIdentifier,
        constitutionRevision: Int,
        summary: String,
        acceptedReceiptID: ForgeCompletionIdentifier,
        relatedDefectIDs: [ForgeCompletionIdentifier] = []
    ) throws {
        guard constitutionRevision > 0 else {
            throw ForgeCompletionValidationError.invalidConstitutionRevision(constitutionRevision)
        }
        let normalizedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSummary.isEmpty,
              normalizedSummary.utf8.count <= 2_000,
              !normalizedSummary.unicodeScalars.contains(where: CharacterSet.controlCharacters.subtracting(.newlines).contains) else {
            throw ForgeCompletionValidationError.invalidLimitationSummary
        }
        var seen = Set<ForgeCompletionIdentifier>()
        for defectID in relatedDefectIDs where !seen.insert(defectID).inserted {
            throw ForgeCompletionValidationError.duplicateRelatedDefectID(defectID.rawValue)
        }
        self.id = id
        self.projectID = projectID
        self.sourceRevision = sourceRevision
        self.missionID = missionID
        self.constitutionRevision = constitutionRevision
        self.summary = normalizedSummary
        self.acceptedReceiptID = acceptedReceiptID
        self.relatedDefectIDs = relatedDefectIDs
    }

    private enum CodingKeys: String, CodingKey {
        case id, projectID, sourceRevision, missionID, constitutionRevision, summary, acceptedReceiptID, relatedDefectIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(ForgeCompletionIdentifier.self, forKey: .id),
            projectID: container.decode(ForgeCompletionIdentifier.self, forKey: .projectID),
            sourceRevision: container.decode(ForgeCompletionIdentifier.self, forKey: .sourceRevision),
            missionID: container.decode(ForgeCompletionIdentifier.self, forKey: .missionID),
            constitutionRevision: container.decode(Int.self, forKey: .constitutionRevision),
            summary: container.decode(String.self, forKey: .summary),
            acceptedReceiptID: container.decode(ForgeCompletionIdentifier.self, forKey: .acceptedReceiptID),
            relatedDefectIDs: container.decode([ForgeCompletionIdentifier].self, forKey: .relatedDefectIDs)
        )
    }
}

public enum ForgeCompletionState: String, Codable, Sendable {
    case blocked
    case repairRequired
    case complete
    case completeWithKnownLimitations
}

public struct ForgeCompletionProjection: Equatable, Sendable {
    public let state: ForgeCompletionState
    public let satisfiedRequirementIDs: [ForgeCompletionIdentifier]
    public let blockingRequirementIDs: [ForgeCompletionIdentifier]
    public let failedRequirementIDs: [ForgeCompletionIdentifier]
    public let repairDefectIDs: [ForgeCompletionIdentifier]
    public let undisclosedDefectIDs: [ForgeCompletionIdentifier]
    public let acceptedEvidenceReceiptIDs: [ForgeCompletionIdentifier]
    public let acceptedLimitationReceiptIDs: [ForgeCompletionIdentifier]
    public let acceptedLimitationIDs: [ForgeCompletionIdentifier]

    fileprivate init(
        state: ForgeCompletionState,
        satisfiedRequirementIDs: [ForgeCompletionIdentifier],
        blockingRequirementIDs: [ForgeCompletionIdentifier],
        failedRequirementIDs: [ForgeCompletionIdentifier],
        repairDefectIDs: [ForgeCompletionIdentifier],
        undisclosedDefectIDs: [ForgeCompletionIdentifier],
        acceptedEvidenceReceiptIDs: [ForgeCompletionIdentifier],
        acceptedLimitationReceiptIDs: [ForgeCompletionIdentifier],
        acceptedLimitationIDs: [ForgeCompletionIdentifier]
    ) {
        self.state = state
        self.satisfiedRequirementIDs = satisfiedRequirementIDs
        self.blockingRequirementIDs = blockingRequirementIDs
        self.failedRequirementIDs = failedRequirementIDs
        self.repairDefectIDs = repairDefectIDs
        self.undisclosedDefectIDs = undisclosedDefectIDs
        self.acceptedEvidenceReceiptIDs = acceptedEvidenceReceiptIDs
        self.acceptedLimitationReceiptIDs = acceptedLimitationReceiptIDs
        self.acceptedLimitationIDs = acceptedLimitationIDs
    }
}

public enum ForgeCompletionEvaluator {
    public static func evaluate(
        constitution: ForgeCompletionConstitution,
        evidence: [ForgeCompletionEvidenceBinding],
        defects: [ForgeCompletionDefect],
        knownLimitations: [ForgeCompletionKnownLimitation]
    ) throws -> ForgeCompletionProjection {
        let requirementByID = Dictionary(uniqueKeysWithValues: constitution.requirements.map { ($0.id, $0) })

        var seenReceipts = Set<ForgeCompletionIdentifier>()
        for binding in evidence {
            guard seenReceipts.insert(binding.acceptedReceiptID).inserted else {
                throw ForgeCompletionValidationError.duplicateEvidenceReceiptID(binding.acceptedReceiptID.rawValue)
            }
            try validateIdentity(
                projectID: binding.projectID,
                sourceRevision: binding.sourceRevision,
                missionID: binding.missionID,
                constitutionRevision: binding.constitutionRevision,
                against: constitution,
                subject: "evidence:\(binding.acceptedReceiptID.rawValue)"
            )
            guard let requirement = requirementByID[binding.requirementID] else {
                throw ForgeCompletionValidationError.unknownRequirement(binding.requirementID.rawValue)
            }
            guard requirement.evidenceClass == binding.evidenceClass else {
                throw ForgeCompletionValidationError.evidenceClassMismatch(requirementID: binding.requirementID.rawValue)
            }
            guard binding.authority.supports(binding.evidenceClass) else {
                throw ForgeCompletionValidationError.unsupportedAuthority(requirementID: binding.requirementID.rawValue)
            }
        }

        var defectByID: [ForgeCompletionIdentifier: ForgeCompletionDefect] = [:]
        for defect in defects {
            guard defectByID[defect.id] == nil else {
                throw ForgeCompletionValidationError.duplicateDefectID(defect.id.rawValue)
            }
            guard defect.projectID == constitution.projectID, defect.sourceRevision == constitution.sourceRevision else {
                throw ForgeCompletionValidationError.identityMismatch("defect:\(defect.id.rawValue)")
            }
            defectByID[defect.id] = defect
        }

        var seenLimitations = Set<ForgeCompletionIdentifier>()
        var disclosedDefectIDs = Set<ForgeCompletionIdentifier>()
        for limitation in knownLimitations {
            guard seenLimitations.insert(limitation.id).inserted else {
                throw ForgeCompletionValidationError.duplicateLimitationID(limitation.id.rawValue)
            }
            guard limitation.projectID == constitution.projectID,
                  limitation.sourceRevision == constitution.sourceRevision,
                  limitation.missionID == constitution.missionID,
                  limitation.constitutionRevision == constitution.constitutionRevision else {
                throw ForgeCompletionValidationError.identityMismatch("limitation:\(limitation.id.rawValue)")
            }
            for defectID in limitation.relatedDefectIDs {
                guard defectByID[defectID] != nil else {
                    throw ForgeCompletionValidationError.unknownRelatedDefectID(defectID.rawValue)
                }
                disclosedDefectIDs.insert(defectID)
            }
        }

        let groupedEvidence = Dictionary(grouping: evidence, by: \.requirementID)
        var satisfied: [ForgeCompletionIdentifier] = []
        var blocking: [ForgeCompletionIdentifier] = []
        var failed: [ForgeCompletionIdentifier] = []
        var acceptedReceiptIDs = Set<ForgeCompletionIdentifier>()

        for requirement in constitution.requirements {
            let bindings = groupedEvidence[requirement.id, default: []]
            let passing = bindings.filter { $0.outcome == .passed }
            let hasFailure = bindings.contains { $0.outcome == .failed }

            if hasFailure && requirement.isRequired {
                failed.append(requirement.id)
            }
            if passing.count >= requirement.minimumPassingReceipts {
                satisfied.append(requirement.id)
                passing.forEach { acceptedReceiptIDs.insert($0.acceptedReceiptID) }
            } else if requirement.isRequired {
                blocking.append(requirement.id)
            }
        }

        let openDefects = defects.filter { $0.status == .open }
        var repairDefects = openDefects
            .filter { $0.severity >= .high }
            .map(\.id)

        let unresolvedLowerSeverity = openDefects.filter { $0.severity < .high }
        var undisclosed = unresolvedLowerSeverity
            .filter { !disclosedDefectIDs.contains($0.id) }
            .map(\.id)

        if constitution.knownLimitationsPolicy == .forbid {
            repairDefects.append(contentsOf: unresolvedLowerSeverity.map(\.id))
            undisclosed.removeAll()
        }

        satisfied.sort()
        blocking.sort()
        failed.sort()
        repairDefects = Array(Set(repairDefects)).sorted()
        undisclosed = Array(Set(undisclosed)).sorted()
        let limitationIDs = knownLimitations.map(\.id).sorted()
        let limitationReceiptIDs = Array(Set(knownLimitations.map(\.acceptedReceiptID))).sorted()
        let acceptedReceipts = Array(acceptedReceiptIDs).sorted()

        let state: ForgeCompletionState
        if !failed.isEmpty || !repairDefects.isEmpty {
            state = .repairRequired
        } else if !blocking.isEmpty || !undisclosed.isEmpty {
            state = .blocked
        } else if !knownLimitations.isEmpty {
            state = constitution.knownLimitationsPolicy == .allowExplicitAccepted
                ? .completeWithKnownLimitations
                : .repairRequired
        } else {
            state = .complete
        }

        return ForgeCompletionProjection(
            state: state,
            satisfiedRequirementIDs: satisfied,
            blockingRequirementIDs: blocking,
            failedRequirementIDs: failed,
            repairDefectIDs: repairDefects,
            undisclosedDefectIDs: undisclosed,
            acceptedEvidenceReceiptIDs: acceptedReceipts,
            acceptedLimitationReceiptIDs: limitationReceiptIDs,
            acceptedLimitationIDs: limitationIDs
        )
    }

    private static func validateIdentity(
        projectID: ForgeCompletionIdentifier,
        sourceRevision: ForgeCompletionIdentifier,
        missionID: ForgeCompletionIdentifier,
        constitutionRevision: Int,
        against constitution: ForgeCompletionConstitution,
        subject: String
    ) throws {
        guard projectID == constitution.projectID,
              sourceRevision == constitution.sourceRevision,
              missionID == constitution.missionID,
              constitutionRevision == constitution.constitutionRevision else {
            throw ForgeCompletionValidationError.identityMismatch(subject)
        }
    }
}

public struct ForgeCompletionArchive: Codable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let constitution: ForgeCompletionConstitution
    public let evidence: [ForgeCompletionEvidenceBinding]
    public let defects: [ForgeCompletionDefect]
    public let knownLimitations: [ForgeCompletionKnownLimitation]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        constitution: ForgeCompletionConstitution,
        evidence: [ForgeCompletionEvidenceBinding],
        defects: [ForgeCompletionDefect],
        knownLimitations: [ForgeCompletionKnownLimitation]
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ForgeCompletionValidationError.unsupportedSchema(schemaVersion)
        }
        _ = try ForgeCompletionEvaluator.evaluate(
            constitution: constitution,
            evidence: evidence,
            defects: defects,
            knownLimitations: knownLimitations
        )
        self.schemaVersion = schemaVersion
        self.constitution = constitution
        self.evidence = evidence
        self.defects = defects
        self.knownLimitations = knownLimitations
    }

    public func projection() throws -> ForgeCompletionProjection {
        try ForgeCompletionEvaluator.evaluate(
            constitution: constitution,
            evidence: evidence,
            defects: defects,
            knownLimitations: knownLimitations
        )
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, constitution, evidence, defects, knownLimitations
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
            constitution: container.decode(ForgeCompletionConstitution.self, forKey: .constitution),
            evidence: container.decode([ForgeCompletionEvidenceBinding].self, forKey: .evidence),
            defects: container.decode([ForgeCompletionDefect].self, forKey: .defects),
            knownLimitations: container.decode([ForgeCompletionKnownLimitation].self, forKey: .knownLimitations)
        )
    }
}
