import Foundation

public enum ForgePlaytestValidationError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion
    case invalidIdentifier(field: String)
    case invalidText(field: String)
    case invalidLimit(field: String)
    case duplicateIdentifier(field: String)
    case invalidActionSequence
    case invalidActionPayload
    case unknownMilestoneReference
    case persistenceJourneyMissingRestart
    case persistenceJourneyMissingPostRestartMilestone
    case observationSequenceInvalid
    case observationActionMismatch
    case observationCountExceedsActions
    case milestoneObservationInvalid
    case candidateRunIdentityMismatch
}

public enum ForgePlaytestPersona: String, Codable, CaseIterable, Sendable {
    case goalRunner
    case explorer
    case chaosTester
    case newPlayer
    case persistenceTester
    case performanceRunner
}

public enum ForgePlaytestSemanticActionKind: String, Codable, CaseIterable, Sendable {
    /// Candidate intent corresponding to a host-authorized semantic control activation.
    case controlActivate
    /// Candidate intent corresponding to host-authorized text entry.
    case textEnter
    /// Candidate intent corresponding to a host-authorized bounded value update.
    case actionSetValue
    /// Candidate intent corresponding to a host-authorized bounded gesture.
    case gesturePerform
    /// Candidate intent asking the host lifecycle to restart the runtime.
    case runtimeRestart
    /// No input delivery claim; waits for later runtime/state evidence.
    case observe
}

public struct ForgePlaytestMilestone: Codable, Equatable, Hashable, Sendable {
    public static let maximumDescriptionUTF8Bytes = 512

    public let id: String
    public let description: String
    public let required: Bool

    public init(id: String, description: String, required: Bool) throws {
        try ForgePlaytestValidation.validateIdentifier(id, field: "milestone.id")
        try ForgePlaytestValidation.validateText(
            description,
            field: "milestone.description",
            maximumUTF8Bytes: Self.maximumDescriptionUTF8Bytes
        )
        self.id = id
        self.description = description
        self.required = required
    }

    private enum CodingKeys: String, CodingKey { case id, description, required }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(String.self, forKey: .id),
            description: container.decode(String.self, forKey: .description),
            required: container.decode(Bool.self, forKey: .required)
        )
    }
}

public struct ForgePlaytestAction: Codable, Equatable, Hashable, Sendable {
    public static let maximumTextUTF8Bytes = 16 * 1024
    public static let maximumGestureDurationMilliseconds = 30_000
    public static let maximumExpectedMilestonesPerAction = 32

    public let id: String
    public let sequence: Int
    public let kind: ForgePlaytestSemanticActionKind
    public let semanticTargetID: String?
    public let textValue: String?
    public let numericValue: Double?
    public let gestureDurationMilliseconds: Int?
    public let expectedMilestoneIDs: [String]

