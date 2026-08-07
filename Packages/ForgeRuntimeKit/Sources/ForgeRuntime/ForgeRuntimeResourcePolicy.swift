import Foundation

public enum ForgeRuntimeResourceAllowance: Equatable, Sendable {
    case localProjectFile(URL)
    case externalHTTPS(host: String)
}

public enum ForgeRuntimeResourceDenial: Error, Equatable, Sendable {
    case unsupportedScheme(String?)
    case credentialsNotAllowed
    case externalNetworkDenied
    case externalHostMissing
    case externalHostNotAllowed(String)
    case externalPortNotAllowed(Int)
    case localFileHostNotAllowed(String)
    case localFileRejected(ForgeProjectSandboxError)
}

public enum ForgeRuntimeResourceDecision: Equatable, Sendable {
    case allow(ForgeRuntimeResourceAllowance)
    case deny(ForgeRuntimeResourceDenial)

    public var isAllowed: Bool {
        if case .allow = self { return true }
        return false
    }
}

/// Pure URL/resource decision core for a future Forge Runtime host.
///
/// This does not claim WebKit enforcement by itself. A concrete runtime must apply this decision at
/// every relevant navigation/resource boundary. The evaluator is intentionally small and fail-closed:
/// project files must resolve through the hardened sandbox, and external access is HTTPS-only to an
/// exact hostname already present in host-derived launch authorization.
public struct ForgeRuntimeResourcePolicy: Sendable {
    public let authorization: ForgeRuntimeLaunchAuthorization
    public let sandbox: ForgeProjectSandbox

    public init(
        authorization: ForgeRuntimeLaunchAuthorization,
        projectRootURL: URL
    ) {
        self.authorization = authorization
        self.sandbox = ForgeProjectSandbox(rootURL: projectRootURL)
    }

    public func decide(_ url: URL) -> ForgeRuntimeResourceDecision {
        guard let rawScheme = url.scheme else {
            return .deny(.unsupportedScheme(nil))
        }

        switch rawScheme.lowercased() {
        case "file":
            return decideLocalFile(url)
        case "https":
            return decideExternalHTTPS(url)
        default:
            return .deny(.unsupportedScheme(rawScheme.lowercased()))
        }
    }

    private func decideLocalFile(_ url: URL) -> ForgeRuntimeResourceDecision {
        if let host = url.host, !host.isEmpty {
            return .deny(.localFileHostNotAllowed(host))
        }

        do {
            let resolved = try sandbox.resolveExistingFile(url: url)
            return .allow(.localProjectFile(resolved))
        } catch let error as ForgeProjectSandboxError {
            return .deny(.localFileRejected(error))
        } catch {
            return .deny(.localFileRejected(.fileNotFound))
        }
    }

    private func decideExternalHTTPS(_ url: URL) -> ForgeRuntimeResourceDecision {
        if url.user != nil || url.password != nil {
            return .deny(.credentialsNotAllowed)
        }

        if let port = url.port, port != 443 {
            return .deny(.externalPortNotAllowed(port))
        }

        guard let host = url.host?.lowercased(), !host.isEmpty else {
            return .deny(.externalHostMissing)
        }

        guard authorization.network.mode == .allowListedHTTPS else {
            return .deny(.externalNetworkDenied)
        }

        guard authorization.network.allowedHosts.contains(host) else {
            return .deny(.externalHostNotAllowed(host))
        }

        return .allow(.externalHTTPS(host: host))
    }
}

public extension ForgeProjectSandbox {
    /// Resolves an absolute file URL only when its lexical path is a strict descendant of this
    /// project's exact root. The resulting relative path is then revalidated by the normal sandbox
    /// resolver, including the project-owned symlink and regular-file checks.
    func resolveExistingFile(url: URL) throws -> URL {
        guard url.isFileURL else {
            throw ForgeProjectSandboxError.invalidRelativePath
        }
        if let host = url.host, !host.isEmpty {
            throw ForgeProjectSandboxError.invalidRelativePath
        }

        let candidate = url.standardizedFileURL
        let rootComponents = rootURL.pathComponents
        let candidateComponents = candidate.pathComponents
        guard candidateComponents.count > rootComponents.count,
              Array(candidateComponents.prefix(rootComponents.count)) == rootComponents else {
            throw ForgeProjectSandboxError.escapedSandbox
        }

        let relativeComponents = candidateComponents.dropFirst(rootComponents.count)
        let relativePath = relativeComponents.joined(separator: "/")
        return try resolveExistingFile(relativePath: relativePath)
    }
}
