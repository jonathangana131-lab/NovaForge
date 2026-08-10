import Foundation
import XCTest
@testable import ForgeVisualQA

final class ForgeVisualAnalysisStaticTrustBoundaryTests: XCTestCase {
    func testExternalConsumerCannotMintTrustedVisualAnalysis() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-visual-analysis-static-trust-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let sourceURL = temporaryDirectory.appendingPathComponent("ExternalVisualAnalysisMint.swift")
        try """
        import ForgeVisualQA

        func attemptMint(
            _ capture: VisualTrustedCapture,
            observations: [FirstMinuteObservation],
            findings: [VisualFinding]
        ) throws {
            _ = try VisualTrustedAnalysis(
                authenticatedCapture: capture,
                observations: observations,
                findings: findings,
                improvementScore: 1,
                analyzerReceiptID: "caller-forged-receipt"
            )
        }
        """.write(to: sourceURL, atomically: true, encoding: .utf8)

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

        XCTAssertNotEqual(process.terminationStatus, 0, "External visual-analysis trust mint unexpectedly compiled")
        XCTAssertFalse(
            diagnostics.localizedCaseInsensitiveContains("no such module 'ForgeVisualQA'"),
            "Static boundary probe failed before reaching VisualTrustedAnalysis: \(diagnostics)"
        )
        XCTAssertTrue(
            diagnostics.contains("VisualTrustedAnalysis"),
            "Expected trusted-analysis diagnostic: \(diagnostics)"
        )
        XCTAssertTrue(
            diagnostics.localizedCaseInsensitiveContains("inaccessible")
                || diagnostics.localizedCaseInsensitiveContains("internal protection level"),
            "Expected access-control rejection, got: \(diagnostics)"
        )
    }

    private func activeModulesURL() throws -> URL {
        let anchors = [
            Bundle(for: ForgeVisualAnalysisStaticTrustBoundaryTests.self).bundleURL,
            URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent(),
        ]

        for anchor in anchors {
            var directory = anchor
            for _ in 0..<12 {
                let modulesURL = directory.appendingPathComponent("Modules", isDirectory: true)
                let moduleURL = modulesURL.appendingPathComponent("ForgeVisualQA.swiftmodule")
                if FileManager.default.fileExists(atPath: moduleURL.path) {
                    return modulesURL
                }

                let parent = directory.deletingLastPathComponent()
                if parent.path == directory.path { break }
                directory = parent
            }
        }

        throw NSError(
            domain: "ForgeVisualAnalysisStaticTrustBoundaryTests",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "ForgeVisualQA module is missing from the active SwiftPM test bundle/executable ancestry"
            ]
        )
    }
}
