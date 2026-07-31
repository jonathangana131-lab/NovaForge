import Foundation

/// Builds a bounded provider transcript without splitting assistant tool-call
/// exchanges from their matching tool results.
///
/// NovaForge deliberately uses a conservative character-based token estimate
/// instead of coupling the app to one provider tokenizer. Provider-side payload
/// compaction applies the same per-role limits, so this estimate remains stable
/// across hosted and local models while avoiding an unbounded message-count
/// window in long-running projects.
enum ProviderContextWindow {
    enum PreparationError: Error, Equatable, Sendable {
        case invalidSanitizedTranscript
    }

    struct Budget: Equatable, Sendable {
        var maximumEstimatedTokens: Int
        var maximumMessages: Int

        static let hosted = Budget(maximumEstimatedTokens: 24_000, maximumMessages: 96)

        static func local(contextTokens: Int) -> Budget {
            let reservedForSystemAndOutput = max(1_024, contextTokens / 3)
            return Budget(
                maximumEstimatedTokens: max(768, contextTokens - reservedForSystemAndOutput),
                maximumMessages: 48
            )
        }
    }

    static func select(
        _ history: [ProviderMessageInput],
        budget: Budget
    ) -> [ProviderMessageInput] {
        guard budget.maximumMessages > 0,
              budget.maximumEstimatedTokens > 0,
              !history.isEmpty else { return [] }

        let ordered = history.sorted(by: messageAscending)
        let groups = coherentGroups(from: ordered)
        let latestUserID = ordered.last(where: { $0.role == .user })?.id

        var selectedGroups: [[ProviderMessageInput]] = []
        var selectedIDs = Set<UUID>()
        var estimatedTokens = 0
        var messageCount = 0

        // Newest coherent exchanges have the highest value. A complete group
        // either fits or stays out; this prevents orphan tool results.
        for group in groups.reversed() {
            let groupTokens = estimatedTokenCount(group)
            let groupMessageCount = group.count
            let containsLatestUser = latestUserID.map { id in group.contains(where: { $0.id == id }) } ?? false
            let fits = messageCount + groupMessageCount <= budget.maximumMessages &&
                estimatedTokens + groupTokens <= budget.maximumEstimatedTokens

            guard fits || (selectedGroups.isEmpty && containsLatestUser) else {
                // Once a recent suffix has begun, stop at the first group that
                // does not fit. Skipping it and then adding older turns creates
                // a misleading, non-contiguous conversation history.
                if !selectedGroups.isEmpty { break }
                continue
            }
            selectedGroups.append(group)
            selectedIDs.formUnion(group.map(\.id))
            estimatedTokens += groupTokens
            messageCount += groupMessageCount
        }

        // Tool-heavy loops can push the initiating user turn beyond the greedy
        // suffix. Pin that request, then evict the oldest optional groups until
        // the message cap is restored. A single oversized user request is kept;
        // ProviderMessageSanitizer performs the final content compaction.
        if let latestUserID,
           !selectedIDs.contains(latestUserID),
           let userGroup = groups.first(where: { $0.contains(where: { $0.id == latestUserID }) }) {
            selectedGroups.append(userGroup)
            selectedIDs.formUnion(userGroup.map(\.id))
            messageCount += userGroup.count
            estimatedTokens += estimatedTokenCount(userGroup)

            while (messageCount > budget.maximumMessages || estimatedTokens > budget.maximumEstimatedTokens),
                  selectedGroups.count > 1 {
                guard let removalIndex = selectedGroups.indices
                    .filter({ !selectedGroups[$0].contains(where: { $0.id == latestUserID }) })
                    .min(by: { groupNewestDate(selectedGroups[$0]) < groupNewestDate(selectedGroups[$1]) }) else {
                    break
                }
                messageCount -= selectedGroups[removalIndex].count
                estimatedTokens -= estimatedTokenCount(selectedGroups[removalIndex])
                selectedGroups.remove(at: removalIndex)
            }
        }

        let selected = selectedGroups
            .flatMap { $0 }
            .reduce(into: [UUID: ProviderMessageInput]()) { partial, message in
                partial[message.id] = message
            }
            .values
            .sorted(by: messageAscending)

        return compactPinnedUserIfNeeded(
            selected,
            latestUserID: latestUserID,
            maximumEstimatedTokens: budget.maximumEstimatedTokens
        )
    }

