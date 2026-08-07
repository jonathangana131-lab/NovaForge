import XCTest
@testable import ForgeVisualQA

final class ForgeVisualQAComparabilityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testScreenshotAndFrameSequenceAreNotInterchangeableRegressionEvidence() throws {
        let screenshot = try capture(kind: .runtimeScreenshot)
        let sequence = try capture(kind: .runtimeFrameSequence)
        XCTAssertEqual(
            VisualRegressionComparator.compare(baseline: screenshot, candidate: sequence),
            .notComparable(.differentEvidenceKind)
        )
    }

    func testAutoPolishRejectsMixedViewportHistory() throws {
        let portrait = try capture(frame: 1)
        let landscape = try capture(
            frame: 2,
            viewport: VisualViewport(
                width: 844,
                height: 390,
                scale: 3,
                orientation: .landscape,
                safeArea: .init(top: 0, leading: 47, bottom: 21, trailing: 47)
            )
        )
        let passes = [
            AutoPolishPass(
                capture: portrait,
                findings: [finding(captureID: portrait.id)],
                improvementScore: 0.1
            ),
            AutoPolishPass(
                capture: landscape,
                findings: [finding(captureID: landscape.id)],
                improvementScore: 0.1
            ),
        ]
        XCTAssertEqual(AutoPolishPlanner.decide(passes: passes), .stop(.insufficientVisualEvidence))
    }

    private func capture(
        frame: UInt64 = 0,
        viewport: VisualViewport? = nil,
        kind: VisualEvidenceKind = .runtimeScreenshot
    ) throws -> VisualCaptureReceipt {
        try VisualCaptureReceipt(
            project: .init(projectID: "project-1", sourceRevision: "r1"),
            runtimeSessionID: "session-1",
            frameOrdinal: frame,
            viewport: viewport ?? VisualViewport(
                width: 390,
                height: 844,
                scale: 3,
                orientation: .portrait,
                safeArea: .init(top: 47, leading: 0, bottom: 34, trailing: 0)
            ),
            accessibility: VisualAccessibilityState(
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

    private func finding(captureID: UUID) -> VisualFinding {
        VisualFinding(
            kind: .awkwardSpacing,
            severity: .minor,
            summary: "Spacing needs work",
            captureID: captureID
        )
    }
}
