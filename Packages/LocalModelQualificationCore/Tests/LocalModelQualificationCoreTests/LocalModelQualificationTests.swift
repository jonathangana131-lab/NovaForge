import Foundation
import XCTest
@testable import LocalModelQualificationCore

final class LocalModelQualificationTests: XCTestCase {
    func testExactSubjectAcceptsFullyBoundPhysicalDeviceIdentity() throws {
        let subject = try makeSubject()
        XCTAssertEqual(subject.artifact.modelRevision, "model-rev-42")
        XCTAssertEqual(subject.artifact.tokenizerRevision, "tokenizer-rev-7")
        XCTAssertEqual(subject.runtime.runtimeRevision, "llama-rev-100")
        XCTAssertEqual(subject.execution.keyCacheType, "q8_0")
        XCTAssertEqual(subject.execution.valueCacheType, "q4_0")
        XCTAssertEqual(subject.execution.contextTokens, 4_096)
        XCTAssertEqual(subject.device.hardwareIdentifier, "iPhone13,2")
        XCTAssertEqual(subject.device.osBuild, "24A123")
    }

    func testArtifactRejectsBlankRevisionAndMalformedDigest() throws {
        XCTAssertThrowsError(
            try LocalModelArtifactIdentity(
                modelID: "model",
                modelRevision: " ",
                tokenizerID: "tokenizer",
                tokenizerRevision: "rev",
                artifactSHA256: String(repeating: "a", count: 64)
            )
        )
        XCTAssertThrowsError(
            try LocalModelArtifactIdentity(
                modelID: "model",
                modelRevision: "rev",
                tokenizerID: "tokenizer",
                tokenizerRevision: "rev",
                artifactSHA256: "not-a-digest"
            )
        )
    }

    func testExecutionProfileRejectsImpossibleContextAndBatch() throws {
        XCTAssertThrowsError(
            try LocalModelExecutionProfile(
                quantization: "Q4_K_M",
                keyCacheType: "q8_0",
                valueCacheType: "q8_0",
                contextTokens: 0,
                batchTokens: 1
            )
        )
        XCTAssertThrowsError(
            try LocalModelExecutionProfile(
                quantization: "Q4_K_M",
                keyCacheType: "q8_0",
                valueCacheType: "q8_0",
                contextTokens: 128,
                batchTokens: 256
            )
        )
    }

    func testPerformanceMeasurementRejectsEstimatedOrInvalidShape() throws {
        XCTAssertThrowsError(
            try LocalModelPerformanceMeasurement(
                promptTokens: 0,
                generatedTokens: 20,
                timeToFirstTokenMilliseconds: 50,
                prefillTokensPerSecond: 10,
                decodeTokensPerSecond: 5,
                peakResidentBytes: 100,
                peakMemoryPressure: .nominal
            )
        )
        XCTAssertThrowsError(
            try LocalModelPerformanceMeasurement(
                promptTokens: 10,
                generatedTokens: 20,
                timeToFirstTokenMilliseconds: .nan,
                prefillTokensPerSecond: 10,
                decodeTokensPerSecond: 5,
                peakResidentBytes: 100,
                peakMemoryPressure: .nominal
            )
        )
    }

    func testTaskSuiteRequiresRealAttemptCounts() throws {
        XCTAssertThrowsError(try LocalModelTaskSuiteResult(suiteID: "coding", suiteRevision: "r1", attempted: 0, passed: 0))
        XCTAssertThrowsError(try LocalModelTaskSuiteResult(suiteID: "coding", suiteRevision: "r1", attempted: 3, passed: 4))
        let result = try LocalModelTaskSuiteResult(suiteID: "coding", suiteRevision: "r1", attempted: 4, passed: 3)
        XCTAssertEqual(result.passRate, 0.75)
    }

    func testPhysicalEvidenceCannotBeBoundToSimulatorSubject() throws {
        let subject = try makeSubject(environment: .simulator)
        XCTAssertThrowsError(
            try LocalModelQualificationEvidence(
                evidenceID: "load",
                subject: subject,
                evidenceClass: .modelLoad,
                source: .physicalDevice,
                authority: .deterministicHarness,
                status: .passed,
                payload: .none
            )
        ) { error in
            XCTAssertEqual(error as? LocalModelQualificationError, .evidenceSourceMismatch)
        }
    }

    func testStaticAnalysisCannotPretendToBeRuntimeEvidence() throws {
        let subject = try makeSubject()
        XCTAssertThrowsError(
            try LocalModelQualificationEvidence(
                evidenceID: "load",
                subject: subject,
                evidenceClass: .modelLoad,
                source: .staticAnalysis,
                authority: .deterministicHarness,
                status: .passed,
                payload: .none
            )
        ) { error in
            XCTAssertEqual(error as? LocalModelQualificationError, .evidenceSourceMismatch)
        }
    }

