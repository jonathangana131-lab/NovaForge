import Foundation

public enum ForgeHomeInvariantError: Error, Equatable, Sendable {
    case invalidArtifactIdentity
    case invalidSourceRevision
    case invalidProducerReceipt
    case invalidMissionStatus
    case invalidArtifactDigest
    case duplicateCapability
    case runtimeEvidenceCannotBeTrusted
    case thumbnailEvidenceCannotBeTrusted
}

private enum ForgeHomeIdentity {
    static func isCanonical(_ value: String) -> Bool {
        guard !value.isEmpty,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return false }
        return value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    static func isCanonicalSHA256(_ value: String) -> Bool {
        guard value.utf8.count == 64 else { return false }
        return value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }
}

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

    public var isCanonical: Bool { ForgeHomeIdentity.isCanonical(rawValue) }
    public var description: String { rawValue }
}

/// Durable creation-owned state. Runtime, screenshot, mission and capability authority are
/// deliberately not persisted here. Those authorities must be reacquired from canonical producers
/// after relaunch before Home can expose Run, actual screenshots, active-mission state or actions.
public struct ForgeCreationRecord: Codable, Hashable, Sendable {
    public let id: ForgeCreationID
    public var name: String
    public var lastChangedAt: Date
    public var currentSourceRevision: String?

    public init(
        id: ForgeCreationID = ForgeCreationID(),
        name: String,
        lastChangedAt: Date,
        currentSourceRevision: String? = nil
    ) throws {
        if let currentSourceRevision {
            guard ForgeHomeIdentity.isCanonical(currentSourceRevision) else {
                throw ForgeHomeInvariantError.invalidSourceRevision
            }
        }
        self.id = id
        self.name = name
        self.lastChangedAt = lastChangedAt
        self.currentSourceRevision = currentSourceRevision
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case lastChangedAt
        case currentSourceRevision
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(ForgeCreationID.self, forKey: .id)
        let name = try container.decode(String.self, forKey: .name)
        let lastChangedAt = try container.decode(Date.self, forKey: .lastChangedAt)
        let currentSourceRevision = try container.decodeIfPresent(String.self, forKey: .currentSourceRevision)
        try self.init(
            id: id,
            name: name,
            lastChangedAt: lastChangedAt,
            currentSourceRevision: currentSourceRevision
        )
    }
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

    public let creationID: ForgeCreationID
    public let missionID: UUID
    public let sourceRevision: String
    public let state: State
    public let statusText: String
    public let updatedAt: Date
    public let producerReceiptID: String

    public init(
        creationID: ForgeCreationID,
        missionID: UUID,
        sourceRevision: String,
        state: State,
        statusText: String,
        updatedAt: Date,
        producerReceiptID: String
    ) throws {
        guard ForgeHomeIdentity.isCanonical(sourceRevision) else {
            throw ForgeHomeInvariantError.invalidSourceRevision
        }
        guard ForgeHomeIdentity.isCanonical(statusText) else {
            throw ForgeHomeInvariantError.invalidMissionStatus
        }
        guard ForgeHomeIdentity.isCanonical(producerReceiptID) else {
            throw ForgeHomeInvariantError.invalidProducerReceipt
        }
        self.creationID = creationID
        self.missionID = missionID
        self.sourceRevision = sourceRevision
        self.state = state
        self.statusText = statusText
        self.updatedAt = updatedAt
        self.producerReceiptID = producerReceiptID
    }

    private enum CodingKeys: String, CodingKey {
        case creationID, missionID, sourceRevision, state, statusText, updatedAt, producerReceiptID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            creationID: container.decode(ForgeCreationID.self, forKey: .creationID),
            missionID: container.decode(UUID.self, forKey: .missionID),
            sourceRevision: container.decode(String.self, forKey: .sourceRevision),
            state: container.decode(State.self, forKey: .state),
            statusText: container.decode(String.self, forKey: .statusText),
            updatedAt: container.decode(Date.self, forKey: .updatedAt),
            producerReceiptID: container.decode(String.self, forKey: .producerReceiptID)
        )
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

    public let creationID: ForgeCreationID
    public let artifactID: ForgeArtifactID
    public let runtimeKind: RuntimeKind
    public let verificationLevel: VerificationLevel
    public let sourceRevision: String
    public let recordedAt: Date
    public let producerReceiptID: String

