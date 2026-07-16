import Foundation
import OSLog

/// Private logger for provider/transcript diagnostics. Uses `.debug` so the
/// information is available in Console.app during development and QA but never
/// written to a release user's stdout/console.
private let providerLogger = Logger(subsystem: "com.joey.NovaForge", category: "provider")

struct AIProviderClient {
    var configuration: ProviderConfiguration
    var session: URLSession = .agentProvider

    func response(
        messages: [ProviderMessageInput],
        model: String,
        temperature: Double,
        customSystemPrompt: String?,
        workspaceSummary: String
    ) async throws -> ProviderResponse {
        guard let url = configuration.chatCompletionsURL else {
            throw OpenAIError.requestFailed("The provider endpoint URL is invalid.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if configuration.provider == .openRouter {
            request.setValue("NovaForge", forHTTPHeaderField: "X-Title")
        }

        let sanitizedTranscript = try preparedTranscript(
            messages: messages,
            customSystemPrompt: customSystemPrompt,
            workspaceSummary: workspaceSummary
        )

        let apiMessages = sanitizedTranscript.messages.map(\.chatCompletionsMessage)

        let body = ChatCompletionsRequest(
            model: model,
            messages: apiMessages,
            tools: ChatCompletionsRequest.toolsList,
            temperature: supportsTemperature(model: model) ? temperature : nil
        )
        
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw OpenAIError.requestFailed(
                OpenAIError.providerFailureMessage(data: data, fallback: "Unknown OpenAI error")
            )
        }
        
        let decoded = try JSONDecoder().decode(ChatCompletionsResponse.self, from: data)
        guard let choiceMessage = decoded.choices?.first?.message else {
            throw OpenAIError.requestFailed("No response choices returned.")
        }
        try ToolCallArgumentValidator.validate(
            choiceMessage.tool_calls,
            sourceDescription: "provider response"
        )
        
        return ProviderResponse(message: choiceMessage, roleLog: sanitizedTranscript.roleLog)
    }

    func streamingResponse(
        messages: [ProviderMessageInput],
        model: String,
        temperature: Double,
        customSystemPrompt: String?,
        workspaceSummary: String,
        onContentBatch: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> ProviderResponse {
        guard let url = configuration.chatCompletionsURL else {
            throw OpenAIError.requestFailed("The provider endpoint URL is invalid.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if configuration.provider == .openRouter {
            request.setValue("NovaForge", forHTTPHeaderField: "X-Title")
        }

        let sanitizedTranscript = try preparedTranscript(
            messages: messages,
            customSystemPrompt: customSystemPrompt,
            workspaceSummary: workspaceSummary
        )

        let apiMessages = sanitizedTranscript.messages.map(\.chatCompletionsMessage)
        var body = ChatCompletionsRequest(
            model: model,
            messages: apiMessages,
            tools: ChatCompletionsRequest.toolsList,
            temperature: supportsTemperature(model: model) ? temperature : nil
        )
        body.stream = true

        request.httpBody = try JSONEncoder().encode(body)

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            var message = ""
            for try await line in bytes.lines {
                if message.count < OpenAIError.maxProviderFailureBodyCharacters {
                    message += line
                    message += "\n"
                }
                if message.count >= OpenAIError.maxProviderFailureBodyCharacters {
                    break
                }
            }
            throw OpenAIError.requestFailed(
                OpenAIError.providerFailureMessage(
                    rawText: message,
                    fallback: "Unknown streaming provider error"
                )
            )
        }

        let decoded = try await decodeStreamingResponse(from: bytes, onContentBatch: onContentBatch)
        return ProviderResponse(message: decoded, roleLog: sanitizedTranscript.roleLog)
    }

    func testConnection(model: String) async throws {
        guard let url = configuration.chatCompletionsURL else {
            throw OpenAIError.requestFailed("The provider endpoint URL is invalid.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if configuration.provider == .openRouter {
            request.setValue("NovaForge", forHTTPHeaderField: "X-Title")
        }

        let apiMessages = [
            ChatCompletionsRequest.Message(
                role: "user",
                content: "ping",
                name: nil,
                tool_call_id: nil,
                tool_calls: nil
            )
        ]

        let body = ChatCompletionsRequest(
            model: model,
            messages: apiMessages,
            tools: nil,
            temperature: supportsTemperature(model: model) ? 0.0 : nil
        )
        
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw OpenAIError.requestFailed(
                OpenAIError.providerFailureMessage(data: data, fallback: "Unknown connection error")
            )
        }
        
        _ = try JSONDecoder().decode(ChatCompletionsResponse.self, from: data)
    }

    func listModels() async throws -> [String] {
        try await modelCatalog().map(\.id)
    }

    func modelCatalog() async throws -> [ProviderModelCatalogEntry] {
        guard let url = configuration.modelsURL else {
            return configuration.provider.modelOptions.map {
                ProviderModelCatalogEntry(
                    id: $0,
                    displayName: configuration.provider.modelDisplayName($0),
                    supportedReasoningEfforts: configuration.provider
                        .fallbackReasoningEfforts($0)
                )
            }
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        }
        if configuration.provider == .openAICodex {
            request.setValue("novaforge_ios", forHTTPHeaderField: "originator")
            request.setValue("NovaForge/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
            if let accountID = Self.chatGPTAccountID(fromJWT: configuration.apiKey) {
                request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-ID")
            }
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw OpenAIError.requestFailed(
                OpenAIError.providerFailureMessage(data: data, fallback: "Could not load models.")
            )
        }

        return try ProviderModelCatalogParser.parse(
            data,
            provider: configuration.provider
        )
    }

    private static func chatGPTAccountID(fromJWT token: String) -> String? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64), data.count <= 64 * 1_024,
              let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let auth = object["https://api.openai.com/auth"]
                as? [String: Any],
              let accountID = auth["chatgpt_account_id"] as? String,
              (1 ... 512).contains(accountID.utf8.count)
        else { return nil }
        return accountID
    }

