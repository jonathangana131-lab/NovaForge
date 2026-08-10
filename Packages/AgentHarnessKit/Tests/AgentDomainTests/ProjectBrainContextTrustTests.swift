import Foundation
import XCTest
@testable import AgentDomain

final class ProjectBrainContextTrustTests: XCTestCase {
    func testTrustedSnapshotBindsAuthorityIntoSelectedContext() throws {
        let projectID = ProjectID()
        let fact = makeFact(
            projectID: projectID,
            kind: .acceptedDecision,
            statement: "Keep the primary action reachable with one hand"
        )
        let snapshot = try ProjectBrainTrustedSnapshot(
            authenticatedProjectID: projectID,
            revision: 9,
            authorityReceiptID: "brain-receipt-9",
            facts: [fact]
        )

        let slice = try ProjectBrainContextSelector.select(
            from: snapshot,
            request: .init(projectID: projectID)
        )

        XCTAssertEqual(slice.snapshotRevision, 9)
        XCTAssertEqual(slice.snapshotAuthorityReceiptID, "brain-receipt-9")
        XCTAssertEqual(slice.facts, [fact])
    }

    func testTrustedSnapshotRejectsInvalidFactBeforeSelection() throws {
        let projectID = ProjectID()
        let invalid = ProjectBrainFact(
            factID: ProjectBrainFactID(),
            projectID: projectID,
            kind: .feature,
            statement: "Model-only guess",
            scope: .init(kind: .project),
            provenance: [
                .init(
                    kind: .modelObservation,
                    reference: "model:guess",
                    capturedAt: .init(rawValue: 1)
                ),
            ],
            lastVerifiedAt: .init(rawValue: 1)
        )

        XCTAssertThrowsError(
            try ProjectBrainTrustedSnapshot(
                authenticatedProjectID: projectID,
                revision: 1,
                authorityReceiptID: "brain-receipt",
                facts: [invalid]
            )
        ) { error in
            XCTAssertEqual(
                error as? ProjectBrainTrustedSnapshotError,
                .invalidFact(invalid.factID, .derivedOnlyProvenance)
            )
        }
    }

    func testTrustedSnapshotRejectsCrossProjectFacts() throws {
        let projectID = ProjectID()
        let foreign = makeFact(
            projectID: ProjectID(),
            kind: .feature,
            statement: "Foreign project fact"
        )

        XCTAssertThrowsError(
            try ProjectBrainTrustedSnapshot(
                authenticatedProjectID: projectID,
                revision: 1,
                authorityReceiptID: "brain-receipt",
                facts: [foreign]
            )
        ) { error in
            XCTAssertEqual(
                error as? ProjectBrainTrustedSnapshotError,
                .crossProjectFact(foreign.factID)
            )
        }
    }

    func testTrustedSnapshotRejectsDuplicateFactIdentity() throws {
        let projectID = ProjectID()
        let original = makeFact(
            projectID: projectID,
            kind: .feature,
            statement: "Original"
        )
        let duplicate = ProjectBrainFact(
            factID: original.factID,
            projectID: projectID,
            kind: .architecture,
            statement: "Conflicting duplicate",
            scope: .init(kind: .project),
            provenance: original.provenance,
            lastVerifiedAt: original.lastVerifiedAt
        )

        XCTAssertThrowsError(
            try ProjectBrainTrustedSnapshot(
                authenticatedProjectID: projectID,
                revision: 1,
                authorityReceiptID: "brain-receipt",
                facts: [original, duplicate]
            )
        ) { error in
            XCTAssertEqual(
                error as? ProjectBrainTrustedSnapshotError,
                .duplicateFactID(original.factID)
            )
        }
    }

    func testTrustedSnapshotRejectsInvalidRevisionAndReceiptIdentity() throws {
        let projectID = ProjectID()

        XCTAssertThrowsError(
            try ProjectBrainTrustedSnapshot(
                authenticatedProjectID: projectID,
                revision: 0,
                authorityReceiptID: "brain-receipt",
                facts: []
            )
        ) { error in
            XCTAssertEqual(error as? ProjectBrainTrustedSnapshotError, .invalidRevision)
        }

        XCTAssertThrowsError(
            try ProjectBrainTrustedSnapshot(
                authenticatedProjectID: projectID,
                revision: 1,
                authorityReceiptID: " padded ",
                facts: []
            )
        ) { error in
            XCTAssertEqual(error as? ProjectBrainTrustedSnapshotError, .invalidAuthorityReceiptID)
        }
    }

    func testTrustedSnapshotCannotSelectForDifferentProject() throws {
        let projectID = ProjectID()
        let snapshot = try ProjectBrainTrustedSnapshot(
            authenticatedProjectID: projectID,
            revision: 1,
            authorityReceiptID: "brain-receipt",
            facts: []
        )

        XCTAssertThrowsError(
            try ProjectBrainContextSelector.select(
                from: snapshot,
                request: .init(projectID: ProjectID())
            )
        ) { error in
            XCTAssertEqual(
                error as? ProjectBrainContextSelectionError,
                .trustedSnapshotProjectMismatch
            )
        }
    }

