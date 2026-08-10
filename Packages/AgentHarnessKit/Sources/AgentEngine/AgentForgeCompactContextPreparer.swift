import AgentDomain
import AgentProviders
import AgentTools
import CryptoKit
import Foundation

/// Post-validation Forge Compact decorator for a canonical context preparer.
///
/// The wrapped preparer sees the complete authoritative transcript first, so
/// checkpoint/source validation and provider replay checks remain unchanged.
/// Only after that succeeds do we consider replacing an eligibility-proven
/// historical plain-text prefix with its already-canonical checkpoint message.
public struct AgentForgeCompactContextPreparer: AgentContextPreparing, Sendable {
    private let base: any AgentContextPreparing
    private let protectedTailItemCount: Int
    private let minimumSavingsBytes: Int

    public init(
        base: any AgentContextPreparing,
        protectedTailItemCount: Int = 6,
        minimumSavingsBytes: Int = 256
    ) {
        self.base = base
        self.protectedTailItemCount = protectedTailItemCount
        self.minimumSavingsBytes = minimumSavingsBytes
    }

    public func prepareProviderTurn(
        state: AgentRunState,
        tools: [ToolDescriptor]
    ) async throws -> AgentPreparedProviderTurn {
        let prepared = try await base.prepareProviderTurn(
            state: state,
            tools: tools
        )
        return try AgentForgeCompactPreparedTurnCompactor.compact(
            prepared: prepared,
            modelItems: state.modelItems,
            projectID: state.context.projectID?.description
                ?? state.context.workspaceID.description,
            missionID: state.context.lineage.runID.description,
            protectedTailItemCount: protectedTailItemCount,
            minimumSavingsBytes: minimumSavingsBytes
        )
    }
}

public enum AgentForgeCompactPreparedTurnCompactor {
    /// Compacts only when the checkpoint planner and provider-message mapping
    /// independently prove the same historical prefix. Any mismatch is a no-op.
    public static func compact(
        prepared: AgentPreparedProviderTurn,
        modelItems: [ModelItem],
        projectID: String,
        missionID: String,
        protectedTailItemCount: Int = 6,
        minimumSavingsBytes: Int = 256
    ) throws -> AgentPreparedProviderTurn {
        let plan = AgentForgeCompactCheckpointPlanner.plan(
            modelItems: modelItems,
            projectID: projectID,
            missionID: missionID,
            protectedTailItemCount: protectedTailItemCount,
            minimumSavingsBytes: minimumSavingsBytes
        )
        guard plan.didCompact,
              let sourceMessages = sourceProviderMessages(
                  modelItems: modelItems,
                  sourceItemIDs: plan.compactedSourceItemIDs
              ),
              let removalRange = uniqueContiguousMatch(
                  sourceMessages,
                  in: prepared.request.messages
              )
        else { return prepared }

        var messages = prepared.request.messages
        messages.removeSubrange(removalRange)
        guard !messages.isEmpty else { return prepared }

        let compactedRequest = CanonicalProviderRequest(
            requestID: prepared.request.requestID,
            model: prepared.request.model,
            messages: messages,
            tools: prepared.request.tools,
            options: prepared.request.options,
            metadata: prepared.request.metadata
        )

        let compactedDigest = try requestDigest(compactedRequest)
        let compactedSourceIDs = Set(plan.compactedSourceItemIDs)
        let retainedItemIDs = prepared.itemIDs.filter {
            !compactedSourceIDs.contains($0)
        }
        guard retainedItemIDs.count < prepared.itemIDs.count else {
            return prepared
        }

        return AgentPreparedProviderTurn(
            request: compactedRequest,
            preferredAdapterIDs: prepared.preferredAdapterIDs,
            itemIDs: retainedItemIDs,
            // Keep routing/context-window accounting conservative until the
            // canonical estimator grows a Forge Compact-aware post-pass.
            estimatedTokens: prepared.estimatedTokens,
            contextDigest: compactedDigest,
            toolLocalities: prepared.toolLocalities
        )
    }

    private static func sourceProviderMessages(
        modelItems: [ModelItem],
        sourceItemIDs: [ModelItemID]
    ) -> [ProviderMessage]? {
        guard sourceItemIDs.count <= modelItems.count else { return nil }
        let prefix = Array(modelItems.prefix(sourceItemIDs.count))
        guard prefix.map(\.id) == sourceItemIDs else { return nil }

        var result: [ProviderMessage] = []
        result.reserveCapacity(prefix.count)
        for item in prefix {
            guard case let .message(message) = item.payload,
                  !message.content.isEmpty
            else { return nil }

            var content: [ProviderContentPart] = []
            content.reserveCapacity(message.content.count)
            for part in message.content {
                guard case let .text(text) = part else { return nil }
                content.append(.text(text))
            }
            result.append(ProviderMessage(
                role: message.role == .user ? .user : .assistant,
                content: content
            ))
        }
        return result
    }

    private static func uniqueContiguousMatch(
        _ needle: [ProviderMessage],
        in haystack: [ProviderMessage]
    ) -> Range<Int>? {
        guard !needle.isEmpty, needle.count <= haystack.count else {
            return nil
        }

        var match: Range<Int>?
        let finalStart = haystack.count - needle.count
        for start in 0...finalStart {
            let range = start..<(start + needle.count)
            guard Array(haystack[range]) == needle else { continue }
            guard match == nil else { return nil }
            match = range
        }
        return match
    }

    private static func requestDigest(
        _ request: CanonicalProviderRequest
    ) throws -> AgentCanonicalSHA256Digest {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(request)
        let hex = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        return try AgentCanonicalSHA256Digest("sha256:\(hex)")
    }
}
