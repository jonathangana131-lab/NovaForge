import Foundation

struct ProviderMessageInput: Sendable {
    let id: UUID
    let role: ChatRole
    let content: String
    let createdAt: Date
    let toolCallID: String?
    let toolCalls: [APIToolCall]
    let reasoningContent: String?
}

struct ProviderChatMessage: Equatable, Sendable {
    let role: String
    let content: String?
    let toolCallID: String?
    let toolCalls: [APIToolCall]?
    let reasoningContent: String?

    var roleLogDescription: String {
        switch role {
        case "assistant":
            if let toolCalls, !toolCalls.isEmpty {
                return "assistant(tool_calls:\(toolCalls.count))"
            }
            return "assistant"
        case "tool":
            return "tool(\(toolCallID ?? "missing-id"))"
        default:
            return role
        }
    }
}

struct ProviderMessageDrop: Equatable, Sendable {
    let id: UUID
    let role: String
    let reason: String
}

struct SanitizedProviderTranscript: Sendable {
    let messages: [ProviderChatMessage]
    let droppedMessages: [ProviderMessageDrop]

    var roleLog: String {
        messages.map(\.roleLogDescription).joined(separator: " -> ")
    }
}

enum ProviderMessageValidationIssue: Equatable, Sendable {
    case toolWithoutAssistant(index: Int)
    case toolMissingID(index: Int)
    case toolIDNotRequested(index: Int, id: String)
    case incompleteToolCalls(index: Int)
}

enum ProviderMessageSanitizer {
    private static let maxSystemContentCharacters = 18_000
    private static let maxUserContentCharacters = 12_000
    private static let maxAssistantContentCharacters = 12_000
    private static let maxToolContentCharacters = 6_000
    private static let maxToolArgumentsCharacters = 4_000

    static func sanitize(systemPrompt: String, history: [ProviderMessageInput]) -> SanitizedProviderTranscript {
        var messages = [
            ProviderChatMessage(
                role: "system",
                content: Self.compactProviderContent(systemPrompt, label: "system prompt", limit: maxSystemContentCharacters),
                toolCallID: nil,
                toolCalls: nil,
                reasoningContent: nil
            )
        ]
        var dropped: [ProviderMessageDrop] = []
        let ordered = history.sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.createdAt < rhs.createdAt
        }

        var index = ordered.startIndex
        while index < ordered.endIndex {
            let input = ordered[index]
            switch input.role {
            case .system:
                dropped.append(.init(id: input.id, role: input.role.rawValue, reason: "system messages are rebuilt from current settings"))
                index = ordered.index(after: index)

            case .user:
                let content = input.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if content.isEmpty {
                    dropped.append(.init(id: input.id, role: input.role.rawValue, reason: "empty user message"))
                } else {
                    messages.append(.init(
                        role: "user",
                        content: Self.compactProviderContent(content, label: "user message", limit: maxUserContentCharacters),
                        toolCallID: nil,
                        toolCalls: nil,
                        reasoningContent: nil
                    ))
                }
                index = ordered.index(after: index)

            case .assistant:
                if input.toolCalls.isEmpty {
                    let content = input.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    if content.isEmpty {
                        dropped.append(.init(id: input.id, role: input.role.rawValue, reason: "empty assistant message"))
                    } else {
                        messages.append(.init(
                            role: "assistant",
                            content: Self.compactProviderContent(content, label: "assistant message", limit: maxAssistantContentCharacters),
                            toolCallID: nil,
                            toolCalls: nil,
                            reasoningContent: Self.compactOptionalReasoningContent(input.reasoningContent)
                        ))
                    }
                    index = ordered.index(after: index)
                } else {
                    let requiredIDs = Set(input.toolCalls.map(\.id))
                    var matchedTools: [ProviderChatMessage] = []
                    var matchedIDs = Set<String>()
                    var toolDrops: [ProviderMessageDrop] = []
                    var scan = ordered.index(after: index)

                    while scan < ordered.endIndex, ordered[scan].role == .tool {
                        let tool = ordered[scan]
                        if let toolCallID = tool.toolCallID, requiredIDs.contains(toolCallID), !matchedIDs.contains(toolCallID) {
                            matchedIDs.insert(toolCallID)
                            matchedTools.append(.init(
                                role: "tool",
                                content: Self.compactProviderContent(tool.content, label: "tool result", limit: maxToolContentCharacters),
                                toolCallID: toolCallID,
                                toolCalls: nil,
                                reasoningContent: nil
                            ))
                        } else {
                            toolDrops.append(.init(
                                id: tool.id,
                                role: tool.role.rawValue,
                                reason: "tool result does not match the preceding assistant tool_calls"
                            ))
                        }
                        scan = ordered.index(after: scan)
                    }

                    if matchedIDs == requiredIDs {
                        messages.append(.init(
                            role: "assistant",
                            content: Self.compactOptionalAssistantContent(input.content),
                            toolCallID: nil,
                            toolCalls: Self.compactToolCallsForProvider(input.toolCalls),
                            reasoningContent: Self.compactOptionalReasoningContent(input.reasoningContent)
                        ))
                        messages.append(contentsOf: matchedTools)
                        dropped.append(contentsOf: toolDrops)
                    } else {
                        dropped.append(.init(
                            id: input.id,
                            role: input.role.rawValue,
                            reason: "assistant tool_calls were not fully answered before the next chat message"
                        ))
                        dropped.append(contentsOf: toolDrops)
                    }
                    index = scan
                }

            case .tool:
                dropped.append(.init(id: input.id, role: input.role.rawValue, reason: "orphan tool result without preceding assistant tool_calls"))
                index = ordered.index(after: index)
            }
        }

