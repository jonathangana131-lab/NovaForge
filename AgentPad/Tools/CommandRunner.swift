import Foundation

struct TerminalCommandSuggestion: Hashable, Sendable {
    let command: String
    let label: String
    let symbol: String
    let detail: String
}

enum TerminalCommandCatalog {
    static let supportedCommands = [
        "ls", "pwd", "mkdir", "touch", "rm", "mv", "cp",
        "grep", "find", "cat", "wc", "head", "validate_html"
    ]
    static let supportedCommandSet = Set(supportedCommands)
    static let mutatingCommandSet: Set<String> = ["mkdir", "touch", "rm", "mv", "cp"]

    static let presetCommands = [
        TerminalCommandSuggestion(
            command: "ls",
            label: "ls",
            symbol: "list.bullet.rectangle",
            detail: "List files in the current workspace folder."
        ),
        TerminalCommandSuggestion(
            command: "pwd",
            label: "pwd",
            symbol: "location.fill",
            detail: "Show the sandbox workspace root."
        ),
        TerminalCommandSuggestion(
            command: "find .",
            label: "find .",
            symbol: "folder.badge.questionmark",
            detail: "Show the workspace tree with safe limits."
        )
    ]

    static let quickCheckCommands = [
        TerminalCommandSuggestion(
            command: "head README.md",
            label: "head README",
            symbol: "text.alignleft",
            detail: "Preview the start of README.md."
        ),
        TerminalCommandSuggestion(
            command: "wc README.md",
            label: "wc README",
            symbol: "number",
            detail: "Count lines, words, and bytes in README.md."
        ),
        TerminalCommandSuggestion(
            command: "grep TODO .",
            label: "grep TODO",
            symbol: "magnifyingglass",
            detail: "Search the workspace for TODO."
        ),
        TerminalCommandSuggestion(
            command: "validate_html --profile auto public/index.html",
            label: "validate HTML",
            symbol: "checkmark.seal",
            detail: "Check a generated HTML artifact for preview readiness."
        )
    ]

    private static var baseCommandSuggestions: [TerminalCommandSuggestion] {
        supportedCommands.map { command in
            TerminalCommandSuggestion(
                command: command,
                label: command,
                symbol: "terminal.fill",
                detail: "Type the required sandbox arguments for \(command)."
            )
        }
    }

    static var autocompleteCommands: [TerminalCommandSuggestion] {
        var seen = Set<String>()
        return (presetCommands + quickCheckCommands + baseCommandSuggestions).filter { suggestion in
            seen.insert(suggestion.command).inserted
        }
    }
}

struct TerminalCommandDraft: Equatable, Sendable {
    let commandLine: String
    let tokens: [String]

    init(_ commandLine: String) {
        self.commandLine = commandLine.trimmingCharacters(in: .whitespacesAndNewlines)
        self.tokens = CommandRunner.tokenize(self.commandLine)
    }

    var commandName: String? {
        tokens.first?.lowercased()
    }

    var isKnown: Bool {
        guard let commandName else { return false }
        return TerminalCommandCatalog.supportedCommandSet.contains(commandName)
    }

    var isMutating: Bool {
        guard let commandName else { return false }
        return TerminalCommandCatalog.mutatingCommandSet.contains(commandName)
    }

    var canRun: Bool {
        !commandLine.isEmpty && isKnown && argumentIssue == nil
    }

