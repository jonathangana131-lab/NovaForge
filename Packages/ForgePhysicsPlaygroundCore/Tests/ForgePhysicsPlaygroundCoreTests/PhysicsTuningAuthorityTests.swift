import XCTest
@testable import ForgePhysicsPlaygroundCore

final class PhysicsTuningAuthorityTests: XCTestCase {
    func testPreviewAuthorizationIsExplicitlyNonApplied() throws {
        let fixture = try Fixture()
        let request = try fixture.request(
            parameterID: "vehicle.mass",
            expected: 1200,
            proposed: 1275,
            operation: .preview,
            actor: .user
        )

        let authorization = try PhysicsTuningAuthority.authorize(
            request,
            catalog: fixture.catalog,
            snapshot: fixture.snapshot
        )

        XCTAssertEqual(authorization.effect, .previewOnly)
        XCTAssertEqual(authorization.previousValue, 1200)
        XCTAssertEqual(authorization.proposedValue, 1275)
        XCTAssertEqual(authorization.parameterKind, .mass)
        XCTAssertEqual(authorization.unit, .kilograms)
        XCTAssertEqual(authorization.snapshotSource, .runtimeObservation)
        XCTAssertEqual(authorization.sourceEvidenceID, "runtime-frame-41")
        XCTAssertFalse(authorization.runtimeMutationObserved)
    }

    func testCommitAuthorizationRequiresSeparateRuntimeMutation() throws {
        let fixture = try Fixture()
        let request = try fixture.request(
            parameterID: "vehicle.steering",
            expected: 0.72,
            proposed: 0.80,
            operation: .commit,
            actor: .agent
        )

        let authorization = try PhysicsTuningAuthority.authorize(
            request,
            catalog: fixture.catalog,
            snapshot: fixture.snapshot
        )

        XCTAssertEqual(authorization.effect, .runtimeMutationRequired)
        XCTAssertEqual(authorization.operation, .commit)
        XCTAssertEqual(authorization.actor, .agent)
        XCTAssertFalse(authorization.runtimeMutationObserved)
    }

    func testDifferentProjectOrRevisionFailsClosed() throws {
        let fixture = try Fixture()
        let otherRevision = try PhysicsProjectRevision(projectID: "project-a", revisionID: "rev-2")
        let request = try PhysicsTuningRequest(
            requestID: "request-stale-rev",
            projectRevision: otherRevision,
            targetID: fixture.catalog.targetID,
            catalogRevision: fixture.catalog.catalogRevision,
            parameterID: "vehicle.mass",
            expectedCurrentValue: 1200,
            proposedValue: 1300,
            operation: .commit,
            actor: .user
        )

        XCTAssertThrowsError(
            try PhysicsTuningAuthority.authorize(request, catalog: fixture.catalog, snapshot: fixture.snapshot)
        ) { error in
            XCTAssertEqual(error as? PhysicsTuningRejection, .projectRevisionMismatch)
        }
    }

    func testTargetAndCatalogRevisionAreBoundExactly() throws {
        let fixture = try Fixture()
        let wrongTarget = try fixture.request(
            targetID: "vehicle-other",
            parameterID: "vehicle.mass",
            expected: 1200,
            proposed: 1300
        )
        XCTAssertThrowsError(
            try PhysicsTuningAuthority.authorize(wrongTarget, catalog: fixture.catalog, snapshot: fixture.snapshot)
        ) { error in
            XCTAssertEqual(error as? PhysicsTuningRejection, .targetMismatch)
        }

        let wrongCatalog = try fixture.request(
            catalogRevision: "catalog-v2",
            parameterID: "vehicle.mass",
            expected: 1200,
            proposed: 1300
        )
        XCTAssertThrowsError(
            try PhysicsTuningAuthority.authorize(wrongCatalog, catalog: fixture.catalog, snapshot: fixture.snapshot)
        ) { error in
            XCTAssertEqual(error as? PhysicsTuningRejection, .catalogRevisionMismatch)
        }
    }