    private func supportsTemperature(model: String) -> Bool {
        let lower = model.lowercased()
        if configuration.provider == .openAICodex { return false }
        if lower.hasPrefix("o") && lower.dropFirst().first?.isNumber == true { return false }
        if lower.contains("reasoning") { return false }
        return true
    }

    private func preparedTranscript(
        messages: [ProviderMessageInput],
        customSystemPrompt: String?,
        workspaceSummary: String
    ) throws -> SanitizedProviderTranscript {
        let transcript: SanitizedProviderTranscript
        do {
            transcript = try ProviderContextWindow.prepareHostedTranscript(
                history: messages,
                customSystemPrompt: customSystemPrompt,
                workspaceSummary: workspaceSummary
            )
        } catch {
            throw OpenAIError.requestFailed(
                "The provider message history is invalid after cleanup. Clear the current run state and retry."
            )
        }
        if !transcript.droppedMessages.isEmpty {
            let reasons = transcript.droppedMessages
                .map { "\($0.role): \($0.reason)" }
                .joined(separator: "; ")
            providerLogger.debug(
                "Provider transcript sanitizer dropped \(transcript.droppedMessages.count, privacy: .public) message(s): \(reasons, privacy: .public)"
            )
        }
        providerLogger.debug(
            "Outgoing provider message roles: \(transcript.roleLog, privacy: .public)"
        )
        return transcript
    }
}

struct ProviderModelCatalogEntry: Equatable, Identifiable, Sendable {
    let id: String
    let displayName: String?
    let supportedReasoningEfforts: [String]

    init(
        id: String,
        displayName: String? = nil,
        supportedReasoningEfforts: [String] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.supportedReasoningEfforts = supportedReasoningEfforts
    }
}

enum ProviderModelCatalogParser {
    static func parse(
        _ data: Data,
        provider: AIProvider
    ) throws -> [ProviderModelCatalogEntry] {
        guard data.count <= 4 * 1_024 * 1_024,
              let root = try JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let rawModels = (root["data"] ?? root["models"]) as? [Any]
        else {
            throw OpenAIError.requestFailed("The provider returned an invalid model catalog.")
        }

        var seen = Set<String>()
        var result: [ProviderModelCatalogEntry] = []
        for rawModel in rawModels.prefix(2_000) {
            guard let model = rawModel as? [String: Any],
                  let rawID = (model["id"] ?? model["slug"] ?? model["model"]) as? String
            else { continue }
            let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isSafeModelID(id), seen.insert(id).inserted else { continue }
            if provider == .openAICodex, !isSupportedChatGPTModelID(id) {
                continue
            }
            result.append(
                ProviderModelCatalogEntry(
                    id: id,
                    displayName: safeDisplayName(
                        model["display_name"] ?? model["displayName"] ?? model["name"]
                    ),
                    supportedReasoningEfforts: reasoningEfforts(
                        model["supported_reasoning_efforts"]
                            ?? model["supportedReasoningEfforts"]
                            ?? model["reasoning_efforts"]
                    )
                )
            )
        }
        guard !result.isEmpty else {
            throw OpenAIError.requestFailed("The provider returned no compatible agent models.")
        }
        return result
    }

