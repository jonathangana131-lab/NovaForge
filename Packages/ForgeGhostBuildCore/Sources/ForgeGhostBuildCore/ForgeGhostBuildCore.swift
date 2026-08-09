import Foundation

public enum ForgeGhostBuildError: Error, Equatable, Sendable {
    case invalidIdentifier(field: String)
    case invalidProjectStateID
    case invalidOrdinal
    case invalidTitle
    case invalidCandidateShape
    case candidateStateMatchesSource
    case duplicateArtifactReference(String)
    case duplicateEvidenceReceipt(String)
    case projectMismatch(candidateID: String, expectedProjectID: String, actualProjectID: String)
    case sourceCheckpointMismatch(candidateID: String, expectedCheckpointID: String, actualCheckpointID: String)
    case sourceStateMismatch(candidateID: String)
    case duplicateCandidateID(String)
    case duplicateOrdinal(UInt32)
    case unknownCandidate(String)
    case identicalComparisonEndpoints(String)
    case candidateNotReady(String)
    case ordinalOverflow
}

public protocol ForgeGhostBuildIdentifierTag: Sendable {}

/// Strong opaque identity copied from an upstream authority. Unlike user-facing text, identity
/// values are never silently trimmed because doing so could alias two externally-authored IDs.
public struct ForgeGhostBuildIdentifier<Tag: ForgeGhostBuildIdentifierTag>:
    Codable,
    Hashable,
    Sendable,
    CustomStringConvertible
{
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard Self.isCanonical(rawValue) else {
            throw ForgeGhostBuildError.invalidIdentifier(field: String(describing: Tag.self))
        }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    private static func isCanonical(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty
            && value == trimmed
            && value.utf8.count <= 512
            && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum ForgeGhostBuildSessionIDTag: ForgeGhostBuildIdentifierTag {}
public enum ForgeGhostBuildCandidateIDTag: ForgeGhostBuildIdentifierTag {}
public enum ForgeGhostBuildProjectIDTag: ForgeGhostBuildIdentifierTag {}
public enum ForgeGhostBuildCheckpointIDTag: ForgeGhostBuildIdentifierTag {}
public enum ForgeGhostBuildArtifactIDTag: ForgeGhostBuildIdentifierTag {}
public enum ForgeGhostBuildReceiptIDTag: ForgeGhostBuildIdentifierTag {}

public typealias ForgeGhostBuildSessionID = ForgeGhostBuildIdentifier<ForgeGhostBuildSessionIDTag>
public typealias ForgeGhostBuildCandidateID = ForgeGhostBuildIdentifier<ForgeGhostBuildCandidateIDTag>
public typealias ForgeGhostBuildProjectID = ForgeGhostBuildIdentifier<ForgeGhostBuildProjectIDTag>
public typealias ForgeGhostBuildCheckpointID = ForgeGhostBuildIdentifier<ForgeGhostBuildCheckpointIDTag>
public typealias ForgeGhostBuildArtifactID = ForgeGhostBuildIdentifier<ForgeGhostBuildArtifactIDTag>
public typealias ForgeGhostBuildReceiptID = ForgeGhostBuildIdentifier<ForgeGhostBuildReceiptIDTag>

/// Opaque accepted/candidate project-state identity supplied by ProjectStore/Mission authority.
/// Interior punctuation and spaces remain legal; boundary whitespace/control characters do not.
public struct ForgeGhostBuildProjectStateID: Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawValue.isEmpty,
              rawValue == trimmed,
              rawValue.utf8.count <= 2_048,
              !rawValue.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            throw ForgeGhostBuildError.invalidProjectStateID
        }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum ForgeGhostBuildArtifactKind: String, CaseIterable, Codable, Hashable, Sendable {
    case screenshot
    case runtimeCapture
    case sourceSnapshot
    case sourceDiff
    case other
}

public struct ForgeGhostBuildArtifactReference: Codable, Hashable, Sendable {
    public let kind: ForgeGhostBuildArtifactKind
    public let id: ForgeGhostBuildArtifactID

    public init(kind: ForgeGhostBuildArtifactKind, id: ForgeGhostBuildArtifactID) {
        self.kind = kind
        self.id = id
    }

    fileprivate var stableSortKey: String { "\(kind.rawValue)|\(id.rawValue)" }
}

public enum ForgeGhostBuildCandidateStatus: String, CaseIterable, Codable, Hashable, Sendable {
    case previewReady
    case failed
}

/// A settled isolated alternative. This is a projection of candidate truth, not an executor and
/// not an accepted project checkpoint. Ready candidates require an upstream materialization receipt.
public struct ForgeGhostBuildCandidate: Codable, Hashable, Sendable {
    public let id: ForgeGhostBuildCandidateID
    public let projectID: ForgeGhostBuildProjectID
    public let sourceCheckpointID: ForgeGhostBuildCheckpointID
    public let sourceProjectStateID: ForgeGhostBuildProjectStateID
    public let ordinal: UInt32
    public let title: String
    public let summary: String?
    public let status: ForgeGhostBuildCandidateStatus
    public let candidateProjectStateID: ForgeGhostBuildProjectStateID?
    public let materializationReceiptID: ForgeGhostBuildReceiptID?
    public let previewArtifacts: [ForgeGhostBuildArtifactReference]
    public let evidenceReceiptIDs: [ForgeGhostBuildReceiptID]
    public let failureReason: String?
    public let knownLimitations: [String]

    public init(
        id: ForgeGhostBuildCandidateID,
        projectID: ForgeGhostBuildProjectID,
        sourceCheckpointID: ForgeGhostBuildCheckpointID,
        sourceProjectStateID: ForgeGhostBuildProjectStateID,
        ordinal: UInt32,
        title: String,
        summary: String? = nil,
        status: ForgeGhostBuildCandidateStatus,
        candidateProjectStateID: ForgeGhostBuildProjectStateID? = nil,
        materializationReceiptID: ForgeGhostBuildReceiptID? = nil,
        previewArtifacts: [ForgeGhostBuildArtifactReference] = [],
        evidenceReceiptIDs: [ForgeGhostBuildReceiptID] = [],
        failureReason: String? = nil,
        knownLimitations: [String] = []
    ) throws {
        guard ordinal > 0 else { throw ForgeGhostBuildError.invalidOrdinal }
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else { throw ForgeGhostBuildError.invalidTitle }

        var seenArtifacts = Set<ForgeGhostBuildArtifactID>()
        for artifact in previewArtifacts where !seenArtifacts.insert(artifact.id).inserted {
            throw ForgeGhostBuildError.duplicateArtifactReference(artifact.id.rawValue)
        }
        var seenReceipts = Set<ForgeGhostBuildReceiptID>()
        for receipt in evidenceReceiptIDs where !seenReceipts.insert(receipt).inserted {
            throw ForgeGhostBuildError.duplicateEvidenceReceipt(receipt.rawValue)
        }

        let normalizedFailure = Self.normalizedOptional(failureReason)
        switch status {
        case .previewReady:
            guard let candidateProjectStateID, materializationReceiptID != nil, normalizedFailure == nil else {
                throw ForgeGhostBuildError.invalidCandidateShape
            }
            guard candidateProjectStateID != sourceProjectStateID else {
                throw ForgeGhostBuildError.candidateStateMatchesSource
            }
        case .failed:
            guard candidateProjectStateID == nil,
                  materializationReceiptID == nil,
                  previewArtifacts.isEmpty,
                  normalizedFailure != nil else {
                throw ForgeGhostBuildError.invalidCandidateShape
            }
        }

        self.id = id
        self.projectID = projectID
        self.sourceCheckpointID = sourceCheckpointID
        self.sourceProjectStateID = sourceProjectStateID
        self.ordinal = ordinal
        self.title = normalizedTitle
        self.summary = Self.normalizedOptional(summary)
        self.status = status
        self.candidateProjectStateID = candidateProjectStateID
        self.materializationReceiptID = materializationReceiptID
        self.previewArtifacts = previewArtifacts.sorted { $0.stableSortKey < $1.stableSortKey }
        self.evidenceReceiptIDs = evidenceReceiptIDs.sorted { $0.rawValue < $1.rawValue }
        self.failureReason = normalizedFailure
        self.knownLimitations = Self.normalizedUniqueStrings(knownLimitations)
    }

    public var screenshotReferences: [ForgeGhostBuildArtifactReference] {
        previewArtifacts.filter { $0.kind == .screenshot }
    }

    private enum CodingKeys: String, CodingKey {
        case id, projectID, sourceCheckpointID, sourceProjectStateID, ordinal, title, summary, status
        case candidateProjectStateID, materializationReceiptID, previewArtifacts, evidenceReceiptIDs
        case failureReason, knownLimitations
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: c.decode(ForgeGhostBuildCandidateID.self, forKey: .id),
            projectID: c.decode(ForgeGhostBuildProjectID.self, forKey: .projectID),
            sourceCheckpointID: c.decode(ForgeGhostBuildCheckpointID.self, forKey: .sourceCheckpointID),
            sourceProjectStateID: c.decode(ForgeGhostBuildProjectStateID.self, forKey: .sourceProjectStateID),
            ordinal: c.decode(UInt32.self, forKey: .ordinal),
            title: c.decode(String.self, forKey: .title),
            summary: c.decodeIfPresent(String.self, forKey: .summary),
            status: c.decode(ForgeGhostBuildCandidateStatus.self, forKey: .status),
            candidateProjectStateID: c.decodeIfPresent(ForgeGhostBuildProjectStateID.self, forKey: .candidateProjectStateID),
            materializationReceiptID: c.decodeIfPresent(ForgeGhostBuildReceiptID.self, forKey: .materializationReceiptID),
            previewArtifacts: c.decode([ForgeGhostBuildArtifactReference].self, forKey: .previewArtifacts),
            evidenceReceiptIDs: c.decode([ForgeGhostBuildReceiptID].self, forKey: .evidenceReceiptIDs),
            failureReason: c.decodeIfPresent(String.self, forKey: .failureReason),
            knownLimitations: c.decode([String].self, forKey: .knownLimitations)
        )
    }

    private static func normalizedOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private static func normalizedUniqueStrings(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { return nil }
            return normalized
        }.sorted()
    }
}

