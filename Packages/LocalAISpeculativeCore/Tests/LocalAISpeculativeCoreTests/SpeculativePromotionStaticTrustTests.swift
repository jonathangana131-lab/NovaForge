import Foundation
import XCTest

final class SpeculativePromotionStaticTrustTests: XCTestCase {
    func testOrdinaryConsumerCannotMintTrustedPromotionAuthority() throws {
        let cases: [(name: String, source: String, expectedSymbol: String)] = [
            (
                "trusted-evidence-init",
                """
                import LocalAISpeculativeCore

                _ = SpeculativeTrustedPromotionEvidence(
                    configuration: fatalError(),
                    declaration: fatalError(),
                    receipt: fatalError()
                )
                """,
                "SpeculativeTrustedPromotionEvidence"
            ),
            (
                "direct-candidate-evaluator",
                """
                import LocalAISpeculativeCore

                _ = SpeculativePromotionEvaluator.evaluate(
                    configuration: fatalError(),
                    declaration: fatalError(),
                    receipt: fatalError()
                )
                """,
                "evaluate"
            ),
            (
                "promotion-result-init",
                """
                import LocalAISpeculativeCore

                _ = SpeculativePromotionResult(
                    isPromotable: true,
                    rejections: [],
                    measuredSpeedupRatio: 2.0
                )
                """,
                "SpeculativePromotionResult"
            ),
            (
                "promotion-result-decode",
                """
                import LocalAISpeculativeCore

                func requiresDecodable<T: Decodable>(_: T.Type) {}
                requiresDecodable(SpeculativePromotionResult.self)
                """,
                "SpeculativePromotionResult"
            ),
        ]

        let modulesURL = try activeModulesURL()
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "novaforge-speculative-promotion-trust-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        for misuse in cases {
            let sourceURL = temporaryDirectory
                .appendingPathComponent("\(misuse.name).swift")
            try misuse.source.write(to: sourceURL, atomically: true, encoding: .utf8)

            let process = Process()
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
            let diagnosticsPipe = Pipe()
            process.standardOutput = diagnosticsPipe
            process.standardError = diagnosticsPipe

            try process.run()
            process.waitUntilExit()
            let diagnostics = String(
                decoding: diagnosticsPipe.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )

            XCTAssertNotEqual(
                process.terminationStatus,
                0,
                "ordinary consumer unexpectedly compiled \(misuse.name)"
            )
            XCTAssertFalse(
                diagnostics.contains("no such module 'LocalAISpeculativeCore'"),
                "probe failed before reaching the promotion trust boundary: \(diagnostics)"
            )
            XCTAssertTrue(
                diagnostics.contains(misuse.expectedSymbol),
                "probe did not fail at the intended promotion API for \(misuse.name): \(diagnostics)"
            )
        }
    }

    private func activeModulesURL() throws -> URL {
        let anchors = [
            Bundle(for: SpeculativePromotionStaticTrustTests.self).bundleURL,
            URL(fileURLWithPath: CommandLine.arguments[0]),
        ]

        for anchor in anchors {
            var directory = anchor.deletingLastPathComponent()
            for _ in 0..<10 {
                let modulesURL = directory.appendingPathComponent("Modules", isDirectory: true)
                let moduleURL = modulesURL
                    .appendingPathComponent("LocalAISpeculativeCore.swiftmodule")
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
            domain: "SpeculativePromotionStaticTrustTests",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "LocalAISpeculativeCore module is missing from the active SwiftPM test bundle/executable ancestry"
            ]
        )
    }
}
