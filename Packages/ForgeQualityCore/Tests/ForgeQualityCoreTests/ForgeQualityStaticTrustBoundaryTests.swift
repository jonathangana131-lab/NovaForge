import Foundation
import XCTest
@testable import ForgeQualityCore

final class ForgeQualityStaticTrustBoundaryTests: XCTestCase {
    func testExternalConsumerCannotMintTrustedPolicy() throws {
        try assertExternalMintRejected(
            source: """
            import ForgeQualityCore
            func attempt(_ policy: ForgeQualityPolicy) {
                _ = ForgeQualityTrustedPolicy(authenticatedPolicy: policy)
            }
            """,
            expectedSymbol: "ForgeQualityTrustedPolicy"
        )
    }

    func testExternalConsumerCannotMintTrustedMeasurement() throws {
        try assertExternalMintRejected(
            source: """
            import ForgeQualityCore
            func attempt(_ measurement: ForgeQualityMeasurement) {
                _ = ForgeQualityTrustedMeasurement(authenticatedMeasurement: measurement)
            }
            """,
            expectedSymbol: "ForgeQualityTrustedMeasurement"
        )
    }

    func testExternalConsumerCannotMintTrustedMeasurementBatch() throws {
        try assertExternalMintRejected(
            source: """
            import ForgeQualityCore
            func attempt(_ batch: ForgeQualityMeasurementBatch) {
                _ = ForgeQualityTrustedMeasurementBatch(authenticatedBatch: batch)
            }
            """,
            expectedSymbol: "ForgeQualityTrustedMeasurementBatch"
        )
    }

    func testExternalConsumerCannotMintTrustedRunBinding() throws {
        try assertExternalMintRejected(
            source: """
            import ForgeQualityCore
            func attempt(_ binding: ForgeQualityRunBinding, _ target: ForgeQualityCompletionTarget) {
                _ = ForgeQualityTrustedRunBinding(
                    authenticatedBinding: binding,
                    authenticatedCompletionTarget: target
                )
            }
            """,
            expectedSymbol: "ForgeQualityTrustedRunBinding"
        )
    }

    private func assertExternalMintRejected(
        source: String,
        expectedSymbol: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-quality-static-trust-\(UUID().uuidString)", isDirectory: true)
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

        let diagnostics = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )

        XCTAssertNotEqual(
            process.terminationStatus,
            0,
            "External trust mint unexpectedly compiled",
            file: file,
            line: line
        )
        XCTAssertFalse(
            diagnostics.localizedCaseInsensitiveContains("no such module 'ForgeQualityCore'"),
            "Static boundary probe failed before reaching the trust API: \(diagnostics)",
            file: file,
            line: line
        )
        XCTAssertTrue(
            diagnostics.contains(expectedSymbol),
            "Expected \(expectedSymbol) trust rejection, got: \(diagnostics)",
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
        let starts = [
            Bundle(for: ForgeQualityStaticTrustBoundaryTests.self).bundleURL,
            URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent(),
        ]

        for start in starts {
            var directory = start
            for _ in 0..<10 {
                let modulesURL = directory.appendingPathComponent("Modules", isDirectory: true)
                let moduleURL = modulesURL.appendingPathComponent("ForgeQualityCore.swiftmodule")
                if FileManager.default.fileExists(atPath: moduleURL.path) {
                    return modulesURL
                }
                let parent = directory.deletingLastPathComponent()
                if parent.path == directory.path { break }
                directory = parent
            }
        }

        throw NSError(
            domain: "ForgeQualityStaticTrustBoundaryTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "ForgeQualityCore module missing from active SwiftPM test ancestry"]
        )
    }
}
