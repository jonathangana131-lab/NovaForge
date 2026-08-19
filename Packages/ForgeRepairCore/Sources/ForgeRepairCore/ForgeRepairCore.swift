import Foundation

public enum ForgeRepairError: Error, Equatable, Sendable {
    case invalidIdentifier
    case invalidSummary
    case invalidBudget
    case invalidEvidence
    case identityMismatch
    case candidateMatchesSourceRevision
    case duplicateAttemptID
    case nonMonotonicAttemptOrdinal
    case attemptBudgetExceeded
    case assessmentMismatch
    case unsupportedArchiveSchema(Int)
}

private enum RepairValidation {
    static let maxIdentifierLength = 96
    static let maxSummaryLength = 512
    static let maxEvidenceReceipts = 64
    static let maxAttempts = 20

    static func identifier(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= maxIdentifierLength else {
            throw ForgeRepairError.invalidIdentifier
        }
        guard value.unicodeScalars.allSatisfy({ 0x21...0x7E ~= $0.value }) else {
            throw ForgeRepairError.invalidIdentifier
        }
        return value
    }

    static func summary(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= maxSummaryLength else {
            throw ForgeRepairError.invalidSummary
        }
        return value
    }
}

public struct ForgeRepairID<Tag: Sendable>: Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) throws {
        self.rawValue = try RepairValidation.identifier(rawValue)
    }

    public init(from decoder: Decoder) throws {
        try self.init(rawValue: decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum RepairProjectTag: Sendable {}
public enum RepairRevisionTag: Sendable {}
public enum RepairCheckpointTag: Sendable {}
public enum RepairDefectTag: Sendable {}
public enum RepairAttemptTag: Sendable {}
public enum RepairReceiptTag: Sendable {}

public typealias RepairProjectID = ForgeRepairID<RepairProjectTag>
public typealias RepairRevisionID = ForgeRepairID<RepairRevisionTag>
public typealias RepairCheckpointID = ForgeRepairID<RepairCheckpointTag>
public typealias RepairDefectID = ForgeRepairID<RepairDefectTag>
public typealias RepairAttemptID = ForgeRepairID<RepairAttemptTag>
public typealias RepairReceiptID = ForgeRepairID<RepairReceiptTag>

public enum RepairDefectClass: String, Codable, CaseIterable, Sendable {
    case build
    case runtime
    case behavior
    case persistence
    case visual
    case accessibility
    case performance
    case test
}

public enum RepairSeverity: Int, Codable, CaseIterable, Comparable, Sendable {
    case low = 0
    case medium = 1
    case high = 2
    case critical = 3

    public static func < (lhs: RepairSeverity, rhs: RepairSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct RepairDefect: Equatable, Codable, Sendable {
    public let id: RepairDefectID
    public let projectID: RepairProjectID
    public let discoveredRevisionID: RepairRevisionID
    public let defectClass: RepairDefectClass
    public let severity: RepairSeverity
    public let summary: String
    public let evidenceReceiptIDs: [RepairReceiptID]

    public init(
        id: RepairDefectID,
        projectID: RepairProjectID,
        discoveredRevisionID: RepairRevisionID,
        defectClass: RepairDefectClass,
        severity: RepairSeverity,
        summary: String,
        evidenceReceiptIDs: [RepairReceiptID]
    ) throws {
        guard !evidenceReceiptIDs.isEmpty,
              evidenceReceiptIDs.count <= RepairValidation.maxEvidenceReceipts,
              Set(evidenceReceiptIDs).count == evidenceReceiptIDs.count else {
            throw ForgeRepairError.invalidEvidence
        }
        self.id = id
        self.projectID = projectID
        self.discoveredRevisionID = discoveredRevisionID
        self.defectClass = defectClass
        self.severity = severity
        self.summary = try RepairValidation.summary(summary)
        self.evidenceReceiptIDs = evidenceReceiptIDs
    }

    private enum CodingKeys: String, CodingKey {
        case id, projectID, discoveredRevisionID, defectClass, severity, summary, evidenceReceiptIDs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: c.decode(RepairDefectID.self, forKey: .id),
            projectID: c.decode(RepairProjectID.self, forKey: .projectID),
            discoveredRevisionID: c.decode(RepairRevisionID.self, forKey: .discoveredRevisionID),
            defectClass: c.decode(RepairDefectClass.self, forKey: .defectClass),
            severity: c.decode(RepairSeverity.self, forKey: .severity),
            summary: c.decode(String.self, forKey: .summary),
            evidenceReceiptIDs: c.decode([RepairReceiptID].self, forKey: .evidenceReceiptIDs)
        )
    }
}

public struct RepairPolicy: Equatable, Codable, Sendable {
    public let maximumAttempts: Int
    public let escalateAfterNonImprovingAttempts: Int
    public let requireFullJourney: Bool
    public let requireVisualRegression: Bool
    public let requireAccessibility: Bool
    public let requirePerformance: Bool

    public init(
        maximumAttempts: Int = 4,
        escalateAfterNonImprovingAttempts: Int = 2,
        requireFullJourney: Bool = true,
        requireVisualRegression: Bool = true,
        requireAccessibility: Bool = true,
        requirePerformance: Bool = true
    ) throws {
        guard (1...RepairValidation.maxAttempts).contains(maximumAttempts),
              (1...maximumAttempts).contains(escalateAfterNonImprovingAttempts) else {
            throw ForgeRepairError.invalidBudget
        }
        self.maximumAttempts = maximumAttempts
        self.escalateAfterNonImprovingAttempts = escalateAfterNonImprovingAttempts
        self.requireFullJourney = requireFullJourney
        self.requireVisualRegression = requireVisualRegression
        self.requireAccessibility = requireAccessibility
        self.requirePerformance = requirePerformance
    }

    private enum CodingKeys: String, CodingKey {
        case maximumAttempts, escalateAfterNonImprovingAttempts, requireFullJourney
        case requireVisualRegression, requireAccessibility, requirePerformance
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            maximumAttempts: c.decode(Int.self, forKey: .maximumAttempts),
            escalateAfterNonImprovingAttempts: c.decode(Int.self, forKey: .escalateAfterNonImprovingAttempts),
            requireFullJourney: c.decode(Bool.self, forKey: .requireFullJourney),
            requireVisualRegression: c.decode(Bool.self, forKey: .requireVisualRegression),
            requireAccessibility: c.decode(Bool.self, forKey: .requireAccessibility),
            requirePerformance: c.decode(Bool.self, forKey: .requirePerformance)
        )
    }
}

public struct RepairEvidenceScorecard: Equatable, Codable, Sendable {
    public let targetDefectObserved: Bool
    public let criticalBlockers: Int
    public let highBlockers: Int
    public let failedJourneys: Int
    public let visualRegressions: Int
    public let accessibilityViolations: Int
    public let performanceViolations: Int
    public let receiptIDs: [RepairReceiptID]

    public init(
        targetDefectObserved: Bool,
        criticalBlockers: Int = 0,
        highBlockers: Int = 0,
        failedJourneys: Int = 0,
        visualRegressions: Int = 0,
        accessibilityViolations: Int = 0,
        performanceViolations: Int = 0,
        receiptIDs: [RepairReceiptID]
    ) throws {
        let counts = [
            criticalBlockers, highBlockers, failedJourneys, visualRegressions,
            accessibilityViolations, performanceViolations,
        ]
        guard counts.allSatisfy({ $0 >= 0 && $0 <= 1_000 }),
              !receiptIDs.isEmpty,
              receiptIDs.count <= RepairValidation.maxEvidenceReceipts,
              Set(receiptIDs).count == receiptIDs.count else {
            throw ForgeRepairError.invalidEvidence
        }
        self.targetDefectObserved = targetDefectObserved
        self.criticalBlockers = criticalBlockers
        self.highBlockers = highBlockers
        self.failedJourneys = failedJourneys
        self.visualRegressions = visualRegressions
        self.accessibilityViolations = accessibilityViolations
        self.performanceViolations = performanceViolations
        self.receiptIDs = receiptIDs
    }

    public var hasMaterialBlocker: Bool {
        criticalBlockers > 0 || highBlockers > 0 || failedJourneys > 0 ||
            visualRegressions > 0 || accessibilityViolations > 0 || performanceViolations > 0
    }

    fileprivate var comparisonVector: [Int] {
        [
            criticalBlockers,
            highBlockers,
            failedJourneys,
            visualRegressions,
            accessibilityViolations,
            performanceViolations,
            targetDefectObserved ? 1 : 0,
        ]
    }

    private enum CodingKeys: String, CodingKey {
        case targetDefectObserved, criticalBlockers, highBlockers, failedJourneys
        case visualRegressions, accessibilityViolations, performanceViolations, receiptIDs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            targetDefectObserved: c.decode(Bool.self, forKey: .targetDefectObserved),
            criticalBlockers: c.decode(Int.self, forKey: .criticalBlockers),
            highBlockers: c.decode(Int.self, forKey: .highBlockers),
            failedJourneys: c.decode(Int.self, forKey: .failedJourneys),
            visualRegressions: c.decode(Int.self, forKey: .visualRegressions),
            accessibilityViolations: c.decode(Int.self, forKey: .accessibilityViolations),
            performanceViolations: c.decode(Int.self, forKey: .performanceViolations),
            receiptIDs: c.decode([RepairReceiptID].self, forKey: .receiptIDs)
        )
    }
}

public struct RepairVerificationReceipts: Equatable, Codable, Sendable {
    public let focusedTest: RepairReceiptID?
    public let fullJourney: RepairReceiptID?
    public let visualRegression: RepairReceiptID?
    public let accessibility: RepairReceiptID?
    public let performance: RepairReceiptID?

    public init(
        focusedTest: RepairReceiptID? = nil,
        fullJourney: RepairReceiptID? = nil,
        visualRegression: RepairReceiptID? = nil,
        accessibility: RepairReceiptID? = nil,
        performance: RepairReceiptID? = nil
    ) throws {
        let ids = [focusedTest, fullJourney, visualRegression, accessibility, performance].compactMap { $0 }
        guard Set(ids).count == ids.count else { throw ForgeRepairError.invalidEvidence }
        self.focusedTest = focusedTest
        self.fullJourney = fullJourney
        self.visualRegression = visualRegression
        self.accessibility = accessibility
        self.performance = performance
    }
}

public enum RepairEvidenceTrend: String, Codable, Sendable {
    case improved
    case unchanged
    case regressed
}

public struct RepairAttempt: Equatable, Codable, Sendable {
    public let id: RepairAttemptID
    public let ordinal: Int
    public let projectID: RepairProjectID
    public let defectID: RepairDefectID
    public let sourceRevisionID: RepairRevisionID
    public let candidateRevisionID: RepairRevisionID
    public let knownGoodCheckpointID: RepairCheckpointID
    public let before: RepairEvidenceScorecard
    public let after: RepairEvidenceScorecard
    public let verification: RepairVerificationReceipts

    public init(
        id: RepairAttemptID,
        ordinal: Int,
        projectID: RepairProjectID,
        defectID: RepairDefectID,
        sourceRevisionID: RepairRevisionID,
        candidateRevisionID: RepairRevisionID,
        knownGoodCheckpointID: RepairCheckpointID,
        before: RepairEvidenceScorecard,
        after: RepairEvidenceScorecard,
        verification: RepairVerificationReceipts
    ) throws {
        guard ordinal > 0 else { throw ForgeRepairError.nonMonotonicAttemptOrdinal }
        guard sourceRevisionID != candidateRevisionID else {
            throw ForgeRepairError.candidateMatchesSourceRevision
        }
        self.id = id
        self.ordinal = ordinal
        self.projectID = projectID
        self.defectID = defectID
        self.sourceRevisionID = sourceRevisionID
        self.candidateRevisionID = candidateRevisionID
        self.knownGoodCheckpointID = knownGoodCheckpointID
        self.before = before
        self.after = after
        self.verification = verification
    }

    public var trend: RepairEvidenceTrend {
        let pairs = zip(after.comparisonVector, before.comparisonVector)
        if pairs.contains(where: { $0 > $1 }) {
            return .regressed
        }
        if zip(after.comparisonVector, before.comparisonVector).contains(where: { $0 < $1 }) {
            return .improved
        }
        return .unchanged
    }

    private enum CodingKeys: String, CodingKey {
        case id, ordinal, projectID, defectID, sourceRevisionID, candidateRevisionID
        case knownGoodCheckpointID, before, after, verification
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: c.decode(RepairAttemptID.self, forKey: .id),
            ordinal: c.decode(Int.self, forKey: .ordinal),
            projectID: c.decode(RepairProjectID.self, forKey: .projectID),
            defectID: c.decode(RepairDefectID.self, forKey: .defectID),
            sourceRevisionID: c.decode(RepairRevisionID.self, forKey: .sourceRevisionID),
            candidateRevisionID: c.decode(RepairRevisionID.self, forKey: .candidateRevisionID),
            knownGoodCheckpointID: c.decode(RepairCheckpointID.self, forKey: .knownGoodCheckpointID),
            before: c.decode(RepairEvidenceScorecard.self, forKey: .before),
            after: c.decode(RepairEvidenceScorecard.self, forKey: .after),
            verification: c.decode(RepairVerificationReceipts.self, forKey: .verification)
        )
    }
}

