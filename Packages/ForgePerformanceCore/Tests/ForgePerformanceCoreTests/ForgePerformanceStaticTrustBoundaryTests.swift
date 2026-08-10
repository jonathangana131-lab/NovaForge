import Foundation
import XCTest
@testable import ForgePerformanceCore

final class ForgePerformanceStaticTrustBoundaryTests: XCTestCase {
    func testExternalConsumerCannotMintTrustedPolicyReceipt() throws {
        let diagnostics = try typecheckExternalConsumer(
            named: "TrustedPolicyMint.swift",
            source: """
            import ForgePerformanceCore

            func attemptMint(_ policy: ForgePerformancePolicy) {
                _ = ForgePerformanceTrustedPolicyReceipt(authenticatedPolicy: policy)
            }
            """
        )

        XCTAssertTrue(
            diagnostics.localizedCaseInsensitiveContains("initializer is inaccessible")
                || diagnostics.localizedCaseInsensitiveContains("'init' is inaccessible"),
            "Expected external policy-trust minting to be inaccessible, got: \(diagnostics)"
        )
    }

    func testExternalConsumerCannotMintTrustedProducerReceipt() throws {
        let diagnostics = try typecheckExternalConsumer(
            named: "TrustedProducerMint.swift",
            source: """
            import ForgePerformanceCore

            func attemptMint(_ run: ForgePerformanceRunEvidence) {
                _ = ForgePerformanceTrustedProducerReceipt(authenticatedRun: run)
            }
            """
        )

        XCTAssertTrue(
            diagnostics.localizedCaseInsensitiveContains("initializer is inaccessible")
                || diagnostics.localizedCaseInsensitiveContains("'init' is inaccessible"),
            "Expected external producer-trust minting to be inaccessible, got: \(diagnostics)"
        )
    }

    func testExternalConsumerCannotPersistAcceptedEvaluation() throws {
        let diagnostics = try typecheckExternalConsumer(
            named: "PersistAcceptedEvaluation.swift",
            source: """
            import Foundation
            import ForgePerformanceCore

            func attemptPersistence(_ evaluation: ForgePerformanceEvaluation) throws {
                _ = try JSONEncoder().encode(evaluation)
            }
            """
        )

        XCTAssertTrue(
            diagnostics.localizedCaseInsensitiveContains("conform to 'encodable'")
                || diagnostics.localizedCaseInsensitiveContains("does not conform to protocol 'encodable'"),
            "Expected accepted evaluation to remain non-Codable, got: \(diagnostics)"
        )
    }

    private func typecheckExternalConsumer(named fileName: String, source: String) throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-performance-static-trust-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent(fileName)
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
        XCTAssertNotEqual(process.terminationStatus, 0, "External trust bypass unexpectedly compiled")
        XCTAssertFalse(
            diagnostics.localizedCaseInsensitiveContains("no such module 'forgeperformancecore'"),
            "Static boundary probe failed before reaching ForgePerformanceCore: \(diagnostics)"
        )
        return diagnostics
    }

    private func activeModulesURL() throws -> URL {
        var directory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        for _ in 0..<10 {
            let modulesURL = directory.appendingPathComponent("Modules", isDirectory: true)
            let moduleURL = modulesURL.appendingPathComponent("ForgePerformanceCore.swiftmodule")
            if FileManager.default.fileExists(atPath: moduleURL.path) {
                return modulesURL
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        throw NSError(
            domain: "ForgePerformanceStaticTrustBoundaryTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "ForgePerformanceCore module is missing from active SwiftPM test executable ancestry"]
        )
    }
}
