import Foundation

public struct ForgeRuntimeHostSupport: Equatable, Sendable {
    public let supportedManifestMajor: Int
    public let maximumManifestMinor: Int
    public let supportedRuntimeMajor: Int
    public let maximumRuntimeMinor: Int
    public let supportedCapabilityIDs: Set<String>
    public let curatedModuleVersions: [String: Set<String>]
    public let supportsMixedOrientation: Bool
    public let maximumStorageQuotaBytes: Int
    public let maximumAssets: Int
    public let maximumCapabilityRequests: Int
    public let maximumModules: Int
    public let maximumNetworkHosts: Int

    public init(
        supportedManifestMajor: Int = 1,
        maximumManifestMinor: Int = 0,
        supportedRuntimeMajor: Int = 1,
        maximumRuntimeMinor: Int = 0,
        supportedCapabilityIDs: Set<String> = [],
        curatedModuleVersions: [String: Set<String>] = [:],
        supportsMixedOrientation: Bool = false,
        maximumStorageQuotaBytes: Int = 64 * 1024 * 1024,
        maximumAssets: Int = 4_096,
        maximumCapabilityRequests: Int = 64,
        maximumModules: Int = 64,
        maximumNetworkHosts: Int = 128
    ) {
        self.supportedManifestMajor = supportedManifestMajor
        self.maximumManifestMinor = maximumManifestMinor
        self.supportedRuntimeMajor = supportedRuntimeMajor
        self.maximumRuntimeMinor = maximumRuntimeMinor
        self.supportedCapabilityIDs = supportedCapabilityIDs
        self.curatedModuleVersions = curatedModuleVersions
        self.supportsMixedOrientation = supportsMixedOrientation
        self.maximumStorageQuotaBytes = maximumStorageQuotaBytes
        self.maximumAssets = maximumAssets
        self.maximumCapabilityRequests = maximumCapabilityRequests
        self.maximumModules = maximumModules
        self.maximumNetworkHosts = maximumNetworkHosts
    }
}

public enum ForgeRuntimeValidationSeverity: String, Codable, Sendable {
    case warning
    case error
}

public enum ForgeRuntimeValidationCode: String, Codable, Sendable {
    case unsupportedManifestVersion
    case invalidProjectID
    case projectIdentityMismatch
    case invalidProjectVersion
    case unsupportedRuntimeVersion
    case invalidEntryPoint
    case invalidDisplayName
    case invalidIconPath
    case unsupportedOrientation
    case storageNamespaceMismatch
    case invalidStorageSchemaVersion
    case invalidStorageQuota
    case capabilityRequestLimitExceeded
    case invalidCapabilityID
    case duplicateCapability
    case unsupportedRequiredCapability
    case unsupportedOptionalCapability
    case networkHostLimitExceeded
    case networkHostsNotAllowed
    case networkAllowListEmpty
    case invalidNetworkHost
    case duplicateNetworkHost
    case assetLimitExceeded
    case invalidAssetPath
    case duplicateAsset
    case moduleLimitExceeded
    case invalidModuleID
    case invalidModuleVersion
    case duplicateModule
    case unsupportedRequiredModule
    case unsupportedOptionalModule
}

public struct ForgeRuntimeValidationIssue: Equatable, Sendable {
    public let severity: ForgeRuntimeValidationSeverity
    public let code: ForgeRuntimeValidationCode
    public let field: String
    public let detail: String

    public init(
        severity: ForgeRuntimeValidationSeverity,
        code: ForgeRuntimeValidationCode,
        field: String,
        detail: String
    ) {
        self.severity = severity
        self.code = code
        self.field = field
        self.detail = detail
    }
}

public struct ForgeRuntimeValidationReport: Equatable, Sendable {
    public let issues: [ForgeRuntimeValidationIssue]

    public init(issues: [ForgeRuntimeValidationIssue]) {
        self.issues = issues
    }

    public var errors: [ForgeRuntimeValidationIssue] {
        issues.filter { $0.severity == .error }
    }

    public var warnings: [ForgeRuntimeValidationIssue] {
        issues.filter { $0.severity == .warning }
    }

    public var isLaunchable: Bool {
        errors.isEmpty
    }
}

/// Validates a manifest against host-owned support and exact project identity.
///
/// A successful report means only that the requested contract is structurally launchable. Actual
/// bridge/network/storage authority must still be created by the host from the validated result;
/// generated code never self-authorizes by editing its manifest.
public struct ForgeRuntimeManifestValidator: Sendable {
    public init() {}

