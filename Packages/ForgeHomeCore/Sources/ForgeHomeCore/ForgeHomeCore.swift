import Foundation

public struct ForgeCreationID: RawRepresentable, Codable, Hashable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init() { self.rawValue = UUID() }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue.uuidString < rhs.rawValue.uuidString
    }

    public var description: String { rawValue.uuidString }
}

public struct ForgeArtifactID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    public var isCanonical: Bool { ForgeHomeIdentity.isCanonical(rawValue) }
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

/// Persistable candidate metadata. Its verification label is not proof that a
/// project actually ran; only a package-owned trust binding can promote it into
/// Home/My Apps capability truth.
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

    public var claimsRunnableInsideNovaForge: Bool {
        artifactID.isCanonical &&
            ForgeHomeIdentity.isCanonical(sourceRevision) &&
            runtimeKind == .forgeWeb &&
            verificationLevel != .generated
    }
}

/// Persistable candidate preview metadata. `runtimeScreenshot` is a claim until
/// a canonical capture/runtime producer authenticates the whole creation record.
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

    public var claimsActualRunnablePreview: Bool {
        artifactID.isCanonical &&
            ForgeHomeIdentity.isCanonical(sourceRevision) &&
            kind == .runtimeScreenshot
    }
}

/// Durable candidate input for Home/My Apps. Codable bytes never restore trust.
public struct ForgeCreationRecord: Codable, Hashable, Sendable {
    public let id: ForgeCreationID
    public var name: String
    public var lastChangedAt: Date
    public var currentSourceRevision: String?
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
        currentSourceRevision: String? = nil,
        activeMission: ForgeMissionReference? = nil,
        runtimeEvidence: ForgeRuntimeEvidence? = nil,
        thumbnailEvidence: ForgeThumbnailEvidence? = nil,
        canEditSource: Bool = false,
        canDuplicate: Bool = false,
        canRemix: Bool = false,
        canExportSource: Bool = false
    ) {
        self.id = id
        self.name = name
        self.lastChangedAt = lastChangedAt
        self.currentSourceRevision = currentSourceRevision
        self.activeMission = activeMission
        self.runtimeEvidence = runtimeEvidence
        self.thumbnailEvidence = thumbnailEvidence
        self.canEditSource = canEditSource
        self.canDuplicate = canDuplicate
        self.canRemix = canRemix
        self.canExportSource = canExportSource
    }
}

public enum ForgeHomeTrustError: Error, Equatable, Sendable {
    case nonCanonicalCurrentSourceRevision
    case nonCanonicalRuntimeArtifact
    case nonCanonicalRuntimeSourceRevision
    case nonCanonicalThumbnailArtifact
    case nonCanonicalThumbnailSourceRevision
    case invalidMissionStatus
}

/// Transient host trust over the complete candidate record. The initializer is
/// intentionally module-internal: persisted/model-authored bytes cannot mint
/// Home capability authority. A future adapter in this module must construct
/// this only after authenticating canonical Project/Mission/Runtime/Visual-QA
/// producer receipts for the whole record.
public struct ForgeHomeTrustBinding: Hashable, Sendable {
    private let authenticatedRecord: ForgeCreationRecord

    init(authenticatedRecord: ForgeCreationRecord) throws {
        if let revision = authenticatedRecord.currentSourceRevision,
           !ForgeHomeIdentity.isCanonical(revision) {
            throw ForgeHomeTrustError.nonCanonicalCurrentSourceRevision
        }
        if let runtime = authenticatedRecord.runtimeEvidence {
            guard runtime.artifactID.isCanonical else {
                throw ForgeHomeTrustError.nonCanonicalRuntimeArtifact
            }
            guard ForgeHomeIdentity.isCanonical(runtime.sourceRevision) else {
                throw ForgeHomeTrustError.nonCanonicalRuntimeSourceRevision
            }
        }
        if let thumbnail = authenticatedRecord.thumbnailEvidence {
            guard thumbnail.artifactID.isCanonical else {
                throw ForgeHomeTrustError.nonCanonicalThumbnailArtifact
            }
            guard ForgeHomeIdentity.isCanonical(thumbnail.sourceRevision) else {
                throw ForgeHomeTrustError.nonCanonicalThumbnailSourceRevision
            }
        }
        if let mission = authenticatedRecord.activeMission,
           mission.statusText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ForgeHomeTrustError.invalidMissionStatus
        }
        self.authenticatedRecord = authenticatedRecord
    }

    public var creationID: ForgeCreationID { authenticatedRecord.id }

    func matches(_ record: ForgeCreationRecord) -> Bool {
        authenticatedRecord == record
    }
}

