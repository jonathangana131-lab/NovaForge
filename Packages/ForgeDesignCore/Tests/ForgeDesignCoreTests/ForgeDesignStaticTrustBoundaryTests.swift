import Foundation
import XCTest
@testable import ForgeDesignCore

final class ForgeDesignStaticTrustBoundaryTests: XCTestCase {
    func testExternalConsumerCannotMintAcceptedSnapshotTrust() throws {
        try assertExternalCompilationRejected(
            source: """
            import ForgeDesignCore

            func attemptMint(_ snapshot: DesignDNA) {
                _ = DesignDNATrustBinding(authenticatedSnapshot: snapshot)
            }
            """
        )
    }

    func testExternalConsumerCannotMintUserMutationAuthority() throws {
        try assertExternalCompilationRejected(
            source: """
            import ForgeDesignCore

            func attemptMint(
                _ before: DesignDNA,
                _ after: DesignDNA,
                _ purpose: DesignDNAUserMutationPurpose
            ) {
                _ = DesignDNAUserMutationAuthority(
                    authenticatedBefore: before,
                    authenticatedAfter: after,
                    purpose: purpose
                )
            }
            """
        )
    }

    func testExternalConsumerCannotMintTransitionTrust() throws {
        try assertExternalCompilationRejected(
            source: """
            import ForgeDesignCore

            func attemptMint(
                _ before: DesignDNA,
                _ after: DesignDNA,
                _ kind: DesignDNATransitionKind
            ) throws {
                _ = try DesignDNATransitionTrustBinding(
                    authenticatedBefore: before,
                    authenticatedAfter: after,
                    kind: kind
                )
            }
            """
        )
    }

    private func assertExternalCompilationRejected(source: String) throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-design-static-trust-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let sourceURL = temporaryDirectory.appendingPathComponent("ExternalTrustMint.swift")
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

        XCTAssertNotEqual(process.terminationStatus, 0, "External trust mint unexpectedly compiled")
        XCTAssertFalse(
            diagnostics.localizedCaseInsensitiveContains("no such module 'ForgeDesignCore'"),
            "Static boundary probe failed before reaching the trust API: \(diagnostics)"
        )
        XCTAssertTrue(
            diagnostics.localizedCaseInsensitiveContains("inaccessible")
                || diagnostics.localizedCaseInsensitiveContains("internal protection level"),
            "Expected access-control rejection, got: \(diagnostics)"
        )
    }

    private func activeModulesURL() throws -> URL {
        let anchors = [
            Bundle(for: ForgeDesignStaticTrustBoundaryTests.self).bundleURL,
            URL(fileURLWithPath: CommandLine.arguments[0]),
        ]

        for anchor in anchors {
            var directory = anchor.deletingLastPathComponent()

            for _ in 0..<10 {
                let modulesURL = directory.appendingPathComponent("Modules", isDirectory: true)
                let moduleURL = modulesURL.appendingPathComponent("ForgeDesignCore.swiftmodule")
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
            domain: "ForgeDesignStaticTrustBoundaryTests",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "ForgeDesignCore module is missing from the active SwiftPM test bundle/executable ancestry"
            ]
        )
    }
}
