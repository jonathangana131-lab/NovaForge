import XCTest
@testable import AgentDomain

final class LocalModelRuntimeQualificationTests: XCTestCase {
    private let artifactSHA256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

    func testExactRuntimeQualificationPreservesMeasuredLabel() {
        let decision = LocalModelRuntimeQualificationGate.evaluate(
            compatibility: measuredCompatibility(.excellent),
            expectedIdentity: identity(),
            receipt: receipt(),
            requiresPassedLocalOnlyNetworkAudit: true
        )

        XCTAssertEqual(decision.effectiveLabel, .excellent)
        XCTAssertTrue(decision.canPresentMeasuredPerformanceLabel)
        XCTAssertEqual(decision.reasons, [])
    }

    func testRuntimeRevisionMismatchDemotesMeasuredLabel() {
        assertIdentityMismatch(identity(runtimeRevision: "llama.cpp-other"))
    }

    func testTokenizerRevisionMismatchDemotesMeasuredLabel() {
        assertIdentityMismatch(identity(tokenizerRevision: "tokenizer-other"))
    }

    func testPromptTemplateRevisionMismatchDemotesMeasuredLabel() {
        assertIdentityMismatch(identity(promptTemplateRevision: "template-other"))
    }

    func testQuantizationMismatchDemotesMeasuredLabel() {
        assertIdentityMismatch(identity(quantization: "Q5_K_M"))
    }

    func testBackendMismatchDemotesMeasuredLabel() {
        assertIdentityMismatch(identity(backendID: "cpu"))
    }

    func testKVCacheTypeMismatchDemotesMeasuredLabel() {
        assertIdentityMismatch(identity(kvCacheValueType: "q4_0"))
    }

    func testContextMismatchDemotesMeasuredLabel() {
        assertIdentityMismatch(identity(contextTokens: 8_192))
    }

    func testExactDeviceModelStillMattersInsideSamePolicyProfile() {
        assertIdentityMismatch(identity(deviceModelIdentifier: "iPhone14,5"))
    }

    func testOSBuildMismatchDemotesMeasuredLabel() {
        assertIdentityMismatch(identity(osBuild: "24A999"))
    }

    func testInvalidMetricsCannotPromoteMeasuredLabel() {
        let invalidMetrics = metrics(decodeTokensPerSecond: .nan)
        let decision = LocalModelRuntimeQualificationGate.evaluate(
            compatibility: measuredCompatibility(.good),
            expectedIdentity: identity(),
            receipt: receipt(metrics: invalidMetrics)
        )

        XCTAssertEqual(decision.effectiveLabel, .untested)
        XCTAssertFalse(decision.canPresentMeasuredPerformanceLabel)
        XCTAssertEqual(decision.reasons, [.qualificationInvalid])
        XCTAssertTrue(receipt(metrics: invalidMetrics).validationIssues.contains(.invalidMetrics))
    }

    func testInvalidTaskSuiteCannotPromoteMeasuredLabel() {
        let invalidSuite = taskSuite(totalTasks: 4, passedTasks: 3, failedTasks: 0)
        let decision = LocalModelRuntimeQualificationGate.evaluate(
            compatibility: measuredCompatibility(.slow),
            expectedIdentity: identity(),
            receipt: receipt(taskSuite: invalidSuite)
        )

        XCTAssertEqual(decision.effectiveLabel, .untested)
        XCTAssertEqual(decision.reasons, [.qualificationInvalid])
        XCTAssertTrue(receipt(taskSuite: invalidSuite).validationIssues.contains(.invalidTaskSuite))
    }

    func testLocalOnlyAuditMustExplicitlyPassWhenRequired() {
        let missing = LocalModelRuntimeQualificationGate.evaluate(
            compatibility: measuredCompatibility(.good),
            expectedIdentity: identity(),
            receipt: receipt(networkAudit: .notRun),
            requiresPassedLocalOnlyNetworkAudit: true
        )
        XCTAssertEqual(missing.effectiveLabel, .untested)
        XCTAssertEqual(missing.reasons, [.localOnlyAuditMissing])

        let failed = LocalModelRuntimeQualificationGate.evaluate(
            compatibility: measuredCompatibility(.good),
            expectedIdentity: identity(),
            receipt: receipt(networkAudit: .failed),
            requiresPassedLocalOnlyNetworkAudit: true
        )
        XCTAssertEqual(failed.effectiveLabel, .untested)
        XCTAssertEqual(failed.reasons, [.localOnlyAuditFailed])
    }