    public func validate(
        _ manifest: ForgeProjectManifest,
        expectedProjectID: String,
        host: ForgeRuntimeHostSupport
    ) -> ForgeRuntimeValidationReport {
        var issues: [ForgeRuntimeValidationIssue] = []

        validateManifestVersion(manifest, host: host, issues: &issues)
        validateProjectIdentity(manifest, expectedProjectID: expectedProjectID, issues: &issues)
        validateRuntimeVersion(manifest, host: host, issues: &issues)
        validatePathsAndDisplay(manifest, host: host, issues: &issues)
        validatePresentation(manifest, host: host, issues: &issues)
        validateStorage(manifest, expectedProjectID: expectedProjectID, host: host, issues: &issues)
        validateCapabilities(manifest, host: host, issues: &issues)
        validateNetwork(manifest, host: host, issues: &issues)
        validateAssets(manifest, host: host, issues: &issues)
        validateModules(manifest, host: host, issues: &issues)

        return ForgeRuntimeValidationReport(issues: issues)
    }

    private func validateManifestVersion(
        _ manifest: ForgeProjectManifest,
        host: ForgeRuntimeHostSupport,
        issues: inout [ForgeRuntimeValidationIssue]
    ) {
        let version = manifest.formatVersion
        guard version.major == host.supportedManifestMajor,
              version.minor >= 0,
              version.minor <= host.maximumManifestMinor else {
            issues.append(.error(
                .unsupportedManifestVersion,
                field: "formatVersion",
                "Manifest format \(version.major).\(version.minor) is not supported by this host."
            ))
            return
        }
    }

    private func validateProjectIdentity(
        _ manifest: ForgeProjectManifest,
        expectedProjectID: String,
        issues: inout [ForgeRuntimeValidationIssue]
    ) {
        if !Self.isValidIdentifier(manifest.projectID, maximumLength: 128) {
            issues.append(.error(
                .invalidProjectID,
                field: "projectID",
                "Project ID must be a bounded ASCII identifier and cannot contain path syntax."
            ))
        }

        if manifest.projectID != expectedProjectID {
            issues.append(.error(
                .projectIdentityMismatch,
                field: "projectID",
                "Manifest project identity does not match the host-selected project."
            ))
        }

        let version = manifest.projectVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        if version.isEmpty || version.utf8.count > 64 || !Self.isValidVersionToken(version) {
            issues.append(.error(
                .invalidProjectVersion,
                field: "projectVersion",
                "Project version must be a non-empty bounded version token."
            ))
        }
    }

    private func validateRuntimeVersion(
        _ manifest: ForgeProjectManifest,
        host: ForgeRuntimeHostSupport,
        issues: inout [ForgeRuntimeValidationIssue]
    ) {
        let version = manifest.runtimeVersion
        guard version.major == host.supportedRuntimeMajor,
              version.minor >= 0,
              version.minor <= host.maximumRuntimeMinor else {
            issues.append(.error(
                .unsupportedRuntimeVersion,
                field: "runtimeVersion",
                "Forge Runtime \(version.major).\(version.minor) is not supported by this host."
            ))
            return
        }
    }

    private func validatePathsAndDisplay(
        _ manifest: ForgeProjectManifest,
        host _: ForgeRuntimeHostSupport,
        issues: inout [ForgeRuntimeValidationIssue]
    ) {
        guard Self.isValidSandboxRelativePath(manifest.entryPoint),
              Self.pathExtension(of: manifest.entryPoint).lowercased() == "html" else {
            issues.append(.error(
                .invalidEntryPoint,
                field: "entryPoint",
                "Entry point must be a sandbox-relative HTML file."
            ))
            return validateDisplay(manifest, issues: &issues)
        }

        validateDisplay(manifest, issues: &issues)
    }

    private func validateDisplay(
        _ manifest: ForgeProjectManifest,
        issues: inout [ForgeRuntimeValidationIssue]
    ) {
        let name = manifest.display.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name.count > 80 {
            issues.append(.error(
                .invalidDisplayName,
                field: "display.name",
                "Display name must contain 1...80 visible characters."
            ))
        }

        if let iconPath = manifest.display.iconPath,
           !Self.isValidSandboxRelativePath(iconPath) {
            issues.append(.error(
                .invalidIconPath,
                field: "display.iconPath",
                "Icon path must remain inside the project sandbox."
            ))
        }
    }

    private func validatePresentation(
        _ manifest: ForgeProjectManifest,
        host: ForgeRuntimeHostSupport,
        issues: inout [ForgeRuntimeValidationIssue]
    ) {
        if manifest.presentation.orientation == .mixed, !host.supportsMixedOrientation {
            issues.append(.error(
                .unsupportedOrientation,
                field: "presentation.orientation",
                "Mixed orientation is not supported by this runtime host."
            ))
        }
    }

