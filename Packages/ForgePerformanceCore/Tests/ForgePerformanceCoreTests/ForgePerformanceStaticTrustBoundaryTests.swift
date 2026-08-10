import Foundation
import XCTest
@testable import ForgePerformanceCore

final class ForgePerformanceStaticTrustBoundaryTests: XCTestCase {
    func testExternalConsumerCannotMintTrustedProducerReceipt() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-performance-static-trust-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let sourceURL = temporaryDirectory.appendingPathComponent("ExternalTrustMint.swift")
        try """
        import ForgePerformanceCore

        func attemptMint(_ run: ForgePerformanceRunEvidence) {
            _ = ForgePerformanceTrustedProducerReceipt(authenticatedRun: run)
        }
        """.write(to: sourceURL, atomically: true, encoding: .utf8)

        let modulesURL = try activeModulesURL()
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "swiftc", "-typecheck", "-swift-version", "6", "-I", modulesURL.path, sourceURL.path,
        ]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()

        let diagnostics = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertNotEqual(process.terminationStatus, 0, "External trust mint unexpectedly compiled")
        XCTAssertFalse(diagnostics.localizedCaseInsensitiveContains("no such module 'ForgePerformanceCore'"), "Static boundary probe failed before trust API: \(diagnostics)")
        XCTAssertTrue(
            diagnostics.localizedCaseInsensitiveContains("inaccessible") || diagnostics.localizedCaseInsensitiveContains("internal protection level"),
            "Expected access-control rejection, got: \(diagnostics)"
        )
    }

    private func activeModulesURL() throws -> URL {
        let bundleModulesURL = Bundle(for: ForgePerformanceStaticTrustBoundaryTests.self)
            .bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("Modules", isDirectory: true)
        if moduleExists(in: bundleModulesURL) {
            return bundleModulesURL
        }

        // Linux SwiftPM places the test executable directly in the configuration
        // directory instead of a macOS .xctest bundle. Keep this bounded fallback
        // so the same trust probe exercises both layouts without hard-coding a
        // configuration, architecture, or repository path.
        var directory = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
        for _ in 0..<10 {
            let modulesURL = directory.appendingPathComponent("Modules", isDirectory: true)
            if moduleExists(in: modulesURL) {
                return modulesURL
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }

        throw NSError(
            domain: "ForgePerformanceStaticTrustBoundaryTests",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "ForgePerformanceCore module missing from active SwiftPM build"
            ]
        )
    }

    private func moduleExists(in modulesURL: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: modulesURL.appendingPathComponent("ForgePerformanceCore.swiftmodule").path
        )
    }
}
