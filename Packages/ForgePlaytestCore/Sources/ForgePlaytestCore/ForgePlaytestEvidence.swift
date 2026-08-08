import Foundation

public struct ForgePlaytestJourneyPlan: Hashable, Sendable {
    public static let maximumExpectedMilestoneIDs = 128

    public let journeyID: String
    public let project: ForgePlaytestProjectRevision
    public let persona: ForgePlaytestPersona
    public let trace: ForgePlaytestTrace
    public let expectedMilestoneIDs: Set<String>

    public init(
        journeyID: String,
        project: ForgePlaytestProjectRevision,
        persona: ForgePlaytestPersona,
        trace: ForgePlaytestTrace,
        expectedMilestoneIDs: Set<String> = []
    ) throws {
        self.journeyID = try ForgePlaytestValidation.stableValue(
            journeyID,
            field: "journeyID",
            maximum: 160
        )
        try ForgePlaytestValidation.maximumCount(
            expectedMilestoneIDs.count,
            field: "journeyPlan.expectedMilestoneIDs",
            maximum: Self.maximumExpectedMilestoneIDs
        )
        var normalizedMilestones = Set<String>()
        for milestoneID in expectedMilestoneIDs {
            let normalized = try ForgePlaytestValidation.stableValue(
                milestoneID,
                field: "milestoneID",
                maximum: 160
            )
            guard normalizedMilestones.insert(normalized).inserted else {
                throw ForgePlaytestError.duplicateMilestoneID(normalized)
            }
        }
        self.project = project
        self.persona = persona
        self.trace = trace
        self.expectedMilestoneIDs = normalizedMilestones
    }
}

public enum ForgePlaytestEvidenceKind: String, CaseIterable, Hashable, Sendable {
    case runtimeExecution
    case runtimeState
    case runtimeEventLog
    case screenshot
    case saveReload
    case performanceSample
    case accessibilityAudit
    case visualComparison
    case crashLog
}

/// Opaque reference to evidence accepted by another canonical owner.
/// This type does not claim the referenced artifact is authentic merely because an ID exists.
public struct ForgePlaytestEvidenceReference: Hashable, Sendable {
    public let receiptID: String
    public let project: ForgePlaytestProjectRevision
    public let journeyID: String
    public let kind: ForgePlaytestEvidenceKind

    public init(
        receiptID: String,
        project: ForgePlaytestProjectRevision,
        journeyID: String,
        kind: ForgePlaytestEvidenceKind
    ) throws {
        self.receiptID = try ForgePlaytestValidation.stableValue(
            receiptID,
            field: "receiptID",
            maximum: 200
        )
        self.journeyID = try ForgePlaytestValidation.stableValue(
            journeyID,
            field: "journeyID",
            maximum: 160
        )
        self.project = project
        self.kind = kind
    }
}

public struct ForgePlaytestMilestoneObservation: Hashable, Sendable {
    public static let maximumEvidenceReceiptIDs = 32

    public let milestoneID: String
    public let evidenceReceiptIDs: Set<String>

    public init(milestoneID: String, evidenceReceiptIDs: Set<String>) throws {
        self.milestoneID = try ForgePlaytestValidation.stableValue(
            milestoneID,
            field: "milestoneID",
            maximum: 160
        )
        guard !evidenceReceiptIDs.isEmpty else {
            throw ForgePlaytestError.emptyReceiptReferences(field: "milestone.evidenceReceiptIDs")
        }
        try ForgePlaytestValidation.maximumCount(
            evidenceReceiptIDs.count,
            field: "milestone.evidenceReceiptIDs",
            maximum: Self.maximumEvidenceReceiptIDs
        )
        self.evidenceReceiptIDs = try ForgePlaytestValidation.receiptIDs(evidenceReceiptIDs)
    }
}

public enum ForgePlaytestDefectSeverity: Int, CaseIterable, Comparable, Hashable, Sendable {
    case low = 0
    case medium = 1
    case high = 2
    case critical = 3

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum ForgePlaytestDefectCategory: String, Hashable, Sendable {
    case functional
    case controls
    case persistence
    case visual
    case accessibility
    case performance
    case runtime
    case firstUse
}

public struct ForgePlaytestDefect: Hashable, Sendable {
    public static let maximumEvidenceReceiptIDs = 32

    public let defectID: String
    public let severity: ForgePlaytestDefectSeverity
    public let category: ForgePlaytestDefectCategory
    public let summary: String
    public let evidenceReceiptIDs: Set<String>

