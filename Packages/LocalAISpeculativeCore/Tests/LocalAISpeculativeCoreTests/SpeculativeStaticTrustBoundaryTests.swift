import Foundation
import XCTest
import LocalAISpeculativeCore

final class SpeculativeStaticTrustBoundaryTests: XCTestCase {
    func testExternalConsumerCannotMintDerivedComparisonAssessment() throws {
        let diagnostics = try typecheckExternalConsumer(
            named: "MintAssessment.swift",
            source: """
            import LocalAISpeculativeCore

            let forged = SpeculativeComparisonAssessment(
                isLatencyCandidate: true,
                rejections: [],
                measuredSpeedupRatio: 99
            )
            _ = forged
            """
        )

        XCTAssertTrue(
            diagnostics.localizedCaseInsensitiveContains("initializer is inaccessible")
                || diagnostics.localizedCaseInsensitiveContains("inaccessible due to 'fileprivate'"),
            "Expected derived assessment construction to be inaccessible, got: \(diagnostics)"
        )
    }

    func testExternalConsumerCannotSerializeDerivedComparisonAssessment() throws {
        let diagnostics = try typecheckExternalConsumer(
            named: "SerializeAssessment.swift",
            source: """
            import Foundation
            import LocalAISpeculativeCore

            func persist(_ assessment: SpeculativeComparisonAssessment) throws -> Data {
                try JSONEncoder().encode(assessment)
            }
            """
        )

        XCTAssertTrue(
            diagnostics.localizedCaseInsensitiveContains("requires that 'speculativecomparisonassessment' conform to 'encodable'")
                || diagnostics.localizedCaseInsensitiveContains("does not conform to protocol 'encodable'"),
            "Expected derived assessment to remain non-Encodable, got: \(diagnostics)"
        )
    }

    private func typecheckExternalConsumer(
        named fileName: String,
        source: String
    ) throws -> String {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-ai-speculative-trust-\(UUID().uuidString)", isDirectory: true)
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

        XCTAssertNotEqual(process.terminationStatus, 0, "External speculative trust bypass unexpectedly compiled")
        XCTAssertFalse(
            diagnostics.localizedCaseInsensitiveContains("no such module 'localaispeculativecore'"),
            "Static boundary probe failed before reaching the speculative API: \(diagnostics)"
        )
        return diagnostics
    }

    private func activeModulesURL() throws -> URL {
        let executableDirectory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let searchAnchors = [
            Bundle(for: SpeculativeStaticTrustBoundaryTests.self).bundleURL,
            executableDirectory,
        ]
        var visitedDirectories = Set<String>()

        for anchor in searchAnchors {
            var directory = anchor
            for _ in 0..<12 {
                if visitedDirectories.insert(directory.standardizedFileURL.path).inserted {
                    let modulesURL = directory.appendingPathComponent("Modules", isDirectory: true)
                    let moduleURL = modulesURL.appendingPathComponent("LocalAISpeculativeCore.swiftmodule")
                    if FileManager.default.fileExists(atPath: moduleURL.path) {
                        return modulesURL
                    }
                }

                let parent = directory.deletingLastPathComponent()
                if parent.path == directory.path {
                    break
                }
                directory = parent
            }
        }

        throw NSError(
            domain: "SpeculativeStaticTrustBoundaryTests",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "LocalAISpeculativeCore module is missing from the active SwiftPM test bundle and executable ancestry"
            ]
        )
    }
}
