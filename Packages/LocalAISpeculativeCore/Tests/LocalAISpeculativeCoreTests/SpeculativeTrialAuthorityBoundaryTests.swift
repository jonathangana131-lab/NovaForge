import Foundation
import XCTest
import LocalAISpeculativeCore

final class SpeculativeTrialAuthorityBoundaryTests: XCTestCase {
    func testPassingTrialShapeNeverAuthorizesExecution() {
        let digestA = String(repeating: "a", count: 64)
        let digestB = String(repeating: "b", count: 64)
        let digestC = String(repeating: "c", count: 64)
        let digestD = String(repeating: "d", count: 64)
        let verifier = SpeculativeParticipantIdentity(
            qualificationProfileID: "target-profile",
            runtimeID: "llama.cpp",
            runtimeRevision: "rev-1",
            tokenSemanticsSHA256: digestA,
            executionLocality: .onDevice
        )
        let drafter = SpeculativeParticipantIdentity(
            qualificationProfileID: "draft-profile",
            runtimeID: "llama.cpp",
            runtimeRevision: "rev-1",
            tokenSemanticsSHA256: digestA,
            executionLocality: .onDevice
        )
        let configuration = SpeculativeDecodingConfiguration(
            verifier: verifier,
            drafter: drafter,
            verifierRuntimeConfigurationSHA256: digestC,
            drafterRuntimeConfigurationSHA256: digestD,
            mechanismID: "draft-simple",
            capabilityDeclarationRevision: "source-rev-1",
            kind: .draftModel,
            maximumDraftTokens: 4,
            contextTokens: 4_096,
            promptContractSHA256: digestB,
            privacyPolicy: .localOnly
        )
        let declaration = SpeculativeRuntimeCapabilityDeclaration(
            runtimeID: "llama.cpp",
            runtimeRevision: "rev-1",
            mechanismID: "draft-simple",
            kind: .draftModel,
            maximumDraftTokens: 8,
            declarationRevision: "source-rev-1"
        )

        let result = SpeculativeTrialValidator.evaluate(
            configuration: configuration,
            declaration: declaration
        )

        XCTAssertTrue(result.isEligible)
        XCTAssertTrue(result.isStructurallyEligible)
        XCTAssertFalse(result.authorizesExecution)
        XCTAssertEqual(result.authority, .researchCandidateShapeOnly)
    }

    func testExternalConsumerCannotMintDerivedTrialEligibility() throws {
        let diagnostics = try typecheckExternalConsumer(
            named: "MintTrialEligibility.swift",
            source: """
            import LocalAISpeculativeCore

            let forged = SpeculativeTrialEligibility(
                isEligible: true,
                rejections: []
            )
            _ = forged
            """
        )

        XCTAssertTrue(
            diagnostics.localizedCaseInsensitiveContains("initializer is inaccessible")
                || diagnostics.localizedCaseInsensitiveContains("inaccessible due to 'fileprivate'"),
            "Expected derived trial eligibility construction to be inaccessible, got: \(diagnostics)"
        )
    }

    func testExternalConsumerCannotSerializeDerivedTrialEligibility() throws {
        let diagnostics = try typecheckExternalConsumer(
            named: "SerializeTrialEligibility.swift",
            source: """
            import Foundation
            import LocalAISpeculativeCore

            func persist(_ eligibility: SpeculativeTrialEligibility) throws -> Data {
                try JSONEncoder().encode(eligibility)
            }
            """
        )

        XCTAssertTrue(
            diagnostics.localizedCaseInsensitiveContains("requires that 'speculativetrialeligibility' conform to 'encodable'")
                || diagnostics.localizedCaseInsensitiveContains("does not conform to protocol 'encodable'"),
            "Expected derived trial eligibility to remain non-Encodable, got: \(diagnostics)"
        )
    }

    private func typecheckExternalConsumer(
        named fileName: String,
        source: String
    ) throws -> String {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-ai-speculative-trial-trust-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let sourceURL = temporaryDirectory.appendingPathComponent(fileName)
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

        XCTAssertNotEqual(process.terminationStatus, 0, "External speculative trial trust bypass unexpectedly compiled")
        XCTAssertFalse(
            diagnostics.localizedCaseInsensitiveContains("no such module 'localaispeculativecore'"),
            "Static boundary probe failed before reaching the speculative API: \(diagnostics)"
        )
        return diagnostics
    }

    private func activeModulesURL() throws -> URL {
        let executableDirectory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let searchAnchors = [
            Bundle(for: SpeculativeTrialAuthorityBoundaryTests.self).bundleURL,
            executableDirectory,
        ]
        var visitedDirectories = Set<String>()

        for anchor in searchAnchors {
            var directory = anchor
            for _ in 0..<12 {
                if visitedDirectories.insert(directory.standardizedFileURL.path).inserted {
                    let modulesURL = directory.appendingPathComponent("Modules", isDirectory: true)
                    let moduleURL = modulesURL.appendingPathComponent("LocalAISpeculativeCore.swiftmodule")
                    if FileManager.default.fileExists(atPath: moduleURL.path) {
                        return modulesURL
                    }
                }

                let parent = directory.deletingLastPathComponent()
                if parent.path == directory.path {
                    break
                }
                directory = parent
            }
        }

        throw NSError(
            domain: "SpeculativeTrialAuthorityBoundaryTests",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "LocalAISpeculativeCore module is missing from the active SwiftPM test bundle and executable ancestry"
            ]
        )
    }
}
