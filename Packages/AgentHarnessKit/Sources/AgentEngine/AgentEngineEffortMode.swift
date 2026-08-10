import AgentProviders

/// User-facing NovaForge execution effort presets for the AgentEngine loop.
///
/// These values control NovaForge's own bounded model-round budget. They are
/// deliberately not provider-native reasoning levels: provider reasoning
/// effort must still be resolved from the exact provider/model capability.
/// Mission, autonomy, approval, resource, cancellation, and terminal-state
/// policies remain authoritative and may stop a run before this ceiling.
public enum AgentEngineEffortMode: String, Codable, CaseIterable, Sendable {
    case fast
    case balanced
    case deep
    case ultra

    /// Maximum model rounds available to one AgentEngine run under this
    /// preset. These are policy ceilings, not performance or completion claims.
    public var maximumModelRounds: UInt32 {
        switch self {
        case .fast:
            32
        case .balanced:
            128
        case .deep:
            256
        case .ultra:
            512
        }
    }
}

public extension AgentEngineConfiguration {
    /// Creates an engine configuration from a named NovaForge effort preset.
    ///
    /// `balanced` intentionally preserves the pre-preset default of 128 model
    /// rounds. Callers that need an exact custom ceiling can continue using the
    /// existing `maximumModelRounds:` initializer.
    init(
        recoveryPolicy: ProviderRecoveryPolicy = .hermesBaseline,
        effortMode: AgentEngineEffortMode
    ) {
        self.init(
            recoveryPolicy: recoveryPolicy,
            maximumModelRounds: effortMode.maximumModelRounds
        )
    }
}
