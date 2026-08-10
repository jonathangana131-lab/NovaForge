import Foundation
import Testing
@testable import ForgeEffortCore

@Test("Balanced is the durable default")
func balancedDefault() {
    let intent = ForgeEffortIntent()
    #expect(intent.schemaVersion == 1)
    #expect(intent.level == .balanced)
}

@Test("Intent round-trips without widening authority")
func intentRoundTrip() throws {
    let intent = ForgeEffortIntent(level: .ultra)
    let encoded = try JSONEncoder().encode(intent)
    let decoded = try JSONDecoder().decode(ForgeEffortIntent.self, from: encoded)
    #expect(decoded == intent)
}

@Test("Future intent schemas fail closed")
func futureSchemaRejected() throws {
    let data = Data(#"{"schemaVersion":2,"level":"ultra"}"#.utf8)
    #expect(throws: ForgeEffortIntentError.unsupportedSchemaVersion(2)) {
        try JSONDecoder().decode(ForgeEffortIntent.self, from: data)
    }
}

@Test("Unknown native support never fabricates provider reasoning")
func unavailableNativeSupportIsHostOnly() {
    for level in ForgeEffortLevel.allCases {
        let resolution = ForgeEffortResolver.resolve(.init(level: level))
        #expect(resolution.nativeReasoningEffort == nil)
        #expect(!resolution.usesNativeReasoning)
    }
}

@Test("Full explicit native support maps friendly effort truthfully")
func fullNativeSupportMapping() {
    let support = ForgeNativeReasoningSupport(ForgeNativeReasoningEffort.allCases)
    #expect(ForgeEffortResolver.resolve(.init(level: .fast), nativeSupport: support).nativeReasoningEffort == .low)
    #expect(ForgeEffortResolver.resolve(.init(level: .balanced), nativeSupport: support).nativeReasoningEffort == .medium)
    #expect(ForgeEffortResolver.resolve(.init(level: .deep), nativeSupport: support).nativeReasoningEffort == .high)
    #expect(ForgeEffortResolver.resolve(.init(level: .ultra), nativeSupport: support).nativeReasoningEffort == .max)
}

@Test("Ultra clamps down to the strongest explicitly supported native level")
func ultraClampsDown() {
    let highOnly = ForgeNativeReasoningSupport([.high])
    #expect(ForgeEffortResolver.resolve(.init(level: .ultra), nativeSupport: highOnly).nativeReasoningEffort == .high)

    let highAndXHigh = ForgeNativeReasoningSupport([.xhigh, .high])
    #expect(ForgeEffortResolver.resolve(.init(level: .ultra), nativeSupport: highAndXHigh).nativeReasoningEffort == .xhigh)
}

@Test("Resolver never upward-substitutes a stronger native effort")
func noUpwardSubstitution() {
    let support = ForgeNativeReasoningSupport([.high, .xhigh, .max])
    let balanced = ForgeEffortResolver.resolve(.init(level: .balanced), nativeSupport: support)
    #expect(balanced.nativeReasoningEffort == nil)
}

@Test("Native support is deterministic, deduplicated, and sorted")
func nativeSupportCanonicalization() {
    let support = ForgeNativeReasoningSupport([.max, .low, .high, .low, .medium])
    #expect(support.supportedEfforts == [.low, .medium, .high, .max])
}

@Test("Host work becomes monotonically stronger through Ultra")
func hostStrategyMonotonicity() {
    let strategies = ForgeEffortLevel.allCases.map(ForgeEffortResolver.hostStrategy)
    for pair in zip(strategies, strategies.dropFirst()) {
        #expect(pair.0.planningPasses <= pair.1.planningPasses)
        #expect(pair.0.reviewerPasses <= pair.1.reviewerPasses)
        #expect(pair.0.retrievalDepth <= pair.1.retrievalDepth)
        #expect(pair.0.verificationDepth <= pair.1.verificationDepth)
        #expect(pair.0.visualCritiquePasses <= pair.1.visualCritiquePasses)
        #expect(pair.0.repairLoopBudget <= pair.1.repairLoopBudget)
    }

    let ultra = ForgeEffortResolver.hostStrategy(for: .ultra)
    #expect(ultra.verificationDepth == .adversarial)
    #expect(ultra.retrievalDepth == .maximumRelevant)
    #expect(ultra.reviewerPasses > 0)
    #expect(ultra.repairLoopBudget > ForgeEffortResolver.hostStrategy(for: .deep).repairLoopBudget)
}

@Test("Host strategy does not weaken when native reasoning is available")
func nativeSupportDoesNotReplaceHostWork() {
    let intent = ForgeEffortIntent(level: .ultra)
    let hostOnly = ForgeEffortResolver.resolve(intent)
    let native = ForgeEffortResolver.resolve(
        intent,
        nativeSupport: ForgeNativeReasoningSupport([.max])
    )
    #expect(native.hostStrategy == hostOnly.hostStrategy)
    #expect(native.nativeReasoningEffort == .max)
}
