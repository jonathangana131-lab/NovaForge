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

    public var isValid: Bool {
        ForgeHomeIdentityPolicy.isCanonicalOpaqueIdentity(rawValue)
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

/// Durable candidate metadata about a runtime artifact.
///
/// `verificationLevel` is a claim until the host authenticates the complete
/// owning `ForgeCreationRecord`. Persisting or decoding this value never grants
/// Home permission to expose Run by itself.
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

    /// Structural claim only. Host trust is separately required by the projector.
    public var claimsRunnableInsideNovaForge: Bool {
        artifactID.isValid &&
            ForgeHomeIdentityPolicy.isCanonicalOpaqueIdentity(sourceRevision) &&
            runtimeKind == .forgeWeb &&
            verificationLevel != .generated
    }
}

/// Durable candidate metadata about a preview artifact.
///
/// A `.runtimeScreenshot` tag is not proof that the bytes were captured from
/// the accepted project revision. Home requires current host trust before this
/// metadata can become an actual project thumbnail.
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

    /// Structural claim only. Host trust is separately required by the projector.
    public var claimsActualRunnablePreview: Bool {
        artifactID.isValid &&
            ForgeHomeIdentityPolicy.isCanonicalOpaqueIdentity(sourceRevision) &&
            kind == .runtimeScreenshot
    }
}

/// Durable candidate state used to derive Home/My Apps presentation.
///
/// Authority-bearing fields are intentionally Codable because the app needs to
/// persist project state, but they do not authorize presentation after decode.
/// `ForgeHomeTrustBinding` must be reacquired from a canonical host boundary.
public struct ForgeCreationRecord: Codable, Hashable, Sendable {
    public let id: ForgeCreationID
    public var name: String
    public var lastChangedAt: Date
    /// Exact accepted source/project-state revision represented by this creation.
    /// Whitespace aliases and control-character identities are not canonical.
    public var currentSourceRevision: String?
    public var activeMission: ForgeMissionReference?
    public var runtimeEvidence: ForgeRuntimeEvidence?
    public var thumbnailEvidence: ForgeThumbnailEvidence?
    /// Candidate capability claims. They become actions only for a host-trusted
    /// whole record.
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

public enum ForgeCreationAction: String, Codable, CaseIterable, Hashable, Sendable {
    case run
    case edit
    case duplicate
    case remix
    case export
    case details
}

/// Non-persistable host authentication of one complete Home candidate record.
///
/// The initializer is package-internal on purpose. Ordinary clients can persist
/// `ForgeCreationRecord`, but cannot turn those bytes back into trusted Home
/// authority. A later canonical ProjectStore/Mission/Runtime adapter must mint
/// this binding only after authenticating the current complete subject.
/// Whole-record equality is deliberate so newly added semantically relevant
/// fields automatically participate in trust rather than being forgotten in a
/// second hand-maintained field list.
public struct ForgeHomeTrustBinding: Hashable, Sendable {
    private let authenticatedRecord: ForgeCreationRecord

    init(authenticatedRecord: ForgeCreationRecord) {
        self.authenticatedRecord = authenticatedRecord
    }

    public func exactlyMatches(_ record: ForgeCreationRecord) -> Bool {
        authenticatedRecord == record
    }
}

/// Derived presentation state. It is intentionally not Codable: relaunch must
/// re-project from durable candidates plus freshly reacquired host trust.
public enum ForgeCreationRunState: Hashable, Sendable {
    case unavailable
    case available(ForgeRuntimeEvidence)

    public var isRunnable: Bool {
        if case .available = self { return true }
        return false
    }
}

/// Derived Home card. It is intentionally not Codable and can only be created
/// by `ForgeHomeProjector` inside this package.
public struct ForgeCreationCard: Hashable, Sendable, Identifiable {
    public let id: ForgeCreationID
    public let name: String
    public let lastChangedAt: Date
    public let activeMission: ForgeMissionReference?
    public let runState: ForgeCreationRunState
    public let actualThumbnail: ForgeThumbnailEvidence?
    public let actions: [ForgeCreationAction]

    init(
        id: ForgeCreationID,
        name: String,
        lastChangedAt: Date,
        activeMission: ForgeMissionReference?,
        runState: ForgeCreationRunState,
        actualThumbnail: ForgeThumbnailEvidence?,
        actions: [ForgeCreationAction]
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

/// Derived Home snapshot. It is intentionally not Codable so trusted Run,
/// mission, capability, or actual-preview presentation cannot be replayed from
/// serialized UI state.
public struct ForgeHomeSnapshot: Hashable, Sendable {
    public static let creationPrompt = "What do you want to make?"

    public let cards: [ForgeCreationCard]

    init(cards: [ForgeCreationCard]) {
        self.cards = cards
    }
}

public enum ForgeHomeProjector {
    /// Candidate-only projection. This overload deliberately fails closed for
    /// every authority-bearing Home claim and is safe for decoded/untrusted data.
    public static func project(_ records: [ForgeCreationRecord]) -> ForgeHomeSnapshot {
        project(records, trustBindings: [])
    }

    /// Projects records using only exact package-owned host trust bindings.
    public static func project(
        _ records: [ForgeCreationRecord],
        trustBindings: Set<ForgeHomeTrustBinding>
    ) -> ForgeHomeSnapshot {
        let cards = records.map { makeCard($0, trustBindings: trustBindings) }
            .sorted(by: cardComesBefore)
        return ForgeHomeSnapshot(cards: cards)
    }

    /// Candidate-only projection. The returned card exposes only non-authority
    /// presentation plus Details until current host trust is provided.
    public static func makeCard(_ record: ForgeCreationRecord) -> ForgeCreationCard {
        makeCard(record, trustBindings: [])
    }

    public static func makeCard(
        _ record: ForgeCreationRecord,
        trustBindings: Set<ForgeHomeTrustBinding>
    ) -> ForgeCreationCard {
        let isTrusted = trustBindings.contains { $0.exactlyMatches(record) }
        let currentRevision = canonicalRevision(record.currentSourceRevision)

        let acceptedRuntime: ForgeRuntimeEvidence?
        if isTrusted,
           let evidence = record.runtimeEvidence,
           evidence.claimsRunnableInsideNovaForge,
           let currentRevision,
           canonicalRevision(evidence.sourceRevision) == currentRevision {
            acceptedRuntime = evidence
        } else {
            acceptedRuntime = nil
        }

        let runState: ForgeCreationRunState = acceptedRuntime.map(ForgeCreationRunState.available) ?? .unavailable

        let thumbnail: ForgeThumbnailEvidence?
        if isTrusted,
           let candidate = record.thumbnailEvidence,
           candidate.claimsActualRunnablePreview,
           acceptedRuntime != nil,
           let currentRevision,
           canonicalRevision(candidate.sourceRevision) == currentRevision {
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
        guard let value, ForgeHomeIdentityPolicy.isCanonicalOpaqueIdentity(value) else { return nil }
        return value
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

private enum ForgeHomeIdentityPolicy {
    static func isCanonicalOpaqueIdentity(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }
}