    var argumentIssue: String? {
        if let shellSyntaxIssue = CommandRunner.shellSyntaxIssue(commandLine) {
            return shellSyntaxIssue
        }
        guard let commandName, isKnown else { return nil }
        let args = Array(tokens.dropFirst())

        switch commandName {
        case "pwd":
            return args.isEmpty ? nil : "pwd does not take a path."
        case "ls":
            return args.count <= 1 ? nil : "ls accepts at most one path."
        case "cat":
            return requireExactlyOnePath(args, command: "cat")
        case "mkdir":
            return requireExactlyOnePath(args, command: "mkdir")
        case "touch":
            return requireExactlyOnePath(args, command: "touch")
        case "rm":
            guard args.count == 1, let path = args.first, !path.hasPrefix("-") else {
                return "rm needs one file or folder path; flags are not available."
            }
            return nil
        case "mv":
            return args.count == 2 ? nil : "mv needs a source path and destination path."
        case "cp":
            return args.count == 2 ? nil : "cp needs a source path and destination path."
        case "grep":
            return args.count == 2 ? nil : "grep needs a query and path, for example grep TODO ."
        case "find":
            return args.count <= 1 ? nil : "find accepts at most one path."
        case "wc":
            return requireExactlyOnePath(args, command: "wc")
        case "head":
            return validateHeadArguments(args)
        case "validate_html":
            return validateHTMLArguments(args)
        default:
            return nil
        }
    }

    var guidance: String {
        guard let commandName else { return "Pick a scoped command preset or type one." }
        if !isKnown {
            return "\(commandName) is not available in the safe iPhone terminal."
        }
        if let argumentIssue {
            return argumentIssue
        }
        if isMutating {
            return "NovaForge will ask before running this workspace mutation."
        }

        switch commandName {
        case "grep":
            return "Searches matching lines inside the workspace path you pass."
        case "find":
            return "Lists workspace paths with depth and row caps for smooth scrolling."
        case "validate_html":
            return "Checks HTML structure and preview readiness without leaving the sandbox."
        case "head", "wc", "cat":
            return "Reads only the requested sandbox file with output limits."
        case "ls", "pwd":
            return "Runs immediately inside the current workspace."
        default:
            return "Runs immediately inside the current workspace; output is capped for smooth scrolling."
        }
    }

    private func requireExactlyOnePath(_ args: [String], command: String) -> String? {
        args.count == 1 ? nil : "\(command) needs exactly one file path."
    }

    private func validateHeadArguments(_ args: [String]) -> String? {
        guard !args.isEmpty else { return "head needs a file path." }
        var path: String?
        var index = 0
        while index < args.count {
            if args[index] == "-n" {
                guard index + 1 < args.count, Int(args[index + 1]) != nil else {
                    return "head -n needs a numeric line count."
                }
                index += 2
            } else if args[index].hasPrefix("-") {
                return "head only supports the -n option."
            } else {
                guard path == nil else { return "head accepts one file path." }
                path = args[index]
                index += 1
            }
        }
        return path == nil ? "head needs a file path." : nil
    }

    private func validateHTMLArguments(_ args: [String]) -> String? {
        guard !args.isEmpty else { return "validate_html needs an HTML file path." }
        var path: String?
        var index = 0
        while index < args.count {
            if args[index] == "--profile" {
                guard index + 1 < args.count else {
                    return "validate_html --profile needs auto, page, or game."
                }
                let candidate = args[index + 1].lowercased()
                guard ["auto", "page", "game"].contains(candidate) else {
                    return "validate_html profile must be auto, page, or game."
                }
                index += 2
            } else if args[index].hasPrefix("-") {
                return "validate_html only supports --profile."
            } else {
                guard path == nil else { return "validate_html accepts one file path." }
                path = args[index]
                index += 1
            }
        }
        return path == nil ? "validate_html needs an HTML file path." : nil
    }
}

protocol TerminalConsoleLineRepresenting: Identifiable, Sendable where ID == UUID {
    var command: String { get }
    var timestamp: Date { get }
}

protocol TerminalConsoleSearchableLineRepresenting: TerminalConsoleLineRepresenting {
    var output: String { get }
}

enum TerminalConsoleState {
    static func mergeLines<Line: TerminalConsoleLineRepresenting>(
        current: [Line],
        recordLines: [Line],
        maxCount: Int
    ) -> [Line] {
        guard !recordLines.isEmpty else { return Array(current.suffix(maxCount)) }
        var linesByID: [UUID: Line] = [:]
        for line in current {
            linesByID[line.id] = line
        }
        for line in recordLines {
            linesByID[line.id] = line
        }
        let sortedLines = linesByID.values.sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return Array(sortedLines.suffix(maxCount))
    }

