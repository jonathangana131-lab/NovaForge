import AgentDomain
import ForgeCompactCore
import Foundation

/// Deterministic projection of reducer-backed supplemental references into a
/// bounded Forge Compact capsule.
///
/// This adapter deliberately does not compact the canonical model-item
/// transcript. Artifacts are projected only as source-backed identity/digest
/// metadata. Checkpoint summaries remain advisory model summaries and can
/// never become mandatory or authoritative mission truth through this bridge.
public struct AgentForgeCompactSupplementProjection: Equatable, Sendable {
    public let renderedContext: String
    public let renderedUTF8Bytes: Int
    public let sourceItemCount: Int
    public let selectedItemIDs: [String]
    public let omittedItemIDs: [String]

    public var selectedItemCount: Int { selectedItemIDs.count }
    public var omittedItemCount: Int { omittedItemIDs.count }

    public init(
        renderedContext: String,
        renderedUTF8Bytes: Int,
        sourceItemCount: Int,
        selectedItemIDs: [String],
        omittedItemIDs: [String]
    ) {
        self.renderedContext = renderedContext
        self.renderedUTF8Bytes = renderedUTF8Bytes
        self.sourceItemCount = sourceItemCount
        self.selectedItemIDs = selectedItemIDs
        self.omittedItemIDs = omittedItemIDs
    }
}

public enum AgentForgeCompactSupplementProjector {
    public static func project(
        context: AgentRunContext,
        sourceRevision: String,
        artifacts: [ArtifactReference],
        checkpoints: [ContextCheckpointReference],
        budgetBytes: Int
    ) throws -> AgentForgeCompactSupplementProjection {
        guard !artifacts.isEmpty || !checkpoints.isEmpty else {
            return AgentForgeCompactSupplementProjection(
                renderedContext: "",
                renderedUTF8Bytes: 0,
                sourceItemCount: 0,
                selectedItemIDs: [],
                omittedItemIDs: []
            )
        }

        let authority = try ProjectCapsuleAuthority(
            projectID: context.projectID?.description
                ?? "conversation:\(context.conversationID.description)",
            missionID: "run:\(context.lineage.runID.description)",
            sourceRevision: sourceRevision,
            missionRevision: Int(context.lineage.generation),
            authorityEpoch: 0,
            capsuleRevision: Int(context.lineage.generation)
        )

        var items: [ForgeCompactContextItem] = []
        items.reserveCapacity(artifacts.count + checkpoints.count)

        for artifact in artifacts {
            let itemID = "artifact:\(artifact.artifactID.description)"
            let displayName = try quoted(artifact.displayName ?? "")
            let mediaType = try quoted(artifact.mediaType)
            let digest = try quoted(artifact.contentDigest)
            let content = "artifact_reference id=\(artifact.artifactID.description) media_type=\(mediaType) digest=\(digest) display_name=\(displayName)"
            items.append(try ForgeCompactContextItem(
                id: itemID,
                sourceRevision: sourceRevision,
                tier: .l2ProjectMemory,
                kind: .sourceLocation,
                priority: 50,
                content: content,
                provenance: ForgeCompactProvenance(
                    kind: .source,
                    reference: artifact.artifactID.description
                ),
                isAuthoritative: true,
                freshness: .current,
                protectedByUser: false
            ))
        }

        for (index, checkpoint) in checkpoints.enumerated() {
            let distanceFromNewest = checkpoints.count - 1 - index
            let priority = 90 - min(distanceFromNewest, 20)
            let sourceDigest = try quoted(checkpoint.sourceDigest)
            let summary = try quoted(checkpoint.summary)
            let content = "checkpoint_summary id=\(checkpoint.checkpointID.description) source_digest=\(sourceDigest) source_item_count=\(checkpoint.sourceItemIDs.count) summary=\(summary)"
            items.append(try ForgeCompactContextItem(
                id: "checkpoint:\(checkpoint.checkpointID.description)",
                sourceRevision: sourceRevision,
                tier: .l1ActiveWorkingSet,
                kind: .workingNote,
                priority: priority,
                content: content,
                provenance: ForgeCompactProvenance(
                    kind: .modelSummary,
                    reference: checkpoint.checkpointID.description
                ),
                isAuthoritative: false,
                freshness: .current,
                protectedByUser: false
            ))
        }

        let capsule = try ProjectCapsuleBuilder.build(
            authority: authority,
            items: items,
            budgetBytes: budgetBytes
        )
        return AgentForgeCompactSupplementProjection(
            renderedContext: capsule.renderedContext,
            renderedUTF8Bytes: capsule.renderedUTF8Bytes,
            sourceItemCount: capsule.sourceItemCount,
            selectedItemIDs: capsule.selectedItems.map(\.id),
            omittedItemIDs: capsule.omittedItems.map(\.id)
        )
    }

    private static func quoted(_ value: String) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let encoded = String(data: data, encoding: .utf8) else {
            throw ForgeCompactError.invalidContent
        }
        return encoded
    }
}
