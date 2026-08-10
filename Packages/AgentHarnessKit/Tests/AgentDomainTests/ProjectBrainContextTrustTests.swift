import Foundation
import XCTest
@testable import AgentDomain

final class ProjectBrainContextTrustTests: XCTestCase {
    func testTrustedSnapshotAndCurrentAuthorityBindExactSourceIntoSelectedContext() throws {
        let projectID = ProjectID()
        let identity = try sourceIdentity()
        let fact = makeFact(
            projectID: projectID,
            kind: .acceptedDecision,
            statement: "Keep the primary action reachable with one hand"
        )
        let snapshot = try trustedSnapshot(
            projectID: projectID,
            identity: identity,
            brainRevision: 9,
            receiptID: "brain-receipt-9",
            digest: "sha256:whole-snapshot-9",
            facts: [fact]
        )
        let currentAuthority = try trustedCurrentAuthority(
            projectID: projectID,
            identity: identity,
            receiptID: "current-source-receipt-9"
        )

        let slice = try ProjectBrainContextSelector.select(
            from: snapshot,
            currentAuthority: currentAuthority,
            request: .init(projectID: projectID)
        )

        XCTAssertEqual(slice.snapshotBrainRevision, 9)
        XCTAssertEqual(slice.sourceIdentity, identity)
        XCTAssertEqual(slice.snapshotAuthorityReceiptID, "brain-receipt-9")
        XCTAssertEqual(slice.currentSourceAuthorityReceiptID, "current-source-receipt-9")
        XCTAssertEqual(slice.snapshotDigest, "sha256:whole-snapshot-9")
        XCTAssertTrue(slice.isTrustedSnapshotBound)
        XCTAssertEqual(slice.facts, [fact])
    }

    func testSourceIdentityDriftFailsClosedWithSameProjectFactsAndBrainRevision() throws {
        let projectID = ProjectID()
        let accepted = try sourceIdentity(
            acceptedProjectStateID: "project-state-A",
            checkpointReferenceID: "checkpoint-A",
            projectRootRevisionID: "source-revision-A"
        )
        let current = try sourceIdentity(
            acceptedProjectStateID: "project-state-B",
            checkpointReferenceID: "checkpoint-B",
            projectRootRevisionID: "source-revision-B"
        )
        let fact = makeFact(
            projectID: projectID,
            kind: .sourceStructure,
            statement: "This source fact still says current"
        )
        let snapshot = try trustedSnapshot(
            projectID: projectID,
            identity: accepted,
            brainRevision: 4,
            receiptID: "brain-receipt",
            digest: "sha256:old-source-snapshot",
            facts: [fact]
        )
        let currentAuthority = try trustedCurrentAuthority(
            projectID: projectID,
            identity: current,
            receiptID: "current-source-receipt"
        )

        XCTAssertThrowsError(
            try ProjectBrainContextSelector.select(
                from: snapshot,
                currentAuthority: currentAuthority,
                request: .init(projectID: projectID)
            )
        ) { error in
            XCTAssertEqual(
                error as? ProjectBrainContextSelectionError,
                .trustedSnapshotSourceMismatch
            )
        }
    }

    func testSnapshotCannotSelfValidateByCopyingPublicSourceIdentity() throws {
        let projectID = ProjectID()
        let staleIdentity = try sourceIdentity(
            acceptedProjectStateID: "old-state",
            checkpointReferenceID: "old-checkpoint",
            projectRootRevisionID: "old-root"
        )
        let currentIdentity = try sourceIdentity(
            acceptedProjectStateID: "new-state",
            checkpointReferenceID: "new-checkpoint",
            projectRootRevisionID: "new-root"
        )
        let snapshot = try trustedSnapshot(
            projectID: projectID,
            identity: staleIdentity,
            facts: []
        )
        XCTAssertEqual(snapshot.sourceIdentity, staleIdentity)

        let currentAuthority = try trustedCurrentAuthority(
            projectID: projectID,
            identity: currentIdentity
        )
        XCTAssertThrowsError(
            try ProjectBrainContextSelector.select(
                from: snapshot,
                currentAuthority: currentAuthority,
                request: .init(projectID: projectID)
            )
        ) { error in
            XCTAssertEqual(
                error as? ProjectBrainContextSelectionError,
                .trustedSnapshotSourceMismatch
            )
        }
    }