    static func commandHistory<Line: TerminalConsoleLineRepresenting>(
        from lines: [Line],
        maxCount: Int
    ) -> [String] {
        var seen = Set<String>()
        let commands = lines.compactMap { line -> String? in
            guard seen.insert(line.command).inserted else { return nil }
            return line.command
        }
        return Array(commands.suffix(maxCount))
    }

    static func filteredLines<Line: TerminalConsoleSearchableLineRepresenting>(
        from lines: [Line],
        query: String,
        outputLimit: Int
    ) -> [Line] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return lines }

        return lines.filter { line in
            line.command.localizedCaseInsensitiveContains(trimmedQuery) ||
            boundedContains(line.output, query: trimmedQuery, limit: outputLimit)
        }
    }

    private static func boundedContains(_ text: String, query: String, limit: Int) -> Bool {
        guard !text.isEmpty else { return false }
        let end = text.index(text.startIndex, offsetBy: min(limit, text.count))
        return text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: text.startIndex..<end) != nil
    }
}

struct CommandRunner {
    let workspace: SandboxWorkspace
    private let maxCommandPreviewBytes = 750_000
    private static let shellSyntaxIssueMessage = "Shell operators are not available in the safe iPhone terminal."
    private static let unclosedQuoteIssue = "Close the quoted argument before running."

    func run(_ commandLine: String) throws -> String {
        guard !TerminalCommandDraft(commandLine).isMutating else {
            throw SandboxError.workspaceMutationPermitRequired
        }
        return try runCommand(commandLine, mutationPermit: nil)
    }

    func run(
        _ commandLine: String,
        permit: WorkspaceMutationPermit
    ) throws -> String {
        try runCommand(commandLine, mutationPermit: permit)
    }

    private func runCommand(
        _ commandLine: String,
        mutationPermit: WorkspaceMutationPermit?
    ) throws -> String {
        try rejectShellSyntax(commandLine)
        let tokens = Self.tokenize(commandLine)
        guard let command = tokens.first else { return "" }
        let args = Array(tokens.dropFirst())

        switch command {
        case "pwd":
            guard args.isEmpty else { throw SandboxError.invalidArguments }
            return "/"
        case "ls":
            guard args.count <= 1 else { throw SandboxError.invalidArguments }
            let path = args.first ?? ""
            let items = try workspace.list(path)
            let rows = items.prefix(250).map { item in
                "\(item.isDirectory ? "d" : "-") \(item.name)"
            }
            let suffix = items.count > 250 ? "\n… truncated after 250 items. Use a narrower path." : ""
            return rows.joined(separator: "\n") + suffix
        case "cat":
            guard args.count == 1, let path = args.first else { throw SandboxError.invalidArguments }
            return try workspace.read(path)
        case "mkdir":
            guard args.count == 1, let path = args.first else { throw SandboxError.invalidArguments }
            let permit = try requiredPermit(mutationPermit)
            try validateTerminalMutation(commandLine, permit: permit)
            try workspace.makeDirectory(path, permit: permit)
            return "Created \(path)"
        case "touch":
            // Create an empty file if missing, or refresh its modification
            // date if present. Never read+rewrite: the old implementation did
            // `(try? workspace.read(path)) ?? ""` then wrote that back, which
            // silently truncated files larger than `maxReadableBytes` to empty.
            guard args.count == 1, let path = args.first else { throw SandboxError.invalidArguments }
            let permit = try requiredPermit(mutationPermit)
            try validateTerminalMutation(commandLine, permit: permit)
            try workspace.touch(path, permit: permit)
            return "Touched \(path)"
        case "rm":
            let path = try deletionPath(from: args)
            let permit = try requiredPermit(mutationPermit)
            try validateTerminalMutation(commandLine, permit: permit)
            try workspace.delete(path, permit: permit)
            return "Removed \(path)"
        case "mv":
            guard args.count == 2 else { throw SandboxError.invalidArguments }
            let permit = try requiredPermit(mutationPermit)
            try validateTerminalMutation(commandLine, permit: permit)
            try workspace.move(
                from: args[0],
                to: args[1],
                permit: permit
            )
            return "Moved \(args[0]) to \(args[1])"
        case "cp":
            guard args.count == 2 else { throw SandboxError.invalidArguments }
            let permit = try requiredPermit(mutationPermit)
            try validateTerminalMutation(commandLine, permit: permit)
            try workspace.copy(
                from: args[0],
                to: args[1],
                permit: permit
            )
            return "Copied \(args[0]) to \(args[1])"
        case "grep":
            guard args.count == 2 else { throw SandboxError.invalidArguments }
            return try workspace.search(args[0], in: args[1])
        case "find":
            guard args.count <= 1 else { throw SandboxError.invalidArguments }
            let path = args.first ?? ""
            return try flatten(path)
        case "wc":
            return try wordCount(args)
        case "head":
            return try head(args)
        case "validate_html":
            let parsed = try validateHTMLArguments(args)
            return try validateHTMLFile(path: parsed.path, profile: parsed.profile)
        default:
            throw SandboxError.unsupportedCommand(command)
        }
    }

