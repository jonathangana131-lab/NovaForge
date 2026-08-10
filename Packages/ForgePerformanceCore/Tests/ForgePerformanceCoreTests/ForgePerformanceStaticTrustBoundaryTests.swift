import Foundation
import XCTest
@testable import ForgePerformanceCore

final class ForgePerformanceStaticTrustBoundaryTests: XCTestCase {
    func testExternalConsumerCannotMintBudgetTrustBinding() throws {
        try assertExternalCompileRejected(
            source: """
            import ForgePerformanceCore

            func attemptMint(_ budget: ForgePerformanceBudget) {
                _ = ForgePerformanceBudgetTrustBinding(authenticatedBudget: budget)
            }
            """
        )
    }

    func testExternalConsumerCannotMintMeasurementTrustBinding() throws {
        try assertExternalCompileRejected(
            source: """
            import ForgePerformanceCore

            func attemptMint(_ batch: ForgePerformanceMeasurementBatch) {
                _ = ForgePerformanceMeasurementTrustBinding(authenticatedBatch: batch)
            }
            """
        )
    }

    private func assertExternalCompileRejected(source: String) throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-performance-static-trust-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let sourceURL = temporaryDirectory.appendingPathComponent("ExternalTrustMint.swift")
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

        let diagnostics = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertNotEqual(process.terminationStatus, 0, "External trust mint unexpectedly compiled")
        XCTAssertFalse(
            diagnostics.localizedCaseInsensitiveContains("no such module 'ForgePerformanceCore'"),
            "Static boundary probe failed before reaching the trust API: \(diagnostics)"
        )
        XCTAssertTrue(
            diagnostics.localizedCaseInsensitiveContains("inaccessible")
                || diagnostics.localizedCaseInsensitiveContains("internal protection level"),
            "Expected access-control rejection, got: \(diagnostics)"
        )
    }

    private func activeModulesURL() throws -> URL {
        var directory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()

        for _ in 0..<10 {
            let modulesURL = directory.appendingPathComponent("Modules", isDirectory: true)
            let moduleURL = modulesURL.appendingPathComponent("ForgePerformanceCore.swiftmodule")
            if FileManager.default.fileExists(atPath: moduleURL.path) {
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
                    "ForgePerformanceCore module is missing from the active SwiftPM test executable ancestry"
            ]
        )
    }
}
