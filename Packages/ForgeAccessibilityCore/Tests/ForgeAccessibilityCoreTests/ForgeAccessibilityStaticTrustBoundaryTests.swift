import Foundation
import XCTest
@testable import ForgeAccessibilityCore

final class ForgeAccessibilityStaticTrustBoundaryTests: XCTestCase {
    func testExternalConsumerCannotMintTrustedProducerReceipt() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-accessibility-static-trust-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let sourceURL = temporaryDirectory.appendingPathComponent("ExternalTrustMint.swift")
        try """
        import ForgeAccessibilityCore

        func attemptMint(_ run: ForgeAccessibilityRunEvidence) {
            _ = ForgeAccessibilityTrustedProducerReceipt(authenticatedRun: run)
        }
        """.write(to: sourceURL, atomically: true, encoding: .utf8)

        let modulesURL = Bundle(for: ForgeAccessibilityStaticTrustBoundaryTests.self)
            .bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("Modules", isDirectory: true)
        let moduleURL = modulesURL.appendingPathComponent("ForgeAccessibilityCore.swiftmodule")
        guard FileManager.default.fileExists(atPath: moduleURL.path) else {
            XCTFail("ForgeAccessibilityCore module is missing from active SwiftPM build at \(modulesURL.path)")
            return
        }

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

        XCTAssertNotEqual(process.terminationStatus, 0, "External trust mint unexpectedly compiled")
        XCTAssertFalse(
            diagnostics.localizedCaseInsensitiveContains("no such module 'ForgeAccessibilityCore'"),
            "Static boundary probe failed before reaching the trust API: \(diagnostics)"
        )
        XCTAssertTrue(
            diagnostics.localizedCaseInsensitiveContains("inaccessible")
                || diagnostics.localizedCaseInsensitiveContains("internal protection level"),
            "Expected access-control rejection, got: \(diagnostics)"
        )
    }
}
