import AgentTools
import Darwin
import Foundation

/// Closed failures for the descriptor-relative workspace reader. No case
/// contains a provider argument, filesystem path, errno, or file content.
enum POSIXWorkspaceReadBackendError: Error, Equatable, Sendable {
    case cancelled
    case workspaceUnavailable
    case invalidRelativePath
    case unsafeFilesystemObject
    case targetChanged
    case unsupportedTool
    case invalidArguments
    case invalidUTF8
    case resourceLimitExceeded
    case outputLimitExceeded
    case operationFailed
}

/// Deterministic race seam used only by focused tests. Production construction
/// uses `.none`; neither closure receives an fd or any filesystem authority.
struct POSIXWorkspaceReadInterposition: Sendable {
    static let none = POSIXWorkspaceReadInterposition(
        beforeOpenComponent: { _ in },
        afterOpenComponent: { _ in }
    )

    let beforeOpenComponent: @Sendable (String) throws -> Void
    let afterOpenComponent: @Sendable (String) throws -> Void
}

/// Production read authority for the canonical twelve sandbox read tools.
///
/// The workspace root is opened once with `O_NOFOLLOW` and retained for this
/// backend's lifetime. Every descendant is opened with `openat` relative to an
/// already-open directory, then checked with both `fstat` and no-follow
/// `fstatat`. Consequently, replacing any pathname component can only make the
/// operation fail; it cannot redirect content reads outside the pinned root.
final class POSIXWorkspaceReadBackend: @unchecked Sendable {
    static let supportedToolNames: Set<String> = [
        "list_directory",
        "list_tree",
        "workspace_summary",
        "file_info",
        "read_file",
        "read_file_range",
        "tail_file",
        "search_text",
        "diff_files",
        "validate_json",
        "validate_html_file",
        "extract_outline",
    ]

    private enum ExpectedKind: Equatable {
        case any
        case directory
        case regularFile
    }

    private struct Limits {
        let maximumPathUTF8Bytes = 4_096
        let maximumDepth = 64
        let maximumDirectoryEntries = 4_096
        let maximumTraversalEntries = 20_000
        let maximumTotalReadBytes = 128 * 1_024 * 1_024
        let maximumScannableFileBytes = 64 * 1_024 * 1_024
        let maximumOutputBytes = 512 * 1_024
        let maximumReadFileBytes = 512 * 1_024
    }

    private struct RootIdentity {
        let device: dev_t
        let inode: ino_t
        let owner: uid_t
        let mode: mode_t

        init(_ metadata: stat) {
            device = metadata.st_dev
            inode = metadata.st_ino
            owner = metadata.st_uid
            mode = metadata.st_mode
        }

        func matches(_ metadata: stat) -> Bool {
            device == metadata.st_dev &&
                inode == metadata.st_ino &&
                owner == metadata.st_uid &&
                mode == metadata.st_mode
        }
    }

    private struct RelativePath {
        let components: [String]

        var string: String { components.joined(separator: "/") }
    }

    private final class OwnedFD {
        let value: Int32

        init(_ value: Int32) {
            self.value = value
        }

        deinit {
            Darwin.close(value)
        }
    }

    private struct OpenedNode {
        let descriptor: OwnedFD
        let metadata: stat

        var fd: Int32 { descriptor.value }
        var isDirectory: Bool {
            metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
        }
    }

    private struct Entry {
        let name: String
        let relativePath: String
        let isDirectory: Bool
        let byteCount: Int64
    }

    private struct SearchMatch {
        let relativePath: String
        let lineNumber: Int
        let lineContent: String
    }

    private struct SearchReport {
        var matches: [SearchMatch] = []
        var filesScanned = 0
        var searchedDirectories = 0
        var capped = false
    }

    private struct OperationBudget {
        let limits: Limits
        var entries = 0
        var bytesRead = 0

        mutating func consumeEntry() throws {
            let next = entries.addingReportingOverflow(1)
            guard !next.overflow,
                  next.partialValue <= limits.maximumTraversalEntries else {
                throw POSIXWorkspaceReadBackendError.resourceLimitExceeded
            }
            entries = next.partialValue
        }

        mutating func consumeBytes(_ count: Int) throws {
            guard count >= 0 else {
                throw POSIXWorkspaceReadBackendError.operationFailed
            }
            let next = bytesRead.addingReportingOverflow(count)
            guard !next.overflow,
                  next.partialValue <= limits.maximumTotalReadBytes else {
                throw POSIXWorkspaceReadBackendError.resourceLimitExceeded
            }
            bytesRead = next.partialValue
        }

        var remainingBytes: Int {
            max(0, limits.maximumTotalReadBytes - bytesRead)
        }
    }

    private let rootFD: Int32
    private let rootIdentity: RootIdentity
    private let ownerUID: uid_t
    private let workspaceName: String
    private let maximumReadableBytes: Int
    private let limits = Limits()
    private let interposition: POSIXWorkspaceReadInterposition

