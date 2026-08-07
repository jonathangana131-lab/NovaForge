import Foundation

public struct ForgeCuratedModuleCatalog: Equatable, Sendable {
    private let versionsByModule: [String: Set<String>]

    public init(versionsByModule: [String: Set<String>] = [:]) {
        self.versionsByModule = versionsByModule
    }

    public static let empty = ForgeCuratedModuleCatalog()

    public func supports(_ requirement: ForgeProjectManifest.ModuleRequirement) -> Bool {
        versionsByModule[requirement.id]?.contains(requirement.version) == true
    }
}

public enum ForgeManifestIssue: Error, Equatable, Sendable, CustomStringConvertible {
    case unsupportedManifestSchema(found: Int, supported: Int)
    case unsupportedRuntimeVersion(found: ForgeRuntimeVersion, supported: ForgeRuntimeVersion)
    case unsupportedRuntimeKind(ForgeRuntimeKind)
    case invalidProjectID(String)
    case invalidProjectVersion(Int)
    case invalidDisplayName
    case invalidEntryPoint(String)
    case invalidPath(String)
    case invalidIconPath(String)
    case duplicateAsset(String)
    case duplicateCapability(ForgeCapability)
    case invalidStorageNamespace(String)
    case invalidStorageSchemaVersion(Int)
    case offlinePolicyContainsOrigins
    case allowlistIsEmpty
    case invalidNetworkOrigin(String)
    case duplicateNetworkOrigin(String)
    case unsupportedModule(id: String, version: String)
    case duplicateModule(String)

    public var description: String {
        switch self {
        case let .unsupportedManifestSchema(found, supported):
            return "Manifest schema \(found) is unsupported; host supports schema \(supported)."
        case let .unsupportedRuntimeVersion(found, supported):
            return "Runtime \(found) is unsupported; host supports \(supported)."
        case let .unsupportedRuntimeKind(kind):
            return "Runtime kind \(kind.rawValue) is unsupported."
        case let .invalidProjectID(id):
            return "Project id is invalid: \(id)"
        case let .invalidProjectVersion(version):
            return "Project version must be positive; found \(version)."
        case .invalidDisplayName:
            return "Display name must contain visible text and remain within the v1 length limit."
        case let .invalidEntryPoint(path):
            return "Entry point must be a sandbox-relative .html file: \(path)"
        case let .invalidPath(path):
            return "Path is not a canonical sandbox-relative path: \(path)"
        case let .invalidIconPath(path):
            return "Icon path must be a supported sandbox image path: \(path)"
        case let .duplicateAsset(path):
            return "Asset is declared more than once: \(path)"
        case let .duplicateCapability(capability):
            return "Capability is requested more than once: \(capability.rawValue)"
        case let .invalidStorageNamespace(namespace):
            return "Storage namespace is invalid: \(namespace)"
        case let .invalidStorageSchemaVersion(version):
            return "Storage schema version must be positive; found \(version)."
        case .offlinePolicyContainsOrigins:
            return "Offline-only network policy cannot contain origins."
        case .allowlistIsEmpty:
            return "Allowlist network policy must contain at least one HTTPS origin."
        case let .invalidNetworkOrigin(origin):
            return "Network origin is not a canonical HTTPS origin: \(origin)"
        case let .duplicateNetworkOrigin(origin):
            return "Network origin is declared more than once: \(origin)"
        case let .unsupportedModule(id, version):
            return "Curated module is unsupported: \(id)@\(version)"
        case let .duplicateModule(id):
            return "Module is declared more than once: \(id)"
        }
    }
}

public struct ForgeManifestValidationError: Error, Equatable, Sendable {
    public let issues: [ForgeManifestIssue]

    public init(issues: [ForgeManifestIssue]) {
        self.issues = issues
    }
}

public struct ForgeManifestValidator: Sendable {
    public var moduleCatalog: ForgeCuratedModuleCatalog

    public init(moduleCatalog: ForgeCuratedModuleCatalog = .empty) {
        self.moduleCatalog = moduleCatalog
    }

    /// Validates all v1 host invariants and reports every deterministic issue found.
    /// No capability is granted by this method; validation only proves the request is structurally hostable.
    public func validate(_ manifest: ForgeProjectManifest) throws {
        var issues: [ForgeManifestIssue] = []

        if manifest.schemaVersion != ForgeRuntimeSupport.currentManifestSchema {
            issues.append(.unsupportedManifestSchema(
                found: manifest.schemaVersion,
                supported: ForgeRuntimeSupport.currentManifestSchema
            ))
        }

        let runtimeVersion = manifest.runtime.version
        if runtimeVersion.major < 0 || runtimeVersion.minor < 0 || runtimeVersion.patch < 0 || runtimeVersion != ForgeRuntimeSupport.currentRuntime {
            issues.append(.unsupportedRuntimeVersion(
                found: runtimeVersion,
                supported: ForgeRuntimeSupport.currentRuntime
            ))
        }

        if manifest.runtime.kind != .web {
            issues.append(.unsupportedRuntimeKind(manifest.runtime.kind))
        }

        if !Self.isValidIdentifier(manifest.project.id, maximumLength: 128) {
            issues.append(.invalidProjectID(manifest.project.id))
        }

        if manifest.project.version < 1 {
            issues.append(.invalidProjectVersion(manifest.project.version))
        }

        let displayName = manifest.project.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if displayName.isEmpty || displayName.count > 80 || displayName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            issues.append(.invalidDisplayName)
        }