    func testEvidencePayloadMustMatchItsEvidenceClass() throws {
        let subject = try makeSubject()
        XCTAssertThrowsError(
            try LocalModelQualificationEvidence(
                evidenceID: "thermal",
                subject: subject,
                evidenceClass: .thermal,
                source: .physicalDevice,
                authority: .deterministicHarness,
                status: .passed,
                payload: .none
            )
        ) { error in
            XCTAssertEqual(error as? LocalModelQualificationError, .invalidEvidencePayload)
        }
    }

    func testArtifactVerificationCanUseDeterministicStaticIntegrityEvidence() throws {
        let subject = try makeSubject()
        let artifact = try evidence(.artifactIntegrity, subject: subject, source: .staticAnalysis)
        let record = try LocalModelQualificationRecord(revision: 1, subject: subject, evidence: [artifact])
        let readiness = record.readiness(for: .artifactVerified, trustedEvidence: trustedEvidence(record))
        XCTAssertTrue(readiness.isQualified)
        XCTAssertTrue(readiness.blockingReasons.isEmpty)
    }

    func testModelReportedArtifactDoesNotSelfAuthorizeQualification() throws {
        let subject = try makeSubject()
        let artifact = try evidence(
            .artifactIntegrity,
            subject: subject,
            source: .staticAnalysis,
            authority: .modelReported
        )
        let record = try LocalModelQualificationRecord(revision: 1, subject: subject, evidence: [artifact])
        let readiness = record.readiness(for: .artifactVerified, trustedEvidence: trustedEvidence(record))
        XCTAssertFalse(readiness.isQualified)
        XCTAssertTrue(readiness.blockingReasons.contains { $0.contains("deterministic-harness") })
    }

    func testDeterministicHarnessLabelAloneCannotAuthorizeQualification() throws {
        let subject = try makeSubject()
        let artifact = try evidence(.artifactIntegrity, subject: subject, source: .staticAnalysis)
        let record = try LocalModelQualificationRecord(revision: 1, subject: subject, evidence: [artifact])
        let readiness = record.readiness(for: .artifactVerified, trustedEvidence: [])
        XCTAssertFalse(readiness.isQualified)
        XCTAssertTrue(readiness.blockingReasons.contains { $0.contains("host qualification boundary") })
    }

    func testTrustBindsExactReceiptNotOnlyEvidenceID() throws {
        let subject = try makeSubject()
        let trusted = try evidence(.artifactIntegrity, subject: subject, source: .staticAnalysis, evidenceID: "same-id")
        let mutated = try evidence(
            .artifactIntegrity,
            subject: subject,
            source: .staticAnalysis,
            authority: .modelReported,
            evidenceID: "same-id"
        )
        let record = try LocalModelQualificationRecord(revision: 1, subject: subject, evidence: [mutated])
        let readiness = record.readiness(for: .artifactVerified, trustedEvidence: [trusted])
        XCTAssertFalse(readiness.isQualified)
        XCTAssertTrue(readiness.blockingReasons.contains { $0.contains("host qualification boundary") })
    }

    func testExactPhysicalHarnessEvidenceQualifiesRuntime() throws {
        let subject = try makeSubject()
        let record = try fullyQualifiedRecord(subject: subject, includeLocalOnlyAudit: false)
        XCTAssertTrue(record.readiness(for: .deviceRuntimeQualified, trustedEvidence: trustedEvidence(record)).isQualified)
        XCTAssertFalse(record.readiness(for: .localOnlyDeviceQualified, trustedEvidence: trustedEvidence(record)).isQualified)
    }

    func testLocalOnlyClaimRequiresDeterministicNetworkAudit() throws {
        let subject = try makeSubject()
        let withoutAudit = try fullyQualifiedRecord(subject: subject, includeLocalOnlyAudit: false)
        XCTAssertFalse(withoutAudit.readiness(for: .localOnlyDeviceQualified, trustedEvidence: trustedEvidence(withoutAudit)).isQualified)

        let withAudit = try fullyQualifiedRecord(subject: subject, includeLocalOnlyAudit: true)
        XCTAssertTrue(withAudit.readiness(for: .localOnlyDeviceQualified, trustedEvidence: trustedEvidence(withAudit)).isQualified)
    }

    func testSimulatorCanStoreBenchmarkEvidenceButCannotQualifyDevice() throws {
        let subject = try makeSubject(environment: .simulator)
        let receipts = try runtimeReceipts(subject: subject, source: .simulator)
        let record = try LocalModelQualificationRecord(revision: 1, subject: subject, evidence: receipts)
        let readiness = record.readiness(for: .deviceRuntimeQualified, trustedEvidence: trustedEvidence(record))
        XCTAssertFalse(readiness.isQualified)
        XCTAssertTrue(readiness.blockingReasons.contains { $0.contains("Simulator") })
        XCTAssertTrue(readiness.blockingReasons.contains { $0.contains("physical device") })
    }

