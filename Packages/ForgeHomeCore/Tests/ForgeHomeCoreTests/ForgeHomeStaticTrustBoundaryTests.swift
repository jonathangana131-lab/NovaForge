import Foundation
import XCTest
@testable import ForgeHomeCore

final class ForgeHomeStaticTrustBoundaryTests: XCTestCase {
    func testExternalConsumerCannotMintHomeTrustBinding() throws {
        let diagnostics = try typecheckExternalConsumer(
            named: "HomeTrustMint.swift",
            source: """
            import Foundation
            import ForgeHomeCore

            let record = ForgeCreationRecord(name: "Forged", lastChangedAt: Date())
            _ = try ForgeHomeTrustBinding(authenticatedRecord: record)
            """
        )

        XCTAssertTrue(
            diagnostics.localizedCaseInsensitiveContains("initializer is inaccessible")
                || diagnostics.localizedCaseInsensitiveContains("inaccessible due to 'internal' protection"),
            "Expected the Home trust initializer to be inaccessible, got: \(diagnostics)"
        )
    }

    func testExternalConsumerCannotConstructRunnableHomeState() throws {
        let diagnostics = try typecheckExternalConsumer(
            named: "HomeRunStateMint.swift",
            source: """
            import Foundation
            import ForgeHomeCore

            let evidence = ForgeRuntimeEvidence(
                artifactID: ForgeArtifactID(rawValue: "runtime-r1"),
                runtimeKind: .forgeWeb,
                verificationLevel: .runtimeTested,
                sourceRevision: "r1",
                recordedAt: Date()
            )
            _ = ForgeCreationRunState(acceptedRuntimeEvidence: evidence)
            """
        )

        XCTAssertTrue(
            diagnostics.localizedCaseInsensitiveContains("initializer is inaccessible")
                || diagnostics.localizedCaseInsensitiveContains("inaccessible due to 'internal' protection")
                || diagnostics.localizedCaseInsensitiveContains("extra argument 'acceptedruntimeevidence'"),
            "Expected Home run-state construction to be inaccessible, got: \(diagnostics)"
        )
    }

    private func typecheckExternalConsumer(named fileName: String, source: String) throws -> String {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-home-static-trust-\(UUID().uuidString)", isDirectory: true)
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

        let diagnostics = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertNotEqual(process.terminationStatus, 0, "External Home trust bypass unexpectedly compiled")
        XCTAssertFalse(
            diagnostics.localizedCaseInsensitiveContains("no such module 'forgehomecore'"),
            "Static boundary probe failed before reaching the Home trust API: \(diagnostics)"
        )
        return diagnostics
    }

    private func activeModulesURL() throws -> URL {
        var directory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()

        for _ in 0..<10 {
            let modulesURL = directory.appendingPathComponent("Modules", isDirectory: true)
            let moduleURL = modulesURL.appendingPathComponent("ForgeHomeCore.swiftmodule")
            if FileManager.default.fileExists(atPath: moduleURL.path) {
                return modulesURL
            }

            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }

        throw NSError(
            domain: "ForgeHomeStaticTrustBoundaryTests",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "ForgeHomeCore module is missing from the active SwiftPM test executable ancestry"
            ]
        )
    }
}
