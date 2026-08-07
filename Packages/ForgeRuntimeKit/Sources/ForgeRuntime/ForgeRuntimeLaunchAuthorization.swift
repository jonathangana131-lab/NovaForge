import Foundation

/// Host-owned authority derived from a manifest that already passed validation and an exact-project
/// grant that came from outside generated project code.
public struct ForgeRuntimeLaunchAuthorization: Equatable, Sendable {
    public let projectID: String
    public let runtimeVersion: ForgeRuntimeVersion
    public let entryPoint: String
    public let presentation: ForgePresentationPolicy
    public let storage: ForgeAuthorizedStoragePolicy
    public let grantedCapabilityIDs: Set<String>
    public let network: ForgeAuthorizedNetworkPolicy
    public let modules: [ForgeAuthorizedModule]

    init(
        projectID: String,
        runtimeVersion: ForgeRuntimeVersion,
        entryPoint: String,
        presentation: ForgePresentationPolicy,
        storage: ForgeAuthorizedStoragePolicy,
        grantedCapabilityIDs: Set<String>,
        network: ForgeAuthorizedNetworkPolicy,
        modules: [ForgeAuthorizedModule]
    ) {
        self.projectID = projectID
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
    /// ForgeRuntimeResourcePolicy additionally restricts external requests to HTTPS port 443.
    public let allowedHosts: [String]
}

public struct ForgeAuthorizedModule: Equatable, Hashable, Sendable {
    public let id: String
    public let version: String
}

public enum ForgeRuntimeLaunchAuthorizationError: Error, Equatable, Sendable {
    case manifestRejected(ForgeRuntimeValidationReport)
    case invalidProjectGrant(ForgeRuntimeProjectGrantError)
    case requiredCapabilityNotGranted(String)
    case networkHostNotGranted(String)
}

public extension ForgeRuntimeManifestValidator {
    /// Validates the project request, validates the separately owned exact-project grant, then derives
    /// only the intersection of requested + supported + granted authority.
    func authorize(
        _ manifest: ForgeProjectManifest,
        expectedProjectID: String,
        host: ForgeRuntimeHostSupport,
        projectGrant: ForgeRuntimeProjectGrant
    ) throws -> ForgeRuntimeLaunchAuthorization {
        let report = validate(manifest, expectedProjectID: expectedProjectID, host: host)
        guard report.isLaunchable else {
            throw ForgeRuntimeLaunchAuthorizationError.manifestRejected(report)
        }

        do {
            try projectGrant.validate(expectedProjectID: expectedProjectID, host: host)
        } catch let error as ForgeRuntimeProjectGrantError {
            throw ForgeRuntimeLaunchAuthorizationError.invalidProjectGrant(error)
        }

        for request in manifest.capabilities where request.requirement == .required {
            guard projectGrant.grantedCapabilityIDs.contains(request.id) else {
                throw ForgeRuntimeLaunchAuthorizationError.requiredCapabilityNotGranted(request.id)
            }
        }

        let requestedCapabilityIDs = Set(manifest.capabilities.map(\.id))
        let grantedCapabilities = requestedCapabilityIDs
            .intersection(host.supportedCapabilityIDs)
            .intersection(projectGrant.grantedCapabilityIDs)

        let allowedHosts: [String]
        switch manifest.network.mode {
        case .denied:
            allowedHosts = []
        case .allowListedHTTPS:
            let requestedHosts = Array(Set(manifest.network.allowedHosts.map { $0.lowercased() })).sorted()
            for hostName in requestedHosts where !projectGrant.allowedHTTPSHosts.contains(hostName) {
                throw ForgeRuntimeLaunchAuthorizationError.networkHostNotGranted(hostName)
            }
            allowedHosts = requestedHosts
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
