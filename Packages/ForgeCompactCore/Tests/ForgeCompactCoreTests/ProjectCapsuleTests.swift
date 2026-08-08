import XCTest
@testable import ForgeCompactCore

final class ProjectCapsuleTests: XCTestCase {
    private func requiredReferences(extra: [ForgeCompactCapsuleReference] = []) throws -> [ForgeCompactCapsuleReference] {
        try [
            ForgeCompactCapsuleReference(id: "constitution", kind: .missionConstitution, authorityRevision: "m1", estimatedPromptBytes: 100),
            ForgeCompactCapsuleReference(id: "objective", kind: .currentObjective, authorityRevision: "m1", estimatedPromptBytes: 80),
            ForgeCompactCapsuleReference(id: "stage", kind: .currentStage, authorityRevision: "m1", estimatedPromptBytes: 60),
            ForgeCompactCapsuleReference(id: "privacy", kind: .privacyPolicy, authorityRevision: "m1", estimatedPromptBytes: 40)
        ] + extra
    }

    func testCapsuleRejectsMissingRequiredTruthReference() throws {
        let references = try requiredReferences().filter { $0.kind != .privacyPolicy }
        XCTAssertThrowsError(
            try ForgeCompactProjectCapsule(capsuleID: "capsule", projectID: "project", sourceRevision: "source", maximumPromptBytes: 1_000, references: references)
        ) { error in
            XCTAssertEqual(error as? ForgeCompactValidationError, .missingRequiredReference(.privacyPolicy))
        }
    }

    func testCapsuleRejectsCaseFoldedDuplicateReferenceIdentity() throws {
        var references = try requiredReferences()
        references.append(try ForgeCompactCapsuleReference(id: "STAGE", kind: .testReceipt, authorityRevision: "t1", estimatedPromptBytes: 10))
        XCTAssertThrowsError(
            try ForgeCompactProjectCapsule(capsuleID: "capsule", projectID: "project", sourceRevision: "source", maximumPromptBytes: 1_000, references: references)
        ) { error in
            XCTAssertEqual(error as? ForgeCompactValidationError, .duplicateReference("STAGE"))
        }
    }

    func testCapsuleEnforcesPromptBudgetAndCanonicalOrdering() throws {
        let defect = try ForgeCompactCapsuleReference(id: "defect-z", kind: .defect, authorityRevision: "d1", estimatedPromptBytes: 30)
        let capsule = try ForgeCompactProjectCapsule(
            capsuleID: "capsule", projectID: "project", sourceRevision: "source",
            maximumPromptBytes: 310, references: requiredReferences(extra: [defect])
        )
        XCTAssertEqual(capsule.estimatedPromptBytes, 310)
        XCTAssertEqual(capsule.references.map(\.kind.rawValue), capsule.references.map(\.kind.rawValue).sorted())

        XCTAssertThrowsError(
            try ForgeCompactProjectCapsule(
                capsuleID: "capsule", projectID: "project", sourceRevision: "source",
                maximumPromptBytes: 309, references: requiredReferences(extra: [defect])
            )
        ) { error in
            XCTAssertEqual(error as? ForgeCompactValidationError, .capsuleBudgetExceeded)
        }
    }
    func testCapsuleDecodeRevalidatesRequiredReferencesAndBudget() throws {
        let capsule = try ForgeCompactProjectCapsule(
            capsuleID: "capsule", projectID: "project", sourceRevision: "source",
            maximumPromptBytes: 1_000, references: requiredReferences()
        )
        let encoded = try JSONEncoder().encode(capsule)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var references = try XCTUnwrap(object["references"] as? [[String: Any]])
        references.removeAll { ($0["kind"] as? String) == "privacyPolicy" }
        object["references"] = references
        let missingPrivacy = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(ForgeCompactProjectCapsule.self, from: missingPrivacy))

        object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["maximumPromptBytes"] = 1
        let overBudget = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(ForgeCompactProjectCapsule.self, from: overBudget))
    }

}
