import Foundation

/// Version of the on-disk Forge project manifest contract.
///
/// Major-version changes may be incompatible. Newer minor versions are accepted only when the
/// host explicitly advertises support for them.
public struct ForgeManifestFormatVersion: Codable, Equatable, Hashable, Sendable {
    public let major: Int
    public let minor: Int

    public init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }
}

/// Version of the Forge Runtime API required by a generated project.
public struct ForgeRuntimeVersion: Codable, Equatable, Hashable, Sendable {
    public let major: Int
    public let minor: Int

    public init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }
}

public struct ForgeProjectDisplayMetadata: Codable, Equatable, Sendable {
    public let name: String
    public let iconPath: String?

    public init(name: String, iconPath: String? = nil) {
        self.name = name
        self.iconPath = iconPath
    }
}

public enum ForgeOrientationPolicy: String, Codable, CaseIterable, Sendable {
    case portrait
    case landscape
    case automatic
    case mixed
}

public enum ForgeViewportPolicy: String, Codable, CaseIterable, Sendable {
    /// Project content stays inside system safe areas.
    case safeArea
    /// Project content may extend under system bars and must consume safe-area insets itself.
    case edgeToEdge
}

public struct ForgePresentationPolicy: Codable, Equatable, Sendable {
    public let orientation: ForgeOrientationPolicy
    public let viewport: ForgeViewportPolicy

    public init(
        orientation: ForgeOrientationPolicy = .automatic,
        viewport: ForgeViewportPolicy = .safeArea
    ) {
        self.orientation = orientation
        self.viewport = viewport
    }
}

public enum ForgeRequirement: String, Codable, CaseIterable, Sendable {
    case required
    case optional
}

/// A host capability requested by untrusted generated project code.
///
/// Capability identifiers intentionally remain strings so a newer project can carry an optional
/// capability on an older host. The validator must never grant a capability merely because it is
/// present in the manifest.
public struct ForgeCapabilityRequest: Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let requirement: ForgeRequirement

    public init(id: String, requirement: ForgeRequirement = .required) {
        self.id = id
        self.requirement = requirement
    }
}

public enum ForgeNetworkMode: String, Codable, CaseIterable, Sendable {
    case denied
    case allowListedHTTPS
}

/// External-network permission for a Forge project.
///
/// The initial contract is intentionally narrow: either no external network, or HTTPS to an exact
/// hostname allowlist. Wildcards, arbitrary schemes, ports and raw URLs are not host authority.
public struct ForgeNetworkPolicy: Codable, Equatable, Sendable {
    public let mode: ForgeNetworkMode
    public let allowedHosts: [String]

    public init(mode: ForgeNetworkMode = .denied, allowedHosts: [String] = []) {
        self.mode = mode
        self.allowedHosts = allowedHosts
    }
}

public struct ForgeStoragePolicy: Codable, Equatable, Sendable {
    /// Logical namespace requested by the project. The host validator binds this to project ID so
    /// a manifest cannot grant itself another project's storage namespace.
    public let namespace: String
    public let schemaVersion: Int
    public let quotaBytes: Int

    public init(namespace: String, schemaVersion: Int = 1, quotaBytes: Int) {
        self.namespace = namespace
        self.schemaVersion = schemaVersion
        self.quotaBytes = quotaBytes
    }
}

/// Requirement for a library bundled and versioned by NovaForge itself.
/// Generated projects cannot name arbitrary package URLs as curated modules.
public struct ForgeCuratedModuleRequirement: Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let version: String
    public let requirement: ForgeRequirement

    public init(id: String, version: String, requirement: ForgeRequirement = .required) {
        self.id = id
        self.version = version
        self.requirement = requirement
    }
}

/// Versioned manifest for safe host-executable projects.
///
/// This is data only. It does not grant capabilities, storage or network access. The host must
/// validate it against `ForgeRuntimeHostSupport` immediately before launch.
public struct ForgeProjectManifest: Codable, Equatable, Sendable {
    public let formatVersion: ForgeManifestFormatVersion
    public let projectID: String
    public let projectVersion: String
    public let runtimeVersion: ForgeRuntimeVersion
    public let entryPoint: String
    public let display: ForgeProjectDisplayMetadata
    public let presentation: ForgePresentationPolicy
    public let storage: ForgeStoragePolicy
    public let capabilities: [ForgeCapabilityRequest]
    public let network: ForgeNetworkPolicy
    public let bundledAssets: [String]
    public let modules: [ForgeCuratedModuleRequirement]

    public init(
        formatVersion: ForgeManifestFormatVersion = .init(major: 1, minor: 0),
        projectID: String,
        projectVersion: String,
        runtimeVersion: ForgeRuntimeVersion = .init(major: 1, minor: 0),
        entryPoint: String = "index.html",
        display: ForgeProjectDisplayMetadata,
        presentation: ForgePresentationPolicy = .init(),
        storage: ForgeStoragePolicy,
        capabilities: [ForgeCapabilityRequest] = [],
        network: ForgeNetworkPolicy = .init(),
        bundledAssets: [String] = [],
        modules: [ForgeCuratedModuleRequirement] = []
    ) {
        self.formatVersion = formatVersion
        self.projectID = projectID
        self.projectVersion = projectVersion
        self.runtimeVersion = runtimeVersion
        self.entryPoint = entryPoint
        self.display = display
        self.presentation = presentation
        self.storage = storage
        self.capabilities = capabilities
        self.network = network
        self.bundledAssets = bundledAssets
        self.modules = modules
    }
}

public enum ForgeRuntimeManifestLoadingError: Error, Equatable, Sendable {
    case manifestTooLarge(actualBytes: Int, maximumBytes: Int)
    case invalidJSON
}

/// Bounded JSON decoding for untrusted generated-project manifests.
public struct ForgeRuntimeManifestDecoder: Sendable {
    public let maximumManifestBytes: Int

    public init(maximumManifestBytes: Int = 256 * 1024) {
        self.maximumManifestBytes = maximumManifestBytes
    }

    public func decode(_ data: Data) throws -> ForgeProjectManifest {
        guard data.count <= maximumManifestBytes else {
            throw ForgeRuntimeManifestLoadingError.manifestTooLarge(
                actualBytes: data.count,
                maximumBytes: maximumManifestBytes
            )
        }

        do {
            return try JSONDecoder().decode(ForgeProjectManifest.self, from: data)
        } catch {
            throw ForgeRuntimeManifestLoadingError.invalidJSON
        }
    }
}
