import Foundation
import XCTest
@testable import ForgeVisualQA

final class ForgeVisualQAStaticTrustBoundaryTests: XCTestCase {
    func testExternalConsumerCannotMintTrustedVisualCapture() throws {
        try assertExternalSourceRejected(
            """
            import ForgeVisualQA

            func attemptMint(_ capture: VisualCaptureReceipt) throws {
                _ = try VisualTrustedCapture(
                    authenticatedCapture: capture,
                    artifactSHA256: String(repeating: "a", count: 64)
                )
            }
            """,
            expectedSymbol: "VisualTrustedCapture"
        )
    }

    func testExternalConsumerCannotMintFirstMinuteAssessment() throws {
        try assertExternalSourceRejected(
            """
            import ForgeVisualQA

            func attemptMint(
                _ capture: VisualTrustedCapture,
                observations: [FirstMinuteObservation]
            ) {
                _ = FirstMinuteAssessment(capture: capture, observations: observations)
            }
            """,
            expectedSymbol: "FirstMinuteAssessment"
        )
    }

    func testExternalConsumerCannotMintAutoPolishPass() throws {
        try assertExternalSourceRejected(
            """
            import ForgeVisualQA

            func attemptMint(
                _ capture: VisualTrustedCapture,
                findings: [VisualFinding]
            ) {
                _ = AutoPolishPass(
                    capture: capture,
                    findings: findings,
                    improvementScore: 1
                )
            }
            """,
            expectedSymbol: "AutoPolishPass"
        )
    }

    private func assertExternalSourceRejected(
        _ source: String,
        expectedSymbol: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-visual-static-trust-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let sourceURL = temporaryDirectory.appendingPathComponent("ExternalVisualTrustMint.swift")
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

        XCTAssertNotEqual(
            process.terminationStatus,
            0,
            "External visual authority mint unexpectedly compiled",
            file: file,
            line: line
        )
        XCTAssertFalse(
            diagnostics.localizedCaseInsensitiveContains("no such module 'ForgeVisualQA'"),
            "Static boundary probe failed before reaching \(expectedSymbol): \(diagnostics)",
            file: file,
            line: line
        )
        XCTAssertTrue(
            diagnostics.contains(expectedSymbol),
            "Expected \(expectedSymbol) diagnostic: \(diagnostics)",
            file: file,
            line: line
        )
        XCTAssertTrue(
            diagnostics.localizedCaseInsensitiveContains("inaccessible")
                || diagnostics.localizedCaseInsensitiveContains("internal protection level"),
            "Expected access-control rejection, got: \(diagnostics)",
            file: file,
            line: line
        )
    }

    private func activeModulesURL() throws -> URL {
        let anchors = [
            Bundle(for: ForgeVisualQAStaticTrustBoundaryTests.self).bundleURL,
            URL(fileURLWithPath: CommandLine.arguments[0]),
        ]

        for anchor in anchors {
            var directory = anchor.deletingLastPathComponent()

            for _ in 0..<10 {
                let modulesURL = directory.appendingPathComponent("Modules", isDirectory: true)
                let moduleURL = modulesURL.appendingPathComponent("ForgeVisualQA.swiftmodule")
                if FileManager.default.fileExists(atPath: moduleURL.path) {
                    return modulesURL
                }

                let parent = directory.deletingLastPathComponent()
                if parent.path == directory.path {
                    break
                }
                directory = parent
            }
        }

        throw NSError(
            domain: "ForgeVisualQAStaticTrustBoundaryTests",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "ForgeVisualQA module is missing from the active SwiftPM test bundle/executable ancestry"
            ]
        )
    }
}
