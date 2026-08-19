import Foundation
import XCTest
@testable import LocalAIBenchmarkCore

final class LocalAIBenchmarkFixtureBridgeTests: XCTestCase {
    func testCanonicalV1CorpusExportDecodesAsAcceptedBenchmarkSuite() throws {
        let repositoryRoot = try findRepositoryRoot()
        let validatorURL = repositoryRoot
            .appendingPathComponent("scripts", isDirectory: true)
            .appendingPathComponent("validate-v14-local-ai-benchmark-fixtures.py")
        let fixtureRoot = repositoryRoot
            .appendingPathComponent("Benchmarks", isDirectory: true)
            .appendingPathComponent("LocalAI", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)

        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "python3",
            validatorURL.path,
            fixtureRoot.path,
            "--suite-json",
        ]
        process.currentDirectoryURL = repositoryRoot
        process.standardOutput = standardOutput
        process.standardError = standardError

        try process.run()
        process.waitUntilExit()

        let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let diagnostics = String(
            decoding: standardError.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        XCTAssertEqual(
            process.terminationStatus,
            0,
            "Canonical fixture validator failed before Swift-domain decode: \(diagnostics)"
        )

        let suite = try JSONDecoder().decode(LocalAIBenchmarkSuite.self, from: output)
        XCTAssertEqual(suite.id, "novaforge.local-ai.general-agent")
        XCTAssertEqual(suite.version, 1)
        XCTAssertEqual(suite.tasks.count, 8)
        XCTAssertEqual(
            suite.tasks.map(\.id),
            [
                "01-intent-routing",
                "02-structured-extraction",
                "03-structured-tool-use",
                "04-repository-navigation",
                "05-code-repair",
                "06-multi-file-change",
                "07-context-compaction",
                "08-continuation-recovery",
            ]
        )
        XCTAssertEqual(
            suite.requiredCategories,
            [
                .intentRouting,
                .structuredToolUse,
                .repositoryNavigation,
                .codeRepair,
                .contextCompaction,
                .continuationRecovery,
            ]
        )
        XCTAssertTrue(suite.tasks.allSatisfy { $0.revision > 0 })
        XCTAssertTrue(suite.tasks.allSatisfy { $0.fixtureDigest.count == 64 })
    }

    private func findRepositoryRoot() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

        for _ in 0..<10 {
            let manifest = directory
                .appendingPathComponent("Benchmarks", isDirectory: true)
                .appendingPathComponent("LocalAI", isDirectory: true)
                .appendingPathComponent("v1", isDirectory: true)
                .appendingPathComponent("manifest.json")
            if FileManager.default.fileExists(atPath: manifest.path) {
                return directory
            }

            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path {
                break
            }
            directory = parent
        }

        throw NSError(
            domain: "LocalAIBenchmarkFixtureBridgeTests",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Could not locate repository root containing Benchmarks/LocalAI/v1/manifest.json"
            ]
        )
    }
}