    init(
        workspace: SandboxWorkspace,
        expectedIdentity: WorkspaceResourceIdentity,
        interposition: POSIXWorkspaceReadInterposition = .none
    ) throws {
        guard try WorkspaceResourceIdentity(workspace: workspace)
                == expectedIdentity else {
            throw POSIXWorkspaceReadBackendError.workspaceUnavailable
        }
        let root = try workspace.resolve("").standardizedFileURL
        guard !root.path.utf8.contains(0) else {
            throw POSIXWorkspaceReadBackendError.workspaceUnavailable
        }

        var before = stat()
        guard root.path.withCString({ Darwin.lstat($0, &before) }) == 0 else {
            throw POSIXWorkspaceReadBackendError.workspaceUnavailable
        }
        let expectedOwner = Darwin.geteuid()
        try Self.validateMetadata(
            before,
            ownerUID: expectedOwner,
            expected: .directory
        )

        let descriptor = root.path.withCString {
            Darwin.open(
                $0,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard descriptor >= 0 else {
            throw POSIXWorkspaceReadBackendError.workspaceUnavailable
        }

        do {
            let opened = try Self.metadata(descriptor)
            try Self.validateMetadata(
                opened,
                ownerUID: expectedOwner,
                expected: .directory
            )
            var after = stat()
            guard root.path.withCString({ Darwin.lstat($0, &after) }) == 0,
                  Self.sameNode(before, opened),
                  Self.sameNode(opened, after),
                  Self.sameSecurityMetadata(before, opened),
                  Self.sameSecurityMetadata(opened, after) else {
                throw POSIXWorkspaceReadBackendError.targetChanged
            }
            rootFD = descriptor
            rootIdentity = RootIdentity(opened)
            ownerUID = expectedOwner
            workspaceName = workspace.workspaceName
            maximumReadableBytes = min(
                max(1, workspace.maxReadableBytes),
                Limits().maximumReadFileBytes
            )
            self.interposition = interposition
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    deinit {
        Darwin.close(rootFD)
    }

    func execute(_ request: LegacySandboxToolRequest) async throws -> String {
        do {
            try Task.checkCancellation()
            guard Self.supportedToolNames.contains(request.name) else {
                throw POSIXWorkspaceReadBackendError.unsupportedTool
            }
            try validatePinnedRoot()
            var budget = OperationBudget(limits: limits)
            let output: String
            switch request.name {
            case "list_directory":
                output = try listDirectory(request, budget: &budget)
            case "list_tree":
                output = try listTree(request, budget: &budget)
            case "workspace_summary":
                output = try workspaceSummary(request, budget: &budget)
            case "file_info":
                output = try fileInfo(request, budget: &budget)
            case "read_file":
                output = try readFile(request, budget: &budget)
            case "read_file_range":
                output = try readFileRange(request, budget: &budget)
            case "tail_file":
                output = try tailFile(request, budget: &budget)
            case "search_text":
                output = try searchText(request, budget: &budget)
            case "diff_files":
                output = try diffFiles(request, budget: &budget)
            case "validate_json":
                output = try validateJSON(request, budget: &budget)
            case "validate_html_file":
                output = try validateHTML(request, budget: &budget)
            case "extract_outline":
                output = try extractOutline(request, budget: &budget)
            default:
                throw POSIXWorkspaceReadBackendError.unsupportedTool
            }
            try Task.checkCancellation()
            try validatePinnedRoot()
            return try boundedOutput(output)
        } catch is CancellationError {
            throw POSIXWorkspaceReadBackendError.cancelled
        }
    }

    static func validateRelativeTarget(_ raw: String, allowRoot: Bool) throws {
        _ = try parsePath(raw, allowRoot: allowRoot, limits: Limits())
    }

    private func listDirectory(
        _ request: LegacySandboxToolRequest,
        budget: inout OperationBudget
    ) throws -> String {
        let rawPath = request.arguments["path"] ?? ""
        let path = try Self.parsePath(rawPath, allowRoot: true, limits: limits)
        let directory = try openPath(path, expected: .directory)
        let names = try directoryNames(directory)
        var entries: [Entry] = []
        entries.reserveCapacity(min(names.count, 251))
        for name in names {
            try Task.checkCancellation()
            try budget.consumeEntry()
            let relative = Self.appending(name, to: path.string)
            let child = try openComponent(
                parent: directory.fd,
                name: name,
                logicalPath: relative,
                expected: .any
            )
            entries.append(Self.entry(name: name, path: relative, node: child))
        }
        try verifyStable(directory)
        entries.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }
            return lhs.name.localizedStandardCompare(rhs.name)
                == .orderedAscending
        }
        let rows = entries.prefix(250).map {
            "\($0.isDirectory ? "folder" : "file"): \($0.relativePath)"
        }
        let suffix = entries.count > 250
            ? "\n… truncated after 250 items. Use a narrower directory path."
            : ""
        return rows.joined(separator: "\n") + suffix
    }

    private func listTree(
        _ request: LegacySandboxToolRequest,
        budget: inout OperationBudget
    ) throws -> String {
        let maxItems = intArgument(
            "max_items",
            request: request,
            default: 250,
            range: 1 ... 800
        )
        let maxDepth = intArgument(
            "max_depth",
            request: request,
            default: 5,
            range: 1 ... 10
        )
        let items = try manifest(
            maximumItems: maxItems,
            maximumDepth: maxDepth,
            budget: &budget
        )
        let rows = items.map { item -> String in
            let depth = item.relativePath.split(separator: "/").count - 1
            let indent = String(repeating: "  ", count: max(0, depth))
            return "\(indent)\(item.isDirectory ? "▸" : "•") \(item.name)"
        }
        let suffix = items.count >= maxItems
            ? "\n… truncated after \(maxItems) items."
            : ""
        return rows.joined(separator: "\n") + suffix
    }

    private func workspaceSummary(
        _ request: LegacySandboxToolRequest,
        budget: inout OperationBudget
    ) throws -> String {
        let maxItems = intArgument(
            "max_items",
            request: request,
            default: 800,
            range: 50 ... 2_000
        )
        let items = try manifest(
            maximumItems: maxItems,
            maximumDepth: 10,
            budget: &budget
        )
        let files = items.filter { !$0.isDirectory }
        let folders = items.filter(\.isDirectory)
        let totalBytes = files.reduce(Int64(0)) { partial, item in
            let next = partial.addingReportingOverflow(item.byteCount)
            return next.overflow ? Int64.max : next.partialValue
        }
        let extensions = Dictionary(grouping: files) { item -> String in
            let value = (item.name as NSString).pathExtension.lowercased()
            return value.isEmpty ? "no extension" : value
        }
        let topExtensions = extensions
            .map { "\($0.key): \($0.value.count)" }
            .sorted()
            .prefix(12)
            .joined(separator: ", ")
        return """
        Workspace: \(workspaceName)
        Files: \(files.count)
        Folders: \(folders.count)
        Bytes: \(totalBytes)
        Types: \(topExtensions.isEmpty ? "none" : topExtensions)
        """
    }

    private func fileInfo(
        _ request: LegacySandboxToolRequest,
        budget: inout OperationBudget
    ) throws -> String {
        let rawPath = try required("path", request: request)
        let path = try Self.parsePath(rawPath, allowRoot: true, limits: limits)
        let node = try openPath(path, expected: .any)
        try budget.consumeEntry()
        try verifyStable(node)
        return """
        Path: \(rawPath)
        Kind: \(node.isDirectory ? "folder" : "file")
        Bytes: \(max(0, Int64(node.metadata.st_size)))
        Created: \(Self.dateDescription(node.metadata.st_birthtimespec))
        Modified: \(Self.dateDescription(node.metadata.st_mtimespec))
        """
    }

    private func readFile(
        _ request: LegacySandboxToolRequest,
        budget: inout OperationBudget
    ) throws -> String {
        let path = try Self.parsePath(
            try required("path", request: request),
            allowRoot: false,
            limits: limits
        )
        let file = try openPath(path, expected: .regularFile)
        try budget.consumeEntry()
        let data = try readComplete(
            file,
            maximumBytes: maximumReadableBytes,
            budget: &budget
        )
        guard let value = String(data: data, encoding: .utf8) else {
            throw POSIXWorkspaceReadBackendError.invalidUTF8
        }
        return value
    }

    private func readFileRange(
        _ request: LegacySandboxToolRequest,
        budget: inout OperationBudget
    ) throws -> String {
        let path = try Self.parsePath(
            try required("path", request: request),
            allowRoot: false,
            limits: limits
        )
        let start = intArgument(
            "start_line",
            request: request,
            default: 1,
            range: 1 ... 50_000
        )
        let count = intArgument(
            "line_count",
            request: request,
            default: 80,
            range: 1 ... 400
        )
        let file = try openPath(path, expected: .regularFile)
        try budget.consumeEntry()
        let prefix = try readPrefix(
            file,
            maximumBytes: limits.maximumScannableFileBytes,
            budget: &budget
        )
        let end = start + count - 1
        var currentLine = 1
        var current = Data()
        var rows: [String] = []
        var lastWasNewline = false

        func emit() throws {
            if currentLine >= start && currentLine <= end {
                rows.append("\(currentLine)|\(Self.decodeLine(current))")
                try Self.validateOutputRows(rows, limits: limits)
            }
            current.removeAll(keepingCapacity: true)
            currentLine += 1
        }

        for byte in prefix.data {
            try Task.checkCancellation()
            lastWasNewline = byte == 10
            if byte == 10 {
                try emit()
                if currentLine > end { return rows.joined(separator: "\n") }
            } else if currentLine >= start && currentLine <= end {
                current.append(byte)
                guard current.count <= limits.maximumOutputBytes else {
                    throw POSIXWorkspaceReadBackendError.outputLimitExceeded
                }
            }
        }
        if currentLine <= end {
            if !current.isEmpty {
                try emit()
            } else if !prefix.data.isEmpty && lastWasNewline {
                try emit()
            }
        }
        if prefix.truncated && currentLine <= end {
            throw POSIXWorkspaceReadBackendError.resourceLimitExceeded
        }
        return rows.joined(separator: "\n")
    }

    private func tailFile(
        _ request: LegacySandboxToolRequest,
        budget: inout OperationBudget
    ) throws -> String {
        let path = try Self.parsePath(
            try required("path", request: request),
            allowRoot: false,
            limits: limits
        )
        let count = intArgument(
            "line_count",
            request: request,
            default: 60,
            range: 1 ... 300
        )
        let file = try openPath(path, expected: .regularFile)
        try budget.consumeEntry()
        let data = try readComplete(
            file,
            maximumBytes: limits.maximumScannableFileBytes,
            budget: &budget
        )
        guard !data.isEmpty else { return "" }

        let maximumTailBytes = max(maximumReadableBytes, 256_000)
        let bytesToRead = min(data.count, maximumTailBytes)
        var windowStart = data.count - bytesToRead
        var window = Data(data[windowStart ..< data.endIndex])
        var note: String?
        if windowStart > 0 {
            if let newline = window.firstIndex(of: 10) {
                let next = window.index(after: newline)
                windowStart += window.distance(from: window.startIndex, to: next)
                window.removeSubrange(window.startIndex ..< next)
            } else {
                note = "… tail truncated to the last \(bytesToRead) bytes of one very long line."
            }
        }

        let parsed = Self.lines(from: window)
        guard !parsed.isEmpty else { return note ?? "" }
        let selectedStart = max(0, parsed.count - count)
        let firstParsedLine = data[..<windowStart].reduce(0) {
            $0 + ($1 == 10 ? 1 : 0)
        } + 1
        let firstSelectedLine = firstParsedLine + selectedStart
        var rows = parsed.dropFirst(selectedStart).enumerated().map {
            "\(firstSelectedLine + $0.offset)|\($0.element)"
        }
        if let note {
            rows.append(note)
        } else if windowStart > 0 && parsed.count < count {
            rows.append(
                "… tail truncated before the last \(parsed.count) complete line(s)."
            )
        }
        try Self.validateOutputRows(rows, limits: limits)
        return rows.joined(separator: "\n")
    }

    private func searchText(
        _ request: LegacySandboxToolRequest,
        budget: inout OperationBudget
    ) throws -> String {
        let query = try required("query", request: request)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return "No matches." }
        let path = try Self.parsePath(
            request.arguments["path"] ?? "",
            allowRoot: true,
            limits: limits
        )
        let start = try openPath(path, expected: .any)
        var report = SearchReport()
        let maxFiles = 600
        let maxDirectories = 160
        let maxMatches = 120
        let perFileLimit = min(750_000, maximumReadableBytes)

        func scanFile(
            _ file: OpenedNode,
            relativePath: String,
            report: inout SearchReport,
            budget: inout OperationBudget
        ) throws {
            try Task.checkCancellation()
            guard report.filesScanned < maxFiles else {
                report.capped = true
                return
            }
            report.filesScanned += 1
            if relativePath.localizedCaseInsensitiveContains(query) {
                report.matches.append(SearchMatch(
                    relativePath: relativePath,
                    lineNumber: 1,
                    lineContent: "Path: \(relativePath)"
                ))
                if report.matches.count >= maxMatches {
                    report.capped = true
                    return
                }
            }
            let size = max(0, Int(file.metadata.st_size))
            guard size <= perFileLimit else { return }
            guard size <= budget.remainingBytes else {
                report.capped = true
                return
            }
            let data = try readComplete(
                file,
                maximumBytes: perFileLimit,
                budget: &budget
            )
            guard String(data: data, encoding: .utf8) != nil else {
                return
            }
            var lineNumber = 0
            var lineStart = data.startIndex
            while lineStart < data.endIndex {
                try Task.checkCancellation()
                let newline = data[lineStart...].firstIndex(of: 10)
                let lineEnd = newline ?? data.endIndex
                lineNumber += 1
                if report.matches.count >= maxMatches {
                    report.capped = true
                    break
                }
                let line = Self.decodeLine(Data(data[lineStart ..< lineEnd]))
                if line.localizedCaseInsensitiveContains(query) {
                    let trimmed = line.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                    let preview = trimmed.count > 240
                        ? String(trimmed.prefix(240)) + "…"
                        : trimmed
                    report.matches.append(SearchMatch(
                        relativePath: relativePath,
                        lineNumber: lineNumber,
                        lineContent: preview
                    ))
                }
                if report.matches.count >= maxMatches {
                    report.capped = true
                    break
                }
                guard let newline else { break }
                lineStart = data.index(after: newline)
            }
        }

        if !start.isDirectory {
            try budget.consumeEntry()
            try scanFile(
                start,
                relativePath: path.string,
                report: &report,
                budget: &budget
            )
        } else {
            var pending: [(path: String, node: OpenedNode)] = [
                (path.string, start),
            ]
            var index = 0
            while index < pending.count {
                try Task.checkCancellation()
                guard report.matches.count < maxMatches,
                      report.searchedDirectories < maxDirectories else {
                    report.capped = true
                    break
                }
                let directory = pending[index]
                index += 1
                report.searchedDirectories += 1
                let names = try directoryNames(directory.node)
                for name in names {
                    try Task.checkCancellation()
                    guard report.matches.count < maxMatches else {
                        report.capped = true
                        break
                    }
                    try budget.consumeEntry()
                    let relative = Self.appending(name, to: directory.path)
                    let child = try openComponent(
                        parent: directory.node.fd,
                        name: name,
                        logicalPath: relative,
                        expected: .any
                    )
                    if child.isDirectory {
                        if pending.count - index + report.searchedDirectories
                            < maxDirectories {
                            pending.append((relative, child))
                        } else {
                            report.capped = true
                        }
                    } else {
                        try scanFile(
                            child,
                            relativePath: relative,
                            report: &report,
                            budget: &budget
                        )
                    }
                }
                try verifyStable(directory.node)
            }
        }

        guard !report.matches.isEmpty else { return "No matches." }
        var returnedBytes = 0
        var rows: [String] = []
        for match in report.matches {
            let row = "\(match.relativePath):\(match.lineNumber): \(match.lineContent)"
            if returnedBytes + row.utf8.count + 1 > 18_000 {
                rows.append(
                    "… truncated after output limit. Narrow the query or path for more."
                )
                return rows.joined(separator: "\n")
            }
            rows.append(row)
            returnedBytes += row.utf8.count + 1
        }
        if report.capped {
            rows.append(
                "… truncated for smoothness after \(report.filesScanned) files / \(report.searchedDirectories) folders. Narrow the query or path for more."
            )
        }
        return rows.joined(separator: "\n")
    }

    private func diffFiles(
        _ request: LegacySandboxToolRequest,
        budget: inout OperationBudget
    ) throws -> String {
        let leftRaw = try required("left", request: request)
        let rightRaw = try required("right", request: request)
        let left = try diffLines(
            Self.parsePath(leftRaw, allowRoot: false, limits: limits),
            budget: &budget
        )
        let right = try diffLines(
            Self.parsePath(rightRaw, allowRoot: false, limits: limits),
            budget: &budget
        )
        var rows = ["--- \(leftRaw)", "+++ \(rightRaw)"]
        let maximumCount = max(left.lines.count, right.lines.count)
        for index in 0 ..< maximumCount {
            try Task.checkCancellation()
            if rows.count >= 220 {
                rows.append("… diff truncated")
                break
            }
            let lhs = index < left.lines.count ? left.lines[index] : nil
            let rhs = index < right.lines.count ? right.lines[index] : nil
            if lhs == rhs { continue }
            if let lhs { rows.append("-\(index + 1)|\(lhs)") }
            if let rhs { rows.append("+\(index + 1)|\(rhs)") }
        }
        if left.truncated || right.truncated {
            rows.append(
                "… compared a bounded prefix only; use read_file_range or tail_file for deeper sections."
            )
        }
        try Self.validateOutputRows(rows, limits: limits)
        return rows.joined(separator: "\n")
    }

    private func validateJSON(
        _ request: LegacySandboxToolRequest,
        budget: inout OperationBudget
    ) throws -> String {
        let rawPath = try required("path", request: request)
        let path = try Self.parsePath(rawPath, allowRoot: false, limits: limits)
        let file = try openPath(path, expected: .regularFile)
        try budget.consumeEntry()
        let byteCount = max(0, Int64(file.metadata.st_size))
        guard byteCount <= 2_000_000 else {
            return "JSON validation for \(rawPath): skipped — file is too large to validate in one tool call (\(byteCount) bytes). Use read_file_range or tail_file to inspect a bounded section."
        }
        let data = try readComplete(
            file,
            maximumBytes: 2_000_000,
            budget: &budget
        )
        do {
            _ = try JSONSerialization.jsonObject(with: data)
            return "JSON validation for \(rawPath): ok"
        } catch {
            return "JSON validation for \(rawPath): failed — \(error.localizedDescription)"
        }
    }

    private func validateHTML(
        _ request: LegacySandboxToolRequest,
        budget: inout OperationBudget
    ) throws -> String {
        let rawPath = try required("path", request: request)
        let path = try Self.parsePath(rawPath, allowRoot: false, limits: limits)
        let profile = request.arguments["profile"].flatMap {
            ["page", "game", "auto"].contains($0) ? $0 : nil
        } ?? "auto"
        let file = try openPath(path, expected: .regularFile)
        try budget.consumeEntry()
        let prefix = try readPrefix(
            file,
            maximumBytes: 750_000,
            budget: &budget
        )
        let lower = String(decoding: prefix.data, as: UTF8.self).lowercased()
        var checks: [String] = []
        func check(_ label: String, _ condition: Bool) {
            checks.append("\(condition ? "ok" : "missing"): \(label)")
        }
        check(
            "doctype or html tag",
            lower.contains("<!doctype") || lower.contains("<html")
        )
        check("head tag", lower.contains("<head"))
        check("body tag", lower.contains("<body"))
        check(
            "responsive viewport",
            lower.contains("name=\"viewport\"") ||
                lower.contains("name='viewport'")
        )
        let looksPlayable = lower.contains("<canvas") ||
            lower.contains("requestanimationframe") ||
            lower.contains("touchstart") ||
            lower.contains("pointerdown") ||
            lower.contains("keydown") ||
            lower.contains("game")
        let playable = profile == "game" || (profile == "auto" && looksPlayable)
        if playable {
            check("script tag", lower.contains("<script"))
            check(
                "canvas or game area",
                lower.contains("<canvas") ||
                    lower.contains("requestanimationframe") ||
                    lower.contains("game")
            )
            check(
                "keyboard/input handling",
                lower.contains("keydown") ||
                    lower.contains("touchstart") ||
                    lower.contains("pointerdown")
            )
        } else {
            check(
                "visible page content",
                lower.contains("<main") || lower.contains("<section") ||
                    lower.contains("<article") || lower.contains("<body")
            )
            check(
                "local/offline markup",
                !lower.contains("<script src=\"http") &&
                    !lower.contains("<link rel=\"stylesheet\" href=\"http")
            )
        }
        let failures = checks.filter { $0.hasPrefix("missing") }
        return """
        HTML validation for \(rawPath)
        Profile: \(playable ? "playable game" : "responsive page")
        \(checks.joined(separator: "\n"))
        \(prefix.truncated ? "Note: checked the first 750000 bytes only." : "")
        Result: \(failures.isEmpty ? "ready for preview" : "\(failures.count) issue(s) to review")
        """
    }

    private func extractOutline(
        _ request: LegacySandboxToolRequest,
        budget: inout OperationBudget
    ) throws -> String {
        let path = try Self.parsePath(
            try required("path", request: request),
            allowRoot: false,
            limits: limits
        )
        let file = try openPath(path, expected: .regularFile)
        try budget.consumeEntry()
        let prefix = try readPrefix(
            file,
            maximumBytes: 1_000_000,
            budget: &budget
        )
        let interesting = [
            "func ", "struct ", "class ", "enum ", "protocol ",
            "extension ", "const ", "let ", "function ", "#", "##",
        ]
        var rows: [String] = []
        var lineNumber = 1
        var current = Data()
        var truncatedByRows = false

        func inspect() {
            let value = Self.decodeLine(current)
                .trimmingCharacters(in: .whitespaces)
            if interesting.contains(where: value.hasPrefix) {
                if rows.count < 180 {
                    rows.append("\(lineNumber)|\(value)")
                } else {
                    truncatedByRows = true
                }
            }
            current.removeAll(keepingCapacity: true)
            lineNumber += 1
        }

        for byte in prefix.data {
            try Task.checkCancellation()
            if byte == 10 {
                inspect()
                if truncatedByRows { break }
            } else {
                current.append(byte)
            }
        }
        if !current.isEmpty && !truncatedByRows { inspect() }
        if truncatedByRows {
            rows.append(
                "… outline truncated after 180 matches. Use search_text or read_file_range for narrower inspection."
            )
        } else if prefix.truncated {
            rows.append(
                "… outline scanned first 1000000 bytes only. Use read_file_range or search_text for deeper sections."
            )
        }
        try Self.validateOutputRows(rows, limits: limits)
        return rows.joined(separator: "\n")
    }

    private func manifest(
        maximumItems: Int,
        maximumDepth: Int,
        budget: inout OperationBudget
    ) throws -> [Entry] {
        let root = try openRootDirectory()
        var items: [Entry] = []

        func visit(
            _ directory: OpenedNode,
            path: String,
            depth: Int,
            items: inout [Entry],
            budget: inout OperationBudget
        ) throws {
            guard items.count < maximumItems else { return }
            let names = try directoryNames(directory)
            for name in names {
                try Task.checkCancellation()
                guard items.count < maximumItems else { break }
                try budget.consumeEntry()
                let relative = Self.appending(name, to: path)
                let child = try openComponent(
                    parent: directory.fd,
                    name: name,
                    logicalPath: relative,
                    expected: .any
                )
                items.append(Self.entry(name: name, path: relative, node: child))
                let childDepth = depth + 1
                if child.isDirectory && childDepth < maximumDepth {
                    try visit(
                        child,
                        path: relative,
                        depth: childDepth,
                        items: &items,
                        budget: &budget
                    )
                }
            }
            try verifyStable(directory)
        }

        try visit(
            root,
            path: "",
            depth: 0,
            items: &items,
            budget: &budget
        )
        return items.sorted {
            $0.relativePath.localizedStandardCompare($1.relativePath)
                == .orderedAscending
        }
    }

    private func diffLines(
        _ path: RelativePath,
        budget: inout OperationBudget
    ) throws -> (lines: [String], truncated: Bool) {
        let file = try openPath(path, expected: .regularFile)
        try budget.consumeEntry()
        let prefix = try readPrefix(
            file,
            maximumBytes: 1_000_000,
            budget: &budget
        )
        var rows = Self.lines(from: prefix.data)
        var truncated = prefix.truncated
        if rows.count > 600 {
            rows = Array(rows.prefix(600))
            truncated = true
        }
        return (rows, truncated)
    }

    private func openPath(
        _ path: RelativePath,
        expected: ExpectedKind
    ) throws -> OpenedNode {
        var current = try openRootDirectory()
        guard !path.components.isEmpty else {
            guard expected != .regularFile else {
                throw POSIXWorkspaceReadBackendError.unsafeFilesystemObject
            }
            return current
        }
        var traversed: [String] = []
        for (index, component) in path.components.enumerated() {
            try Task.checkCancellation()
            traversed.append(component)
            current = try openComponent(
                parent: current.fd,
                name: component,
                logicalPath: traversed.joined(separator: "/"),
                expected: index == path.components.count - 1
                    ? expected
                    : .directory
            )
        }
        return current
    }

    private func openRootDirectory() throws -> OpenedNode {
        try Task.checkCancellation()
        let descriptor = Darwin.openat(
            rootFD,
            ".",
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw POSIXWorkspaceReadBackendError.workspaceUnavailable
        }
        let owned = OwnedFD(descriptor)
        let value = try Self.metadata(descriptor)
        try Self.validateMetadata(
            value,
            ownerUID: ownerUID,
            expected: .directory
        )
        guard rootIdentity.matches(value) else {
            throw POSIXWorkspaceReadBackendError.targetChanged
        }
        return OpenedNode(descriptor: owned, metadata: value)
    }

    private func openComponent(
        parent: Int32,
        name: String,
        logicalPath: String,
        expected: ExpectedKind
    ) throws -> OpenedNode {
        try Task.checkCancellation()
        try interposition.beforeOpenComponent(logicalPath)
        try Task.checkCancellation()
        guard let discovered = try Self.metadataNoFollow(
            parent: parent,
            name: name
        ) else {
            throw POSIXWorkspaceReadBackendError.targetChanged
        }
        try Self.validateMetadata(
            discovered,
            ownerUID: ownerUID,
            expected: expected
        )
        let flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW |
            (expected == .directory ? O_DIRECTORY : 0)
        let descriptor = name.withCString {
            Darwin.openat(parent, $0, flags)
        }
        guard descriptor >= 0 else {
            switch errno {
            case ELOOP, ENOTDIR:
                throw POSIXWorkspaceReadBackendError.unsafeFilesystemObject
            case ENOENT:
                throw POSIXWorkspaceReadBackendError.targetChanged
            default:
                throw POSIXWorkspaceReadBackendError.operationFailed
            }
        }
        let owned = OwnedFD(descriptor)
        let opened = try Self.metadata(descriptor)
        try Self.validateMetadata(
            opened,
            ownerUID: ownerUID,
            expected: expected
        )
        guard Self.sameNode(discovered, opened),
              Self.sameSecurityMetadata(discovered, opened) else {
            throw POSIXWorkspaceReadBackendError.targetChanged
        }
        try interposition.afterOpenComponent(logicalPath)
        try Task.checkCancellation()
        guard let named = try Self.metadataNoFollow(parent: parent, name: name),
              Self.sameNode(opened, named),
              Self.sameSecurityMetadata(opened, named) else {
            throw POSIXWorkspaceReadBackendError.targetChanged
        }
        return OpenedNode(descriptor: owned, metadata: opened)
    }

    private func directoryNames(_ directory: OpenedNode) throws -> [String] {
        guard directory.isDirectory else {
            throw POSIXWorkspaceReadBackendError.unsafeFilesystemObject
        }
        let streamFD = Darwin.openat(
            directory.fd,
            ".",
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard streamFD >= 0 else {
            throw POSIXWorkspaceReadBackendError.operationFailed
        }
        let streamMetadata: stat
        do {
            streamMetadata = try Self.metadata(streamFD)
        } catch {
            Darwin.close(streamFD)
            throw error
        }
        guard Self.sameNode(directory.metadata, streamMetadata),
              let stream = Darwin.fdopendir(streamFD) else {
            Darwin.close(streamFD)
            throw POSIXWorkspaceReadBackendError.targetChanged
        }
        defer { Darwin.closedir(stream) }

        var names: [String] = []
        var observed = 0
        while true {
            try Task.checkCancellation()
            errno = 0
            guard let entry = Darwin.readdir(stream) else {
                guard errno == 0 else {
                    throw POSIXWorkspaceReadBackendError.operationFailed
                }
                break
            }
            observed += 1
            guard observed <= limits.maximumDirectoryEntries + 2 else {
                throw POSIXWorkspaceReadBackendError.resourceLimitExceeded
            }
            let name: String? = withUnsafePointer(to: &entry.pointee.d_name) {
                pointer in
                pointer.withMemoryRebound(
                    to: CChar.self,
                    capacity: Int(NAME_MAX) + 1
                ) {
                    String(validatingCString: $0)
                }
            }
            guard let name else {
                throw POSIXWorkspaceReadBackendError.unsafeFilesystemObject
            }
            if name == "." || name == ".." || name.hasPrefix(".") {
                continue
            }
            guard Self.isSafeComponent(name) else {
                throw POSIXWorkspaceReadBackendError.unsafeFilesystemObject
            }
            names.append(name)
        }
        try verifyStable(directory)
        return names.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    private func readComplete(
        _ file: OpenedNode,
        maximumBytes: Int,
        budget: inout OperationBudget
    ) throws -> Data {
        let size = max(0, Int64(file.metadata.st_size))
        guard size <= Int64(maximumBytes),
              size <= Int64(Int.max) else {
            throw POSIXWorkspaceReadBackendError.resourceLimitExceeded
        }
        let result = try read(
            file,
            maximumBytes: maximumBytes,
            stopAtLimit: false,
            budget: &budget
        )
        guard !result.truncated,
              result.data.count == Int(size) else {
            throw POSIXWorkspaceReadBackendError.targetChanged
        }
        return result.data
    }

    private func readPrefix(
        _ file: OpenedNode,
        maximumBytes: Int,
        budget: inout OperationBudget
    ) throws -> (data: Data, truncated: Bool) {
        try read(
            file,
            maximumBytes: maximumBytes,
            stopAtLimit: true,
            budget: &budget
        )
    }

    private func read(
        _ file: OpenedNode,
        maximumBytes: Int,
        stopAtLimit: Bool,
        budget: inout OperationBudget
    ) throws -> (data: Data, truncated: Bool) {
        guard !file.isDirectory,
              maximumBytes >= 0 else {
            throw POSIXWorkspaceReadBackendError.unsafeFilesystemObject
        }
        var result = Data()
        result.reserveCapacity(min(maximumBytes, max(0, Int(file.metadata.st_size))))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        var offset: off_t = 0
        while result.count < maximumBytes {
            try Task.checkCancellation()
            let requested = min(buffer.count, maximumBytes - result.count)
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return Darwin.pread(file.fd, base, requested, offset)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw POSIXWorkspaceReadBackendError.operationFailed
            }
            if count == 0 { break }
            try budget.consumeBytes(count)
            result.append(buffer, count: count)
            offset += off_t(count)
        }
        try verifyStable(file)
        let declaredSize = max(0, Int64(file.metadata.st_size))
        let truncated = declaredSize > Int64(result.count)
        if !stopAtLimit && truncated {
            throw POSIXWorkspaceReadBackendError.resourceLimitExceeded
        }
        return (result, truncated)
    }

    private func verifyStable(_ node: OpenedNode) throws {
        let current = try Self.metadata(node.fd)
        guard Self.sameStableMetadata(node.metadata, current) else {
            throw POSIXWorkspaceReadBackendError.targetChanged
        }
    }

    private func validatePinnedRoot() throws {
        let current = try Self.metadata(rootFD)
        try Self.validateMetadata(
            current,
            ownerUID: ownerUID,
            expected: .directory
        )
        guard rootIdentity.matches(current) else {
            throw POSIXWorkspaceReadBackendError.targetChanged
        }
    }

    private func required(
        _ key: String,
        request: LegacySandboxToolRequest
    ) throws -> String {
        guard let value = request.arguments[key], !value.isEmpty else {
            throw POSIXWorkspaceReadBackendError.invalidArguments
        }
        return value
    }

    private func intArgument(
        _ key: String,
        request: LegacySandboxToolRequest,
        default defaultValue: Int,
        range: ClosedRange<Int>
    ) -> Int {
        guard let raw = request.arguments[key], let value = Int(raw) else {
            return defaultValue
        }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    private func boundedOutput(_ output: String) throws -> String {
        guard output.utf8.count <= limits.maximumOutputBytes else {
            throw POSIXWorkspaceReadBackendError.outputLimitExceeded
        }
        return output
    }

    private static func validateOutputRows(
        _ rows: [String],
        limits: Limits
    ) throws {
        var bytes = max(0, rows.count - 1)
        for row in rows {
            let next = bytes.addingReportingOverflow(row.utf8.count)
            guard !next.overflow,
                  next.partialValue <= limits.maximumOutputBytes else {
                throw POSIXWorkspaceReadBackendError.outputLimitExceeded
            }
            bytes = next.partialValue
        }
    }

    private static func parsePath(
        _ raw: String,
        allowRoot: Bool,
        limits: Limits
    ) throws -> RelativePath {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count <= limits.maximumPathUTF8Bytes,
              !trimmed.utf8.contains(0),
              !trimmed.hasPrefix("/") else {
            throw POSIXWorkspaceReadBackendError.invalidRelativePath
        }
        var components: [String] = []
        for value in trimmed.split(separator: "/", omittingEmptySubsequences: false) {
            let component = String(value)
            if component.isEmpty || component == "." { continue }
            guard component != "..", isSafeComponent(component) else {
                throw POSIXWorkspaceReadBackendError.invalidRelativePath
            }
            components.append(component)
        }
        guard components.count <= limits.maximumDepth,
              allowRoot || !components.isEmpty else {
            throw POSIXWorkspaceReadBackendError.invalidRelativePath
        }
        return RelativePath(components: components)
    }

    private static func isSafeComponent(_ component: String) -> Bool {
        let bytes = component.utf8
        guard !component.isEmpty,
              bytes.count <= Int(NAME_MAX),
              !bytes.contains(0),
              !component.contains("/") else {
            return false
        }
        return component.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.controlCharacters.contains(scalar) &&
                scalar.properties.generalCategory != .format
        }
    }

    private static func appending(_ name: String, to path: String) -> String {
        path.isEmpty ? name : "\(path)/\(name)"
    }

    private static func entry(
        name: String,
        path: String,
        node: OpenedNode
    ) -> Entry {
        Entry(
            name: name,
            relativePath: path,
            isDirectory: node.isDirectory,
            byteCount: max(0, Int64(node.metadata.st_size))
        )
    }

    private static func decodeLine(_ data: Data) -> String {
        var value = data
        if value.last == 13 { value.removeLast() }
        return String(data: value, encoding: .utf8) ??
            String(decoding: value, as: UTF8.self)
    }

    private static func lines(from data: Data) -> [String] {
        guard !data.isEmpty else { return [] }
        var rows: [String] = []
        var start = data.startIndex
        while let newline = data[start...].firstIndex(of: 10) {
            rows.append(decodeLine(Data(data[start ..< newline])))
            start = data.index(after: newline)
        }
        if start < data.endIndex {
            rows.append(decodeLine(Data(data[start ..< data.endIndex])))
        } else if data.last == 10 {
            rows.append("")
        }
        return rows
    }

    private static func dateDescription(_ value: timespec) -> String {
        guard value.tv_sec > 0 else { return "unknown" }
        let interval = TimeInterval(value.tv_sec) +
            TimeInterval(value.tv_nsec) / 1_000_000_000
        return Date(timeIntervalSince1970: interval).description
    }

    private static func metadata(_ descriptor: Int32) throws -> stat {
        var value = stat()
        guard Darwin.fstat(descriptor, &value) == 0 else {
            throw POSIXWorkspaceReadBackendError.operationFailed
        }
        return value
    }

    private static func metadataNoFollow(
        parent: Int32,
        name: String
    ) throws -> stat? {
        var value = stat()
        let result = name.withCString {
            Darwin.fstatat(parent, $0, &value, AT_SYMLINK_NOFOLLOW)
        }
        if result == 0 { return value }
        if errno == ENOENT { return nil }
        throw POSIXWorkspaceReadBackendError.operationFailed
    }

    private static func validateMetadata(
        _ metadata: stat,
        ownerUID: uid_t,
        expected: ExpectedKind
    ) throws {
        let type = metadata.st_mode & mode_t(S_IFMT)
        let isDirectory = type == mode_t(S_IFDIR)
        let isRegular = type == mode_t(S_IFREG)
        let unsafeWriteBits = mode_t(S_IWGRP) | mode_t(S_IWOTH)
        guard metadata.st_uid == ownerUID,
              metadata.st_nlink > 0,
              metadata.st_mode & unsafeWriteBits == 0,
              metadata.st_mode & mode_t(S_IRUSR) != 0,
              (isDirectory || isRegular),
              (!isRegular || metadata.st_nlink == 1),
              (!isDirectory || metadata.st_mode & mode_t(S_IXUSR) != 0) else {
            throw POSIXWorkspaceReadBackendError.unsafeFilesystemObject
        }
        switch expected {
        case .any:
            break
        case .directory where !isDirectory,
             .regularFile where !isRegular:
            throw POSIXWorkspaceReadBackendError.unsafeFilesystemObject
        case .directory, .regularFile:
            break
        }
    }

    private static func sameNode(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev &&
            lhs.st_ino == rhs.st_ino &&
            lhs.st_mode & mode_t(S_IFMT) == rhs.st_mode & mode_t(S_IFMT)
    }

    private static func sameSecurityMetadata(_ lhs: stat, _ rhs: stat) -> Bool {
        sameNode(lhs, rhs) &&
            lhs.st_uid == rhs.st_uid &&
            lhs.st_gid == rhs.st_gid &&
            lhs.st_mode == rhs.st_mode &&
            lhs.st_nlink == rhs.st_nlink
    }

    private static func sameStableMetadata(_ lhs: stat, _ rhs: stat) -> Bool {
        sameSecurityMetadata(lhs, rhs) &&
            lhs.st_size == rhs.st_size &&
            lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec &&
            lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec &&
            lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec &&
            lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }
}
