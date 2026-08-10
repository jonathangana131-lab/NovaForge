import AgentDomain
import ForgeCompactCore
import Foundation

/// A deliberately narrow Forge Compact bridge for the Preview agent harness.
///
/// The authoritative run ledger stays untouched. A checkpoint is eligible only
/// when it proves that it summarizes the entire historical prefix before the
/// checkpoint and every covered item is a plain text message. This excludes
/// provider-owned reasoning replay, tools, images, artifacts, structured data,
/// and the protected recent tail from compaction by construction.
public struct AgentForgeCompactCheckpointPlan: Equatable, Sendable {
    public let checkpointItemID: ModelItemID?
    public let compactedSourceItemIDs: [ModelItemID]
    public let sourceTextUTF8Bytes: Int
    public let checkpointSummaryUTF8Bytes: Int
    public let capsuleRenderedUTF8Bytes: Int

    public init(
        checkpointItemID: ModelItemID?,
        compactedSourceItemIDs: [ModelItemID],
        sourceTextUTF8Bytes: Int,
        checkpointSummaryUTF8Bytes: Int,
        capsuleRenderedUTF8Bytes: Int
    ) {
        self.checkpointItemID = checkpointItemID
        self.compactedSourceItemIDs = compactedSourceItemIDs
        self.sourceTextUTF8Bytes = sourceTextUTF8Bytes
        self.checkpointSummaryUTF8Bytes = checkpointSummaryUTF8Bytes
        self.capsuleRenderedUTF8Bytes = capsuleRenderedUTF8Bytes
    }

    public static let none = AgentForgeCompactCheckpointPlan(
        checkpointItemID: nil,
        compactedSourceItemIDs: [],
        sourceTextUTF8Bytes: 0,
        checkpointSummaryUTF8Bytes: 0,
        capsuleRenderedUTF8Bytes: 0
    )

    public var didCompact: Bool {
        checkpointItemID != nil && !compactedSourceItemIDs.isEmpty
    }

    public var estimatedSavedUTF8Bytes: Int {
        let result = sourceTextUTF8Bytes.subtractingReportingOverflow(
            checkpointSummaryUTF8Bytes
        )
        guard !result.overflow else { return 0 }
        return max(0, result.partialValue)
    }
}

public enum AgentForgeCompactCheckpointPlanner {
    /// Returns the newest checkpoint that can safely replace an old plain-text
    /// prefix. Any ambiguity is a no-op rather than a lossy guess.
    public static func plan(
        modelItems: [ModelItem],
        projectID: String,
        missionID: String,
        protectedTailItemCount: Int = 6,
        minimumSavingsBytes: Int = 256
    ) -> AgentForgeCompactCheckpointPlan {
        guard !modelItems.isEmpty,
              protectedTailItemCount >= 0,
              minimumSavingsBytes >= 0
        else { return .none }

        let protectedStart: Int
        if protectedTailItemCount >= modelItems.count {
            protectedStart = 0
        } else {
            protectedStart = modelItems.count - protectedTailItemCount
        }

        for checkpointIndex in modelItems.indices.reversed() {
            guard checkpointIndex < protectedStart,
                  case let .contextCheckpoint(checkpoint) = modelItems[checkpointIndex].payload,
                  !checkpoint.sourceItemIDs.isEmpty
            else { continue }

            let historicalPrefix = Array(modelItems[..<checkpointIndex])
            guard checkpoint.sourceItemIDs == historicalPrefix.map(\.id),
                  Set(checkpoint.sourceItemIDs).count == checkpoint.sourceItemIDs.count
            else { continue }

            var sourceTextBytes = 0
            var allPlainTextMessages = true
            for item in historicalPrefix {
                guard case let .message(message) = item.payload,
                      !message.content.isEmpty
                else {
                    allPlainTextMessages = false
                    break
                }

                for part in message.content {
                    guard case let .text(text) = part,
                          !text.isEmpty
                    else {
                        allPlainTextMessages = false
                        break
                    }
                    let next = sourceTextBytes.addingReportingOverflow(text.utf8.count)
                    guard !next.overflow else {
                        allPlainTextMessages = false
                        break
                    }
                    sourceTextBytes = next.partialValue
                }
                if !allPlainTextMessages { break }
            }
            guard allPlainTextMessages else { continue }

            let summaryBytes = checkpoint.summary.utf8.count
            let requiredSourceBytes = summaryBytes.addingReportingOverflow(
                minimumSavingsBytes
            )
            guard !requiredSourceBytes.overflow,
                  sourceTextBytes >= requiredSourceBytes.partialValue
            else { continue }

            do {
                let authority = try ProjectCapsuleAuthority(
                    projectID: projectID,
                    missionID: missionID,
                    sourceRevision: checkpoint.sourceDigest,
                    missionRevision: 0,
                    authorityEpoch: 0,
                    capsuleRevision: checkpointIndex
                )
                let summaryItem = try ForgeCompactContextItem(
                    id: "checkpoint-\(checkpoint.checkpointID.description)",
                    sourceRevision: checkpoint.sourceDigest,
                    tier: .l1ActiveWorkingSet,
                    kind: .workingNote,
                    priority: 80,
                    content: checkpoint.summary,
                    provenance: try ForgeCompactProvenance(
                        kind: .checkpoint,
                        reference: "checkpoint:\(checkpoint.checkpointID.description)"
                    ),
                    isAuthoritative: false,
                    freshness: .current,
                    protectedByUser: false
                )
                let capsule = try ProjectCapsuleBuilder.build(
                    authority: authority,
                    items: [summaryItem],
                    budgetBytes: summaryItem.renderedUTF8Bytes
                )
                return AgentForgeCompactCheckpointPlan(
                    checkpointItemID: modelItems[checkpointIndex].id,
                    compactedSourceItemIDs: checkpoint.sourceItemIDs,
                    sourceTextUTF8Bytes: sourceTextBytes,
                    checkpointSummaryUTF8Bytes: summaryBytes,
                    capsuleRenderedUTF8Bytes: capsule.renderedUTF8Bytes
                )
            } catch {
                // Forge Compact validation is the authority boundary. Invalid
                // identifiers, revisions, or capsule shape fail closed.
                continue
            }
        }

        return .none
    }
}
