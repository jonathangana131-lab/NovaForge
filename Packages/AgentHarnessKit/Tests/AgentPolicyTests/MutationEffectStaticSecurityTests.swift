@testable import AgentPolicy
import Foundation
import XCTest

final class MutationEffectStaticSecurityTests: XCTestCase {
    func testMoveOnlyAuthoritiesRejectCopyEscapeAtCompileTime() throws {
        let packageRoot = packageRootURL()
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "novaforge-move-only-compile-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let cases: [(name: String, source: String)] = [
            (
                "ClaimedPermitDoubleConsume",
                """
                import AgentPolicy
                func sink(_ value: consuming ClaimedToolEffectPermit) {}
                func misuse(_ value: consuming ClaimedToolEffectPermit) {
                    sink(value)
                    sink(value)
                }
                """
            ),
            (
                "QueueLeaseDoubleConsume",
                """
                import AgentPolicy
                func sink(_ value: consuming WorkspaceMutationQueueLease) {}
                func misuse(_ value: consuming WorkspaceMutationQueueLease) {
                    sink(value)
                    sink(value)
                }
                """
            ),
            (
                "BorrowedAuthorizationConsume",
                """
                import AgentPolicy
                func sink(
                    _ value: consuming MutationEffectApplicationAuthorization
                ) {}
                func misuse(
                    _ value: borrowing MutationEffectApplicationAuthorization
                ) {
                    sink(value)
                }
                """
            ),
            (
                "BorrowedAuthorizationEscape",
                """
                import AgentPolicy
                func misuse(
                    _ value: borrowing MutationEffectApplicationAuthorization
                ) -> MutationEffectApplicationAuthorization {
                    consume value
                }
                """
            ),
        ]

