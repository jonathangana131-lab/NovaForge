import Foundation

public enum ForgeHistoryError: Error, Equatable, Sendable {
    case invalidIdentifier(String)
    case emptyTitle
    case duplicateCheckpointID(String)
    case duplicateSequence(UInt64)
    case duplicateArtifactReference(String)
    case evidenceArtifactNotAttached(String)
    case unprovenEvidence(ForgeHistoryEvidenceKind)
    case missingParent(checkpointID: String, parentID: String)
    case parentNotEarlier(checkpointID: String, parentID: String)
    case timestampPrecedesParent(checkpointID: String, parentID: String)
    case unknownCheckpoint(String)
    case identicalComparisonEndpoints(String)
    case invalidEvidenceEnvironment(kind: ForgeHistoryEvidenceKind, environment: ForgeHistoryEvidenceEnvironment)
    case environmentVerificationRequiresReceipt(ForgeHistoryEvidenceKind)
}

public protocol ForgeHistoryIdentifierTag: Sendable {}

/// Strong, opaque identity copied from an authoritative upstream store. History can bind to the
/// identity but cannot reinterpret it as a Mission Engine, provider-route, or filesystem value.
public struct ForgeHistoryIdentifier<Tag: ForgeHistoryIdentifierTag>:
    Codable,
    Hashable,
    Sendable,
    CustomStringConvertible
{
    public let rawValue: String

    public init(rawValue: String) throws {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValid(normalized) else {
            throw ForgeHistoryError.invalidIdentifier(rawValue)
        }
        self.rawValue = normalized
    }

    public init(_ rawValue: String) throws {
        try self.init(rawValue: rawValue)
    }

    public var description: String { rawValue }

    private static func isValid(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 160 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 45, 46, 48...57, 58, 65...90, 95, 97...122:
                true
            default:
                false
            }
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(rawValue: container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum ForgeHistoryProjectIDTag: ForgeHistoryIdentifierTag {}
public enum ForgeHistoryMissionIDTag: ForgeHistoryIdentifierTag {}
public enum ForgeHistoryCheckpointIDTag: ForgeHistoryIdentifierTag {}
public enum ForgeHistoryArtifactIDTag: ForgeHistoryIdentifierTag {}
public enum ForgeHistoryReceiptIDTag: ForgeHistoryIdentifierTag {}

public typealias ForgeHistoryProjectID = ForgeHistoryIdentifier<ForgeHistoryProjectIDTag>
public typealias ForgeHistoryMissionID = ForgeHistoryIdentifier<ForgeHistoryMissionIDTag>
public typealias ForgeHistoryCheckpointID = ForgeHistoryIdentifier<ForgeHistoryCheckpointIDTag>
public typealias ForgeHistoryArtifactID = ForgeHistoryIdentifier<ForgeHistoryArtifactIDTag>
public typealias ForgeHistoryReceiptID = ForgeHistoryIdentifier<ForgeHistoryReceiptIDTag>

public enum ForgeHistoryArtifactKind: String, CaseIterable, Codable, Hashable, Sendable {
    case sourceSnapshot
    case sourceDiff
    case screenshot
    case runtimeCapture
    case testReport
    case performanceReport
    case other
}

/// Reference to durable evidence owned elsewhere. The History domain stores only a typed opaque
/// reference, never raw credentials, terminal output, or a guessed filesystem location.
public struct ForgeHistoryArtifactReference: Codable, Hashable, Sendable {
    public let kind: ForgeHistoryArtifactKind
    public let id: ForgeHistoryArtifactID

    public init(kind: ForgeHistoryArtifactKind, id: ForgeHistoryArtifactID) {
        self.kind = kind
        self.id = id
    }

    fileprivate var stableSortKey: String { "\(kind.rawValue)|\(id.rawValue)" }
}

/// Evidence is modeled as distinct claims instead of a single confidence ladder. For example,
/// Simulator Verified and Physical Device Verified are different truths, not adjacent marketing
/// badges that History may silently upgrade between.
public enum ForgeHistoryEvidenceKind: String, CaseIterable, Codable, Hashable, Sendable {
    case generated
    case compiled
    case runtimeTested
    case visuallyInspected
    case simulatorVerified
    case physicalDeviceVerified
}

public enum ForgeHistoryEvidenceEnvironment: String, CaseIterable, Codable, Hashable, Sendable {
    case unspecified
    case iPhonePhysical
    case simulator
    case pairedMac
    case cloud
}

public struct ForgeHistoryEvidenceClaim: Codable, Hashable, Sendable {
    public let kind: ForgeHistoryEvidenceKind
    public let environment: ForgeHistoryEvidenceEnvironment
    public let artifact: ForgeHistoryArtifactReference?
    public let receiptReference: ForgeHistoryReceiptID?

    public init(
        kind: ForgeHistoryEvidenceKind,
        environment: ForgeHistoryEvidenceEnvironment = .unspecified,
        artifact: ForgeHistoryArtifactReference? = nil,
        receiptReference: ForgeHistoryReceiptID? = nil
    ) throws {
        switch kind {
        case .physicalDeviceVerified:
            guard environment == .iPhonePhysical else {
                throw ForgeHistoryError.invalidEvidenceEnvironment(kind: kind, environment: environment)
            }
        case .simulatorVerified:
            guard environment == .simulator else {
                throw ForgeHistoryError.invalidEvidenceEnvironment(kind: kind, environment: environment)
            }
        case .generated, .compiled, .runtimeTested, .visuallyInspected:
            break
        }
        self.kind = kind
        self.environment = environment
        self.artifact = artifact
        self.receiptReference = receiptReference
    }

    fileprivate var stableSortKey: String {
        [
            kind.rawValue,
            environment.rawValue,
            artifact?.stableSortKey ?? "",
            receiptReference?.rawValue ?? "",
        ].joined(separator: "|")
    }

    private enum CodingKeys: String, CodingKey {
        case kind, environment, artifact, receiptReference
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            kind: container.decode(ForgeHistoryEvidenceKind.self, forKey: .kind),
            environment: container.decode(ForgeHistoryEvidenceEnvironment.self, forKey: .environment),
            artifact: container.decodeIfPresent(ForgeHistoryArtifactReference.self, forKey: .artifact),
            receiptReference: container.decodeIfPresent(ForgeHistoryReceiptID.self, forKey: .receiptReference)
        )
    }
}

/// Immutable accepted history point. This is a projection contract, not an API for authoring
/// Mission Engine checkpoints. Upstream adapters should construct it only from accepted state.
public struct ForgeHistoryCheckpoint: Codable, Hashable, Sendable {
    public let id: ForgeHistoryCheckpointID
    public let parentID: ForgeHistoryCheckpointID?
    public let sequence: UInt64
    public let acceptedAtMilliseconds: Int64
    public let title: String
    public let summary: String?
    public let acceptedExecutionReceiptReference: ForgeHistoryReceiptID?
    public let artifacts: [ForgeHistoryArtifactReference]
    public let evidence: [ForgeHistoryEvidenceClaim]
    public let knownLimitations: [String]

    public init(
        id: ForgeHistoryCheckpointID,
        parentID: ForgeHistoryCheckpointID? = nil,
        sequence: UInt64,
        acceptedAtMilliseconds: Int64,
        title: String,
        summary: String? = nil,
        acceptedExecutionReceiptReference: ForgeHistoryReceiptID? = nil,
        artifacts: [ForgeHistoryArtifactReference] = [],
        evidence: [ForgeHistoryEvidenceClaim] = [],
        knownLimitations: [String] = []
    ) throws {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else { throw ForgeHistoryError.emptyTitle }

        var seenArtifacts = Set<ForgeHistoryArtifactID>()
        for artifact in artifacts where !seenArtifacts.insert(artifact.id).inserted {
            throw ForgeHistoryError.duplicateArtifactReference(artifact.id.rawValue)
        }

        let artifactSet = Set(artifacts)
        for claim in evidence {
            if let artifact = claim.artifact, !artifactSet.contains(artifact) {
                throw ForgeHistoryError.evidenceArtifactNotAttached(artifact.id.rawValue)
            }

            let hasExecutionReceipt =
                claim.receiptReference != nil || acceptedExecutionReceiptReference != nil
            switch claim.kind {
            case .simulatorVerified, .physicalDeviceVerified:
                guard hasExecutionReceipt else {
                    throw ForgeHistoryError.environmentVerificationRequiresReceipt(claim.kind)
                }
            case .generated, .compiled, .runtimeTested, .visuallyInspected:
                guard claim.artifact != nil || hasExecutionReceipt else {
                    throw ForgeHistoryError.unprovenEvidence(claim.kind)
                }
            }
        }

        self.id = id
        self.parentID = parentID
        self.sequence = sequence
        self.acceptedAtMilliseconds = acceptedAtMilliseconds
        self.title = normalizedTitle
        self.summary = Self.normalizedOptional(summary)
        self.acceptedExecutionReceiptReference = acceptedExecutionReceiptReference
        self.artifacts = artifacts.sorted { $0.stableSortKey < $1.stableSortKey }
        self.evidence = Array(Set(evidence)).sorted { $0.stableSortKey < $1.stableSortKey }
        self.knownLimitations = Self.normalizedUniqueStrings(knownLimitations)
    }

    public func artifactReferences(kind: ForgeHistoryArtifactKind) -> [ForgeHistoryArtifactReference] {
        artifacts.filter { $0.kind == kind }
    }

    public var primaryScreenshotReference: ForgeHistoryArtifactReference? {
        artifactReferences(kind: .screenshot).first
    }

    public var primarySourceSnapshotReference: ForgeHistoryArtifactReference? {
        artifactReferences(kind: .sourceSnapshot).first
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
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, parentID, sequence, acceptedAtMilliseconds, title, summary
        case acceptedExecutionReceiptReference, artifacts, evidence, knownLimitations
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(ForgeHistoryCheckpointID.self, forKey: .id),
            parentID: container.decodeIfPresent(ForgeHistoryCheckpointID.self, forKey: .parentID),
            sequence: container.decode(UInt64.self, forKey: .sequence),
            acceptedAtMilliseconds: container.decode(Int64.self, forKey: .acceptedAtMilliseconds),
            title: container.decode(String.self, forKey: .title),
            summary: container.decodeIfPresent(String.self, forKey: .summary),
            acceptedExecutionReceiptReference: container.decodeIfPresent(ForgeHistoryReceiptID.self, forKey: .acceptedExecutionReceiptReference),
            artifacts: container.decode([ForgeHistoryArtifactReference].self, forKey: .artifacts),
            evidence: container.decode([ForgeHistoryEvidenceClaim].self, forKey: .evidence),
            knownLimitations: container.decode([String].self, forKey: .knownLimitations)
        )
    }
}

