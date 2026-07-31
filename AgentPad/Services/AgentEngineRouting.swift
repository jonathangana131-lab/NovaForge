import Foundation

/// Stable engine identity captured by the harness acceptance contract. V1
/// records predate a persisted sidecar, so they are inferred as `.v1`; V2 will
/// persist this exact value atomically with its canonical acceptance event.
enum AgentEngineVersion: String, Codable, CaseIterable, Sendable {
    case v1
    case v2
}

enum AgentHarnessFeature: String, Codable, CaseIterable, Hashable, Sendable {
    case v2DarkReplay
    case v2HostedText
    case v2ReadTools
    case v2MutationTools
    case v2Local
    case v2Worker
    case v2MemorySkills
    case v2Subagents
    case v2MCP
    case v2Automation
}

enum AgentExecutionNodeClass: String, Codable, Sendable {
    case onDevice
    case pairedWorker
}

struct AgentRunRoutingMetadata: Codable, Equatable, Sendable {
    let engineVersion: AgentEngineVersion
    let enabledFeatures: [AgentHarnessFeature]
    let executionNode: AgentExecutionNodeClass
    let shadowMode: Bool

    init(
        engineVersion: AgentEngineVersion,
        enabledFeatures: [AgentHarnessFeature],
        executionNode: AgentExecutionNodeClass,
        shadowMode: Bool
    ) {
        self.engineVersion = engineVersion
        self.enabledFeatures = Array(Set(enabledFeatures)).sorted { $0.rawValue < $1.rawValue }
        self.executionNode = executionNode
        self.shadowMode = shadowMode
    }

    static let v1 = AgentRunRoutingMetadata(
        engineVersion: .v1,
        enabledFeatures: [],
        executionNode: .onDevice,
        shadowMode: false
    )
}

/// Feature routing is deliberately inert until an acceptance transaction has
/// a V2 sidecar/event store. Individual flags cannot activate V2 without the
/// master gate, and production V1 does not call this policy yet.
enum AgentEngineRoutingPolicy {
    static let masterV2Key = "NovaForge.AgentHarnessV2.enabled"

    /// M5 exposes two deliberately tiny DEBUG-only, on-device routes. The
    /// hosted-text route has no tool authority. The read-tools route adds only
    /// the frozen twelve-tool inspection catalog after the same dark replay.
    /// Every other feature combination remains V1.
    private static let hostedTextCanaryFeatures: Set<AgentHarnessFeature> = [
        .v2DarkReplay,
        .v2HostedText,
    ]
    private static let hostedReadToolsCanaryFeatures: Set<AgentHarnessFeature> = [
        .v2DarkReplay,
        .v2HostedText,
        .v2ReadTools,
    ]

    static func requestedRoute(
        defaults: UserDefaults = .standard,
        executionNode: AgentExecutionNodeClass = .onDevice
    ) -> AgentRunRoutingMetadata {
        #if DEBUG
        guard defaults.bool(forKey: masterV2Key) else { return .v1 }

        let features = AgentHarnessFeature.allCases.filter {
            defaults.bool(forKey: storageKey(for: $0))
        }
        let requested = Set(features)
        guard executionNode == .onDevice,
              requested == hostedTextCanaryFeatures ||
                requested == hostedReadToolsCanaryFeatures else { return .v1 }

        return AgentRunRoutingMetadata(
            engineVersion: .v2,
            enabledFeatures: features,
            executionNode: executionNode,
            shadowMode: true
        )
        #else
        return .v1
        #endif
    }

    static func storageKey(for feature: AgentHarnessFeature) -> String {
        "NovaForge.AgentHarnessV2.feature.\(feature.rawValue)"
    }
}

extension AgentRunRecord {
    /// Every record in `NovaForgeSchemaV1` was accepted by V1. This computed
    /// compatibility metadata changes no stored schema shape and prevents an
    /// old run from being reinterpreted when V2 flags change later.
    var acceptedRoutingMetadata: AgentRunRoutingMetadata { .v1 }
}
