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
        var directory = Bundle(for: ForgeHistoryQualityStaticTrustBoundaryTests.self).bundleURL

        for _ in 0..<10 {
            let modulesURL = directory.appendingPathComponent("Modules", isDirectory: true)
            let moduleURL = modulesURL.appendingPathComponent("ForgeHistoryCore.swiftmodule")
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
            domain: "ForgeHistoryQualityStaticTrustBoundaryTests",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "ForgeHistoryCore module is missing from the active SwiftPM XCTest bundle ancestry"
            ]
        )
    }
}
