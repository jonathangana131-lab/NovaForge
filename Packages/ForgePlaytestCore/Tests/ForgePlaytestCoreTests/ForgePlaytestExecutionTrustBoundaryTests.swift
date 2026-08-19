import Foundation
import XCTest
@testable import ForgePlaytestCore

final class ForgePlaytestExecutionTrustBoundaryTests: XCTestCase {
    func testExternalConsumerCannotMintAuthenticatedExecutionBinding() throws {
        let diagnostics = try typecheckExternalConsumer(
            named: "ForgePlaytestExecutionTrustBypass.swift",
            source: """
            import ForgePlaytestCore

            func forgeBinding(
                result: ForgePlaytestJourneyResult,
                trace: ForgePlaytestTrace
            ) throws {
                _ = try ForgePlaytestExecutionBinding(
                    result: result,
                    trace: trace
                )
            }
            """
        )

        XCTAssertTrue(
            diagnostics.localizedCaseInsensitiveContains("inaccessible due to 'internal' protection level")
                || diagnostics.localizedCaseInsensitiveContains("initializer is inaccessible"),
            "Expected ordinary imports to be unable to mint authenticated execution evidence, got: \(diagnostics)"
        )
    }

    func testExternalConsumerCannotUseLegacyCallerShapedExecutionBinding() throws {
        let diagnostics = try typecheckExternalConsumer(
            named: "ForgePlaytestLegacyExecutionTrustBypass.swift",
            source: """
            import ForgePlaytestCore

            func forgeBinding(
                evidence: ForgePlaytestEvidenceReference,
                trace: ForgePlaytestTrace
            ) throws {
                _ = try ForgePlaytestExecutionBinding(
                    executionEvidence: evidence,
                    trace: trace
                )
            }
            """
        )

        XCTAssertTrue(
            diagnostics.localizedCaseInsensitiveContains("incorrect argument label")
                || diagnostics.localizedCaseInsensitiveContains("extra argument")
                || diagnostics.localizedCaseInsensitiveContains("missing argument")
                || diagnostics.localizedCaseInsensitiveContains("inaccessible"),
            "Expected the old caller-shaped execution authority path to stay unavailable, got: \(diagnostics)"
        )
    }

    private func typecheckExternalConsumer(named fileName: String, source: String) throws -> String {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-playtest-execution-trust-\(UUID().uuidString)", isDirectory: true)
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
        XCTAssertNotEqual(process.terminationStatus, 0, "External execution-trust bypass unexpectedly compiled")
        XCTAssertFalse(
            diagnostics.localizedCaseInsensitiveContains("no such module 'forgeplaytestcore'"),
            "Trust probe failed before reaching ForgePlaytestCore access control: \(diagnostics)"
        )
        return diagnostics
    }

    private func activeModulesURL() throws -> URL {
        let bundleRoot = Bundle(for: ForgePlaytestExecutionTrustBoundaryTests.self).bundleURL
        let executableRoot = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()

        if let modulesURL = findModulesURL(startingAt: bundleRoot) {
            return modulesURL
        }
        if let modulesURL = findModulesURL(startingAt: executableRoot) {
            return modulesURL
        }

        throw NSError(
            domain: "ForgePlaytestExecutionTrustBoundaryTests",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "ForgePlaytestCore module is missing from the active SwiftPM XCTest bundle and executable ancestry"
            ]
        )
    }

    private func findModulesURL(startingAt start: URL) -> URL? {
        var directory = start

        for _ in 0..<12 {
            let modulesURL = directory.appendingPathComponent("Modules", isDirectory: true)
            let moduleURL = modulesURL.appendingPathComponent("ForgePlaytestCore.swiftmodule")
            if FileManager.default.fileExists(atPath: moduleURL.path) {
                return modulesURL
            }

            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }

        return nil
    }
}