    private static func reasoningEfforts(_ raw: Any?) -> [String] {
        guard let rawValues = raw as? [Any] else { return [] }
        let accepted = Set(["none", "low", "medium", "high", "xhigh", "max"])
        var seen = Set<String>()
        return rawValues.compactMap { rawValue in
            let value: String?
            if let string = rawValue as? String {
                value = string
            } else if let object = rawValue as? [String: Any] {
                value = (object["reasoning_effort"]
                    ?? object["reasoningEffort"]
                    ?? object["effort"]) as? String
            } else {
                value = nil
            }
            guard let normalized = value?.lowercased(),
                  accepted.contains(normalized),
                  seen.insert(normalized).inserted
            else { return nil }
            return normalized
        }
    }

    private static func safeDisplayName(_ raw: Any?) -> String? {
        guard let value = raw as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1 ... 160).contains(trimmed.utf8.count),
              !trimmed.unicodeScalars.contains(where: { $0.value == 0 })
        else { return nil }
        return trimmed
    }

    private static func isSafeModelID(_ value: String) -> Bool {
        guard (1 ... 200).contains(value.utf8.count) else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (
                CharacterSet.alphanumerics.contains(scalar)
                    || "-._/:".unicodeScalars.contains(scalar)
            )
        }
    }

    private static func isSupportedChatGPTModelID(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.hasPrefix("gpt-5") && !lower.contains("codex")
    }
}

struct ProviderResponse: Sendable {
    let message: ChatCompletionsResponse.Choice.Message
    let roleLog: String
}

private struct StreamingToolCallPart {
    var id = ""
    var type = "function"
    var name = ""
    var arguments = ""

    func makeToolCall(index: Int) -> APIToolCall? {
        guard !name.isEmpty else { return nil }
        return APIToolCall(
            id: id.isEmpty ? "stream-tool-\(index)" : id,
            type: type.isEmpty ? "function" : type,
            function: APIFunctionCall(name: name, arguments: arguments)
        )
    }
}

enum OpenAIError: LocalizedError {
    case requestFailed(String)

    static let maxProviderFailureBodyCharacters = 8_000
    private static let maxProviderFailureMessageCharacters = 1_400

    var errorDescription: String? {
        switch self {
        case .requestFailed(let message):
            message
        }
    }

    static func providerFailureMessage(data: Data, fallback: String) -> String {
        let rawText = String(data: data, encoding: .utf8) ?? ""
        return providerFailureMessage(rawText: rawText, fallback: fallback)
    }

    static func providerFailureMessage(rawText: String, fallback: String) -> String {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseMessage = trimmed.isEmpty ? fallback : trimmed
        let redacted = redactSensitiveProviderText(baseMessage)
        guard redacted.count > maxProviderFailureMessageCharacters else {
            return redacted
        }

        let note = "\n\n[NovaForge shortened this provider error; the raw response was too large to show safely.]\n\n"
        let budget = maxProviderFailureMessageCharacters - note.count
        let headCount = max(320, Int(Double(budget) * 0.70))
        let tailCount = max(160, budget - headCount)
        return "\(redacted.prefix(headCount))\(note)--- \(max(0, redacted.count - headCount - tailCount)) characters omitted ---\n\(redacted.suffix(tailCount))"
    }

    private static func redactSensitiveProviderText(_ text: String) -> String {
        var output = text
        let patterns: [(String, String)] = [
            (#"sk-[A-Za-z0-9_\-]{12,}"#, "sk-…redacted"),
            (#"(?i)(authorization\s*[:=]\s*bearer\s+)[^\s\"']+"#, "$1…redacted"),
            (#"(?i)(api[_-]?key\s*[:=]\s*)[^\s\"',}]+"#, "$1…redacted")
        ]
        for (pattern, replacement) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(output.startIndex..<output.endIndex, in: output)
            output = regex.stringByReplacingMatches(in: output, range: range, withTemplate: replacement)
        }
        return output
    }
}

private extension URLSession {
    static let agentProvider: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 180
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
    }()
}

struct ChatCompletionsRequest: Encodable, Sendable {
    struct Message: Encodable, Sendable {
        let role: String
        let content: String?
        let name: String?
        let tool_call_id: String?
        let tool_calls: [APIToolCall]?
    }