        if !ForgeSandboxPath.isCanonical(manifest.runtime.entryPoint) || !manifest.runtime.entryPoint.lowercased().hasSuffix(".html") {
            issues.append(.invalidEntryPoint(manifest.runtime.entryPoint))
        }

        if let iconPath = manifest.project.iconPath {
            if !ForgeSandboxPath.isCanonical(iconPath) || !Self.isSupportedIconPath(iconPath) {
                issues.append(.invalidIconPath(iconPath))
            }
        }

        var seenAssets = Set<String>()
        for asset in manifest.assets {
            guard ForgeSandboxPath.isCanonical(asset) else {
                issues.append(.invalidPath(asset))
                continue
            }
            if !seenAssets.insert(asset).inserted {
                issues.append(.duplicateAsset(asset))
            }
        }

        var seenCapabilities = Set<ForgeCapability>()
        for capability in manifest.runtime.requestedCapabilities {
            if !seenCapabilities.insert(capability).inserted {
                issues.append(.duplicateCapability(capability))
            }
        }

        if !Self.isValidIdentifier(manifest.runtime.storage.namespace, maximumLength: 128) {
            issues.append(.invalidStorageNamespace(manifest.runtime.storage.namespace))
        }
        if manifest.runtime.storage.schemaVersion < 1 {
            issues.append(.invalidStorageSchemaVersion(manifest.runtime.storage.schemaVersion))
        }

        issues.append(contentsOf: validateNetwork(manifest.runtime.network))

        var seenModules = Set<String>()
        for module in manifest.modules {
            let key = module.id
            if !seenModules.insert(key).inserted {
                issues.append(.duplicateModule(key))
            }
            if !Self.isValidModuleIdentifier(module.id) || !Self.isValidModuleVersion(module.version) || !moduleCatalog.supports(module) {
                issues.append(.unsupportedModule(id: module.id, version: module.version))
            }
        }

        if !issues.isEmpty {
            throw ForgeManifestValidationError(issues: issues)
        }
    }

    private func validateNetwork(_ policy: ForgeNetworkPolicy) -> [ForgeManifestIssue] {
        switch policy.mode {
        case .offlineOnly:
            return policy.allowedOrigins.isEmpty ? [] : [.offlinePolicyContainsOrigins]
        case .allowlist:
            guard !policy.allowedOrigins.isEmpty else { return [.allowlistIsEmpty] }
            var issues: [ForgeManifestIssue] = []
            var seen = Set<String>()
            for origin in policy.allowedOrigins {
                guard Self.isCanonicalHTTPSOrigin(origin) else {
                    issues.append(.invalidNetworkOrigin(origin))
                    continue
                }
                let canonical = origin.lowercased()
                if !seen.insert(canonical).inserted {
                    issues.append(.duplicateNetworkOrigin(origin))
                }
            }
            return issues
        }
    }

    private static func isValidIdentifier(_ value: String, maximumLength: Int) -> Bool {
        guard (3...maximumLength).contains(value.count) else { return false }
        guard value == value.lowercased() else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")
        guard value.unicodeScalars.allSatisfy(allowed.contains) else { return false }
        guard let first = value.unicodeScalars.first, CharacterSet.alphanumerics.contains(first) else { return false }
        guard let last = value.unicodeScalars.last, CharacterSet.alphanumerics.contains(last) else { return false }
        return !value.contains("..") && !value.contains("--") && !value.contains("__")
    }

    private static func isValidModuleIdentifier(_ value: String) -> Bool {
        guard (1...80).contains(value.count) else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-/@")
        return value == value.lowercased() && value.unicodeScalars.allSatisfy(allowed.contains) && !value.contains("..")
    }

    private static func isValidModuleVersion(_ value: String) -> Bool {
        guard (1...40).contains(value.count) else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.+-")
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func isSupportedIconPath(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "webp", "svg"].contains(ext)
    }

    private static func isCanonicalHTTPSOrigin(_ value: String) -> Bool {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines), !value.contains("*") else { return false }
        guard let components = URLComponents(string: value) else { return false }
        guard components.scheme?.lowercased() == "https", let host = components.host, !host.isEmpty else { return false }
        guard components.user == nil, components.password == nil, components.query == nil, components.fragment == nil else { return false }
        guard components.path.isEmpty || components.path == "/" else { return false }
        guard value == value.lowercased() else { return false }
        return true
    }
}

public enum ForgeSandboxPath {
    /// Returns true only for canonical relative paths that cannot escape a project sandbox.
    /// Percent-encoded separators/traversal, URL syntax, backslashes, control characters,
    /// empty segments and dot segments are all rejected rather than normalized silently.
    public static func isCanonical(_ rawPath: String) -> Bool {
        guard !rawPath.isEmpty, rawPath == rawPath.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        guard !rawPath.hasPrefix("/"), !rawPath.hasPrefix("~"), !rawPath.contains("\\") else { return false }
        guard !rawPath.contains(":"), !rawPath.contains("?"), !rawPath.contains("#") else { return false }
        guard !rawPath.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
        guard let decoded = rawPath.removingPercentEncoding, decoded == rawPath else { return false }

        let components = rawPath.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty else { return false }
        for component in components {
            guard !component.isEmpty, component != ".", component != ".." else { return false }
        }
        return true
    }
}