public enum RepairNextAction: String, Codable, Sendable {
    case runFocusedTest
    case runFullJourney
    case runVisualRegression
    case runAccessibility
    case runPerformance
    case acceptCandidate
    case retryFocusedRepair
    case escalateRootCause
    case restoreKnownGoodAndEscalate
    case stopBlocked
}

/// Persistable candidate projection only. This value is not execution authority; canonical repair
/// adapters must consume `ForgeRepairTrustedAssessment`, which cannot be minted by ordinary imports.
public struct RepairAssessment: Equatable, Codable, Sendable {
    public let nextAction: RepairNextAction
    public let attemptCount: Int
    public let consecutiveNonImprovingAttempts: Int
    public let candidateRevisionID: RepairRevisionID?

    public init(
        nextAction: RepairNextAction,
        attemptCount: Int,
        consecutiveNonImprovingAttempts: Int,
        candidateRevisionID: RepairRevisionID?
    ) {
        self.nextAction = nextAction
        self.attemptCount = attemptCount
        self.consecutiveNonImprovingAttempts = consecutiveNonImprovingAttempts
        self.candidateRevisionID = candidateRevisionID
    }
}

public struct RepairCampaign: Equatable, Codable, Sendable {
    public let projectID: RepairProjectID
    public let defect: RepairDefect
    public let knownGoodCheckpointID: RepairCheckpointID
    public let policy: RepairPolicy
    public let attempts: [RepairAttempt]

