import Foundation

struct ToolRequest: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let arguments: [String: String]

    var isMutating: Bool {
        if name == "run_command" {
            return TerminalCommandDraft(arguments["command"] ?? "").isMutating
        }
        return [
            "write_file", "append_file", "delete_path", "move_path", "copy_path",
            "make_directory", "replace_text"
        ].contains(name)
    }

    var argumentsJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(arguments),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

}

struct SandboxToolExecutor: Sendable {
    let workspace: SandboxWorkspace
    private let maxJSONValidationBytes = 2_000_000
    private let maxOutlineScanBytes = 1_000_000

    func execute(_ request: ToolRequest) throws -> String {
        guard !request.isMutating else {
            throw SandboxError.workspaceMutationPermitRequired
        }
        return try execute(request, mutationPermit: nil)
    }

    func execute(_ request: ToolRequest, permit: WorkspaceMutationPermit) throws -> String {
        try execute(request, mutationPermit: permit)
    }

    private func execute(
        _ request: ToolRequest,
        mutationPermit: WorkspaceMutationPermit?
    ) throws -> String {
        switch request.name {
        case "list_directory":
            let path = request.arguments["path"] ?? ""
            let items = try workspace.list(path)
            let rows = items.prefix(250).map { "\($0.isDirectory ? "folder" : "file"): \($0.relativePath)" }
            let suffix = items.count > 250 ? "\n… truncated after 250 items. Use a narrower directory path." : ""
            return rows.joined(separator: "\n") + suffix
        case "list_tree":
            return try listTree(request)
        case "workspace_summary":
            return try workspaceSummary(request)
        case "file_info":
            return try fileInfo(request)
        case "read_file":
            return try workspace.read(required("path", in: request))
        case "read_file_range":
            return try readFileRange(request)
        case "tail_file":
            return try tailFile(request)
        case "write_file":
            let path = try required("path", in: request)
            try workspace.write(
                path,
                contents: try present("contents", in: request),
                permit: try requiredPermit(mutationPermit)
            )
            return "Wrote \(path)"
        case "append_file":
            let path = try required("path", in: request)
            try workspace.append(
                path,
                contents: try present("contents", in: request),
                permit: try requiredPermit(mutationPermit)
            )
            return "Appended \(path)"
        case "replace_text":
            return try replaceText(request, permit: try requiredPermit(mutationPermit))
        case "delete_path":
            let path = try required("path", in: request)
            try workspace.delete(path, permit: try requiredPermit(mutationPermit))
            return "Deleted \(path)"
        case "move_path":
            let source = try required("from", in: request)
            let destination = try required("to", in: request)
            try workspace.move(
                from: source,
                to: destination,
                permit: try requiredPermit(mutationPermit)
            )
            return "Moved \(source) to \(destination)"
        case "copy_path":
            let source = try required("from", in: request)
            let destination = try required("to", in: request)
            try workspace.copy(
                from: source,
                to: destination,
                permit: try requiredPermit(mutationPermit)
            )
            return "Copied \(source) to \(destination)"
        case "make_directory":
            let path = try required("path", in: request)
            try workspace.makeDirectory(path, permit: try requiredPermit(mutationPermit))
            return "Created folder \(path)"
        case "search_text":
            return try workspace.search(required("query", in: request), in: request.arguments["path"] ?? "")
        case "diff_files":
            return try diffFiles(request)
        case "validate_json":
            return try validateJSON(request)
        case "validate_html_file":
            let path = try required("path", in: request)
            let profile = request.arguments["profile"].flatMap { ["page", "game", "auto"].contains($0) ? $0 : nil } ?? "auto"
            return try CommandRunner(workspace: workspace).validateHTMLFile(path: path, profile: profile)
        case "extract_outline":
            return try extractOutline(request)
        case "run_command":
            let command = try required("command", in: request)
            if TerminalCommandDraft(command).isMutating {
                return try CommandRunner(workspace: workspace).run(
                    command,
                    permit: try requiredPermit(mutationPermit)
                )
            }
            return try CommandRunner(workspace: workspace).run(command)
        default:
            throw SandboxError.unsupportedCommand(request.name)
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

    private func required(_ key: String, in request: ToolRequest) throws -> String {
        guard let value = request.arguments[key], !value.isEmpty else { throw SandboxError.invalidArguments }
        return value
    }

    private func present(_ key: String, in request: ToolRequest) throws -> String {
        guard let value = request.arguments[key] else { throw SandboxError.invalidArguments }
        return value
    }

    private func intArgument(_ key: String, in request: ToolRequest, default defaultValue: Int, range: ClosedRange<Int>) -> Int {
        guard let raw = request.arguments[key], let parsed = Int(raw) else { return defaultValue }
        return min(max(parsed, range.lowerBound), range.upperBound)
    }

    private func listTree(_ request: ToolRequest) throws -> String {
        let maxItems = intArgument("max_items", in: request, default: 250, range: 1...800)
        let maxDepth = intArgument("max_depth", in: request, default: 5, range: 1...10)
        let items = try workspace.manifest(maxItems: maxItems, maxDepth: maxDepth)
        let rows = items.prefix(maxItems).map { item -> String in
            let depth = item.relativePath.split(separator: "/").count - 1
            let indent = String(repeating: "  ", count: max(0, depth))
            return "\(indent)\(item.isDirectory ? "▸" : "•") \(item.name)"
        }
        let suffix = items.count >= maxItems ? "\n… truncated after \(maxItems) items." : ""
        return rows.joined(separator: "\n") + suffix
    }

    private func workspaceSummary(_ request: ToolRequest) throws -> String {
        let maxItems = intArgument("max_items", in: request, default: 800, range: 50...2_000)
        let items = try workspace.manifest(maxItems: maxItems, maxDepth: 10)
        let files = items.filter { !$0.isDirectory }
        let folders = items.filter { $0.isDirectory }
        let totalBytes = files.reduce(Int64(0)) { $0 + $1.byteCount }
        let extensions = Dictionary(grouping: files) { file in
            let ext = (file.name as NSString).pathExtension.lowercased()
            return ext.isEmpty ? "no extension" : ext
        }
        let topExtensions = extensions
            .map { "\($0.key): \($0.value.count)" }
            .sorted()
            .prefix(12)
            .joined(separator: ", ")
        return """
        Workspace: \(workspace.workspaceName)
        Files: \(files.count)
        Folders: \(folders.count)
        Bytes: \(totalBytes)
        Types: \(topExtensions.isEmpty ? "none" : topExtensions)
        """
    }

    private func fileInfo(_ request: ToolRequest) throws -> String {
        let path = try required("path", in: request)
        let url = try workspace.resolve(path)
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey])
        return """
        Path: \(path)
        Kind: \((values.isDirectory ?? false) ? "folder" : "file")
        Bytes: \(values.fileSize ?? 0)
        Created: \(values.creationDate?.description ?? "unknown")
        Modified: \(values.contentModificationDate?.description ?? "unknown")
        """
    }

