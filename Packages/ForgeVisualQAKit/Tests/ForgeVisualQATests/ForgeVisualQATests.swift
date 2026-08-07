import XCTest
@testable import ForgeVisualQA

final class ForgeVisualQATests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testCaptureRejectsBlankProjectRevisionSessionAndInvalidViewport() throws {
        XCTAssertThrowsError(try capture(projectID: "", revision: "r1"))
        XCTAssertThrowsError(try capture(projectID: "p", revision: ""))
        XCTAssertThrowsError(try capture(session: ""))
        let badViewport = VisualViewport(
            width: 0,
            height: 844,
            scale: 3,
            orientation: .portrait,
            safeArea: .init(top: 47, leading: 0, bottom: 34, trailing: 0)
        )
        XCTAssertThrowsError(try capture(viewport: badViewport))
    }

    func testSourceInspectionIsNeverRuntimeVisualProof() throws {
        XCTAssertFalse(try capture(kind: .sourceInspection).isRuntimeVisualProof)
        XCTAssertTrue(try capture(kind: .runtimeScreenshot).isRuntimeVisualProof)
        XCTAssertTrue(try capture(kind: .runtimeFrameSequence).isRuntimeVisualProof)
    }

    func testRegressionComparisonAllowsDifferentRevisionsForSameControlledViewport() throws {
        let baseline = try capture(revision: "before")
        let candidate = try capture(revision: "after", session: "session-2")
        XCTAssertEqual(VisualRegressionComparator.compare(baseline: baseline, candidate: candidate), .comparable)
    }

    func testRegressionComparisonRejectsSourceOnlyDifferentProjectViewportAndAccessibility() throws {
        let baseline = try capture()
        XCTAssertEqual(
            VisualRegressionComparator.compare(baseline: baseline, candidate: try capture(kind: .sourceInspection)),
            .notComparable(.insufficientVisualEvidence)
        )
        XCTAssertEqual(
            VisualRegressionComparator.compare(baseline: baseline, candidate: try capture(projectID: "other")),
            .notComparable(.differentProject)
        )
        let landscape = VisualViewport(
            width: 844,
            height: 390,
            scale: 3,
            orientation: .landscape,
            safeArea: .init(top: 0, leading: 47, bottom: 21, trailing: 47)
        )
        XCTAssertEqual(
            VisualRegressionComparator.compare(baseline: baseline, candidate: try capture(viewport: landscape)),
            .notComparable(.differentViewport)
        )
        let contrast = VisualAccessibilityState(
            reduceMotion: false,
            reduceTransparency: false,
            increaseContrast: true,
            differentiateWithoutColor: false,
            dynamicTypeCategory: "large"
        )
        XCTAssertEqual(
            VisualRegressionComparator.compare(baseline: baseline, candidate: try capture(accessibility: contrast)),
            .notComparable(.differentAccessibilityState)
        )
    }

    func testFirstMinuteAssessmentRequiresEveryCriterionAndCurrentRuntimeCaptureForVisualChecks() throws {
        let currentCapture = try capture()
        var observations = FirstMinuteCriterion.allCases.map {
            FirstMinuteObservation(criterion: $0, passed: true, captureID: currentCapture.id)
        }
        XCTAssertTrue(FirstMinuteAssessment(capture: currentCapture, observations: observations).passes)

        observations.removeLast()
        XCTAssertFalse(FirstMinuteAssessment(capture: currentCapture, observations: observations).passes)

        let staleID = UUID()
        let stale = FirstMinuteCriterion.allCases.map {
            FirstMinuteObservation(criterion: $0, passed: true, captureID: staleID)
        }
        XCTAssertFalse(FirstMinuteAssessment(capture: currentCapture, observations: stale).passes)
    }

    func testFirstMinuteAssessmentRejectsSourceOnlyVisualClaims() throws {
        let sourceOnly = try capture(kind: .sourceInspection)
        let observations = FirstMinuteCriterion.allCases.map { criterion in
            FirstMinuteObservation(criterion: criterion, passed: true, captureID: sourceOnly.id)
        }
        XCTAssertFalse(FirstMinuteAssessment(capture: sourceOnly, observations: observations).passes)
    }

    func testFirstMinuteAssessmentFailsOnAnyFailedCriterion() throws {
        let currentCapture = try capture()
        let observations = FirstMinuteCriterion.allCases.map { criterion in
            FirstMinuteObservation(
                criterion: criterion,
                passed: criterion != .primaryActionIsDiscoverable,
                captureID: currentCapture.id
            )
        }
        let assessment = FirstMinuteAssessment(capture: currentCapture, observations: observations)
        XCTAssertFalse(assessment.passes)
        XCTAssertEqual(assessment.failedCriteria, [.primaryActionIsDiscoverable])
    }

    func testSelectionIdentityRequiresExactRuntimeProjectRevisionAndSession() throws {
        let capture = try capture(revision: "r2", session: "session-2")
        let selection = try VisualSelectionIdentity(
            kind: .domElement,
            project: .init(projectID: "project-1", sourceRevision: "r2"),
            runtimeSessionID: "session-2",
            runtimeNodeID: "button:start",
            source: .init(path: "src/App.js", symbol: "startButton")
        )
        XCTAssertTrue(selection.isValid(for: capture))
        XCTAssertFalse(selection.isValid(for: try self.capture(revision: "r3", session: "session-2")))
        XCTAssertFalse(selection.isValid(for: try self.capture(revision: "r2", session: "other")))
    }

    func testSelectionRejectsBlankNodeOrSourcePath() {
        XCTAssertThrowsError(
            try VisualSelectionIdentity(
                kind: .sceneEntity,
                project: .init(projectID: "p", sourceRevision: "r"),
                runtimeSessionID: "s",
                runtimeNodeID: "",
                source: .init(path: "scene.js")
            )
        )
        XCTAssertThrowsError(
            try VisualSelectionIdentity(
                kind: .sceneEntity,
                project: .init(projectID: "p", sourceRevision: "r"),
                runtimeSessionID: "s",
                runtimeNodeID: "car",
                source: .init(path: " ")
            )
        )
    }

    func testAutoPolishRefusesToPolishPastFunctionalBlocker() throws {
        let currentCapture = try capture()
        let crash = finding(kind: .runtimeCrash, severity: .blocker, captureID: currentCapture.id)
        let spacing = finding(kind: .awkwardSpacing, severity: .minor, captureID: currentCapture.id)
        let pass = AutoPolishPass(capture: currentCapture, findings: [spacing, crash], improvementScore: 0.5)
        XCTAssertEqual(
            AutoPolishPlanner.decide(passes: [pass]),
            .repairFunctionalBlocker(crash)
        )
    }

    func testAutoPolishRejectsUnevidencedOrStaleFindings() throws {
        let currentCapture = try capture()
        let unsupported = finding(kind: .clipping, severity: .major, captureID: nil)
        let stale = finding(kind: .overlap, severity: .major, captureID: UUID())
        XCTAssertEqual(
            AutoPolishPlanner.decide(
                passes: [AutoPolishPass(capture: currentCapture, findings: [unsupported], improvementScore: 0.5)]
            ),
            .stop(.insufficientVisualEvidence)
        )
        XCTAssertEqual(
            AutoPolishPlanner.decide(
                passes: [AutoPolishPass(capture: currentCapture, findings: [stale], improvementScore: 0.5)]
            ),
            .stop(.insufficientVisualEvidence)
        )
    }

    func testAutoPolishPrioritizesSeverityThenMeaningfulKind() throws {
        let currentCapture = try capture()
        let overlap = finding(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            kind: .overlap,
            severity: .major,
            captureID: currentCapture.id
        )
        let clipping = finding(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            kind: .clipping,
            severity: .major,
            captureID: currentCapture.id
        )
        let pass = AutoPolishPass(capture: currentCapture, findings: [overlap, clipping], improvementScore: 0.5)
        XCTAssertEqual(AutoPolishPlanner.decide(passes: [pass]), .fixVisualFinding(clipping))
    }

    func testAutoPolishStopsWhenAccepted() throws {
        let pass = AutoPolishPass(capture: try capture(), findings: [], improvementScore: 0.3)
        XCTAssertEqual(AutoPolishPlanner.decide(passes: [pass]), .stop(.acceptancePassed))
    }

    func testAutoPolishStopsAtMaxPassesBeforeChoosingCosmeticWork() throws {
        let passes = (0..<3).map { index -> AutoPolishPass in
            let currentCapture = try! capture(frame: UInt64(index))
            let issue = finding(kind: .cosmeticPolish, severity: .cosmetic, captureID: currentCapture.id)
            return AutoPolishPass(capture: currentCapture, findings: [issue], improvementScore: 0.2)
        }
        XCTAssertEqual(
            AutoPolishPlanner.decide(passes: passes, policy: .init(maximumPasses: 3)),
            .stop(.maximumPassesReached)
        )
    }

    func testAutoPolishStopsOnImprovementPlateau() throws {
        let firstCapture = try capture(frame: 1)
        let secondCapture = try capture(frame: 2)
        let passes = [
            AutoPolishPass(
                capture: firstCapture,
                findings: [finding(kind: .awkwardSpacing, severity: .minor, captureID: firstCapture.id)],
                improvementScore: 0.01
            ),
            AutoPolishPass(
                capture: secondCapture,
                findings: [finding(kind: .awkwardSpacing, severity: .minor, captureID: secondCapture.id)],
                improvementScore: 0.02
            ),
        ]
        XCTAssertEqual(
            AutoPolishPlanner.decide(
                passes: passes,
                policy: .init(maximumPasses: 8, plateauWindow: 2, minimumMeaningfulImprovement: 0.05)
            ),
            .stop(.improvementPlateau)
        )
    }

    func testAutoPolishHonorsUserAndDependencyStops() throws {
        let currentCapture = try capture()
        let issue = finding(kind: .clipping, severity: .major, captureID: currentCapture.id)
        let pass = AutoPolishPass(capture: currentCapture, findings: [issue], improvementScore: 0.5)
        XCTAssertEqual(AutoPolishPlanner.decide(passes: [pass], userPaused: true), .stop(.userPaused))
        XCTAssertEqual(AutoPolishPlanner.decide(passes: [pass], dependencyBlocked: true), .stop(.dependencyBlocked))
    }

    func testAutoPolishRequiresRuntimeVisualEvidence() throws {
        let sourceOnly = try capture(kind: .sourceInspection)
        let issue = finding(kind: .clipping, severity: .major, captureID: sourceOnly.id)
        let pass = AutoPolishPass(capture: sourceOnly, findings: [issue], improvementScore: 0.5)
        XCTAssertEqual(AutoPolishPlanner.decide(passes: [pass]), .stop(.insufficientVisualEvidence))
    }

    func testAutoPolishPassClampsImprovementScore() throws {
        let currentCapture = try capture()
        XCTAssertEqual(
            AutoPolishPass(capture: currentCapture, findings: [], improvementScore: 4).improvementScore,
            1
        )
        XCTAssertEqual(
            AutoPolishPass(capture: currentCapture, findings: [], improvementScore: -2).improvementScore,
            0
        )
    }

    func testPolicyClampsUnsafeConfiguration() {
        let policy = AutoPolishPolicy(maximumPasses: 0, plateauWindow: 0, minimumMeaningfulImprovement: -1)
        XCTAssertEqual(policy.maximumPasses, 1)
        XCTAssertEqual(policy.plateauWindow, 1)
        XCTAssertEqual(policy.minimumMeaningfulImprovement, 0)
    }

    func testCaptureAndSelectionRoundTripRemainStable() throws {
        let capture = try capture()
        let selection = try VisualSelectionIdentity(
            kind: .hudElement,
            project: capture.project,
            runtimeSessionID: capture.runtimeSessionID,
            runtimeNodeID: "hud:speed",
            source: .init(path: "src/hud.js", symbol: "speedHUD")
        )
        let encoder = JSONEncoder()
        let decodedCapture = try JSONDecoder().decode(VisualCaptureReceipt.self, from: encoder.encode(capture))
        let decodedSelection = try JSONDecoder().decode(VisualSelectionIdentity.self, from: encoder.encode(selection))
        XCTAssertEqual(decodedCapture, capture)
        XCTAssertEqual(decodedSelection, selection)
    }

    private func capture(
        projectID: String = "project-1",
        revision: String = "r1",
        session: String = "session-1",
        frame: UInt64 = 0,
        viewport: VisualViewport? = nil,
        accessibility: VisualAccessibilityState? = nil,
        kind: VisualEvidenceKind = .runtimeScreenshot
    ) throws -> VisualCaptureReceipt {
        try VisualCaptureReceipt(
            project: .init(projectID: projectID, sourceRevision: revision),
            runtimeSessionID: session,
            frameOrdinal: frame,
            viewport: viewport ?? VisualViewport(
                width: 390,
                height: 844,
                scale: 3,
                orientation: .portrait,
                safeArea: .init(top: 47, leading: 0, bottom: 34, trailing: 0)
            ),
            accessibility: accessibility ?? VisualAccessibilityState(
                reduceMotion: false,
                reduceTransparency: false,
                increaseContrast: false,
                differentiateWithoutColor: false,
                dynamicTypeCategory: "large"
            ),
            evidenceKind: kind,
            capturedAt: now
        )
    }

    private func finding(
        id: UUID = UUID(),
        kind: VisualFindingKind,
        severity: VisualFindingSeverity,
        captureID: UUID?
    ) -> VisualFinding {
        VisualFinding(
            id: id,
            kind: kind,
            severity: severity,
            summary: kind.rawValue,
            captureID: captureID
        )
    }
}