    public init(
        creationID: ForgeCreationID,
        artifactID: ForgeArtifactID,
        runtimeKind: RuntimeKind,
        verificationLevel: VerificationLevel,
        sourceRevision: String,
        recordedAt: Date,
        producerReceiptID: String
    ) throws {
        guard artifactID.isCanonical else { throw ForgeHomeInvariantError.invalidArtifactIdentity }
        guard ForgeHomeIdentity.isCanonical(sourceRevision) else {
            throw ForgeHomeInvariantError.invalidSourceRevision
        }
        guard ForgeHomeIdentity.isCanonical(producerReceiptID) else {
            throw ForgeHomeInvariantError.invalidProducerReceipt
        }
        self.creationID = creationID
        self.artifactID = artifactID
        self.runtimeKind = runtimeKind
        self.verificationLevel = verificationLevel
        self.sourceRevision = sourceRevision
        self.recordedAt = recordedAt
        self.producerReceiptID = producerReceiptID
    }

    public var claimsRunnableInsideNovaForge: Bool {
        runtimeKind == .forgeWeb && verificationLevel != .generated
    }

    private enum CodingKeys: String, CodingKey {
        case creationID, artifactID, runtimeKind, verificationLevel, sourceRevision, recordedAt, producerReceiptID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            creationID: container.decode(ForgeCreationID.self, forKey: .creationID),
            artifactID: container.decode(ForgeArtifactID.self, forKey: .artifactID),
            runtimeKind: container.decode(RuntimeKind.self, forKey: .runtimeKind),
            verificationLevel: container.decode(VerificationLevel.self, forKey: .verificationLevel),
            sourceRevision: container.decode(String.self, forKey: .sourceRevision),
            recordedAt: container.decode(Date.self, forKey: .recordedAt),
            producerReceiptID: container.decode(String.self, forKey: .producerReceiptID)
        )
    }
}

public struct ForgeThumbnailEvidence: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case runtimeScreenshot
        case importedReference
    }

    public let creationID: ForgeCreationID
    public let artifactID: ForgeArtifactID
    public let artifactSHA256: String
    public let kind: Kind
    public let sourceRevision: String
    public let recordedAt: Date
    public let producerReceiptID: String

    public init(
        creationID: ForgeCreationID,
        artifactID: ForgeArtifactID,
        artifactSHA256: String,
        kind: Kind,
        sourceRevision: String,
        recordedAt: Date,
        producerReceiptID: String
    ) throws {
        guard artifactID.isCanonical else { throw ForgeHomeInvariantError.invalidArtifactIdentity }
        guard ForgeHomeIdentity.isCanonicalSHA256(artifactSHA256) else {
            throw ForgeHomeInvariantError.invalidArtifactDigest
        }
        guard ForgeHomeIdentity.isCanonical(sourceRevision) else {
            throw ForgeHomeInvariantError.invalidSourceRevision
        }
        guard ForgeHomeIdentity.isCanonical(producerReceiptID) else {
            throw ForgeHomeInvariantError.invalidProducerReceipt
        }
        self.creationID = creationID
        self.artifactID = artifactID
        self.artifactSHA256 = artifactSHA256
        self.kind = kind
        self.sourceRevision = sourceRevision
        self.recordedAt = recordedAt
        self.producerReceiptID = producerReceiptID
    }

    public var claimsActualRuntimePreview: Bool { kind == .runtimeScreenshot }

    private enum CodingKeys: String, CodingKey {
        case creationID, artifactID, artifactSHA256, kind, sourceRevision, recordedAt, producerReceiptID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            creationID: container.decode(ForgeCreationID.self, forKey: .creationID),
            artifactID: container.decode(ForgeArtifactID.self, forKey: .artifactID),
            artifactSHA256: container.decode(String.self, forKey: .artifactSHA256),
            kind: container.decode(Kind.self, forKey: .kind),
            sourceRevision: container.decode(String.self, forKey: .sourceRevision),
            recordedAt: container.decode(Date.self, forKey: .recordedAt),
            producerReceiptID: container.decode(String.self, forKey: .producerReceiptID)
        )
    }
}

public enum ForgeCreationCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case edit
    case duplicate
    case remix
    case export
    case share
}

public struct ForgeCapabilityClaim: Codable, Hashable, Sendable {
    public let creationID: ForgeCreationID
    public let sourceRevision: String
    public let capabilities: [ForgeCreationCapability]
    public let producerReceiptID: String