    public init(
        defectID: String,
        severity: ForgePlaytestDefectSeverity,
        category: ForgePlaytestDefectCategory,
        summary: String,
        evidenceReceiptIDs: Set<String>
    ) throws {
        self.defectID = try ForgePlaytestValidation.stableValue(
            defectID,
            field: "defectID",
            maximum: 160
        )
        self.summary = try ForgePlaytestValidation.userFacingValue(
            summary,
            field: "defect.summary",
            maximum: 600
        )
        guard !evidenceReceiptIDs.isEmpty else {
            throw ForgePlaytestError.emptyReceiptReferences(field: "defect.evidenceReceiptIDs")
        }
        try ForgePlaytestValidation.maximumCount(
            evidenceReceiptIDs.count,
            field: "defect.evidenceReceiptIDs",
            maximum: Self.maximumEvidenceReceiptIDs
        )
        self.severity = severity
        self.category = category
        self.evidenceReceiptIDs = try ForgePlaytestValidation.receiptIDs(evidenceReceiptIDs)
    }
}

public enum ForgePlaytestJourneyStatus: String, Hashable, Sendable {
    case completed
    case interrupted
    case failed
}

public struct ForgePlaytestJourneyResult: Hashable, Sendable {
    public static let maximumEvidenceReferences = 256
    public static let maximumMilestones = 128
    public static let maximumDefects = 128

    public let project: ForgePlaytestProjectRevision
    public let journeyID: String
    public let persona: ForgePlaytestPersona
    public let traceID: String
    public let status: ForgePlaytestJourneyStatus
    public let evidence: [ForgePlaytestEvidenceReference]
    public let milestones: [ForgePlaytestMilestoneObservation]
    public let defects: [ForgePlaytestDefect]

    public init(
        project: ForgePlaytestProjectRevision,
        journeyID: String,
        persona: ForgePlaytestPersona,
        traceID: String,
        status: ForgePlaytestJourneyStatus,
        evidence: [ForgePlaytestEvidenceReference],
        milestones: [ForgePlaytestMilestoneObservation] = [],
        defects: [ForgePlaytestDefect] = []
    ) throws {
        let normalizedJourneyID = try ForgePlaytestValidation.stableValue(
            journeyID,
            field: "journeyID",
            maximum: 160
        )
        self.traceID = try ForgePlaytestValidation.stableValue(
            traceID,
            field: "traceID",
            maximum: 160
        )
        try ForgePlaytestValidation.maximumCount(
            evidence.count,
            field: "journey.evidence",
            maximum: Self.maximumEvidenceReferences
        )
        try ForgePlaytestValidation.maximumCount(
            milestones.count,
            field: "journey.milestones",
            maximum: Self.maximumMilestones
        )
        try ForgePlaytestValidation.maximumCount(
            defects.count,
            field: "journey.defects",
            maximum: Self.maximumDefects
        )

        var receiptIDs = Set<String>()
        for reference in evidence {
            guard reference.project.projectID == project.projectID else {
                throw ForgePlaytestError.projectMismatch
            }
            guard reference.project.sourceRevision == project.sourceRevision else {
                throw ForgePlaytestError.sourceRevisionMismatch
            }
            guard reference.journeyID == normalizedJourneyID else {
                throw ForgePlaytestError.journeyMismatch
            }
            guard receiptIDs.insert(reference.receiptID).inserted else {
                throw ForgePlaytestError.duplicateReceiptID(reference.receiptID)
            }
        }

        if status == .completed, !evidence.contains(where: { $0.kind == .runtimeExecution }) {
            throw ForgePlaytestError.completedJourneyMissingRuntimeExecution
        }

        var milestoneIDs = Set<String>()
        for milestone in milestones {
            guard milestoneIDs.insert(milestone.milestoneID).inserted else {
                throw ForgePlaytestError.duplicateMilestoneID(milestone.milestoneID)
            }
            for receiptID in milestone.evidenceReceiptIDs where !receiptIDs.contains(receiptID) {
                throw ForgePlaytestError.unknownReceiptReference(receiptID)
            }
        }

        var defectIDs = Set<String>()
        for defect in defects {
            guard defectIDs.insert(defect.defectID).inserted else {
                throw ForgePlaytestError.duplicateDefectID(defect.defectID)
            }
            for receiptID in defect.evidenceReceiptIDs where !receiptIDs.contains(receiptID) {
                throw ForgePlaytestError.unknownReceiptReference(receiptID)
            }
        }

        self.project = project
        self.journeyID = normalizedJourneyID
        self.persona = persona
        self.status = status
        self.evidence = evidence
        self.milestones = milestones
        self.defects = defects
    }

    public var evidenceKinds: Set<ForgePlaytestEvidenceKind> {
        Set(evidence.map(\.kind))
    }

    public var milestoneIDs: Set<String> {
        Set(milestones.map(\.milestoneID))
    }
}
