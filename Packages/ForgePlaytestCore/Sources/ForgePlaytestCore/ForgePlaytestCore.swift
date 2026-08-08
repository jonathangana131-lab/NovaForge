import Foundation

/// DOMAIN/TRUTH contracts for V14 autonomous playtesting.
///
/// This module does not execute a project, grant runtime capabilities, capture screenshots,
/// or decide Mission Engine completion. It accepts only opaque receipts from those canonical
/// owners and projects whether a bounded set of playtest journeys is sufficient to pass the
/// playtest gate for one exact project revision.
public enum ForgePlaytestError: Error, Equatable, Sendable {
    case blankValue(field: String)
    case valueTooLong(field: String, maximum: Int)
    case controlCharacter(field: String)
    case invalidAxisValue
    case invalidPointerCoordinate
    case invalidTickRate
    case invalidStepSequence
    case invalidStepTick
    case tooManySteps(maximum: Int)
    case duplicateJourneyID(String)
    case duplicateReceiptID(String)
    case duplicateMilestoneID(String)
    case duplicateDefectID(String)
    case emptyReceiptReferences(field: String)
    case unknownReceiptReference(String)
    case projectMismatch
    case sourceRevisionMismatch
    case journeyMismatch
    case personaMismatch
    case conflictingPersonaRequirement(String)
    case invalidMinimumJourneys
    case emptyRequirements
    case invalidEvidenceRequirement
    case completedJourneyMissingRuntimeExecution
    case unknownJourneyPlan(String)
    case traceMismatch
    case collectionTooLarge(field: String, maximum: Int)
}

public struct ForgePlaytestProjectRevision: Hashable, Sendable {
    public let projectID: String
    public let sourceRevision: String

    public init(projectID: String, sourceRevision: String) throws {
        self.projectID = try ForgePlaytestValidation.stableValue(
            projectID,
            field: "projectID",
            maximum: 160
        )
        self.sourceRevision = try ForgePlaytestValidation.stableValue(
            sourceRevision,
            field: "sourceRevision",
            maximum: 200
        )
    }
}

public enum ForgePlaytestPersona: String, CaseIterable, Hashable, Sendable {
    case goalRunner
    case explorer
    case chaosTester
    case newPlayer
    case saveReloadTester
    case visualReviewer
    case performanceRunner
    case accessibilityRunner
}

public enum ForgePlaytestButtonPhase: String, Hashable, Sendable {
    case press
    case release
}

public enum ForgePlaytestPointerPhase: String, Hashable, Sendable {
    case begin
    case move
    case end
    case cancel
}

/// Semantic intent only. Runtime adapters remain responsible for mapping these actions to
/// explicitly authorized host/project controls.
public enum ForgePlaytestAction: Hashable, Sendable {
    case axis(controlID: String, value: Double)
    case button(controlID: String, phase: ForgePlaytestButtonPhase)
    case pointer(controlID: String, x: Double, y: Double, phase: ForgePlaytestPointerPhase)
    case wait
    case pause
    case resume
    case restart
    case save
    case reload
    case escape

    public static func validatedAxis(controlID: String, value: Double) throws -> Self {
        let id = try ForgePlaytestValidation.stableValue(controlID, field: "controlID", maximum: 120)
        guard value.isFinite, (-1.0 ... 1.0).contains(value) else {
            throw ForgePlaytestError.invalidAxisValue
        }
        return .axis(controlID: id, value: value)
    }

    public static func validatedButton(
        controlID: String,
        phase: ForgePlaytestButtonPhase
    ) throws -> Self {
        let id = try ForgePlaytestValidation.stableValue(controlID, field: "controlID", maximum: 120)
        return .button(controlID: id, phase: phase)
    }

    public static func validatedPointer(
        controlID: String,
        x: Double,
        y: Double,
        phase: ForgePlaytestPointerPhase
    ) throws -> Self {
        let id = try ForgePlaytestValidation.stableValue(controlID, field: "controlID", maximum: 120)
        guard x.isFinite, y.isFinite,
              (0.0 ... 1.0).contains(x),
              (0.0 ... 1.0).contains(y)
        else {
            throw ForgePlaytestError.invalidPointerCoordinate
        }
        return .pointer(controlID: id, x: x, y: y, phase: phase)
    }

