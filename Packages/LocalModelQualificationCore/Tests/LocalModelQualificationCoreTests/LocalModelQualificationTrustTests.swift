import Foundation
import XCTest
@testable import LocalModelQualificationCore

final class LocalModelQualificationTrustTests: XCTestCase {
    func testAuthenticatedEvidenceCanProduceOpaqueAcceptedClaim() throws {
        let subject = try makeSubject()
        let artifact = try artifactEvidence(subject: subject)
        let record = try LocalModelQualificationRecord(
            revision: 7,
            subject: subject,
            evidence: [artifact]
        )
        let authenticated = LocalModelTrustedEvidenceReceipt(
            authenticatedEvidence: artifact
        )

        let decision = record.trustDecision(
            for: .artifactVerified,
            authenticatedEvidence: [authenticated]
        )

        XCTAssertTrue(decision.readiness.isQualified)
        let accepted = try XCTUnwrap(decision.acceptedClaim)
        XCTAssertEqual(accepted.claim, .artifactVerified)
        XCTAssertEqual(accepted.subject, subject)
        XCTAssertEqual(accepted.recordRevision, 7)
        XCTAssertEqual(accepted.authenticatedEvidenceIDs, [artifact.evidenceID])
    }

    func testPublicCandidateEvidenceWithoutOpaqueReceiptCannotAccept() throws {
        let subject = try makeSubject()
        let artifact = try artifactEvidence(subject: subject)
        let record = try LocalModelQualificationRecord(
            revision: 1,
            subject: subject,
            evidence: [artifact]
        )

        let decision = record.trustDecision(
            for: .artifactVerified,
            authenticatedEvidence: []
        )

        XCTAssertFalse(decision.readiness.isQualified)
        XCTAssertNil(decision.acceptedClaim)
        XCTAssertTrue(
            decision.readiness.blockingReasons.contains {
                $0.contains("host qualification boundary")
            }
        )
    }

    func testOpaqueTrustBindsCompleteEvidenceNotOnlyID() throws {
        let subject = try makeSubject()
        let authenticatedEvidence = try artifactEvidence(
            subject: subject,
            evidenceID: "same-id"
        )
        let callerShapedMutation = try artifactEvidence(
            subject: subject,
            authority: .modelReported,
            evidenceID: "same-id"
        )
        let record = try LocalModelQualificationRecord(
            revision: 1,
            subject: subject,
            evidence: [callerShapedMutation]
        )
        let authenticated = LocalModelTrustedEvidenceReceipt(
            authenticatedEvidence: authenticatedEvidence
        )

        let decision = record.trustDecision(
            for: .artifactVerified,
            authenticatedEvidence: [authenticated]
        )

        XCTAssertFalse(decision.readiness.isQualified)
        XCTAssertNil(decision.acceptedClaim)
        XCTAssertTrue(
            decision.readiness.blockingReasons.contains {
                $0.contains("host qualification boundary")
            }
        )
    }

    func testExternalConsumerCannotMintQualificationAuthority() throws {
        let cases: [(name: String, source: String)] = [
            (
                "TrustedEvidenceMint",
                """
                import LocalModelQualificationCore

                func mint(_ evidence: LocalModelQualificationEvidence) {
                    _ = LocalModelTrustedEvidenceReceipt(
                        authenticatedEvidence: evidence
                    )
                }
                """
            ),
            (
                "AcceptedClaimMint",
                """
                import LocalModelQualificationCore

                func mint(_ subject: LocalModelQualificationSubject) {
                    _ = LocalModelQualifiedClaimReceipt(
                        claim: .artifactVerified,
                        subject: subject,
                        recordRevision: 1,
                        authenticatedEvidenceIDs: []
                    )
                }
                """
            ),
        ]

        for misuse in cases {
            let diagnostics = try typecheckExternalConsumer(
                named: misuse.name,
                source: misuse.source
            )
            XCTAssertTrue(
                diagnostics.localizedCaseInsensitiveContains("inaccessible")
                    || diagnostics.localizedCaseInsensitiveContains("internal protection level")
                    || diagnostics.localizedCaseInsensitiveContains("fileprivate protection level"),
                "Expected access-control rejection for \(misuse.name), got: \(diagnostics)"
            )
        }
    }