    private func requiredPermit(
        _ permit: WorkspaceMutationPermit?
    ) throws -> WorkspaceMutationPermit {
        guard let permit else {
            throw SandboxError.workspaceMutationPermitRequired
        }
        return permit
    }

    private func validateTerminalMutation(
        _ commandLine: String,
        permit: WorkspaceMutationPermit
    ) throws {
        try permit.validate(
            workspace: workspace,
            operation: .terminalCommand(
                command: commandLine,
                targetPaths: WorkspaceMutationOperation.terminalTargetPaths(for: commandLine)
            )
        )
    }

    func validateHTMLFile(path: String, profile: String = "auto") throws -> String {
        let normalizedProfile = ["auto", "page", "game"].contains(profile) ? profile : "auto"
        return try validateHTML(path, profile: normalizedProfile)
    }

    static func shellSyntaxIssue(_ commandLine: String) -> String? {
        var quote: Character?
        var index = commandLine.startIndex

        while index < commandLine.endIndex {
            let char = commandLine[index]

            if char == "\"" || char == "'" {
                if quote == char {
                    quote = nil
                } else if quote == nil {
                    quote = char
                }
                index = commandLine.index(after: index)
                continue
            }

            if quote == nil {
                if char == "|" || char == ">" || char == "<" || char == ";" || char == "`" {
                    return shellSyntaxIssueMessage
                }

                let nextIndex = commandLine.index(after: index)
                if nextIndex < commandLine.endIndex {
                    let next = commandLine[nextIndex]
                    if (char == "&" && next == "&") || (char == "$" && next == "(") {
                        return shellSyntaxIssueMessage
                    }
                }
            }

            index = commandLine.index(after: index)
        }

        return quote == nil ? nil : unclosedQuoteIssue
    }

    private func rejectShellSyntax(_ commandLine: String) throws {
        guard let issue = Self.shellSyntaxIssue(commandLine) else { return }
        if issue == Self.unclosedQuoteIssue {
            throw SandboxError.invalidArguments
        }
        throw SandboxError.unsupportedCommand("shell operators are not available")
    }

    private func deletionPath(from args: [String]) throws -> String {
        // Keep the in-app terminal intentionally boring and predictable. The
        // workspace layer already prevents root/path-escape deletes; this guard
        // closes the common footgun where `rm -rf SomeFolder` silently ignored
        // `-rf` and deleted the last token anyway.
        guard args.count == 1, let path = args.first, !path.hasPrefix("-") else {
            throw SandboxError.invalidArguments
        }
        return path
    }

