import Foundation

/// Host-owned launch constraints. Generated project code never constructs authority;
/// NovaForge supplies this context after applying product policy and any required approval.
public struct ForgeRuntimeAuthorizationContext: Equatable, Sendable {
    public var supportedCapabilities: Set<ForgeCapability>
    public var grantedCapabilities: Set<ForgeCapability>
    public var supportedOrientations: Set<ForgeOrientationPolicy>
    public var supportedViewportLayouts: Set<ForgeViewportPolicy.Layout>
    public var networkAccess: NetworkAccess

    public init(
        supportedCapabilities: Set<ForgeCapability> = [],
        grantedCapabilities: Set<ForgeCapability> = [],
        supportedOrientations: Set<ForgeOrientationPolicy> = [.portrait, .landscape, .auto],
        supportedViewportLayouts: Set<ForgeViewportPolicy.Layout> = [.safeArea],
        networkAccess: NetworkAccess = .offlineOnly
    ) {
        self.supportedCapabilities = supportedCapabilities
        self.grantedCapabilities = grantedCapabilities
        self.supportedOrientations = supportedOrientations
        self.supportedViewportLayouts = supportedViewportLayouts
        self.networkAccess = networkAccess
    }

    public enum NetworkAccess: Equatable, Sendable {
        case offlineOnly
        case allowlist(Set<String>)
    }
}

public enum ForgeRuntimeAuthorizationIssue: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidManifest([ForgeManifestIssue])
    case hostPolicyGrantsUnsupportedCapability(ForgeCapability)
    case unsupportedCapability(ForgeCapability)
    case capabilityNotGranted(ForgeCapability)
    case unsupportedOrientation(ForgeOrientationPolicy)
    case unsupportedViewportLayout(ForgeViewportPolicy.Layout)
    case networkAccessNotGranted(String)

    public var description: String {
        switch self {
        case let .invalidManifest(issues):
            return "Manifest validation failed with \(issues.count) issue(s)."
        case let .hostPolicyGrantsUnsupportedCapability(capability):
            return "Host policy grants unsupported capability: \(capability.rawValue)"
        case let .unsupportedCapability(capability):
            return "Host does not implement requested capability: \(capability.rawValue)"
        case let .capabilityNotGranted(capability):
            return "Requested capability has not been granted: \(capability.rawValue)"
        case let .unsupportedOrientation(orientation):
            return "Host cannot present requested orientation policy: \(orientation.rawValue)"
        case let .unsupportedViewportLayout(layout):
            return "Host cannot present requested viewport layout: \(layout.rawValue)"
        case let .networkAccessNotGranted(origin):
            return "Network origin has not been granted by host policy: \(origin)"
        }
    }
}

/// Immutable output consumed by a runtime host after validation and authorization.
/// It contains only authority explicitly requested by the project *and* granted by the host.
public struct ForgeRuntimeLaunchAuthorization: Equatable, Sendable {
    public let capabilities: Set<ForgeCapability>
    public let networkPolicy: ForgeNetworkPolicy
    public let orientation: ForgeOrientationPolicy
    public let viewport: ForgeViewportPolicy

    public init(
        capabilities: Set<ForgeCapability>,
        networkPolicy: ForgeNetworkPolicy,
        orientation: ForgeOrientationPolicy,
        viewport: ForgeViewportPolicy
    ) {
        self.capabilities = capabilities
        self.networkPolicy = networkPolicy
        self.orientation = orientation
        self.viewport = viewport
    }
}

public struct ForgeRuntimeLaunchAuthorizer: Sendable {
    public var validator: ForgeManifestValidator

    public init(validator: ForgeManifestValidator = .init()) {
        self.validator = validator
    }

    public func authorize(
        _ manifest: ForgeProjectManifest,
        context: ForgeRuntimeAuthorizationContext
    ) throws -> ForgeRuntimeLaunchAuthorization {
        do {
            try validator.validate(manifest)
        } catch let error as ForgeManifestValidationError {
            throw ForgeRuntimeAuthorizationIssue.invalidManifest(error.issues)
        }

        if let invalidGrant = context.grantedCapabilities
            .subtracting(context.supportedCapabilities)
            .sorted(by: { $0.rawValue < $1.rawValue })
            .first {
            throw ForgeRuntimeAuthorizationIssue.hostPolicyGrantsUnsupportedCapability(invalidGrant)
        }

        let requested = Set(manifest.runtime.requestedCapabilities)
        if let unsupported = requested
            .subtracting(context.supportedCapabilities)
            .sorted(by: { $0.rawValue < $1.rawValue })
            .first {
            throw ForgeRuntimeAuthorizationIssue.unsupportedCapability(unsupported)
        }

        if let denied = requested
            .subtracting(context.grantedCapabilities)
            .sorted(by: { $0.rawValue < $1.rawValue })
            .first {
            throw ForgeRuntimeAuthorizationIssue.capabilityNotGranted(denied)
        }

        guard context.supportedOrientations.contains(manifest.runtime.orientation) else {
            throw ForgeRuntimeAuthorizationIssue.unsupportedOrientation(manifest.runtime.orientation)
        }

        guard context.supportedViewportLayouts.contains(manifest.runtime.viewport.layout) else {
            throw ForgeRuntimeAuthorizationIssue.unsupportedViewportLayout(manifest.runtime.viewport.layout)
        }

        try authorizeNetwork(manifest.runtime.network, hostAccess: context.networkAccess)

        return ForgeRuntimeLaunchAuthorization(
            capabilities: requested,
            networkPolicy: manifest.runtime.network,
            orientation: manifest.runtime.orientation,
            viewport: manifest.runtime.viewport
        )
    }

    private func authorizeNetwork(
        _ projectPolicy: ForgeNetworkPolicy,
        hostAccess: ForgeRuntimeAuthorizationContext.NetworkAccess
    ) throws {
        switch projectPolicy.mode {
        case .offlineOnly:
            return
        case .allowlist:
            let hostOrigins: Set<String>
            switch hostAccess {
            case .offlineOnly:
                hostOrigins = []
            case let .allowlist(origins):
                hostOrigins = origins
            }

            for origin in projectPolicy.allowedOrigins.sorted() where !hostOrigins.contains(origin) {
                throw ForgeRuntimeAuthorizationIssue.networkAccessNotGranted(origin)
            }
        }
    }
}
