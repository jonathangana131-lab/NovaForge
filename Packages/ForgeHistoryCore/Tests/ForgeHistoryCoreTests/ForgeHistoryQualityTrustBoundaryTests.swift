import Foundation
import XCTest
@testable import ForgeHistoryCore

final class ForgeHistoryQualityTrustBoundaryTests: XCTestCase {
    func testExternalConsumerCannotMintAcceptedQualityEvidenceReference() throws {
        try assertExternalCompilationRejected(
            source: """
            import ForgeHistoryCore

            func attemptMint(_ receipt: ForgeHistoryProducerReceiptReference) {
                _ = ForgeHistoryAcceptedQualityEvidenceReference(
                    kind: .accessibility,
                    producerReceiptReference: receipt
                )
            }
            """,
            expectedSymbol: "ForgeHistoryAcceptedQualityEvidenceReference"
        )
    }

    func testExternalConsumerCannotMintAcceptedCheckpointBinding() throws {
        try assertExternalCompilationRejected(
            source: """
            import ForgeHistoryCore

            func attemptMint(
                project: ForgeHistoryProjectID,
                checkpoint: ForgeHistoryCheckpointID
            ) throws {
                _ = try ForgeHistoryCheckpointQualityBinding(
                    projectID: project,
                    checkpointID: checkpoint,
                    evidence: []
                )
            }
            """,
            expectedSymbol: "ForgeHistoryCheckpointQualityBinding"
        )
    }

    private func assertExternalCompilationRejected(
        source: String,
        expectedSymbol: String
    ) throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-history-quality-trust-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let sourceURL = temporaryDirectory.appendingPathComponent("ExternalHistoryQualityMint.swift")
        try source.write(to: sourceURL, atomically: true, encoding: .utf8)

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "swiftc",
            "-typecheck",
            "-swift-version",
            "6",
            "-I",
            try activeModulesURL().path,
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

        XCTAssertNotEqual(process.terminationStatus, 0, "External accepted-quality mint unexpectedly compiled")
        XCTAssertFalse(
            diagnostics.localizedCaseInsensitiveContains("no such module 'ForgeHistoryCore'"),
            "Static boundary probe failed before reaching the History trust API: \(diagnostics)"
        )
        XCTAssertTrue(
            diagnostics.contains(expectedSymbol),
            "Expected diagnostic for \(expectedSymbol), got: \(diagnostics)"
        )
        XCTAssertTrue(
            diagnostics.localizedCaseInsensitiveContains("inaccessible")
                || diagnostics.localizedCaseInsensitiveContains("internal protection level"),
            "Expected access-control rejection, got: \(diagnostics)"
        )
    }

    private func activeModulesURL() throws -> URL {
        var directory = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()

        for _ in 0..<10 {
            let modulesURL = directory.appendingPathComponent("Modules", isDirectory: true)
            let moduleURL = modulesURL.appendingPathComponent("ForgeHistoryCore.swiftmodule")
            if FileManager.default.fileExists(atPath: moduleURL.path) {
                return modulesURL
            }

            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path {
                break
            }
            directory = parent
        }

        throw NSError(
            domain: "ForgeHistoryQualityTrustBoundaryTests",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "ForgeHistoryCore module is missing from the active SwiftPM test executable ancestry"
            ]
        )
    }
}