    fileprivate func validate() throws {
        switch self {
        case let .axis(controlID, value):
            _ = try Self.validatedAxis(controlID: controlID, value: value)
        case let .button(controlID, phase):
            _ = try Self.validatedButton(controlID: controlID, phase: phase)
        case let .pointer(controlID, x, y, phase):
            _ = try Self.validatedPointer(controlID: controlID, x: x, y: y, phase: phase)
        case .wait, .pause, .resume, .restart, .save, .reload, .escape:
            break
        }
    }
}

public struct ForgePlaytestStep: Hashable, Sendable {
    public let sequence: Int
    public let tick: UInt64
    public let action: ForgePlaytestAction

    public init(sequence: Int, tick: UInt64, action: ForgePlaytestAction) throws {
        guard sequence >= 0 else { throw ForgePlaytestError.invalidStepSequence }
        try action.validate()
        self.sequence = sequence
        self.tick = tick
        self.action = action
    }
}

public struct ForgePlaytestTrace: Hashable, Sendable {
    public static let maximumSteps = 4_096
    public static let maximumDurationSeconds: UInt64 = 30 * 60

    public let traceID: String
    public let tickRateHz: UInt16
    public let steps: [ForgePlaytestStep]

    public init(traceID: String, tickRateHz: UInt16 = 60, steps: [ForgePlaytestStep]) throws {
        self.traceID = try ForgePlaytestValidation.stableValue(traceID, field: "traceID", maximum: 160)
        guard (1 ... 240).contains(tickRateHz) else { throw ForgePlaytestError.invalidTickRate }
        guard steps.count <= Self.maximumSteps else {
            throw ForgePlaytestError.tooManySteps(maximum: Self.maximumSteps)
        }

        let maximumTick = UInt64(tickRateHz) * Self.maximumDurationSeconds
        var previousTick: UInt64 = 0
        for (index, step) in steps.enumerated() {
            guard step.sequence == index else { throw ForgePlaytestError.invalidStepSequence }
            guard step.tick <= maximumTick else { throw ForgePlaytestError.invalidStepTick }
            if index > 0, step.tick < previousTick {
                throw ForgePlaytestError.invalidStepTick
            }
            try step.action.validate()
            previousTick = step.tick
        }

        self.tickRateHz = tickRateHz
        self.steps = steps
    }
}

public struct ForgePlaytestJourneyPlan: Hashable, Sendable {
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

public struct ForgePlaytestPersonaRequirement: Hashable, Sendable {
    public let persona: ForgePlaytestPersona
    public let minimumCompletedJourneys: Int
    public let requiredEvidenceKinds: Set<ForgePlaytestEvidenceKind>
    public let requiredMilestoneIDs: Set<String>

    public init(
        persona: ForgePlaytestPersona,
        minimumCompletedJourneys: Int = 1,
        requiredEvidenceKinds: Set<ForgePlaytestEvidenceKind> = [.runtimeExecution],
        requiredMilestoneIDs: Set<String> = []
    ) throws {
        guard minimumCompletedJourneys > 0, minimumCompletedJourneys <= 32 else {
            throw ForgePlaytestError.invalidMinimumJourneys
        }
        guard requiredEvidenceKinds.contains(.runtimeExecution) else {
            // Every accepted journey must bind to proof that a runtime execution happened.
            throw ForgePlaytestError.invalidEvidenceRequirement
        }
        var normalizedMilestones = Set<String>()
        for milestoneID in requiredMilestoneIDs {
            let normalized = try ForgePlaytestValidation.stableValue(
                milestoneID,
                field: "requiredMilestoneID",
                maximum: 160
            )
            guard normalizedMilestones.insert(normalized).inserted else {
                throw ForgePlaytestError.duplicateMilestoneID(normalized)
            }
        }
        self.persona = persona
        self.minimumCompletedJourneys = minimumCompletedJourneys
        self.requiredEvidenceKinds = requiredEvidenceKinds
        self.requiredMilestoneIDs = normalizedMilestones
    }
}

public struct ForgePlaytestAcceptancePolicy: Hashable, Sendable {
    public let requirements: [ForgePlaytestPersonaRequirement]
    public let repairThreshold: ForgePlaytestDefectSeverity