    struct ToolDefinition: Encodable, Sendable {
        struct Function: Encodable, Sendable {
            let name: String
            let description: String
            let parameters: ParameterDefinition
        }
        let type: String = "function"
        let function: Function
    }

    struct ParameterDefinition: Encodable, Sendable {
        let type: String = "object"
        let properties: [String: PropertyDefinition]
        let required: [String]
    }

    struct PropertyDefinition: Encodable, Sendable {
        let type: String
        let description: String
    }

    let model: String
    let messages: [Message]
    let tools: [ToolDefinition]?
    let temperature: Double?
    var stream: Bool? = nil
}

extension ChatCompletionsRequest {
    static let toolsList: [ToolDefinition] = [
        .init(function: .init(
            name: "list_directory",
            description: "List the contents of a directory. Returns relative paths and whether each is a folder or file.",
            parameters: .init(
                properties: [
                    "path": .init(type: "string", description: "The relative path to list. Use empty string for root directory.")
                ],
                required: []
            )
        )),
        .init(function: .init(
            name: "read_file",
            description: "Read the complete UTF-8 contents of a file in the workspace.",
            parameters: .init(
                properties: [
                    "path": .init(type: "string", description: "The relative path of the file to read.")
                ],
                required: ["path"]
            )
        )),
        .init(function: .init(
            name: "write_file",
            description: "Write content to a file in the workspace. Overwrites existing files, or creates new files and directories if needed.",
            parameters: .init(
                properties: [
                    "path": .init(type: "string", description: "The relative path of the file to write."),
                    "contents": .init(type: "string", description: "The text contents to write to the file.")
                ],
                required: ["path", "contents"]
            )
        )),
        .init(function: .init(
            name: "append_file",
            description: "Append text contents to an existing file in the workspace.",
            parameters: .init(
                properties: [
                    "path": .init(type: "string", description: "The relative path of the file to append to."),
                    "contents": .init(type: "string", description: "The text contents to append.")
                ],
                required: ["path", "contents"]
            )
        )),
        .init(function: .init(
            name: "delete_path",
            description: "Permanently delete a file or directory at the specified workspace path.",
            parameters: .init(
                properties: [
                    "path": .init(type: "string", description: "The relative path to delete.")
                ],
                required: ["path"]
            )
        )),
        .init(function: .init(
            name: "move_path",
            description: "Move or rename a file or directory in the workspace.",
            parameters: .init(
                properties: [
                    "from": .init(type: "string", description: "The relative source path."),
                    "to": .init(type: "string", description: "The relative destination path.")
                ],
                required: ["from", "to"]
            )
        )),
        .init(function: .init(
            name: "copy_path",
            description: "Copy a file or directory to a new path in the workspace.",
            parameters: .init(
                properties: [
                    "from": .init(type: "string", description: "The relative source path."),
                    "to": .init(type: "string", description: "The relative destination path.")
                ],
                required: ["from", "to"]
            )
        )),
        .init(function: .init(
            name: "make_directory",
            description: "Create a new directory (folder) in the workspace.",
            parameters: .init(
                properties: [
                    "path": .init(type: "string", description: "The relative path of the folder to create.")
                ],
                required: ["path"]
            )
        )),
        .init(function: .init(
            name: "search_text",
            description: "Search for a query text pattern recursively within files in the workspace (grep).",
            parameters: .init(
                properties: [
                    "query": .init(type: "string", description: "The text search query."),
                    "path": .init(type: "string", description: "Optional relative path of directory to search within.")
                ],
                required: ["query"]
            )
        )),
        .init(function: .init(
            name: "list_tree",
            description: "Show a recursive workspace tree with indentation. Use this to understand project structure before editing.",
            parameters: .init(
                properties: [
                    "max_depth": .init(type: "string", description: "Optional max folder depth, default 5."),
                    "max_items": .init(type: "string", description: "Optional max rows, default 250.")
                ],
                required: []
            )
        )),
        .init(function: .init(
            name: "workspace_summary",
            description: "Summarize file/folder counts, total bytes, and common file types in the workspace.",
            parameters: .init(
                properties: [
                    "max_items": .init(type: "string", description: "Optional max files to inspect, default 800.")
                ],
                required: []
            )
        )),
        .init(function: .init(
            name: "file_info",
            description: "Get metadata for one file or folder: kind, byte size, created date, and modified date.",
            parameters: .init(
                properties: [
                    "path": .init(type: "string", description: "Relative file or folder path.")
                ],
                required: ["path"]
            )
        )),
        .init(function: .init(
            name: "read_file_range",
            description: "Read a specific line range with line numbers instead of loading a whole file.",
            parameters: .init(
                properties: [
                    "path": .init(type: "string", description: "Relative file path."),
                    "start_line": .init(type: "string", description: "1-based line to start at."),
                    "line_count": .init(type: "string", description: "Number of lines to read, default 80.")
                ],
                required: ["path"]
            )
        )),
        .init(function: .init(
            name: "tail_file",
            description: "Read the last lines of a log or source file with line numbers.",
            parameters: .init(
                properties: [
                    "path": .init(type: "string", description: "Relative file path."),
                    "line_count": .init(type: "string", description: "Number of trailing lines, default 60.")
                ],
                required: ["path"]
            )
        )),
        .init(function: .init(
            name: "replace_text",
            description: "Safely replace exact text inside a file. Refuses ambiguous multiple matches unless replace_all=true.",
            parameters: .init(
                properties: [
                    "path": .init(type: "string", description: "Relative file path."),
                    "old": .init(type: "string", description: "Exact text to replace."),
                    "new": .init(type: "string", description: "Replacement text."),
                    "replace_all": .init(type: "string", description: "true to replace every match; default false.")
                ],
                required: ["path", "old", "new"]
            )
        )),
        .init(function: .init(
            name: "diff_files",
            description: "Compare two workspace text files and return a compact line-oriented diff.",
            parameters: .init(
                properties: [
                    "left": .init(type: "string", description: "Original/left relative path."),
                    "right": .init(type: "string", description: "New/right relative path.")
                ],
                required: ["left", "right"]
            )
        )),
        .init(function: .init(
            name: "validate_json",
            description: "Validate that a workspace file is parseable JSON and report the parse error if not.",
            parameters: .init(
                properties: [
                    "path": .init(type: "string", description: "Relative JSON file path.")
                ],
                required: ["path"]
            )
        )),
        .init(function: .init(
            name: "validate_html_file",
            description: "Run NovaForge's HTML readiness checks before previewing. Use profile=game for canvas/playable games and profile=page for landing pages or websites.",
            parameters: .init(
                properties: [
                    "path": .init(type: "string", description: "Relative HTML file path."),
                    "profile": .init(type: "string", description: "Optional: page, game, or auto. Defaults to auto.")
                ],
                required: ["path"]
            )
        )),
        .init(function: .init(
            name: "extract_outline",
            description: "Extract code/document outline lines such as Swift types/functions, JS functions/constants, and Markdown headings.",
            parameters: .init(
                properties: [
                    "path": .init(type: "string", description: "Relative file path.")
                ],
                required: ["path"]
            )
        )),
        .init(function: .init(
            name: "run_command",
            description: "Run a simple sandbox command. Available: pwd, ls, cat, mkdir, touch, rm, mv, cp, grep, find, wc, head, validate_html. Prefer dedicated tools for reading ranges, metadata, diffs, JSON validation, and text replacement. Shell operators like |, >, && are forbidden.",
            parameters: .init(
                properties: [
                    "command": .init(type: "string", description: "The command to run, e.g., 'find .', 'head -n 40 index.html', 'wc index.html', or 'validate_html game.html'.")
                ],
                required: ["command"]
            )
        ))
    ]
}

struct ChatCompletionsResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable, Sendable {
            let role: String
            let content: String?
            let tool_calls: [APIToolCall]?
        }
        let message: Message?
    }

    let choices: [Choice]?
}

