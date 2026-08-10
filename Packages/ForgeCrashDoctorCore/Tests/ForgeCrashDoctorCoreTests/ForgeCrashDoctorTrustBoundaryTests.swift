import Foundation
import XCTest
@testable import ForgeCrashDoctorCore

final class ForgeCrashDoctorTrustBoundaryTests: XCTestCase {
    func testExternalConsumerCannotMintTrustedRuntimeIncident() throws {
        let diagnostics = try typecheckExternalConsumer(named: "ForgeTrustedCrashBypass.swift", source: """
        import ForgeCrashDoctorCore
        func forgeTrust(_ incident: ForgeCrashIncident) throws {
            _ = try ForgeCrashTrustedIncident(authenticatedIncident: incident, artifactIdentity: String(repeating: "a", count: 64))
        }
        """)
        assertAccessControlDiagnostic(diagnostics)
    }

    func testExternalConsumerCannotMintTrustedRepairPolicy() throws {
        let diagnostics = try typecheckExternalConsumer(named: "ForgeTrustedPolicyBypass.swift", source: """
        import ForgeCrashDoctorCore
        func forgePolicy(_ policy: ForgeCrashRetryPolicy) throws {
            _ = try ForgeCrashTrustedRetryPolicy(authenticatedPolicy: policy, policyRevision: "policy-v1")
        }
        """)
        assertAccessControlDiagnostic(diagnostics)
    }

    func testExternalConsumerCannotMintTrustedFailedAttempt() throws {
        let diagnostics = try typecheckExternalConsumer(named: "ForgeTrustedAttemptBypass.swift", source: """
        import ForgeCrashDoctorCore
        func forgeAttempt(_ incident: ForgeCrashTrustedIncident) throws {
            _ = try ForgeCrashTrustedFailedAttempt(sequence: 1, trustedIncident: incident, failureKind: .sameCrashReturned)
        }
        """)
        assertAccessControlDiagnostic(diagnostics)
    }

    func testExternalConsumerCannotInvokePrivilegedTriage() throws {
        let diagnostics = try typecheckExternalConsumer(named: "ForgeTriageBypass.swift", source: """
        import ForgeCrashDoctorCore
        func bypass(_ incident: ForgeCrashTrustedIncident, _ control: ForgeCrashTrustedRepairControl) throws {
            _ = try ForgeCrashTriage.makeSubmission(for: incident, trustedControl: control)
        }
        """)
        assertAccessControlDiagnostic(diagnostics)
    }

    private func assertAccessControlDiagnostic(_ diagnostics: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(
            diagnostics.localizedCaseInsensitiveContains("inaccessible due to 'internal' protection level")
                || diagnostics.localizedCaseInsensitiveContains("is inaccessible"),
            "Expected ordinary imports to be blocked by module access control, got: \(diagnostics)",
            file: file,
            line: line
        )
    }

    private func typecheckExternalConsumer(named fileName: String, source: String) throws -> String {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-crash-doctor-trust-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let sourceURL = temporaryDirectory.appendingPathComponent(fileName)
        try source.write(to: sourceURL, atomically: true, encoding: .utf8)

        let modulesURL = try activeModulesURL()
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["swiftc", "-typecheck", "-swift-version", "6", "-I", modulesURL.path, sourceURL.path]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()

        let diagnostics = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertNotEqual(process.terminationStatus, 0, "External trust bypass unexpectedly compiled")
        XCTAssertFalse(
            diagnostics.localizedCaseInsensitiveContains("no such module 'forgecrashdoctorcore'"),
            "Trust probe failed before reaching ForgeCrashDoctorCore access control: \(diagnostics)"
        )
        return diagnostics
    }

    private func activeModulesURL() throws -> URL {
        let starts = [
            Bundle(for: ForgeCrashDoctorTrustBoundaryTests.self).bundleURL,
            URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent(),
        ]

        for start in starts {
            if let modules = findModules(startingAt: start) { return modules }
        }

        throw NSError(
            domain: "ForgeCrashDoctorTrustBoundaryTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "ForgeCrashDoctorCore module is missing from XCTest bundle and executable ancestry"]
        )
    }

    private func findModules(startingAt start: URL) -> URL? {
        var directory = start
        for _ in 0..<12 {
            let modulesURL = directory.appendingPathComponent("Modules", isDirectory: true)
            let moduleURL = modulesURL.appendingPathComponent("ForgeCrashDoctorCore.swiftmodule")
            if FileManager.default.fileExists(atPath: moduleURL.path) { return modulesURL }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        return nil
    }
}
