import Foundation

/// Host-owned authority derived from a manifest that already passed validation.
///
/// Generated code never constructs this value directly. The host derives it from its own support
/// snapshot so optional unsupported requests disappear rather than becoming ambient authority.
public struct ForgeRuntimeLaunchAuthorization: Equatable, Sendable {
    public let projectID: String
    /// Canonical validated manifest project version retained so downstream host-owned capabilities
    /// can bind to the exact source revision selected by the host rather than a caller-supplied alias.
    public let projectVersion: String
    public let runtimeVersion: ForgeRuntimeVersion
    public let entryPoint: String
    public let presentation: ForgePresentationPolicy
    public let storage: ForgeAuthorizedStoragePolicy
    public let grantedCapabilityIDs: Set<String>
    public let network: ForgeAuthorizedNetworkPolicy
    public let modules: [ForgeAuthorizedModule]

    init(
        projectID: String,
        projectVersion: String,
        runtimeVersion: ForgeRuntimeVersion,
        entryPoint: String,
        presentation: ForgePresentationPolicy,
        storage: ForgeAuthorizedStoragePolicy,
        grantedCapabilityIDs: Set<String>,
        network: ForgeAuthorizedNetworkPolicy,
        modules: [ForgeAuthorizedModule]
    ) {
        self.projectID = projectID
        self.projectVersion = projectVersion
        self.runtimeVersion = runtimeVersion
        self.entryPoint = entryPoint
        self.presentation = presentation
        self.storage = storage
        self.grantedCapabilityIDs = grantedCapabilityIDs
        self.network = network
        self.modules = modules
    }
}

public struct ForgeAuthorizedStoragePolicy: Equatable, Sendable {
    public let namespace: String
    public let schemaVersion: Int
    public let quotaBytes: Int
}

public struct ForgeAuthorizedNetworkPolicy: Equatable, Sendable {
    public let mode: ForgeNetworkMode
    /// Canonical lowercase exact hostnames. Empty when network is denied.
    public let allowedHosts: [String]
}

public struct ForgeAuthorizedModule: Equatable, Hashable, Sendable {
    public let id: String
    public let version: String
}

public enum ForgeRuntimeLaunchAuthorizationError: Error, Equatable, Sendable {
    case manifestRejected(ForgeRuntimeValidationReport)
}

public extension ForgeRuntimeManifestValidator {
    /// Validates and then derives the exact host-granted launch authority.
    func authorize(
        _ manifest: ForgeProjectManifest,
        expectedProjectID: String,
        host: ForgeRuntimeHostSupport
    ) throws -> ForgeRuntimeLaunchAuthorization {
        let report = validate(manifest, expectedProjectID: expectedProjectID, host: host)
        guard report.isLaunchable else {
            throw ForgeRuntimeLaunchAuthorizationError.manifestRejected(report)
        }

        let grantedCapabilities = Set(
            manifest.capabilities.lazy
                .map(\.id)
                .filter(host.supportedCapabilityIDs.contains)
        )

        let allowedHosts: [String]
        switch manifest.network.mode {
        case .denied:
            allowedHosts = []
        case .allowListedHTTPS:
            allowedHosts = Array(Set(manifest.network.allowedHosts.map { $0.lowercased() })).sorted()
        }

        let authorizedModules = manifest.modules.compactMap { module -> ForgeAuthorizedModule? in
            guard host.curatedModuleVersions[module.id]?.contains(module.version) == true else {
                return nil
            }
            return .init(id: module.id, version: module.version)
        }.sorted { lhs, rhs in
            lhs.id == rhs.id ? lhs.version < rhs.version : lhs.id < rhs.id
        }

        return ForgeRuntimeLaunchAuthorization(
            projectID: manifest.projectID,
            projectVersion: manifest.projectVersion.trimmingCharacters(in: .whitespacesAndNewlines),
            runtimeVersion: manifest.runtimeVersion,
            entryPoint: manifest.entryPoint,
            presentation: manifest.presentation,
            storage: .init(
                namespace: manifest.storage.namespace,
                schemaVersion: manifest.storage.schemaVersion,
                quotaBytes: manifest.storage.quotaBytes
            ),
            grantedCapabilityIDs: grantedCapabilities,
            network: .init(mode: manifest.network.mode, allowedHosts: allowedHosts),
            modules: authorizedModules
        )
    }
}

/// Shared lexical path policy for untrusted Forge manifest paths.
enum ForgeRuntimePathPolicy {
    static func isValidRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 1_024 else { return false }
        guard !value.hasPrefix("/"), !value.hasPrefix("~"), !value.contains("\\"), !value.contains("\0"),
              !value.contains("%"), !value.contains("?"), !value.contains("#") else {
            return false
        }

        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty else { return false }
        return components.allSatisfy { component in
            !component.isEmpty && component != "." && component != ".."
        }
    }
}

public enum ForgeProjectSandboxError: Error, Equatable, Sendable {
    case invalidRelativePath
    case fileNotFound
    case directoryNotAllowed
    case symbolicLinkNotAllowed
    case nonRegularFile
    case escapedSandbox
}

/// Resolves project-owned files while defending against lexical traversal and symlink escape.
///
/// The host-selected root is canonicalized when the sandbox is created. Project-owned symbolic-link
/// components are rejected rather than followed, then the existing regular file is canonicalized and
/// checked against the exact root path components. The eventual runtime host should still avoid
/// mutable validation-to-open races while a project is running.
public struct ForgeProjectSandbox: Sendable {
    public let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
    }

    public func resolveExistingFile(
        relativePath: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard ForgeRuntimePathPolicy.isValidRelativePath(relativePath) else {
            throw ForgeProjectSandboxError.invalidRelativePath
        }

        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        var candidate = rootURL
        for component in components {
            candidate.appendPathComponent(String(component), isDirectory: false)
            let values = try? candidate.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values?.isSymbolicLink == true {
                throw ForgeProjectSandboxError.symbolicLinkNotAllowed
            }
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory) else {
            throw ForgeProjectSandboxError.fileNotFound
        }
        guard !isDirectory.boolValue else {
            throw ForgeProjectSandboxError.directoryNotAllowed
        }

        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
        let rootComponents = rootURL.pathComponents
        let resolvedComponents = resolved.pathComponents
        guard resolvedComponents.count > rootComponents.count,
              Array(resolvedComponents.prefix(rootComponents.count)) == rootComponents else {
            throw ForgeProjectSandboxError.escapedSandbox
        }

        let values = try resolved.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else {
            throw ForgeProjectSandboxError.nonRegularFile
        }

        return resolved
    }
}
