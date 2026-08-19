import Foundation
import XCTest
import ForgeRuntime

final class ForgeRuntimeStateStaticTrustBoundaryTests: XCTestCase {
    func testExternalConsumerCannotPromoteCandidateVerdictToAccepted() throws {
        let diagnostics = try typecheckExternalConsumer(
            named: "AcceptedState.swift",
            source: """
            import ForgeRuntime

            let verdict: ForgeRuntimeStateCandidateVerdict = .accepted
            """
        )

        XCTAssertTrue(
            diagnostics.localizedCaseInsensitiveContains("no member 'accepted'")
                || diagnostics.localizedCaseInsensitiveContains("has no member 'accepted'"),
            "Expected candidate-only verdict to reject accepted authority, got: \(diagnostics)"
        )
    }

    func testExternalConsumerCannotResolveRemovedForgeableAuthenticator() throws {
        let diagnostics = try typecheckExternalConsumer(
            named: "LegacyAuthenticator.swift",
            source: """
            import ForgeRuntime

            typealias LeakedRuntimeStateTrust = ForgeRuntimeStateEvidenceAuthenticating
            """
        )

        XCTAssertTrue(
            diagnostics.localizedCaseInsensitiveContains("cannot find type 'forgeruntimestateevidenceauthenticating'")
                || diagnostics.localizedCaseInsensitiveContains("cannot find 'forgeruntimestateevidenceauthenticating'"),
            "Expected the forgeable legacy authenticator surface to be absent, got: \(diagnostics)"
        )
    }

    private func typecheckExternalConsumer(
        named fileName: String,
        source: String
    ) throws -> String {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-runtime-state-trust-\(UUID().uuidString)", isDirectory: true)
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

        XCTAssertNotEqual(process.terminationStatus, 0, "External Runtime state trust bypass unexpectedly compiled")
        XCTAssertFalse(
            diagnostics.localizedCaseInsensitiveContains("no such module 'forgeruntime'"),
            "Static boundary probe failed before reaching the Runtime state API: \(diagnostics)"
        )
        return diagnostics
    }

    private func activeModulesURL() throws -> URL {
        var directory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()

        for _ in 0..<10 {
            let modulesURL = directory.appendingPathComponent("Modules", isDirectory: true)
            let moduleURL = modulesURL.appendingPathComponent("ForgeRuntime.swiftmodule")
            if FileManager.default.fileExists(atPath: moduleURL.path) {
                return modulesURL
            }

            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path {
                break
            }
            directory = parent
        }

        throw NSError(
            domain: "ForgeRuntimeStateStaticTrustBoundaryTests",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "ForgeRuntime module is missing from the active SwiftPM test executable ancestry"
            ]
        )
    }
}