    func testFailedCurrentEvidenceBlocksPromotion() throws {
        let subject = try makeSubject()
        var receipts = try runtimeReceipts(subject: subject, source: .physicalDevice)
        receipts.removeAll { $0.evidenceClass == .thermal }
        receipts.append(
            try evidence(
                .thermal,
                subject: subject,
                status: .failed,
                payload: .thermal(.critical)
            )
        )
        let record = try LocalModelQualificationRecord(revision: 2, subject: subject, evidence: receipts)
        let readiness = record.readiness(for: .deviceRuntimeQualified, trustedEvidence: trustedEvidence(record))
        XCTAssertFalse(readiness.isQualified)
        XCTAssertTrue(readiness.blockingReasons.contains { $0.contains("thermal evidence did not pass") })
    }

    func testDuplicateEvidenceClassFailsClosed() throws {
        let subject = try makeSubject()
        let first = try evidence(.artifactIntegrity, subject: subject, source: .staticAnalysis, evidenceID: "hash-1")
        let second = try evidence(.artifactIntegrity, subject: subject, source: .staticAnalysis, evidenceID: "hash-2")
        XCTAssertThrowsError(
            try LocalModelQualificationRecord(revision: 1, subject: subject, evidence: [first, second])
        ) { error in
            XCTAssertEqual(error as? LocalModelQualificationError, .duplicateEvidenceClass(.artifactIntegrity))
        }
    }

    func testEvidenceCannotCrossExactKVProfileBoundary() throws {
        let q8q4 = try makeSubject(keyCacheType: "q8_0", valueCacheType: "q4_0")
        let q8q8 = try makeSubject(keyCacheType: "q8_0", valueCacheType: "q8_0")
        let receipt = try evidence(.artifactIntegrity, subject: q8q4, source: .staticAnalysis)
        XCTAssertThrowsError(
            try LocalModelQualificationRecord(revision: 1, subject: q8q8, evidence: [receipt])
        ) { error in
            XCTAssertEqual(error as? LocalModelQualificationError, .evidenceSubjectMismatch)
        }
    }

    func testEvidenceCannotCrossOSBuildBoundary() throws {
        let oldBuild = try makeSubject(osBuild: "24A123")
        let newBuild = try makeSubject(osBuild: "24A124")
        let receipt = try evidence(.artifactIntegrity, subject: oldBuild, source: .staticAnalysis)
        XCTAssertThrowsError(
            try LocalModelQualificationRecord(revision: 1, subject: newBuild, evidence: [receipt])
        ) { error in
            XCTAssertEqual(error as? LocalModelQualificationError, .evidenceSubjectMismatch)
        }
    }

    func testArchiveRoundTripIsCanonicalAndValidated() throws {
        let subject = try makeSubject()
        let record2 = try fullyQualifiedRecord(subject: subject, revision: 2, includeLocalOnlyAudit: true)
        let record1 = try LocalModelQualificationRecord(
            revision: 1,
            subject: subject,
            evidence: [try evidence(.artifactIntegrity, subject: subject, source: .staticAnalysis)]
        )
        let archive = try LocalModelQualificationArchive(records: [record2, record1])
        XCTAssertEqual(archive.records.map(\.revision), [1, 2])

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(archive)
        let decoded = try JSONDecoder().decode(LocalModelQualificationArchive.self, from: data)
        XCTAssertEqual(decoded, archive)
        XCTAssertEqual(try encoder.encode(decoded), data)
    }

    func testArchiveRejectsUnknownSchema() throws {
        let subject = try makeSubject()
        let archive = try LocalModelQualificationArchive(
            records: [try LocalModelQualificationRecord(
                revision: 1,
                subject: subject,
                evidence: [try evidence(.artifactIntegrity, subject: subject, source: .staticAnalysis)]
            )]
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(archive)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["schemaVersion"] = 99
        let corrupted = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(LocalModelQualificationArchive.self, from: corrupted))
    }

