import Foundation
import XCTest
@testable import ForgePerformanceCore

final class ForgePerformanceStaticTrustBoundaryTests: XCTestCase {
    func testExternalConsumerCannotMintTrustedReceipts() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-performance-static-trust-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let probes: [(name: String, source: String)] = [
            (
                "ProducerTrustMint",
                """
                import ForgePerformanceCore

                func attemptMint(_ run: ForgePerformanceRunEvidence) {
                    _ = ForgePerformanceTrustedProducerReceipt(authenticatedRun: run)
                }
                """
            ),
            (
                "PolicyTrustMint",
                """
                import ForgePerformanceCore

                func attemptMint(_ policy: ForgePerformancePolicy) {
                    _ = ForgePerformanceTrustedPolicyReceipt(authenticatedPolicy: policy)
                }
                """
            ),
        ]

        let modulesURL = try activeModulesURL()
        for probe in probes {
            let sourceURL = temporaryDirectory.appendingPathComponent("\(probe.name).swift")
            try probe.source.write(to: sourceURL, atomically: true, encoding: .utf8)

            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [
                "swiftc", "-typecheck", "-swift-version", "6", "-I", modulesURL.path, sourceURL.path,
            ]
            process.standardOutput = output
            process.standardError = output
            try process.run()
            process.waitUntilExit()

            let diagnostics = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            XCTAssertNotEqual(process.terminationStatus, 0, "\(probe.name) unexpectedly compiled")
            XCTAssertFalse(
                diagnostics.localizedCaseInsensitiveContains("no such module 'ForgePerformanceCore'"),
                "\(probe.name) failed before trust API: \(diagnostics)"
            )
            XCTAssertTrue(
                diagnostics.localizedCaseInsensitiveContains("inaccessible")
                    || diagnostics.localizedCaseInsensitiveContains("internal protection level"),
                "\(probe.name) expected access-control rejection, got: \(diagnostics)"
            )
        }
    }

    private func activeModulesURL() throws -> URL {
        let anchors = [
            Bundle(for: ForgePerformanceStaticTrustBoundaryTests.self).bundleURL,
            URL(fileURLWithPath: CommandLine.arguments[0]),
        ]

        for anchor in anchors {
            var directory = anchor.deletingLastPathComponent()
            for _ in 0..<10 {
                let modulesURL = directory.appendingPathComponent("Modules", isDirectory: true)
                if moduleExists(in: modulesURL) {
                    return modulesURL
                }
                let parent = directory.deletingLastPathComponent()
                if parent.path == directory.path { break }
                directory = parent
            }
        }

        throw NSError(
            domain: "ForgePerformanceStaticTrustBoundaryTests",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "ForgePerformanceCore module missing from active SwiftPM test bundle/executable ancestry"
            ]
        )
    }

    private func moduleExists(in modulesURL: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: modulesURL.appendingPathComponent("ForgePerformanceCore.swiftmodule").path
        )
    }
}