    public init(
        id: String,
        sequence: Int,
        kind: ForgePlaytestSemanticActionKind,
        semanticTargetID: String? = nil,
        textValue: String? = nil,
        numericValue: Double? = nil,
        gestureDurationMilliseconds: Int? = nil,
        expectedMilestoneIDs: [String] = []
    ) throws {
        try ForgePlaytestValidation.validateIdentifier(id, field: "action.id")
        guard sequence > 0 else { throw ForgePlaytestValidationError.invalidActionSequence }
        if let semanticTargetID {
            try ForgePlaytestValidation.validateIdentifier(semanticTargetID, field: "action.semanticTargetID")
        }
        guard expectedMilestoneIDs.count <= Self.maximumExpectedMilestonesPerAction else {
            throw ForgePlaytestValidationError.invalidLimit(field: "action.expectedMilestoneIDs")
        }
        for milestoneID in expectedMilestoneIDs {
            try ForgePlaytestValidation.validateIdentifier(milestoneID, field: "action.expectedMilestoneIDs")
        }
        guard Set(expectedMilestoneIDs).count == expectedMilestoneIDs.count else {
            throw ForgePlaytestValidationError.duplicateIdentifier(field: "action.expectedMilestoneIDs")
        }

        switch kind {
        case .controlActivate:
            guard semanticTargetID != nil,
                  textValue == nil,
                  numericValue == nil,
                  gestureDurationMilliseconds == nil else {
                throw ForgePlaytestValidationError.invalidActionPayload
            }
        case .textEnter:
            guard semanticTargetID != nil,
                  let textValue,
                  !textValue.isEmpty,
                  textValue.utf8.count <= Self.maximumTextUTF8Bytes,
                  numericValue == nil,
                  gestureDurationMilliseconds == nil else {
                throw ForgePlaytestValidationError.invalidActionPayload
            }
        case .actionSetValue:
            guard semanticTargetID != nil,
                  textValue == nil,
                  let numericValue,
                  numericValue.isFinite,
                  (-1.0 ... 1.0).contains(numericValue),
                  gestureDurationMilliseconds == nil else {
                throw ForgePlaytestValidationError.invalidActionPayload
            }
        case .gesturePerform:
            guard semanticTargetID != nil,
                  textValue == nil,
                  numericValue == nil,
                  let gestureDurationMilliseconds,
                  (1 ... Self.maximumGestureDurationMilliseconds).contains(gestureDurationMilliseconds) else {
                throw ForgePlaytestValidationError.invalidActionPayload
            }
        case .runtimeRestart, .observe:
            guard semanticTargetID == nil,
                  textValue == nil,
                  numericValue == nil,
                  gestureDurationMilliseconds == nil else {
                throw ForgePlaytestValidationError.invalidActionPayload
            }
        }

        self.id = id
        self.sequence = sequence
        self.kind = kind
        self.semanticTargetID = semanticTargetID
        self.textValue = textValue
        self.numericValue = numericValue
        self.gestureDurationMilliseconds = gestureDurationMilliseconds
        self.expectedMilestoneIDs = expectedMilestoneIDs
    }

    private enum CodingKeys: String, CodingKey {
        case id, sequence, kind, semanticTargetID, textValue, numericValue
        case gestureDurationMilliseconds, expectedMilestoneIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(String.self, forKey: .id),
            sequence: container.decode(Int.self, forKey: .sequence),
            kind: container.decode(ForgePlaytestSemanticActionKind.self, forKey: .kind),
            semanticTargetID: container.decodeIfPresent(String.self, forKey: .semanticTargetID),
            textValue: container.decodeIfPresent(String.self, forKey: .textValue),
            numericValue: container.decodeIfPresent(Double.self, forKey: .numericValue),
            gestureDurationMilliseconds: container.decodeIfPresent(Int.self, forKey: .gestureDurationMilliseconds),
            expectedMilestoneIDs: container.decode([String].self, forKey: .expectedMilestoneIDs)
        )
    }
}