    func testOnlyExplicitlyExposedParameterCanBeAuthorized() throws {
        let fixture = try Fixture()
        let request = try fixture.request(
            parameterID: "vehicle.secretBoost",
            expected: 1,
            proposed: 2
        )

        XCTAssertThrowsError(
            try PhysicsTuningAuthority.authorize(request, catalog: fixture.catalog, snapshot: fixture.snapshot)
        ) { error in
            XCTAssertEqual(
                error as? PhysicsTuningRejection,
                .parameterNotExposed("vehicle.secretBoost")
            )
        }
    }

    func testMissingCurrentValueFailsClosed() throws {
        let fixture = try Fixture(values: ["vehicle.mass": 1200])
        let request = try fixture.request(
            parameterID: "vehicle.steering",
            expected: 0.72,
            proposed: 0.8
        )

        XCTAssertThrowsError(
            try PhysicsTuningAuthority.authorize(request, catalog: fixture.catalog, snapshot: fixture.snapshot)
        ) { error in
            XCTAssertEqual(
                error as? PhysicsTuningRejection,
                .currentValueMissing("vehicle.steering")
            )
        }
    }

    func testStaleExpectedValuePreventsLostUpdate() throws {
        let fixture = try Fixture()
        let request = try fixture.request(
            parameterID: "vehicle.mass",
            expected: 1199,
            proposed: 1300
        )

        XCTAssertThrowsError(
            try PhysicsTuningAuthority.authorize(request, catalog: fixture.catalog, snapshot: fixture.snapshot)
        ) { error in
            XCTAssertEqual(
                error as? PhysicsTuningRejection,
                .staleCurrentValue(parameterID: "vehicle.mass", expected: 1199, observed: 1200)
            )
        }
    }

    func testProposedValueMustRemainInsideHostSuppliedBounds() throws {
        let fixture = try Fixture()
        let below = try fixture.request(
            parameterID: "vehicle.mass",
            expected: 1200,
            proposed: 99
        )
        XCTAssertThrowsError(
            try PhysicsTuningAuthority.authorize(below, catalog: fixture.catalog, snapshot: fixture.snapshot)
        ) { error in
            XCTAssertEqual(
                error as? PhysicsTuningRejection,
                .proposedValueBelowMinimum(parameterID: "vehicle.mass", proposed: 99, minimum: 100)
            )
        }

        let above = try fixture.request(
            parameterID: "vehicle.steering",
            expected: 0.72,
            proposed: 1.01
        )
        XCTAssertThrowsError(
            try PhysicsTuningAuthority.authorize(above, catalog: fixture.catalog, snapshot: fixture.snapshot)
        ) { error in
            XCTAssertEqual(
                error as? PhysicsTuningRejection,
                .proposedValueAboveMaximum(parameterID: "vehicle.steering", proposed: 1.01, maximum: 1)
            )
        }
    }

    func testSnapshotCurrentValueMustAlsoBeInsideDefinitionBounds() throws {
        let fixture = try Fixture(values: [
            "vehicle.mass": 12_000,
            "vehicle.steering": 0.72,
        ])
        let request = try fixture.request(
            parameterID: "vehicle.mass",
            expected: 12_000,
            proposed: 1300
        )

        XCTAssertThrowsError(
            try PhysicsTuningAuthority.authorize(request, catalog: fixture.catalog, snapshot: fixture.snapshot)
        ) { error in
            XCTAssertEqual(
                error as? PhysicsTuningRejection,
                .currentValueOutsideExposedBounds(parameterID: "vehicle.mass", observed: 12_000)
            )
        }
    }

    func testNonFiniteInputsAreRejectedAtConstructionBoundary() throws {
        let revision = try PhysicsProjectRevision(projectID: "project-a", revisionID: "rev-1")

        XCTAssertThrowsError(
            try PhysicsParameterDefinition(
                id: "bad",
                kind: .gravity,
                displayName: "Gravity",
                unit: .metersPerSecondSquared,
                minimumValue: -.infinity,
                maximumValue: 100
            )
        )

        XCTAssertThrowsError(
            try PhysicsTuningSnapshot(
                projectRevision: revision,
                targetID: "scene",
                catalogRevision: "catalog",
                source: .acceptedConfiguration,
                evidenceID: "config-1",
                values: ["gravity": .nan]
            )
        )

        XCTAssertThrowsError(
            try PhysicsTuningRequest(
                requestID: "request",
                projectRevision: revision,
                targetID: "scene",
                catalogRevision: "catalog",
                parameterID: "gravity",
                expectedCurrentValue: 9.81,
                proposedValue: .infinity,
                operation: .preview,
                actor: .user
            )
        )
    }

