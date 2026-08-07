import Foundation

public enum ForgeRuntimeKind: String, Codable, CaseIterable, Sendable {
    case webV1 = "web-v1"
}

public enum ForgeRuntimeOrientation: String, Codable, CaseIterable, Sendable {
    case portrait
    case landscape
    case automatic
}

public enum ForgeRuntimeCapability: String, Codable, CaseIterable, Sendable {
    case localStorage = "local-storage"
    case haptics
    case share
    case controller
    case filePicker = "file-picker"
    case photoPicker = "photo-picker"
}

public struct ForgeRuntimeNetworkPolicy: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable {
        case offlineOnly = "offline-only"
        case denyAll = "deny-all"
        case allowlistedHosts = "allowlisted-hosts"
    }

    public var mode: Mode
    public var allowedHosts: [String]

    public init(mode: Mode = .offlineOnly, allowedHosts: [String] = []) {
        self.mode = mode
        self.allowedHosts = allowedHosts
    }

    public static let offlineOnly = Self(mode: .offlineOnly)
    public static let denyAll = Self(mode: .denyAll)

    public static func allowlisted(_ hosts: [String]) -> Self {
        Self(mode: .allowlistedHosts, allowedHosts: hosts)
    }
}

public struct ForgeProjectManifest: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var projectID: String
    public var displayName: String
    public var runtime: ForgeRuntimeKind
    public var entryPoint: String
    public var orientation: ForgeRuntimeOrientation
    public var capabilities: [ForgeRuntimeCapability]
    public var network: ForgeRuntimeNetworkPolicy

    public init(
        schemaVersion: Int = 1,
        projectID: String,
        displayName: String,
        runtime: ForgeRuntimeKind = .webV1,
        entryPoint: String = "index.html",
        orientation: ForgeRuntimeOrientation = .automatic,
        capabilities: [ForgeRuntimeCapability] = [.localStorage],
        network: ForgeRuntimeNetworkPolicy = .offlineOnly
    ) {
        self.schemaVersion = schemaVersion
        self.projectID = projectID
        self.displayName = displayName
        self.runtime = runtime
        self.entryPoint = entryPoint
        self.orientation = orientation
        self.capabilities = capabilities
        self.network = network
    }
}

public struct ForgeRuntimeLaunchPlan: Codable, Equatable, Sendable {
    public let projectID: String
    public let displayName: String
    public let runtime: ForgeRuntimeKind
    public let entryPointRelativePath: String
    public let orientation: ForgeRuntimeOrientation
    public let capabilities: [ForgeRuntimeCapability]
    public let network: ForgeRuntimeNetworkPolicy

    public init(
        projectID: String,
        displayName: String,
        runtime: ForgeRuntimeKind,
        entryPointRelativePath: String,
        orientation: ForgeRuntimeOrientation,
        capabilities: [ForgeRuntimeCapability],
        network: ForgeRuntimeNetworkPolicy
    ) {
        self.projectID = projectID
        self.displayName = displayName
        self.runtime = runtime
        self.entryPointRelativePath = entryPointRelativePath
        self.orientation = orientation
        self.capabilities = capabilities
        self.network = network
    }
}

public enum ForgeRuntimeManifestError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case invalidProjectID(String)
    case invalidDisplayName
    case invalidEntryPoint(String)
    case unsupportedEntryPoint(String)
    case duplicateCapability(ForgeRuntimeCapability)
    case networkHostsNotAllowed(ForgeRuntimeNetworkPolicy.Mode)
    case emptyNetworkAllowlist
    case duplicateNetworkHost(String)
    case invalidNetworkHost(String)
}

extension ForgeRuntimeManifestError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let version):
            return "Unsupported Forge Runtime manifest schema version: \(version)."
        case .invalidProjectID(let projectID):
            return "Invalid Forge project identifier: \(projectID)."
        case .invalidDisplayName:
            return "Forge project display name must contain 1 to 80 visible characters."
        case .invalidEntryPoint(let path):
            return "Forge Runtime entry point is not a safe sandbox-relative path: \(path)."
        case .unsupportedEntryPoint(let path):
            return "Forge Runtime currently executes HTML entry points only: \(path)."
        case .duplicateCapability(let capability):
            return "Forge Runtime capability is listed more than once: \(capability.rawValue)."
        case .networkHostsNotAllowed(let mode):
            return "Network hosts cannot be supplied while policy mode is \(mode.rawValue)."
        case .emptyNetworkAllowlist:
            return "An allowlisted-hosts network policy requires at least one host."
        case .duplicateNetworkHost(let host):
            return "Network host is listed more than once: \(host)."
        case .invalidNetworkHost(let host):
            return "Invalid Forge Runtime network host: \(host)."
        }
    }
}

public enum ForgeRuntimeManifestValidator {
    public static let supportedSchemaVersion = 1