    public init(
        projectID: RepairProjectID,
        defect: RepairDefect,
        knownGoodCheckpointID: RepairCheckpointID,
        policy: RepairPolicy,
        attempts: [RepairAttempt] = []
    ) throws {
        guard defect.projectID == projectID else { throw ForgeRepairError.identityMismatch }
        guard attempts.count <= policy.maximumAttempts else { throw ForgeRepairError.attemptBudgetExceeded }

        var seen = Set<RepairAttemptID>()
        var expectedOrdinal = 1
        for attempt in attempts {
            guard attempt.projectID == projectID,
                  attempt.defectID == defect.id,
                  attempt.knownGoodCheckpointID == knownGoodCheckpointID else {
                throw ForgeRepairError.identityMismatch
            }
            guard seen.insert(attempt.id).inserted else { throw ForgeRepairError.duplicateAttemptID }
            guard attempt.ordinal == expectedOrdinal else { throw ForgeRepairError.nonMonotonicAttemptOrdinal }
            expectedOrdinal += 1
        }

        self.projectID = projectID
        self.defect = defect
        self.knownGoodCheckpointID = knownGoodCheckpointID
        self.policy = policy
        self.attempts = attempts
    }

    public func appending(_ attempt: RepairAttempt) throws -> RepairCampaign {
        try RepairCampaign(
            projectID: projectID,
            defect: defect,
            knownGoodCheckpointID: knownGoodCheckpointID,
            policy: policy,
            attempts: attempts + [attempt]
        )
    }