public struct ForgeVisualTimeMachineItem: Codable, Hashable, Sendable {
    public let checkpointID: ForgeHistoryCheckpointID
    public let sequence: UInt64
    public let acceptedAtMilliseconds: Int64
    public let title: String
    public let screenshotReferences: [ForgeHistoryArtifactReference]
    public let evidence: [ForgeHistoryEvidenceClaim]

    public var primaryScreenshotReference: ForgeHistoryArtifactReference? {
        screenshotReferences.first
    }
}

/// Comparison exposes only evidence references actually present on the accepted endpoints. Missing
/// screenshots/diffs remain missing rather than being fabricated to satisfy a presentation slot.
public struct ForgeHistoryComparison: Codable, Hashable, Sendable {
    public let fromCheckpointID: ForgeHistoryCheckpointID
    public let toCheckpointID: ForgeHistoryCheckpointID
    public let beforeSourceSnapshots: [ForgeHistoryArtifactReference]
    public let afterSourceSnapshots: [ForgeHistoryArtifactReference]
    public let beforeScreenshots: [ForgeHistoryArtifactReference]
    public let afterScreenshots: [ForgeHistoryArtifactReference]
    public let directRecordedSourceDiff: ForgeHistoryArtifactReference?
    public let addedEvidence: [ForgeHistoryEvidenceClaim]
    public let removedEvidence: [ForgeHistoryEvidenceClaim]
    public let addedLimitations: [String]
    public let resolvedLimitations: [String]

