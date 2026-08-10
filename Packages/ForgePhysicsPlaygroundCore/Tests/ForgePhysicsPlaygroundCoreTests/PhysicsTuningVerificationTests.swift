import XCTest
@testable import ForgePhysicsPlaygroundCore

final class PhysicsTuningVerificationTests: XCTestCase {
    func testCommitCanProduceReceiptOnlyAfterMatchingPostconditionObservation() throws {
        let fixture = try VerificationFixture(operation: .commit, proposedValue: 1275)
        let observation = try fixture.postcondition(observedValue: 1275)

        let receipt = try PhysicsTuningAuthority.verifyPostcondition(
            for: fixture.authorization,
            observation: observation
        )

        XCTAssertTrue(receipt.postconditionObserved)
        XCTAssertTrue(receipt.runtimePostconditionObserved)
        XCTAssertEqual(receipt.resultProjectRevision.revisionID, "rev-result")
        XCTAssertEqual(receipt.verificationEvidenceID, "postcondition-evidence")
        XCTAssertEqual(receipt.observedValue, 1275)
    }

    func testPreviewCannotProduceCommitVerificationReceipt() throws {
        let fixture = try VerificationFixture(operation: .preview, proposedValue: 1275)
        let observation = try fixture.postcondition(observedValue: 1275)

        XCTAssertThrowsError(
            try PhysicsTuningAuthority.verifyPostcondition(
                for: fixture.authorization,
                observation: observation
            )
        ) { error in
            XCTAssertEqual(
                error as? PhysicsTuningVerificationRejection,
                .previewCannotProduceCommitReceipt
            )
        }
    }

    func testPostconditionMustMatchAuthorizedValueAndProject() throws {
        let fixture = try VerificationFixture(operation: .commit, proposedValue: 1275)
        let wrongValue = try fixture.postcondition(observedValue: 1274)
        XCTAssertThrowsError(
            try PhysicsTuningAuthority.verifyPostcondition(
                for: fixture.authorization,
                observation: wrongValue
            )
        ) { error in
            XCTAssertEqual(
                error as? PhysicsTuningVerificationRejection,
                .observedValueMismatch(expected: 1275, observed: 1274)
            )
        }

        let otherProject = try PhysicsProjectRevision(projectID: "project-b", revisionID: "rev-result")
        let wrongProject = try fixture.postcondition(
            resultRevision: otherProject,
            observedValue: 1275
        )
        XCTAssertThrowsError(
            try PhysicsTuningAuthority.verifyPostcondition(
                for: fixture.authorization,
                observation: wrongProject
            )
        ) { error in
            XCTAssertEqual(error as? PhysicsTuningVerificationRejection, .resultProjectMismatch)
        }
    }

    func testPostconditionRejectsNonFiniteObservedValue() throws {
        let fixture = try VerificationFixture(operation: .commit, proposedValue: 1275)

        XCTAssertThrowsError(try fixture.postcondition(observedValue: .nan)) { error in
            guard case .nonFiniteObservedValue(parameterID: "vehicle.mass", value: let value) =
                    error as? PhysicsTuningPostconditionValidationError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(value.isNaN)
        }
    }
}

private struct VerificationFixture {
    let revision: PhysicsProjectRevision
    let authorization: PhysicsTuningAuthorization

    init(operation: PhysicsTuningOperation, proposedValue: Double) throws {
        revision = try PhysicsProjectRevision(projectID: "project-a", revisionID: "rev-1")
        let definition = try PhysicsParameterDefinition(
            id: "vehicle.mass",
            kind: .mass,
            displayName: "Mass",
            unit: .kilograms,
            minimumValue: 100,
            maximumValue: 5000
        )
        let catalog = try PhysicsExposedCatalog(
            projectRevision: revision,
            targetID: "vehicle-player",
            catalogRevision: "catalog-v1",
            parameters: [definition]
        )
        let snapshot = try PhysicsTuningSnapshot(
            projectRevision: revision,
            targetID: "vehicle-player",
            catalogRevision: "catalog-v1",
            source: .runtimeObservation,
            evidenceID: "runtime-frame-41",
            values: ["vehicle.mass": 1200]
        )
        let request = try PhysicsTuningRequest(
            requestID: "request-mass",
            projectRevision: revision,
            targetID: "vehicle-player",
            catalogRevision: "catalog-v1",
            parameterID: "vehicle.mass",
            expectedCurrentValue: 1200,
            proposedValue: proposedValue,
            operation: operation,
            actor: .agent
        )
        authorization = try PhysicsTuningAuthority.authorize(
            request,
            catalog: catalog,
            snapshot: snapshot
        )
    }

    func postcondition(
        resultRevision: PhysicsProjectRevision? = nil,
        observedValue: Double
    ) throws -> PhysicsTuningPostconditionObservation {
        let resultRevision = try resultRevision ?? PhysicsProjectRevision(
            projectID: revision.projectID,
            revisionID: "rev-result"
        )
        return try PhysicsTuningPostconditionObservation(
            requestID: authorization.requestID,
            sourceProjectRevision: authorization.projectRevision,
            resultProjectRevision: resultRevision,
            targetID: authorization.targetID,
            catalogRevision: authorization.catalogRevision,
            parameterID: authorization.parameterID,
            source: .runtimeObservation,
            evidenceID: "postcondition-evidence",
            observedValue: observedValue
        )
    }
}
