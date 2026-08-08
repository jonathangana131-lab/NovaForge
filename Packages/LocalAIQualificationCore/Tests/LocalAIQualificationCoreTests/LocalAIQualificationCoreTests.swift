import XCTest
@testable import LocalAIQualificationCore

final class LocalAIQualificationCoreTests: XCTestCase {
    private func model() throws -> LocalAIModelIdentity {
        try .init(
            modelID: "Qwen/Qwen3.5-4B",
            modelRevision: "model-sha",
            tokenizerID: "Qwen/Qwen3.5-4B",
            tokenizerRevision: "tokenizer-sha"
        )
    }

    private func runtime(
        kv: LocalAIKVCacheType = .q8,
        loading: LocalAIWeightLoadingMode = .memoryMapped
    ) throws -> LocalAIRuntimeProfile {
        try .init(
            runtimeID: "llama.cpp",
            runtimeRevision: "runtime-sha",
            backend: .metal,
            quantization: "Q4_K_M",
            kvCacheType: kv,
            contextTokens: 4_096,
            weightLoadingMode: loading
        )
    }

    private func device(_ environment: LocalAIEvidenceEnvironment = .physicalDevice) throws -> LocalAIDeviceIdentity {
        try .init(
            hardwareIdentifier: "iPhone13,2",
            chipIdentifier: "A14",
            osName: "iOS",
            osVersion: "27.0",
            environment: environment
        )
    }

    private func profile(
        environment: LocalAIEvidenceEnvironment = .physicalDevice,
        loading: LocalAIWeightLoadingMode = .memoryMapped
    ) throws -> LocalAIExactProfile {
        .init(model: try model(), runtime: try runtime(loading: loading), device: try device(environment))
    }

    private func measurements(
        memoryPressure: LocalAIMemoryPressureOutcome = .none,
        thermalEnd: LocalAIThermalState = .fair
    ) throws -> LocalAIMeasurements {
        try .init(
            coldLoadMilliseconds: 1_200,
            timeToFirstTokenMilliseconds: 480,
            prefillTokensPerSecond: 80,
            decodeTokensPerSecond: 18,
            peakResidentMemoryBytes: 2_100_000_000,
            observedContextTokens: 2_048,
            memoryPressure: memoryPressure,
            thermalStart: .nominal,
            thermalEnd: thermalEnd,
            energyJoules: 15
        )
    }

    private func suite(_ outcome: LocalAITaskOutcome = .passed) throws -> LocalAITaskSuiteReceipt {
        try .init(
            suiteID: "novaforge-local-agent",
            suiteRevision: "suite-1",
            results: [
                try .init(taskID: "structured-tool-call", outcome: outcome),
                try .init(taskID: "multi-file-edit", outcome: .passed),
                try .init(taskID: "repair-loop", outcome: .passed),
            ]
        )
    }

    private func standard(
        suiteID: String = "novaforge-local-agent",
        suiteRevision: String = "suite-1",
        requiredTaskIDs: [String] = ["structured-tool-call", "multi-file-edit", "repair-loop"]
    ) throws -> LocalAIQualificationStandard {
        try .init(
            standardID: "novaforge-iphone-local-agent",
            standardRevision: "standard-1",
            taskSuiteID: suiteID,
            taskSuiteRevision: suiteRevision,
            requiredTaskIDs: requiredTaskIDs
        )
    }

    private func receipt(
        profile: LocalAIExactProfile? = nil,
        revision: Int = 1,
        memoryPressure: LocalAIMemoryPressureOutcome = .none,
        thermalEnd: LocalAIThermalState = .fair,
        taskOutcome: LocalAITaskOutcome = .passed,
        locality: LocalAILocalityPolicy = .localOnly,
        audit: LocalAINetworkAudit = .noExternalAccessObserved
    ) throws -> LocalAIQualificationReceipt {
        try .init(
            profile: profile ?? self.profile(),
            evidenceRevision: revision,
            measurements: measurements(memoryPressure: memoryPressure, thermalEnd: thermalEnd),
            taskSuite: suite(taskOutcome),
            localityPolicy: locality,
            networkAudit: audit
        )
    }