    /// Deterministic candidate projection used by package validation/archive integrity only.
    /// Ordinary imports cannot call this to authorize repair execution or candidate acceptance.
    func assess() -> RepairAssessment {
        guard let latest = attempts.last else {
            return RepairAssessment(
                nextAction: .retryFocusedRepair,
                attemptCount: 0,
                consecutiveNonImprovingAttempts: 0,
                candidateRevisionID: nil
            )
        }

        let nonImproving = attempts.reversed().prefix { $0.trend != .improved }.count

        if latest.trend == .regressed {
            return RepairAssessment(
                nextAction: .restoreKnownGoodAndEscalate,
                attemptCount: attempts.count,
                consecutiveNonImprovingAttempts: nonImproving,
                candidateRevisionID: latest.candidateRevisionID
            )
        }

        if !latest.after.targetDefectObserved && !latest.after.hasMaterialBlocker {
            if latest.verification.focusedTest == nil {
                return assessment(.runFocusedTest, latest, nonImproving)
            }
            if policy.requireFullJourney && latest.verification.fullJourney == nil {
                return assessment(.runFullJourney, latest, nonImproving)
            }
            if policy.requireVisualRegression && latest.verification.visualRegression == nil {
                return assessment(.runVisualRegression, latest, nonImproving)
            }
            if policy.requireAccessibility && latest.verification.accessibility == nil {
                return assessment(.runAccessibility, latest, nonImproving)
            }
            if policy.requirePerformance && latest.verification.performance == nil {
                return assessment(.runPerformance, latest, nonImproving)
            }
            return assessment(.acceptCandidate, latest, nonImproving)
        }

        if attempts.count >= policy.maximumAttempts {
            return assessment(.stopBlocked, latest, nonImproving)
        }
        if nonImproving >= policy.escalateAfterNonImprovingAttempts {
            return assessment(.escalateRootCause, latest, nonImproving)
        }
        return assessment(.retryFocusedRepair, latest, nonImproving)
    }

