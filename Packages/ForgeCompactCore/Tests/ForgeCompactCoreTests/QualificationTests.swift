import XCTest
@testable import ForgeCompactCore

final class QualificationTests: XCTestCase {
    private func profile(contextTokens: Int = 2_048) throws -> LocalRuntimeProfileIdentity {
        try LocalRuntimeProfileIdentity(
            modelID: "Qwen/example", modelRevision: "model-sha",
            tokenizerID: "Qwen/tokenizer", tokenizerRevision: "tokenizer-sha",
            runtimeID: "llama.cpp-metal", runtimeRevision: "runtime-sha",
            weightQuantization: "Q4_K_M", keyCacheType: "q8_0", valueCacheType: "q8_0",
            contextTokens: contextTokens, deviceIdentifier: "iPhone13,2", osBuild: "27.0-test-build"
        )
    }

    private func evidence(networkAudit: Bool = true, thermal: ForgeCompactThermalState = .fair) throws -> LocalRuntimeQualificationEvidence {
        try LocalRuntimeQualificationEvidence(
            profile: profile(), evidenceRevision: "evidence-1", observedAt: Date(timeIntervalSince1970: 1_700_000_000),
            loadSucceeded: true, completedWithoutTermination: true, localOnlyNetworkAuditPassed: networkAudit,
            peakResidentMemoryBytes: 1_200, timeToFirstTokenMilliseconds: 850,
            promptTokensPerSecond: 18.5, decodeTokensPerSecond: 7.25, thermalState: thermal,
            taskSuiteID: "novaforge-local-agent-v1", taskCaseCount: 20, taskPassedCount: 17
        )
    }

    func testProfileIdentityRejectsBlankRevision() throws {
        XCTAssertThrowsError(
            try LocalRuntimeProfileIdentity(
                modelID: "Qwen/example", modelRevision: " ", tokenizerID: "tok", tokenizerRevision: "tok-rev",
                runtimeID: "runtime", runtimeRevision: "rev", weightQuantization: "Q4_K_M",
                keyCacheType: "q8_0", valueCacheType: "q8_0", contextTokens: 2_048,
                deviceIdentifier: "iPhone13,2", osBuild: "27A"
            )
        ) { error in
            XCTAssertEqual(error as? ForgeCompactValidationError, .blankField("modelRevision"))
        }
    }

    func testProfileIdentityRejectsImpossibleContext() throws {
        XCTAssertThrowsError(try profile(contextTokens: 0)) { error in
            XCTAssertEqual(error as? ForgeCompactValidationError, .invalidContextTokens)
        }
    }

    func testEvidenceRejectsNonFiniteMetric() throws {
        XCTAssertThrowsError(
            try LocalRuntimeQualificationEvidence(
                profile: profile(), evidenceRevision: "e1", observedAt: .now,
                loadSucceeded: true, completedWithoutTermination: true, localOnlyNetworkAuditPassed: true,
                peakResidentMemoryBytes: 100, timeToFirstTokenMilliseconds: .infinity,
                promptTokensPerSecond: 1, decodeTokensPerSecond: 1, thermalState: .fair,
                taskSuiteID: "suite", taskCaseCount: 1, taskPassedCount: 1
            )
        ) { error in
            XCTAssertEqual(error as? ForgeCompactValidationError, .invalidMetric("timeToFirstTokenMilliseconds"))
        }
    }

    func testQualificationFailsClosedWithoutLocalOnlyAudit() throws {
        XCTAssertThrowsError(try QualifiedLocalRuntimeProfile(evidence: evidence(networkAudit: false), acceptanceID: "accept"))
    }

    func testQualificationFailsClosedWhenThermalObservationUnknown() throws {
        XCTAssertThrowsError(try QualifiedLocalRuntimeProfile(evidence: evidence(thermal: .unknown), acceptanceID: "accept"))
    }

    func testQualifiedProfileRetainsExactRuntimeAndDeviceIdentity() throws {
        let accepted = try QualifiedLocalRuntimeProfile(evidence: evidence(), acceptanceID: "acceptance-1")
        XCTAssertEqual(accepted.profile.runtimeRevision, "runtime-sha")
        XCTAssertEqual(accepted.profile.keyCacheType, "q8_0")
        XCTAssertEqual(accepted.profile.deviceIdentifier, "iPhone13,2")
        XCTAssertEqual(accepted.evidence.taskCaseCount, 20)
        XCTAssertEqual(accepted.evidence.taskPassedCount, 17)
    }
    func testProfileDecodeRevalidatesTamperedContext() throws {
        let encoded = try JSONEncoder().encode(profile())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["contextTokens"] = 0
        let tampered = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(LocalRuntimeProfileIdentity.self, from: tampered))
    }

    func testQualifiedProfileDecodeCannotBypassLocalOnlyAuditGate() throws {
        let accepted = try QualifiedLocalRuntimeProfile(evidence: evidence(), acceptanceID: "acceptance-1")
        let encoded = try JSONEncoder().encode(accepted)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var evidenceObject = try XCTUnwrap(object["evidence"] as? [String: Any])
        evidenceObject["localOnlyNetworkAuditPassed"] = false
        object["evidence"] = evidenceObject
        let tampered = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(QualifiedLocalRuntimeProfile.self, from: tampered))
    }

}
