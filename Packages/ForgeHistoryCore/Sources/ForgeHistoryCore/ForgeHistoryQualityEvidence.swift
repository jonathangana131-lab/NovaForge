/// Quality evidence shown by History is an exact reference to a canonical producer receipt.
/// History does not re-score accessibility or performance, authenticate producer receipts, or
/// collapse richer producer identity (device, OS build, policy, budget, source revision) into a
/// weaker local badge.
public enum ForgeHistoryQualityEvidenceKind: String, CaseIterable, Hashable, Sendable {
    case accessibility
    case performance
}

public enum ForgeHistoryQualityProjectionError: Error, Equatable, Sendable {
    case emptyQualityEvidence(checkpointID: String)
    case duplicateQualityKind(checkpointID: String, kind: ForgeHistoryQualityEvidenceKind)
    case projectMismatch(checkpointID: String, expectedProjectID: String, actualProjectID: String)
    case unknownCheckpoint(String)
    case duplicateCheckpointBinding(String)
}

/// Ephemeral reference to one already-accepted canonical quality receipt. This value is
/// deliberately non-Codable: persisted/model-authored bytes must not become accepted quality truth
/// merely by naming a receipt. A host adapter must reconstruct it from current producer authority.
public struct ForgeHistoryAcceptedQualityEvidenceReference: Hashable, Sendable {
    public let kind: ForgeHistoryQualityEvidenceKind
    public let producerReceiptReference: ForgeHistoryReceiptID
    public let artifactReference: ForgeHistoryArtifactReference?

    public init(
        kind: ForgeHistoryQualityEvidenceKind,
        producerReceiptReference: ForgeHistoryReceiptID,
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

/// Host-supplied accepted quality references for one canonical History checkpoint. The binding
/// carries project identity explicitly so an adapter cannot accidentally mix quality evidence from
/// another project into an otherwise-valid timeline.
public struct ForgeHistoryCheckpointQualityBinding: Hashable, Sendable {
    public let projectID: ForgeHistoryProjectID
    public let checkpointID: ForgeHistoryCheckpointID
    public let evidence: [ForgeHistoryAcceptedQualityEvidenceReference]

    public init(
        projectID: ForgeHistoryProjectID,
        checkpointID: ForgeHistoryCheckpointID,
        evidence: [ForgeHistoryAcceptedQualityEvidenceReference]
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

/// Presentation state for a checkpoint whose current canonical quality receipts were accepted by
/// the host. This is a reference projection only; the producer remains authoritative for what the
/// receipt proves and whether it is still current.
public struct ForgeHistoryCheckpointQualityState: Hashable, Sendable {
    public let checkpointID: ForgeHistoryCheckpointID
    public let evidence: [ForgeHistoryAcceptedQualityEvidenceReference]

    fileprivate init(
        checkpointID: ForgeHistoryCheckpointID,
        evidence: [ForgeHistoryAcceptedQualityEvidenceReference]
    ) {
        self.checkpointID = checkpointID
        self.evidence = evidence
    }

    public func evidence(
        kind: ForgeHistoryQualityEvidenceKind
    ) -> ForgeHistoryAcceptedQualityEvidenceReference? {
        evidence.first(where: { $0.kind == kind })
    }
}

/// Ephemeral quality overlay for the canonical History timeline. Checkpoint chronology and identity
/// remain owned by `ForgeHistoryTimeline`; this wrapper only retains host-accepted producer receipt
/// references in the same canonical order.
public struct ForgeHistoryAcceptedQualityTimelineProjection: Hashable, Sendable {
    public let timeline: ForgeHistoryTimeline
    public let qualityStates: [ForgeHistoryCheckpointQualityState]

    fileprivate init(
        timeline: ForgeHistoryTimeline,
        qualityStates: [ForgeHistoryCheckpointQualityState]
    ) {
        self.timeline = timeline
        self.qualityStates = qualityStates
    }

    public func qualityState(
        for checkpointID: ForgeHistoryCheckpointID
    ) -> ForgeHistoryCheckpointQualityState? {
        qualityStates.first(where: { $0.checkpointID == checkpointID })
    }
}

public enum ForgeHistoryAcceptedQualityTimelineProjector {
    public static func project(
        timeline: ForgeHistoryTimeline,
        acceptedQuality: [ForgeHistoryCheckpointQualityBinding]
    ) throws -> ForgeHistoryAcceptedQualityTimelineProjection {
        let checkpointsByID = Dictionary(
            uniqueKeysWithValues: timeline.checkpoints.map { ($0.id, $0) }
        )
        var seenCheckpointIDs = Set<ForgeHistoryCheckpointID>()
        var qualityByCheckpoint = [ForgeHistoryCheckpointID: [ForgeHistoryAcceptedQualityEvidenceReference]]()

        for binding in acceptedQuality {
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
                ForgeHistoryCheckpointQualityState(
                    checkpointID: checkpoint.id,
                    evidence: $0
                )
            }
        }

        return ForgeHistoryAcceptedQualityTimelineProjection(
            timeline: timeline,
            qualityStates: orderedStates
        )
    }
}