    private func validateStorage(
        _ manifest: ForgeProjectManifest,
        expectedProjectID: String,
        host: ForgeRuntimeHostSupport,
        issues: inout [ForgeRuntimeValidationIssue]
    ) {
        if manifest.storage.namespace != expectedProjectID || manifest.storage.namespace != manifest.projectID {
            issues.append(.error(
                .storageNamespaceMismatch,
                field: "storage.namespace",
                "Storage namespace must be bound to the exact host-selected project identity."
            ))
        }

        if manifest.storage.schemaVersion < 1 {
            issues.append(.error(
                .invalidStorageSchemaVersion,
                field: "storage.schemaVersion",
                "Storage schema version must be positive."
            ))
        }

        if manifest.storage.quotaBytes <= 0 || manifest.storage.quotaBytes > host.maximumStorageQuotaBytes {
            issues.append(.error(
                .invalidStorageQuota,
                field: "storage.quotaBytes",
                "Requested storage quota exceeds the host-owned project limit."
            ))
        }
    }

    private func validateCapabilities(
        _ manifest: ForgeProjectManifest,
        host: ForgeRuntimeHostSupport,
        issues: inout [ForgeRuntimeValidationIssue]
    ) {
        if manifest.capabilities.count > host.maximumCapabilityRequests {
            issues.append(.error(
                .capabilityRequestLimitExceeded,
                field: "capabilities",
                "Capability request count exceeds the host manifest limit."
            ))
        }

        var seen: Set<String> = []
        for (index, request) in manifest.capabilities.enumerated() {
            let field = "capabilities[\(index)]"
            if !Self.isValidCapabilityID(request.id) {
                issues.append(.error(
                    .invalidCapabilityID,
                    field: "\(field).id",
                    "Capability ID is not a valid namespaced token."
                ))
                continue
            }

            if !seen.insert(request.id).inserted {
                issues.append(.error(
                    .duplicateCapability,
                    field: field,
                    "A capability may be requested only once."
                ))
                continue
            }

            guard host.supportedCapabilityIDs.contains(request.id) else {
                switch request.requirement {
                case .required:
                    issues.append(.error(
                        .unsupportedRequiredCapability,
                        field: field,
                        "Required capability \(request.id) is not supported by this host."
                    ))
                case .optional:
                    issues.append(.warning(
                        .unsupportedOptionalCapability,
                        field: field,
                        "Optional capability \(request.id) will not be granted."
                    ))
                }
                continue
            }
        }
    }

    private func validateNetwork(
        _ manifest: ForgeProjectManifest,
        host: ForgeRuntimeHostSupport,
        issues: inout [ForgeRuntimeValidationIssue]
    ) {
        let hosts = manifest.network.allowedHosts
        if hosts.count > host.maximumNetworkHosts {
            issues.append(.error(
                .networkHostLimitExceeded,
                field: "network.allowedHosts",
                "Network allowlist exceeds the host manifest limit."
            ))
        }

        switch manifest.network.mode {
        case .denied:
            if !hosts.isEmpty {
                issues.append(.error(
                    .networkHostsNotAllowed,
                    field: "network.allowedHosts",
                    "A denied network policy cannot carry allowed hosts."
                ))
            }
        case .allowListedHTTPS:
            if hosts.isEmpty {
                issues.append(.error(
                    .networkAllowListEmpty,
                    field: "network.allowedHosts",
                    "HTTPS allowlist mode requires at least one exact hostname."
                ))
            }
        }

        var seen: Set<String> = []
        for (index, rawHost) in hosts.enumerated() {
            let normalized = rawHost.lowercased()
            if !Self.isValidExactHost(rawHost) {
                issues.append(.error(
                    .invalidNetworkHost,
                    field: "network.allowedHosts[\(index)]",
                    "Network hosts must be exact hostnames without scheme, wildcard, port, path or credentials."
                ))
                continue
            }

            if !seen.insert(normalized).inserted {
                issues.append(.warning(
                    .duplicateNetworkHost,
                    field: "network.allowedHosts[\(index)]",
                    "Duplicate network host will not widen authority."
                ))
            }
        }
    }

    private func validateAssets(
        _ manifest: ForgeProjectManifest,
        host: ForgeRuntimeHostSupport,
        issues: inout [ForgeRuntimeValidationIssue]
    ) {
        if manifest.bundledAssets.count > host.maximumAssets {
            issues.append(.error(
                .assetLimitExceeded,
                field: "bundledAssets",
                "Bundled asset count exceeds the host manifest limit."
            ))
        }

        var seen: Set<String> = []
        for (index, path) in manifest.bundledAssets.enumerated() {
            if !Self.isValidSandboxRelativePath(path) {
                issues.append(.error(
                    .invalidAssetPath,
                    field: "bundledAssets[\(index)]",
                    "Bundled asset path must remain inside the project sandbox."
                ))
                continue
            }

            if !seen.insert(path).inserted {
                issues.append(.warning(
                    .duplicateAsset,
                    field: "bundledAssets[\(index)]",
                    "Duplicate asset entry is redundant."
                ))
            }
        }
    }

