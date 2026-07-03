import Foundation

enum SandboxError: LocalizedError, Equatable {
    case pathEscapesWorkspace
    case fileTooLarge
    case unsupportedCommand(String)
    case invalidArguments
    case workspaceRootMutationDenied
    case recursiveWorkspaceMutationDenied
    case directoryOverwriteDenied
    case pathAlreadyExists

    var errorDescription: String? {
        switch self {
        case .pathEscapesWorkspace:
            "That path leaves the NovaForge workspace."
        case .fileTooLarge:
            "The file is too large to read in one tool call."
        case .unsupportedCommand(let command):
            "Unsupported command: \(command)"
        case .invalidArguments:
            "The command or tool arguments are invalid."
        case .workspaceRootMutationDenied:
            "NovaForge will not delete, move, or overwrite the workspace root. Reset the workspace from Settings if you mean to clear everything."
        case .recursiveWorkspaceMutationDenied:
            "NovaForge will not copy or move a folder into itself. Choose a destination outside that folder."
        case .directoryOverwriteDenied:
            "NovaForge will not replace an existing folder with another file or folder. Delete or rename the folder first."
        case .pathAlreadyExists:
            "A file or folder already exists at that path. Pick a new name or open the existing item."
        }
    }
}

struct FileItem: Identifiable, Hashable, Sendable {
    let name: String
    let relativePath: String
    let isDirectory: Bool
    let byteCount: Int64
    let modifiedAt: Date?

    var id: String { relativePath }
}

struct WorkspaceSearchMatch: Identifiable, Hashable, Sendable {
    let fileName: String
    let relativePath: String
    let lineNumber: Int
    let lineContent: String

    var id: String { "\(relativePath):\(lineNumber):\(lineContent)" }
}

struct WorkspaceSearchReport: Equatable, Sendable {
    var matches: [WorkspaceSearchMatch] = []
    var filesScanned = 0
    var skippedLargeFiles = 0
    var skippedUnsafePaths = 0
    var searchedDirectories = 0
    var capped = false
}

struct SandboxWorkspace: Sendable {
    let workspaceName: String
    let rootURL: URL
    var maxReadableBytes: Int = 256_000