    func testParameterKindRejectsSemanticallyWrongUnit() throws {
        XCTAssertThrowsError(
            try PhysicsParameterDefinition(
                id: "vehicle.mass",
                kind: .mass,
                displayName: "Mass",
                unit: .degrees,
                minimumValue: 100,
                maximumValue: 5000
            )
        ) { error in
            XCTAssertEqual(
                error as? PhysicsTuningValidationError,
                .unitMismatch(
                    parameterID: "vehicle.mass",
                    kind: .mass,
                    expected: .kilograms,
                    actual: .degrees
                )
            )
        }
    }

    func testDuplicateParameterIDsAreRejected() throws {
        let revision = try PhysicsProjectRevision(projectID: "project-a", revisionID: "rev-1")
        let first = try PhysicsParameterDefinition(
            id: "same",
            kind: .friction,
            displayName: "Tire Grip",
            unit: .coefficient,
            minimumValue: 0,
            maximumValue: 3
        )
        let second = try PhysicsParameterDefinition(
            id: "same",
            kind: .mass,
            displayName: "Mass",
            unit: .kilograms,
            minimumValue: 1,
            maximumValue: 1000
        )

        XCTAssertThrowsError(
            try PhysicsExposedCatalog(
                projectRevision: revision,
                targetID: "vehicle",
                catalogRevision: "catalog-v1",
                parameters: [first, second]
            )
        ) { error in
            XCTAssertEqual(error as? PhysicsTuningValidationError, .duplicateParameterID("same"))
        }
    }

    func testRecommendedStepIsHintAndDoesNotSilentlyRoundIntent() throws {
        let fixture = try Fixture()
        let request = try fixture.request(
            parameterID: "vehicle.mass",
            expected: 1200,
            proposed: 1234.567,
            operation: .preview
        )

        let authorization = try PhysicsTuningAuthority.authorize(
            request,
            catalog: fixture.catalog,
            snapshot: fixture.snapshot
        )
        XCTAssertEqual(authorization.proposedValue, 1234.567)
    }
}

private struct Fixture {
    let revision: PhysicsProjectRevision
    let catalog: PhysicsExposedCatalog
    let snapshot: PhysicsTuningSnapshot

    init(values: [String: Double]? = nil) throws {
        revision = try PhysicsProjectRevision(projectID: "project-a", revisionID: "rev-1")
        let mass = try PhysicsParameterDefinition(
            id: "vehicle.mass",
            kind: .mass,
            displayName: "Mass",
            unit: .kilograms,
            minimumValue: 100,
            maximumValue: 5000,
            recommendedStep: 25
        )
        let steering = try PhysicsParameterDefinition(
            id: "vehicle.steering",
            kind: .steeringResponse,
            displayName: "Steering Response",
            unit: .normalized,
            minimumValue: 0,
            maximumValue: 1,
            recommendedStep: 0.01
        )
        catalog = try PhysicsExposedCatalog(
            projectRevision: revision,
            targetID: "vehicle-player",
            catalogRevision: "catalog-v1",
            parameters: [mass, steering]
        )
        snapshot = try PhysicsTuningSnapshot(
            projectRevision: revision,
            targetID: "vehicle-player",
            catalogRevision: "catalog-v1",
            source: .runtimeObservation,
            evidenceID: "runtime-frame-41",
            values: values ?? [
                "vehicle.mass": 1200,
                "vehicle.steering": 0.72,
            ]
        )
    }

    func request(
        targetID: String = "vehicle-player",
        catalogRevision: String = "catalog-v1",
        parameterID: String,
        expected: Double,
        proposed: Double,
        operation: PhysicsTuningOperation = .commit,
        actor: PhysicsTuningActor = .user
    ) throws -> PhysicsTuningRequest {
        try PhysicsTuningRequest(
            requestID: "request-\(parameterID)-\(proposed)",
            projectRevision: revision,
            targetID: targetID,
            catalogRevision: catalogRevision,
            parameterID: parameterID,
            expectedCurrentValue: expected,
            proposedValue: proposed,
            operation: operation,
            actor: actor
        )
    }
}