    public init(
        requirements: [ForgePlaytestPersonaRequirement],
        repairThreshold: ForgePlaytestDefectSeverity = .high
    ) throws {
        guard !requirements.isEmpty else { throw ForgePlaytestError.emptyRequirements }
        var personas = Set<ForgePlaytestPersona>()
        for requirement in requirements {
            guard personas.insert(requirement.persona).inserted else {
                throw ForgePlaytestError.conflictingPersonaRequirement(requirement.persona.rawValue)
            }
        }
        self.requirements = requirements.sorted { $0.persona.rawValue < $1.persona.rawValue }
        self.repairThreshold = repairThreshold
    }
}

public enum ForgePlaytestBlocker: Hashable, Sendable {
    case missingCompletedJourneys(persona: ForgePlaytestPersona, required: Int, actual: Int)
    case insufficientQualifiedJourneys(persona: ForgePlaytestPersona, required: Int, actual: Int)
    case missingEvidence(persona: ForgePlaytestPersona, kind: ForgePlaytestEvidenceKind)
    case missingMilestone(persona: ForgePlaytestPersona, milestoneID: String)
}

public struct ForgePlaytestRepairItem: Hashable, Sendable {
    public let journeyID: String
    public let persona: ForgePlaytestPersona
    public let defect: ForgePlaytestDefect
}

public struct ForgePlaytestAcceptedProjection: Hashable, Sendable {
    public let project: ForgePlaytestProjectRevision
    public let acceptedJourneyIDs: [String]
    public let contributingReceiptIDs: [String]

    fileprivate init(
        project: ForgePlaytestProjectRevision,
        acceptedJourneyIDs: [String],
        contributingReceiptIDs: [String]
    ) {
        self.project = project
        self.acceptedJourneyIDs = acceptedJourneyIDs
        self.contributingReceiptIDs = contributingReceiptIDs
    }
}

/// Playtest-only verdict. `.accepted` is evidence suitable for the Mission Engine to consume;
/// it is not itself mission completion.
public enum ForgePlaytestGateVerdict: Hashable, Sendable {
    case blocked([ForgePlaytestBlocker])
    case repairRequired([ForgePlaytestRepairItem])
    case accepted(ForgePlaytestAcceptedProjection)
}

public enum ForgePlaytestGateEvaluator {
    public static let maximumJourneyPlans = 256
    public static let maximumJourneyResults = 256