    private func readFileRange(_ request: ToolRequest) throws -> String {
        let path = try required("path", in: request)
        let start = intArgument("start_line", in: request, default: 1, range: 1...50_000)
        let count = intArgument("line_count", in: request, default: 80, range: 1...400)
        return try boundedLineRange(path: path, startLine: start, lineCount: count)
    }

    private func tailFile(_ request: ToolRequest) throws -> String {
        let path = try required("path", in: request)
        let count = intArgument("line_count", in: request, default: 60, range: 1...300)
        return try boundedTail(path: path, lineCount: count)
    }

    private func boundedLineRange(path: String, startLine: Int, lineCount: Int) throws -> String {
        let url = try workspace.resolve(path)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let endLine = startLine + lineCount - 1
        var currentLine = 1
        var rows: [String] = []
        var buffer = Data()
        var sawAnyByte = false
        var lastByteWasNewline = false

        func emit(_ lineData: Data) {
            if currentLine >= startLine && currentLine <= endLine {
                rows.append("\(currentLine)|\(decodeLine(lineData))")
            }
            currentLine += 1
        }

        while currentLine <= endLine {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: 16_384) ?? Data()
            guard !chunk.isEmpty else { break }
            sawAnyByte = true
            lastByteWasNewline = chunk.last == 10
            buffer.append(chunk)

            while let newlineIndex = buffer.firstIndex(of: 10) {
                let lineData = Data(buffer[..<newlineIndex])
                emit(lineData)
                buffer.removeSubrange(buffer.startIndex...newlineIndex)
                if currentLine > endLine { return rows.joined(separator: "\n") }
            }
        }

