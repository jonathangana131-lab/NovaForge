import Foundation
import XCTest
@testable import ForgeCompletionCore

final class ForgeCompletionTrustBoundaryTests: XCTestCase {
    func testExternalConsumerCannotInvokeAuthoritativeEvaluator() throws {
        let diagnostics = try typecheckExternalConsumer(
            named: "ForgeCompletionEvaluatorBypass.swift",
            source: """
            import ForgeCompletionCore

            func forgeCompletion(
                constitution: ForgeCompletionConstitution,
                evidence: [ForgeCompletionEvidence],
                inventory: ForgeCompletionDefectInventory
            ) throws {
                _ = try ForgeCompletionEvaluator.evaluate(
                    constitution: constitution,
                    evidence: evidence,
                    defectInventory: inventory
                )
            }
            """
        )

        XCTAssertTrue(
            diagnostics.localizedCaseInsensitiveContains("cannot find 'forgecompletionevaluator' in scope")
                || diagnostics.localizedCaseInsensitiveContains("inaccessible due to 'internal' protection level"),
            "Expected ordinary imports to be unable to invoke Completion acceptance, got: \(diagnostics)"
        )
    }

    func testExternalConsumerCannotConstructSatisfiedEvaluation() throws {
        let diagnostics = try typecheckExternalConsumer(
            named: "ForgeCompletionResultBypass.swift",
            source: """
            import ForgeCompletionCore

            func forgeResult(_ target: ForgeCompletionTarget) {
                _ = ForgeCompletionEvaluation(
                    target: target,
                    status: .satisfied,
                    blockers: [],
                    acceptedEvidenceIDs: [],
                    waivedCriterionIDs: [],
                    knownLimitationIDs: []
                )
            }
            """
        )

        XCTAssertTrue(
            diagnostics.localizedCaseInsensitiveContains("inaccessible due to 'internal' protection level")
                || diagnostics.localizedCaseInsensitiveContains("initializer is inaccessible"),
            "Expected ordinary imports to be unable to mint a satisfied evaluation, got: \(diagnostics)"
        )
    }

    func testExternalConsumerCannotDecodeAuthoritativeEvaluation() throws {
        let diagnostics = try typecheckExternalConsumer(
            named: "ForgeCompletionDecodeBypass.swift",
            source: """
            import Foundation
            import ForgeCompletionCore

            func decodeResult(_ data: Data) throws {
                _ = try JSONDecoder().decode(ForgeCompletionEvaluation.self, from: data)
            }
            """
        )

        XCTAssertTrue(
            diagnostics.localizedCaseInsensitiveContains("does not conform to protocol 'decodable'")
                || diagnostics.localizedCaseInsensitiveContains("requires that 'forgecompletionevaluation' conform to 'decodable'"),
            "Expected authoritative Completion evaluations to remain non-decodable, got: \(diagnostics)"
        )
    }

    private func typecheckExternalConsumer(named fileName: String, source: String) throws -> String {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-completion-trust-\(UUID().uuidString)", isDirectory: true)
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
        XCTAssertNotEqual(process.terminationStatus, 0, "External Completion authority bypass unexpectedly compiled")
        XCTAssertFalse(
            diagnostics.localizedCaseInsensitiveContains("no such module 'forgecompletioncore'"),
            "Trust probe failed before reaching ForgeCompletionCore access control: \(diagnostics)"
        )
        return diagnostics
    }

    private func activeModulesURL() throws -> URL {
        var directory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()

        for _ in 0..<10 {
            let modulesURL = directory.appendingPathComponent("Modules", isDirectory: true)
            let moduleURL = modulesURL.appendingPathComponent("ForgeCompletionCore.swiftmodule")
            if FileManager.default.fileExists(atPath: moduleURL.path) {
                return modulesURL
            }

            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }

        throw NSError(
            domain: "ForgeCompletionTrustBoundaryTests",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "ForgeCompletionCore module is missing from the active SwiftPM test executable ancestry"
            ]
        )
    }
}
