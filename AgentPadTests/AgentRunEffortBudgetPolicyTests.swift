import AgentDomain
import AgentProviders
import XCTest
@testable import NovaForge

final class AgentRunEffortBudgetPolicyTests: XCTestCase {
    func testMediumPreservesExactLegacyStandardBudget() {
        let budget = AgentRunEffortBudgetPolicy.budget(
            reasoningEffort: .medium,
            orchestrationMode: .standard
        )

        XCTAssertEqual(budget, AgentBudget(limits: .standard))
    }

    func testFiveComposerStopsIncreaseReducerEnforcedWorkBudget() {
        let low = budget(.low, .standard)
        let medium = budget(.medium, .standard)
        let high = budget(.high, .standard)
        let extraHigh = budget(.xhigh, .standard)
        let ultra = budget(.max, .ultraCode)

        XCTAssertEqual(
            [
                low.limits.iterations,
                medium.limits.iterations,
                high.limits.iterations,
                extraHigh.limits.iterations,
                ultra.limits.iterations,
            ],
            [8, 32, 48, 64, 128]
        )
        XCTAssertEqual(
            [
                low.limits.providerAttempts,
                medium.limits.providerAttempts,
                high.limits.providerAttempts,
                extraHigh.limits.providerAttempts,
                ultra.limits.providerAttempts,
            ],
            [12, 48, 72, 96, 192]
        )
        XCTAssertEqual(
            [
                low.limits.toolInvocations,
                medium.limits.toolInvocations,
                high.limits.toolInvocations,
                extraHigh.limits.toolInvocations,
                ultra.limits.toolInvocations,
            ],
            [24, 64, 96, 128, 256]
        )
    }

    func testUltraIsStrongestButRetainsConservativeGlobalSafetyLimits() {
        let ultra = budget(.max, .ultraCode)
        let standard = AgentBudgetLimits.standard

        XCTAssertEqual(ultra.limits.iterations, 128)
        XCTAssertEqual(ultra.limits.providerAttempts, 192)
        XCTAssertEqual(ultra.limits.toolInvocations, 256)
        XCTAssertEqual(ultra.limits.inputTokens, standard.inputTokens)
        XCTAssertEqual(ultra.limits.outputTokens, standard.outputTokens)
        XCTAssertEqual(
            ultra.limits.elapsedMilliseconds,
            standard.elapsedMilliseconds
        )
        XCTAssertEqual(ultra.limits.costMicrounits, standard.costMicrounits)
        XCTAssertEqual(ultra.limits.childRuns, standard.childRuns)
        XCTAssertEqual(ultra.limits.childDepth, standard.childDepth)
    }

    func testLegacyUltraMatchesExistingExtraHighMigration() {
        XCTAssertEqual(
            budget(.max, .ultra),
            budget(.xhigh, .standard)
        )
    }

    func testStandardMaxDoesNotSilentlyPromoteToUltra() {
        XCTAssertEqual(
            budget(.max, .standard),
            budget(.xhigh, .standard)
        )
        XCTAssertNotEqual(
            budget(.max, .standard),
            budget(.max, .ultraCode)
        )
    }

    func testNoneSharesLowQuickBudget() {
        XCTAssertEqual(
            budget(.none, .standard),
            budget(.low, .standard)
        )
    }

    private func budget(
        _ effort: ProviderReasoningEffort,
        _ mode: AgentOrchestrationMode
    ) -> AgentBudget {
        AgentRunEffortBudgetPolicy.budget(
            reasoningEffort: effort,
            orchestrationMode: mode
        )
    }
}