    func testOlderReceiptSchemaFailsClosed() {
        let oldReceipt = receipt(schemaVersion: 0)
        let decision = LocalModelRuntimeQualificationGate.evaluate(
            compatibility: measuredCompatibility(.excellent),
            expectedIdentity: identity(),
            receipt: oldReceipt
        )

        XCTAssertEqual(decision.effectiveLabel, .untested)
        XCTAssertEqual(decision.reasons, [.qualificationInvalid])
        XCTAssertTrue(oldReceipt.validationIssues.contains(.unsupportedSchemaVersion))
    }

    func testNonPerformanceBlockerCannotBeElevatedByQualificationReceipt() {
        let blocked = LocalModelCompatibilityResult(
            label: .tooLarge,
            reasons: [.memoryBudgetExceeded],
            evidence: [.init(kind: .measured, code: "memory.measured_budget_exceeded", detail: "Measured peak memory exceeded budget.")]
        )

        let decision = LocalModelRuntimeQualificationGate.evaluate(
            compatibility: blocked,
            expectedIdentity: identity(),
            receipt: receipt()
        )

        XCTAssertEqual(decision.effectiveLabel, .tooLarge)
        XCTAssertFalse(decision.canPresentMeasuredPerformanceLabel)
        XCTAssertEqual(decision.reasons, [])
    }

    func testMeasuredLookingLabelWithoutMeasuredEvidenceFailsClosed() {
        let malformed = LocalModelCompatibilityResult(
            label: .excellent,
            reasons: [.measuredPerformance],
            evidence: [.init(kind: .inferred, code: "bad", detail: "Not actually measured.")]
        )

        let decision = LocalModelRuntimeQualificationGate.evaluate(
            compatibility: malformed,
            expectedIdentity: identity(),
            receipt: receipt()
        )

        XCTAssertEqual(decision.effectiveLabel, .untested)
        XCTAssertEqual(decision.reasons, [.measuredCompatibilityEvidenceMissing])
    }

    func testMeasuredMemoryAloneCannotMasqueradeAsMeasuredPerformance() {
        let malformed = LocalModelCompatibilityResult(
            label: .excellent,
            reasons: [.measuredPerformance],
            evidence: [.init(kind: .measured, code: "memory.peak_observed", detail: "Memory is measured, speed is not.")]
        )

        let decision = LocalModelRuntimeQualificationGate.evaluate(
            compatibility: malformed,
            expectedIdentity: identity(),
            receipt: receipt()
        )

        XCTAssertEqual(decision.effectiveLabel, .untested)
        XCTAssertEqual(decision.reasons, [.measuredCompatibilityEvidenceMissing])
    }