    public var hasSourcePair: Bool {
        !beforeSourceSnapshots.isEmpty && !afterSourceSnapshots.isEmpty
    }

    public var hasVisualPair: Bool {
        !beforeScreenshots.isEmpty && !afterScreenshots.isEmpty
    }
}

/// Human-friendly History actions are exact intents only. Restore/fork execution remains under
/// ProjectStore/Mission policy, approvals, and conflict reconciliation.
public enum ForgeHistoryActionIntent: Codable, Hashable, Sendable {
    case restore(projectID: ForgeHistoryProjectID, checkpointID: ForgeHistoryCheckpointID)
    case fork(projectID: ForgeHistoryProjectID, checkpointID: ForgeHistoryCheckpointID)
    case compare(projectID: ForgeHistoryProjectID, from: ForgeHistoryCheckpointID, to: ForgeHistoryCheckpointID)
}

public struct ForgeHistoryTimeline: Codable, Hashable, Sendable {
    public let projectID: ForgeHistoryProjectID
    public let missionID: ForgeHistoryMissionID?
    public let checkpoints: [ForgeHistoryCheckpoint]

    public init(
        projectID: ForgeHistoryProjectID,
        missionID: ForgeHistoryMissionID? = nil,
        checkpoints: [ForgeHistoryCheckpoint]
    ) throws {
        var checkpointIDs = Set<ForgeHistoryCheckpointID>()
        var sequences = Set<UInt64>()
        for checkpoint in checkpoints {
            guard checkpointIDs.insert(checkpoint.id).inserted else {
                throw ForgeHistoryError.duplicateCheckpointID(checkpoint.id.rawValue)
            }
            guard sequences.insert(checkpoint.sequence).inserted else {
                throw ForgeHistoryError.duplicateSequence(checkpoint.sequence)
            }
        }

        let ordered = checkpoints.sorted { lhs, rhs in
            if lhs.sequence != rhs.sequence { return lhs.sequence < rhs.sequence }
            return lhs.id.rawValue < rhs.id.rawValue
        }
        let byID = Dictionary(uniqueKeysWithValues: ordered.map { ($0.id, $0) })
        var prior = Set<ForgeHistoryCheckpointID>()

        for checkpoint in ordered {
            if let parentID = checkpoint.parentID {
                guard let parent = byID[parentID] else {
                    throw ForgeHistoryError.missingParent(
                        checkpointID: checkpoint.id.rawValue,
                        parentID: parentID.rawValue
                    )
                }
                guard prior.contains(parentID), parent.sequence < checkpoint.sequence else {
                    throw ForgeHistoryError.parentNotEarlier(
                        checkpointID: checkpoint.id.rawValue,
                        parentID: parentID.rawValue
                    )
                }
                guard parent.acceptedAtMilliseconds <= checkpoint.acceptedAtMilliseconds else {
                    throw ForgeHistoryError.timestampPrecedesParent(
                        checkpointID: checkpoint.id.rawValue,
                        parentID: parentID.rawValue
                    )
                }
            }
            prior.insert(checkpoint.id)
        }

        self.projectID = projectID
        self.missionID = missionID
        self.checkpoints = ordered
    }

