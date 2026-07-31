import AgentDomain
import AgentProviders
import AgentTools
import Foundation

public struct CanaryToolContractFingerprint: Codable, Equatable, Sendable {
    public let identity: ToolIdentity
    public let contractSHA256: String

    public init(identity: ToolIdentity, contractSHA256: String) {
        self.identity = identity
        self.contractSHA256 = contractSHA256
    }
}

public enum DeveloperCanaryToolDenial: Codable, Equatable, Sendable {
    case effectful(ToolEffectClass)
    case nonCanonicalDescriptor
    case notFrozenForRun
}

public enum DeveloperCanaryToolDecision: Codable, Equatable, Sendable {
    case allowed
    case denied(DeveloperCanaryToolDenial)

    public var isAllowed: Bool {
        self == .allowed
    }
}

public enum DeveloperCanaryPolicyError: Error, Equatable, Sendable {
    case acceptedContextMissing(RunID)
    case duplicateTool(ToolIdentity)
    case toolDenied(ToolIdentity, DeveloperCanaryToolDenial)
    case runChanged(expected: RunID, actual: RunID)
    case routeChanged
    case featureSetChanged
}

/// Immutable per-run canary configuration. The route and accepted feature set
/// are frozen values, while tool decisions are constrained to exact canonical
/// read-only descriptors selected when the policy was created.
public struct FrozenDeveloperCanaryPolicy: Sendable {
    public let runID: RunID
    public let hostedTextCapability: HostedTextOnlyProviderCapability
    public let acceptedFeatures: AgentFeatureSet
    public let allowedToolIdentities: [ToolIdentity]
    public let allowedToolContracts: [CanaryToolContractFingerprint]
    public let configurationSHA256: String

    private let allowedDescriptors: [ToolIdentity: ToolDescriptor]

    init(
        runID: RunID,
        hostedTextCapability: HostedTextOnlyProviderCapability,
        acceptedFeatures: AgentFeatureSet,
        allowedDescriptors: [ToolIdentity: ToolDescriptor],
        allowedToolContracts: [CanaryToolContractFingerprint],
        configurationSHA256: String
    ) {
        self.runID = runID
        self.hostedTextCapability = hostedTextCapability
        self.acceptedFeatures = acceptedFeatures
        self.allowedDescriptors = allowedDescriptors
        allowedToolIdentities = allowedDescriptors.keys.sorted {
            if $0.name == $1.name { return $0.version < $1.version }
            return $0.name < $1.name
        }
        self.allowedToolContracts = allowedToolContracts
        self.configurationSHA256 = configurationSHA256
    }

    public func decision(
        for descriptor: ToolDescriptor
    ) -> DeveloperCanaryToolDecision {
        let baseline = DeveloperCanaryPolicy.decision(for: descriptor)
        guard baseline.isAllowed else { return baseline }
        guard let frozen = allowedDescriptors[descriptor.identity] else {
            return .denied(.notFrozenForRun)
        }
        guard frozen == descriptor else {
            return .denied(.nonCanonicalDescriptor)
        }
        return .allowed
    }

    /// Fail closed if a caller attempts to reuse this policy with different
    /// routing or feature inputs, or for another accepted run.
    public func validateFrozenInputs(
        runID: RunID,
        hostedTextCapability: HostedTextOnlyProviderCapability,
        features: AgentFeatureSet
    ) throws {
        guard runID == self.runID else {
            throw DeveloperCanaryPolicyError.runChanged(
                expected: self.runID,
                actual: runID
            )
        }
        guard hostedTextCapability == self.hostedTextCapability else {
            throw DeveloperCanaryPolicyError.routeChanged
        }
        guard features == acceptedFeatures else {
            throw DeveloperCanaryPolicyError.featureSetChanged
        }
    }
}

/// Developer-only policy construction. Nothing in this type activates a route
/// or dispatches a tool; it only freezes and evaluates a proposed canary shape.
public enum DeveloperCanaryPolicy {
    private static let canonicalReadOnlyDescriptors: [ToolIdentity: ToolDescriptor] = {
        let descriptors = SandboxToolCatalog.all
            .map(\.descriptor)
            .filter { $0.effectClass == .readOnlyLocal }
        return Dictionary(uniqueKeysWithValues: descriptors.map {
            ($0.identity, $0)
        })
    }()

    public static func decision(
        for descriptor: ToolDescriptor
    ) -> DeveloperCanaryToolDecision {
        guard descriptor.effectClass == .readOnlyLocal else {
            return .denied(.effectful(descriptor.effectClass))
        }
        guard descriptor.approvalClass == .none,
              descriptor.parallelSafety == .parallelRead,
              canonicalReadOnlyDescriptors[descriptor.identity] == descriptor
        else {
            return .denied(.nonCanonicalDescriptor)
        }
        return .allowed
    }

    public static func freeze(
        for attestation: DarkReplayAttestation,
        hostedTextCapability: HostedTextOnlyProviderCapability,
        tools: [ToolDescriptor]
    ) async throws -> FrozenDeveloperCanaryPolicy {
        let report = try await attestation.revalidatedReport()
        guard let context = report.state.context else {
            throw DeveloperCanaryPolicyError.acceptedContextMissing(report.runID)
        }

        var frozen: [ToolIdentity: ToolDescriptor] = [:]
        for descriptor in tools {
            let identity = descriptor.identity
            guard frozen[identity] == nil else {
                throw DeveloperCanaryPolicyError.duplicateTool(identity)
            }
            let toolDecision = decision(for: descriptor)
            guard toolDecision.isAllowed else {
                guard case let .denied(reason) = toolDecision else {
                    preconditionFailure("A non-allowed canary decision must be denied")
                }
                throw DeveloperCanaryPolicyError.toolDenied(identity, reason)
            }
            frozen[identity] = descriptor
        }

        let identities = frozen.keys.sorted {
            if $0.name == $1.name { return $0.version < $1.version }
            return $0.name < $1.name
        }
        let contractFingerprints = try identities.map { identity in
            guard let descriptor = frozen[identity] else {
                preconditionFailure("A frozen tool identity must retain its descriptor")
            }
            return CanaryToolContractFingerprint(
                identity: identity,
                contractSHA256: try CanonicalToolContract.sha256(descriptor)
            )
        }
        let digestMaterial = DeveloperCanaryDigestMaterial(
            runID: report.runID,
            acceptedLedgerSHA256: report.digests.ledgerSHA256,
            acceptedReportSHA256: attestation.acceptedReportSHA256,
            hostedTextRoute: hostedTextCapability.snapshot,
            acceptedFeatures: context.features,
            allowedToolContracts: contractFingerprints
        )
        return FrozenDeveloperCanaryPolicy(
            runID: report.runID,
            hostedTextCapability: hostedTextCapability,
            acceptedFeatures: context.features,
            allowedDescriptors: frozen,
            allowedToolContracts: contractFingerprints,
            configurationSHA256: try CanonicalShadowDigest.sha256(
                domain: .developerCanaryConfiguration,
                digestMaterial
            )
        )
    }
}

private struct DeveloperCanaryDigestMaterial: Codable {
    let runID: RunID
    let acceptedLedgerSHA256: String
    let acceptedReportSHA256: String
    let hostedTextRoute: HostedTextOnlyRouteSnapshot
    let acceptedFeatures: AgentFeatureSet
    let allowedToolContracts: [CanaryToolContractFingerprint]
}