    public init(
        creationID: ForgeCreationID,
        sourceRevision: String,
        capabilities: [ForgeCreationCapability],
        producerReceiptID: String
    ) throws {
        guard ForgeHomeIdentity.isCanonical(sourceRevision) else {
            throw ForgeHomeInvariantError.invalidSourceRevision
        }
        guard ForgeHomeIdentity.isCanonical(producerReceiptID) else {
            throw ForgeHomeInvariantError.invalidProducerReceipt
        }
        guard Set(capabilities).count == capabilities.count else {
            throw ForgeHomeInvariantError.duplicateCapability
        }
        self.creationID = creationID
        self.sourceRevision = sourceRevision
        self.capabilities = capabilities
        self.producerReceiptID = producerReceiptID
    }

    private enum CodingKeys: String, CodingKey {
        case creationID, sourceRevision, capabilities, producerReceiptID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            creationID: container.decode(ForgeCreationID.self, forKey: .creationID),
            sourceRevision: container.decode(String.self, forKey: .sourceRevision),
            capabilities: container.decode([ForgeCreationCapability].self, forKey: .capabilities),
            producerReceiptID: container.decode(String.self, forKey: .producerReceiptID)
        )
    }
}

/// Host-authenticated mission reference. Deliberately non-Codable; persisted/model-authored
/// candidate metadata cannot restore its own authority after relaunch.
public struct ForgeTrustedMissionReference: Equatable, Hashable, Sendable {
    public let candidate: ForgeMissionReference

    init(authenticatedCandidate: ForgeMissionReference) {
        self.candidate = authenticatedCandidate
    }
}

/// Host-authenticated runtime evidence. Deliberately non-Codable and module-constructed.
public struct ForgeTrustedRuntimeEvidence: Equatable, Hashable, Sendable {
    public let candidate: ForgeRuntimeEvidence

    init(authenticatedCandidate: ForgeRuntimeEvidence) throws {
        guard authenticatedCandidate.claimsRunnableInsideNovaForge else {
            throw ForgeHomeInvariantError.runtimeEvidenceCannotBeTrusted
        }
        self.candidate = authenticatedCandidate
    }
}

/// Host-authenticated runtime screenshot evidence. Deliberately non-Codable and module-constructed.
public struct ForgeTrustedThumbnailEvidence: Equatable, Hashable, Sendable {
    public let candidate: ForgeThumbnailEvidence

    init(authenticatedCandidate: ForgeThumbnailEvidence) throws {
        guard authenticatedCandidate.claimsActualRuntimePreview else {
            throw ForgeHomeInvariantError.thumbnailEvidenceCannotBeTrusted
        }
        self.candidate = authenticatedCandidate
    }
}

/// Host-authenticated action capabilities. Deliberately non-Codable and module-constructed.
public struct ForgeTrustedCapabilityClaim: Equatable, Hashable, Sendable {
    public let candidate: ForgeCapabilityClaim

    init(authenticatedCandidate: ForgeCapabilityClaim) {
        self.candidate = authenticatedCandidate
    }
}

public struct ForgeHomeProjectionInput: Sendable {
    public let record: ForgeCreationRecord
    public let activeMission: ForgeTrustedMissionReference?
    public let runtimeEvidence: ForgeTrustedRuntimeEvidence?
    public let thumbnailEvidence: ForgeTrustedThumbnailEvidence?
    public let capabilityClaim: ForgeTrustedCapabilityClaim?

    public init(
        record: ForgeCreationRecord,
        activeMission: ForgeTrustedMissionReference? = nil,
        runtimeEvidence: ForgeTrustedRuntimeEvidence? = nil,
        thumbnailEvidence: ForgeTrustedThumbnailEvidence? = nil,
        capabilityClaim: ForgeTrustedCapabilityClaim? = nil
    ) {
        self.record = record
        self.activeMission = activeMission
        self.runtimeEvidence = runtimeEvidence
        self.thumbnailEvidence = thumbnailEvidence
        self.capabilityClaim = capabilityClaim
    }
}

public enum ForgeCreationAction: String, CaseIterable, Hashable, Sendable {
    case run
    case edit
    case duplicate
    case remix
    case export
    case share
    case details
}

public enum ForgeCreationRunState: Equatable, Sendable {
    case unavailable
    case available(ForgeTrustedRuntimeEvidence)

    public var isRunnable: Bool {
        if case .available = self { return true }
        return false
    }
}

public struct ForgeCreationCard: Equatable, Sendable, Identifiable {
    public let id: ForgeCreationID
    public let name: String
    public let lastChangedAt: Date
    public let activeMission: ForgeTrustedMissionReference?
    public let runState: ForgeCreationRunState
    public let actualThumbnail: ForgeTrustedThumbnailEvidence?
    public let actions: [ForgeCreationAction]