public struct ForgePlaytestJourney: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let maximumActions = 1_024
    public static let maximumMilestones = 128

    public let schemaVersion: Int
    public let journeyID: String
    public let projectID: String
    public let sourceRevision: String
    public let checkpointID: String
    public let runtimeVersion: String
    public let persona: ForgePlaytestPersona
    public let deterministicSeed: UInt64
    public let maximumPlannedActions: Int
    public let milestones: [ForgePlaytestMilestone]
    public let actions: [ForgePlaytestAction]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        journeyID: String,
        projectID: String,
        sourceRevision: String,
        checkpointID: String,
        runtimeVersion: String,
        persona: ForgePlaytestPersona,
        deterministicSeed: UInt64,
        maximumPlannedActions: Int,
        milestones: [ForgePlaytestMilestone],
        actions: [ForgePlaytestAction]
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ForgePlaytestValidationError.unsupportedSchemaVersion
        }
        try ForgePlaytestValidation.validateIdentifier(journeyID, field: "journey.journeyID")
        try ForgePlaytestValidation.validateIdentifier(projectID, field: "journey.projectID")
        try ForgePlaytestValidation.validateIdentifier(sourceRevision, field: "journey.sourceRevision")
        try ForgePlaytestValidation.validateIdentifier(checkpointID, field: "journey.checkpointID")
        try ForgePlaytestValidation.validateIdentifier(runtimeVersion, field: "journey.runtimeVersion")
        guard (1 ... Self.maximumActions).contains(maximumPlannedActions),
              !actions.isEmpty,
              actions.count <= maximumPlannedActions,
              milestones.count <= Self.maximumMilestones else {
            throw ForgePlaytestValidationError.invalidLimit(field: "journey")
        }
        guard Set(actions.map(\.id)).count == actions.count else {
            throw ForgePlaytestValidationError.duplicateIdentifier(field: "journey.actions")
        }
        guard Set(milestones.map(\.id)).count == milestones.count else {
            throw ForgePlaytestValidationError.duplicateIdentifier(field: "journey.milestones")
        }
        for (offset, action) in actions.enumerated() where action.sequence != offset + 1 {
            throw ForgePlaytestValidationError.invalidActionSequence
        }
        let milestoneIDs = Set(milestones.map(\.id))
        for action in actions where !Set(action.expectedMilestoneIDs).isSubset(of: milestoneIDs) {
            throw ForgePlaytestValidationError.unknownMilestoneReference
        }
        if persona == .goalRunner, !milestones.contains(where: \.required) {
            throw ForgePlaytestValidationError.invalidLimit(field: "journey.goalRunner.requiredMilestone")
        }
        if persona == .persistenceTester {
            guard let restartIndex = actions.firstIndex(where: { $0.kind == .runtimeRestart }) else {
                throw ForgePlaytestValidationError.persistenceJourneyMissingRestart
            }
            let postRestartRequired = actions.dropFirst(restartIndex + 1).contains { action in
                action.expectedMilestoneIDs.contains { milestoneID in
                    milestones.first(where: { $0.id == milestoneID })?.required == true
                }
            }
            guard postRestartRequired else {
                throw ForgePlaytestValidationError.persistenceJourneyMissingPostRestartMilestone
            }
        }

        self.schemaVersion = schemaVersion
        self.journeyID = journeyID
        self.projectID = projectID
        self.sourceRevision = sourceRevision
        self.checkpointID = checkpointID
        self.runtimeVersion = runtimeVersion
        self.persona = persona
        self.deterministicSeed = deterministicSeed
        self.maximumPlannedActions = maximumPlannedActions
        self.milestones = milestones
        self.actions = actions
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, journeyID, projectID, sourceRevision, checkpointID, runtimeVersion
        case persona, deterministicSeed, maximumPlannedActions, milestones, actions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
            journeyID: container.decode(String.self, forKey: .journeyID),
            projectID: container.decode(String.self, forKey: .projectID),
            sourceRevision: container.decode(String.self, forKey: .sourceRevision),
            checkpointID: container.decode(String.self, forKey: .checkpointID),
            runtimeVersion: container.decode(String.self, forKey: .runtimeVersion),
            persona: container.decode(ForgePlaytestPersona.self, forKey: .persona),
            deterministicSeed: container.decode(UInt64.self, forKey: .deterministicSeed),
            maximumPlannedActions: container.decode(Int.self, forKey: .maximumPlannedActions),
            milestones: container.decode([ForgePlaytestMilestone].self, forKey: .milestones),
            actions: container.decode([ForgePlaytestAction].self, forKey: .actions)
        )
    }
}

public enum ForgePlaytestCandidateActionDisposition: String, Codable, Sendable {
    /// Caller-reported candidate metadata only. It is not a Runtime delivery receipt.
    case reportedDelivered
    case reportedRejected
    case reportedRuntimeUnavailable
}