private struct ChatCompletionsStreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            struct ToolCall: Decodable {
                struct Function: Decodable {
                    let name: String?
                    let arguments: String?
                }

                let index: Int?
                let id: String?
                let type: String?
                let function: Function?
            }

            let role: String?
            let content: String?
            let tool_calls: [ToolCall]?
        }

        let delta: Delta?
        let finish_reason: String?
    }

    let choices: [Choice]?
}

struct StreamingResponseValidator {
    static func makeMessage(
        content: String,
        toolCalls: [APIToolCall],
        sawDataPayload: Bool,
        malformedPayloadCount: Int,
        sawDone: Bool = true
    ) throws -> ChatCompletionsResponse.Choice.Message {
        guard sawDone else {
            throw OpenAIError.requestFailed("The provider stream ended before the completion marker. Retry or switch providers.")
        }
        guard malformedPayloadCount == 0 else {
            if content.isEmpty && toolCalls.isEmpty {
                throw OpenAIError.requestFailed("The provider stream contained malformed data and no usable response. Retry or switch providers.")
            }
            throw OpenAIError.requestFailed("The provider stream contained malformed data after a partial response. Retry so NovaForge does not save incomplete output.")
        }
        try ToolCallArgumentValidator.validate(
            toolCalls,
            sourceDescription: "provider stream"
        )
        guard !content.isEmpty || !toolCalls.isEmpty else {
            if sawDataPayload {
                throw OpenAIError.requestFailed("The provider stream ended without content or tool calls. Retry or switch providers.")
            }
            throw OpenAIError.requestFailed("The provider stream was empty. Retry or switch providers.")
        }

        return ChatCompletionsResponse.Choice.Message(
            role: "assistant",
            content: content.isEmpty ? nil : content,
            tool_calls: toolCalls.isEmpty ? nil : toolCalls
        )
    }
}