/// Durable truth for one Ghost Build exploration rooted in exactly one accepted project state.
/// It can outlive a model conversation but cannot itself promote a candidate into accepted state.
public struct ForgeGhostBuildSession: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let id: ForgeGhostBuildSessionID
    public let projectID: ForgeGhostBuildProjectID
    public let sourceCheckpointID: ForgeGhostBuildCheckpointID
    public let sourceProjectStateID: ForgeGhostBuildProjectStateID
    public let createdAtMilliseconds: Int64
    public let candidates: [ForgeGhostBuildCandidate]

    public init(
        id: ForgeGhostBuildSessionID,
        projectID: ForgeGhostBuildProjectID,
        sourceCheckpointID: ForgeGhostBuildCheckpointID,
        sourceProjectStateID: ForgeGhostBuildProjectStateID,
        createdAtMilliseconds: Int64,
        candidates: [ForgeGhostBuildCandidate] = []
    ) throws {
        var seenIDs = Set<ForgeGhostBuildCandidateID>()
        var seenOrdinals = Set<UInt32>()
        for candidate in candidates {
            guard candidate.projectID == projectID else {
                throw ForgeGhostBuildError.projectMismatch(
                    candidateID: candidate.id.rawValue,
                    expectedProjectID: projectID.rawValue,
                    actualProjectID: candidate.projectID.rawValue
                )
            }
            guard candidate.sourceCheckpointID == sourceCheckpointID else {
                throw ForgeGhostBuildError.sourceCheckpointMismatch(
                    candidateID: candidate.id.rawValue,
                    expectedCheckpointID: sourceCheckpointID.rawValue,
                    actualCheckpointID: candidate.sourceCheckpointID.rawValue
                )
            }
            guard candidate.sourceProjectStateID == sourceProjectStateID else {
                throw ForgeGhostBuildError.sourceStateMismatch(candidateID: candidate.id.rawValue)
            }
            guard seenIDs.insert(candidate.id).inserted else {
                throw ForgeGhostBuildError.duplicateCandidateID(candidate.id.rawValue)
            }
            guard seenOrdinals.insert(candidate.ordinal).inserted else {
                throw ForgeGhostBuildError.duplicateOrdinal(candidate.ordinal)
            }
        }

        schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.projectID = projectID
        self.sourceCheckpointID = sourceCheckpointID
        self.sourceProjectStateID = sourceProjectStateID
        self.createdAtMilliseconds = createdAtMilliseconds
        self.candidates = candidates.sorted {
            if $0.ordinal != $1.ordinal { return $0.ordinal < $1.ordinal }
            return $0.id.rawValue < $1.id.rawValue
        }
    }

    public var readyCandidates: [ForgeGhostBuildCandidate] {
        candidates.filter { $0.status == .previewReady }
    }

    public func candidate(id: ForgeGhostBuildCandidateID) -> ForgeGhostBuildCandidate? {
        candidates.first(where: { $0.id == id })
    }

    public func tryAnotherIdeaIntent() throws -> ForgeGhostBuildTryAnotherIdeaIntent {
        let maximum = candidates.map(\.ordinal).max() ?? 0
        guard maximum < UInt32.max else { throw ForgeGhostBuildError.ordinalOverflow }
        return ForgeGhostBuildTryAnotherIdeaIntent(
            sessionID: id,
            projectID: projectID,
            sourceCheckpointID: sourceCheckpointID,
            sourceProjectStateID: sourceProjectStateID,
            requestedOrdinal: maximum + 1
        )
    }

    public func previewIntent(candidateID: ForgeGhostBuildCandidateID) throws -> ForgeGhostBuildPreviewIntent {
        let candidate = try requireReadyCandidate(candidateID)
        return ForgeGhostBuildPreviewIntent(
            sessionID: id,
            projectID: projectID,
            candidateID: candidate.id,
            candidateProjectStateID: candidate.candidateProjectStateID!,
            materializationReceiptID: candidate.materializationReceiptID!
        )
    }

    public func promotionIntent(candidateID: ForgeGhostBuildCandidateID) throws -> ForgeGhostBuildPromotionIntent {
        let candidate = try requireReadyCandidate(candidateID)
        return ForgeGhostBuildPromotionIntent(
            sessionID: id,
            projectID: projectID,
            sourceCheckpointID: sourceCheckpointID,
            sourceProjectStateID: sourceProjectStateID,
            candidateID: candidate.id,
            candidateProjectStateID: candidate.candidateProjectStateID!,
            materializationReceiptID: candidate.materializationReceiptID!,
            evidenceReceiptIDs: candidate.evidenceReceiptIDs
        )
    }

    public func discardIntent(candidateID: ForgeGhostBuildCandidateID) throws -> ForgeGhostBuildDiscardIntent {
        guard candidate(id: candidateID) != nil else {
            throw ForgeGhostBuildError.unknownCandidate(candidateID.rawValue)
        }
        return ForgeGhostBuildDiscardIntent(sessionID: id, projectID: projectID, candidateID: candidateID)
    }

    public func comparison(
        from leftID: ForgeGhostBuildCandidateID,
        to rightID: ForgeGhostBuildCandidateID
    ) throws -> ForgeGhostBuildComparison {
        guard leftID != rightID else {
            throw ForgeGhostBuildError.identicalComparisonEndpoints(leftID.rawValue)
        }
        let left = try requireReadyCandidate(leftID)
        let right = try requireReadyCandidate(rightID)
        return ForgeGhostBuildComparison(
            projectID: projectID,
            sourceCheckpointID: sourceCheckpointID,
            sourceProjectStateID: sourceProjectStateID,
            leftCandidateID: left.id,
            rightCandidateID: right.id,
            leftProjectStateID: left.candidateProjectStateID!,
            rightProjectStateID: right.candidateProjectStateID!,
            leftScreenshots: left.screenshotReferences,
            rightScreenshots: right.screenshotReferences,
            leftLimitations: left.knownLimitations,
            rightLimitations: right.knownLimitations
        )
    }

    private func requireReadyCandidate(_ candidateID: ForgeGhostBuildCandidateID) throws -> ForgeGhostBuildCandidate {
        guard let candidate = candidate(id: candidateID) else {
            throw ForgeGhostBuildError.unknownCandidate(candidateID.rawValue)
        }
        guard candidate.status == .previewReady,
              candidate.candidateProjectStateID != nil,
              candidate.materializationReceiptID != nil else {
            throw ForgeGhostBuildError.candidateNotReady(candidateID.rawValue)
        }
        return candidate
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, projectID, sourceCheckpointID, sourceProjectStateID
        case createdAtMilliseconds, candidates
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: c,
                debugDescription: "Unsupported Forge Ghost Build schema version \(version)."
            )
        }
        try self.init(
            id: c.decode(ForgeGhostBuildSessionID.self, forKey: .id),
            projectID: c.decode(ForgeGhostBuildProjectID.self, forKey: .projectID),
            sourceCheckpointID: c.decode(ForgeGhostBuildCheckpointID.self, forKey: .sourceCheckpointID),
            sourceProjectStateID: c.decode(ForgeGhostBuildProjectStateID.self, forKey: .sourceProjectStateID),
            createdAtMilliseconds: c.decode(Int64.self, forKey: .createdAtMilliseconds),
            candidates: c.decode([ForgeGhostBuildCandidate].self, forKey: .candidates)
        )
    }
}

