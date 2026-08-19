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

    private func activeModulesURL() throws -> URL {
        let moduleName = "ForgeAccessibilityCore.swiftmodule"
        let fileManager = FileManager.default
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        if let configuration = ProcessInfo.processInfo.environment[
            "NOVAFORGE_SWIFT_PACKAGE_CONFIGURATION"
        ] {
            let modulesURL = packageRoot
                .appendingPathComponent(".build", isDirectory: true)
                .appendingPathComponent(configuration, isDirectory: true)
                .appendingPathComponent("Modules", isDirectory: true)
            if fileManager.fileExists(
                atPath: modulesURL.appendingPathComponent(moduleName).path
            ) {
                return modulesURL
            }
        }

        let testBundle = Bundle(for: ForgeAccessibilityStaticTrustBoundaryTests.self)
        var searchRoots = [testBundle.bundleURL]
        if let executableURL = testBundle.executableURL {
            searchRoots.append(executableURL.deletingLastPathComponent())
        }
        searchRoots.append(
            URL(fileURLWithPath: CommandLine.arguments[0])
                .deletingLastPathComponent()
        )

        for searchRoot in searchRoots {
            var directory = searchRoot
            for _ in 0..<12 {
                let modulesURL = directory.appendingPathComponent("Modules", isDirectory: true)
                if fileManager.fileExists(
                    atPath: modulesURL.appendingPathComponent(moduleName).path
                ) {
                    return modulesURL
                }

                let parent = directory.deletingLastPathComponent()
                if parent.path == directory.path {
                    break
                }
                directory = parent
            }
        }

        for configuration in ["debug", "release"] {
            let modulesURL = packageRoot
                .appendingPathComponent(".build", isDirectory: true)
                .appendingPathComponent(configuration, isDirectory: true)
                .appendingPathComponent("Modules", isDirectory: true)
            if fileManager.fileExists(
                atPath: modulesURL.appendingPathComponent(moduleName).path
            ) {
                return modulesURL
            }
        }

        throw NSError(
            domain: "ForgeAccessibilityStaticTrustBoundaryTests",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "ForgeAccessibilityCore module is missing from the active SwiftPM build"
            ]
        )
    }
}