    static func tokenize(_ commandLine: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        for char in commandLine {
            if char == "\"" || char == "'" {
                if quote == char {
                    quote = nil
                } else if quote == nil {
                    quote = char
                } else {
                    current.append(char)
                }
            } else if char.isWhitespace && quote == nil {
                if !current.isEmpty {
                    result.append(current)
                    current = ""
                }
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private func flatten(_ path: String) throws -> String {
        let maxRows = 500
        var rows: [String] = []
        var truncated = false
        func visit(_ relative: String, depth: Int = 0) throws {
            try Task.checkCancellation()
            guard rows.count < maxRows else {
                truncated = true
                return
            }
            for item in try workspace.list(relative) {
                try Task.checkCancellation()
                guard rows.count < maxRows else {
                    truncated = true
                    break
                }
                rows.append(item.relativePath)
                if item.isDirectory, depth < 8 {
                    try visit(item.relativePath, depth: depth + 1)
                } else if item.isDirectory {
                    truncated = true
                }
            }
        }
        try visit(path)
        if rows.isEmpty { return "." }
        if truncated || rows.count >= maxRows {
            rows.append("… truncated after \(rows.count) paths. Use a narrower find path.")
        }
        return rows.joined(separator: "\n")
    }

    private func wordCount(_ args: [String]) throws -> String {
        try Task.checkCancellation()
        guard args.count == 1, let path = args.first, !path.isEmpty else { throw SandboxError.invalidArguments }
        let url = try readableFileURL(path)
        let byteCount = try fileByteCount(at: url)
        if byteCount == 0 {
            return "0 0 0 \(path)"
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var lineCount = 1
        var wordCount = 0
        var inWord = false
        let whitespace = Set<UInt8>([9, 10, 11, 12, 13, 32])
        while true {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
            guard !chunk.isEmpty else { break }
            for byte in chunk {
                if byte == 10 { lineCount += 1 }
                if whitespace.contains(byte) {
                    if inWord { wordCount += 1 }
                    inWord = false
                } else {
                    inWord = true
                }
            }
        }
        if inWord { wordCount += 1 }
        return "\(lineCount) \(wordCount) \(byteCount) \(path)"
    }

    private func readableFileURL(_ path: String) throws -> URL {
        let url = try workspace.resolve(path)
        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        if values.isDirectory == true { throw SandboxError.invalidArguments }
        return url
    }

    private func fileByteCount(at url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func readPrefixText(_ path: String, maxBytes: Int) throws -> (text: String, truncated: Bool) {
        let url = try readableFileURL(path)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maxBytes) ?? Data()
        let truncated = !(try handle.read(upToCount: 1) ?? Data()).isEmpty
        return (String(decoding: data, as: UTF8.self), truncated)
    }

    private func readHeadLines(_ path: String, count: Int) throws -> (lines: [String], truncated: Bool) {
        let url = try readableFileURL(path)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var rows: [String] = []
        rows.reserveCapacity(count)
        var currentLine = Data()
        var bytesRead = 0
        var reachedEOF = false
        var stoppedAfterRequestedLineCount = false

        while rows.count < count && bytesRead < maxCommandPreviewBytes {
            try Task.checkCancellation()
            let remainingBudget = maxCommandPreviewBytes - bytesRead
            let chunk = try handle.read(upToCount: min(64 * 1024, remainingBudget)) ?? Data()
            guard !chunk.isEmpty else {
                reachedEOF = true
                break
            }
            bytesRead += chunk.count
            for byte in chunk {
                if byte == 10 {
                    rows.append(String(decoding: currentLine, as: UTF8.self))
                    currentLine.removeAll(keepingCapacity: true)
                    if rows.count >= count {
                        stoppedAfterRequestedLineCount = true
                        break
                    }
                } else if byte != 13 {
                    currentLine.append(byte)
                }
            }
        }

        if rows.count < count, !currentLine.isEmpty {
            rows.append(String(decoding: currentLine, as: UTF8.self))
        }

        let hasMoreBytes: Bool
        if stoppedAfterRequestedLineCount {
            hasMoreBytes = true
        } else if reachedEOF {
            hasMoreBytes = false
        } else {
            hasMoreBytes = !(try handle.read(upToCount: 1) ?? Data()).isEmpty
        }
        return (rows, hasMoreBytes)
    }


    private func head(_ args: [String]) throws -> String {
        var count = 20
        var path: String?
        var index = 0
        while index < args.count {
            if args[index] == "-n" {
                guard index + 1 < args.count, let parsed = Int(args[index + 1]) else {
                    throw SandboxError.invalidArguments
                }
                count = max(1, min(parsed, 200))
                index += 2
            } else if args[index].hasPrefix("-") {
                throw SandboxError.invalidArguments
            } else {
                guard path == nil else { throw SandboxError.invalidArguments }
                path = args[index]
                index += 1
            }
        }
        guard let path else { throw SandboxError.invalidArguments }
        let result = try readHeadLines(path, count: count)
        try Task.checkCancellation()
        var rows = result.lines
        if result.truncated {
            rows.append("… truncated after \(rows.count) lines. Use a smaller -n or open the file preview.")
        }
        return rows.joined(separator: "\n")
    }

    private func validateHTMLArguments(_ args: [String]) throws -> (path: String, profile: String) {
        var profile = "auto"
        var path: String?
        var index = 0
        while index < args.count {
            if args[index] == "--profile" {
                guard index + 1 < args.count else { throw SandboxError.invalidArguments }
                let candidate = args[index + 1].lowercased()
                profile = ["auto", "page", "game"].contains(candidate) ? candidate : "auto"
                index += 2
            } else if args[index].hasPrefix("-") {
                throw SandboxError.invalidArguments
            } else {
                guard path == nil else { throw SandboxError.invalidArguments }
                path = args[index]
                index += 1
            }
        }
        guard let path else { throw SandboxError.invalidArguments }
        return (path, profile)
    }

    private func validateHTML(_ path: String, profile: String) throws -> String {
        try Task.checkCancellation()
        let prefix = try readPrefixText(path, maxBytes: maxCommandPreviewBytes)
        try Task.checkCancellation()
        let lower = prefix.text.lowercased()
        var checks: [String] = []
        func check(_ label: String, _ condition: Bool) {
            checks.append("\(condition ? "ok" : "missing"): \(label)")
        }
        check("doctype or html tag", lower.contains("<!doctype") || lower.contains("<html"))
        check("head tag", lower.contains("<head"))
        check("body tag", lower.contains("<body"))
        check("responsive viewport", lower.contains("name=\"viewport\"") || lower.contains("name='viewport'"))

        let looksPlayable = lower.contains("<canvas") ||
            lower.contains("requestanimationframe") ||
            lower.contains("touchstart") ||
            lower.contains("pointerdown") ||
            lower.contains("keydown") ||
            lower.contains("game")
        let shouldRequirePlayableChecks = profile == "game" || (profile == "auto" && looksPlayable)
        if shouldRequirePlayableChecks {
            check("script tag", lower.contains("<script"))
            check("canvas or game area", lower.contains("<canvas") || lower.contains("requestanimationframe") || lower.contains("game"))
            check("keyboard/input handling", lower.contains("keydown") || lower.contains("touchstart") || lower.contains("pointerdown"))
        } else {
            check("visible page content", lower.contains("<main") || lower.contains("<section") || lower.contains("<article") || lower.contains("<body"))
            check("local/offline markup", !lower.contains("<script src=\"http") && !lower.contains("<link rel=\"stylesheet\" href=\"http"))
        }

        let failures = checks.filter { $0.hasPrefix("missing") }
        return """
        HTML validation for \(path)
        Profile: \(shouldRequirePlayableChecks ? "playable game" : "responsive page")
        \(checks.joined(separator: "\n"))
        \(prefix.truncated ? "Note: checked the first \(maxCommandPreviewBytes) bytes only." : "")
        Result: \(failures.isEmpty ? "ready for preview" : "\(failures.count) issue(s) to review")
        """
    }
}
