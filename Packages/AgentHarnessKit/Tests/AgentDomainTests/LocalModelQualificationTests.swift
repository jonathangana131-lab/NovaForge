import XCTest
@testable import AgentDomain

final class LocalModelQualificationTests: XCTestCase {
    private let artifactDigest = String(repeating: "a", count: 64)

    func testPhysicalDeviceObservationIsEligibleForMeasuredClassification() {
        let assessment = LocalModelQualificationValidator.evaluate(makeObservation())

        XCTAssertEqual(assessment.status, .eligibleForMeasuredClassification)
        XCTAssertTrue(assessment.issues.isEmpty)
        XCTAssertTrue(assessment.canDriveMeasuredCompatibility)
    }

    func testSimulatorObservationRemainsResearchOnly() {
        let assessment = LocalModelQualificationValidator.evaluate(
            makeObservation(identity: makeIdentity(environment: .simulator))
        )

        XCTAssertEqual(assessment.status, .researchOnly)
        XCTAssertEqual(assessment.issues, [.physicalDeviceEvidenceRequired])
        XCTAssertFalse(assessment.canDriveMeasuredCompatibility)
    }

    func testExecutionDetailsArePartOfExactIdentity() {
        let baseline = makeIdentity()

        XCTAssertNotEqual(baseline, makeIdentity(runtimeRevision: "runtime-rev-2"))
        XCTAssertNotEqual(baseline, makeIdentity(tokenizerRevision: "tokenizer-rev-2"))
        XCTAssertNotEqual(baseline, makeIdentity(kvCacheType: "q4_0"))
        XCTAssertNotEqual(baseline, makeIdentity(contextWindowTokens: 16_384))
        XCTAssertNotEqual(baseline, makeIdentity(deviceModelIdentifier: "iPhone14,5"))
        XCTAssertNotEqual(baseline, makeIdentity(operatingSystemVersion: "27.1"))
    }

    func testMalformedDigestAndZeroContextFailClosed() {
        let assessment = LocalModelQualificationValidator.evaluate(
            makeObservation(identity: makeIdentity(artifactSHA256: "invalid", contextWindowTokens: 0))
        )

        XCTAssertEqual(assessment.status, .invalid)
        XCTAssertEqual(assessment.issues, [.malformedArtifactSHA256, .invalidContextWindow])
    }

    func testInvalidMeasurementsFailClosed() {
        let assessment = LocalModelQualificationValidator.evaluate(
            makeObservation(metrics: .init(
                peakResidentMemoryBytes: 0,
                timeToFirstTokenMilliseconds: .nan,
                prefillTokensPerSecond: 0,
                decodeTokensPerSecond: -1,
                maximumThermalState: .fair,
                energyMillijoules: -.infinity
            ))
        )

        XCTAssertEqual(assessment.status, .invalid)
        XCTAssertEqual(
            assessment.issues,
            [.invalidMemoryMeasurement, .invalidPerformanceMeasurement, .invalidEnergyMeasurement]
        )
    }

    func testMissingOrDuplicateTaskSuiteEvidenceFailsClosed() {
        let missing = LocalModelQualificationValidator.evaluate(makeObservation(taskSuites: []))
        XCTAssertEqual(missing.status, .invalid)
        XCTAssertEqual(missing.issues, [.missingTaskSuiteEvidence])

        let suite = makeSuite()
        let duplicate = LocalModelQualificationValidator.evaluate(
            makeObservation(taskSuites: [suite, suite])
        )
        XCTAssertEqual(duplicate.status, .invalid)
        XCTAssertEqual(duplicate.issues, [.duplicateTaskSuiteIdentity])
    }

    func testTaskFailureIsRecordedInsteadOfConvertedIntoAValidationFailure() {
        let suite = makeSuite(successfulTasks: 7, failedTasks: 2)
        let record = makeObservation(taskSuites: [suite])
        let assessment = LocalModelQualificationValidator.evaluate(record)

        XCTAssertEqual(assessment.status, .eligibleForMeasuredClassification)
        XCTAssertEqual(record.taskSuites[0].successfulTasks, 7)
        XCTAssertEqual(record.taskSuites[0].failedTasks, 2)
        XCTAssertEqual(record.taskSuites[0].totalTasks, 9)
    }

    func testCodableRoundTripPreservesQualificationTruth() throws {
        let original = makeObservation(identity: makeIdentity(environment: .simulator))
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LocalModelQualificationObservation.self, from: encoded)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(LocalModelQualificationValidator.evaluate(decoded).status, .researchOnly)
    }

    func testInvalidPersistedRecordIsRejectedOnDecode() throws {
        let invalid = makeObservation(taskSuites: [])
        let encoded = try JSONEncoder().encode(invalid)

        XCTAssertThrowsError(
            try JSONDecoder().decode(LocalModelQualificationObservation.self, from: encoded)
        )
    }

    private func makeObservation(
        identity: LocalModelQualificationIdentity? = nil,
        metrics: LocalModelQualificationMetrics? = nil,
        taskSuites: [LocalModelTaskSuiteObservation]? = nil
    ) -> LocalModelQualificationObservation {
        .init(
            identity: identity ?? makeIdentity(),
            measuredAt: AgentInstant(rawValue: 1_786_180_800_000),
            metrics: metrics ?? makeMetrics(),
            taskSuites: taskSuites ?? [makeSuite()]
        )
    }

    private func makeIdentity(
        artifactSHA256: String? = nil,
        tokenizerRevision: String = "tokenizer-rev-1",
        runtimeRevision: String = "runtime-rev-1",
        kvCacheType: String = "q8_0",
        contextWindowTokens: UInt64 = 8_192,
        deviceModelIdentifier: String = "iPhone13,2",
        operatingSystemVersion: String = "27.0",
        environment: LocalModelQualificationEnvironment = .physicalDevice
    ) -> LocalModelQualificationIdentity {
        .init(
            modelID: "example-model",
            modelRevision: "model-rev-1",
            artifactSHA256: artifactSHA256 ?? artifactDigest,
            artifactFormat: "gguf",
            tokenizerID: "example-tokenizer",
            tokenizerRevision: tokenizerRevision,
            runtimeID: "llama.cpp",
            runtimeRevision: runtimeRevision,
            quantization: "Q4_K_M",
            kvCacheType: kvCacheType,
            contextWindowTokens: contextWindowTokens,
            deviceModelIdentifier: deviceModelIdentifier,
            operatingSystemVersion: operatingSystemVersion,
            environment: environment
        )
    }

    private func makeMetrics() -> LocalModelQualificationMetrics {
        .init(
            peakResidentMemoryBytes: 2_900_000_000,
            timeToFirstTokenMilliseconds: 620,
            prefillTokensPerSecond: 42.5,
            decodeTokensPerSecond: 7.2,
            maximumThermalState: .fair,
            memoryPressureEvents: 0,
            energyMillijoules: 1_234.5
        )
    }

    private func makeSuite(
        successfulTasks: UInt16 = 8,
        failedTasks: UInt16 = 0
    ) -> LocalModelTaskSuiteObservation {
        .init(
            suiteID: "novaforge-local-agent-core",
            suiteRevision: "suite-v1",
            successfulTasks: successfulTasks,
            failedTasks: failedTasks
        )
    }
}