    init(name: String = "Default", fileManager: FileManager = .default) {
        self.workspaceName = Self.sanitizedWorkspaceName(name)
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let workspacesRoot = documents
            .appendingPathComponent("Workspaces", isDirectory: true)
            .standardizedFileURL
        let candidateRoot = workspacesRoot
            .appendingPathComponent(self.workspaceName, isDirectory: true)
            .standardizedFileURL
        self.rootURL = candidateRoot.path.hasPrefix(workspacesRoot.path + "/")
            ? candidateRoot
            : workspacesRoot.appendingPathComponent("Default", isDirectory: true)
        try? fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    init(rootURL: URL, maxReadableBytes: Int = 256_000) {
        self.workspaceName = rootURL.lastPathComponent
        self.rootURL = rootURL
        self.maxReadableBytes = maxReadableBytes
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    private var standardizedRootPath: String {
        rootURL.standardizedFileURL.path
    }

    private var resolvedRootPath: String {
        rootURL.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func isPath(_ path: String, inside rootPath: String) -> Bool {
        path == rootPath || path.hasPrefix(rootPath + "/")
    }

    private func isWorkspaceRootRequest(_ relativePath: String) -> Bool {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "." || trimmed == "./"
    }

    private func isDirectory(at url: URL) -> Bool {
        ((try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false) == true
    }

    private func rejectRecursiveMutation(source: URL, destination: URL) throws {
        let sourcePath = source.standardizedFileURL.resolvingSymlinksInPath().path
        let destinationPath = destination.standardizedFileURL.resolvingSymlinksInPath().path
        guard isDirectory(at: source), destinationPath.hasPrefix(sourcePath + "/") else { return }
        throw SandboxError.recursiveWorkspaceMutationDenied
    }

    private func rejectDirectoryOverwrite(destination: URL) throws {
        guard FileManager.default.fileExists(atPath: destination.path), isDirectory(at: destination) else { return }
        throw SandboxError.directoryOverwriteDenied
    }

    private func safeRelativePath(for fileURL: URL) -> String? {
        let standardPath = fileURL.standardizedFileURL.path
        guard isPath(standardPath, inside: standardizedRootPath) else { return nil }

        let resolvedPath = fileURL.standardizedFileURL.resolvingSymlinksInPath().path
        guard isPath(resolvedPath, inside: resolvedRootPath) else { return nil }

        if standardPath == standardizedRootPath { return "" }
        let prefix = standardizedRootPath + "/"
        guard standardPath.hasPrefix(prefix) else { return nil }
        return String(standardPath.dropFirst(prefix.count))
    }

    static func sanitizedWorkspaceName(_ rawName: String) -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let leaf = trimmed
            .split(separator: "/", omittingEmptySubsequences: true)
            .filter { $0 != "." && $0 != ".." }
            .last
            .map(String.init) ?? ""
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let sanitizedScalars = leaf.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? String(scalar) : "-"
        }.joined()
        let sanitized = sanitizedScalars
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return sanitized.isEmpty ? "Default" : String(sanitized.prefix(64))
    }

    func resolve(_ relativePath: String) throws -> URL {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/") { throw SandboxError.pathEscapesWorkspace }
        if trimmed
            .split(separator: "/", omittingEmptySubsequences: false)
            .contains(where: { $0 == ".." }) {
            throw SandboxError.pathEscapesWorkspace
        }
        let normalized = URL(fileURLWithPath: trimmed.isEmpty ? "." : trimmed).standardizedFileURL.path
        if normalized.hasPrefix("../") || normalized == ".." {
            throw SandboxError.pathEscapesWorkspace
        }
        let url = rootURL.appendingPathComponent(normalized).standardizedFileURL
        let rootPath = rootURL.standardizedFileURL.resolvingSymlinksInPath().path
        let resolvedPath = url.resolvingSymlinksInPath().path
        guard resolvedPath == rootPath || resolvedPath.hasPrefix(rootPath + "/") else {
            throw SandboxError.pathEscapesWorkspace
        }
        return url
    }

    func list(_ relativePath: String = "") throws -> [FileItem] {
        let url = try resolve(relativePath)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let maxItems = 500
        let children = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )

        var items: [FileItem] = []
        items.reserveCapacity(min(maxItems, 128))
        for fileURL in children.sorted(by: { lhs, rhs in
            lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
        }) {
            try Task.checkCancellation()
            guard items.count < maxItems else { break }
            guard let safeRelative = safeRelativePath(for: fileURL), !safeRelative.isEmpty else {
                continue
            }
            let values = try fileURL.resourceValues(forKeys: keys)
            items.append(
                FileItem(
                    name: fileURL.lastPathComponent,
                    relativePath: safeRelative,
                    isDirectory: values.isDirectory ?? false,
                    byteCount: Int64(values.fileSize ?? 0),
                    modifiedAt: values.contentModificationDate
                )
            )
        }

        return items.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory && !rhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    func manifest(maxItems: Int = 500, maxDepth: Int = 5) throws -> [FileItem] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var items: [FileItem] = []
        items.reserveCapacity(min(maxItems, 128))
        for case let fileURL as URL in enumerator {
            try Task.checkCancellation()
            guard items.count < maxItems else { break }
            guard let relative = safeRelativePath(for: fileURL), !relative.isEmpty else {
                enumerator.skipDescendants()
                continue
            }
            let depth = relative.split(separator: "/").count
            if depth > maxDepth {
                enumerator.skipDescendants()
                continue
            }
            let values = try fileURL.resourceValues(forKeys: keys)
            items.append(
                FileItem(
                    name: fileURL.lastPathComponent,
                    relativePath: relative,
                    isDirectory: values.isDirectory ?? false,
                    byteCount: Int64(values.fileSize ?? 0),
                    modifiedAt: values.contentModificationDate
                )
            )
        }

        return items.sorted { lhs, rhs in
            lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
        }
    }

    func read(_ relativePath: String) throws -> String {
        let url = try resolve(relativePath)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        if size > maxReadableBytes { throw SandboxError.fileTooLarge }
        return try String(contentsOf: url, encoding: .utf8)
    }

    func write(_ relativePath: String, contents: String) throws {
        guard !isWorkspaceRootRequest(relativePath) else {
            throw SandboxError.workspaceRootMutationDenied
        }
        let url = try resolve(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    func createNewFile(_ relativePath: String, contents: String = "") throws {
        guard !isWorkspaceRootRequest(relativePath) else {
            throw SandboxError.workspaceRootMutationDenied
        }
        let url = try resolve(relativePath)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw SandboxError.pathAlreadyExists
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    func append(_ relativePath: String, contents: String) throws {
        guard !isWorkspaceRootRequest(relativePath) else {
            throw SandboxError.workspaceRootMutationDenied
        }
        let url = try resolve(relativePath)
        // Append directly to disk without loading existing content into memory.
        // The previous implementation did `(try? read) ?? ""` then rewrote, but
        // `read` throws for files above `maxReadableBytes` and `try?` swallowed
        // that, yielding "" — silently truncating large files to just the new
        // text. Appending via a file handle avoids that data loss entirely and
        // also keeps append O(new content) rather than O(file size).
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            // Create the file (empty) so the handle can open it for writing/appending.
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            // Fall back to a plain write if a handle can't be opened.
            try contents.write(to: url, atomically: true, encoding: .utf8)
            return
        }
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(contents.utf8))
    }

    func touch(_ relativePath: String) throws {
        guard !isWorkspaceRootRequest(relativePath) else {
            throw SandboxError.workspaceRootMutationDenied
        }
        let url = try resolve(relativePath)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.setAttributes(
                [.modificationDate: Date()],
                ofItemAtPath: url.path
            )
        } else {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data().write(to: url, options: .atomic)
        }
    }

    func makeDirectory(_ relativePath: String) throws {
        guard !isWorkspaceRootRequest(relativePath) else {
            throw SandboxError.workspaceRootMutationDenied
        }
        try FileManager.default.createDirectory(at: resolve(relativePath), withIntermediateDirectories: true)
    }

    func createNewDirectory(_ relativePath: String) throws {
        guard !isWorkspaceRootRequest(relativePath) else {
            throw SandboxError.workspaceRootMutationDenied
        }
        let url = try resolve(relativePath)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw SandboxError.pathAlreadyExists
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func delete(_ relativePath: String) throws {
        guard !isWorkspaceRootRequest(relativePath) else {
            throw SandboxError.workspaceRootMutationDenied
        }
        try FileManager.default.removeItem(at: resolve(relativePath))
    }

    func move(from: String, to: String) throws {
        guard !isWorkspaceRootRequest(from), !isWorkspaceRootRequest(to) else {
            throw SandboxError.workspaceRootMutationDenied
        }
        let source = try resolve(from)
        let destination = try resolve(to)
        guard source.standardizedFileURL.path != destination.standardizedFileURL.path else {
            throw SandboxError.invalidArguments
        }
        try rejectRecursiveMutation(source: source, destination: destination)
        try rejectDirectoryOverwrite(destination: destination)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: source, to: destination)
    }

    func copy(from: String, to: String) throws {
        guard !isWorkspaceRootRequest(from), !isWorkspaceRootRequest(to) else {
            throw SandboxError.workspaceRootMutationDenied
        }
        let source = try resolve(from)
        let destination = try resolve(to)
        guard source.standardizedFileURL.path != destination.standardizedFileURL.path else {
            throw SandboxError.invalidArguments
        }
        try rejectRecursiveMutation(source: source, destination: destination)
        try rejectDirectoryOverwrite(destination: destination)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }

    func searchMatches(
        query rawQuery: String,
        in relativePath: String = "",
        maxFilesScanned: Int = 600,
        maxDirectories: Int = 160,
        maxMatches: Int = 120,
        maxReadableFileBytes: Int = 750_000
    ) throws -> WorkspaceSearchReport {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return WorkspaceSearchReport() }

        let start = try resolve(relativePath)
        let fileReadLimit = min(maxReadableFileBytes, maxReadableBytes)
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        var report = WorkspaceSearchReport()

        func scanFile(_ fileURL: URL, values initialValues: URLResourceValues? = nil) throws {
            try Task.checkCancellation()

            guard let relative = safeRelativePath(for: fileURL), !relative.isEmpty else {
                report.skippedUnsafePaths += 1
                return
            }

            guard report.filesScanned < maxFilesScanned else {
                report.capped = true
                return
            }
            report.filesScanned += 1

            let values: URLResourceValues
            if let initialValues {
                values = initialValues
            } else {
                values = try fileURL.resourceValues(forKeys: Set(keys))
            }

            if relative.localizedCaseInsensitiveContains(query) {
                report.matches.append(WorkspaceSearchMatch(
                    fileName: fileURL.lastPathComponent,
                    relativePath: relative,
                    lineNumber: 1,
                    lineContent: "Path: \(relative)"
                ))
                if report.matches.count >= maxMatches {
                    report.capped = true
                    return
                }
            }

            if (values.fileSize ?? 0) > fileReadLimit {
                report.skippedLargeFiles += 1
                return
            }
            guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
            var lineNumber = 0
            contents.enumerateLines { line, stop in
                lineNumber += 1
                if Task.isCancelled || report.matches.count >= maxMatches {
                    report.capped = true
                    stop = true
                    return
                }
                guard line.localizedCaseInsensitiveContains(query) else { return }
                let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                let preview = trimmedLine.count > 240 ? String(trimmedLine.prefix(240)) + "…" : trimmedLine
                report.matches.append(WorkspaceSearchMatch(
                    fileName: fileURL.lastPathComponent,
                    relativePath: relative,
                    lineNumber: lineNumber,
                    lineContent: preview
                ))
                if report.matches.count >= maxMatches {
                    report.capped = true
                    stop = true
                }
            }
        }

        let startValues = try start.resourceValues(forKeys: Set(keys))
        if startValues.isDirectory != true {
            try scanFile(start, values: startValues)
            return report
        }

        var pendingDirectories: [URL] = [start]
        var pendingIndex = 0

        while pendingIndex < pendingDirectories.count {
            try Task.checkCancellation()
            guard report.matches.count < maxMatches else {
                report.capped = true
                break
            }
            guard report.searchedDirectories < maxDirectories else {
                report.capped = true
                break
            }

            let directory = pendingDirectories[pendingIndex]
            pendingIndex += 1
            report.searchedDirectories += 1

            let children = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            )) ?? []

