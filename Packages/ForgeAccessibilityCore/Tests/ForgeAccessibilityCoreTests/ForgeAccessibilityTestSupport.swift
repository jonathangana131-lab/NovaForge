import XCTest
@testable import ForgeAccessibilityCore

class ForgeAccessibilityTestCase: XCTestCase {
    func target(
        projectID: String = "project-1",
        sourceRevision: String = "source-abc",
        checkpointID: String = "checkpoint-7",
        runtimeVersion: String = "forge-runtime-1"
    ) throws -> ForgeAccessibilityTarget {
        try ForgeAccessibilityTarget(
            projectID: projectID,
            sourceRevision: sourceRevision,
            checkpointID: checkpointID,
            runtimeVersion: runtimeVersion
        )
    }

    func environment(
        assistiveTechnology: ForgeAccessibilityAssistiveTechnology = .none,
        contentSize: ForgeAccessibilityContentSize = .large,
        reduceMotion: Bool = false,
        reduceTransparency: Bool = false,
        increasedContrast: Bool = false
    ) -> ForgeAccessibilityEnvironment {
        ForgeAccessibilityEnvironment(
            orientation: .portrait,
            assistiveTechnology: assistiveTechnology,
            contentSize: contentSize,
            reduceMotion: reduceMotion,
            reduceTransparency: reduceTransparency,
            increasedContrast: increasedContrast
        )
    }

    func baselineScenarios() throws -> [ForgeAccessibilityScenario] {
        [
            try ForgeAccessibilityScenario(
                id: "baseline-touch",
                environment: environment(),
                requiredChecks: [.touchTargetGeometry]
            ),
            try ForgeAccessibilityScenario(
                id: "voiceover",
                environment: environment(assistiveTechnology: .voiceOver),
                requiredChecks: [.voiceOverReachability, .semanticNameRoleValue, .focusOrder]
            ),
            try ForgeAccessibilityScenario(
                id: "dynamic-type",
                environment: environment(contentSize: .accessibilityExtraExtraExtraLarge),
                requiredChecks: [.dynamicTypeLayout]
            ),
            try ForgeAccessibilityScenario(
                id: "reduce-motion",
                environment: environment(reduceMotion: true),
                requiredChecks: [.reduceMotionBehavior]
            ),
            try ForgeAccessibilityScenario(
                id: "reduce-transparency",
                environment: environment(reduceTransparency: true),
                requiredChecks: [.reduceTransparencyFallback]
            ),
            try ForgeAccessibilityScenario(
                id: "increased-contrast",
                environment: environment(increasedContrast: true),
                requiredChecks: [.contrast]
            ),
        ]
    }

    func policy() throws -> ForgeAccessibilityPolicy {
        try ForgeAccessibilityPolicy(target: target(), scenarios: baselineScenarios())
    }

    func passed(_ kind: ForgeAccessibilityCheckKind) throws -> ForgeAccessibilityCheckResult {
        try ForgeAccessibilityCheckResult(
            kind: kind,
            outcome: .passed,
            inspectedElementCount: 12,
            failureCount: 0
        )
    }

    func run(
        for scenario: ForgeAccessibilityScenario,
        target: ForgeAccessibilityTarget? = nil,
        receiptID: String? = nil,
        checkResults: [ForgeAccessibilityCheckResult]? = nil
    ) throws -> ForgeAccessibilityRunEvidence {
        try ForgeAccessibilityRunEvidence(
            runID: "run-\(scenario.id)",
            target: target ?? self.target(),
            scenarioID: scenario.id,
            authority: .hostRuntimeHarness,
            producerReceiptID: receiptID ?? "receipt-\(scenario.id)",
            checkResults: checkResults ?? scenario.requiredChecks.map { try passed($0) }
        )
    }

    func allPassingRuns(policy: ForgeAccessibilityPolicy) throws -> [ForgeAccessibilityRunEvidence] {
        try policy.scenarios.map { try run(for: $0, target: policy.target) }
    }

    func trust(_ run: ForgeAccessibilityRunEvidence) throws -> ForgeAccessibilityTrustedProducerReceipt {
        ForgeAccessibilityTrustedProducerReceipt(authenticatedRun: run)
    }

    func trusts(_ runs: [ForgeAccessibilityRunEvidence]) throws -> [ForgeAccessibilityTrustedProducerReceipt] {
        try runs.map { try trust($0) }
    }

}
