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
    case repairThresholdTooWeak
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
