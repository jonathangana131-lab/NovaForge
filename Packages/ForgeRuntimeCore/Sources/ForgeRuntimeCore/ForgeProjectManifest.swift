import Foundation

/// The host-executable project contract for NovaForge's sandboxed web runtime.
///
/// This type intentionally describes capability requests rather than host authority.
/// A project manifest can request a bridge capability, but only the host policy can grant it.
public struct ForgeProjectManifest: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var project: Project
    public var runtime: Runtime
    public var assets: [String]
    public var modules: [ModuleRequirement]
    public var launch: LaunchMetadata?

    public init(
        schemaVersion: Int = ForgeRuntimeSupport.currentManifestSchema,
        project: Project,
        runtime: Runtime,
        assets: [String] = [],
        modules: [ModuleRequirement] = [],
        launch: LaunchMetadata? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.project = project
        self.runtime = runtime
        self.assets = assets
        self.modules = modules
        self.launch = launch
    }
}

public extension ForgeProjectManifest {
    struct Project: Codable, Equatable, Sendable {
        public var id: String
        public var version: Int
        public var displayName: String
        public var iconPath: String?

        public init(id: String, version: Int = 1, displayName: String, iconPath: String? = nil) {
            self.id = id
            self.version = version
            self.displayName = displayName
            self.iconPath = iconPath
        }
    }

    struct Runtime: Codable, Equatable, Sendable {
        public var version: ForgeRuntimeVersion
        public var kind: ForgeRuntimeKind
        public var entryPoint: String
        public var orientation: ForgeOrientationPolicy
        public var viewport: ForgeViewportPolicy
        public var requestedCapabilities: [ForgeCapability]
        public var network: ForgeNetworkPolicy
        public var storage: ForgeStoragePolicy

        public init(
            version: ForgeRuntimeVersion = ForgeRuntimeSupport.currentRuntime,
            kind: ForgeRuntimeKind = .web,
            entryPoint: String,
            orientation: ForgeOrientationPolicy = .auto,
            viewport: ForgeViewportPolicy = .init(),
            requestedCapabilities: [ForgeCapability] = [],
            network: ForgeNetworkPolicy = .offlineOnly,
            storage: ForgeStoragePolicy
        ) {
            self.version = version
            self.kind = kind
            self.entryPoint = entryPoint
            self.orientation = orientation
            self.viewport = viewport
            self.requestedCapabilities = requestedCapabilities
            self.network = network
            self.storage = storage
        }
    }

    struct ModuleRequirement: Codable, Equatable, Hashable, Sendable {
        public var id: String
        public var version: String

        public init(id: String, version: String) {
            self.id = id
            self.version = version
        }
    }

    struct LaunchMetadata: Codable, Equatable, Sendable {
        public var title: String?
        public var subtitle: String?
        public var prefersDarkAppearance: Bool?

        public init(title: String? = nil, subtitle: String? = nil, prefersDarkAppearance: Bool? = nil) {
            self.title = title
            self.subtitle = subtitle
            self.prefersDarkAppearance = prefersDarkAppearance
        }
    }
}

public enum ForgeRuntimeKind: String, Codable, CaseIterable, Sendable {
    /// HTML/CSS/JavaScript/Canvas/WebGL hosted by NovaForge.
    case web
}

public enum ForgeOrientationPolicy: String, Codable, CaseIterable, Sendable {
    case portrait
    case landscape
    case auto
    case mixed
}

public struct ForgeViewportPolicy: Codable, Equatable, Sendable {
    public enum Layout: String, Codable, CaseIterable, Sendable {
        /// The project is laid out inside the current safe area.
        case safeArea
        /// The project owns the full visual canvas and receives safe-area inset values.
        case edgeToEdge
    }

    public var layout: Layout
    public var allowsUserScaling: Bool

    public init(layout: Layout = .safeArea, allowsUserScaling: Bool = false) {
        self.layout = layout
        self.allowsUserScaling = allowsUserScaling
    }
}

/// Bridge capabilities implemented by Forge Runtime v1.
///
/// Absence means no access. Unknown values fail decoding instead of silently degrading.
public enum ForgeCapability: String, Codable, CaseIterable, Sendable {
    case localStorage
    case haptics
    case share
    case controller
    case filePicker
    case photoPicker
}

public struct ForgeNetworkPolicy: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable {
        case offlineOnly
        case allowlist
    }

    public var mode: Mode
    public var allowedOrigins: [String]

    public init(mode: Mode, allowedOrigins: [String] = []) {
        self.mode = mode
        self.allowedOrigins = allowedOrigins
    }

    public static let offlineOnly = ForgeNetworkPolicy(mode: .offlineOnly)

    public static func allowlist(_ origins: [String]) -> ForgeNetworkPolicy {
        ForgeNetworkPolicy(mode: .allowlist, allowedOrigins: origins)
    }
}

public struct ForgeStoragePolicy: Codable, Equatable, Sendable {
    public var namespace: String
    public var schemaVersion: Int

    public init(namespace: String, schemaVersion: Int = 1) {
        self.namespace = namespace
        self.schemaVersion = schemaVersion
    }
}

public struct ForgeRuntimeVersion: Codable, Equatable, Hashable, Comparable, Sendable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int

    public init(_ major: Int, _ minor: Int, _ patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }
}

public enum ForgeRuntimeSupport {
    public static let currentManifestSchema = 1
    public static let currentRuntime = ForgeRuntimeVersion(1, 0, 0)
}