struct ToolCallArgumentValidator {
    static func validate(
        _ toolCalls: [APIToolCall]?,
        sourceDescription: String
    ) throws {
        for call in toolCalls ?? [] {
            let arguments = call.function.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !arguments.isEmpty else { continue }
            guard let data = arguments.data(using: .utf8) else {
                throw OpenAIError.requestFailed("The \(sourceDescription) ended with incomplete tool-call arguments. Retry before running tools.")
            }

            let decoded: Any
            do {
                decoded = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            } catch {
                throw OpenAIError.requestFailed("The \(sourceDescription) ended with incomplete tool-call arguments. Retry before running tools.")
            }

            guard decoded is [String: Any] else {
                throw OpenAIError.requestFailed("The \(sourceDescription) returned tool-call arguments that were not a JSON object. Retry before running tools.")
            }
            try validateFlatArgumentObject(decoded, sourceDescription: sourceDescription)
        }
    }

    static func validateFlatArgumentObject(_ decoded: Any, sourceDescription: String) throws {
        guard let object = decoded as? [String: Any] else {
            throw OpenAIError.requestFailed("The \(sourceDescription) returned tool-call arguments that were not a JSON object. Retry before running tools.")
        }
        for (key, value) in object {
            if value is [String: Any] || value is [Any] || value is NSNull {
                throw OpenAIError.requestFailed("The \(sourceDescription) returned tool-call argument `\(key)` with nested arrays or objects. Retry before running tools.")
            }
        }
    }
}

struct StreamingResponseDecoder {
    private static let maxStreamedContentBytes = 256 * 1024
    private static let maxStreamedToolArgumentBytes = 512 * 1024
    private static let maxStreamedToolCalls = 32

    private let decoder = JSONDecoder()
    private var content = ""
    private var pendingContent = ""
    private var lastDelivery = ContinuousClock.now
    private var toolParts: [Int: StreamingToolCallPart] = [:]
    private var streamedContentBytes = 0
    private var streamedToolArgumentBytes = 0
    private var sawDataPayload = false
    private var sawDone = false
    private var malformedPayloadCount = 0