    private func typecheckExternalConsumer(
        named name: String,
        source: String
    ) throws -> String {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "local-model-qualification-static-trust-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let sourceURL = temporaryDirectory.appendingPathComponent("\(name).swift")
        try source.write(to: sourceURL, atomically: true, encoding: .utf8)

        let modulesURL = try activeModulesURL()
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "swiftc",
            "-typecheck",
            "-swift-version",
            "6",
            "-I",
            modulesURL.path,
            sourceURL.path,
        ]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()

        let diagnostics = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        XCTAssertNotEqual(
            process.terminationStatus,
            0,
            "\(name) unexpectedly compiled"
        )
        XCTAssertFalse(
            diagnostics.localizedCaseInsensitiveContains(
                "no such module 'localmodelqualificationcore'"
            ),
            "Static trust probe failed before reaching the authority API: \(diagnostics)"
        )
        return diagnostics
    }

    private func activeModulesURL() throws -> URL {
        let moduleName = "LocalModelQualificationCore.swiftmodule"
        let fileManager = FileManager.default
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        if let rawConfiguration = ProcessInfo.processInfo.environment[
            "NOVAFORGE_SWIFT_PACKAGE_CONFIGURATION"
        ] {
            let modulesURL = packageRoot
                .appendingPathComponent(".build", isDirectory: true)
                .appendingPathComponent(
                    rawConfiguration.lowercased(),
                    isDirectory: true
                )
                .appendingPathComponent("Modules", isDirectory: true)
            if fileManager.fileExists(
                atPath: modulesURL.appendingPathComponent(moduleName).path
            ) {
                return modulesURL
            }
        }

        let testBundle = Bundle(for: LocalModelQualificationTrustTests.self)
        var searchRoots = [testBundle.bundleURL]
        if let executableURL = testBundle.executableURL {
            searchRoots.append(executableURL.deletingLastPathComponent())
        }
        searchRoots.append(
            URL(fileURLWithPath: CommandLine.arguments[0])
                .deletingLastPathComponent()
        )

        for searchRoot in searchRoots {
            var directory = searchRoot
            for _ in 0..<12 {
                let modulesURL = directory.appendingPathComponent(
                    "Modules",
                    isDirectory: true
                )
                if fileManager.fileExists(
                    atPath: modulesURL.appendingPathComponent(moduleName).path
                ) {
                    return modulesURL
                }

                let parent = directory.deletingLastPathComponent()
                if parent.path == directory.path {
                    break
                }
                directory = parent
            }
        }

        for configuration in ["debug", "release"] {
            let modulesURL = packageRoot
                .appendingPathComponent(".build", isDirectory: true)
                .appendingPathComponent(configuration, isDirectory: true)
                .appendingPathComponent("Modules", isDirectory: true)
            if fileManager.fileExists(
                atPath: modulesURL.appendingPathComponent(moduleName).path
            ) {
                return modulesURL
            }
        }

        throw NSError(
            domain: "LocalModelQualificationTrustTests",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "LocalModelQualificationCore module is missing from the active SwiftPM build"
            ]
        )
    }

    private func makeSubject() throws -> LocalModelQualificationSubject {
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
                keyCacheType: "q8_0",
                valueCacheType: "q4_0",
                contextTokens: 4_096,
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

    private func artifactEvidence(
        subject: LocalModelQualificationSubject,
        authority: LocalModelEvidenceAuthority = .deterministicHarness,
        evidenceID: String = "artifact-integrity"
    ) throws -> LocalModelQualificationEvidence {
        try .init(
            evidenceID: evidenceID,
            subject: subject,
            evidenceClass: .artifactIntegrity,
            source: .staticAnalysis,
            authority: authority,
            status: .passed,
            payload: .none
        )
    }
}