    public static func evaluate(
        project: ForgePlaytestProjectRevision,
        policy: ForgePlaytestAcceptancePolicy,
        plans: [ForgePlaytestJourneyPlan],
        results: [ForgePlaytestJourneyResult]
    ) throws -> ForgePlaytestGateVerdict {
        try ForgePlaytestValidation.maximumCount(
            plans.count,
            field: "playtest.plans",
            maximum: Self.maximumJourneyPlans
        )
        try ForgePlaytestValidation.maximumCount(
            results.count,
            field: "playtest.results",
            maximum: Self.maximumJourneyResults
        )

        var plansByJourneyID: [String: ForgePlaytestJourneyPlan] = [:]
        for plan in plans {
            guard plan.project.projectID == project.projectID else {
                throw ForgePlaytestError.projectMismatch
            }
            guard plan.project.sourceRevision == project.sourceRevision else {
                throw ForgePlaytestError.sourceRevisionMismatch
            }
            guard plansByJourneyID.updateValue(plan, forKey: plan.journeyID) == nil else {
                throw ForgePlaytestError.duplicateJourneyID(plan.journeyID)
            }
        }

        var journeyIDs = Set<String>()
        for result in results {
            guard journeyIDs.insert(result.journeyID).inserted else {
                throw ForgePlaytestError.duplicateJourneyID(result.journeyID)
            }
            guard result.project.projectID == project.projectID else {
                throw ForgePlaytestError.projectMismatch
            }
            guard result.project.sourceRevision == project.sourceRevision else {
                throw ForgePlaytestError.sourceRevisionMismatch
            }
            guard let plan = plansByJourneyID[result.journeyID] else {
                throw ForgePlaytestError.unknownJourneyPlan(result.journeyID)
            }
            guard plan.persona == result.persona else {
                throw ForgePlaytestError.personaMismatch
            }
            guard plan.trace.traceID == result.traceID else {
                throw ForgePlaytestError.traceMismatch
            }
        }

        let completed = results.filter { $0.status == .completed }
        var blockers: [ForgePlaytestBlocker] = []
        var acceptedJourneys = Set<String>()

        for requirement in policy.requirements {
            let personaResults = completed
                .filter { $0.persona == requirement.persona }
                .sorted { $0.journeyID < $1.journeyID }

            if personaResults.count < requirement.minimumCompletedJourneys {
                blockers.append(.missingCompletedJourneys(
                    persona: requirement.persona,
                    required: requirement.minimumCompletedJourneys,
                    actual: personaResults.count
                ))
                continue
            }

            let qualified = personaResults.filter { result in
                guard let plan = plansByJourneyID[result.journeyID] else { return false }
                return requirement.requiredEvidenceKinds.isSubset(of: result.evidenceKinds)
                    && requirement.requiredMilestoneIDs.isSubset(of: result.milestoneIDs)
                    && plan.expectedMilestoneIDs.isSubset(of: result.milestoneIDs)
            }

            if qualified.count < requirement.minimumCompletedJourneys {
                var addedSpecificBlocker = false

                for kind in requirement.requiredEvidenceKinds.sorted(by: { $0.rawValue < $1.rawValue }) {
                    let matchingCount = personaResults.filter { $0.evidenceKinds.contains(kind) }.count
                    if matchingCount < requirement.minimumCompletedJourneys {
                        blockers.append(.missingEvidence(persona: requirement.persona, kind: kind))
                        addedSpecificBlocker = true
                    }
                }

                for milestoneID in requirement.requiredMilestoneIDs.sorted() {
                    let matchingCount = personaResults.filter { $0.milestoneIDs.contains(milestoneID) }.count
                    if matchingCount < requirement.minimumCompletedJourneys {
                        blockers.append(.missingMilestone(persona: requirement.persona, milestoneID: milestoneID))
                        addedSpecificBlocker = true
                    }
                }

                let plannedMissingMilestones = Set(personaResults.flatMap { result -> [String] in
                    guard let plan = plansByJourneyID[result.journeyID] else { return [] }
                    return plan.expectedMilestoneIDs.subtracting(result.milestoneIDs).map { $0 }
                }).sorted()
                for milestoneID in plannedMissingMilestones {
                    blockers.append(.missingMilestone(persona: requirement.persona, milestoneID: milestoneID))
                    addedSpecificBlocker = true
                }

                if !addedSpecificBlocker {
                    blockers.append(.insufficientQualifiedJourneys(
                        persona: requirement.persona,
                        required: requirement.minimumCompletedJourneys,
                        actual: qualified.count
                    ))
                }
                continue
            }

            qualified.prefix(requirement.minimumCompletedJourneys).forEach {
                acceptedJourneys.insert($0.journeyID)
            }
        }

        if !blockers.isEmpty {
            return .blocked(blockers)
        }

        let repairItems = completed.flatMap { result in
            result.defects.compactMap { defect -> ForgePlaytestRepairItem? in
                guard defect.severity >= policy.repairThreshold else { return nil }
                return ForgePlaytestRepairItem(
                    journeyID: result.journeyID,
                    persona: result.persona,
                    defect: defect
                )
            }
        }.sorted {
            if $0.defect.severity != $1.defect.severity {
                return $0.defect.severity > $1.defect.severity
            }
            if $0.journeyID != $1.journeyID { return $0.journeyID < $1.journeyID }
            return $0.defect.defectID < $1.defect.defectID
        }

        if !repairItems.isEmpty {
            return .repairRequired(repairItems)
        }

        let contributingResults = completed.filter { acceptedJourneys.contains($0.journeyID) }
        let receiptIDs = Set(contributingResults.flatMap { $0.evidence.map(\.receiptID) }).sorted()
        return .accepted(ForgePlaytestAcceptedProjection(
            project: project,
            acceptedJourneyIDs: acceptedJourneys.sorted(),
            contributingReceiptIDs: receiptIDs
        ))
    }
}

private enum ForgePlaytestValidation {
    static func stableValue(_ value: String, field: String, maximum: Int) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw ForgePlaytestError.blankValue(field: field) }
        guard normalized.count <= maximum else {
            throw ForgePlaytestError.valueTooLong(field: field, maximum: maximum)
        }
        guard !normalized.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ForgePlaytestError.controlCharacter(field: field)
        }
        return normalized
    }

    static func userFacingValue(_ value: String, field: String, maximum: Int) throws -> String {
        try stableValue(value, field: field, maximum: maximum)
    }

    static func maximumCount(_ count: Int, field: String, maximum: Int) throws {
        guard count <= maximum else {
            throw ForgePlaytestError.collectionTooLarge(field: field, maximum: maximum)
        }
    }

    static func receiptIDs(_ values: Set<String>) throws -> Set<String> {
        var normalized = Set<String>()
        for value in values {
            let receiptID = try stableValue(value, field: "receiptID", maximum: 200)
            guard normalized.insert(receiptID).inserted else {
                throw ForgePlaytestError.duplicateReceiptID(receiptID)
            }
        }
        return normalized
    }
}