    func testPhysicalExactEvidenceCanQualify() throws {
        XCTAssertEqual(LocalAIQualificationEvaluator.badge(for: try receipt(), against: try standard()), .qualified)
    }

    func testSimulatorEvidenceCannotMintQualifiedBadge() throws {
        let simulatorProfile = try profile(environment: .simulator)
        XCTAssertEqual(
            LocalAIQualificationEvaluator.badge(for: try receipt(profile: simulatorProfile), against: try standard()),
            .experimental
        )
    }

    func testExperimentalBeyondRAMModeCannotMintQualifiedBadge() throws {
        let experimental = try profile(loading: .flashStreamingExperimental)
        XCTAssertEqual(
            LocalAIQualificationEvaluator.badge(for: try receipt(profile: experimental), against: try standard()),
            .experimental
        )
    }

    func testLocalOnlyExternalNetworkEvidenceFailsClosed() throws {
        XCTAssertEqual(
            LocalAIQualificationEvaluator.badge(for: try receipt(audit: .externalAccessObserved), against: try standard()),
            .unsupported
        )
    }

    func testUnmeasuredNetworkAuditCannotQualify() throws {
        XCTAssertEqual(
            LocalAIQualificationEvaluator.badge(for: try receipt(audit: .notMeasured), against: try standard()),
            .experimental
        )
    }

    func testFailedTaskOrCriticalResourceEvidenceIsUnsupported() throws {
        XCTAssertEqual(
            LocalAIQualificationEvaluator.badge(for: try receipt(taskOutcome: .failed), against: try standard()),
            .unsupported
        )
        XCTAssertEqual(
            LocalAIQualificationEvaluator.badge(for: try receipt(memoryPressure: .critical), against: try standard()),
            .unsupported
        )
        XCTAssertEqual(
            LocalAIQualificationEvaluator.badge(for: try receipt(thermalEnd: .critical), against: try standard()),
            .unsupported
        )
    }

    func testArbitraryOrStaleTaskSuiteCannotMintQualifiedBadge() throws {
        let exactReceipt = try receipt()
        XCTAssertEqual(
            LocalAIQualificationEvaluator.badge(
                for: exactReceipt,
                against: try standard(suiteRevision: "suite-2")
            ),
            .unverified
        )

        XCTAssertEqual(
            LocalAIQualificationEvaluator.badge(
                for: exactReceipt,
                against: try standard(requiredTaskIDs: ["structured-tool-call", "security-audit"])
            ),
            .unverified
        )
    }

    func testQualificationStandardRejectsDuplicateRequiredTaskIdentity() throws {
        XCTAssertThrowsError(
            try standard(requiredTaskIDs: ["same", "same"])
        )
    }

    func testReceiptRejectsObservedContextBeyondExactRuntimeProfile() throws {
        let badMeasurements = try LocalAIMeasurements(
            coldLoadMilliseconds: 1,
            timeToFirstTokenMilliseconds: 1,
            prefillTokensPerSecond: 1,
            decodeTokensPerSecond: 1,
            peakResidentMemoryBytes: 1,
            observedContextTokens: 8_192,
            memoryPressure: .none,
            thermalStart: .nominal,
            thermalEnd: .nominal,
            energyJoules: nil
        )
        XCTAssertThrowsError(
            try LocalAIQualificationReceipt(
                profile: profile(),
                evidenceRevision: 1,
                measurements: badMeasurements,
                taskSuite: suite(),
                localityPolicy: .localOnly,
                networkAudit: .noExternalAccessObserved
            )
        )
    }

    func testTaskSuiteRejectsDuplicateTaskIdentity() throws {
        XCTAssertThrowsError(
            try LocalAITaskSuiteReceipt(
                suiteID: "suite",
                suiteRevision: "r1",
                results: [
                    try .init(taskID: "same", outcome: .passed),
                    try .init(taskID: "same", outcome: .failed),
                ]
            )
        )
    }