    private func assessment(
        _ action: RepairNextAction,
        _ latest: RepairAttempt,
        _ nonImproving: Int
    ) -> RepairAssessment {
        RepairAssessment(
            nextAction: action,
            attemptCount: attempts.count,
            consecutiveNonImprovingAttempts: nonImproving,
            candidateRevisionID: latest.candidateRevisionID
        )
    }

    private enum CodingKeys: String, CodingKey {
        case projectID, defect, knownGoodCheckpointID, policy, attempts
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            projectID: c.decode(RepairProjectID.self, forKey: .projectID),
            defect: c.decode(RepairDefect.self, forKey: .defect),
            knownGoodCheckpointID: c.decode(RepairCheckpointID.self, forKey: .knownGoodCheckpointID),
            policy: c.decode(RepairPolicy.self, forKey: .policy),
            attempts: c.decode([RepairAttempt].self, forKey: .attempts)
        )
    }
}

/// Durable candidate/archive integrity only. Decoding re-derives candidate policy projection but
/// never restores trusted execution authority; the trusted repair boundary is intentionally non-Codable.
public struct ForgeRepairArchive: Equatable, Codable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let campaign: RepairCampaign
    public let assessment: RepairAssessment

    public init(campaign: RepairCampaign) {
        self.schemaVersion = Self.currentSchemaVersion
        self.campaign = campaign
        self.assessment = campaign.assess()
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, campaign, assessment
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let schema = try c.decode(Int.self, forKey: .schemaVersion)
        guard schema == Self.currentSchemaVersion else {
            throw ForgeRepairError.unsupportedArchiveSchema(schema)
        }
        let campaign = try c.decode(RepairCampaign.self, forKey: .campaign)
        let assessment = try c.decode(RepairAssessment.self, forKey: .assessment)
        guard assessment == campaign.assess() else { throw ForgeRepairError.assessmentMismatch }
        self.schemaVersion = schema
        self.campaign = campaign
        self.assessment = assessment
    }
}
