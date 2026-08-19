import Foundation
import XCTest
@testable import ForgePlaytestCore

final class ForgePlaytestDefectTrustBoundaryTests: XCTestCase {
    func testExternalConsumerCannotMintAuthenticatedDefectBinding() throws {
        let diagnostics = try typecheckExternalConsumer(
            named: "ForgePlaytestDefectTrustBypass.swift",
            source: """
            import ForgePlaytestCore

            func forgeBinding(
                project: ForgePlaytestProjectRevision,
                defect: ForgePlaytestDefect,
                evidence: ForgePlaytestEvidenceReference
            ) throws {
                _ = try ForgePlaytestAuthenticatedDefectBinding(
                    project: project,
                    journeyID: evidence.journeyID,
                    defect: defect,
                    supportingEvidence: [evidence]
                )
            }
            """
        )

        XCTAssertTrue(
            diagnostics.localizedCaseInsensitiveContains("inaccessible due to 'internal' protection level")
                || diagnostics.localizedCaseInsensitiveContains("initializer is inaccessible"),
            "Expected ordinary imports to be unable to mint authenticated defect evidence, got: \(diagnostics)"
        )
    }

    private func typecheckExternalConsumer(named fileName: String, source: String) throws -> String {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-playtest-defect-trust-\(UUID().uuidString)", isDirectory: true)
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
        XCTAssertNotEqual(process.terminationStatus, 0, "External defect-trust bypass unexpectedly compiled")
        XCTAssertFalse(
            diagnostics.localizedCaseInsensitiveContains("no such module 'forgeplaytestcore'"),
            "Trust probe failed before reaching ForgePlaytestCore access control: \(diagnostics)"
        )
        return diagnostics
    }

    private func activeModulesURL() throws -> URL {
        let bundleRoot = Bundle(for: ForgePlaytestDefectTrustBoundaryTests.self).bundleURL
        let executableRoot = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()

        if let modulesURL = findModulesURL(startingAt: bundleRoot) {
            return modulesURL
        }
        if let modulesURL = findModulesURL(startingAt: executableRoot) {
            return modulesURL
        }

        throw NSError(
            domain: "ForgePlaytestDefectTrustBoundaryTests",
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