/// These values are requests only. Their initializers are intentionally internal and none of the
/// action intents conform to Codable, so persisted bytes cannot independently mint mutation authority.
public struct ForgeGhostBuildTryAnotherIdeaIntent: Hashable, Sendable {
    public let sessionID: ForgeGhostBuildSessionID
    public let projectID: ForgeGhostBuildProjectID
    public let sourceCheckpointID: ForgeGhostBuildCheckpointID
    public let sourceProjectStateID: ForgeGhostBuildProjectStateID
    public let requestedOrdinal: UInt32

    fileprivate init(
        sessionID: ForgeGhostBuildSessionID,
        projectID: ForgeGhostBuildProjectID,
        sourceCheckpointID: ForgeGhostBuildCheckpointID,
        sourceProjectStateID: ForgeGhostBuildProjectStateID,
        requestedOrdinal: UInt32
    ) {
        self.sessionID = sessionID
        self.projectID = projectID
        self.sourceCheckpointID = sourceCheckpointID
        self.sourceProjectStateID = sourceProjectStateID
        self.requestedOrdinal = requestedOrdinal
    }
}

public struct ForgeGhostBuildPreviewIntent: Hashable, Sendable {
    public let sessionID: ForgeGhostBuildSessionID
    public let projectID: ForgeGhostBuildProjectID
    public let candidateID: ForgeGhostBuildCandidateID
    public let candidateProjectStateID: ForgeGhostBuildProjectStateID
    public let materializationReceiptID: ForgeGhostBuildReceiptID