        return SanitizedProviderTranscript(
            messages: compactForProvider(messages),
            droppedMessages: dropped
        )
    }

    private static func compactOptionalAssistantContent(_ content: String) -> String? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return compactProviderContent(trimmed, label: "assistant tool-call message", limit: maxAssistantContentCharacters)
    }

    private static func compactOptionalReasoningContent(_ content: String?) -> String? {
        guard let content else { return nil }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return compactProviderContent(trimmed, label: "assistant reasoning replay", limit: maxAssistantContentCharacters)
    }

    private static func compactProviderContent(_ content: String, label: String, limit: Int) -> String {
        guard content.count > limit else { return content }
        let note = "\n\n[NovaForge compacted this \(label) for the provider payload; the full text stays in the chat, Runs history, and workspace files.]\n\n"
        let budget = max(512, limit - note.count)
        let headCount = max(256, Int(Double(budget) * 0.72))
        let tailCount = max(128, budget - headCount)
        let omitted = max(0, content.count - headCount - tailCount)
        return "\(content.prefix(headCount))\(note)--- \(omitted) characters omitted ---\n\(content.suffix(tailCount))"
    }

    private static func compactToolCallsForProvider(_ toolCalls: [APIToolCall]) -> [APIToolCall] {
        toolCalls.map { call in
            let compactedArguments = compactToolArguments(call.function.arguments, toolName: call.function.name)
            guard compactedArguments != call.function.arguments else { return call }
            return APIToolCall(
                id: call.id,
                type: call.type,
                function: APIFunctionCall(name: call.function.name, arguments: compactedArguments)
            )
        }
    }

    private static func compactToolArguments(_ arguments: String, toolName: String) -> String {
        guard arguments.count > maxToolArgumentsCharacters else { return arguments }

        if let data = arguments.data(using: .utf8),
           var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            var changed = false
            for key in ["contents", "content", "text", "replacement", "new_string", "old_string"] {
                guard let value = object[key] as? String, value.count > 1_200 else { continue }
                object[key] = compactProviderContent(value, label: "\(toolName).\(key) argument", limit: 1_200)
                changed = true
            }
            if changed,
               JSONSerialization.isValidJSONObject(object),
               let compactedData = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
               let compacted = String(data: compactedData, encoding: .utf8),
               compacted.count <= maxToolArgumentsCharacters {
                return compacted
            }

            let preserved = ["path", "from", "to", "command", "query", "pattern", "file"]
                .reduce(into: [String: Any]()) { partial, key in
                    if let value = object[key] as? String {
                        partial[key] = Self.compactProviderContent(
                            value,
                            label: "\(toolName).\(key) argument",
                            limit: 900
                        )
                    }
                }
            var fallback = preserved
            fallback["__novaforge_compacted_arguments"] = "\(toolName) arguments were too large for provider history; full arguments remain in the local chat/tool run record."
            fallback["preview"] = compactProviderContent(arguments, label: "\(toolName) arguments", limit: 1_200)
            if JSONSerialization.isValidJSONObject(fallback),
               let fallbackData = try? JSONSerialization.data(withJSONObject: fallback, options: [.sortedKeys, .withoutEscapingSlashes]),
               let encodedFallback = String(data: fallbackData, encoding: .utf8),
               encodedFallback.count <= maxToolArgumentsCharacters {
                return encodedFallback
            }
        }

        return "{\"__novaforge_compacted_arguments\":\"\(toolName) arguments were too large for provider history; full arguments remain in local app history.\",\"preview\":\"\(jsonEscaped(compactProviderContent(arguments, label: "\(toolName) arguments", limit: 1_200)))\"}"
    }

    private static func jsonEscaped(_ string: String) -> String {
        let data = try? JSONEncoder().encode(string)
        let encoded = data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        return String(encoded.dropFirst().dropLast())
    }

    private static func compactForProvider(_ messages: [ProviderChatMessage]) -> [ProviderChatMessage] {
        let maxProviderMessages = 72
        guard messages.count > maxProviderMessages, let system = messages.first else {
            return messages
        }

        var kept = Array(messages.dropFirst().suffix(maxProviderMessages - 1))
        while kept.first?.role == "tool" {
            kept.removeFirst()
        }

        while let first = kept.first,
              first.role == "assistant",
              let toolCalls = first.toolCalls,
              !toolCalls.isEmpty,
              !hasCompleteToolResults(for: toolCalls, in: kept.dropFirst()) {
            kept.removeFirst()
        }

        let droppedCount = max(0, messages.count - 1 - kept.count)
        let compactedSystemContent = """
        \(system.content ?? "")

        Runtime note: NovaForge compacted \(droppedCount) older provider messages to keep the app responsive. Continue from the visible recent conversation and tool results. If more detail is needed, inspect files with tools instead of relying on old transcript text.
        """

        let compactedSystem = ProviderChatMessage(
            role: system.role,
            content: compactedSystemContent,
            toolCallID: nil,
            toolCalls: nil,
            reasoningContent: nil
        )
        return [compactedSystem] + kept
    }

    private static func hasCompleteToolResults(
        for toolCalls: [APIToolCall],
        in followingMessages: ArraySlice<ProviderChatMessage>
    ) -> Bool {
        var neededIDs = Set(toolCalls.map(\.id))
        for message in followingMessages {
            guard message.role == "tool" else { break }
            if let toolCallID = message.toolCallID {
                neededIDs.remove(toolCallID)
            }
            if neededIDs.isEmpty {
                return true
            }
        }
        return neededIDs.isEmpty
    }

    // Providers such as DeepSeek reject any `tool` role message that is not part of
    // an immediately coherent assistant tool_calls exchange. This validator keeps
    // the provider transcript strict while allowing the app to keep richer UI logs.
    static func validate(_ messages: [ProviderChatMessage]) -> [ProviderMessageValidationIssue] {
        var issues: [ProviderMessageValidationIssue] = []
        var pendingToolIDs = Set<String>()
        var assistantToolCallIndex: Int?

        for (index, message) in messages.enumerated() {
            if message.role == "assistant", let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                if !pendingToolIDs.isEmpty, let assistantToolCallIndex {
                    issues.append(.incompleteToolCalls(index: assistantToolCallIndex))
                }
                pendingToolIDs = Set(toolCalls.map(\.id))
                assistantToolCallIndex = index
                continue
            }

            if message.role == "tool" {
                guard !pendingToolIDs.isEmpty else {
                    issues.append(.toolWithoutAssistant(index: index))
                    continue
                }
                guard let toolCallID = message.toolCallID else {
                    issues.append(.toolMissingID(index: index))
                    continue
                }
                guard pendingToolIDs.contains(toolCallID) else {
                    issues.append(.toolIDNotRequested(index: index, id: toolCallID))
                    continue
                }
                pendingToolIDs.remove(toolCallID)
                if pendingToolIDs.isEmpty {
                    assistantToolCallIndex = nil
                }
                continue
            }

            if !pendingToolIDs.isEmpty {
                if let assistantToolCallIndex {
                    issues.append(.incompleteToolCalls(index: assistantToolCallIndex))
                }
                pendingToolIDs.removeAll()
                assistantToolCallIndex = nil
            }
        }

        if !pendingToolIDs.isEmpty, let assistantToolCallIndex {
            issues.append(.incompleteToolCalls(index: assistantToolCallIndex))
        }

        return issues
    }
}

extension ChatMessage {
    var providerInput: ProviderMessageInput {
        ProviderMessageInput(
            id: id,
            role: role,
            content: content,
            createdAt: createdAt,
            toolCallID: toolCallID,
            toolCalls: toolCalls ?? [],
            reasoningContent: reasoningContent
        )
    }
}