    func testStructuralUserDecisionFactStillRequiresSnapshotAuthentication() throws {
        let projectID = ProjectID()
        let callerShapedAcceptedDecision = ProjectBrainFact(
            factID: ProjectBrainFactID(),
            projectID: projectID,
            kind: .acceptedDecision,
            statement: "Caller claims the user accepted this",
            scope: .init(kind: .project),
            provenance: [
                .init(
                    kind: .userDecision,
                    reference: "caller-supplied-user-decision",
                    capturedAt: .init(rawValue: 1)
                ),
            ],
            lastVerifiedAt: .init(rawValue: 1)
        )

        XCTAssertNil(callerShapedAcceptedDecision.validationError)

        // @testable code can exercise the module-owned constructor, but ordinary importers cannot.
        // The static compiler test below proves that external candidate bytes cannot perform this
        // promotion themselves; a future host adapter must authenticate this complete subject first.
        let snapshot = try ProjectBrainTrustedSnapshot(
            authenticatedProjectID: projectID,
            revision: 1,
            authorityReceiptID: "host-authenticated-after-verification",
            facts: [callerShapedAcceptedDecision]
        )
        let slice = try ProjectBrainContextSelector.select(
            from: snapshot,
            request: .init(projectID: projectID)
        )
        XCTAssertEqual(slice.facts, [callerShapedAcceptedDecision])
    }

    func testExternalConsumerCannotMintSnapshotOrSelectRawFacts() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("project-brain-trust-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let sourceURL = temporaryDirectory.appendingPathComponent("ExternalProjectBrainMint.swift")
        try """
        import AgentDomain

        func attemptMint(
            projectID: ProjectID,
            fact: ProjectBrainFact,
            request: ProjectBrainContextRequest
        ) throws {
            _ = try ProjectBrainTrustedSnapshot(
                authenticatedProjectID: projectID,
                revision: 1,
                authorityReceiptID: "caller",
                facts: [fact]
            )
            _ = try ProjectBrainContextSelector.select(from: [fact], request: request)
        }
        """.write(to: sourceURL, atomically: true, encoding: .utf8)

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "swiftc",
            "-typecheck",
            "-swift-version",
            "6",
            "-I",
            try activeModulesURL().path,
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

        XCTAssertNotEqual(
            process.terminationStatus,
            0,
            "External Project Brain trust mint unexpectedly compiled"
        )
        XCTAssertFalse(
            diagnostics.localizedCaseInsensitiveContains("no such module 'AgentDomain'"),
            "Static boundary probe failed before reaching Project Brain access control: \(diagnostics)"
        )
        XCTAssertTrue(
            diagnostics.contains("ProjectBrainTrustedSnapshot")
                || diagnostics.contains("ProjectBrainContextSelector"),
            "Expected Project Brain trust-boundary diagnostic: \(diagnostics)"
        )
        XCTAssertTrue(
            diagnostics.localizedCaseInsensitiveContains("inaccessible")
                || diagnostics.localizedCaseInsensitiveContains("internal protection level")
                || diagnostics.localizedCaseInsensitiveContains("cannot convert value"),
            "Expected access/type rejection, got: \(diagnostics)"
        )
    }

    private func activeModulesURL() throws -> URL {
        let fileManager = FileManager.default
        let bundleURL = Bundle(for: ProjectBrainContextTrustTests.self).bundleURL
        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0])

        var roots = [
            bundleURL,
            bundleURL.deletingLastPathComponent(),
            executableURL.deletingLastPathComponent(),
        ]
        if bundleURL.pathExtension == "xctest" {
            roots.append(bundleURL.deletingLastPathComponent())
        }

        var visited = Set<String>()
        for root in roots {
            var cursor = root
            for _ in 0..<8 {
                if visited.insert(cursor.path).inserted {
                    let directModule = cursor.appendingPathComponent("AgentDomain.swiftmodule")
                    if fileManager.fileExists(atPath: directModule.path) {
                        return cursor
                    }
                    let modules = cursor.appendingPathComponent("Modules", isDirectory: true)
                    let nestedModule = modules.appendingPathComponent("AgentDomain.swiftmodule")
                    if fileManager.fileExists(atPath: nestedModule.path) {
                        return modules
                    }
                }
                let parent = cursor.deletingLastPathComponent()
                if parent.path == cursor.path { break }
                cursor = parent
            }
        }

        throw ProjectBrainTrustTestError.agentDomainModuleNotFound
    }

    private func makeFact(
        projectID: ProjectID,
        kind: ProjectBrainFactKind,
        statement: String
    ) -> ProjectBrainFact {
        ProjectBrainFact(
            factID: ProjectBrainFactID(),
            projectID: projectID,
            kind: kind,
            statement: statement,
            scope: .init(kind: .project),
            provenance: [
                .init(
                    kind: .sourceFile,
                    reference: "Sources/App.swift",
                    capturedAt: .init(rawValue: 1),
                    contentDigest: "sha256:test"
                ),
            ],
            lastVerifiedAt: .init(rawValue: 1)
        )
    }
}

private enum ProjectBrainTrustTestError: Error {
    case agentDomainModuleNotFound
}
