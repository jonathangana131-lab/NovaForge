import Foundation

/// Why a generated Forge project URL was denied by host policy.
///
/// This is intentionally conservative. A URL that does not fit the currently authorized project-file
/// or exact-host HTTPS shapes is denied rather than silently widened into ambient WebKit authority.
public enum ForgeRuntimeURLAccessDenial: String, Codable, Equatable, Sendable {
    case invalidProjectRoot
    case nonLocalFileAuthority
    case projectFileOutsideSandbox
    case projectFileNotFound
    case projectDirectoryNotAllowed
    case projectSymbolicLinkNotAllowed
    case projectNonRegularFile
    case projectFileUnavailable
    case networkDenied
    case unsupportedRemoteScheme
    case invalidRemoteURL
    case credentialsNotAllowed
    case explicitPortNotAllowed
    case hostNotAllowListed
}

/// Host decision for one URL requested by a generated Forge project.
///
/// `.allowProjectFile` is emitted only after `ForgeProjectSandbox` revalidates that the URL names an
/// existing regular project file through a non-symlink path. `.allowHTTPS` grants only the exact
/// normalized hostname shown.
public enum ForgeRuntimeURLAccessDecision: Equatable, Sendable {
    case allowProjectFile
    case allowHTTPS(host: String)
    case deny(ForgeRuntimeURLAccessDenial)

    public var isAllowed: Bool {
        switch self {
        case .allowProjectFile, .allowHTTPS:
            true
        case .deny:
            false
        }
    }
}

/// Applies canonical `ForgeRuntimeLaunchAuthorization.network` authority to project URLs.
///
/// This type is deliberately WebKit-independent so navigation, resource-loading and any future proxy
/// layer can share one fail-closed decision. Installing this evaluator only in a navigation delegate is
/// **not** a complete WebKit network sandbox: the host must apply equivalent authority to every remote
/// load path (subresources, fetch/XHR, media, workers, redirects, etc.) before claiming network isolation.
public struct ForgeRuntimeURLAccessEvaluator: Sendable {
    public init() {}

    public func evaluate(
        _ url: URL,
        launchAuthorization: ForgeRuntimeLaunchAuthorization,
        projectRootURL: URL
    ) -> ForgeRuntimeURLAccessDecision {
        if url.isFileURL {
            return evaluateProjectFile(url, projectRootURL: projectRootURL)
        }

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let rawScheme = components.scheme else {
            return .deny(.invalidRemoteURL)
        }

        guard rawScheme.lowercased() == "https" else {
            return .deny(.unsupportedRemoteScheme)
        }

        guard components.user == nil, components.password == nil else {
            return .deny(.credentialsNotAllowed)
        }

        // Manifest network authority is exact hostnames only. It deliberately does not contain a
        // port dimension, so an explicit port must not be inferred as authorized.
        guard components.port == nil else {
            return .deny(.explicitPortNotAllowed)
        }

        guard let rawHost = components.host, !rawHost.isEmpty else {
            return .deny(.invalidRemoteURL)
        }
        let host = rawHost.lowercased()

        switch launchAuthorization.network.mode {
        case .denied:
            return .deny(.networkDenied)

        case .allowListedHTTPS:
            guard launchAuthorization.network.allowedHosts.contains(host) else {
                return .deny(.hostNotAllowListed)
            }
            return .allowHTTPS(host: host)
        }
    }

    private func evaluateProjectFile(
        _ url: URL,
        projectRootURL: URL
    ) -> ForgeRuntimeURLAccessDecision {
        guard projectRootURL.isFileURL else {
            return .deny(.invalidProjectRoot)
        }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if let host = components?.host, !host.isEmpty {
            return .deny(.nonLocalFileAuthority)
        }
        if components?.user != nil || components?.password != nil || components?.port != nil {
            return .deny(.nonLocalFileAuthority)
        }

        // Derive the relative path from the host-selected lexical root, then let ForgeProjectSandbox
        // perform the authoritative component-by-component symlink, existence, regular-file and
        // canonical-root checks. `resolvingSymlinksInPath()` alone is insufficient when a final child
        // does not yet exist because Foundation may leave an earlier symlink component unresolved.
        let lexicalRoot = projectRootURL.standardizedFileURL
        let candidate = url.standardizedFileURL
        let rootComponents = lexicalRoot.pathComponents
        let candidateComponents = candidate.pathComponents
        guard candidateComponents.count > rootComponents.count,
              Array(candidateComponents.prefix(rootComponents.count)) == rootComponents else {
            return .deny(.projectFileOutsideSandbox)
        }

        let relativePath = candidateComponents
            .dropFirst(rootComponents.count)
            .joined(separator: "/")

        do {
            _ = try ForgeProjectSandbox(rootURL: lexicalRoot)
                .resolveExistingFile(relativePath: relativePath)
            return .allowProjectFile
        } catch let error as ForgeProjectSandboxError {
            switch error {
            case .invalidRelativePath, .escapedSandbox:
                return .deny(.projectFileOutsideSandbox)
            case .fileNotFound:
                return .deny(.projectFileNotFound)
            case .directoryNotAllowed:
                return .deny(.projectDirectoryNotAllowed)
            case .symbolicLinkNotAllowed:
                return .deny(.projectSymbolicLinkNotAllowed)
            case .nonRegularFile:
                return .deny(.projectNonRegularFile)
            }
        } catch {
            return .deny(.projectFileUnavailable)
        }
    }
}
