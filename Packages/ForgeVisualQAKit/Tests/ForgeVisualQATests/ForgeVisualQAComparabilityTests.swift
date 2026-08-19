import XCTest
@testable import ForgeVisualQA

final class ForgeVisualQAComparabilityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testScreenshotAndFrameSequenceAreNotInterchangeableRegressionEvidence() throws {
        let screenshot = try trustedCapture(kind: .runtimeScreenshot, digestByte: "a")
        let sequence = try trustedCapture(kind: .runtimeFrameSequence, digestByte: "b")
        XCTAssertEqual(
            VisualRegressionComparator.compare(baseline: screenshot, candidate: sequence),
            .notComparable(.differentEvidenceKind)
        )
    }

    func testDifferentSourceRevisionsAreNotComparableRegressionEvidence() throws {
        let baseline = try trustedCapture(sourceRevision: "r1", digestByte: "a")
        let candidate = try trustedCapture(sourceRevision: "r2", digestByte: "b")
        XCTAssertEqual(
            VisualRegressionComparator.compare(baseline: baseline, candidate: candidate),
            .notComparable(.differentProject)
        )
    }

    func testAutoPolishRejectsMixedViewportHistory() throws {
        let portrait = try trustedCapture(frame: 1, digestByte: "a")
        let landscape = try trustedCapture(
            frame: 2,
            viewport: VisualViewport(
                width: 844,
                height: 390,
                scale: 3,
                orientation: .landscape,
                safeArea: .init(top: 0, leading: 47, bottom: 21, trailing: 47)
            ),
            digestByte: "b"
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

    private func trustedCapture(
        frame: UInt64 = 0,
        viewport: VisualViewport? = nil,
        kind: VisualEvidenceKind = .runtimeScreenshot,
        sourceRevision: String = "r1",
        digestByte: String
    ) throws -> VisualTrustedCapture {
        let capture = try VisualCaptureReceipt(
            project: .init(projectID: "project-1", sourceRevision: sourceRevision),
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
        return try VisualTrustedCapture(
            authenticatedCapture: capture,
            artifactSHA256: String(repeating: digestByte, count: 64)
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