    fileprivate init(
        sessionID: ForgeGhostBuildSessionID,
        projectID: ForgeGhostBuildProjectID,
        candidateID: ForgeGhostBuildCandidateID,
        candidateProjectStateID: ForgeGhostBuildProjectStateID,
        materializationReceiptID: ForgeGhostBuildReceiptID
    ) {
        self.sessionID = sessionID
        self.projectID = projectID
        self.candidateID = candidateID
        self.candidateProjectStateID = candidateProjectStateID
        self.materializationReceiptID = materializationReceiptID
    }
}

public struct ForgeGhostBuildPromotionIntent: Hashable, Sendable {
    public let sessionID: ForgeGhostBuildSessionID
    public let projectID: ForgeGhostBuildProjectID
    public let sourceCheckpointID: ForgeGhostBuildCheckpointID
    public let sourceProjectStateID: ForgeGhostBuildProjectStateID
    public let candidateID: ForgeGhostBuildCandidateID
    public let candidateProjectStateID: ForgeGhostBuildProjectStateID
    public let materializationReceiptID: ForgeGhostBuildReceiptID
    public let evidenceReceiptIDs: [ForgeGhostBuildReceiptID]

    fileprivate init(
        sessionID: ForgeGhostBuildSessionID,
        projectID: ForgeGhostBuildProjectID,
        sourceCheckpointID: ForgeGhostBuildCheckpointID,
        sourceProjectStateID: ForgeGhostBuildProjectStateID,
        candidateID: ForgeGhostBuildCandidateID,
        candidateProjectStateID: ForgeGhostBuildProjectStateID,
        materializationReceiptID: ForgeGhostBuildReceiptID,
        evidenceReceiptIDs: [ForgeGhostBuildReceiptID]
    ) {
        self.sessionID = sessionID
        self.projectID = projectID
        self.sourceCheckpointID = sourceCheckpointID
        self.sourceProjectStateID = sourceProjectStateID
        self.candidateID = candidateID
        self.candidateProjectStateID = candidateProjectStateID
        self.materializationReceiptID = materializationReceiptID
        self.evidenceReceiptIDs = evidenceReceiptIDs
    }
}