    func testArchiveDecodeRevalidatesTamperedExecutionBudget() throws {
        let subject = try makeSubject()
        let archive = try LocalModelQualificationArchive(
            records: [try fullyQualifiedRecord(subject: subject, includeLocalOnlyAudit: false)]
        )
        let data = try JSONEncoder().encode(archive)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var records = try XCTUnwrap(object["records"] as? [[String: Any]])
        var first = records[0]
        var subjectObject = try XCTUnwrap(first["subject"] as? [String: Any])
        var execution = try XCTUnwrap(subjectObject["execution"] as? [String: Any])
        execution["contextTokens"] = 0
        subjectObject["execution"] = execution
        first["subject"] = subjectObject
        records[0] = first
        object["records"] = records
        let corrupted = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(LocalModelQualificationArchive.self, from: corrupted))
    }

    private func trustedEvidence(_ record: LocalModelQualificationRecord) -> Set<LocalModelQualificationEvidence> {
        Set(record.evidence)
    }

    private func makeSubject(
        environment: LocalExecutionEnvironment = .physicalDevice,
        keyCacheType: String = "q8_0",
        valueCacheType: String = "q4_0",
        osBuild: String = "24A123"
    ) throws -> LocalModelQualificationSubject {
        try .init(
            artifact: .init(
                modelID: "example/model",
                modelRevision: "model-rev-42",
                tokenizerID: "example/tokenizer",
                tokenizerRevision: "tokenizer-rev-7",
                artifactSHA256: String(repeating: "a", count: 64)
            ),
            runtime: .init(
                runtimeID: "llama.cpp",
                runtimeRevision: "llama-rev-100",
                backend: "Metal"
            ),
            execution: .init(
                quantization: "Q4_K_M",
                keyCacheType: keyCacheType,
                valueCacheType: valueCacheType,
                contextTokens: 4_096,
                batchTokens: 64
            ),
            device: .init(
                environment: environment,
                hardwareIdentifier: environment == .physicalDevice ? "iPhone13,2" : "iPhone13,2-Simulator",
                marketingName: environment == .physicalDevice ? "iPhone 12" : "iPhone 12 Simulator",
                chip: "A14",
                osVersion: "27.0",
                osBuild: osBuild
            )
        )
    }

    private func measurement() throws -> LocalModelPerformanceMeasurement {
        try .init(
            promptTokens: 512,
            generatedTokens: 128,
            timeToFirstTokenMilliseconds: 180,
            prefillTokensPerSecond: 42,
            decodeTokensPerSecond: 11,
            peakResidentBytes: 1_750_000_000,
            peakKVCacheBytes: 120_000_000,
            energyJoules: 14.5,
            peakMemoryPressure: .warning
        )
    }

    private func evidence(
        _ evidenceClass: LocalModelEvidenceClass,
        subject: LocalModelQualificationSubject,
        source: LocalModelEvidenceSource = .physicalDevice,
        authority: LocalModelEvidenceAuthority = .deterministicHarness,
        status: LocalModelEvidenceStatus = .passed,
        payload: LocalModelEvidencePayload? = nil,
        evidenceID: String? = nil
    ) throws -> LocalModelQualificationEvidence {
        let resolvedPayload: LocalModelEvidencePayload
        if let payload {
            resolvedPayload = payload
        } else {
            switch evidenceClass {
            case .artifactIntegrity, .modelLoad:
                resolvedPayload = .none
            case .firstToken, .throughput, .memory:
                resolvedPayload = .performance(try measurement())
            case .thermal:
                resolvedPayload = .thermal(.fair)
            case .taskSuite:
                resolvedPayload = .taskSuite(
                    try .init(suiteID: "novaforge-local-agent", suiteRevision: "suite-r3", attempted: 20, passed: 18)
                )
            case .localOnlyNetworkAudit:
                resolvedPayload = .localOnlyAudit(receiptID: "network-audit-1")
            }
        }
        return try .init(
            evidenceID: evidenceID ?? "evidence-\(evidenceClass.rawValue)",
            subject: subject,
            evidenceClass: evidenceClass,
            source: source,
            authority: authority,
            status: status,
            payload: resolvedPayload
        )
    }

    private func runtimeReceipts(
        subject: LocalModelQualificationSubject,
        source: LocalModelEvidenceSource
    ) throws -> [LocalModelQualificationEvidence] {
        [
            try evidence(.artifactIntegrity, subject: subject, source: .staticAnalysis),
            try evidence(.modelLoad, subject: subject, source: source),
            try evidence(.firstToken, subject: subject, source: source),
            try evidence(.throughput, subject: subject, source: source),
            try evidence(.memory, subject: subject, source: source),
            try evidence(.thermal, subject: subject, source: source),
            try evidence(.taskSuite, subject: subject, source: source),
        ]
    }

    private func fullyQualifiedRecord(
        subject: LocalModelQualificationSubject,
        revision: Int = 1,
        includeLocalOnlyAudit: Bool
    ) throws -> LocalModelQualificationRecord {
        var receipts = try runtimeReceipts(subject: subject, source: .physicalDevice)
        if includeLocalOnlyAudit {
            receipts.append(try evidence(.localOnlyNetworkAudit, subject: subject))
        }
        return try .init(revision: revision, subject: subject, evidence: receipts)
    }
}
