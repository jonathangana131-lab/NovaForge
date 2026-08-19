import AgentDomain
import Foundation
import XCTest

final class MissionProjectBrainDomainTests: XCTestCase {
    func testMissionConstitutionRoundTripsWithDeterministicSets() throws {
        let instant = AgentInstant(rawValue: 1_900_000_000_000)
        let missionID = MissionID(rawValue: uuid(1))
        let projectID = ProjectID(rawValue: uuid(2))
        let constitution = MissionConstitution(
            missionID: missionID,
            projectID: projectID,
            acceptedAt: instant,
            productGoal: "Build a touch-first driving game",
            projectType: "3D Forge Runtime game",
            designIntent: "Fast · Dark · Landscape · Realistic physics",
            orientationTarget: "landscape",
            deviceTargets: MissionStringSet(["iPhone 12+", "iPhone 12+", "iPhone 15 Pro"]),
            requiredCapabilities: MissionStringSet(["Local Save", "3D Scene", "Touch Controls", "3D Scene"]),
            explicitNonGoals: MissionStringSet(["GitHub required for play"]),
            constraints: MissionStringSet(["Must run inside Forge Runtime"]),
            buildDepth: .obsessive,
            creativity: .inventive,
            refactorRisk: .rebuild,
            localityPreference: .localOnly,
            performanceTarget: "Great on iPhone 12 and newer",
            accessibilityTarget: "Reduce Motion and non-color state cues",
            persistenceExpectations: "Garage state survives relaunch",
            acceptanceJourneys: MissionStringSet(["Launch -> Drive -> Pause -> Resume"]),
            expectedEvidence: MissionEvidenceSet([
                .runtimeTested,
                .visuallyInspected,
                .runtimeTested,
                .performanceMeasured,
            ])
        )

        XCTAssertNil(constitution.validationError)
        XCTAssertEqual(
            constitution.requiredCapabilities.values,
            ["3D Scene", "Local Save", "Touch Controls"]
        )
        XCTAssertEqual(
            constitution.expectedEvidence.values,
            [.performanceMeasured, .runtimeTested, .visuallyInspected]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(constitution)
        let decoded = try JSONDecoder().decode(MissionConstitution.self, from: encoded)
        XCTAssertEqual(decoded, constitution)
        XCTAssertEqual(try encoder.encode(decoded), encoded)
    }

    func testMissionConstitutionRejectsSilentEmptyContractFields() {
        let constitution = MissionConstitution(
            missionID: MissionID(rawValue: uuid(10)),
            projectID: ProjectID(rawValue: uuid(11)),
            revision: 1,
            acceptedAt: AgentInstant(rawValue: 1),
            productGoal: "   ",
            projectType: "utility",
            constraints: MissionStringSet(["offline", "\n"])
        )

        XCTAssertEqual(constitution.validationError, .missingProductGoal)

        let blankSet = MissionConstitution(
            missionID: MissionID(rawValue: uuid(12)),
            projectID: ProjectID(rawValue: uuid(13)),
            acceptedAt: AgentInstant(rawValue: 2),
            productGoal: "Calculator",
            projectType: "utility",
            constraints: MissionStringSet(["offline", "\n"])
        )
        XCTAssertEqual(blankSet.validationError, .blankSetValue)
    }

    func testProjectBrainRequiresSourceAuthorityNotOnlyModelSummary() {
        let instant = AgentInstant(rawValue: 50)
        let fact = ProjectBrainFact(
            factID: ProjectBrainFactID(rawValue: uuid(20)),
            projectID: ProjectID(rawValue: uuid(21)),
            missionID: MissionID(rawValue: uuid(22)),
            kind: .designDNA,
            statement: "Touch targets stay at least 44pt",
            scope: ProjectBrainScope(kind: .project),
            provenance: [
                ProjectBrainProvenance(
                    kind: .acceptedSummary,
                    reference: "mission-summary-4",
                    capturedAt: instant
                ),
            ],
            lastVerifiedAt: instant
        )

        XCTAssertFalse(fact.hasSourceAuthority)
        XCTAssertEqual(fact.validationError, .derivedOnlyProvenance)

        let sourced = fact.refreshed(
            provenance: [
                ProjectBrainProvenance(
                    kind: .userDecision,
                    reference: "plan-decision:touch-targets",
                    capturedAt: instant
                ),
                ProjectBrainProvenance(
                    kind: .acceptedSummary,
                    reference: "mission-summary-4",
                    capturedAt: instant
                ),
            ],
            verifiedAt: instant
        )
        XCTAssertTrue(sourced.hasSourceAuthority)
        XCTAssertNil(sourced.validationError)
    }

    func testProjectBrainStalenessPreservesAuthorityUntilRefresh() throws {
        let originalTime = AgentInstant(rawValue: 100)
        let source = ProjectBrainProvenance(
            kind: .sourceFile,
            reference: "AgentPad/Views/ForgeChrome.swift",
            capturedAt: originalTime,
            contentDigest: "sha256:abc123"
        )
        let current = ProjectBrainFact(
            factID: ProjectBrainFactID(rawValue: uuid(30)),
            projectID: ProjectID(rawValue: uuid(31)),
            kind: .sourceStructure,
            statement: "Forge chrome owns the primary action presentation",
            scope: ProjectBrainScope(
                kind: .file,
                reference: "AgentPad/Views/ForgeChrome.swift"
            ),
            provenance: [source],
            lastVerifiedAt: originalTime
        )

        let stale = current.markingStale(reason: "source digest changed")
        XCTAssertEqual(stale.freshness, .stale)
        XCTAssertEqual(stale.staleReason, "source digest changed")
        XCTAssertEqual(stale.provenance, current.provenance)
        XCTAssertEqual(stale.lastVerifiedAt, originalTime)
        XCTAssertNil(stale.validationError)

        let refreshedTime = AgentInstant(rawValue: 200)
        let refreshedSource = ProjectBrainProvenance(
            kind: .sourceFile,
            reference: "AgentPad/Views/ForgeChrome.swift",
            capturedAt: refreshedTime,
            contentDigest: "sha256:def456"
        )
        let refreshed = stale.refreshed(
            statement: "Forge chrome still owns the primary action presentation",
            provenance: [refreshedSource],
            verifiedAt: refreshedTime
        )

        XCTAssertEqual(refreshed.freshness, .current)
        XCTAssertNil(refreshed.staleReason)
        XCTAssertEqual(refreshed.lastVerifiedAt, refreshedTime)
        XCTAssertNil(refreshed.validationError)

        let roundTrip = try JSONDecoder().decode(
            ProjectBrainFact.self,
            from: JSONEncoder().encode(refreshed)
        )
        XCTAssertEqual(roundTrip, refreshed)
    }

    func testProjectBrainScopeAndStaleReasonValidation() {
        let instant = AgentInstant(rawValue: 500)
        let source = ProjectBrainProvenance(
            kind: .testEvidence,
            reference: "test:drive-flow",
            capturedAt: instant
        )
        let missingScope = ProjectBrainFact(
            factID: ProjectBrainFactID(rawValue: uuid(40)),
            projectID: ProjectID(rawValue: uuid(41)),
            kind: .testEvidence,
            statement: "Drive flow passed",
            scope: ProjectBrainScope(kind: .file),
            provenance: [source],
            lastVerifiedAt: instant
        )
        XCTAssertEqual(missingScope.validationError, .missingScopeReference)

        let staleWithoutReason = ProjectBrainFact(
            factID: ProjectBrainFactID(rawValue: uuid(42)),
            projectID: ProjectID(rawValue: uuid(43)),
            kind: .testEvidence,
            statement: "Drive flow passed",
            scope: ProjectBrainScope(kind: .runtime, reference: "forge-runtime"),
            provenance: [source],
            lastVerifiedAt: instant,
            freshness: .stale
        )
        XCTAssertEqual(staleWithoutReason.validationError, .missingStaleReason)
    }

    func testProjectBrainScopeRejectsWhitespaceAndControlAliases() throws {
        let canonical = ProjectBrainScope(
            kind: .file,
            reference: "AgentPad/Views/ForgeChrome.swift"
        )
        XCTAssertNil(canonical.validationError)

        let aliases = [
            " AgentPad/Views/ForgeChrome.swift",
            "AgentPad/Views/ForgeChrome.swift ",
            "AgentPad/Views/ForgeChrome.swift\n",
            "AgentPad/Views/Forge\tChrome.swift",
        ]

        for alias in aliases {
            let scope = ProjectBrainScope(kind: .file, reference: alias)
            XCTAssertEqual(scope.validationError, .nonCanonicalScopeReference, alias)

            let roundTrip = try JSONDecoder().decode(
                ProjectBrainScope.self,
                from: JSONEncoder().encode(scope)
            )
            XCTAssertEqual(roundTrip.validationError, .nonCanonicalScopeReference, alias)
        }

        XCTAssertEqual(
            ProjectBrainScope(kind: .project, reference: " ").validationError,
            .blankScopeReference
        )
        XCTAssertEqual(
            ProjectBrainScope(kind: .mission, reference: " ").validationError,
            .missingScopeReference
        )
    }

    func testProjectBrainProvenanceRejectsWhitespaceAndControlAliases() throws {
        let instant = AgentInstant(rawValue: 600)
        let canonical = ProjectBrainProvenance(
            kind: .sourceFile,
            reference: "AgentPad/Views/ForgeChrome.swift",
            capturedAt: instant
        )
        XCTAssertNil(canonical.validationError)

        let aliases = [
            " AgentPad/Views/ForgeChrome.swift",
            "AgentPad/Views/ForgeChrome.swift ",
            "AgentPad/Views/ForgeChrome.swift\r",
            "AgentPad/Views/Forge\tChrome.swift",
        ]

        for alias in aliases {
            let provenance = ProjectBrainProvenance(
                kind: .sourceFile,
                reference: alias,
                capturedAt: instant
            )
            XCTAssertEqual(provenance.validationError, .nonCanonicalProvenanceReference, alias)

            let roundTrip = try JSONDecoder().decode(
                ProjectBrainProvenance.self,
                from: JSONEncoder().encode(provenance)
            )
            XCTAssertEqual(roundTrip.validationError, .nonCanonicalProvenanceReference, alias)
        }

        XCTAssertEqual(
            ProjectBrainProvenance(
                kind: .sourceFile,
                reference: " ",
                capturedAt: instant
            ).validationError,
            .blankProvenanceReference
        )
    }

    private func uuid(_ value: UInt8) -> UUID {
        UUID(uuid: (
            0, 0, 0, 0,
            0, 0,
            0, 0,
            0, 0,
            0, 0,
            0, 0, 0, value
        ))
    }
}