    func testQualificationReceiptCodableRoundTripPreservesExactIdentity() throws {
        let original = receipt()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LocalModelRuntimeQualificationReceipt.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.identity.runtimeRevision, "llama.cpp-r7777")
        XCTAssertEqual(decoded.identity.kvCacheKeyType, "q8_0")
        XCTAssertEqual(decoded.identity.kvCacheValueType, "q8_0")
        XCTAssertEqual(decoded.identity.contextTokens, 4_096)
        XCTAssertEqual(decoded.identity.deviceModelIdentifier, "iPhone13,2")
        XCTAssertEqual(decoded.identity.osBuild, "24A321")
    }

    private func assertIdentityMismatch(
        _ receiptIdentity: LocalModelRuntimeQualificationIdentity,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let decision = LocalModelRuntimeQualificationGate.evaluate(
            compatibility: measuredCompatibility(.excellent),
            expectedIdentity: identity(),
            receipt: receipt(identity: receiptIdentity)
        )

        XCTAssertEqual(decision.effectiveLabel, .untested, file: file, line: line)
        XCTAssertFalse(decision.canPresentMeasuredPerformanceLabel, file: file, line: line)
        XCTAssertEqual(decision.reasons, [.qualificationIdentityMismatch], file: file, line: line)
    }

    private func measuredCompatibility(
        _ label: LocalModelCompatibilityLabel
    ) -> LocalModelCompatibilityResult {
        LocalModelCompatibilityResult(
            label: label,
            reasons: [.measuredPerformance],
            evidence: [
                .init(
                    kind: .measured,
                    code: "benchmark.generation_rate",
                    detail: "Exact-device measured performance."
                )
            ]
        )
    }

    private func identity(
        runtimeRevision: String = "llama.cpp-r7777",
        tokenizerRevision: String = "tokenizer-r1",
        promptTemplateRevision: String = "template-r2",
        quantization: String = "Q4_K_M",
        backendID: String = "metal",
        kvCacheValueType: String = "q8_0",
        contextTokens: UInt64 = 4_096,
        deviceModelIdentifier: String = "iPhone13,2",
        osBuild: String = "24A321"
    ) -> LocalModelRuntimeQualificationIdentity {
        .init(
            modelID: "example/local-coder",
            modelRevision: "model-r1",
            artifactID: "q4-k-m",
            artifactSHA256: artifactSHA256,
            quantization: quantization,
            tokenizerID: "example-tokenizer",
            tokenizerRevision: tokenizerRevision,
            promptTemplateID: "chat-template",
            promptTemplateRevision: promptTemplateRevision,
            runtimeID: "llama.cpp",
            runtimeRevision: runtimeRevision,
            backendID: backendID,
            kvCacheKeyType: "q8_0",
            kvCacheValueType: kvCacheValueType,
            contextTokens: contextTokens,
            deviceProfileID: "iphone12-policy-v1",
            deviceModelIdentifier: deviceModelIdentifier,
            osVersion: "27.0",
            osBuild: osBuild
        )
    }

    private func metrics(
        decodeTokensPerSecond: Double = 7.5
    ) -> LocalModelRuntimeQualificationMetrics {
        .init(
            peakResidentMemoryBytes: 2_800_000_000,
            timeToFirstTokenMilliseconds: 950,
            prefillTokensPerSecond: 38,
            decodeTokensPerSecond: decodeTokensPerSecond,
            memoryPressureEvents: 0,
            thermalStart: .nominal,
            thermalEnd: .fair
        )
    }

    private func taskSuite(
        totalTasks: UInt16 = 4,
        passedTasks: UInt16 = 4,
        failedTasks: UInt16 = 0
    ) -> LocalModelQualificationTaskSuite {
        .init(
            suiteID: "novaforge-local-agent-smoke",
            suiteRevision: "suite-r3",
            totalTasks: totalTasks,
            passedTasks: passedTasks,
            failedTasks: failedTasks,
            toolCallAttempts: 6,
            validToolCalls: 6,
            structuredOutputAttempts: 3,
            validStructuredOutputs: 3,
            autonomousMissionAttempts: 1,
            successfulAutonomousMissions: 1
        )
    }

    private func receipt(
        schemaVersion: UInt16 = LocalModelRuntimeQualificationReceipt.currentSchemaVersion,
        identity: LocalModelRuntimeQualificationIdentity? = nil,
        metrics: LocalModelRuntimeQualificationMetrics? = nil,
        taskSuite: LocalModelQualificationTaskSuite? = nil,
        networkAudit: LocalModelQualificationNetworkAudit = .passed
    ) -> LocalModelRuntimeQualificationReceipt {
        .init(
            schemaVersion: schemaVersion,
            identity: identity ?? self.identity(),
            measuredAt: AgentInstant(rawValue: 1_786_196_800_000),
            metrics: metrics ?? self.metrics(),
            taskSuite: taskSuite ?? self.taskSuite(),
            localOnlyNetworkAudit: networkAudit
        )
    }
}
