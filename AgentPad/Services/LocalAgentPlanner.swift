import AgentDomain
import Foundation

struct LocalAgentPlan: Sendable {
    let intro: String
    let toolCalls: [APIToolCall]
    let completion: String
}

/// One grammar-constrained decision emitted by the on-device coding model.
/// Every field is present to keep the GBNF small and deterministic; only the
/// fields required by `action` are compiled into canonical tool arguments.
struct LocalAgentModelDecision: Codable, Equatable, Sendable {
    let action: String
    let path: String
    let value: String
    let replacement: String
    let response: String

    private enum CodingKeys: String, CodingKey {
        case action
        case path
        case value
        case replacement
        case response
    }

    init(
        action: String,
        path: String = "",
        value: String = "",
        replacement: String = "",
        response: String = ""
    ) {
        self.action = action
        self.path = path
        self.value = value
        self.replacement = replacement
        self.response = response
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        action = try container.decode(String.self, forKey: .action)
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
        value = try container.decodeIfPresent(String.self, forKey: .value) ?? ""
        replacement = try container.decodeIfPresent(
            String.self,
            forKey: .replacement
        ) ?? ""
        response = try container.decodeIfPresent(
            String.self,
            forKey: .response
        ) ?? ""
    }
}

enum LocalAgentModelTurn: Equatable, Sendable {
    case respond(String)
    case tool(preface: String, call: APIToolCall)
}

enum LocalAgentModelDecisionError: Error, Equatable, Sendable {
    case invalidAction
    case invalidPath
    case missingArgument
    case oversizedArgument
}

/// Exact GBNF and compiler used by the local-agent route. The authority digest
/// binds these bytes, while llama.cpp enforces the grammar token by token.
enum LocalAgentModelGrammar {
    static let compilerID = "novaforge.local-agent-gbnf"
    static let compilerVersion = "3.3.0"
    static let maximumModelPlannedToolCalls = 6

    static let routerPrompt = """
    You are NovaForge Local's action router. Return exactly one compact JSON object. Put action first and include only the fields required by that action. respond requires response. list_tree and workspace_summary require no other field. list_directory, file_info, read_file require path. read_file_range, tail_file, search_text, write_file, append_file, validate_html_file require path and value. replace_text requires path, value, and replacement. run_command requires value. Allowed actions: respond, list_directory, list_tree, workspace_summary, file_info, read_file, read_file_range, tail_file, search_text, write_file, append_file, replace_text, validate_html_file, run_command. Use workspace-relative paths only. Use value for search text, file or appended contents, old replacement text, HTML profile, command, a read range written start,count, or a tail line count. Inspect before editing when file contents are unknown. Use read_file_range or tail_file when a complete file was truncated. Use append_file for a later chunk only after write_file succeeded. Choose respond for ordinary questions or when no safe action is justified. A response must be one short user-facing sentence and must never claim an action already succeeded.
    """