public struct ForgePlaytestCandidateActionObservation: Codable, Equatable, Hashable, Sendable {
    public let actionID: String
    public let sequence: Int
    public let disposition: ForgePlaytestCandidateActionDisposition

    public init(actionID: String, sequence: Int, disposition: ForgePlaytestCandidateActionDisposition) throws {
        try ForgePlaytestValidation.validateIdentifier(actionID, field: "observation.actionID")
        guard sequence > 0 else { throw ForgePlaytestValidationError.observationSequenceInvalid }
        self.actionID = actionID
        self.sequence = sequence
        self.disposition = disposition
    }

    private enum CodingKeys: String, CodingKey { case actionID, sequence, disposition }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            actionID: container.decode(String.self, forKey: .actionID),
            sequence: container.decode(Int.self, forKey: .sequence),
            disposition: container.decode(ForgePlaytestCandidateActionDisposition.self, forKey: .disposition)
        )
    }
}

public struct ForgePlaytestCandidateMilestoneObservation: Codable, Equatable, Hashable, Sendable {
    public let milestoneID: String
    public let firstObservedAfterActionSequence: Int

    public init(milestoneID: String, firstObservedAfterActionSequence: Int) throws {
        try ForgePlaytestValidation.validateIdentifier(milestoneID, field: "milestoneObservation.milestoneID")
        guard firstObservedAfterActionSequence > 0 else {
            throw ForgePlaytestValidationError.milestoneObservationInvalid
        }
        self.milestoneID = milestoneID
        self.firstObservedAfterActionSequence = firstObservedAfterActionSequence
    }

    private enum CodingKeys: String, CodingKey { case milestoneID, firstObservedAfterActionSequence }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            milestoneID: container.decode(String.self, forKey: .milestoneID),
            firstObservedAfterActionSequence: container.decode(Int.self, forKey: .firstObservedAfterActionSequence)
        )
    }
}

public struct ForgePlaytestCandidateRun: Codable, Equatable, Sendable {
    public static let maximumFatalRuntimeErrors = 1_024

    public let runID: String
    public let journeyID: String
    public let projectID: String
    public let sourceRevision: String
    public let checkpointID: String
    public let runtimeVersion: String
    public let deterministicSeed: UInt64
    public let actionObservations: [ForgePlaytestCandidateActionObservation]
    public let milestoneObservations: [ForgePlaytestCandidateMilestoneObservation]
    public let reportedFatalRuntimeErrorCount: Int

    public init(
        runID: String,
        journeyID: String,
        projectID: String,
        sourceRevision: String,
        checkpointID: String,
        runtimeVersion: String,
        deterministicSeed: UInt64,
        actionObservations: [ForgePlaytestCandidateActionObservation],
        milestoneObservations: [ForgePlaytestCandidateMilestoneObservation],
        reportedFatalRuntimeErrorCount: Int
    ) throws {
        try ForgePlaytestValidation.validateIdentifier(runID, field: "run.runID")
        try ForgePlaytestValidation.validateIdentifier(journeyID, field: "run.journeyID")
        try ForgePlaytestValidation.validateIdentifier(projectID, field: "run.projectID")
        try ForgePlaytestValidation.validateIdentifier(sourceRevision, field: "run.sourceRevision")
        try ForgePlaytestValidation.validateIdentifier(checkpointID, field: "run.checkpointID")
        try ForgePlaytestValidation.validateIdentifier(runtimeVersion, field: "run.runtimeVersion")
        guard (0 ... Self.maximumFatalRuntimeErrors).contains(reportedFatalRuntimeErrorCount) else {
            throw ForgePlaytestValidationError.invalidLimit(field: "run.reportedFatalRuntimeErrorCount")
        }
        guard actionObservations.count <= ForgePlaytestJourney.maximumActions,
              milestoneObservations.count <= ForgePlaytestJourney.maximumMilestones else {
            throw ForgePlaytestValidationError.invalidLimit(field: "run.observations")
        }
        guard Set(actionObservations.map(\.actionID)).count == actionObservations.count else {
            throw ForgePlaytestValidationError.duplicateIdentifier(field: "run.actionObservations")
        }
        for (offset, observation) in actionObservations.enumerated() where observation.sequence != offset + 1 {
            throw ForgePlaytestValidationError.observationSequenceInvalid
        }
        guard Set(milestoneObservations.map(\.milestoneID)).count == milestoneObservations.count else {
            throw ForgePlaytestValidationError.duplicateIdentifier(field: "run.milestoneObservations")
        }

        self.runID = runID
        self.journeyID = journeyID
        self.projectID = projectID
        self.sourceRevision = sourceRevision
        self.checkpointID = checkpointID
        self.runtimeVersion = runtimeVersion
        self.deterministicSeed = deterministicSeed
        self.actionObservations = actionObservations
        self.milestoneObservations = milestoneObservations
        self.reportedFatalRuntimeErrorCount = reportedFatalRuntimeErrorCount
    }

