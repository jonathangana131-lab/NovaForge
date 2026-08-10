import AgentDomain
import AgentProviders

/// Derives the accepted AgentBudget from the existing Composer reasoning /
/// orchestration preference. This is intentionally not a second user-facing
/// effort authority: AgentRunPreferenceStore remains the source of user intent,
/// while this policy freezes that intent into the reducer-enforced run budget.
enum AgentRunEffortBudgetPolicy {
    /// Medium preserves the exact pre-Preview budget so the existing default
    /// does not silently become more expensive or less capable.
    static let medium = AgentBudget(limits: .standard)

    static func budget(
        reasoningEffort: ProviderReasoningEffort,
        orchestrationMode: AgentOrchestrationMode
    ) -> AgentBudget {
        switch orchestrationMode {
        case .ultraCode:
            return makeBudget(
                iterations: 128,
                providerAttempts: 192,
                toolInvocations: 256
            )
        case .ultra:
            // Legacy `.ultra` is migrated by AgentRunPreferenceStore to
            // `.standard + .xhigh`. Mirror that migration if an in-memory
            // legacy value reaches this pure policy before normalization.
            return makeBudget(
                iterations: 64,
                providerAttempts: 96,
                toolInvocations: 128
            )
        case .standard:
            switch reasoningEffort {
            case .none, .low:
                return makeBudget(
                    iterations: 8,
                    providerAttempts: 12,
                    toolInvocations: 24
                )
            case .medium:
                return medium
            case .high:
                return makeBudget(
                    iterations: 48,
                    providerAttempts: 72,
                    toolInvocations: 96
                )
            case .xhigh, .max:
                // The current five-stop Composer treats `.max` in standard
                // orchestration as Extra High. Only `.ultraCode` is the top
                // orchestration stop, so a stale `.standard + .max` record
                // must not silently promote itself to Ultra.
                return makeBudget(
                    iterations: 64,
                    providerAttempts: 96,
                    toolInvocations: 128
                )
            }
        }
    }

    private static func makeBudget(
        iterations: UInt64,
        providerAttempts: UInt64,
        toolInvocations: UInt64
    ) -> AgentBudget {
        var limits = AgentBudgetLimits.standard
        limits.iterations = iterations
        limits.providerAttempts = providerAttempts
        limits.toolInvocations = toolInvocations
        return AgentBudget(limits: limits)
    }
}
