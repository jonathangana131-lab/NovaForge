import XCTest
@testable import ForgeVisualQA

final class ForgeVisualQATests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let artifactDigest = String(repeating: "a", count: 64)

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

    func testCandidateRuntimeKindIsOnlyStructuralMetadata() throws {
        XCTAssertFalse(try capture(kind: .sourceInspection).claimsRuntimeVisualEvidence)
        XCTAssertTrue(try capture(kind: .runtimeScreenshot).claimsRuntimeVisualEvidence)
        XCTAssertTrue(try capture(kind: .runtimeFrameSequence).claimsRuntimeVisualEvidence)
    }

    func testTrustedCaptureRejectsSourceInspectionAndMalformedArtifactDigest() throws {
        XCTAssertThrowsError(
            try VisualTrustedCapture(
                authenticatedCapture: capture(kind: .sourceInspection),
                artifactSHA256: artifactDigest
            )
        ) { error in
            XCTAssertEqual(error as? VisualQAInvariantError, .nonRuntimeCaptureCannotBeTrusted)
        }

        for digest in ["", String(repeating: "a", count: 63), String(repeating: "A", count: 64), String(repeating: "g", count: 64)] {
            XCTAssertThrowsError(
                try VisualTrustedCapture(
                    authenticatedCapture: capture(),
                    artifactSHA256: digest
                )
            ) { error in
                XCTAssertEqual(error as? VisualQAInvariantError, .invalidArtifactDigest)
            }
        }
    }

    func testRegressionComparisonAllowsDifferentRevisionsForSameControlledViewport() throws {
        let baseline = try trustedCapture(revision: "before")
        let candidate = try trustedCapture(revision: "after", session: "session-2", digestByte: "b")
        XCTAssertEqual(VisualRegressionComparator.compare(baseline: baseline, candidate: candidate), .comparable)
    }

    func testRegressionComparisonRejectsDifferentProjectKindViewportAndAccessibility() throws {
        let baseline = try trustedCapture()
        XCTAssertEqual(
            VisualRegressionComparator.compare(
                baseline: baseline,
                candidate: try trustedCapture(projectID: "other", digestByte: "b")
            ),
            .notComparable(.differentProject)
        )
        XCTAssertEqual(
            VisualRegressionComparator.compare(
                baseline: baseline,
                candidate: try trustedCapture(kind: .runtimeFrameSequence, digestByte: "b")
            ),
            .notComparable(.differentEvidenceKind)
        )
        let landscape = VisualViewport(
            width: 844,
            height: 390,
            scale: 3,
            orientation: .landscape,
            safeArea: .init(top: 0, leading: 47, bottom: 21, trailing: 47)
        )
        XCTAssertEqual(
            VisualRegressionComparator.compare(
                baseline: baseline,
                candidate: try trustedCapture(viewport: landscape, digestByte: "b")
            ),
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
            VisualRegressionComparator.compare(
                baseline: baseline,
                candidate: try trustedCapture(accessibility: contrast, digestByte: "b")
            ),
            .notComparable(.differentAccessibilityState)
        )
    }

    func testFirstMinuteAssessmentRequiresEveryCriterionAndCurrentTrustedAnalysis() throws {
        let currentCapture = try trustedCapture()
        var observations = FirstMinuteCriterion.allCases.map {
            FirstMinuteObservation(criterion: $0, passed: true, captureID: currentCapture.id)
        }
        XCTAssertTrue(
            FirstMinuteAssessment(
                acceptedAnalysis: try trustedAnalysis(capture: currentCapture, observations: observations)
            ).passes
        )

        observations.removeLast()
        XCTAssertFalse(
            FirstMinuteAssessment(
                acceptedAnalysis: try trustedAnalysis(capture: currentCapture, observations: observations)
            ).passes
        )
    }

    func testTrustedAnalysisRejectsStaleVisualObservation() throws {
        let currentCapture = try trustedCapture()
        let stale = FirstMinuteCriterion.allCases.map {
            FirstMinuteObservation(criterion: $0, passed: true, captureID: UUID())
        }
        XCTAssertThrowsError(try trustedAnalysis(capture: currentCapture, observations: stale)) { error in
            guard case VisualAnalysisAuthorityError.observationCaptureMismatch = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testTrustedAnalysisRejectsDuplicateFirstMinuteCriterion() throws {
        let currentCapture = try trustedCapture()
        let observations = [
            FirstMinuteObservation(criterion: .purposeIsClear, passed: true, captureID: currentCapture.id),
            FirstMinuteObservation(criterion: .purposeIsClear, passed: false, captureID: currentCapture.id),
        ]
        XCTAssertThrowsError(try trustedAnalysis(capture: currentCapture, observations: observations)) { error in
            XCTAssertEqual(
                error as? VisualAnalysisAuthorityError,
                .duplicateObservationCriterion(.purposeIsClear)
            )
        }
    }

    func testFirstMinuteAssessmentFailsOnAnyFailedCriterion() throws {
        let currentCapture = try trustedCapture()
        let observations = FirstMinuteCriterion.allCases.map { criterion in
            FirstMinuteObservation(
                criterion: criterion,
                passed: criterion != .primaryActionIsDiscoverable,
                captureID: currentCapture.id
            )
        }
        let assessment = FirstMinuteAssessment(
            acceptedAnalysis: try trustedAnalysis(capture: currentCapture, observations: observations)
        )
        XCTAssertFalse(assessment.passes)
        XCTAssertEqual(assessment.failedCriteria, [.primaryActionIsDiscoverable])
    }

    func testSelectionIdentityRequiresExactTrustedRuntimeProjectRevisionAndSession() throws {
        let capture = try trustedCapture(revision: "r2", session: "session-2")
        let selection = try VisualSelectionIdentity(
            kind: .domElement,
            project: .init(projectID: "project-1", sourceRevision: "r2"),
            runtimeSessionID: "session-2",
            runtimeNodeID: "button:start",
            source: .init(path: "src/App.js", symbol: "startButton")
        )
        XCTAssertTrue(selection.isValid(for: capture))
        XCTAssertFalse(selection.isValid(for: try trustedCapture(revision: "r3", session: "session-2", digestByte: "b")))
        XCTAssertFalse(selection.isValid(for: try trustedCapture(revision: "r2", session: "other", digestByte: "b")))
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
        let currentCapture = try trustedCapture()
        let crash = finding(kind: .runtimeCrash, severity: .blocker, captureID: currentCapture.id)
        let spacing = finding(kind: .awkwardSpacing, severity: .minor, captureID: currentCapture.id)
        let pass = try acceptedPass(capture: currentCapture, findings: [spacing, crash], improvementScore: 0.5)
        XCTAssertEqual(
            AutoPolishPlanner.decide(passes: [pass]),
            .repairFunctionalBlocker(crash)
        )
    }

    func testTrustedAnalysisRejectsUnevidencedOrStaleFindings() throws {
        let currentCapture = try trustedCapture()
        let unsupported = finding(kind: .clipping, severity: .major, captureID: nil)
        let stale = finding(kind: .overlap, severity: .major, captureID: UUID())

        for invalidFinding in [unsupported, stale] {
            XCTAssertThrowsError(
                try trustedAnalysis(
                    capture: currentCapture,
                    findings: [invalidFinding],
                    improvementScore: 0.5
                )
            ) { error in
                XCTAssertEqual(
                    error as? VisualAnalysisAuthorityError,
                    .findingCaptureMismatch(invalidFinding.id)
                )
            }
        }
    }

    func testAutoPolishPrioritizesSeverityThenMeaningfulKind() throws {
        let currentCapture = try trustedCapture()
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
        let pass = try acceptedPass(capture: currentCapture, findings: [overlap, clipping], improvementScore: 0.5)
        XCTAssertEqual(AutoPolishPlanner.decide(passes: [pass]), .fixVisualFinding(clipping))
    }

    func testAutoPolishStopsWhenAcceptedOnlyWithTrustedAnalysis() throws {
        let pass = try acceptedPass(capture: trustedCapture(), findings: [], improvementScore: 0.3)
        XCTAssertEqual(AutoPolishPlanner.decide(passes: [pass]), .stop(.acceptancePassed))
    }

    func testAutoPolishStopsAtMaxPassesBeforeChoosingCosmeticWork() throws {
        let passes = try (0..<3).map { index -> AutoPolishPass in
            let currentCapture = try trustedCapture(frame: UInt64(index), digestByte: String(index + 1))
            let issue = finding(kind: .cosmeticPolish, severity: .cosmetic, captureID: currentCapture.id)
            return try acceptedPass(capture: currentCapture, findings: [issue], improvementScore: 0.2)
        }
        XCTAssertEqual(
            AutoPolishPlanner.decide(passes: passes, policy: .init(maximumPasses: 3)),
            .stop(.maximumPassesReached)
        )
    }

    func testAutoPolishStopsOnImprovementPlateau() throws {
        let firstCapture = try trustedCapture(frame: 1, digestByte: "1")
        let secondCapture = try trustedCapture(frame: 2, digestByte: "2")
        let passes = [
            try acceptedPass(
                capture: firstCapture,
                findings: [finding(kind: .awkwardSpacing, severity: .minor, captureID: firstCapture.id)],
                improvementScore: 0.01
            ),
            try acceptedPass(
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
        let currentCapture = try trustedCapture()
        let issue = finding(kind: .clipping, severity: .major, captureID: currentCapture.id)
        let pass = try acceptedPass(capture: currentCapture, findings: [issue], improvementScore: 0.5)
        XCTAssertEqual(AutoPolishPlanner.decide(passes: [pass], userPaused: true), .stop(.userPaused))
        XCTAssertEqual(AutoPolishPlanner.decide(passes: [pass], dependencyBlocked: true), .stop(.dependencyBlocked))
    }

    func testTrustedAnalysisRejectsInvalidImprovementScore() throws {
        let currentCapture = try trustedCapture()
        for score in [Double.nan, Double.infinity, -0.01, 1.01] {
            XCTAssertThrowsError(
                try trustedAnalysis(capture: currentCapture, improvementScore: score)
            ) { error in
                XCTAssertEqual(error as? VisualAnalysisAuthorityError, .invalidImprovementScore)
            }
        }
    }

    func testTrustedAnalysisRejectsNonCanonicalAnalyzerReceipt() throws {
        let currentCapture = try trustedCapture()
        for receipt in ["", " receipt", "receipt ", "receipt\nother"] {
            XCTAssertThrowsError(
                try trustedAnalysis(capture: currentCapture, analyzerReceiptID: receipt)
            ) { error in
                XCTAssertEqual(error as? VisualAnalysisAuthorityError, .invalidAnalyzerReceipt)
            }
        }
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

    private func trustedCapture(
        projectID: String = "project-1",
        revision: String = "r1",
        session: String = "session-1",
        frame: UInt64 = 0,
        viewport: VisualViewport? = nil,
        accessibility: VisualAccessibilityState? = nil,
        kind: VisualEvidenceKind = .runtimeScreenshot,
        digestByte: String = "a"
    ) throws -> VisualTrustedCapture {
        let receipt = try capture(
            projectID: projectID,
            revision: revision,
            session: session,
            frame: frame,
            viewport: viewport,
            accessibility: accessibility,
            kind: kind
        )
        return try VisualTrustedCapture(
            authenticatedCapture: receipt,
            artifactSHA256: String(repeating: digestByte, count: 64)
        )
    }

    private func trustedAnalysis(
        capture: VisualTrustedCapture,
        observations: [FirstMinuteObservation] = [],
        findings: [VisualFinding] = [],
        improvementScore: Double = 0,
        analyzerReceiptID: String = "analyzer-receipt"
    ) throws -> VisualTrustedAnalysis {
        try VisualTrustedAnalysis(
            authenticatedCapture: capture,
            observations: observations,
            findings: findings,
            improvementScore: improvementScore,
            analyzerReceiptID: analyzerReceiptID
        )
    }

    private func acceptedPass(
        capture: VisualTrustedCapture,
        findings: [VisualFinding],
        improvementScore: Double
    ) throws -> AutoPolishPass {
        AutoPolishPass(
            acceptedAnalysis: try trustedAnalysis(
                capture: capture,
                findings: findings,
                improvementScore: improvementScore,
                analyzerReceiptID: "analyzer-\(capture.id.uuidString)"
            )
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