    mutating func process(
        line: String,
        onContentBatch: @escaping @MainActor @Sendable (String) -> Void
    ) async throws {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix(":") else { return }
        guard trimmed.hasPrefix("data:") else { return }

        let payload = trimmed
            .dropFirst("data:".count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        sawDataPayload = true
        if payload == "[DONE]" {
            sawDone = true
            return
        }
        guard let data = payload.data(using: .utf8),
              let chunk = try? decoder.decode(ChatCompletionsStreamChunk.self, from: data) else {
            malformedPayloadCount += 1
            return
        }

        for choice in chunk.choices ?? [] {
            guard let delta = choice.delta else { continue }
            if let text = delta.content, !text.isEmpty {
                streamedContentBytes += text.utf8.count
                guard streamedContentBytes <= Self.maxStreamedContentBytes else {
                    throw OpenAIError.requestFailed("The provider stream exceeded NovaForge's streamed text limit. Ask for a smaller answer or have the model write large output to workspace files.")
                }
                content += text
                pendingContent += text

                let elapsed = lastDelivery.duration(to: .now)
                let shouldDeliver = elapsed >= .milliseconds(90)
                    || pendingContent.count >= 420
                if shouldDeliver {
                    await onContentBatch(pendingContent)
                    pendingContent.removeAll(keepingCapacity: true)
                    lastDelivery = .now
                }
            }

            for toolDelta in delta.tool_calls ?? [] {
                let index = toolDelta.index ?? toolParts.count
                if toolParts[index] == nil, toolParts.count >= Self.maxStreamedToolCalls {
                    throw OpenAIError.requestFailed("The provider stream exceeded NovaForge's streamed tool-call limit. Retry with fewer tool actions.")
                }
                var part = toolParts[index] ?? StreamingToolCallPart()
                if let id = toolDelta.id {
                    part.id = id
                }
                if let type = toolDelta.type {
                    part.type = type
                }
                if let name = toolDelta.function?.name {
                    part.name += name
                }
                if let arguments = toolDelta.function?.arguments {
                    streamedToolArgumentBytes += arguments.utf8.count
                    guard streamedToolArgumentBytes <= Self.maxStreamedToolArgumentBytes else {
                        throw OpenAIError.requestFailed("The provider stream exceeded NovaForge's streamed tool-call argument limit. Ask it to create smaller files or split work into multiple steps.")
                    }
                    part.arguments += arguments
                }
                toolParts[index] = part
            }
        }
    }

    mutating func finish(
        onContentBatch: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> ChatCompletionsResponse.Choice.Message {
        if !pendingContent.isEmpty {
            await onContentBatch(pendingContent)
        }

        let toolCalls = toolParts
            .keys
            .sorted()
            .compactMap { index in
                toolParts[index]?.makeToolCall(index: index)
            }

        return try StreamingResponseValidator.makeMessage(
            content: content,
            toolCalls: toolCalls,
            sawDataPayload: sawDataPayload,
            malformedPayloadCount: malformedPayloadCount,
            sawDone: sawDone
        )
    }

    static func decode(
        lines: [String],
        onContentBatch: @escaping @MainActor @Sendable (String) -> Void = { _ in }
    ) async throws -> ChatCompletionsResponse.Choice.Message {
        var decoder = StreamingResponseDecoder()
        for line in lines {
            try await decoder.process(line: line, onContentBatch: onContentBatch)
        }
        return try await decoder.finish(onContentBatch: onContentBatch)
    }
}

private func decodeStreamingResponse(
    from bytes: URLSession.AsyncBytes,
    onContentBatch: @escaping @MainActor @Sendable (String) -> Void
) async throws -> ChatCompletionsResponse.Choice.Message {
    var decoder = StreamingResponseDecoder()
    for try await line in bytes.lines {
        try await decoder.process(line: line, onContentBatch: onContentBatch)
    }
    return try await decoder.finish(onContentBatch: onContentBatch)
}

extension ChatMessage {
    func toAPIMessage() -> ChatCompletionsRequest.Message {
        var apiToolCalls: [APIToolCall]? = nil
        if let json = toolCallsJSON,
           let data = json.data(using: .utf8) {
            apiToolCalls = try? JSONDecoder().decode([APIToolCall].self, from: data)
        }
        
        return ChatCompletionsRequest.Message(
            role: roleRawValue,
            content: content.isEmpty && apiToolCalls != nil ? nil : content,
            name: nil,
            tool_call_id: toolCallID,
            tool_calls: apiToolCalls
        )
    }
}

extension ProviderChatMessage {
    var chatCompletionsMessage: ChatCompletionsRequest.Message {
        ChatCompletionsRequest.Message(
            role: role,
            content: content,
            name: nil,
            tool_call_id: toolCallID,
            tool_calls: toolCalls
        )
    }
}