    public var latestCheckpoint: ForgeHistoryCheckpoint? { checkpoints.last }

    public var visualTimeMachineItems: [ForgeVisualTimeMachineItem] {
        checkpoints.map { checkpoint in
            ForgeVisualTimeMachineItem(
                checkpointID: checkpoint.id,
                sequence: checkpoint.sequence,
                acceptedAtMilliseconds: checkpoint.acceptedAtMilliseconds,
                title: checkpoint.title,
                screenshotReferences: checkpoint.artifactReferences(kind: .screenshot),
                evidence: checkpoint.evidence
            )
        }
    }

    public func checkpoint(id: ForgeHistoryCheckpointID) -> ForgeHistoryCheckpoint? {
        checkpoints.first(where: { $0.id == id })
    }

    public func lineage(to checkpointID: ForgeHistoryCheckpointID) throws -> [ForgeHistoryCheckpoint] {
        guard checkpoint(id: checkpointID) != nil else {
            throw ForgeHistoryError.unknownCheckpoint(checkpointID.rawValue)
        }

        let byID = Dictionary(uniqueKeysWithValues: checkpoints.map { ($0.id, $0) })
        var path: [ForgeHistoryCheckpoint] = []
        var cursor: ForgeHistoryCheckpointID? = checkpointID
        while let currentID = cursor, let current = byID[currentID] {
            path.append(current)
            cursor = current.parentID
        }
        return path.reversed()
    }

