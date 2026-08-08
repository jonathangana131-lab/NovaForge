import Foundation
import XCTest
@testable import ForgeCompactCore

final class ProjectCapsuleArchiveStoreTests: XCTestCase {
    func testMissingArchiveDistinguishesAbsentFromCorrupt() async throws {
        let fixture = makeFixture()
        defer { fixture.remove() }
        let store = try ProjectCapsuleArchiveStore(
            fileURL: fixture.fileURL,
            projectID: "project-1",
            missionID: "mission-1"
        )

        let optional = try await store.loadIfPresent()
        XCTAssertNil(optional)

        do {
            _ = try await store.load()
            XCTFail("Expected missing archive to fail")
        } catch {
            XCTAssertEqual(error as? ProjectCapsuleArchiveStoreError, .archiveNotFound)
        }
    }

    func testSaveCreatesParentAndRoundTripsValidatedArchive() async throws {
        let fixture = makeFixture(nested: true)
        defer { fixture.remove() }
        let store = try ProjectCapsuleArchiveStore(
            fileURL: fixture.fileURL,
            projectID: "project-1",
            missionID: "mission-1"
        )
        let archive = try makeArchive(capsuleRevisions: [1, 2])

        try await store.save(archive)
        let loaded = try await store.load()

        XCTAssertEqual(loaded, archive)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.fileURL.path))
    }

    func testExactResaveIsIdempotent() async throws {
        let fixture = makeFixture()
        defer { fixture.remove() }
        let store = try ProjectCapsuleArchiveStore(
            fileURL: fixture.fileURL,
            projectID: "project-1",
            missionID: "mission-1"
        )
        let archive = try makeArchive(capsuleRevisions: [1, 2])
        try await store.save(archive)
        let before = try Data(contentsOf: fixture.fileURL)

        try await store.save(archive)
        let after = try Data(contentsOf: fixture.fileURL)

        XCTAssertEqual(after, before)
    }

    func testStrictHistoryExtensionSucceeds() async throws {
        let fixture = makeFixture()
        defer { fixture.remove() }
        let store = try ProjectCapsuleArchiveStore(
            fileURL: fixture.fileURL,
            projectID: "project-1",
            missionID: "mission-1"
        )
        let first = try makeArchive(capsuleRevisions: [1])
        let extended = try makeArchive(capsuleRevisions: [1, 2, 3])

        try await store.save(first)
        try await store.save(extended)
        let loaded = try await store.load()

        XCTAssertEqual(loaded, extended)
    }

    func testRollbackIsRejectedWithoutChangingDurableBytes() async throws {
        let fixture = makeFixture()
        defer { fixture.remove() }
        let store = try ProjectCapsuleArchiveStore(
            fileURL: fixture.fileURL,
            projectID: "project-1",
            missionID: "mission-1"
        )
        let latest = try makeArchive(capsuleRevisions: [1, 2])
        let stale = try makeArchive(capsuleRevisions: [1])
        try await store.save(latest)
        let before = try Data(contentsOf: fixture.fileURL)

        do {
            try await store.save(stale)
            XCTFail("Expected rollback to fail closed")
        } catch {
            XCTAssertEqual(error as? ProjectCapsuleArchiveStoreError, .historyRollback)
        }

        let loaded = try await store.load()
        XCTAssertEqual(try Data(contentsOf: fixture.fileURL), before)
        XCTAssertEqual(loaded, latest)
    }

    func testDivergentExistingHistoryIsRejectedWithoutOverwrite() async throws {
        let fixture = makeFixture()
        defer { fixture.remove() }
        let store = try ProjectCapsuleArchiveStore(
            fileURL: fixture.fileURL,
            projectID: "project-1",
            missionID: "mission-1"
        )
        let original = try makeArchive(capsuleRevisions: [1])
        let divergent = try makeArchive(
            capsuleRevisions: [1, 2],
            firstObjective: "Rewritten accepted history"
        )
        try await store.save(original)
        let before = try Data(contentsOf: fixture.fileURL)

        do {
            try await store.save(divergent)
            XCTFail("Expected divergent history to fail closed")
        } catch {
            XCTAssertEqual(
                error as? ProjectCapsuleArchiveStoreError,
                .divergentHistory(index: 0)
            )
        }

        let loaded = try await store.load()
        XCTAssertEqual(try Data(contentsOf: fixture.fileURL), before)
        XCTAssertEqual(loaded, original)
    }

    func testStoreRejectsArchiveIdentityMismatchBeforeWrite() async throws {
        let fixture = makeFixture()
        defer { fixture.remove() }
        let store = try ProjectCapsuleArchiveStore(
            fileURL: fixture.fileURL,
            projectID: "project-1",
            missionID: "mission-1"
        )
        let wrongProject = try makeArchive(
            projectID: "project-2",
            capsuleRevisions: [1]
        )

        do {
            try await store.save(wrongProject)
            XCTFail("Expected identity mismatch")
        } catch {
            XCTAssertEqual(error as? ProjectCapsuleArchiveStoreError, .identityMismatch)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.fileURL.path))
    }

    func testLoadRejectsValidArchiveForDifferentIdentity() async throws {
        let fixture = makeFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let otherArchive = try makeArchive(
            projectID: "project-2",
            capsuleRevisions: [1]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(otherArchive).write(to: fixture.fileURL, options: [.atomic])

        let store = try ProjectCapsuleArchiveStore(
            fileURL: fixture.fileURL,
            projectID: "project-1",
            missionID: "mission-1"
        )

        do {
            _ = try await store.load()
            XCTFail("Expected identity mismatch")
        } catch {
            XCTAssertEqual(error as? ProjectCapsuleArchiveStoreError, .identityMismatch)
        }
    }

    func testCorruptExistingFileFailsClosedAndIsNotOverwritten() async throws {
        let fixture = makeFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let corrupt = Data("{ definitely-not-valid-json".utf8)
        try corrupt.write(to: fixture.fileURL)
        let store = try ProjectCapsuleArchiveStore(
            fileURL: fixture.fileURL,
            projectID: "project-1",
            missionID: "mission-1"
        )

        do {
            _ = try await store.loadIfPresent()
            XCTFail("Expected corrupt archive to fail")
        } catch {
            XCTAssertEqual(error as? ProjectCapsuleArchiveStoreError, .decodeFailed)
        }

        do {
            try await store.save(try makeArchive(capsuleRevisions: [1]))
            XCTFail("Corrupt durable state must not be treated as empty")
        } catch {
            XCTAssertEqual(error as? ProjectCapsuleArchiveStoreError, .decodeFailed)
        }

        XCTAssertEqual(try Data(contentsOf: fixture.fileURL), corrupt)
    }

    func testDirectoryAtArchivePathFailsAsReadError() async throws {
        let fixture = makeFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.fileURL,
            withIntermediateDirectories: true
        )
        let store = try ProjectCapsuleArchiveStore(
            fileURL: fixture.fileURL,
            projectID: "project-1",
            missionID: "mission-1"
        )

        do {
            _ = try await store.loadIfPresent()
            XCTFail("Directory must not be treated as a missing archive")
        } catch {
            XCTAssertEqual(error as? ProjectCapsuleArchiveStoreError, .readFailed)
        }
    }

    func testInitializerRejectsRemoteAndDirectoryURLs() {
        XCTAssertThrowsError(
            try ProjectCapsuleArchiveStore(
                fileURL: URL(string: "https://example.com/archive.json")!,
                projectID: "project-1",
                missionID: "mission-1"
            )
        ) { error in
            XCTAssertEqual(error as? ProjectCapsuleArchiveStoreError, .nonFileURL)
        }

        let directoryURL = URL(
            fileURLWithPath: FileManager.default.temporaryDirectory.path,
            isDirectory: true
        )
        XCTAssertThrowsError(
            try ProjectCapsuleArchiveStore(
                fileURL: directoryURL,
                projectID: "project-1",
                missionID: "mission-1"
            )
        ) { error in
            XCTAssertEqual(error as? ProjectCapsuleArchiveStoreError, .directoryURL)
        }
    }

    private func makeArchive(
        projectID: String = "project-1",
        missionID: String = "mission-1",
        capsuleRevisions: [Int],
        firstObjective: String = "Keep accepted mission truth"
    ) throws -> ProjectCapsuleArchive {
        let capsules = try capsuleRevisions.enumerated().map { offset, capsuleRevision in
            try makeCapsule(
                projectID: projectID,
                missionID: missionID,
                capsuleRevision: capsuleRevision,
                objective: offset == 0 ? firstObjective : "Continue revision \(capsuleRevision)"
            )
        }
        return try ProjectCapsuleArchive(
            projectID: projectID,
            missionID: missionID,
            capsules: capsules
        )
    }

    private func makeCapsule(
        projectID: String,
        missionID: String,
        capsuleRevision: Int,
        objective: String
    ) throws -> ProjectCapsule {
        let sourceRevision = "source-r\(capsuleRevision)"
        let authority = try ProjectCapsuleAuthority(
            projectID: projectID,
            missionID: missionID,
            sourceRevision: sourceRevision,
            missionRevision: capsuleRevision,
            authorityEpoch: 1,
            capsuleRevision: capsuleRevision
        )
        let item = try ForgeCompactContextItem(
            id: "objective",
            sourceRevision: sourceRevision,
            tier: .l0AlwaysResident,
            kind: .currentObjective,
            priority: 100,
            content: objective,
            provenance: ForgeCompactProvenance(
                kind: .source,
                reference: "mission/objective"
            ),
            isAuthoritative: true
        )
        return try ProjectCapsuleBuilder.build(
            authority: authority,
            items: [item],
            budgetBytes: 4_096
        )
    }

    private func makeFixture(nested: Bool = false) -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NovaForge-ForgeCompact-\(UUID().uuidString)", isDirectory: true)
        let fileURL: URL
        if nested {
            fileURL = root
                .appendingPathComponent("deep", isDirectory: true)
                .appendingPathComponent("capsules.json", isDirectory: false)
        } else {
            fileURL = root.appendingPathComponent("capsules.json", isDirectory: false)
        }
        return Fixture(root: root, fileURL: fileURL)
    }
}

private struct Fixture {
    let root: URL
    let fileURL: URL

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
