import Foundation
import XCTest
@testable import ForgeHistoryCore

final class ForgeHistoryQualityStaticTrustBoundaryTests: XCTestCase {
    func testExternalConsumerCannotPromoteQualityReferenceToAcceptedStatus() throws {
        let diagnostics = try typecheckExternalConsumer(
            named: "AcceptedStatus.swift",
            source: """
            import ForgeHistoryCore

            func attemptPromotion(_ reference: ForgeHistoryQualityEvidenceReference) {
                switch reference.verificationStatus {
                case .unverifiedReference:
                    break
                case .accepted:
                    break
                }
            }
            """
        )

        XCTAssertTrue(
            diagnostics.localizedCaseInsensitiveContains("no member 'accepted'")
                || diagnostics.localizedCaseInsensitiveContains("has no member 'accepted'"),
            "Expected the public verification enum to reject an accepted status, got: \(diagnostics)"
        )
    }

    func testExternalConsumerCannotResolveLegacyAcceptedQualityMint() throws {
        let diagnostics = try typecheckExternalConsumer(
            named: "LegacyAcceptedMint.swift",
            source: """
            import ForgeHistoryCore

            typealias LeakedAcceptedQualityMint = ForgeHistoryAcceptedQualityEvidenceReference
            """
        )

        XCTAssertTrue(
            diagnostics.localizedCaseInsensitiveContains("cannot find type 'forgehistoryacceptedqualityevidencereference'")
                || diagnostics.localizedCaseInsensitiveContains("cannot find 'forgehistoryacceptedqualityevidencereference'"),
            "Expected the legacy accepted-quality minting type to be absent, got: \(diagnostics)"
        )
    }

    private func typecheckExternalConsumer(
        named fileName: String,
        source: String
    ) throws -> String {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-history-static-trust-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
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

        XCTAssertNotEqual(process.terminationStatus, 0, "External trust bypass unexpectedly compiled")
        XCTAssertFalse(
            diagnostics.localizedCaseInsensitiveContains("no such module 'forgehistorycore'"),
            "Static boundary probe failed before reaching the History trust API: \(diagnostics)"
        )
        return diagnostics
    }

    private func activeModulesURL() throws -> URL {
        let moduleName = "ForgeHistoryCore.swiftmodule"
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

        let testBundle = Bundle(for: ForgeHistoryQualityStaticTrustBoundaryTests.self)
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
            domain: "ForgeHistoryQualityStaticTrustBoundaryTests",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "ForgeHistoryCore module is missing from the active SwiftPM build"
            ]
        )
    }
}