        if currentLine <= endLine {
            if !buffer.isEmpty {
                emit(buffer)
            } else if sawAnyByte && lastByteWasNewline {
                emit(Data())
            }
        }

        return rows.joined(separator: "\n")
    }

    private func boundedTail(path: String, lineCount: Int) throws -> String {
        let url = try workspace.resolve(path)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard fileSize > 0 else { return "" }

        let maxTailBytes = Int64(max(workspace.maxReadableBytes, 256_000))
        let bytesToRead = min(fileSize, maxTailBytes)
        var windowStartOffset = fileSize - bytesToRead

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(windowStartOffset))
        var data = try handle.read(upToCount: Int(bytesToRead)) ?? Data()
        var note: String?

        if windowStartOffset > 0 {
            if let firstNewline = data.firstIndex(of: 10) {
                let dropThroughNewline = data.index(after: firstNewline)
                windowStartOffset += Int64(dropThroughNewline)
                data.removeSubrange(data.startIndex..<dropThroughNewline)
            } else {
                note = "… tail truncated to the last \(bytesToRead) bytes of one very long line."
            }
        }

        let lines = lines(from: data)
        guard !lines.isEmpty else { return note ?? "" }
        let selectedStart = max(0, lines.count - lineCount)
        let firstParsedLine = try countNewlines(in: url, upTo: windowStartOffset) + 1
        let firstSelectedLine = firstParsedLine + selectedStart
        var rows = lines.dropFirst(selectedStart).enumerated().map { index, line in
            "\(firstSelectedLine + index)|\(line)"
        }
        if let note {
            rows.append(note)
        } else if windowStartOffset > 0 && lines.count < lineCount {
            rows.append("… tail truncated before the last \(lines.count) complete line(s).")
        }
        return rows.joined(separator: "\n")
    }

    private func decodeLine(_ data: Data) -> String {
        var lineData = data
        if lineData.last == 13 { lineData.removeLast() }
        return String(data: lineData, encoding: .utf8) ?? String(decoding: lineData, as: UTF8.self)
    }

    private func lines(from data: Data) -> [String] {
        guard !data.isEmpty else { return [] }
        var rows: [String] = []
        var lineStart = data.startIndex
        while let newlineIndex = data[lineStart...].firstIndex(of: 10) {
            rows.append(decodeLine(Data(data[lineStart..<newlineIndex])))
            lineStart = data.index(after: newlineIndex)
        }
        if lineStart < data.endIndex {
            rows.append(decodeLine(Data(data[lineStart..<data.endIndex])))
        } else if data.last == 10 {
            rows.append("")
        }
        return rows
    }

    private func countNewlines(in url: URL, upTo targetOffset: Int64) throws -> Int {
        guard targetOffset > 0 else { return 0 }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var remaining = targetOffset
        var count = 0
        while remaining > 0 {
            try Task.checkCancellation()
            let chunkSize = min(Int64(64 * 1024), remaining)
            let chunk = try handle.read(upToCount: Int(chunkSize)) ?? Data()
            guard !chunk.isEmpty else { break }
            count += chunk.reduce(0) { partial, byte in partial + (byte == 10 ? 1 : 0) }
            remaining -= Int64(chunk.count)
        }
        return count
    }

    private func replaceText(
        _ request: ToolRequest,
        permit: WorkspaceMutationPermit
    ) throws -> String {
        let path = try required("path", in: request)
        let old = try required("old", in: request)
        guard !old.isEmpty else { throw SandboxError.invalidArguments }
        let new = try present("new", in: request)
        let replaceAll = (request.arguments["replace_all"] ?? "false").lowercased() == "true"
        let url = try workspace.resolve(path)
        let oldData = Data(old.utf8)
        let newData = Data(new.utf8)
        let matches = try streamReplace(in: url, oldData: oldData, newData: newData, replaceAll: true, outputURL: nil)
        guard matches > 0 else { return "No match found in \(path)." }
        guard replaceAll || matches == 1 else { return "Found \(matches) matches in \(path). Pass replace_all=true or use more specific old text." }

        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).novaforge-replace-\(UUID().uuidString)")
        let validateMutation = {
            try permit.validate(workspace: workspace, operation: .replaceText(path: path))
        }
        do {
            _ = try streamReplace(
                in: url,
                oldData: oldData,
                newData: newData,
                replaceAll: replaceAll,
                outputURL: temporaryURL,
                mutationValidation: validateMutation
            )
            try validateMutation()
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporaryURL)
        } catch {
            do {
                try validateMutation()
                try? FileManager.default.removeItem(at: temporaryURL)
            } catch {
                // An invalid or revoked capability must not be used even for
                // cleanup; the app's temporary-file recovery owns that case.
            }
            throw error
        }
        return "Replaced \(replaceAll ? matches : 1) occurrence(s) in \(path)."
    }

    @discardableResult
    private func streamReplace(
        in url: URL,
        oldData: Data,
        newData: Data,
        replaceAll: Bool,
        outputURL: URL?,
        mutationValidation: (() throws -> Void)? = nil
    ) throws -> Int {
        guard !oldData.isEmpty else { throw SandboxError.invalidArguments }
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }

        let output: FileHandle?
        if let outputURL {
            try mutationValidation?()
            FileManager.default.createFile(atPath: outputURL.path, contents: nil)
            output = try FileHandle(forWritingTo: outputURL)
        } else {
            output = nil
        }
        defer { try? output?.close() }

        let overlap = max(oldData.count - 1, 0)
        var buffer = Data()
        var matches = 0
        while true {
            try Task.checkCancellation()
            let chunk = try input.read(upToCount: 64 * 1024) ?? Data()
            if chunk.isEmpty { break }
            buffer.append(chunk)

            while let range = buffer.range(of: oldData) {
                if let output {
                    try mutationValidation?()
                    try output.write(contentsOf: buffer[..<range.lowerBound])
                    try mutationValidation?()
                    try output.write(contentsOf: newData)
                }
                matches += 1
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                if !replaceAll { break }
            }

            if !replaceAll, matches > 0 { break }
            if buffer.count > overlap {
                let flushEnd = buffer.index(buffer.endIndex, offsetBy: -overlap)
                if let output {
                    try mutationValidation?()
                    try output.write(contentsOf: buffer[..<flushEnd])
                }
                buffer.removeSubrange(buffer.startIndex..<flushEnd)
            }
        }

        if let output {
            try mutationValidation?()
            try output.write(contentsOf: buffer)
            if !replaceAll, matches > 0 {
                while true {
                    try Task.checkCancellation()
                    let chunk = try input.read(upToCount: 64 * 1024) ?? Data()
                    if chunk.isEmpty { break }
                    try mutationValidation?()
                    try output.write(contentsOf: chunk)
                }
            }
        }
        return matches
    }

    private func diffFiles(_ request: ToolRequest) throws -> String {
        let leftPath = try required("left", in: request)
        let rightPath = try required("right", in: request)
        let left = try boundedDiffLines(path: leftPath)
        let right = try boundedDiffLines(path: rightPath)
        let maxLines = 220
        var rows = ["--- \(leftPath)", "+++ \(rightPath)"]
        let maxCount = max(left.lines.count, right.lines.count)
        for index in 0..<maxCount {
            if rows.count >= maxLines { rows.append("… diff truncated"); break }
            let lhs = index < left.lines.count ? left.lines[index] : nil
            let rhs = index < right.lines.count ? right.lines[index] : nil
            if lhs == rhs { continue }
            if let lhs { rows.append("-\(index + 1)|\(lhs)") }
            if let rhs { rows.append("+\(index + 1)|\(rhs)") }
        }
        if left.truncated || right.truncated {
            rows.append("… compared a bounded prefix only; use read_file_range or tail_file for deeper sections.")
        }
        return rows.joined(separator: "\n")
    }

    private func boundedDiffLines(path: String, maxLines: Int = 600, maxBytes: Int = 1_000_000) throws -> (lines: [String], truncated: Bool) {
        let url = try workspace.resolve(path)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var data = Data()
        var truncated = false
        while data.count < maxBytes {
            try Task.checkCancellation()
            let chunkSize = min(64 * 1024, maxBytes - data.count)
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            guard !chunk.isEmpty else { break }
            data.append(chunk)
        }
        if !(try handle.read(upToCount: 1) ?? Data()).isEmpty {
            truncated = true
        }
        var rows = lines(from: data)
        if rows.count > maxLines {
            rows = Array(rows.prefix(maxLines))
            truncated = true
        }
        return (rows, truncated)
    }

    private func validateJSON(_ request: ToolRequest) throws -> String {
        let path = try required("path", in: request)
        let url = try workspace.resolve(path)
        let byteCount = try fileByteCount(at: url)
        guard byteCount <= maxJSONValidationBytes else {
            return "JSON validation for \(path): skipped — file is too large to validate in one tool call (\(byteCount) bytes). Use read_file_range or tail_file to inspect a bounded section."
        }

        guard let stream = InputStream(url: url) else { throw SandboxError.invalidArguments }
        stream.open()
        defer { stream.close() }
        do {
            _ = try JSONSerialization.jsonObject(with: stream)
            return "JSON validation for \(path): ok"
        } catch {
            return "JSON validation for \(path): failed — \(error.localizedDescription)"
        }
    }

    private func extractOutline(_ request: ToolRequest) throws -> String {
        let path = try required("path", in: request)
        let url = try workspace.resolve(path)
        let byteCount = try fileByteCount(at: url)
        let maxBytes = min(byteCount, Int64(maxOutlineScanBytes))
        let interestingPrefixes = ["func ", "struct ", "class ", "enum ", "protocol ", "extension ", "const ", "let ", "function ", "#", "##"]
        let maxRows = 180
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var rows: [String] = []
        rows.reserveCapacity(min(maxRows, 64))
        var currentLine = 1
        var currentLineData = Data()
        var bytesRead: Int64 = 0
        var truncatedByRows = false

        func inspect(_ lineData: Data) {
            let trimmed = decodeLine(lineData).trimmingCharacters(in: .whitespaces)
            if interestingPrefixes.contains(where: { trimmed.hasPrefix($0) }) {
                if rows.count < maxRows {
                    rows.append("\(currentLine)|\(trimmed)")
                } else {
                    truncatedByRows = true
                }
            }
            currentLine += 1
        }

        while bytesRead < maxBytes && !truncatedByRows {
            try Task.checkCancellation()
            let remainingBudget = Int(maxBytes - bytesRead)
            let chunk = try handle.read(upToCount: min(64 * 1024, remainingBudget)) ?? Data()
            guard !chunk.isEmpty else { break }
            bytesRead += Int64(chunk.count)
            for byte in chunk {
                if byte == 10 {
                    inspect(currentLineData)
                    currentLineData.removeAll(keepingCapacity: true)
                    if truncatedByRows { break }
                } else {
                    currentLineData.append(byte)
                }
            }
        }

        if !currentLineData.isEmpty && !truncatedByRows {
            inspect(currentLineData)
        }
        if truncatedByRows {
            rows.append("… outline truncated after \(maxRows) matches. Use search_text or read_file_range for narrower inspection.")
        } else if byteCount > Int64(maxOutlineScanBytes) {
            rows.append("… outline scanned first \(maxOutlineScanBytes) bytes only. Use read_file_range or search_text for deeper sections.")
        }
        return rows.joined(separator: "\n")
    }

    private func fileByteCount(at url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }
}