    public static func makeLaunchPlan(for manifest: ForgeProjectManifest) throws -> ForgeRuntimeLaunchPlan {
        guard manifest.schemaVersion == supportedSchemaVersion else {
            throw ForgeRuntimeManifestError.unsupportedSchemaVersion(manifest.schemaVersion)
        }

        try validateProjectID(manifest.projectID)
        let displayName = try validatedDisplayName(manifest.displayName)
        try validateEntryPoint(manifest.entryPoint)
        try validateCapabilities(manifest.capabilities)
        let network = try validatedNetworkPolicy(manifest.network)

        return ForgeRuntimeLaunchPlan(
            projectID: manifest.projectID,
            displayName: displayName,
            runtime: manifest.runtime,
            entryPointRelativePath: manifest.entryPoint,
            orientation: manifest.orientation,
            capabilities: manifest.capabilities.sorted { $0.rawValue < $1.rawValue },
            network: network
        )
    }

    private static func validateProjectID(_ projectID: String) throws {
        guard !projectID.isEmpty, projectID.utf8.count <= 64 else {
            throw ForgeRuntimeManifestError.invalidProjectID(projectID)
        }

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")
        guard projectID.unicodeScalars.allSatisfy(allowed.contains),
              projectID.first?.isASCII == true,
              projectID.first?.isLetter == true || projectID.first?.isNumber == true,
              projectID.last?.isLetter == true || projectID.last?.isNumber == true,
              !projectID.contains("..") else {
            throw ForgeRuntimeManifestError.invalidProjectID(projectID)
        }
    }

    private static func validatedDisplayName(_ displayName: String) throws -> String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= 80,
              !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ForgeRuntimeManifestError.invalidDisplayName
        }
        return trimmed
    }

    private static func validateEntryPoint(_ path: String) throws {
        guard isSafeRelativePath(path) else {
            throw ForgeRuntimeManifestError.invalidEntryPoint(path)
        }

        guard path.lowercased().hasSuffix(".html") else {
            throw ForgeRuntimeManifestError.unsupportedEntryPoint(path)
        }
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              path.utf8.count <= 240,
              !path.hasPrefix("/"),
              !path.hasPrefix("~"),
              !path.contains("\\"),
              !path.contains(":"),
              !path.contains("%"),
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return false
        }

        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty else { return false }
        return components.allSatisfy { component in
            !component.isEmpty && component != "." && component != ".."
        }
    }

    private static func validateCapabilities(_ capabilities: [ForgeRuntimeCapability]) throws {
        var seen = Set<ForgeRuntimeCapability>()
        for capability in capabilities {
            guard seen.insert(capability).inserted else {
                throw ForgeRuntimeManifestError.duplicateCapability(capability)
            }
        }
    }

    private static func validatedNetworkPolicy(
        _ policy: ForgeRuntimeNetworkPolicy
    ) throws -> ForgeRuntimeNetworkPolicy {
        switch policy.mode {
        case .offlineOnly, .denyAll:
            guard policy.allowedHosts.isEmpty else {
                throw ForgeRuntimeManifestError.networkHostsNotAllowed(policy.mode)
            }
            return policy

        case .allowlistedHosts:
            guard !policy.allowedHosts.isEmpty else {
                throw ForgeRuntimeManifestError.emptyNetworkAllowlist
            }
            guard policy.allowedHosts.count <= 32 else {
                throw ForgeRuntimeManifestError.invalidNetworkHost("too-many-hosts")
            }

            var seen = Set<String>()
            var validated: [String] = []
            validated.reserveCapacity(policy.allowedHosts.count)

            for rawHost in policy.allowedHosts {
                let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
                guard isValidHost(host) else {
                    throw ForgeRuntimeManifestError.invalidNetworkHost(rawHost)
                }
                guard seen.insert(host).inserted else {
                    throw ForgeRuntimeManifestError.duplicateNetworkHost(host)
                }
                validated.append(host)
            }

            return .allowlisted(validated.sorted())
        }
    }

    private static func isValidHost(_ host: String) -> Bool {
        guard !host.isEmpty,
              host.utf8.count <= 253,
              host == host.lowercased(),
              !host.contains("//"),
              !host.contains("/"),
              !host.contains(":"),
              !host.contains("@"),
              !host.contains("*"),
              !host.contains("%"),
              host.unicodeScalars.allSatisfy({ $0.isASCII }) else {
            return false
        }

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")
        guard host.unicodeScalars.allSatisfy(allowed.contains),
              !host.hasPrefix("."),
              !host.hasSuffix("."),
              !host.contains("..") else {
            return false
        }

        return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            guard !label.isEmpty,
                  label.utf8.count <= 63,
                  label.first != "-",
                  label.last != "-" else {
                return false
            }
            return true
        }
    }
}