    private enum CodingKeys: String, CodingKey {
        case runID, journeyID, projectID, sourceRevision, checkpointID, runtimeVersion
        case deterministicSeed, actionObservations, milestoneObservations, reportedFatalRuntimeErrorCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            runID: container.decode(String.self, forKey: .runID),
            journeyID: container.decode(String.self, forKey: .journeyID),
            projectID: container.decode(String.self, forKey: .projectID),
            sourceRevision: container.decode(String.self, forKey: .sourceRevision),
            checkpointID: container.decode(String.self, forKey: .checkpointID),
            runtimeVersion: container.decode(String.self, forKey: .runtimeVersion),
            deterministicSeed: container.decode(UInt64.self, forKey: .deterministicSeed),
            actionObservations: container.decode([ForgePlaytestCandidateActionObservation].self, forKey: .actionObservations),
            milestoneObservations: container.decode([ForgePlaytestCandidateMilestoneObservation].self, forKey: .milestoneObservations),
            reportedFatalRuntimeErrorCount: container.decode(Int.self, forKey: .reportedFatalRuntimeErrorCount)
        )
    }
}

public enum ForgePlaytestCandidateFailure: Equatable, Sendable {
    case incompleteActionTrace(expected: Int, observed: Int)
    case actionNotReportedDelivered(actionID: String)
    case requiredMilestoneMissing(milestoneID: String)
    case milestoneObservedBeforeExpectedAction(milestoneID: String)
    case reportedFatalRuntimeErrors(count: Int)
}

public enum ForgePlaytestCandidateDisposition: Equatable, Sendable {
    case satisfiedCandidate
    case incomplete([ForgePlaytestCandidateFailure])
    case failedCandidate([ForgePlaytestCandidateFailure])
}

public struct ForgePlaytestCandidateProjection: Equatable, Sendable {
    public let disposition: ForgePlaytestCandidateDisposition
    public let journeyID: String
    public let runID: String

    /// Candidate projections are never Runtime, Mission, Playtest, or Completion authority.
    public var authorizesExecution: Bool { false }
    public var authorizesCompletion: Bool { false }
}

