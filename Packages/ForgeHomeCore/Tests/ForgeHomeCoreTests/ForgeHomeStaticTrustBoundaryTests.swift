import Foundation
import XCTest
@testable import ForgeHomeCore

final class ForgeHomeStaticTrustBoundaryTests: XCTestCase {
    func testOrdinaryConsumerCannotMintTrustedHomeAuthority() throws {
        let moduleDirectory = try XCTUnwrap(findModuleDirectory())
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ForgeHomeTrustProbe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let probe = temporaryDirectory.appendingPathComponent("Probe.swift")
        try """
        import ForgeHomeCore

        func probe(
            mission: ForgeMissionReference,
            runtime: ForgeRuntimeEvidence,
            thumbnail: ForgeThumbnailEvidence,
            capabilities: ForgeCapabilityClaim
        ) throws {
            _ = ForgeTrustedMissionReference(authenticatedCandidate: mission)
            _ = try ForgeTrustedRuntimeEvidence(authenticatedCandidate: runtime)
            _ = try ForgeTrustedThumbnailEvidence(authenticatedCandidate: thumbnail)
            _ = ForgeTrustedCapabilityClaim(authenticatedCandidate: capabilities)
        }
        """.write(to: probe, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["swiftc", "-typecheck", "-I", moduleDirectory.path, probe.path]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let diagnostic = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        XCTAssertNotEqual(process.terminationStatus, 0, "External consumer unexpectedly minted trusted authority")
        XCTAssertTrue(
            diagnostic.contains("inaccessible due to 'internal' protection level") ||
                diagnostic.contains("is inaccessible due to 'internal' protection level") ||
                diagnostic.contains("'init(authenticatedCandidate:)' is inaccessible"),
            "Expected access-control failure, got: \(diagnostic)"
        )
        XCTAssertFalse(diagnostic.contains("no such module 'ForgeHomeCore'"), diagnostic)
    }

    private func findModuleDirectory() -> URL? {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        var directory = executable.deletingLastPathComponent()
        for _ in 0..<5 {
            let candidate = directory.appendingPathComponent("Modules", isDirectory: true)
            let module = candidate.appendingPathComponent("ForgeHomeCore.swiftmodule", isDirectory: true)
            if FileManager.default.fileExists(atPath: module.path) {
                return candidate
            }
            directory.deleteLastPathComponent()
        }
        return nil
    }
}
