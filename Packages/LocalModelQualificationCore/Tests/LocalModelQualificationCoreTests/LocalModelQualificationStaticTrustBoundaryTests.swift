import Foundation
import XCTest
@testable import LocalModelQualificationCore

final class LocalModelQualificationStaticTrustBoundaryTests: XCTestCase {
    func testExternalConsumerCannotMintQualificationTrustBinding() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-model-qualification-static-trust-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let sourceURL = temporaryDirectory.appendingPathComponent("ExternalTrustMint.swift")
        let externalSource = [
            "import LocalModelQualificationCore",
            "",
            "func attemptMint(_ evidence: LocalModelQualificationEvidence) {",
            "    _ = LocalModelQualificationTrustBinding(authenticatedEvidence: evidence)",
            "}",
        ].joined(separator: "\n")
        try externalSource.write(to: sourceURL, atomically: true, encoding: .utf8)

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
        XCTAssertNotEqual(process.terminationStatus, 0, "External qualification trust mint unexpectedly compiled")
        XCTAssertFalse(
            diagnostics.localizedCaseInsensitiveContains("no such module 'LocalModelQualificationCore'"),
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
            Bundle(for: LocalModelQualificationStaticTrustBoundaryTests.self).bundleURL,
            URL(fileURLWithPath: CommandLine.arguments[0]),
        ]

        for anchor in anchors {
            var directory = anchor.deletingLastPathComponent()
            for _ in 0..<10 {
                let modulesURL = directory.appendingPathComponent("Modules", isDirectory: true)
                let moduleURL = modulesURL.appendingPathComponent("LocalModelQualificationCore.swiftmodule")
                if FileManager.default.fileExists(atPath: moduleURL.path) {
                    return modulesURL
                }
                let parent = directory.deletingLastPathComponent()
                if parent.path == directory.path { break }
                directory = parent
            }
        }

        throw NSError(
            domain: "LocalModelQualificationStaticTrustBoundaryTests",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "LocalModelQualificationCore module is missing from the active SwiftPM test bundle/executable ancestry"
            ]
        )
    }
}