    func testArchiveRequiresExactProfileAndMonotonicEvidenceRevision() throws {
        let exact = try profile()
        let first = try receipt(profile: exact, revision: 1)
        let second = try receipt(profile: exact, revision: 2)
        XCTAssertEqual(try LocalAIQualificationArchive(profile: exact, receipts: [first, second]).badge(against: standard()), .qualified)

        XCTAssertThrowsError(try LocalAIQualificationArchive(profile: exact, receipts: [second, first]))

        let other = LocalAIExactProfile(
            model: try model(),
            runtime: try runtime(kv: .q4),
            device: try device()
        )
        XCTAssertThrowsError(
            try LocalAIQualificationArchive(
                profile: exact,
                receipts: [try receipt(profile: other, revision: 1)]
            )
        )
    }

    func testArchiveRoundTripIsDeterministicAndRejectsUnknownSchema() throws {
        let exact = try profile()
        let archive = try LocalAIQualificationArchive(
            profile: exact,
            receipts: [try receipt(profile: exact, revision: 1)]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let first = try encoder.encode(archive)
        let decoded = try JSONDecoder().decode(LocalAIQualificationArchive.self, from: first)
        XCTAssertEqual(decoded, archive)
        XCTAssertEqual(try encoder.encode(decoded), first)

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: first) as? [String: Any])
        var mutated = object
        mutated["schemaVersion"] = 99
        let badData = try JSONSerialization.data(withJSONObject: mutated, options: [.sortedKeys])
        XCTAssertThrowsError(try JSONDecoder().decode(LocalAIQualificationArchive.self, from: badData))
    }

    func testRuntimeRejectsBlankCustomKVIdentity() throws {
        XCTAssertThrowsError(
            try LocalAIRuntimeProfile(
                runtimeID: "llama.cpp",
                runtimeRevision: "runtime-sha",
                backend: .metal,
                quantization: "Q4_K_M",
                kvCacheType: .custom("   "),
                contextTokens: 4_096,
                weightLoadingMode: .resident
            )
        )
    }

    func testMeasurementsRejectNonFiniteOrZeroPerformanceEvidence() throws {
        XCTAssertThrowsError(
            try LocalAIMeasurements(
                coldLoadMilliseconds: .infinity,
                timeToFirstTokenMilliseconds: 1,
                prefillTokensPerSecond: 1,
                decodeTokensPerSecond: 1,
                peakResidentMemoryBytes: 1,
                observedContextTokens: 1,
                memoryPressure: .none,
                thermalStart: .nominal,
                thermalEnd: .nominal,
                energyJoules: nil
            )
        )
        XCTAssertThrowsError(
            try LocalAIMeasurements(
                coldLoadMilliseconds: 1,
                timeToFirstTokenMilliseconds: 1,
                prefillTokensPerSecond: 1,
                decodeTokensPerSecond: 0,
                peakResidentMemoryBytes: 1,
                observedContextTokens: 1,
                memoryPressure: .none,
                thermalStart: .nominal,
                thermalEnd: .nominal,
                energyJoules: nil
            )
        )
    }

    func testDecodeRevalidatesNestedIdentifiersAndMetrics() throws {
        let exact = try profile()
        let archive = try LocalAIQualificationArchive(
            profile: exact,
            receipts: [try receipt(profile: exact, revision: 1)]
        )
        let data = try JSONEncoder().encode(archive)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var profileObject = try XCTUnwrap(object["profile"] as? [String: Any])
        var runtimeObject = try XCTUnwrap(profileObject["runtime"] as? [String: Any])
        runtimeObject["contextTokens"] = 0
        profileObject["runtime"] = runtimeObject
        object["profile"] = profileObject
        let corrupted = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(LocalAIQualificationArchive.self, from: corrupted))
    }
}
