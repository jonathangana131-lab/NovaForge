import Foundation
import XCTest
@testable import ForgeCompactCore

final class ForgeCompactCollectionBoundsTests: XCTestCase {
    func testBuilderRejectsOversizedSourceSetBeforeDuplicateOrSortWork() throws {
        let candidate = try item(id: "candidate")
        let oversized = Array(
            repeating: candidate,
            count: ProjectCapsule.maximumSourceItems + 1
        )

        XCTAssertThrowsError(
            try ProjectCapsuleBuilder.build(
                authority: authority(capsuleRevision: 1),
                items: oversized,
                budgetBytes: 2_000_000
            )
        ) { error in
            XCTAssertEqual(
                error as? ForgeCompactError,
                .collectionTooLarge(
                    field: "capsule.sourceItems",
                    maximum: ProjectCapsule.maximumSourceItems
                )
            )
        }
    }

    func testCapsuleDecodeRejectsOversizedSelectedArrayBeforeDuplicateValidation() throws {
        let capsule = try ProjectCapsuleBuilder.build(
            authority: authority(capsuleRevision: 1),
            items: [try item(id: "candidate")],
            budgetBytes: 2_000_000
        )
        var object = try jsonObject(for: capsule)
        let selectedItems = try XCTUnwrap(object["selectedItems"] as? [Any])
        let selectedItem = try XCTUnwrap(selectedItems.first)
        object["selectedItems"] = Array(
            repeating: selectedItem,
            count: ProjectCapsule.maximumSourceItems + 1
        )
        object["sourceItemCount"] = ProjectCapsule.maximumSourceItems + 1
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])

        XCTAssertThrowsError(try JSONDecoder().decode(ProjectCapsule.self, from: data)) { error in
            XCTAssertEqual(
                error as? ForgeCompactError,
                .collectionTooLarge(
                    field: "capsule.sourceItems",
                    maximum: ProjectCapsule.maximumSourceItems
                )
            )
        }
    }

    func testCapsuleSourceCountBoundaryAndOverflowFailClosed() throws {
        XCTAssertEqual(
            try ProjectCapsule.checkedSourceItemCount(
                selectedCount: ProjectCapsule.maximumSourceItems,
                omittedCount: 0
            ),
            ProjectCapsule.maximumSourceItems
        )

        XCTAssertThrowsError(
            try ProjectCapsule.checkedSourceItemCount(
                selectedCount: ProjectCapsule.maximumSourceItems,
                omittedCount: 1
            )
        ) { error in
            XCTAssertEqual(
                error as? ForgeCompactError,
                .collectionTooLarge(
                    field: "capsule.sourceItems",
                    maximum: ProjectCapsule.maximumSourceItems
                )
            )
        }

        XCTAssertThrowsError(
            try ProjectCapsule.checkedSourceItemCount(
                selectedCount: Int.max,
                omittedCount: 1
            )
        ) { error in
            XCTAssertEqual(
                error as? ForgeCompactError,
                .collectionTooLarge(
                    field: "capsule.sourceItems",
                    maximum: ProjectCapsule.maximumSourceItems
                )
            )
        }
    }

    func testArchiveRejectsOversizedCapsuleSetBeforeRevisionScan() throws {
        let capsule = try ProjectCapsuleBuilder.build(
            authority: authority(capsuleRevision: 1),
            items: [try item(id: "candidate")],
            budgetBytes: 2_000_000
        )
        let oversized = Array(
            repeating: capsule,
            count: ProjectCapsuleArchive.maximumCapsules + 1
        )

        XCTAssertThrowsError(
            try ProjectCapsuleArchive(
                projectID: "project-1",
                missionID: "mission-1",
                capsules: oversized
            )
        ) { error in
            XCTAssertEqual(
                error as? ForgeCompactError,
                .collectionTooLarge(
                    field: "archive.capsules",
                    maximum: ProjectCapsuleArchive.maximumCapsules
                )
            )
        }
    }

    func testArchiveDecodeRejectsOversizedCapsuleArrayBeforeRevisionValidation() throws {
        let capsule = try ProjectCapsuleBuilder.build(
            authority: authority(capsuleRevision: 1),
            items: [try item(id: "candidate")],
            budgetBytes: 2_000_000
        )
        let archive = try ProjectCapsuleArchive(
            projectID: "project-1",
            missionID: "mission-1",
            capsules: [capsule]
        )
        var object = try jsonObject(for: archive)
        let capsules = try XCTUnwrap(object["capsules"] as? [Any])
        let encodedCapsule = try XCTUnwrap(capsules.first)
        object["capsules"] = Array(
            repeating: encodedCapsule,
            count: ProjectCapsuleArchive.maximumCapsules + 1
        )
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])

        XCTAssertThrowsError(try JSONDecoder().decode(ProjectCapsuleArchive.self, from: data)) { error in
            XCTAssertEqual(
                error as? ForgeCompactError,
                .collectionTooLarge(
                    field: "archive.capsules",
                    maximum: ProjectCapsuleArchive.maximumCapsules
                )
            )
        }
    }

    func testArchiveAggregateItemBoundaryFailsClosed() throws {
        let exact = try ProjectCapsuleArchive.checkedArchiveTotals(
            currentSourceItems: ProjectCapsuleArchive.maximumTotalSourceItems,
            addingSourceItems: 0,
            currentRenderedUTF8Bytes: 0,
            addingRenderedUTF8Bytes: 0
        )
        XCTAssertEqual(exact.sourceItems, ProjectCapsuleArchive.maximumTotalSourceItems)

        XCTAssertThrowsError(
            try ProjectCapsuleArchive.checkedArchiveTotals(
                currentSourceItems: ProjectCapsuleArchive.maximumTotalSourceItems,
                addingSourceItems: 1,
                currentRenderedUTF8Bytes: 0,
                addingRenderedUTF8Bytes: 0
            )
        ) { error in
            XCTAssertEqual(
                error as? ForgeCompactError,
                .collectionTooLarge(
                    field: "archive.sourceItems",
                    maximum: ProjectCapsuleArchive.maximumTotalSourceItems
                )
            )
        }
    }

    func testArchiveAggregateRenderedByteBoundaryFailsClosed() throws {
        let exact = try ProjectCapsuleArchive.checkedArchiveTotals(
            currentSourceItems: 0,
            addingSourceItems: 0,
            currentRenderedUTF8Bytes: ProjectCapsuleArchive.maximumRenderedUTF8Bytes,
            addingRenderedUTF8Bytes: 0
        )
        XCTAssertEqual(
            exact.renderedUTF8Bytes,
            ProjectCapsuleArchive.maximumRenderedUTF8Bytes
        )

        XCTAssertThrowsError(
            try ProjectCapsuleArchive.checkedArchiveTotals(
                currentSourceItems: 0,
                addingSourceItems: 0,
                currentRenderedUTF8Bytes: ProjectCapsuleArchive.maximumRenderedUTF8Bytes,
                addingRenderedUTF8Bytes: 1
            )
        ) { error in
            XCTAssertEqual(
                error as? ForgeCompactError,
                .collectionTooLarge(
                    field: "archive.renderedUTF8Bytes",
                    maximum: ProjectCapsuleArchive.maximumRenderedUTF8Bytes
                )
            )
        }
    }

    func testArchiveAggregateArithmeticOverflowFailsClosed() throws {
        XCTAssertThrowsError(
            try ProjectCapsuleArchive.checkedArchiveTotals(
                currentSourceItems: Int.max,
                addingSourceItems: 1,
                currentRenderedUTF8Bytes: 0,
                addingRenderedUTF8Bytes: 0
            )
        )

        XCTAssertThrowsError(
            try ProjectCapsuleArchive.checkedArchiveTotals(
                currentSourceItems: 0,
                addingSourceItems: 0,
                currentRenderedUTF8Bytes: Int.max,
                addingRenderedUTF8Bytes: 1
            )
        )
    }

    private func authority(capsuleRevision: Int) throws -> ProjectCapsuleAuthority {
        try ProjectCapsuleAuthority(
            projectID: "project-1",
            missionID: "mission-1",
            sourceRevision: "source-1",
            missionRevision: 1,
            authorityEpoch: 1,
            capsuleRevision: capsuleRevision
        )
    }

    private func item(id: String) throws -> ForgeCompactContextItem {
        try ForgeCompactContextItem(
            id: id,
            sourceRevision: "source-1",
            tier: .l1ActiveWorkingSet,
            kind: .workingNote,
            priority: 50,
            content: "candidate context",
            provenance: ForgeCompactProvenance(kind: .source, reference: "ref-\(id)"),
            isAuthoritative: false
        )
    }

    private func jsonObject<T: Encodable>(for value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }
}
