import Foundation
import XCTest
@testable import LocalModelQualificationCore

final class LocalModelArtifactIntegrityProducerTests: XCTestCase {
    func testMatchingArtifactCanQualifyOnlyArtifactIntegrity() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let artifactURL = temporaryDirectory.appendingPathComponent("model.gguf")
        try Data("abc".utf8).write(to: artifactURL)

        let subject = try makeSubject(
            artifactSHA256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        let verification = try LocalModelArtifactIntegrityProducer.verify(
            subject: subject,
            artifactURL: artifactURL
        )
        let record = try LocalModelQualificationRecord(
            revision: 1,
            subject: subject,
            evidence: [verification.evidence]
        )

        XCTAssertTrue(verification.passed)
        XCTAssertEqual(verification.evidence.evidenceClass, .artifactIntegrity)
        XCTAssertEqual(verification.evidence.source, .staticAnalysis)
        XCTAssertEqual(verification.evidence.authority, .deterministicHarness)
        XCTAssertEqual(verification.evidence.status, .passed)
        XCTAssertTrue(
            record.readiness(
                for: .artifactVerified,
                trustedReceipts: [verification.trustedReceipt]
            ).isQualified
        )

        let deviceReadiness = record.readiness(
            for: .deviceRuntimeQualified,
            trustedReceipts: [verification.trustedReceipt]
        )
        XCTAssertFalse(deviceReadiness.isQualified)
        XCTAssertTrue(deviceReadiness.blockingReasons.contains("Missing modelLoad evidence."))
        XCTAssertTrue(deviceReadiness.blockingReasons.contains("Missing firstToken evidence."))
        XCTAssertTrue(deviceReadiness.blockingReasons.contains("Missing throughput evidence."))
        XCTAssertTrue(deviceReadiness.blockingReasons.contains("Missing memory evidence."))
        XCTAssertTrue(deviceReadiness.blockingReasons.contains("Missing thermal evidence."))
        XCTAssertTrue(deviceReadiness.blockingReasons.contains("Missing taskSuite evidence."))
    }

    func testMismatchedArtifactProducesTrustedFailedEvidenceWithoutPromotion() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let artifactURL = temporaryDirectory.appendingPathComponent("model.gguf")
        try Data("abd".utf8).write(to: artifactURL)

        let subject = try makeSubject(
            artifactSHA256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        let verification = try LocalModelArtifactIntegrityProducer.verify(
            subject: subject,
            artifactURL: artifactURL
        )
        let record = try LocalModelQualificationRecord(
            revision: 1,
            subject: subject,
            evidence: [verification.evidence]
        )

        XCTAssertFalse(verification.passed)
        XCTAssertEqual(verification.evidence.status, .failed)
        let readiness = record.readiness(
            for: .artifactVerified,
            trustedReceipts: [verification.trustedReceipt]
        )
        XCTAssertFalse(readiness.isQualified)
        XCTAssertTrue(
            readiness.blockingReasons.contains("artifactIntegrity evidence did not pass.")
        )
    }

    func testSymlinkArtifactIsRejectedBeforeTrustMinting() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let targetURL = temporaryDirectory.appendingPathComponent("target.gguf")
        let symlinkURL = temporaryDirectory.appendingPathComponent("model.gguf")
        try Data("abc".utf8).write(to: targetURL)
        try FileManager.default.createSymbolicLink(
            at: symlinkURL,
            withDestinationURL: targetURL
        )

        let subject = try makeSubject(
            artifactSHA256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )

        XCTAssertThrowsError(
            try LocalModelArtifactIntegrityProducer.verify(
                subject: subject,
                artifactURL: symlinkURL
            )
        ) { error in
            XCTAssertEqual(
                error as? LocalModelArtifactIntegrityProducerError,
                .artifactNotRegularFile
            )
        }
    }

    func testDirectoryArtifactIsRejectedBeforeTrustMinting() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let subject = try makeSubject(
            artifactSHA256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )

        XCTAssertThrowsError(
            try LocalModelArtifactIntegrityProducer.verify(
                subject: subject,
                artifactURL: temporaryDirectory
            )
        ) { error in
            XCTAssertEqual(
                error as? LocalModelArtifactIntegrityProducerError,
                .artifactNotRegularFile
            )
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "local-model-artifact-integrity-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    private func makeSubject(
        artifactSHA256: String
    ) throws -> LocalModelQualificationSubject {
        try .init(
            artifact: .init(
                modelID: "example/model",
                modelRevision: "model-revision-1",
                tokenizerID: "example/tokenizer",
                tokenizerRevision: "tokenizer-revision-1",
                artifactSHA256: artifactSHA256
            ),
            runtime: .init(
                runtimeID: "llama.cpp",
                runtimeRevision: "runtime-revision-1",
                backend: "Metal"
            ),
            execution: .init(
                quantization: "Q4_K_M",
                keyCacheType: "f16",
                valueCacheType: "f16",
                contextTokens: 2_048,
                batchTokens: 64
            ),
            device: .init(
                environment: .physicalDevice,
                hardwareIdentifier: "iPhone13,2",
                marketingName: "iPhone 12",
                chip: "A14",
                osVersion: "27.0",
                osBuild: "24A123"
            )
        )
    }
}
