import Foundation
import XCTest
@testable import ForgeAccessibilityCore

final class ForgeAccessibilityPolicyStaticTrustBoundaryTests: XCTestCase {
    func testExternalConsumerCannotMintTrustedPolicy() throws {
        let diagnostics = try typecheckExternalSource(
            name: "ExternalPolicyTrustMint",
            source: """
            import ForgeAccessibilityCore

            func attemptMint(_ policy: ForgeAccessibilityPolicy) {
                _ = ForgeAccessibilityTrustedPolicy(authenticatedPolicy: policy)
            }
            """
        )

        XCTAssertTrue(
            diagnostics.localizedCaseInsensitiveContains("inaccessible")
                || diagnostics.localizedCaseInsensitiveContains("internal protection level"),
            "Expected trusted-policy access-control rejection, got: \(diagnostics)"
        )
    }

    func testExternalConsumerCannotCallRawEvaluatorWithoutTrustedPolicy() throws {
        let diagnostics = try typecheckExternalSource(
            name: "ExternalRawEvaluatorBypass",
            source: """
            import ForgeAccessibilityCore

            func attemptBypass(
                policy: ForgeAccessibilityPolicy,
                runs: [ForgeAccessibilityRunEvidence],
                receipts: [ForgeAccessibilityTrustedProducerReceipt]
            ) throws {
                _ = try ForgeAccessibilityEvaluator.evaluate(
                    policy: policy,
                    runs: runs,
                    trustedProducerReceipts: receipts
                )
            }
            """
        )

        XCTAssertTrue(
            diagnostics.localizedCaseInsensitiveContains("missing argument for parameter 'trustedpolicy'")
                || diagnostics.localizedCaseInsensitiveContains("inaccessible")
                || diagnostics.localizedCaseInsensitiveContains("internal protection level"),
            "Expected raw-evaluator trust-boundary rejection, got: \(diagnostics)"
        )
    }

    private func typecheckExternalSource(name: String, source: String) throws -> String {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-accessibility-policy-static-trust-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let sourceURL = temporaryDirectory.appendingPathComponent("\(name).swift")
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
            diagnostics.localizedCaseInsensitiveContains("no such module 'ForgeAccessibilityCore'"),
            "Static boundary probe failed before reaching the trust API: \(diagnostics)"
        )
        return diagnostics
    }

    private func activeModulesURL() throws -> URL {
        let anchors = [
            Bundle(for: ForgeAccessibilityPolicyStaticTrustBoundaryTests.self).bundleURL,
            URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent(),
        ]

        for anchor in anchors {
            var directory = anchor
            for _ in 0..<12 {
                let modulesURL = directory.appendingPathComponent("Modules", isDirectory: true)
                let moduleURL = modulesURL.appendingPathComponent("ForgeAccessibilityCore.swiftmodule")
                if FileManager.default.fileExists(atPath: moduleURL.path) {
                    return modulesURL
                }

                let parent = directory.deletingLastPathComponent()
                if parent.path == directory.path {
                    break
                }
                directory = parent
            }
        }

        throw NSError(
            domain: "ForgeAccessibilityPolicyStaticTrustBoundaryTests",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "ForgeAccessibilityCore module is missing from the active SwiftPM test bundle/executable ancestry"
            ]
        )
    }
}