    static func estimatedTokenCount(_ history: [ProviderMessageInput]) -> Int {
        history.reduce(0) { partial, message in
            partial + estimatedTokenCount(message)
        }
    }

    /// One prompt/context boundary shared by V1 and every V2 canary. Keeping
    /// selection, prompt construction, compaction, and validation here makes
    /// byte-for-byte parity testable instead of relying on two similar strings.
    static func prepareHostedTranscript(
        history: [ProviderMessageInput],
        customSystemPrompt: String?,
        workspaceSummary: String,
        budget: Budget = .hosted
    ) throws -> SanitizedProviderTranscript {
        let selected = select(history, budget: budget)
        let transcript = ProviderMessageSanitizer.sanitize(
            systemPrompt: systemPrompt(
                customSystemPrompt: customSystemPrompt,
                workspaceSummary: workspaceSummary
            ),
            history: selected
        )
        guard ProviderMessageSanitizer.validate(transcript.messages).isEmpty else {
            throw PreparationError.invalidSanitizedTranscript
        }
        return transcript
    }

    static func systemPrompt(
        customSystemPrompt: String?,
        workspaceSummary: String
    ) -> String {
        if let customSystemPrompt,
           !customSystemPrompt.trimmingCharacters(
               in: .whitespacesAndNewlines
           ).isEmpty {
            return customSystemPrompt
        }
        return """
        You are NovaForge, an iOS sandbox coding and file assistant.
        You can inspect project structure, summarize workspaces, read whole files or line ranges, get file metadata, write/append/replace text, manage files/folders, diff files, validate JSON/HTML, extract code outlines, search text, and run safe commands in the sandbox using your tools.
        When the user asks you to build an app, web page, or game, create or edit real workspace files with write_file/append_file/replace_text instead of pasting the project into chat.
        Use tools in small inspect-edit-validate loops: list_tree or workspace_summary, read only relevant files/ranges, write changes, run targeted validators/checks, then fix any failure before the final response.
        For HTML games/pages, write the file, then run validate_html <path>, wc <path>, head -n 40 <path>, and find . before the final response.
        For code tasks, prefer tool actions over long chat output. Never stream full generated source into chat unless the user explicitly asks to see the source.
        Do not greet, restate the request, or narrate obvious preparation. Before tool calls, use at most one short sentence and only when it clarifies what will happen next.
        Use short paragraphs. Use Markdown only when it improves scanning, and never wrap a filename in both bold and inline-code markers.
        Keep final chat responses short: say what changed, which file to open, and what validation passed.

        Current workspace files:
        \(workspaceSummary)

        Always output a clear final text response to the user once you have finished executing tools or if no tools are needed.
        """
    }

    static func workspaceSummary(
        for workspace: SandboxWorkspace,
        provider: AIProvider
    ) -> String {
        let items = (try? workspace.manifest(
            maxItems: provider == .local ? 120 : 500,
            maxDepth: provider == .local ? 3 : 5
        )) ?? []
        guard !items.isEmpty else { return "No files yet." }

        let limit = provider == .local ? 36 : 160
        let paths = items.map { item in
            "\(item.isDirectory ? "folder" : "file"): \(item.relativePath)"
        }
        let visible = paths.prefix(limit).joined(separator: "\n")
        let remaining = max(0, paths.count - limit)
        return remaining > 0
            ? "\(visible)\n... \(remaining) more workspace items hidden for responsive provider setup."
            : visible
    }

