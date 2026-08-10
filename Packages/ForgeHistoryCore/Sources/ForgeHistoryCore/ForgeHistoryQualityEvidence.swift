import Foundation

/// Quality domains that History may link to. The kind alone never says that the producer evidence
/// passed, is current, or satisfies completion.
public enum ForgeHistoryQualityEvidenceKind: String, CaseIterable, Hashable, Sendable {
    case accessibility
    case performance
    case visualQA
}

/// Public History quality references are deliberately non-authoritative until a canonical producer
/// bridge can supply a trust-bearing type that external/model-authored code cannot mint.
public enum ForgeHistoryQualityEvidenceVerificationStatus: String, CaseIterable, Hashable, Sendable {
    case unverifiedReference
}

public enum ForgeHistoryQualityProjectionError: Error, Equatable, Sendable {
    case invalidProducerReceiptReference
    case emptyQualityEvidence(checkpointID: String)
    case duplicateQualityKind(checkpointID: String, kind: ForgeHistoryQualityEvidenceKind)
    case projectMismatch(checkpointID: String, expectedProjectID: String, actualProjectID: String)
    case unknownCheckpoint(String)
    case duplicateCheckpointBinding(String)
}

/// Exact opaque identity emitted by a quality producer.
///
/// This deliberately does not reuse `ForgeHistoryReceiptID`: History's own durable receipt IDs have
/// a tighter ASCII/length grammar, while producer domains may legitimately use a broader canonical
/// identifier. Preserving the string only creates a reference; it does not authenticate the named
/// producer receipt or make it completion evidence.
public struct ForgeHistoryProducerReceiptReference: Hashable, Sendable, CustomStringConvertible {
    public static let maximumLength = 4_096

    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard !rawValue.isEmpty,
              rawValue.count <= Self.maximumLength,
              rawValue == rawValue.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ForgeHistoryQualityProjectionError.invalidProducerReceiptReference
        }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

/// Ephemeral link to producer evidence. This is intentionally named and typed as an unverified
/// reference: any external caller can construct it, so it must never be rendered as accepted or
/// passed merely because it appears in History. A future producer bridge must use an unforgeable
/// trusted producer type before introducing accepted-quality semantics.
public struct ForgeHistoryQualityEvidenceReference: Hashable, Sendable {
    public let kind: ForgeHistoryQualityEvidenceKind
    public let producerReceiptReference: ForgeHistoryProducerReceiptReference
    public let artifactReference: ForgeHistoryArtifactReference?

    public var verificationStatus: ForgeHistoryQualityEvidenceVerificationStatus {
        .unverifiedReference
    }

    public init(
        kind: ForgeHistoryQualityEvidenceKind,
        producerReceiptReference: ForgeHistoryProducerReceiptReference,
        artifactReference: ForgeHistoryArtifactReference? = nil
    ) {
        self.kind = kind
        self.producerReceiptReference = producerReceiptReference
        self.artifactReference = artifactReference
    }

    fileprivate var stableSortKey: String {
        [
            kind.rawValue,
            producerReceiptReference.rawValue,
            artifactReference?.kind.rawValue ?? "",
            artifactReference?.id.rawValue ?? "",
        ].joined(separator: "|")
    }
}

/// Project/checkpoint-scoped references supplied by a host. The binding only proves that History can
/// associate the references with an existing checkpoint; it does not prove the producer receipt is
/// authentic, current, passing, or sufficient for completion.
public struct ForgeHistoryCheckpointQualityReferenceBinding: Hashable, Sendable {
    public let projectID: ForgeHistoryProjectID
    public let checkpointID: ForgeHistoryCheckpointID
    public let evidence: [ForgeHistoryQualityEvidenceReference]

    public init(
        projectID: ForgeHistoryProjectID,
        checkpointID: ForgeHistoryCheckpointID,
        evidence: [ForgeHistoryQualityEvidenceReference]
    ) throws {
        guard !evidence.isEmpty else {
            throw ForgeHistoryQualityProjectionError.emptyQualityEvidence(
                checkpointID: checkpointID.rawValue
            )
        }

        var seenKinds = Set<ForgeHistoryQualityEvidenceKind>()
        for claim in evidence where !seenKinds.insert(claim.kind).inserted {
            throw ForgeHistoryQualityProjectionError.duplicateQualityKind(
                checkpointID: checkpointID.rawValue,
                kind: claim.kind
            )
        }

        self.projectID = projectID
        self.checkpointID = checkpointID
        self.evidence = evidence.sorted { $0.stableSortKey < $1.stableSortKey }
    }
}