public enum ForgeCreationAction: String, CaseIterable, Hashable, Sendable {
    case run
    case edit
    case duplicate
    case remix
    case export
    case details
}

/// Read-only presentation of Home run capability. External callers cannot construct
/// a runnable value; only package-owned projection from authenticated Home trust may do so.
public struct ForgeCreationRunState: Hashable, Sendable {
    private let acceptedRuntimeEvidence: ForgeRuntimeEvidence?

    init(acceptedRuntimeEvidence: ForgeRuntimeEvidence?) {
        self.acceptedRuntimeEvidence = acceptedRuntimeEvidence
    }

    public var isRunnable: Bool { acceptedRuntimeEvidence != nil }
    public var runtimeEvidence: ForgeRuntimeEvidence? { acceptedRuntimeEvidence }
}

/// Derived presentation state. Intentionally non-Codable: relaunch must rebuild
/// it from candidate records plus freshly authenticated trust bindings.
public struct ForgeCreationCard: Hashable, Sendable, Identifiable {
    public let id: ForgeCreationID
    public let name: String
    public let lastChangedAt: Date
    public let activeMission: ForgeMissionReference?
    public let runState: ForgeCreationRunState
    public let actualThumbnail: ForgeThumbnailEvidence?
    public let actions: [ForgeCreationAction]
}

public struct ForgeHomeSnapshot: Hashable, Sendable {
    public static let creationPrompt = "What do you want to make?"
    public let cards: [ForgeCreationCard]
    /// Duplicate persisted identities are quarantined rather than selecting a caller-controlled winner.
    public let conflictedCreationIDs: [ForgeCreationID]
}

public enum ForgeHomeProjector {
    public static func project(
        _ records: [ForgeCreationRecord],
        trustedBindings: Set<ForgeHomeTrustBinding> = []
    ) -> ForgeHomeSnapshot {
        let grouped = Dictionary(grouping: records, by: \.id)
        let conflictedCreationIDs = grouped
            .filter { $0.value.count > 1 }
            .map(\.key)
            .sorted()
        let uniqueRecords = grouped
            .filter { $0.value.count == 1 }
            .compactMap { $0.value.first }
        let cards = uniqueRecords
            .map { makeCard($0, trustedBindings: trustedBindings) }
            .sorted(by: cardComesBefore)
        return ForgeHomeSnapshot(cards: cards, conflictedCreationIDs: conflictedCreationIDs)
    }

    public static func makeCard(
        _ record: ForgeCreationRecord,
        trustedBindings: Set<ForgeHomeTrustBinding> = []
    ) -> ForgeCreationCard {
        let isTrusted = trustedBindings.contains { $0.matches(record) }
        let currentRevision = canonicalRevision(record.currentSourceRevision)

        let acceptedRuntime: ForgeRuntimeEvidence?
        if isTrusted,
           let evidence = record.runtimeEvidence,
           evidence.claimsRunnableInsideNovaForge,
           let currentRevision,
           evidence.sourceRevision == currentRevision {
            acceptedRuntime = evidence
        } else {
            acceptedRuntime = nil
        }

        let runState = ForgeCreationRunState(acceptedRuntimeEvidence: acceptedRuntime)

        let thumbnail: ForgeThumbnailEvidence?
        if isTrusted,
           let candidate = record.thumbnailEvidence,
           candidate.claimsActualRunnablePreview,
           acceptedRuntime != nil,
           let currentRevision,
           candidate.sourceRevision == currentRevision {
            thumbnail = candidate
        } else {
            thumbnail = nil
        }

        var actions: [ForgeCreationAction] = []
        if runState.isRunnable { actions.append(.run) }
        if isTrusted && record.canEditSource { actions.append(.edit) }
        if isTrusted && record.canDuplicate { actions.append(.duplicate) }
        if isTrusted && record.canRemix { actions.append(.remix) }
        if isTrusted && record.canExportSource { actions.append(.export) }
        actions.append(.details)

        return ForgeCreationCard(
            id: record.id,
            name: normalizedProjectName(record.name),
            lastChangedAt: record.lastChangedAt,
            activeMission: isTrusted ? record.activeMission : nil,
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

    private static func canonicalRevision(_ value: String?) -> String? {
        guard let value, ForgeHomeIdentity.isCanonical(value) else { return nil }
        return value
    }
}

public struct ForgeNewCreationIntent: Codable, Hashable, Sendable {
    public let rawText: String

    public init(rawText: String) { self.rawText = rawText }

    public var normalizedText: String {
        rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isReadyToPlan: Bool { !normalizedText.isEmpty }
}

private enum ForgeHomeIdentity {
    static func isCanonical(_ value: String) -> Bool {
        guard !value.isEmpty,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            return false
        }
        return true
    }
}
