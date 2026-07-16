import AgentDomain
import AgentProviders
import AgentTools
import Foundation

public enum DeveloperReadOnlyCanaryPolicyError: Error, Equatable, Sendable {
    case acceptedContextMissing(RunID)
    case emptyToolSet
    case toolDefinitionLimitExceeded(maximum: UInt32, actual: UInt32)
    case duplicateTool(ToolIdentity)
    case toolDenied(ToolIdentity, DeveloperCanaryToolDenial)
    case runChanged(expected: RunID, actual: RunID)
    case routeChanged
    case featureSetChanged
}

/// Immutable authority for one accepted run, one package-minted hosted route,
/// and one exact set of canonical read-only tool contracts. It contains no
/// backend and cannot authorize a write-capable executor.
public struct FrozenDeveloperReadOnlyCanaryPolicy: Sendable {
    public let runID: RunID
    public let hostedReadOnlyToolsCapability: HostedReadOnlyToolsProviderCapability
    public let acceptedFeatures: AgentFeatureSet
    public let allowedToolIdentities: [ToolIdentity]
    public let allowedToolContracts: [CanaryToolContractFingerprint]
    public let configurationSHA256: String

    private let allowedDescriptors: [ToolIdentity: ToolDescriptor]

    init(
        runID: RunID,
        hostedReadOnlyToolsCapability: HostedReadOnlyToolsProviderCapability,
        acceptedFeatures: AgentFeatureSet,
        allowedDescriptors: [ToolIdentity: ToolDescriptor],
        allowedToolContracts: [CanaryToolContractFingerprint],
        configurationSHA256: String
    ) {
        self.runID = runID
        self.hostedReadOnlyToolsCapability = hostedReadOnlyToolsCapability
        self.acceptedFeatures = acceptedFeatures
        self.allowedDescriptors = allowedDescriptors
        allowedToolIdentities = allowedDescriptors.keys.sorted(by: Self.identityOrder)
        self.allowedToolContracts = allowedToolContracts
        self.configurationSHA256 = configurationSHA256
    }

    public func decision(for descriptor: ToolDescriptor) -> DeveloperCanaryToolDecision {
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

    public func validateFrozenInputs(
        runID: RunID,
        hostedReadOnlyToolsCapability: HostedReadOnlyToolsProviderCapability,
        features: AgentFeatureSet
    ) throws {
        guard runID == self.runID else {
            throw DeveloperReadOnlyCanaryPolicyError.runChanged(
                expected: self.runID,
                actual: runID
            )
        }
        guard hostedReadOnlyToolsCapability == self.hostedReadOnlyToolsCapability else {
            throw DeveloperReadOnlyCanaryPolicyError.routeChanged
        }
        guard features == acceptedFeatures else {
            throw DeveloperReadOnlyCanaryPolicyError.featureSetChanged
        }
    }

    func descriptor(for identity: ToolIdentity) -> ToolDescriptor? {
        allowedDescriptors[identity]
    }

    func contractFingerprint(for identity: ToolIdentity) -> CanaryToolContractFingerprint? {
        allowedToolContracts.first { $0.identity == identity }
    }

    private static func identityOrder(_ lhs: ToolIdentity, _ rhs: ToolIdentity) -> Bool {
        if lhs.name == rhs.name { return lhs.version < rhs.version }
        return lhs.name < rhs.name
    }
}

/// Construction boundary for the hosted read-tool canary. The text-only
/// policy remains unchanged and cannot be widened by this API.
public enum DeveloperReadOnlyCanaryPolicy {
    public static func freeze(
        for attestation: DarkReplayAttestation,
        hostedReadOnlyToolsCapability: HostedReadOnlyToolsProviderCapability,
        tools: [ToolDescriptor]
    ) async throws -> FrozenDeveloperReadOnlyCanaryPolicy {
        let report = try await attestation.revalidatedReport()
        guard let context = report.state.context else {
            throw DeveloperReadOnlyCanaryPolicyError.acceptedContextMissing(report.runID)
        }
        guard !tools.isEmpty else {
            throw DeveloperReadOnlyCanaryPolicyError.emptyToolSet
        }
        let actualCount = UInt32(clamping: tools.count)
        let maximum = hostedReadOnlyToolsCapability.snapshot.maximumToolDefinitions
        guard actualCount <= maximum else {
            throw DeveloperReadOnlyCanaryPolicyError.toolDefinitionLimitExceeded(
                maximum: maximum,
                actual: actualCount
            )
        }

        var frozen: [ToolIdentity: ToolDescriptor] = [:]
        for descriptor in tools {
            let identity = descriptor.identity
            guard frozen[identity] == nil else {
                throw DeveloperReadOnlyCanaryPolicyError.duplicateTool(identity)
            }
            let decision = DeveloperCanaryPolicy.decision(for: descriptor)
            guard decision.isAllowed else {
                guard case let .denied(reason) = decision else {
                    preconditionFailure("A non-allowed canary decision must be denied")
                }
                throw DeveloperReadOnlyCanaryPolicyError.toolDenied(identity, reason)
            }
            frozen[identity] = descriptor
        }

        let identities = frozen.keys.sorted {
            if $0.name == $1.name { return $0.version < $1.version }
            return $0.name < $1.name
        }
        let fingerprints = try identities.map { identity in
            guard let descriptor = frozen[identity] else {
                preconditionFailure("A frozen identity must retain its descriptor")
            }
            return CanaryToolContractFingerprint(
                identity: identity,
                contractSHA256: try CanonicalToolContract.sha256(descriptor)
            )
        }
        let digestMaterial = DeveloperReadOnlyCanaryDigestMaterial(
            runID: report.runID,
            acceptedLedgerSHA256: report.digests.ledgerSHA256,
            acceptedReportSHA256: attestation.acceptedReportSHA256,
            hostedReadOnlyToolsRoute: hostedReadOnlyToolsCapability.snapshot,
            acceptedFeatures: context.features,
            allowedToolContracts: fingerprints
        )
        return FrozenDeveloperReadOnlyCanaryPolicy(
            runID: report.runID,
            hostedReadOnlyToolsCapability: hostedReadOnlyToolsCapability,
            acceptedFeatures: context.features,
            allowedDescriptors: frozen,
            allowedToolContracts: fingerprints,
            configurationSHA256: try CanonicalShadowDigest.sha256(
                domain: .developerReadOnlyCanaryConfiguration,
                digestMaterial
            )
        )
    }
}

private struct DeveloperReadOnlyCanaryDigestMaterial: Codable {
    let runID: RunID
    let acceptedLedgerSHA256: String
    let acceptedReportSHA256: String
    let hostedReadOnlyToolsRoute: HostedReadOnlyToolsRouteSnapshot
    let acceptedFeatures: AgentFeatureSet
    let allowedToolContracts: [CanaryToolContractFingerprint]
}