    private func validateModules(
        _ manifest: ForgeProjectManifest,
        host: ForgeRuntimeHostSupport,
        issues: inout [ForgeRuntimeValidationIssue]
    ) {
        if manifest.modules.count > host.maximumModules {
            issues.append(.error(
                .moduleLimitExceeded,
                field: "modules",
                "Curated module count exceeds the host manifest limit."
            ))
        }

        var seen: Set<String> = []
        for (index, module) in manifest.modules.enumerated() {
            let field = "modules[\(index)]"
            if !Self.isValidIdentifier(module.id, maximumLength: 96) {
                issues.append(.error(
                    .invalidModuleID,
                    field: "\(field).id",
                    "Curated module ID is not a valid bounded identifier."
                ))
                continue
            }

            if !Self.isValidVersionToken(module.version) {
                issues.append(.error(
                    .invalidModuleVersion,
                    field: "\(field).version",
                    "Curated module version is not a valid bounded version token."
                ))
                continue
            }

            if !seen.insert(module.id).inserted {
                issues.append(.error(
                    .duplicateModule,
                    field: field,
                    "A curated module may be requested only once."
                ))
                continue
            }

            let supported = host.curatedModuleVersions[module.id]?.contains(module.version) == true
            guard supported else {
                switch module.requirement {
                case .required:
                    issues.append(.error(
                        .unsupportedRequiredModule,
                        field: field,
                        "Required curated module/version is not supported by this host."
                    ))
                case .optional:
                    issues.append(.warning(
                        .unsupportedOptionalModule,
                        field: field,
                        "Optional curated module/version will not be loaded."
                    ))
                }
                continue
            }
        }
    }

    private static func isValidIdentifier(_ value: String, maximumLength: Int) -> Bool {
        guard !value.isEmpty, value.utf8.count <= maximumLength else { return false }
        let scalars = Array(value.unicodeScalars)
        guard let first = scalars.first, isASCIIAlphaNumeric(first) else { return false }
        return scalars.allSatisfy { scalar in
            isASCIIAlphaNumeric(scalar) || scalar == "-" || scalar == "_" || scalar == "."
        }
    }

    private static func isValidCapabilityID(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 64 else { return false }
        let scalars = Array(value.unicodeScalars)
        guard let first = scalars.first, isASCIILowercaseLetter(first) else { return false }
        return scalars.allSatisfy { scalar in
            isASCIILowercaseLetter(scalar) || isASCIIDigit(scalar) || scalar == "-" || scalar == "."
        }
    }

    private static func isValidVersionToken(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 64 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            isASCIIAlphaNumeric(scalar) || scalar == "." || scalar == "-" || scalar == "_" || scalar == "+"
        }
    }

    private static func isValidSandboxRelativePath(_ value: String) -> Bool {
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

    private static func pathExtension(of value: String) -> String {
        guard let last = value.split(separator: "/").last,
              let dot = last.lastIndex(of: "."),
              dot < last.index(before: last.endIndex) else {
            return ""
        }
        return String(last[last.index(after: dot)...])
    }

    private static func isValidExactHost(_ value: String) -> Bool {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.utf8.count <= 253,
              !value.contains("://"),
              !value.contains("/"),
              !value.contains("@"),
              !value.contains(":"),
              !value.contains("*"),
              !value.hasPrefix("."),
              !value.hasSuffix(".") else {
            return false
        }

        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else { return false }
        return labels.allSatisfy { label in
            guard !label.isEmpty, label.utf8.count <= 63,
                  label.first != "-", label.last != "-" else {
                return false
            }
            return label.unicodeScalars.allSatisfy { scalar in
                isASCIIAlphaNumeric(scalar) || scalar == "-"
            }
        }
    }

    private static func isASCIIAlphaNumeric(_ scalar: Unicode.Scalar) -> Bool {
        isASCIIUppercaseLetter(scalar) || isASCIILowercaseLetter(scalar) || isASCIIDigit(scalar)
    }

    private static func isASCIIUppercaseLetter(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 65 && scalar.value <= 90
    }

    private static func isASCIILowercaseLetter(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 97 && scalar.value <= 122
    }

    private static func isASCIIDigit(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 48 && scalar.value <= 57
    }
}

private extension ForgeRuntimeValidationIssue {
    static func error(
        _ code: ForgeRuntimeValidationCode,
        field: String,
        _ detail: String
    ) -> Self {
        .init(severity: .error, code: code, field: field, detail: detail)
    }

    static func warning(
        _ code: ForgeRuntimeValidationCode,
        field: String,
        _ detail: String
    ) -> Self {
        .init(severity: .warning, code: code, field: field, detail: detail)
    }
}