public struct ForgeGhostBuildDiscardIntent: Hashable, Sendable {
    public let sessionID: ForgeGhostBuildSessionID
    public let projectID: ForgeGhostBuildProjectID
    public let candidateID: ForgeGhostBuildCandidateID

    fileprivate init(
        sessionID: ForgeGhostBuildSessionID,
        projectID: ForgeGhostBuildProjectID,
        candidateID: ForgeGhostBuildCandidateID
    ) {
        self.sessionID = sessionID
        self.projectID = projectID
        self.candidateID = candidateID
    }
}

public struct ForgeGhostBuildComparison: Hashable, Sendable {
    public let projectID: ForgeGhostBuildProjectID
    public let sourceCheckpointID: ForgeGhostBuildCheckpointID
    public let sourceProjectStateID: ForgeGhostBuildProjectStateID
    public let leftCandidateID: ForgeGhostBuildCandidateID
    public let rightCandidateID: ForgeGhostBuildCandidateID
    public let leftProjectStateID: ForgeGhostBuildProjectStateID
    public let rightProjectStateID: ForgeGhostBuildProjectStateID
    public let leftScreenshots: [ForgeGhostBuildArtifactReference]
    public let rightScreenshots: [ForgeGhostBuildArtifactReference]
    public let leftLimitations: [String]
    public let rightLimitations: [String]

    public var hasVisualPair: Bool {
        !leftScreenshots.isEmpty && !rightScreenshots.isEmpty
    }
}