            for fileURL in children.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
                try Task.checkCancellation()
                guard report.matches.count < maxMatches else {
                    report.capped = true
                    break
                }

                guard let relative = safeRelativePath(for: fileURL), !relative.isEmpty else {
                    report.skippedUnsafePaths += 1
                    continue
                }

                let values = try fileURL.resourceValues(forKeys: Set(keys))

                if values.isDirectory == true {
                    if report.searchedDirectories + pendingDirectories.count - pendingIndex < maxDirectories {
                        pendingDirectories.append(fileURL)
                    } else {
                        report.capped = true
                    }
                    continue
                }

                try scanFile(fileURL, values: values)
            }
        }

        return report
    }

    func search(_ query: String, in relativePath: String = "") throws -> String {
        let report = try searchMatches(query: query, in: relativePath)
        if report.matches.isEmpty { return "No matches." }
        var returnedBytes = 0
        let maxReturnedBytes = 18_000
        var rows: [String] = []
        for match in report.matches {
            let row = "\(match.relativePath):\(match.lineNumber): \(match.lineContent)"
            if returnedBytes + row.utf8.count + 1 > maxReturnedBytes {
                rows.append("… truncated after output limit. Narrow the query or path for more.")
                return rows.joined(separator: "\n")
            }
            rows.append(row)
            returnedBytes += row.utf8.count + 1
        }
        if report.capped {
            rows.append("… truncated for smoothness after \(report.filesScanned) files / \(report.searchedDirectories) folders. Narrow the query or path for more.")
        }
        return rows.joined(separator: "\n")
    }

    func reset() throws {
        if FileManager.default.fileExists(atPath: rootURL.path) {
            try FileManager.default.removeItem(at: rootURL)
        }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    static func listWorkspaces(fileManager: FileManager = .default) -> [String] {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let workspacesURL = documents.appendingPathComponent("Workspaces", isDirectory: true)
        guard let urls = try? fileManager.contentsOfDirectory(
            at: workspacesURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return ["Default"]
        }
        let names = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { $0.lastPathComponent }
            .sorted()
        return names.isEmpty ? ["Default"] : names
    }
}