    public func children(of checkpointID: ForgeHistoryCheckpointID) throws -> [ForgeHistoryCheckpoint] {
        guard checkpoint(id: checkpointID) != nil else {
            throw ForgeHistoryError.unknownCheckpoint(checkpointID.rawValue)
        }
        return checkpoints.filter { $0.parentID == checkpointID }
    }

    public func comparison(
        from fromID: ForgeHistoryCheckpointID,
        to toID: ForgeHistoryCheckpointID
    ) throws -> ForgeHistoryComparison {
        guard fromID != toID else {
            throw ForgeHistoryError.identicalComparisonEndpoints(fromID.rawValue)
        }
        guard let before = checkpoint(id: fromID) else {
            throw ForgeHistoryError.unknownCheckpoint(fromID.rawValue)
        }
        guard let after = checkpoint(id: toID) else {
            throw ForgeHistoryError.unknownCheckpoint(toID.rawValue)
        }

        let beforeEvidence = Set(before.evidence)
        let afterEvidence = Set(after.evidence)
        let beforeLimitations = Set(before.knownLimitations)
        let afterLimitations = Set(after.knownLimitations)
        let directDiff = after.parentID == before.id
            ? after.artifactReferences(kind: .sourceDiff).first
            : nil

        return ForgeHistoryComparison(
            fromCheckpointID: fromID,
            toCheckpointID: toID,
            beforeSourceSnapshots: before.artifactReferences(kind: .sourceSnapshot),
            afterSourceSnapshots: after.artifactReferences(kind: .sourceSnapshot),
            beforeScreenshots: before.artifactReferences(kind: .screenshot),
            afterScreenshots: after.artifactReferences(kind: .screenshot),
            directRecordedSourceDiff: directDiff,
            addedEvidence: after.evidence.filter { !beforeEvidence.contains($0) },
            removedEvidence: before.evidence.filter { !afterEvidence.contains($0) },
            addedLimitations: after.knownLimitations.filter { !beforeLimitations.contains($0) },
            resolvedLimitations: before.knownLimitations.filter { !afterLimitations.contains($0) }
        )
    }

    public func restoreIntent(to checkpointID: ForgeHistoryCheckpointID) throws -> ForgeHistoryActionIntent {
        guard checkpoint(id: checkpointID) != nil else {
            throw ForgeHistoryError.unknownCheckpoint(checkpointID.rawValue)
        }
        return .restore(projectID: projectID, checkpointID: checkpointID)
    }

    public func forkIntent(from checkpointID: ForgeHistoryCheckpointID) throws -> ForgeHistoryActionIntent {
        guard checkpoint(id: checkpointID) != nil else {
            throw ForgeHistoryError.unknownCheckpoint(checkpointID.rawValue)
        }
        return .fork(projectID: projectID, checkpointID: checkpointID)
    }

    public func compareIntent(
        from fromID: ForgeHistoryCheckpointID,
        to toID: ForgeHistoryCheckpointID
    ) throws -> ForgeHistoryActionIntent {
        _ = try comparison(from: fromID, to: toID)
        return .compare(projectID: projectID, from: fromID, to: toID)
    }

    private enum CodingKeys: String, CodingKey { case projectID, missionID, checkpoints }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            projectID: container.decode(ForgeHistoryProjectID.self, forKey: .projectID),
            missionID: container.decodeIfPresent(ForgeHistoryMissionID.self, forKey: .missionID),
            checkpoints: container.decode([ForgeHistoryCheckpoint].self, forKey: .checkpoints)
        )
    }
}