    static let gbnf = #"""
    root ::= respond | noarg | patharg | valuearg | replacementarg | commandarg
    respond ::= "{" ws "\"action\"" ws ":" ws "\"respond\"" "," ws "\"response\"" ws ":" ws string "}" ws
    noarg ::= "{" ws "\"action\"" ws ":" ws noarg-action "}" ws
    patharg ::= "{" ws "\"action\"" ws ":" ws path-action "," ws "\"path\"" ws ":" ws string "}" ws
    valuearg ::= "{" ws "\"action\"" ws ":" ws value-action "," ws "\"path\"" ws ":" ws string "," ws "\"value\"" ws ":" ws string "}" ws
    replacementarg ::= "{" ws "\"action\"" ws ":" ws "\"replace_text\"" "," ws "\"path\"" ws ":" ws string "," ws "\"value\"" ws ":" ws string "," ws "\"replacement\"" ws ":" ws string "}" ws
    commandarg ::= "{" ws "\"action\"" ws ":" ws "\"run_command\"" "," ws "\"value\"" ws ":" ws string "}" ws
    noarg-action ::= "\"list_tree\"" | "\"workspace_summary\""
    path-action ::= "\"list_directory\"" | "\"file_info\"" | "\"read_file\""
    value-action ::= "\"read_file_range\"" | "\"tail_file\"" | "\"search_text\"" | "\"write_file\"" | "\"append_file\"" | "\"validate_html_file\""
    string ::= "\"" char* "\""
    char ::= [^"\\\u0000-\u001f] | "\\" (["\\/bfnrt] | "u" hex hex hex hex)
    hex ::= [0-9a-fA-F]
    ws ::= [ \t\n\r]*
    """#

    static func compile(
        _ decision: LocalAgentModelDecision
    ) throws -> LocalAgentModelTurn {
        let action = decision.action
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let path = decision.path
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let value = decision.value
        let replacement = decision.replacement
        let response = compactResponse(decision.response)

        guard value.utf8.count <= 16_384,
              replacement.utf8.count <= 16_384 else {
            throw LocalAgentModelDecisionError.oversizedArgument
        }

        if action == "respond" {
            let text = response.isEmpty
                ? "I couldn’t choose a safe local action for that request."
                : response
            return .respond(text)
        }

        let arguments: [String: JSONValue]
        switch action {
        case "list_directory":
            try requireSafePath(path, allowRoot: true)
            arguments = ["path": .string(path)]
        case "list_tree":
            arguments = [:]
        case "workspace_summary":
            arguments = [:]
        case "file_info", "read_file":
            try requireSafePath(path, allowRoot: false)
            arguments = ["path": .string(path)]
        case "read_file_range":
            try requireSafePath(path, allowRoot: false)
            let range = try boundedReadRange(value)
            arguments = [
                "path": .string(path),
                "start_line": .number(.integer(Int64(range.start))),
                "line_count": .number(.integer(Int64(range.count))),
            ]
        case "tail_file":
            try requireSafePath(path, allowRoot: false)
            let count = try boundedInteger(
                value,
                defaultValue: 120,
                range: 1 ... 300
            )
            arguments = [
                "path": .string(path),
                "line_count": .number(.integer(Int64(count))),
            ]
        case "search_text":
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LocalAgentModelDecisionError.missingArgument
            }
            try requireSafePath(path, allowRoot: true)
            arguments = ["query": .string(value), "path": .string(path)]
        case "write_file", "append_file":
            try requireSafePath(path, allowRoot: false)
            arguments = ["path": .string(path), "contents": .string(value)]
        case "replace_text":
            try requireSafePath(path, allowRoot: false)
            guard !value.isEmpty else {
                throw LocalAgentModelDecisionError.missingArgument
            }
            arguments = [
                "path": .string(path),
                "old": .string(value),
                "new": .string(replacement),
            ]
        case "validate_html_file":
            try requireSafePath(path, allowRoot: false)
            let profile = ["auto", "page", "game"].contains(value.lowercased())
                ? value.lowercased()
                : "auto"
            arguments = ["path": .string(path), "profile": .string(profile)]
        case "run_command":
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LocalAgentModelDecisionError.missingArgument
            }
            arguments = ["command": .string(value)]
        default:
            throw LocalAgentModelDecisionError.invalidAction
        }

        let call = APIToolCall(
            id: "local-model-\(UUID().uuidString.prefix(12))",
            type: "function",
            function: APIFunctionCall(
                name: action,
                arguments: try encodedArguments(arguments)
            )
        )
        return .tool(
            preface: response.isEmpty ? defaultPreface(for: action) : response,
            call: call
        )
    }

    private static func encodedArguments(
        _ arguments: [String: JSONValue]
    ) throws -> String {
        let data = try JSONEncoder().encode(JSONValue.object(arguments))
        guard let text = String(data: data, encoding: .utf8) else {
            throw LocalAgentModelDecisionError.invalidAction
        }
        return text
    }

    private static func boundedReadRange(
        _ value: String
    ) throws -> (start: Int, count: Int) {
        let parts = value.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count <= 2 else {
            throw LocalAgentModelDecisionError.missingArgument
        }
        let start = try boundedInteger(
            parts.first.map(String.init) ?? "",
            defaultValue: 1,
            range: 1 ... 50_000
        )
        let count = try boundedInteger(
            parts.count == 2 ? String(parts[1]) : "",
            defaultValue: 200,
            range: 1 ... 400
        )
        return (start, count)
    }

    private static func boundedInteger(
        _ value: String,
        defaultValue: Int,
        range: ClosedRange<Int>
    ) throws -> Int {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return defaultValue }
        guard let parsed = Int(trimmed), range.contains(parsed) else {
            throw LocalAgentModelDecisionError.missingArgument
        }
        return parsed
    }

    private static func requireSafePath(
        _ path: String,
        allowRoot: Bool
    ) throws {
        guard path.utf8.count <= 4_096,
              (allowRoot || !path.isEmpty),
              !path.hasPrefix("/"),
              !path.hasPrefix("~"),
              !path.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }),
              !path.split(separator: "/", omittingEmptySubsequences: false)
                .contains(where: { $0 == ".." }) else {
            throw LocalAgentModelDecisionError.invalidPath
        }
    }

    private static func compactResponse(_ value: String) -> String {
        let compact = value
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard compact.count > 240 else { return compact }
        return String(compact.prefix(239)) + "…"
    }

    private static func defaultPreface(for action: String) -> String {
        switch action {
        case "list_directory", "list_tree", "workspace_summary":
            "I’ll inspect the workspace."
        case "file_info", "read_file", "read_file_range", "tail_file":
            "I’ll read that file."
        case "search_text":
            "I’ll search the workspace."
        case "write_file":
            "I’ll create that file after you approve the write."
        case "append_file":
            "I’ll append the next chunk after you approve the change."
        case "replace_text":
            "I’ll edit that file after you approve the change."
        case "validate_html_file":
            "I’ll validate that artifact."
        case "run_command":
            "I’ll run that sandbox command after you approve it."
        default:
            "I’ll handle that locally."
        }
    }
}

enum LocalAgentPlanner {
    static func plan(prompt: String, workspace: SandboxWorkspace) -> LocalAgentPlan? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lower = trimmed.lowercased()

        if isProjectContinuation(lower) {
            let context = continuationContext(from: trimmed, workspace: workspace)
            return plan(
                intro: context.intro,
                requests: context.requests,
                completion: context.completion
            )
        }

        if let command = commandIntent(from: trimmed, lower: lower) {
            return plan(
                intro: "I can run that in the sandbox.",
                requests: [ToolRequest(id: id("local-command"), name: "run_command", arguments: ["command": command])],
                completion: "Command finished. I kept the output compact in the run card."
            )
        }

        if lower.contains("list files") || lower.contains("show files") || lower == "files" || lower.contains("what files") {
            return plan(
                intro: "I’ll list the workspace files.",
                requests: [ToolRequest(id: id("local-list"), name: "list_directory", arguments: ["path": ""])],
                completion: "Workspace scan finished."
            )
        }

        if let search = searchIntent(from: trimmed, lower: lower) {
            var arguments = ["query": search.query]
            if let path = search.path { arguments["path"] = path }
            return plan(
                intro: "I’ll search the workspace for that.",
                requests: [ToolRequest(
                    id: id("local-search"),
                    name: "search_text",
                    arguments: arguments
                )],
                completion: "Search finished. Open the result details if you want the matching lines."
            )
        }

        if let path = readIntent(from: trimmed, lower: lower) {
            return plan(
                intro: "I’ll read that file.",
                requests: [ToolRequest(id: id("local-read"), name: "read_file", arguments: ["path": path])],
                completion: "File read complete."
            )
        }

        if wantsSampleNativeSwiftGame(lower) {
            return plan(
                intro: "I’ll create a native Swift game artifact manifest with exportable SwiftUI source.",
                requests: [
                    ToolRequest(
                        id: id("local-swift-game-manifest"),
                        name: "write_file",
                        arguments: [
                            "path": SwiftGameArtifactFactory.sampleManifestPath,
                            "contents": SwiftGameArtifactFactory.sampleManifestJSON()
                        ]
                    ),
                    ToolRequest(
                        id: id("local-swift-game-source"),
                        name: "write_file",
                        arguments: [
                            "path": SwiftGameArtifactFactory.sampleSourcePath,
                            "contents": SwiftGameArtifactFactory.exportSource()
                        ]
                    ),
                    ToolRequest(
                        id: id("local-swift-game-readme"),
                        name: "write_file",
                        arguments: [
                            "path": SwiftGameArtifactFactory.sampleReadmePath,
                            "contents": SwiftGameArtifactFactory.readme()
                        ]
                    ),
                    ToolRequest(
                        id: id("local-swift-game-info"),
                        name: "file_info",
                        arguments: ["path": SwiftGameArtifactFactory.sampleManifestPath]
                    )
                ],
                completion: "Native Swift game artifact ready. Open StarfieldSprint.nf-game.json to play it, rotate sideways for handheld mode, or inspect the export files."
            )
        }

        // The iPhone 12 profile intentionally has a small generation budget. Use a
        // deterministic, audited starter for the two common artifact requests so
        // Local mode creates something playable/useful offline instead of timing out
        // halfway through an HTML file. Follow-up reads and explicit writes still use
        // the same sandbox tools and approval policy as every other provider.
        if wantsGeneratedGame(lower) {
            let path = preferredHTMLPath(
                from: trimmed,
                lower: lower,
                workspace: workspace
            )
            let title = gameTitle(from: trimmed)
            return plan(
                intro: "I’ll create a responsive offline game and validate it on this iPhone.",
                requests: validatedHTMLRequests(
                    path: path,
                    contents: requestedGameHTML(title: title, lower: lower),
                    idPrefix: "local-game",
                    profile: "game"
                ),
                completion: "Game ready at \(path). Open the artifact, rotate sideways for full-screen play, or add its NovaForge Shortcut to the Home Screen."
            )
        }

        if wantsGeneratedWebArtifact(lower) {
            let path = preferredWebArtifactPath(
                from: trimmed,
                lower: lower,
                workspace: workspace
            )
            let title = webArtifactTitle(from: trimmed, lower: lower)
            return plan(
                intro: "I’ll create a polished offline web artifact and validate it on this iPhone.",
                requests: validatedHTMLRequests(
                    path: path,
                    contents: webArtifactHTML(title: title, lower: lower),
                    idPrefix: "local-web",
                    profile: "page"
                ),
                completion: "Artifact ready at \(path). Open it in Workspace to preview, share, or iterate."
            )
        }

        if let write = writeIntent(from: trimmed, lower: lower) {
            return plan(
                intro: "I’ll write that file in the sandbox.",
                requests: [
                    ToolRequest(
                        id: id("local-write"),
                        name: "write_file",
                        arguments: ["path": write.path, "contents": write.contents]
                    )
                ],
                completion: "File written."
            )
        }

        return nil
    }

    private static func wantsSampleNativeSwiftGame(_ lower: String) -> Bool {
        let mentionsSwiftGame = lower.contains("swift game") ||
            lower.contains("native game") ||
            lower.contains("native swift") ||
            lower.contains("swift-game") ||
            lower.contains("swiftgame")
        let asksForSample = lower.contains("sample") ||
            lower.contains("demo") ||
            lower.contains("seed") ||
            lower.contains("artifact mode") ||
            lower.contains("game artifact")
        let asksToCreate = ["make", "build", "create", "write", "generate", "prototype"]
            .contains { lower.contains($0) }
        return mentionsSwiftGame && (asksForSample || asksToCreate)
    }

    private static func plan(intro: String, requests: [ToolRequest], completion: String) -> LocalAgentPlan {
        let calls = requests.map { request in
            APIToolCall(
                id: request.id,
                type: "function",
                function: APIFunctionCall(name: request.name, arguments: request.argumentsJSON)
            )
        }
        return LocalAgentPlan(intro: intro, toolCalls: calls, completion: completion)
    }

    private static func id(_ prefix: String) -> String {
        "\(prefix)-\(UUID().uuidString.prefix(8))"
    }

    private static func isProjectContinuation(_ lower: String) -> Bool {
        lower.contains("novaforge project continuation") ||
            (lower.contains("continue the active project") && lower.contains("recommended next step"))
    }

    private struct ContinuationContext {
        let intro: String
        let requests: [ToolRequest]
        let completion: String
    }

    private static func continuationContext(from prompt: String, workspace: SandboxWorkspace) -> ContinuationContext {
        let project = lineValue(prefix: "Project:", in: prompt) ?? "active project"
        let mission = lineValue(prefix: "Mission:", in: prompt) ?? "the project mission"
        let nextStep = lineValue(prefix: "Recommended next step:", in: prompt) ?? "choose the next useful project step"
        let blocker = lineValue(prefix: "Blocker:", in: prompt)
        let latestProofLine = lineValue(prefix: "Latest proof:", in: prompt)
        let proofPath = latestProofLine
            .flatMap { firstPath(in: $0) }
            .flatMap { workspaceFileExists($0, workspace: workspace) ? $0 : nil }

        var requests: [ToolRequest] = [
            ToolRequest(
                id: id("local-project-summary"),
                name: "workspace_summary",
                arguments: ["max_items": "1000"]
            )
        ]

        if let proofPath {
            requests.append(
                ToolRequest(
                    id: id("local-proof-info"),
                    name: "file_info",
                    arguments: ["path": proofPath]
                )
            )
            if proofPath.lowercased().hasSuffix(".html") || proofPath.lowercased().hasSuffix(".htm") {
                requests.append(
                    ToolRequest(
                        id: id("local-proof-validate"),
                        name: "validate_html_file",
                        arguments: ["path": proofPath, "profile": "auto"]
                    )
                )
            }
        } else {
            requests.append(
                ToolRequest(
                    id: id("local-project-tree"),
                    name: "list_tree",
                    arguments: ["max_depth": "4", "max_items": "250"]
                )
            )
        }

        if blocker != nil, proofPath == nil {
            requests.append(
                ToolRequest(
                    id: id("local-blocker-search"),
                    name: "search_text",
                    arguments: ["query": "TODO"]
                )
            )
        }

        let action = blocker == nil ? nextStep : "review the blocker before changing work"
        let proofDetail = proofPath.map { "checked \($0)" } ?? "captured a workspace summary and project tree"
        return ContinuationContext(
            intro: "Agent Plan: I’ll inspect \(project) against its mission, then choose the next concrete action. Mission focus: \(compactSentence(mission)). Next: \(compactSentence(action)).",
            requests: uniquedRequests(requests),
            completion: "Agent Proof: \(proofDetail). No workspace mutation was made during this continuation scan. Next step: \(compactSentence(nextStep))."
        )
    }

    private static func lineValue(prefix: String, in text: String) -> String? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let value = String(line)
            guard value.hasPrefix(prefix) else { continue }
            let trimmed = String(value.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private static func uniquedRequests(_ requests: [ToolRequest]) -> [ToolRequest] {
        var seen = Set<String>()
        return requests.filter { request in
            let key = "\(request.name):\(request.argumentsJSON)"
            return seen.insert(key).inserted
        }
    }

    private static func compactSentence(_ text: String) -> String {
        let oneLine = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard oneLine.count > 150 else { return oneLine }
        return String(oneLine.prefix(149)) + "…"
    }

    private static func commandIntent(from prompt: String, lower: String) -> String? {
        for prefix in ["run command ", "run terminal ", "terminal "] {
            if lower.hasPrefix(prefix) {
                return String(prompt.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private struct SearchIntent {
        let query: String
        let path: String?
    }

    private static func searchIntent(
        from prompt: String,
        lower: String
    ) -> SearchIntent? {
        guard lower.contains("search") || lower.contains("find text") else { return nil }
        let separators = ["search for ", "search ", "find text "]
        for separator in separators {
            if let range = lower.range(of: separator) {
                let start = prompt.index(prompt.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: range.upperBound))
                let remainder = String(prompt[start...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let parsed = splitSearchRemainder(remainder)
                return parsed.query.isEmpty ? nil : parsed
            }
        }
        return nil
    }

    private static func splitSearchRemainder(
        _ remainder: String
    ) -> SearchIntent {
        let pattern = #"^\s*[\"'`]([^\"'`]+)[\"'`](?:\s+(?:in|under|inside)\s+(.+))?\s*$"#
        if let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ),
           let match = regex.firstMatch(
               in: remainder,
               range: NSRange(remainder.startIndex..., in: remainder)
           ),
           let queryRange = Range(match.range(at: 1), in: remainder) {
            let path: String?
            if match.range(at: 2).location != NSNotFound,
               let pathRange = Range(match.range(at: 2), in: remainder) {
                path = cleanedSafePath(String(remainder[pathRange]))
            } else {
                path = nil
            }
            return SearchIntent(
                query: String(remainder[queryRange]),
                path: path
            )
        }

        let lower = remainder.lowercased()
        for marker in [" inside ", " under ", " in "] {
            guard let range = lower.range(of: marker, options: .backwards)
            else { continue }
            let boundary = lower.distance(
                from: lower.startIndex,
                to: range.lowerBound
            )
            let queryEnd = remainder.index(
                remainder.startIndex,
                offsetBy: boundary
            )
            let pathStart = remainder.index(
                queryEnd,
                offsetBy: marker.count
            )
            let query = String(remainder[..<queryEnd])
                .trimmingCharacters(in: .whitespacesAndNewlines
                    .union(CharacterSet(charactersIn: "\"'`")))
            if let path = cleanedSafePath(String(remainder[pathStart...])),
               !query.isEmpty {
                return SearchIntent(query: query, path: path)
            }
        }
        return SearchIntent(
            query: remainder.trimmingCharacters(
                in: .whitespacesAndNewlines.union(
                    CharacterSet(charactersIn: "\"'`")
                )
            ),
            path: nil
        )
    }

    private static func readIntent(from prompt: String, lower: String) -> String? {
        guard lower.contains("read") || lower.contains("open") || lower.contains("show") else { return nil }
        if let path = firstPath(in: prompt) { return path }
        for prefix in ["read file ", "open file ", "show file "] {
            guard lower.hasPrefix(prefix) else { continue }
            return cleanedSafePath(String(prompt.dropFirst(prefix.count)))
        }
        return nil
    }

    private static func writeIntent(from prompt: String, lower: String) -> (path: String, contents: String)? {
        guard lower.contains("write file") || lower.contains("create file") else { return nil }
        let path = firstPath(in: prompt) ?? "notes/local-note.txt"
        let contentSeparators = [" with ", " containing ", " content "]
        for separator in contentSeparators {
            if let range = lower.range(of: separator) {
                let start = prompt.index(prompt.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: range.upperBound))
                let contents = String(prompt[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
                return (path, contents.isEmpty ? "Created by NovaForge Local.\n" : contents)
            }
        }
        return (path, "Created by NovaForge Local.\n")
    }

    private static func wantsGeneratedGame(_ lower: String) -> Bool {
        let action = [
            "make", "build", "create", "write", "improve", "fix", "optimize",
            "tune", "refine", "continue", "update"
        ].contains { lower.contains($0) }
        let game = lower.contains("game") || lower.contains("snake") ||
            lower.contains("slither") || lower.contains("flappy") ||
            lower.contains("tetris") || lower.contains("falling block")
        let web = lower.contains("html") || lower.contains("canvas") || lower.contains("browser") || game
        return action && game && web
    }

    private static func preferredHTMLPath(from prompt: String, lower: String, workspace: SandboxWorkspace) -> String {
        if let path = firstPath(in: prompt), path.lowercased().hasSuffix(".html") {
            return path
        }
        let shouldContinueExisting = ["continue", "improve", "fix", "optimize", "tune", "refine", "update"]
            .contains { lower.contains($0) }
        if shouldContinueExisting, let existing = existingHTMLArtifact(in: workspace) {
            return existing.relativePath
        }
        if lower.contains("slither") { return "slither-arena.html" }
        if lower.contains("snake") { return "snake.html" }
        if lower.contains("flappy") || lower.contains("bird") {
            return "flappy-flight.html"
        }
        if lower.contains("tetris") || lower.contains("falling block") {
            return "falling-blocks.html"
        }
        return "novaforge-arcade.html"
    }

    private static func existingHTMLArtifact(in workspace: SandboxWorkspace) -> FileItem? {
        // Keep local planning instant on older iPhones: a prompt like "continue the game"
        // should not recursively scan thousands of workspace files on the main actor.
        var newest: FileItem?
        var pendingDirectories = [""]
        var visitedDirectories = 0
        var visitedFiles = 0
        let maxDirectories = 40
        let maxFiles = 500

        while let directory = pendingDirectories.popLast() {
            if Task.isCancelled { return newest }
            guard visitedDirectories < maxDirectories, visitedFiles < maxFiles else { break }
            visitedDirectories += 1
            guard let items = try? workspace.list(directory) else { continue }
            for item in items {
                if Task.isCancelled { return newest }
                if item.isDirectory {
                    if pendingDirectories.count < maxDirectories {
                        pendingDirectories.append(item.relativePath)
                    }
                } else {
                    visitedFiles += 1
                    if item.relativePath.lowercased().hasSuffix(".html"),
                       (item.modifiedAt ?? .distantPast) > (newest?.modifiedAt ?? .distantPast) {
                        newest = item
                    }
                    if visitedFiles >= maxFiles { break }
                }
            }
        }

        return newest
    }

    private static func firstPath(in prompt: String) -> String? {
        let quotedPattern = #"[\"'`]([^\"'`\n]+)[\"'`]"#
        if let regex = try? NSRegularExpression(pattern: quotedPattern),
           let match = regex.firstMatch(
               in: prompt,
               range: NSRange(prompt.startIndex..., in: prompt)
           ),
           let range = Range(match.range(at: 1), in: prompt),
           let path = cleanedSafePath(String(prompt[range])),
           path.contains("/") || path.contains(".") {
            return path
        }

        let extensions = "html|htm|css|js|jsx|ts|tsx|swift|md|txt|json|log|py|yaml|yml|plist|xml|toml|sh|c|cc|cpp|h|hpp|m|mm|kt|java|rs|go|rb|php|vue|svelte"
        let pattern = #"[\p{L}\p{N}_@+\-./]+\.(__EXT__)"#
            .replacingOccurrences(of: "__EXT__", with: extensions)
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else { return nil }
        let range = NSRange(prompt.startIndex..<prompt.endIndex, in: prompt)
        guard let match = regex.firstMatch(in: prompt, range: range),
              let swiftRange = Range(match.range, in: prompt) else { return nil }
        return cleanedSafePath(String(prompt[swiftRange]))
    }

    private static func cleanedSafePath(_ raw: String) -> String? {
        let path = raw.trimmingCharacters(
            in: .whitespacesAndNewlines.union(
                CharacterSet(charactersIn: "\"'`")
            )
        )
        guard !path.isEmpty,
              path.utf8.count <= 4_096,
              !path.hasPrefix("/"),
              !path.hasPrefix("~"),
              !path.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }),
              !path.split(separator: "/", omittingEmptySubsequences: false)
                .contains(where: { $0 == ".." }) else { return nil }
        return path
    }

    private static func gameTitle(from prompt: String) -> String {
        let lower = prompt.lowercased()
        if lower.contains("slither") { return "Slither Arena" }
        if lower.contains("snake") { return "Snake Arena" }
        if lower.contains("flappy") || lower.contains("bird") {
            return "Flappy Flight"
        }
        if lower.contains("tetris") || lower.contains("falling block") {
            return "Falling Blocks"
        }
        return "NovaForge Arcade"
    }

    private static func wantsGeneratedWebArtifact(_ lower: String) -> Bool {
        let action = [
            "make", "build", "create", "write", "design", "prototype", "mock up", "mockup", "generate"
        ].contains { lower.contains($0) }
        let artifact = [
            "web page", "webpage", "website", "landing page", "portfolio", "dashboard", "html page",
            "single page", "web app", "microsite", "page"
        ].contains { lower.contains($0) }
        return action && artifact && !wantsGeneratedGame(lower)
    }

    private static func preferredWebArtifactPath(from prompt: String, lower: String, workspace: SandboxWorkspace) -> String {
        if let path = firstPath(in: prompt), path.lowercased().hasSuffix(".html") {
            return path
        }
        let base: String
        if lower.contains("dashboard") {
            base = "dashboard"
        } else if lower.contains("portfolio") {
            base = "portfolio"
        } else if lower.contains("landing") {
            base = "landing-page"
        } else if lower.contains("website") || lower.contains("web page") || lower.contains("webpage") {
            base = "website"
        } else {
            base = "novaforge-page"
        }
        return firstAvailableHTMLPath(base: base, workspace: workspace)
    }

    private static func firstAvailableHTMLPath(base: String, workspace: SandboxWorkspace) -> String {
        let sanitizedBase = base
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let candidateBase = sanitizedBase.isEmpty ? "novaforge-page" : sanitizedBase
        for index in 0..<100 {
            let path = index == 0 ? "\(candidateBase).html" : "\(candidateBase)-\(index + 1).html"
            if !workspaceFileExists(path, workspace: workspace) {
                return path
            }
        }
        return "\(candidateBase)-\(UUID().uuidString.prefix(8)).html"
    }

    private static func workspaceFileExists(_ path: String, workspace: SandboxWorkspace) -> Bool {
        guard let url = try? workspace.resolve(path) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private static func webArtifactTitle(from prompt: String, lower: String) -> String {
        if lower.contains("portfolio") { return "NovaForge Portfolio" }
        if lower.contains("dashboard") { return "Launch Dashboard" }
        if lower.contains("landing") { return "Launch Landing Page" }
        if lower.contains("website") { return "NovaForge Website" }
        if let path = firstPath(in: prompt) {
            return path
                .split(separator: "/")
                .last?
                .replacingOccurrences(of: ".html", with: "")
                .replacingOccurrences(of: "-", with: " ")
                .capitalized ?? "NovaForge Page"
        }
        return "NovaForge Page"
    }

    private static func validatedHTMLRequests(path: String, contents: String, idPrefix: String, profile: String) -> [ToolRequest] {
        [
            ToolRequest(
                id: id("\(idPrefix)-write"),
                name: "write_file",
                arguments: ["path": path, "contents": contents]
            ),
            ToolRequest(
                id: id("\(idPrefix)-validate"),
                name: "validate_html_file",
                arguments: ["path": path, "profile": profile]
            ),
            ToolRequest(
                id: id("\(idPrefix)-info"),
                name: "file_info",
                arguments: ["path": path]
            )
        ]
    }

    private static func htmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func webArtifactHTML(title: String, lower: String) -> String {
        let eyebrow = lower.contains("portfolio") ? "PORTFOLIO" : lower.contains("dashboard") ? "DASHBOARD" : "LAUNCH PAGE"
        let primary = lower.contains("portfolio") ? "View Work" : lower.contains("dashboard") ? "Review Metrics" : "Start Project"
        let secondary = lower.contains("portfolio") ? "Book Joey" : lower.contains("dashboard") ? "Open Roadmap" : "See Demo"
        return """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
          <title>\(title)</title>
          <style>
            :root { color-scheme: dark; font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", system-ui, sans-serif; }
            * { box-sizing: border-box; }
            html, body { min-height: 100%; margin: 0; background: #071018; color: #f4fbff; }
            body { overflow-x: hidden; background: radial-gradient(circle at 12% 8%, #1b6c84 0, transparent 34%), radial-gradient(circle at 86% 12%, #6c3dff66 0, transparent 32%), linear-gradient(135deg, #071018 0%, #0b1624 52%, #071018 100%); }
            main { min-height: 100svh; padding: max(22px, env(safe-area-inset-top)) max(18px, env(safe-area-inset-right)) max(22px, env(safe-area-inset-bottom)) max(18px, env(safe-area-inset-left)); display: grid; grid-template-rows: auto 1fr auto; gap: clamp(18px, 3vw, 34px); }
            nav, .hero, .metric, .panel, footer { border: 1px solid #ffffff24; background: linear-gradient(145deg, #ffffff18, #ffffff09); box-shadow: 0 24px 90px #0008, inset 0 1px 0 #ffffff2e; backdrop-filter: blur(22px); }
            nav { display: flex; align-items: center; justify-content: space-between; gap: 12px; border-radius: 22px; padding: 12px 14px; }
            .brand { display: flex; align-items: center; gap: 10px; font-weight: 900; letter-spacing: -.03em; }
            .logo { width: 36px; height: 36px; border-radius: 13px; display: grid; place-items: center; background: linear-gradient(135deg, #39e7ff, #8affc1); color: #061018; }
            .nav-actions { display: flex; gap: 8px; flex-wrap: wrap; justify-content: flex-end; }
            .pill, button { border: 1px solid #ffffff24; border-radius: 999px; padding: 9px 12px; background: #07101899; color: #f4fbff; font-weight: 800; }
            .stage { display: grid; grid-template-columns: minmax(0, 1.1fr) minmax(260px, .9fr); align-items: stretch; gap: clamp(16px, 3vw, 28px); }
            .hero { border-radius: clamp(24px, 4vw, 42px); padding: clamp(22px, 5vw, 56px); display: grid; align-content: center; gap: 18px; min-height: min(620px, 62svh); }
            .eyebrow { color: #8affc1; font-size: 12px; font-weight: 1000; letter-spacing: .18em; }
            h1 { margin: 0; max-width: 11ch; font-size: clamp(48px, 12vw, 118px); line-height: .86; letter-spacing: -.075em; }
            p { margin: 0; color: #c9d7e1; font-size: clamp(16px, 2.2vw, 22px); line-height: 1.35; max-width: 58ch; }
            .cta { display: flex; flex-wrap: wrap; gap: 10px; margin-top: 4px; }
            .cta button:first-child { background: linear-gradient(135deg, #39e7ff, #8affc1); color: #061018; }
            .side { display: grid; gap: 14px; grid-template-rows: repeat(3, minmax(0, 1fr)); }
            .metric, .panel { border-radius: 26px; padding: clamp(18px, 3vw, 28px); display: grid; gap: 10px; align-content: center; min-width: 0; }
            .number { font-size: clamp(34px, 8vw, 74px); line-height: .9; font-weight: 1000; letter-spacing: -.06em; color: #8affc1; }
            .panel strong, .metric strong { font-size: clamp(17px, 2vw, 24px); }
            footer { border-radius: 20px; padding: 12px 14px; display: flex; justify-content: space-between; gap: 12px; color: #9bb3c7; font-size: 13px; font-weight: 700; }
            @media (max-width: 760px) {
              main { gap: 14px; }
              nav, footer { border-radius: 18px; }
              .stage { grid-template-columns: 1fr; }
              .hero { min-height: auto; }
              h1 { max-width: 9ch; }
              .side { grid-template-rows: none; }
            }
            @media (orientation: landscape) and (max-height: 520px) {
              main { min-height: 100vh; gap: 10px; padding: 10px max(12px, env(safe-area-inset-right)) 10px max(12px, env(safe-area-inset-left)); }
              nav, footer { padding: 8px 10px; }
              .stage { grid-template-columns: minmax(0, 1fr) minmax(280px, .9fr); gap: 10px; }
              .hero, .metric, .panel { border-radius: 22px; padding: 18px; }
              .hero { min-height: 0; }
              h1 { font-size: clamp(34px, 11vh, 62px); max-width: 12ch; }
              p { font-size: 14px; }
              .number { font-size: clamp(30px, 10vh, 54px); }
            }
          </style>
        </head>
        <body>
          <main>
            <nav aria-label="Artifact navigation"><div class="brand"><span class="logo">✦</span><span>\(title)</span></div><div class="nav-actions"><span class="pill">Responsive</span><span class="pill">Local HTML</span></div></nav>
            <section class="stage">
              <article class="hero">
                <div class="eyebrow">\(eyebrow)</div>
                <h1>Ship a beautiful idea.</h1>
                <p>A polished, self-contained NovaForge artifact with safe-area spacing, readable landscape layout, glass cards, and live-preview friendly CSS.</p>
                <div class="cta"><button>\(primary)</button><button>\(secondary)</button></div>
              </article>
              <aside class="side" aria-label="Highlights">
                <div class="metric"><span class="number">3×</span><strong>Faster first draft</strong><p>Starts with real files instead of a chat-only mockup.</p></div>
                <div class="panel"><strong>Landscape-ready</strong><p>Uses fluid grids and compact landscape rules so previews stay useful on iPhone.</p></div>
                <div class="panel"><strong>Offline artifact</strong><p>No CDN, no network, and no hidden dependency: everything is inside this HTML file.</p></div>
              </aside>
            </section>
            <footer><span>Generated by NovaForge Local</span><span>Open · Share · Iterate</span></footer>
          </main>
        </body>
        </html>
        """
    }

    private static func requestedGameHTML(
        title: String,
        lower: String
    ) -> String {
        if lower.contains("flappy") || lower.contains("bird") {
            return flappyGameHTML(title: title)
        }
        if lower.contains("tetris") || lower.contains("falling block") {
            return fallingBlocksGameHTML(title: title)
        }
        return snakeGameHTML(title: title)
    }

    private static func flappyGameHTML(title: String) -> String {
        """
        <!doctype html>
        <html lang="en"><head>
        <meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
        <title>\(title)</title>
        <style>
        *{box-sizing:border-box}html,body{margin:0;width:100%;height:100%;overflow:hidden;background:#071522;color:#f7fbff;font-family:-apple-system,system-ui,sans-serif}main{height:100%;display:grid;grid-template-columns:minmax(150px,.28fr) 1fr;gap:12px;padding:max(10px,env(safe-area-inset-top)) max(10px,env(safe-area-inset-right)) max(10px,env(safe-area-inset-bottom)) max(10px,env(safe-area-inset-left))}header{display:grid;align-content:center;gap:10px}h1{font-size:clamp(24px,6vmin,58px);line-height:.9;margin:0}p{margin:0;color:#b8d8ee;line-height:1.3}.score{font-size:clamp(20px,4vmin,38px);font-weight:900;color:#ffe475}button{border:1px solid #ffffff40;border-radius:14px;background:#ffffff16;color:white;padding:10px 14px;font-weight:800}canvas{display:block;width:100%;height:100%;min-height:0;border-radius:22px;border:1px solid #ffffff30;background:#103a59;touch-action:none}@media(orientation:portrait){main{grid-template-columns:1fr;grid-template-rows:auto 1fr}header{display:flex;align-items:center;justify-content:space-between;gap:8px}header p{display:none}h1{font-size:clamp(22px,7vw,34px)}}@media(orientation:landscape) and (max-height:420px){main{display:block;padding:0}header{position:absolute;z-index:2;left:max(10px,env(safe-area-inset-left));top:max(10px,env(safe-area-inset-top));display:flex;align-items:center;gap:10px;text-shadow:0 2px 8px #000}header p{display:none}canvas{position:absolute;inset:0;border-radius:0}}
        </style></head><body><main><header><div><h1>\(title)</h1><p>Tap, click, or press Space to fly through every gate.</p></div><div class="score">Score <span id="score">0</span></div><button id="restart">Restart</button></header><canvas id="game" aria-label="Flappy flight game"></canvas></main>
        <script>
        const c=document.querySelector('#game'),x=c.getContext('2d'),scoreEl=document.querySelector('#score');let dpr=1,w=1,h=1,bird,pipes,score,alive,last,spawn;
        function resize(){const r=c.getBoundingClientRect();dpr=Math.min(3,devicePixelRatio||1);c.width=Math.max(1,r.width*dpr);c.height=Math.max(1,r.height*dpr);w=c.width;h=c.height;draw()}
        function reset(){bird={x:w*.24,y:h*.45,v:0,r:Math.max(12*dpr,Math.min(w,h)*.025)};pipes=[];score=0;alive=true;last=performance.now();spawn=0;scoreEl.textContent=0}
        function flap(){if(!alive){reset();return}bird.v=-Math.max(360*dpr,h*.62)}
        function addPipe(){const gap=Math.max(125*dpr,h*.28),margin=gap*.65,center=margin+Math.random()*Math.max(1,h-margin*2);pipes.push({x:w+40*dpr,width:Math.max(54*dpr,w*.075),top:center-gap/2,bottom:center+gap/2,scored:false})}
        function update(dt){if(!alive)return;bird.v+=Math.max(900*dpr,h*1.6)*dt;bird.y+=bird.v*dt;spawn-=dt;if(spawn<=0){addPipe();spawn=1.45}const speed=Math.max(190*dpr,w*.25);for(const p of pipes){p.x-=speed*dt;if(!p.scored&&p.x+p.width<bird.x){p.scored=true;score++;scoreEl.textContent=score}const hitX=bird.x+bird.r>p.x&&bird.x-bird.r<p.x+p.width;if(hitX&&(bird.y-bird.r<p.top||bird.y+bird.r>p.bottom))alive=false}pipes=pipes.filter(p=>p.x+p.width>-20*dpr);if(bird.y+bird.r>h||bird.y-bird.r<0)alive=false}
        function draw(){const g=x.createLinearGradient(0,0,0,h);g.addColorStop(0,'#134b72');g.addColorStop(1,'#071522');x.fillStyle=g;x.fillRect(0,0,w,h);for(const p of pipes){x.fillStyle='#58e6a9';x.fillRect(p.x,0,p.width,p.top);x.fillRect(p.x,p.bottom,p.width,h-p.bottom);x.fillStyle='#b7ffd8';x.fillRect(p.x-4*dpr,p.top-14*dpr,p.width+8*dpr,14*dpr);x.fillRect(p.x-4*dpr,p.bottom,p.width+8*dpr,14*dpr)}x.save();x.translate(bird.x,bird.y);x.rotate(Math.max(-.5,Math.min(.9,bird.v/900)));x.fillStyle='#ffe475';x.beginPath();x.arc(0,0,bird.r,0,Math.PI*2);x.fill();x.fillStyle='#ff8a66';x.fillRect(bird.r*.55,-bird.r*.12,bird.r*.9,bird.r*.35);x.restore();if(!alive){x.fillStyle='#000a';x.fillRect(0,0,w,h);x.fillStyle='white';x.textAlign='center';x.font=`900 ${Math.max(28*dpr,h*.09)}px system-ui`;x.fillText('Tap to fly again',w/2,h/2)}}
        function loop(t){const dt=Math.min(.034,(t-last)/1000);last=t;update(dt);draw();requestAnimationFrame(loop)}
        c.addEventListener('pointerdown',e=>{e.preventDefault();flap()});addEventListener('keydown',e=>{if(e.code==='Space'||e.key==='ArrowUp'){e.preventDefault();flap()}});document.querySelector('#restart').onclick=reset;addEventListener('resize',resize);resize();reset();requestAnimationFrame(loop);
        </script></body></html>
        """
    }

    private static func fallingBlocksGameHTML(title: String) -> String {
        """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover"><title>\(title)</title>
        <style>*{box-sizing:border-box}html,body{margin:0;width:100%;height:100%;overflow:hidden;background:#080813;color:#fff;font-family:-apple-system,system-ui,sans-serif}main{height:100%;display:grid;grid-template-columns:minmax(160px,.32fr) minmax(220px,1fr);gap:12px;padding:max(10px,env(safe-area-inset-top)) max(10px,env(safe-area-inset-right)) max(10px,env(safe-area-inset-bottom)) max(10px,env(safe-area-inset-left))}header{display:grid;align-content:center;gap:10px}h1{font-size:clamp(24px,6vmin,58px);line-height:.9;margin:0}.score{font-size:clamp(18px,4vmin,34px);font-weight:900;color:#76f4ff}.controls{display:grid;grid-template-columns:repeat(4,1fr);gap:7px}button{border:1px solid #ffffff38;border-radius:13px;background:#ffffff13;color:white;min-height:44px;font-size:20px;font-weight:900;touch-action:manipulation}canvas{display:block;width:100%;height:100%;min-height:0;border:1px solid #ffffff2d;border-radius:22px;background:#0d0d1c;touch-action:none}@media(orientation:portrait){main{grid-template-columns:1fr;grid-template-rows:auto 1fr}header{display:grid;grid-template-columns:1fr auto;align-items:center}header p{display:none}.controls{grid-column:1/-1}h1{font-size:clamp(22px,7vw,34px)}}@media(orientation:landscape) and (max-height:420px){main{grid-template-columns:minmax(140px,.25fr) 1fr;padding:6px}}</style></head>
        <body><main><header><div><h1>\(title)</h1><p>Clear lines with arrows, swipe, or the controls.</p></div><div class="score">Score <span id="score">0</span></div><div class="controls"><button data-a="left">←</button><button data-a="rotate">↻</button><button data-a="right">→</button><button data-a="drop">↓</button></div></header><canvas id="game" aria-label="Falling blocks game"></canvas></main>
        <script>
        const c=document.querySelector('#game'),x=c.getContext('2d'),scoreEl=document.querySelector('#score'),COLS=10,ROWS=20,colors=['','#5ee7ff','#ffd166','#b388ff','#ff7f8f','#66f2a3','#ff9f55','#72a5ff'];let board,piece,score,last,acc,over,dpr=1,cell=20,ox=0,oy=0;
        const shapes=[[[1,1,1,1]],[[2,2],[2,2]],[[0,3,0],[3,3,3]],[[4,0,0],[4,4,4]],[[0,0,5],[5,5,5]],[[0,6,6],[6,6,0]],[[7,7,0],[0,7,7]]];
        function resize(){const r=c.getBoundingClientRect();dpr=Math.min(3,devicePixelRatio||1);c.width=Math.max(1,r.width*dpr);c.height=Math.max(1,r.height*dpr);cell=Math.max(6,Math.min(c.width/COLS,c.height/ROWS));ox=(c.width-cell*COLS)/2;oy=(c.height-cell*ROWS)/2;draw()}
        function reset(){board=Array.from({length:ROWS},()=>Array(COLS).fill(0));score=0;over=false;spawn();scoreEl.textContent=0;last=performance.now();acc=0}
        function spawn(){const s=shapes[Math.floor(Math.random()*shapes.length)].map(r=>[...r]);piece={s,x:Math.floor((COLS-s[0].length)/2),y:0};if(hit(piece.s,piece.x,piece.y))over=true}
        function hit(s,px,py){return s.some((r,y)=>r.some((v,q)=>v&&(px+q<0||px+q>=COLS||py+y>=ROWS||(py+y>=0&&board[py+y][px+q]))))}
        function move(dx,dy){if(over)return false;if(!hit(piece.s,piece.x+dx,piece.y+dy)){piece.x+=dx;piece.y+=dy;return true}if(dy){merge();clear();spawn()}return false}
        function rotate(){const s=piece.s[0].map((_,i)=>piece.s.map(r=>r[i]).reverse());if(!hit(s,piece.x,piece.y))piece.s=s}
        function merge(){piece.s.forEach((r,y)=>r.forEach((v,q)=>{if(v&&piece.y+y>=0)board[piece.y+y][piece.x+q]=v}))}
        function clear(){let lines=0;board=board.filter(r=>{if(r.every(Boolean)){lines++;return false}return true});while(board.length<ROWS)board.unshift(Array(COLS).fill(0));score+=[0,100,300,500,800][lines]||0;scoreEl.textContent=score}
        function act(a){if(a==='left')move(-1,0);if(a==='right')move(1,0);if(a==='rotate')rotate();if(a==='drop'){while(move(0,1));score+=2;scoreEl.textContent=score}draw()}
        function block(v,q,y){if(!v)return;x.fillStyle=colors[v];x.fillRect(ox+q*cell+1*dpr,oy+y*cell+1*dpr,cell-2*dpr,cell-2*dpr)}
        function draw(){x.fillStyle='#0d0d1c';x.fillRect(0,0,c.width,c.height);board.forEach((r,y)=>r.forEach((v,q)=>block(v,q,y)));if(piece)piece.s.forEach((r,y)=>r.forEach((v,q)=>block(v,piece.x+q,piece.y+y)));if(over){x.fillStyle='#000c';x.fillRect(0,0,c.width,c.height);x.fillStyle='white';x.textAlign='center';x.font=`900 ${Math.max(28*dpr,c.height*.08)}px system-ui`;x.fillText('Game Over',c.width/2,c.height/2)}}
        function loop(t){acc+=t-last;last=t;while(acc>520){move(0,1);acc-=520}draw();requestAnimationFrame(loop)}
        addEventListener('keydown',e=>{const m={ArrowLeft:'left',ArrowRight:'right',ArrowUp:'rotate',ArrowDown:'drop'}[e.key];if(m){e.preventDefault();act(m)}if(e.key==='r')reset()});document.querySelectorAll('button').forEach(b=>b.onclick=()=>act(b.dataset.a));let start;c.onpointerdown=e=>start=e;c.onpointerup=e=>{if(!start)return;const dx=e.clientX-start.clientX,dy=e.clientY-start.clientY;Math.abs(dx)>Math.abs(dy)?act(dx>0?'right':'left'):dy>35?act('drop'):act('rotate');start=null};addEventListener('resize',resize);resize();reset();requestAnimationFrame(loop);
        </script></body></html>
        """
    }

    private static func snakeGameHTML(title: String) -> String {
        """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
          <title>\(title)</title>
          <style>
            :root { color-scheme: dark; font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", sans-serif; }
            * { box-sizing: border-box; }
            html, body { width: 100%; height: 100%; min-height: 100%; background: #06100c; overflow: hidden; }
            body { margin: 0; background: radial-gradient(circle at 22% 12%, #123a2a, #06100c 56%); color: #effff5; }
            main { width: 100%; height: 100%; padding: max(10px, env(safe-area-inset-top)) max(10px, env(safe-area-inset-right)) max(10px, env(safe-area-inset-bottom)) max(10px, env(safe-area-inset-left)); display: grid; grid-template-columns: minmax(170px, .34fr) minmax(0, .66fr); align-items: stretch; overflow: hidden; gap: clamp(10px, 2vw, 24px); }
            header { display: grid; gap: clamp(8px, 1.5vmin, 14px); align-content: center; min-width: 0; }
            h1 { margin: 0; font-size: clamp(22px, 5vmin, 52px); line-height: .94; letter-spacing: -.045em; }
            p { margin: 0; max-width: 30rem; color: #b5d6c4; font-size: clamp(12px, 2vmin, 18px); line-height: 1.22; }
            .score { width: fit-content; display: grid; gap: 1px; font-weight: 900; color: #8fffc1; font-size: clamp(15px, 2.6vmin, 26px); padding: 10px 13px; border: 1px solid #2d6c50; border-radius: 16px; background: #0a1d15cc; }
            .score span { font-size: 1.15em; }
            .game-wrap { width: 100%; height: 100%; min-width: 0; min-height: 0; justify-self: stretch; align-self: stretch; }
            canvas { display: block; width: 100%; height: 100%; background: radial-gradient(circle at 30% 20%, #163c2d, #08130f 58%); border: 1px solid #255540; border-radius: clamp(14px, 3vmin, 26px); box-shadow: inset 0 0 22px #58ffa314; touch-action: none; }
            .bar { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 4px; }
            button { appearance: none; border: 1px solid #37634e; background: #13221acc; color: #effff5; border-radius: 12px; padding: 9px 12px; font-weight: 800; }
            @media (orientation: landscape) {
              main { grid-template-columns: minmax(150px, .30fr) minmax(0, .70fr); }
              .game-wrap { width: 100%; height: 100%; }
            }
            @media (orientation: landscape) and (max-height: 360px), (orientation: landscape) and (max-width: 720px) {
              main { position: relative; display: block; padding: 0; overflow: hidden; }
              header { position: absolute; inset: 8px auto auto 8px; z-index: 2; display: flex; align-items: center; gap: 8px; pointer-events: none; }
              header > div:first-child { min-width: 0; }
              h1 { font-size: clamp(16px, 5vmin, 24px); max-width: 11rem; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; text-shadow: 0 2px 8px #000b; }
              p, .bar { display: none; }
              .score { font-size: clamp(12px, 4vmin, 18px); padding: 7px 9px; background: #07140ee8; }
              .game-wrap { position: absolute; inset: 0; width: 100%; height: 100%; }
              canvas { border-radius: 18px; }
            }
            @media (orientation: portrait) {
              main { grid-template-columns: 1fr; grid-template-rows: auto minmax(0, 1fr); align-content: stretch; overflow: hidden; gap: 10px; }
              header { grid-template-columns: minmax(0, 1fr) auto; gap: 8px 12px; align-items: start; align-content: start; }
              header > div:first-child { min-width: 0; }
              h1 { font-size: clamp(24px, 7vw, 38px); }
              p { font-size: clamp(12px, 3.4vw, 16px); max-width: none; }
              .score { grid-row: 1 / span 2; grid-column: 2; }
              .bar { grid-column: 1 / -1; margin-top: 0; }
              .game-wrap { width: 100%; height: 100%; min-height: 0; justify-self: stretch; align-self: stretch; }
            }
          </style>
        </head>
        <body>
          <main>
            <header>
              <div>
                <h1>\(title)</h1>
                <p>Arrow keys, WASD, or swipe. Eat, grow, and avoid yourself.</p>
              </div>
              <div class="score">Score <span id="score">0</span></div>
              <div class="bar"><button id="restart">Restart</button><button id="pause">Pause</button></div>
            </header>
            <section class="game-wrap" aria-label="Game board">
              <canvas id="game" width="720" height="720"></canvas>
            </section>
          </main>
          <script>
            const canvas = document.querySelector("#game");
            const ctx = canvas.getContext("2d");
            const scoreEl = document.querySelector("#score");
            let cols = 24, rows = 24, cell = 1, boardX = 0, boardY = 0, pixelRatio = 1, resizeFrame = 0;
            let snake, dir, nextDir, food, score, paused, over, last, acc;
            function resizeCanvas() {
              const rect = canvas.getBoundingClientRect();
              pixelRatio = Math.max(1, Math.min(3, window.devicePixelRatio || 1));
              canvas.width = Math.max(1, Math.floor(rect.width * pixelRatio));
              canvas.height = Math.max(1, Math.floor(rect.height * pixelRatio));
              const targetCell = Math.max(18 * pixelRatio, Math.min(canvas.width / 34, canvas.height / 18));
              cols = Math.max(18, Math.floor(canvas.width / targetCell));
              rows = Math.max(12, Math.floor(canvas.height / targetCell));
              cell = Math.min(canvas.width / cols, canvas.height / rows);
              boardX = (canvas.width - cols * cell) / 2;
              boardY = (canvas.height - rows * cell) / 2;
              ensureSnakeInBounds();
              draw();
            }
            function requestResize() {
              cancelAnimationFrame(resizeFrame);
              resizeFrame = requestAnimationFrame(resizeCanvas);
            }
            function reset() {
              resizeCanvas();
              const midX = Math.floor(cols / 2), midY = Math.floor(rows / 2);
              snake = [{x: midX, y: midY}, {x: midX - 1, y: midY}, {x: midX - 2, y: midY}];
              dir = {x: 1, y: 0}; nextDir = dir; score = 0; paused = false; over = false; last = 0; acc = 0;
              placeFood(); scoreEl.textContent = score; draw();
            }
            function clampCell(value, max) { return Math.max(0, Math.min(max - 1, value)); }
            function ensureSnakeInBounds() {
              if (!Array.isArray(snake) || snake.length === 0) return;
              const seen = new Set();
              snake = snake.map(p => ({x: clampCell(p.x, cols), y: clampCell(p.y, rows)})).filter(p => {
                const key = `${p.x},${p.y}`;
                if (seen.has(key)) return false;
                seen.add(key);
                return true;
              });
              if (!food || food.x < 0 || food.y < 0 || food.x >= cols || food.y >= rows || snake.some(p => p.x === food.x && p.y === food.y)) placeFood();
            }
            function placeFood() {
              for (let attempt = 0; attempt < 200; attempt++) {
                const candidate = {x: Math.floor(Math.random() * cols), y: Math.floor(Math.random() * rows)};
                if (!Array.isArray(snake) || !snake.some(p => p.x === candidate.x && p.y === candidate.y)) { food = candidate; return; }
              }
              food = {x: 0, y: 0};
            }
            function setDir(x, y) { if (dir.x + x !== 0 || dir.y + y !== 0) nextDir = {x, y}; }
            function step() {
              if (paused || over) return;
              dir = nextDir;
              const head = {x: (snake[0].x + dir.x + cols) % cols, y: (snake[0].y + dir.y + rows) % rows};
              if (snake.some(p => p.x === head.x && p.y === head.y)) over = true;
              if (over) return;
              snake.unshift(head);
              if (head.x === food.x && head.y === food.y) { score += 10; scoreEl.textContent = score; placeFood(); } else snake.pop();
            }
            function draw() {
              if (!Array.isArray(snake) || !food) return;
              ctx.clearRect(0, 0, canvas.width, canvas.height);
              ctx.fillStyle = "#07130f"; ctx.fillRect(0, 0, canvas.width, canvas.height);
              ctx.save(); ctx.translate(boardX, boardY);
              const boardW = cols * cell, boardH = rows * cell;
              ctx.fillStyle = "#0b1f17"; ctx.fillRect(0, 0, boardW, boardH);
              ctx.fillStyle = "#ff5f87"; ctx.beginPath(); ctx.arc((food.x + .5) * cell, (food.y + .5) * cell, cell * .32, 0, Math.PI * 2); ctx.fill();
              snake.forEach((p, i) => { ctx.fillStyle = i ? "#4ef2a0" : "#b7ffd3"; roundRect(p.x * cell + 3 * pixelRatio, p.y * cell + 3 * pixelRatio, cell - 6 * pixelRatio, cell - 6 * pixelRatio, 9 * pixelRatio); });
              if (over) { ctx.fillStyle = "#000b"; ctx.fillRect(0, 0, boardW, boardH); ctx.fillStyle = "#effff5"; ctx.font = `800 ${Math.max(30, boardH * .12)}px system-ui`; ctx.textAlign = "center"; ctx.fillText("Game Over", boardW / 2, boardH / 2); }
              ctx.restore();
            }
            function roundRect(x, y, w, h, r) { ctx.beginPath(); ctx.roundRect(x, y, Math.max(1, w), Math.max(1, h), Math.max(1, r)); ctx.fill(); }
            function loop(t) { acc += t - last; last = t; while (acc > 112) { step(); acc -= 112; } draw(); requestAnimationFrame(loop); }
            addEventListener("keydown", e => { if (e.key === "ArrowUp" || e.key === "w") setDir(0,-1); if (e.key === "ArrowDown" || e.key === "s") setDir(0,1); if (e.key === "ArrowLeft" || e.key === "a") setDir(-1,0); if (e.key === "ArrowRight" || e.key === "d") setDir(1,0); if (e.key === " ") paused = !paused; });
            let start; canvas.addEventListener("touchstart", e => start = e.touches[0], {passive: true}); canvas.addEventListener("touchmove", e => { if (!start) return; const t = e.touches[0], dx = t.clientX - start.clientX, dy = t.clientY - start.clientY; if (Math.max(Math.abs(dx), Math.abs(dy)) < 24) return; e.preventDefault(); Math.abs(dx) > Math.abs(dy) ? setDir(Math.sign(dx), 0) : setDir(0, Math.sign(dy)); start = t; }, {passive: false});
            document.querySelector("#restart").onclick = reset; document.querySelector("#pause").onclick = () => paused = !paused;
            addEventListener("resize", requestResize);
            window.visualViewport?.addEventListener("resize", requestResize);
            document.addEventListener("visibilitychange", requestResize);
            reset(); requestAnimationFrame(loop);
          </script>
        </body>
        </html>
        """
    }
}