public enum ForgePlaytestCandidateEvaluator {
    public static func project(
        journey: ForgePlaytestJourney,
        run: ForgePlaytestCandidateRun
    ) throws -> ForgePlaytestCandidateProjection {
        guard run.journeyID == journey.journeyID,
              run.projectID == journey.projectID,
              run.sourceRevision == journey.sourceRevision,
              run.checkpointID == journey.checkpointID,
              run.runtimeVersion == journey.runtimeVersion,
              run.deterministicSeed == journey.deterministicSeed else {
            throw ForgePlaytestValidationError.candidateRunIdentityMismatch
        }
        guard run.actionObservations.count <= journey.actions.count else {
            throw ForgePlaytestValidationError.observationCountExceedsActions
        }
        for (offset, observation) in run.actionObservations.enumerated() {
            let action = journey.actions[offset]
            guard observation.sequence == action.sequence,
                  observation.actionID == action.id else {
                throw ForgePlaytestValidationError.observationActionMismatch
            }
        }

        let milestoneByID = Dictionary(uniqueKeysWithValues: journey.milestones.map { ($0.id, $0) })
        let firstExpectedSequence = firstExpectedMilestoneSequence(journey: journey)
        for observation in run.milestoneObservations {
            guard milestoneByID[observation.milestoneID] != nil,
                  observation.firstObservedAfterActionSequence <= journey.actions.count else {
                throw ForgePlaytestValidationError.milestoneObservationInvalid
            }
        }

        var hardFailures: [ForgePlaytestCandidateFailure] = []
        var incompleteness: [ForgePlaytestCandidateFailure] = []

        if run.reportedFatalRuntimeErrorCount > 0 {
            hardFailures.append(.reportedFatalRuntimeErrors(count: run.reportedFatalRuntimeErrorCount))
        }

        for observation in run.actionObservations where observation.disposition != .reportedDelivered {
            hardFailures.append(.actionNotReportedDelivered(actionID: observation.actionID))
        }

        if run.actionObservations.count < journey.actions.count {
            incompleteness.append(
                .incompleteActionTrace(expected: journey.actions.count, observed: run.actionObservations.count)
            )
        }

        let observedMilestones = Dictionary(
            uniqueKeysWithValues: run.milestoneObservations.map { ($0.milestoneID, $0.firstObservedAfterActionSequence) }
        )
        for milestone in journey.milestones where milestone.required {
            guard let observedSequence = observedMilestones[milestone.id] else {
                if run.actionObservations.count == journey.actions.count {
                    hardFailures.append(.requiredMilestoneMissing(milestoneID: milestone.id))
                } else {
                    incompleteness.append(.requiredMilestoneMissing(milestoneID: milestone.id))
                }
                continue
            }
            if let expectedSequence = firstExpectedSequence[milestone.id], observedSequence < expectedSequence {
                hardFailures.append(.milestoneObservedBeforeExpectedAction(milestoneID: milestone.id))
            }
        }

        let disposition: ForgePlaytestCandidateDisposition
        if !hardFailures.isEmpty {
            disposition = .failedCandidate(hardFailures + incompleteness)
        } else if !incompleteness.isEmpty {
            disposition = .incomplete(incompleteness)
        } else {
            disposition = .satisfiedCandidate
        }

        return ForgePlaytestCandidateProjection(
            disposition: disposition,
            journeyID: journey.journeyID,
            runID: run.runID
        )
    }

    private static func firstExpectedMilestoneSequence(journey: ForgePlaytestJourney) -> [String: Int] {
        var result: [String: Int] = [:]
        for action in journey.actions {
            for milestoneID in action.expectedMilestoneIDs where result[milestoneID] == nil {
                result[milestoneID] = action.sequence
            }
        }
        return result
    }
}

private enum ForgePlaytestValidation {
    private static let maximumIdentifierUTF8Bytes = 160

    static func validateIdentifier(_ value: String, field: String) throws {
        guard !value.isEmpty,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.utf8.count <= maximumIdentifierUTF8Bytes,
              !value.contains("/"),
              !value.contains("\\"),
              value.unicodeScalars.allSatisfy({ scalar in
                  scalar.value >= 0x21 && scalar.value <= 0x7E
              }) else {
            throw ForgePlaytestValidationError.invalidIdentifier(field: field)
        }
    }

    static func validateText(_ value: String, field: String, maximumUTF8Bytes: Int) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.utf8.count <= maximumUTF8Bytes,
              !value.unicodeScalars.contains(where: { scalar in
                  scalar.value < 0x20 && scalar != "\n" && scalar != "\t"
              }) else {
            throw ForgePlaytestValidationError.invalidText(field: field)
        }
    }
}