    private static func coherentGroups(from ordered: [ProviderMessageInput]) -> [[ProviderMessageInput]] {
        var groups: [[ProviderMessageInput]] = []
        var index = ordered.startIndex

        while index < ordered.endIndex {
            let message = ordered[index]
            // A tool result is only meaningful when its assistant tool-call
            // envelope is present. Legacy or partially repaired transcripts
            // can contain an orphan result; never spend context budget on a
            // provider-invalid standalone tool message.
            if message.role == .tool {
                index = ordered.index(after: index)
                continue
            }
            guard message.role == .assistant, !message.toolCalls.isEmpty else {
                groups.append([message])
                index = ordered.index(after: index)
                continue
            }

            var group = [message]
            let requiredIDs = Set(message.toolCalls.map(\.id))
            var matchedIDs = Set<String>()
            var nextIndex = ordered.index(after: index)
            while nextIndex < ordered.endIndex,
                  ordered[nextIndex].role == .tool,
                  let toolCallID = ordered[nextIndex].toolCallID,
                  requiredIDs.contains(toolCallID) {
                group.append(ordered[nextIndex])
                matchedIDs.insert(toolCallID)
                nextIndex = ordered.index(after: nextIndex)
            }
            // Never send an assistant tool-call envelope without exactly one
            // available result for every declared call. Providers reject that
            // shape, and a repaired/legacy transcript may legitimately contain
            // a partial exchange after an interruption.
            if matchedIDs == requiredIDs, group.count == requiredIDs.count + 1 {
                groups.append(group)
            }
            index = nextIndex
        }
        return groups
    }

    private static func estimatedTokenCount(_ message: ProviderMessageInput) -> Int {
        let contentLimit: Int
        switch message.role {
        case .system:
            contentLimit = 18_000
        case .user, .assistant:
            contentLimit = 12_000
        case .tool:
            contentLimit = 6_000
        }
        let contentCharacters = min(message.content.count, contentLimit)
        let toolArgumentCharacters = message.toolCalls.reduce(0) { partial, call in
            partial + min(call.function.arguments.count, 4_000)
        }
        // Four characters per token is intentionally conservative for mixed
        // prose/code, plus a small role/serialization overhead per message.
        return max(1, (contentCharacters + toolArgumentCharacters + 3) / 4) + 12
    }

    /// The durable transcript always keeps the exact request. This final pass
    /// only bounds the ephemeral provider copy when the newest user turn alone
    /// is larger than a small local model's usable context window.
    private static func compactPinnedUserIfNeeded(
        _ messages: [ProviderMessageInput],
        latestUserID: UUID?,
        maximumEstimatedTokens: Int
    ) -> [ProviderMessageInput] {
        guard let latestUserID,
              let userIndex = messages.firstIndex(where: { $0.id == latestUserID }),
              estimatedTokenCount(messages) > maximumEstimatedTokens else {
            return messages
        }

        let latestUser = messages[userIndex]
        let otherMessages = messages.enumerated().compactMap { index, message in
            index == userIndex ? nil : message
        }
        let availableUserTokens = maximumEstimatedTokens - estimatedTokenCount(otherMessages)

        // Every serialized message has a small fixed role/JSON overhead. An
        // impossibly tiny synthetic budget cannot represent even one message;
        // production budgets are hundreds of tokens or more.
        guard availableUserTokens > 12 else { return [] }

        let maximumCharacters = max(1, (availableUserTokens - 12) * 4)
        guard latestUser.content.count > maximumCharacters else { return messages }

        var compacted = messages
        compacted[userIndex] = ProviderMessageInput(
            id: latestUser.id,
            role: latestUser.role,
            content: compactPinnedUserContent(latestUser.content, maximumCharacters: maximumCharacters),
            createdAt: latestUser.createdAt,
            toolCallID: latestUser.toolCallID,
            toolCalls: latestUser.toolCalls
        )
        return compacted
    }

    private static func compactPinnedUserContent(_ content: String, maximumCharacters: Int) -> String {
        guard content.count > maximumCharacters else { return content }
        let marker = "\n\n[NovaForge shortened this provider copy to fit the current model; the full request remains in chat.]\n\n"
        guard maximumCharacters > marker.count + 32 else {
            return String(content.prefix(maximumCharacters))
        }

        let contentBudget = maximumCharacters - marker.count
        let headCount = max(16, Int(Double(contentBudget) * 0.72))
        let tailCount = max(1, contentBudget - headCount)
        return "\(content.prefix(headCount))\(marker)\(content.suffix(tailCount))"
    }

    private static func groupNewestDate(_ group: [ProviderMessageInput]) -> Date {
        group.map(\.createdAt).max() ?? .distantPast
    }

    private static func messageAscending(_ lhs: ProviderMessageInput, _ rhs: ProviderMessageInput) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