    func testSnapshotDigestDistinguishesOtherwiseMatchingAuthorityMetadata() throws {
        let projectID = ProjectID()
        let identity = try sourceIdentity()
        let fact = makeFact(
            projectID: projectID,
            kind: .feature,
            statement: "Feature"
        )
        let first = try trustedSnapshot(
            projectID: projectID,
            identity: identity,
            brainRevision: 2,
            receiptID: "same-receipt",
            digest: "sha256:snapshot-A",
            facts: [fact]
        )
        let second = try trustedSnapshot(
            projectID: projectID,
            identity: identity,
            brainRevision: 2,
            receiptID: "same-receipt",
            digest: "sha256:snapshot-B",
            facts: [fact]
        )

        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(first.snapshotDigest, second.snapshotDigest)
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
            try trustedSnapshot(
                projectID: projectID,
                identity: sourceIdentity(),
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
            try trustedSnapshot(
                projectID: projectID,
                identity: sourceIdentity(),
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
            try trustedSnapshot(
                projectID: projectID,
                identity: sourceIdentity(),
                facts: [original, duplicate]
            )
        ) { error in
            XCTAssertEqual(
                error as? ProjectBrainTrustedSnapshotError,
                .duplicateFactID(original.factID)
            )
        }
    }

    func testTrustedSnapshotRejectsInvalidBrainRevisionReceiptAndDigest() throws {
        let projectID = ProjectID()
        let identity = try sourceIdentity()

        XCTAssertThrowsError(
            try ProjectBrainTrustedSnapshot(
                authenticatedProjectID: projectID,
                brainRevision: 0,
                sourceIdentity: identity,
                authorityReceiptID: "brain-receipt",
                snapshotDigest: "sha256:snapshot",
                facts: []
            )
        ) { error in
            XCTAssertEqual(error as? ProjectBrainTrustedSnapshotError, .invalidBrainRevision)
        }

        XCTAssertThrowsError(
            try ProjectBrainTrustedSnapshot(
                authenticatedProjectID: projectID,
                brainRevision: 1,
                sourceIdentity: identity,
                authorityReceiptID: " padded ",
                snapshotDigest: "sha256:snapshot",
                facts: []
            )
        ) { error in
            XCTAssertEqual(error as? ProjectBrainTrustedSnapshotError, .invalidAuthorityReceiptID)
        }

        XCTAssertThrowsError(
            try ProjectBrainTrustedSnapshot(
                authenticatedProjectID: projectID,
                brainRevision: 1,
                sourceIdentity: identity,
                authorityReceiptID: "brain-receipt",
                snapshotDigest: " padded ",
                facts: []
            )
        ) { error in
            XCTAssertEqual(error as? ProjectBrainTrustedSnapshotError, .invalidSnapshotDigest)
        }
    }

    func testTrustedCurrentAuthorityRejectsInvalidReceipt() throws {
        XCTAssertThrowsError(
            try ProjectBrainTrustedSelectionAuthority(
                authenticatedProjectID: ProjectID(),
                sourceIdentity: sourceIdentity(),
                authorityReceiptID: " padded "
            )
        ) { error in
            XCTAssertEqual(
                error as? ProjectBrainTrustedSelectionAuthorityError,
                .invalidAuthorityReceiptID
            )
        }
    }

    func testSourceIdentityRejectsNonCanonicalComponents() throws {
        XCTAssertThrowsError(
            try ProjectBrainSourceIdentity(
                acceptedProjectStateID: " state ",
                checkpointReferenceID: "checkpoint",
                projectRootRevisionID: "revision"
            )
        ) { error in
            XCTAssertEqual(
                error as? ProjectBrainSourceIdentityError,
                .invalidAcceptedProjectStateID
            )
        }

        XCTAssertThrowsError(
            try ProjectBrainSourceIdentity(
                acceptedProjectStateID: "state",
                checkpointReferenceID: "check\u{0000}point",
                projectRootRevisionID: "revision"
            )
        ) { error in
            XCTAssertEqual(
                error as? ProjectBrainSourceIdentityError,
                .invalidCheckpointReferenceID
            )
        }

        XCTAssertThrowsError(
            try ProjectBrainSourceIdentity(
                acceptedProjectStateID: "state",
                checkpointReferenceID: "checkpoint",
                projectRootRevisionID: ""
            )
        ) { error in
            XCTAssertEqual(
                error as? ProjectBrainSourceIdentityError,
                .invalidProjectRootRevisionID
            )
        }
    }

    func testTrustedSnapshotCannotSelectForDifferentProject() throws {
        let projectID = ProjectID()
        let identity = try sourceIdentity()
        let snapshot = try trustedSnapshot(
            projectID: projectID,
            identity: identity,
            facts: []
        )
        let authority = try trustedCurrentAuthority(
            projectID: projectID,
            identity: identity
        )

        XCTAssertThrowsError(
            try ProjectBrainContextSelector.select(
                from: snapshot,
                currentAuthority: authority,
                request: .init(projectID: ProjectID())
            )
        ) { error in
            XCTAssertEqual(
                error as? ProjectBrainContextSelectionError,
                .trustedSnapshotProjectMismatch
            )
        }
    }

    func testTrustedCurrentAuthorityCannotSelectForDifferentProject() throws {
        let projectID = ProjectID()
        let identity = try sourceIdentity()
        let snapshot = try trustedSnapshot(
            projectID: projectID,
            identity: identity,
            facts: []
        )
        let foreignAuthority = try trustedCurrentAuthority(
            projectID: ProjectID(),
            identity: identity
        )

        XCTAssertThrowsError(
            try ProjectBrainContextSelector.select(
                from: snapshot,
                currentAuthority: foreignAuthority,
                request: .init(projectID: projectID)
            )
        ) { error in
            XCTAssertEqual(
                error as? ProjectBrainContextSelectionError,
                .trustedSelectionAuthorityProjectMismatch
            )
        }
    }

    func testStructuralUserDecisionFactStillRequiresSnapshotAndCurrentSourceAuthority() throws {
        let projectID = ProjectID()
        let identity = try sourceIdentity()
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

        // @testable code can exercise module-owned constructors, but ordinary importers cannot.
        // Independent compiler probes below prove external candidate bytes cannot mint either
        // authority capability or bypass them by selecting raw fact arrays.
        let snapshot = try trustedSnapshot(
            projectID: projectID,
            identity: identity,
            receiptID: "host-authenticated-after-verification",
            digest: "sha256:authenticated-whole-snapshot",
            facts: [callerShapedAcceptedDecision]
        )
        let authority = try trustedCurrentAuthority(
            projectID: projectID,
            identity: identity,
            receiptID: "host-current-source-verification"
        )
        let slice = try ProjectBrainContextSelector.select(
            from: snapshot,
            currentAuthority: authority,
            request: .init(projectID: projectID)
        )
        XCTAssertEqual(slice.facts, [callerShapedAcceptedDecision])
        XCTAssertTrue(slice.isTrustedSnapshotBound)
    }

    func testExternalConsumerCannotMintTrustedSnapshot() throws {
        try assertExternalCompilationFails(
            sourceName: "ExternalProjectBrainSnapshotMint.swift",
            source: """
            import AgentDomain

            func attemptMint(projectID: ProjectID, fact: ProjectBrainFact) throws {
                let identity = try ProjectBrainSourceIdentity(
                    acceptedProjectStateID: "state",
                    checkpointReferenceID: "checkpoint",
                    projectRootRevisionID: "root-revision"
                )
                _ = try ProjectBrainTrustedSnapshot(
                    authenticatedProjectID: projectID,
                    brainRevision: 1,
                    sourceIdentity: identity,
                    authorityReceiptID: "caller",
                    snapshotDigest: "sha256:caller",
                    facts: [fact]
                )
            }
            """,
            expectedSurface: "ProjectBrainTrustedSnapshot"
        )
    }

    func testExternalConsumerCannotMintCurrentSourceAuthority() throws {
        try assertExternalCompilationFails(
            sourceName: "ExternalProjectBrainCurrentAuthorityMint.swift",
            source: """
            import AgentDomain

            func attemptMint(projectID: ProjectID) throws {
                let identity = try ProjectBrainSourceIdentity(
                    acceptedProjectStateID: "state",
                    checkpointReferenceID: "checkpoint",
                    projectRootRevisionID: "root-revision"
                )
                _ = try ProjectBrainTrustedSelectionAuthority(
                    authenticatedProjectID: projectID,
                    sourceIdentity: identity,
                    authorityReceiptID: "caller"
                )
            }
            """,
            expectedSurface: "ProjectBrainTrustedSelectionAuthority"
        )
    }

    func testExternalConsumerCannotSelectRawFactArray() throws {
        try assertExternalCompilationFails(
            sourceName: "ExternalProjectBrainRawSelection.swift",
            source: """
            import AgentDomain

            func attemptRawSelection(
                fact: ProjectBrainFact,
                request: ProjectBrainContextRequest
            ) throws {
                _ = try ProjectBrainContextSelector.select(from: [fact], request: request)
            }
            """,
            expectedSurface: "ProjectBrainContextSelector"
        )
    }

    private func assertExternalCompilationFails(
        sourceName: String,
        source: String,
        expectedSurface: String
    ) throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("project-brain-trust-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let sourceURL = temporaryDirectory.appendingPathComponent(sourceName)
        try source.write(to: sourceURL, atomically: true, encoding: .utf8)

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
            "External Project Brain trust bypass unexpectedly compiled"
        )
        XCTAssertFalse(
            diagnostics.localizedCaseInsensitiveContains("no such module 'AgentDomain'"),
            "Static boundary probe failed before reaching Project Brain access control: \(diagnostics)"
        )
        XCTAssertTrue(
            diagnostics.contains(expectedSurface)
                || diagnostics.contains("currentAuthority"),
            "Expected \(expectedSurface) trust-boundary diagnostic: \(diagnostics)"
        )
        XCTAssertTrue(
            diagnostics.localizedCaseInsensitiveContains("inaccessible")
                || diagnostics.localizedCaseInsensitiveContains("internal protection level")
                || diagnostics.localizedCaseInsensitiveContains("cannot convert value")
                || diagnostics.localizedCaseInsensitiveContains("missing argument"),
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

    private func sourceIdentity(
        acceptedProjectStateID: String = "accepted-project-state-1",
        checkpointReferenceID: String = "checkpoint-1",
        projectRootRevisionID: String = "project-root-revision-1"
    ) throws -> ProjectBrainSourceIdentity {
        try ProjectBrainSourceIdentity(
            acceptedProjectStateID: acceptedProjectStateID,
            checkpointReferenceID: checkpointReferenceID,
            projectRootRevisionID: projectRootRevisionID
        )
    }

    private func trustedSnapshot(
        projectID: ProjectID,
        identity: ProjectBrainSourceIdentity,
        brainRevision: UInt64 = 1,
        receiptID: String = "brain-receipt",
        digest: String = "sha256:snapshot",
        facts: [ProjectBrainFact]
    ) throws -> ProjectBrainTrustedSnapshot {
        try ProjectBrainTrustedSnapshot(
            authenticatedProjectID: projectID,
            brainRevision: brainRevision,
            sourceIdentity: identity,
            authorityReceiptID: receiptID,
            snapshotDigest: digest,
            facts: facts
        )
    }

    private func trustedCurrentAuthority(
        projectID: ProjectID,
        identity: ProjectBrainSourceIdentity,
        receiptID: String = "current-source-receipt"
    ) throws -> ProjectBrainTrustedSelectionAuthority {
        try ProjectBrainTrustedSelectionAuthority(
            authenticatedProjectID: projectID,
            sourceIdentity: identity,
            authorityReceiptID: receiptID
        )
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