    public init(
        id: ForgeCreationID,
        name: String,
        lastChangedAt: Date,
        activeMission: ForgeTrustedMissionReference?,
        runState: ForgeCreationRunState,
        actualThumbnail: ForgeTrustedThumbnailEvidence?,
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

public struct ForgeHomeSnapshot: Equatable, Sendable {
    public static let creationPrompt = "What do you want to make?"

    public let cards: [ForgeCreationCard]

    public init(cards: [ForgeCreationCard]) {
        self.cards = cards
    }
}

public enum ForgeHomeProjector {
    public static func project(_ records: [ForgeCreationRecord]) -> ForgeHomeSnapshot {
        project(records.map { ForgeHomeProjectionInput(record: $0) })
    }

    public static func project(_ inputs: [ForgeHomeProjectionInput]) -> ForgeHomeSnapshot {
        let cards = inputs.map(makeCard).sorted(by: cardComesBefore)
        return ForgeHomeSnapshot(cards: cards)
    }

    public static func makeCard(_ record: ForgeCreationRecord) -> ForgeCreationCard {
        makeCard(ForgeHomeProjectionInput(record: record))
    }

    public static func makeCard(_ input: ForgeHomeProjectionInput) -> ForgeCreationCard {
        let record = input.record
        guard let currentRevision = record.currentSourceRevision else {
            return baseCard(record: record)
        }

        let mission = input.activeMission.flatMap { trusted in
            exactMatch(
                creationID: trusted.candidate.creationID,
                sourceRevision: trusted.candidate.sourceRevision,
                record: record,
                currentRevision: currentRevision
            ) ? trusted : nil
        }

        let runtime = input.runtimeEvidence.flatMap { trusted in
            exactMatch(
                creationID: trusted.candidate.creationID,
                sourceRevision: trusted.candidate.sourceRevision,
                record: record,
                currentRevision: currentRevision
            ) ? trusted : nil
        }

        let thumbnail: ForgeTrustedThumbnailEvidence?
        if let trusted = input.thumbnailEvidence,
           runtime != nil,
           exactMatch(
               creationID: trusted.candidate.creationID,
               sourceRevision: trusted.candidate.sourceRevision,
               record: record,
               currentRevision: currentRevision
           ) {
            thumbnail = trusted
        } else {
            thumbnail = nil
        }

        let capabilities = input.capabilityClaim.flatMap { trusted in
            exactMatch(
                creationID: trusted.candidate.creationID,
                sourceRevision: trusted.candidate.sourceRevision,
                record: record,
                currentRevision: currentRevision
            ) ? trusted.candidate.capabilities : nil
        } ?? []

        var actions: [ForgeCreationAction] = []
        if runtime != nil { actions.append(.run) }
        let capabilitySet = Set(capabilities)
        if capabilitySet.contains(.edit) { actions.append(.edit) }
        if capabilitySet.contains(.duplicate) { actions.append(.duplicate) }
        if capabilitySet.contains(.remix) { actions.append(.remix) }
        if capabilitySet.contains(.export) { actions.append(.export) }
        if capabilitySet.contains(.share) { actions.append(.share) }
        actions.append(.details)

        return ForgeCreationCard(
            id: record.id,
            name: normalizedProjectName(record.name),
            lastChangedAt: record.lastChangedAt,
            activeMission: mission,
            runState: runtime.map(ForgeCreationRunState.available) ?? .unavailable,
            actualThumbnail: thumbnail,
            actions: actions
        )
    }

    private static func exactMatch(
        creationID: ForgeCreationID,
        sourceRevision: String,
        record: ForgeCreationRecord,
        currentRevision: String
    ) -> Bool {
        creationID == record.id && sourceRevision == currentRevision
    }

    private static func baseCard(record: ForgeCreationRecord) -> ForgeCreationCard {
        ForgeCreationCard(
            id: record.id,
            name: normalizedProjectName(record.name),
            lastChangedAt: record.lastChangedAt,
            activeMission: nil,
            runState: .unavailable,
            actualThumbnail: nil,
            actions: [.details]
        )
    }

    private static func cardComesBefore(_ lhs: ForgeCreationCard, _ rhs: ForgeCreationCard) -> Bool {
        let lhsHasMission = lhs.activeMission != nil
        let rhsHasMission = rhs.activeMission != nil
        if lhsHasMission != rhsHasMission { return lhsHasMission }

        let lhsMissionDate = lhs.activeMission?.candidate.updatedAt
        let rhsMissionDate = rhs.activeMission?.candidate.updatedAt
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

    public var isReadyToPlan: Bool { !normalizedText.isEmpty }
}