        for misuse in cases {
            let result = try compileMisuse(
                misuse,
                packageRoot: packageRoot,
                temporaryDirectory: temporaryDirectory
            )
            XCTAssertNotEqual(
                result.status,
                0,
                "\(misuse.name) unexpectedly compiled"
            )
            XCTAssertTrue(
                result.diagnostics.contains("consumed more than once")
                    || result.diagnostics.contains("noncopyable")
                    || result.diagnostics.contains(
                        "borrowed value cannot be consumed"
                    )
                    || result.diagnostics.contains(
                        "borrowed and cannot be consumed"
                    )
                    || result.diagnostics.contains("does not live long enough"),
                "\(misuse.name): \(result.diagnostics)"
            )
        }
    }

    func testGatewaySourceHasNoPublicMutationBypassOrPlaintextLogging()
        throws
    {
        let sourceURL = packageRootURL().appendingPathComponent(
            "Sources/AgentPolicy/MutationEffectGateway.swift"
        )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains(
            "_ claimedPermit: consuming ClaimedToolEffectPermit"
        ))
        XCTAssertTrue(source.contains(
            "authorization: borrowing MutationEffectApplicationAuthorization"
        ))
        XCTAssertFalse(source.contains("fifo: WorkspaceMutationFIFOCoordinator"))
        XCTAssertFalse(source.contains("public init(\n        tool:"))
        XCTAssertFalse(source.contains("public func apply(\n        _ permit: ToolEffectPermit"))
        XCTAssertFalse(source.contains("public func apply(\n        _ operation: MutationEffectOperation"))
        XCTAssertFalse(source.contains("MutationEffectApprovalPreview: Codable"))
        XCTAssertFalse(source.contains("print("))
        XCTAssertFalse(source.contains("NSLog"))
        XCTAssertFalse(source.contains("os_log"))
        XCTAssertFalse(source.contains("Logger("))

        let applyingProtocol = try XCTUnwrap(source.range(
            of: "public protocol MutationEffectApplying"
        ))
        let clockProtocol = try XCTUnwrap(source.range(
            of: "public protocol MutationEffectSynchronousClock"
        ))
        let applyingRange = (
            applyingProtocol.lowerBound..<clockProtocol.lowerBound
        )
        let applyingSource = source[applyingRange]
        XCTAssertFalse(applyingSource.contains("async"))
    }

    func testOriginSelectionHasNoPublicScalarRequestAPI() throws {
        let source = try String(
            contentsOf: packageRootURL().appendingPathComponent(
                "Sources/AgentPolicy/RiskPolicy.swift"
            ),
            encoding: .utf8
        )
        XCTAssertFalse(source.contains(
            "public static func resolve(\n        origin: MutationOrigin"
        ))
        XCTAssertFalse(source.contains(
            "public static func resolveNonProvider"
        ))
        XCTAssertTrue(source.contains("private static func resolveBound("))
        XCTAssertTrue(source.contains(
            "private static func resolveNonProviderBound("
        ))
        XCTAssertTrue(source.contains(
            "private static func resolveCanonicalProviderBound("
        ))
        for entryPoint in [
            "resolveAgentV2", "resolveV1Fallback", "resolveEditor",
            "resolveFiles", "resolveTerminal", "resolveArtifact",
            "resolveControl", "resolveProjectOS", "resolveTrustedSystem",
        ] {
            XCTAssertTrue(source.contains("public static func \(entryPoint)("))
        }

        let operationsSource = try String(
            contentsOf: packageRootURL().appendingPathComponent(
                "Sources/AgentPolicy/MutationOriginAndNonProviderOperations.swift"
            ),
            encoding: .utf8
        )
        XCTAssertFalse(operationsSource.contains(
            "public enum NonProviderMutationOperation"
        ))
        XCTAssertFalse(operationsSource.contains(
            "public enum TerminalPolicyMutationOperation"
        ))
        XCTAssertFalse(operationsSource.contains(
            "public enum ArtifactPolicyMutationOperation"
        ))
    }

    func testOriginSpecificOperationTypesRejectCrossSurfaceCasesAtCompileTime()
        throws
    {
        let packageRoot = packageRootURL()
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "novaforge-origin-contract-compile-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let cases: [(name: String, source: String)] = [
            (
                "EditorCannotReset",
                """
                import AgentPolicy
                let value: EditorPolicyMutationOperation =
                    .resetWorkspace(.init())
                """
            ),
            (
                "FilesCannotSeed",
                """
                import AgentPolicy
                let value: FilesPolicyMutationOperation =
                    .seedWorkspace(.init(entries: []))
                """
            ),
            (
                "ControlCannotSeed",
                """
                import AgentPolicy
                let value: ControlPolicyMutationOperation =
                    .seedWorkspace(.init(entries: []))
                """
            ),
            (
                "ProjectOSCannotCreate",
                """
                import AgentPolicy
                let value: ProjectOSPolicyMutationOperation =
                    .createFile(.init(path: "a"))
                """
            ),
            (
                "TerminalCannotWrite",
                """
                import AgentPolicy
                import AgentTools
                let value: TerminalCanonicalMutationOperation =
                    .writeFile(.init(path: "a", contents: ""))
                """
            ),
            (
                "ArtifactCannotDelete",
                """
                import AgentPolicy
                import AgentTools
                let value: ArtifactCanonicalMutationOperation =
                    .deletePath(.init(path: "a"))
                """
            ),
            (
                "GenericPolicyOperationIsSealed",
                """
                import AgentPolicy
                let value: NonProviderMutationOperation? = nil
                """
            ),
        ]

        for misuse in cases {
            let result = try compileMisuse(
                misuse,
                packageRoot: packageRoot,
                temporaryDirectory: temporaryDirectory
            )
            XCTAssertNotEqual(
                result.status,
                0,
                "\(misuse.name) unexpectedly compiled"
            )
            XCTAssertTrue(
                result.diagnostics.contains("has no member")
                    || result.diagnostics.contains("cannot find type")
                    || result.diagnostics.contains("inaccessible")
                    || result.diagnostics.contains("internal protection level"),
                "\(misuse.name): \(result.diagnostics)"
            )
        }
    }

    private func packageRootURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func compileMisuse(
        _ misuse: (name: String, source: String),
        packageRoot: URL,
        temporaryDirectory: URL
    ) throws -> (status: Int32, diagnostics: String) {
        let sourceURL = temporaryDirectory.appendingPathComponent(
            "\(misuse.name).swift"
        )
        try misuse.source.write(
            to: sourceURL,
            atomically: true,
            encoding: .utf8
        )
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "swiftc",
            "-emit-sil",
            "-swift-version",
            "6",
            "-I",
            packageRoot.appendingPathComponent(".build/debug/Modules").path,
            "-o",
            "/dev/null",
            sourceURL.path,
        ]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return (
            process.terminationStatus,
            String(decoding: data, as: UTF8.self)
        )
    }
}
