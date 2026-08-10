import Foundation
import XCTest
@testable import ForgeVisualQA

final class ForgeVisualSelectionStaticTrustBoundaryTests: XCTestCase {
    func testExternalConsumerCannotPromoteCandidateSelectionToTrust() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-visual-selection-static-trust-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let sourceURL = temporaryDirectory.appendingPathComponent("ExternalVisualSelectionMint.swift")
        try """
        import ForgeVisualQA

        func attemptMint(
            _ capture: VisualTrustedCapture,
            selection: VisualSelectionIdentity
        ) throws {
            _ = selection.isValid(for: capture)
            _ = try VisualTrustedSelection(
                authenticatedCapture: capture,
                authenticatedSelection: selection,
                producerReceiptID: "caller-forged-receipt"
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

        XCTAssertNotEqual(process.terminationStatus, 0, "External visual-selection trust mint unexpectedly compiled")
        XCTAssertFalse(
            diagnostics.localizedCaseInsensitiveContains("no such module 'ForgeVisualQA'"),
            "Static boundary probe failed before reaching selection trust boundary: \(diagnostics)"
        )
        XCTAssertTrue(
            diagnostics.contains("isValid") || diagnostics.contains("VisualTrustedSelection"),
            "Expected selection trust diagnostic: \(diagnostics)"
        )
        XCTAssertTrue(
            diagnostics.localizedCaseInsensitiveContains("inaccessible")
                || diagnostics.localizedCaseInsensitiveContains("internal protection level"),
            "Expected access-control rejection, got: \(diagnostics)"
        )
    }

    private func activeModulesURL() throws -> URL {
        let anchors = [
            Bundle(for: ForgeVisualSelectionStaticTrustBoundaryTests.self).bundleURL,
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
            domain: "ForgeVisualSelectionStaticTrustBoundaryTests",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "ForgeVisualQA module is missing from the active SwiftPM test bundle/executable ancestry"
            ]
        )
    }
}
