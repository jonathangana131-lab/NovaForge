import Foundation
import XCTest
@testable import AgentProviders

final class ProviderRouteProfileStaticTrustBoundaryTests: XCTestCase {
    func testExternalConsumerCannotMintSupportedRouteProfile() throws {
        let diagnostics = try typecheckExternalConsumer(
            named: "ProviderRouteProfileTrustBypass.swift",
            source: """
            import AgentProviders

            func forgeProfile(
                descriptor: ProviderAdapterDescriptor,
                endpoint: ProviderEndpointAuthority,
                authenticationMode: ProviderAuthenticationMode,
                dataHandling: ProviderDataHandlingPolicy,
                replayPolicy: ProviderReplayPolicy,
                retryBehavior: ProviderRetryBehavior,
                cancellationBehavior: ProviderCancellationBehavior,
                evidence: ProviderRouteEvidence
            ) throws {
                _ = try ProviderRouteProfile(
                    descriptor: descriptor,
                    endpoint: endpoint,
                    authenticationMode: authenticationMode,
                    dataHandling: dataHandling,
                    replayPolicy: replayPolicy,
                    retryBehavior: retryBehavior,
                    cancellationBehavior: cancellationBehavior,
                    supportState: .supported,
                    evidence: evidence
                )
            }
            """
        )

        XCTAssertTrue(
            diagnostics.contains("ProviderRouteProfile") &&
                (diagnostics.localizedCaseInsensitiveContains("inaccessible due to 'internal' protection level") ||
                    diagnostics.localizedCaseInsensitiveContains("initializer is inaccessible")),
            "Expected ordinary imports to be unable to mint ProviderRouteProfile authority, got: \(diagnostics)"
        )
    }

    private func typecheckExternalConsumer(named fileName: String, source: String) throws -> String {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-route-profile-trust-\(UUID().uuidString)", isDirectory: true)
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
        XCTAssertNotEqual(process.terminationStatus, 0, "External provider-route authority bypass unexpectedly compiled")
        XCTAssertFalse(
            diagnostics.localizedCaseInsensitiveContains("no such module 'agentproviders'"),
            "Trust probe failed before reaching AgentProviders access control: \(diagnostics)"
        )
        return diagnostics
    }

    private func activeModulesURL() throws -> URL {
        let bundleRoot = Bundle(for: ProviderRouteProfileStaticTrustBoundaryTests.self).bundleURL
        let executableRoot = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()

        if let modulesURL = findModulesURL(startingAt: bundleRoot) {
            return modulesURL
        }
        if let modulesURL = findModulesURL(startingAt: executableRoot) {
            return modulesURL
        }

        throw NSError(
            domain: "ProviderRouteProfileStaticTrustBoundaryTests",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "AgentProviders module is missing from the active SwiftPM XCTest bundle and executable ancestry"
            ]
        )
    }

    private func findModulesURL(startingAt start: URL) -> URL? {
        var directory = start

        for _ in 0..<12 {
            let modulesURL = directory.appendingPathComponent("Modules", isDirectory: true)
            let moduleURL = modulesURL.appendingPathComponent("AgentProviders.swiftmodule")
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
