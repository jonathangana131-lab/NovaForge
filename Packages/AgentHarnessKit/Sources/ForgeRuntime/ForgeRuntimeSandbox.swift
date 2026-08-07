import Foundation

public enum ForgeRuntimeSandboxError: Error, Equatable, Sendable {
    case rootIsNotDirectory
    case invalidRelativePath(String)
    case symbolicLinkNotAllowed(String)
    case resourceEscapesSandbox(String)
    case resourceNotFound(String)
    case resourceIsNotRegularFile(String)
}

extension ForgeRuntimeSandboxError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .rootIsNotDirectory:
            return "Forge Runtime sandbox root must be an existing directory."
        case .invalidRelativePath(let path):
            return "Forge Runtime resource path is not a safe sandbox-relative path: \(path)."
        case .symbolicLinkNotAllowed(let path):
            return "Forge Runtime does not follow symbolic links inside project sandboxes: \(path)."
        case .resourceEscapesSandbox(let path):
            return "Forge Runtime resource resolves outside the project sandbox: \(path)."
        case .resourceNotFound(let path):
            return "Forge Runtime resource does not exist: \(path)."
        case .resourceIsNotRegularFile(let path):
            return "Forge Runtime resource must be a regular file: \(path)."
        }
    }
}

public enum ForgeRuntimeSandbox {
    public static func resolveExistingFile(
        relativePath: String,
        under rootDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard rootDirectory.isFileURL else {
            throw ForgeRuntimeSandboxError.rootIsNotDirectory
        }

        var rootIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: rootDirectory.path, isDirectory: &rootIsDirectory),
              rootIsDirectory.boolValue else {
            throw ForgeRuntimeSandboxError.rootIsNotDirectory
        }

        let components = try validatedPathComponents(relativePath)
        let canonicalRoot = rootDirectory.resolvingSymlinksInPath().standardizedFileURL

        var candidate = canonicalRoot
        for component in components {
            candidate.appendPathComponent(component, isDirectory: false)
            let values = try? candidate.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values?.isSymbolicLink == true {
                throw ForgeRuntimeSandboxError.symbolicLinkNotAllowed(relativePath)
            }
        }

        let canonicalCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard isContained(canonicalCandidate, by: canonicalRoot) else {
            throw ForgeRuntimeSandboxError.resourceEscapesSandbox(relativePath)
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: canonicalCandidate.path, isDirectory: &isDirectory) else {
            throw ForgeRuntimeSandboxError.resourceNotFound(relativePath)
        }
        guard !isDirectory.boolValue else {
            throw ForgeRuntimeSandboxError.resourceIsNotRegularFile(relativePath)
        }

        let values = try canonicalCandidate.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else {
            throw ForgeRuntimeSandboxError.resourceIsNotRegularFile(relativePath)
        }

        return canonicalCandidate
    }

    private static func validatedPathComponents(_ path: String) throws -> [String] {
        guard !path.isEmpty,
              path.utf8.count <= 240,
              !path.hasPrefix("/"),
              !path.hasPrefix("~"),
              !path.contains("\\"),
              !path.contains(":"),
              !path.contains("%"),
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ForgeRuntimeSandboxError.invalidRelativePath(path)
        }

        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ForgeRuntimeSandboxError.invalidRelativePath(path)
        }
        return components
    }

    private static func isContained(_ candidate: URL, by root: URL) -> Bool {
        let rootComponents = root.pathComponents
        let candidateComponents = candidate.pathComponents
        guard candidateComponents.count >= rootComponents.count else { return false }
        return Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }
}
