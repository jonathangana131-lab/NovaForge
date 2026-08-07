import Foundation

public struct ForgeCreationID: RawRepresentable, Codable, Hashable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init() {
        self.rawValue = UUID()
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue.uuidString < rhs.rawValue.uuidString
    }

    public var description: String { rawValue.uuidString }
}

public struct ForgeArtifactID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public struct ForgeMissionReference: Codable, Hashable, Sendable {
    public enum State: String, Codable, Hashable, Sendable {
        case understanding
        case planning
        case editing
        case running
        case inspecting
        case fixing
        case polishing
        case waitingForDecision
        case paused
    }

    public let missionID: UUID
    public let state: State
    public let statusText: String
    public let updatedAt: Date

    public init(missionID: UUID, state: State, statusText: String, updatedAt: Date) {
        self.missionID = missionID
        self.state = state
        self.statusText = statusText
        self.updatedAt = updatedAt
    }
}

public struct ForgeRuntimeEvidence: Codable, Hashable, Sendable {
    public enum RuntimeKind: String, Codable, Hashable, Sendable {
        case forgeWeb
        case externalNative
    }

    public enum VerificationLevel: String, Codable, Hashable, Sendable {
        case generated
        case launchAuthorized
        case runtimeTested
        case simulatorVerified
        case physicalDeviceVerified
    }

    public let artifactID: ForgeArtifactID
    public let runtimeKind: RuntimeKind
    public let verificationLevel: VerificationLevel
    public let sourceRevision: String
    public let recordedAt: Date

    public init(
        artifactID: ForgeArtifactID,
        runtimeKind: RuntimeKind,
        verificationLevel: VerificationLevel,
        sourceRevision: String,
        recordedAt: Date
    ) {
        self.artifactID = artifactID
        self.runtimeKind = runtimeKind
        self.verificationLevel = verificationLevel
        self.sourceRevision = sourceRevision
        self.recordedAt = recordedAt
    }

    public var isRunnableInsideNovaForge: Bool {
        runtimeKind == .forgeWeb && verificationLevel != .generated
    }
}

public struct ForgeThumbnailEvidence: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case runtimeScreenshot
        case importedReference
    }

    public let artifactID: ForgeArtifactID
    public let kind: Kind
    public let sourceRevision: String
    public let recordedAt: Date

    public init(
        artifactID: ForgeArtifactID,
        kind: Kind,
        sourceRevision: String,
        recordedAt: Date
    ) {
        self.artifactID = artifactID
        self.kind = kind
        self.sourceRevision = sourceRevision
        self.recordedAt = recordedAt
    }

    /// Only a capture of the runnable project may be presented as the project's
    /// actual latest preview. Imported references remain useful inputs but are
    /// not evidence that NovaForge produced or ran the shown result.
    public var isActualRunnablePreview: Bool {
        kind == .runtimeScreenshot
    }
}

public struct ForgeCreationRecord: Codable, Hashable, Sendable {
    public let id: ForgeCreationID
    public var name: String
    public var lastChangedAt: Date
    public var activeMission: ForgeMissionReference?
    public var runtimeEvidence: ForgeRuntimeEvidence?
    public var thumbnailEvidence: ForgeThumbnailEvidence?
    public var canEditSource: Bool
    public var canDuplicate: Bool
    public var canRemix: Bool
    public var canExportSource: Bool

    public init(
        id: ForgeCreationID = ForgeCreationID(),
        name: String,
        lastChangedAt: Date,
        activeMission: ForgeMissionReference? = nil,
        runtimeEvidence: ForgeRuntimeEvidence? = nil,
        thumbnailEvidence: ForgeThumbnailEvidence? = nil,
        canEditSource: Bool = true,
        canDuplicate: Bool = true,
        canRemix: Bool = true,
        canExportSource: Bool = true
    ) {
        self.id = id
        self.name = name
        self.lastChangedAt = lastChangedAt
        self.activeMission = activeMission
        self.runtimeEvidence = runtimeEvidence
        self.thumbnailEvidence = thumbnailEvidence
        self.canEditSource = canEditSource
        self.canDuplicate = canDuplicate
        self.canRemix = canRemix
        self.canExportSource = canExportSource
    }
}