/// Presentation state containing only unverified producer references for one checkpoint.
public struct ForgeHistoryCheckpointQualityReferenceState: Hashable, Sendable {
    public let checkpointID: ForgeHistoryCheckpointID
    public let evidence: [ForgeHistoryQualityEvidenceReference]

    fileprivate init(
        checkpointID: ForgeHistoryCheckpointID,
        evidence: [ForgeHistoryQualityEvidenceReference]
    ) {
        self.checkpointID = checkpointID
        self.evidence = evidence
    }

    public func evidence(
        kind: ForgeHistoryQualityEvidenceKind
    ) -> ForgeHistoryQualityEvidenceReference? {
        evidence.first(where: { $0.kind == kind })
    }
}

/// Ephemeral unverified-reference overlay for the canonical History timeline. Checkpoint chronology
/// and identity remain owned by `ForgeHistoryTimeline`; this wrapper cannot express accepted quality.
public struct ForgeHistoryQualityReferenceTimelineProjection: Hashable, Sendable {
    public let timeline: ForgeHistoryTimeline
    public let qualityStates: [ForgeHistoryCheckpointQualityReferenceState]

    fileprivate init(
        timeline: ForgeHistoryTimeline,
        qualityStates: [ForgeHistoryCheckpointQualityReferenceState]
    ) {
        self.timeline = timeline
        self.qualityStates = qualityStates
    }

    public func qualityState(
        for checkpointID: ForgeHistoryCheckpointID
    ) -> ForgeHistoryCheckpointQualityReferenceState? {
        qualityStates.first(where: { $0.checkpointID == checkpointID })
    }
}

public enum ForgeHistoryQualityReferenceTimelineProjector {
    public static func project(
        timeline: ForgeHistoryTimeline,
        qualityReferences: [ForgeHistoryCheckpointQualityReferenceBinding]
    ) throws -> ForgeHistoryQualityReferenceTimelineProjection {
        let checkpointsByID = Dictionary(
            uniqueKeysWithValues: timeline.checkpoints.map { ($0.id, $0) }
        )
        var seenCheckpointIDs = Set<ForgeHistoryCheckpointID>()
        var qualityByCheckpoint = [ForgeHistoryCheckpointID: [ForgeHistoryQualityEvidenceReference]]()

        for binding in qualityReferences {
            guard binding.projectID == timeline.projectID else {
                throw ForgeHistoryQualityProjectionError.projectMismatch(
                    checkpointID: binding.checkpointID.rawValue,
                    expectedProjectID: timeline.projectID.rawValue,
                    actualProjectID: binding.projectID.rawValue
                )
            }
            guard seenCheckpointIDs.insert(binding.checkpointID).inserted else {
                throw ForgeHistoryQualityProjectionError.duplicateCheckpointBinding(
                    binding.checkpointID.rawValue
                )
            }
            guard let checkpoint = checkpointsByID[binding.checkpointID] else {
                throw ForgeHistoryQualityProjectionError.unknownCheckpoint(
                    binding.checkpointID.rawValue
                )
            }

            let attachedArtifacts = Set(checkpoint.artifacts)
            for claim in binding.evidence {
                if let artifact = claim.artifactReference, !attachedArtifacts.contains(artifact) {
                    throw ForgeHistoryError.evidenceArtifactNotAttached(artifact.id.rawValue)
                }
            }
            qualityByCheckpoint[binding.checkpointID] = binding.evidence
        }

        let orderedStates = timeline.checkpoints.compactMap { checkpoint in
            qualityByCheckpoint[checkpoint.id].map {
                ForgeHistoryCheckpointQualityReferenceState(
                    checkpointID: checkpoint.id,
                    evidence: $0
                )
            }
        }

        return ForgeHistoryQualityReferenceTimelineProjection(
            timeline: timeline,
            qualityStates: orderedStates
        )
    }
}
