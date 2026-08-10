import Foundation
import XCTest
@testable import ContinuityCore

final class ContinuityStaticTrustBoundaryTests: XCTestCase {
    func testExternalConsumerCannotMintExecutionGrant() throws {
        let diagnostics = try typecheckExternalConsumer(
            named: "MintExecutionGrant.swift",
            source: """
            import ContinuityCore

            let identity = ContinuityIdentity(
                missionID: "mission-1",
                projectID: "project-1",
                checkpointID: "checkpoint-1",
                missionRevision: 1
            )
            let _ = ContinuityExecutionGrant(
                identity: identity,
                mode: .verifiedCloud,
                authorityReceiptID: "forged"
            )
            """
        )

        XCTAssertTrue(
            diagnostics.localizedCaseInsensitiveContains("inaccessible due to 'internal' protection level")
                || diagnostics.localizedCaseInsensitiveContains("initializer is inaccessible"),
            "Expected external execution-grant construction to fail on access control, got: \(diagnostics)"
        )
    }

    func testExternalConsumerCannotMintMissionAuthority() throws {
        let diagnostics = try typecheckExternalConsumer(
            named: "MintMissionAuthority.swift",
            source: """
            import ContinuityCore

            let identity = ContinuityIdentity(
                missionID: "mission-1",
                projectID: "project-1",
                checkpointID: "checkpoint-1",
                missionRevision: 1
            )
            let _ = ContinuityMissionAuthority(
                identity: identity,
                purpose: .stateProjection(.completed),
                authorityReceiptID: "forged"
            )
            """
        )

        XCTAssertTrue(
            diagnostics.localizedCaseInsensitiveContains("inaccessible due to 'internal' protection level")
                || diagnostics.localizedCaseInsensitiveContains("initializer is inaccessible"),
            "Expected external Mission-authority construction to fail on access control, got: \(diagnostics)"
        )
    }

    func testExternalConsumerCannotMintTerminalSnapshot() throws {
        let diagnostics = try typecheckExternalConsumer(
            named: "MintTerminalSnapshot.swift",
            source: """
            import ContinuityCore

            let identity = ContinuityIdentity(
                missionID: "mission-1",
                projectID: "project-1",
                checkpointID: "checkpoint-1",
                missionRevision: 1
            )
            let _ = ContinuitySnapshot(identity: identity, state: .completed, epoch: 1)
            """
        )

        XCTAssertTrue(
            diagnostics.localizedCaseInsensitiveContains("extra argument 'state'")
                || diagnostics.localizedCaseInsensitiveContains("extra argument"),
            "Expected external terminal snapshot construction to be unavailable, got: \(diagnostics)"
        )
    }

    func testExternalConsumerCannotSeedReplayEpoch() throws {
        let diagnostics = try typecheckExternalConsumer(
            named: "SeedReplayEpoch.swift",
            source: """
            import ContinuityCore

            let identity = ContinuityIdentity(
                missionID: "mission-1",
                projectID: "project-1",
                checkpointID: "checkpoint-1",
                missionRevision: 1
            )
            let _ = ContinuitySnapshot(identity: identity, epoch: 99)
            """
        )

        XCTAssertTrue(
            diagnostics.localizedCaseInsensitiveContains("extra argument 'epoch'")
                || diagnostics.localizedCaseInsensitiveContains("extra argument"),
            "Expected external replay-epoch seeding to be unavailable, got: \(diagnostics)"
        )
    }

    func testExternalConsumerCannotSerializeLiveSnapshot() throws {
        let diagnostics = try typecheckExternalConsumer(
            named: "EncodeLiveSnapshot.swift",
            source: """
            import Foundation
            import ContinuityCore

            let identity = ContinuityIdentity(
                missionID: "mission-1",
                projectID: "project-1",
                checkpointID: "checkpoint-1",
                missionRevision: 1
            )
            let snapshot = ContinuitySnapshot(identity: identity)
            let _ = try JSONEncoder().encode(snapshot)
            """
        )

        XCTAssertTrue(
            diagnostics.localizedCaseInsensitiveContains("continuitysnapshot")
                && diagnostics.localizedCaseInsensitiveContains("encodable"),
            "Expected live snapshot serialization to fail because ContinuitySnapshot is not Encodable, got: \(diagnostics)"
        )
    }

    private func typecheckExternalConsumer(named fileName: String, source: String) throws -> String {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("continuity-static-trust-\(UUID().uuidString)", isDirectory: true)
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

        let diagnostics = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertNotEqual(process.terminationStatus, 0, "External trust bypass unexpectedly compiled")
        XCTAssertFalse(
            diagnostics.localizedCaseInsensitiveContains("no such module 'continuitycore'"),
            "Static boundary probe failed before reaching ContinuityCore: \(diagnostics)"
        )
        return diagnostics
    }

    private func activeModulesURL() throws -> URL {
        let anchors = [
            Bundle(for: ContinuityStaticTrustBoundaryTests.self).bundleURL,
            URL(fileURLWithPath: CommandLine.arguments[0]),
        ]

        for anchor in anchors {
            var directory = anchor.deletingLastPathComponent()

            for _ in 0..<10 {
                let modulesURL = directory.appendingPathComponent("Modules", isDirectory: true)
                let moduleURL = modulesURL.appendingPathComponent("ContinuityCore.swiftmodule")
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
            domain: "ContinuityStaticTrustBoundaryTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "ContinuityCore module is missing from active SwiftPM test bundle/executable ancestry"]
        )
    }
}