public enum ForgeCreationAction: String, Codable, CaseIterable, Hashable, Sendable {
    case run
    case edit
    case duplicate
    case remix
    case export
    case details
}

public enum ForgeCreationRunState: Codable, Hashable, Sendable {
    case unavailable
    case available(ForgeRuntimeEvidence)

    public var isRunnable: Bool {
        if case .available = self { return true }
        return false
    }
}

public struct ForgeCreationCard: Codable, Hashable, Sendable, Identifiable {
    public let id: ForgeCreationID
    public let name: String
    public let lastChangedAt: Date
    public let activeMission: ForgeMissionReference?
    public let runState: ForgeCreationRunState
    public let actualThumbnail: ForgeThumbnailEvidence?
    public let actions: Set<ForgeCreationAction>

    public init(
        id: ForgeCreationID,
        name: String,
        lastChangedAt: Date,
        activeMission: ForgeMissionReference?,
        runState: ForgeCreationRunState,
        actualThumbnail: ForgeThumbnailEvidence?,
        actions: Set<ForgeCreationAction>
    ) {
        self.id = id
        self.name = name
        self.lastChangedAt = lastChangedAt
        self.activeMission = activeMission
        self.runState = runState
        self.actualThumbnail = actualThumbnail
        self.actions = actions
    }
}

public struct ForgeHomeSnapshot: Codable, Hashable, Sendable {
    public static let creationPrompt = "What do you want to make?"

    public let cards: [ForgeCreationCard]

    public init(cards: [ForgeCreationCard]) {
        self.cards = cards
    }
}

public enum ForgeHomeProjector {
    public static func project(_ records: [ForgeCreationRecord]) -> ForgeHomeSnapshot {
        let cards = records.map(makeCard)
            .sorted(by: cardComesBefore)
        return ForgeHomeSnapshot(cards: cards)
    }

    public static func makeCard(_ record: ForgeCreationRecord) -> ForgeCreationCard {
        let runState: ForgeCreationRunState
        if let evidence = record.runtimeEvidence, evidence.isRunnableInsideNovaForge {
            runState = .available(evidence)
        } else {
            runState = .unavailable
        }

        let thumbnail: ForgeThumbnailEvidence?
        if let candidate = record.thumbnailEvidence,
           candidate.isActualRunnablePreview,
           let runtime = record.runtimeEvidence,
           runtime.isRunnableInsideNovaForge,
           candidate.sourceRevision == runtime.sourceRevision {
            thumbnail = candidate
        } else {
            thumbnail = nil
        }

        var actions: Set<ForgeCreationAction> = [.details]
        if runState.isRunnable { actions.insert(.run) }
        if record.canEditSource { actions.insert(.edit) }
        if record.canDuplicate { actions.insert(.duplicate) }
        if record.canRemix { actions.insert(.remix) }
        if record.canExportSource { actions.insert(.export) }

        return ForgeCreationCard(
            id: record.id,
            name: normalizedProjectName(record.name),
            lastChangedAt: record.lastChangedAt,
            activeMission: record.activeMission,
            runState: runState,
            actualThumbnail: thumbnail,
            actions: actions
        )
    }

    private static func cardComesBefore(_ lhs: ForgeCreationCard, _ rhs: ForgeCreationCard) -> Bool {
        let lhsHasMission = lhs.activeMission != nil
        let rhsHasMission = rhs.activeMission != nil
        if lhsHasMission != rhsHasMission { return lhsHasMission }

        let lhsMissionDate = lhs.activeMission?.updatedAt
        let rhsMissionDate = rhs.activeMission?.updatedAt
        if lhsMissionDate != rhsMissionDate {
            if let lhsMissionDate, let rhsMissionDate { return lhsMissionDate > rhsMissionDate }
            return lhsMissionDate != nil
        }

        if lhs.lastChangedAt != rhs.lastChangedAt { return lhs.lastChangedAt > rhs.lastChangedAt }
        return lhs.id < rhs.id
    }

    private static func normalizedProjectName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled Creation" : trimmed
    }
}

public struct ForgeNewCreationIntent: Codable, Hashable, Sendable {
    public let rawText: String

    public init(rawText: String) {
        self.rawText = rawText
    }

    public var normalizedText: String {
        rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isReadyToPlan: Bool {
        !normalizedText.isEmpty
    }
}
