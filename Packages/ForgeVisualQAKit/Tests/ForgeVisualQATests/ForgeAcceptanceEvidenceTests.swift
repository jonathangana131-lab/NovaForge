import XCTest
@testable import ForgeVisualQA

final class ForgeAcceptanceEvidenceTests: XCTestCase {
    private func capture(kind: VisualEvidenceKind = .runtimeFrameSequence, revision: String = "r1") throws -> VisualCaptureReceipt {
        try VisualCaptureReceipt(
            project: .init(projectID: "project", sourceRevision: revision),
            runtimeSessionID: "session",
            frameOrdinal: 100,
            viewport: .init(width: 390, height: 844, scale: 3, orientation: .portrait, safeArea: .init(top: 47, leading: 0, bottom: 34, trailing: 0)),
            accessibility: .init(reduceMotion: false, reduceTransparency: false, increaseContrast: false, differentiateWithoutColor: false, dynamicTypeCategory: "large"),
            evidenceKind: kind,
            capturedAt: Date(timeIntervalSince1970: 100)
        )
    }

    private func environment(_ kind: VisualExecutionEnvironmentKind = .simulator) throws -> VisualExecutionEnvironmentIdentity {
        try .init(kind: kind, deviceModelIdentifier: "iPhone13,2", osVersion: "27.0", runtimeVersion: "forge-runtime-1")
    }

    func testAccessibilityAcceptsConcreteRequiredEvidence() throws {
        let receipt = try VisualAccessibilityReceipt(
            capture: capture(kind: .runtimeScreenshot),
            environment: environment(),
            observations: [
                try .init(check: .voiceOverTraversal, passed: true, source: .accessibilityTree),
                try .init(check: .minimumTouchTarget, passed: true, source: .measuredGeometry),
            ]
        )
        let policy = try VisualAccessibilityAcceptancePolicy(requiredChecks: [.voiceOverTraversal, .minimumTouchTarget])
        XCTAssertEqual(VisualAccessibilityEvidenceEvaluator.evaluate(receipt: receipt, policy: policy), .accepted(receiptID: receipt.id))
    }

    func testAccessibilityMissingAndFailedChecksBlock() throws {
        let receipt = try VisualAccessibilityReceipt(
            capture: capture(kind: .runtimeScreenshot), environment: environment(),
            observations: [try .init(check: .voiceOverTraversal, passed: false, source: .runtimeInteraction)]
        )
        let policy = try VisualAccessibilityAcceptancePolicy(requiredChecks: [.voiceOverTraversal, .dynamicTypeLayout])
        let verdict = VisualAccessibilityEvidenceEvaluator.evaluate(receipt: receipt, policy: policy)
        guard case let .blocked(blockers) = verdict else { return XCTFail("expected blocked") }
        XCTAssertTrue(blockers.contains(.failedChecks([.voiceOverTraversal])))
        XCTAssertTrue(blockers.contains(.missingChecks([.dynamicTypeLayout])))
    }

    func testModelAssertionCannotBecomeAccessibilityEvidence() throws {
        XCTAssertThrowsError(try VisualAccessibilityObservation(check: .textContrast, passed: true, source: .modelAssertion))
    }

    func testDuplicateAccessibilityCheckFailsClosed() throws {
        XCTAssertThrowsError(try VisualAccessibilityReceipt(
            capture: capture(kind: .runtimeScreenshot), environment: environment(),
            observations: [
                try .init(check: .textContrast, passed: true, source: .screenshotMeasurement),
                try .init(check: .textContrast, passed: true, source: .screenshotMeasurement),
            ]
        ))
    }

    func testSourceInspectionCannotBackAcceptanceReceipt() throws {
        XCTAssertThrowsError(try VisualAccessibilityReceipt(
            capture: capture(kind: .sourceInspection), environment: environment(),
            observations: [try .init(check: .textContrast, passed: true, source: .screenshotMeasurement)]
        ))
    }

    func testPhysicalDeviceRequirementRejectsSimulatorAccessibilityEvidence() throws {
        let receipt = try VisualAccessibilityReceipt(
            capture: capture(kind: .runtimeScreenshot), environment: environment(.simulator),
            observations: [try .init(check: .dynamicTypeLayout, passed: true, source: .systemPreferenceExercise)]
        )
        let policy = try VisualAccessibilityAcceptancePolicy(requiredChecks: [.dynamicTypeLayout], requiresPhysicalDevice: true)
        XCTAssertEqual(VisualAccessibilityEvidenceEvaluator.evaluate(receipt: receipt, policy: policy), .blocked([.physicalDeviceRequired]))
    }

    func testPerformanceSummaryAndAcceptanceAreDerivedFromSamples() throws {
        let samples = try [10.0, 11, 12, 13, 30].enumerated().map {
            try VisualFramePerformanceSample(frameOrdinal: UInt64($0.offset), frameDurationMilliseconds: $0.element, dropped: false)
        }
        let receipt = try VisualPerformanceReceipt(capture: capture(), environment: environment(.physicalDevice), samples: samples)
        XCTAssertEqual(receipt.summary.sampleCount, 5)
        XCTAssertEqual(receipt.summary.p95FrameDurationMilliseconds, 30)
        XCTAssertEqual(receipt.summary.worstFrameDurationMilliseconds, 30)
        let policy = try VisualPerformanceAcceptancePolicy(minimumSampleCount: 5, maximumP95FrameDurationMilliseconds: 31, maximumWorstFrameDurationMilliseconds: 31, maximumDroppedFrameRatio: 0, requiresPhysicalDevice: true)
        guard case .accepted = VisualPerformanceEvidenceEvaluator.evaluate(receipt: receipt, policy: policy) else { return XCTFail("expected accepted") }
    }

    func testPerformanceGateReportsAllMaterialViolations() throws {
        let samples = [
            try VisualFramePerformanceSample(frameOrdinal: 1, frameDurationMilliseconds: 10, dropped: false),
            try VisualFramePerformanceSample(frameOrdinal: 2, frameDurationMilliseconds: 40, dropped: true),
        ]
        let receipt = try VisualPerformanceReceipt(capture: capture(), environment: environment(), samples: samples)
        let policy = try VisualPerformanceAcceptancePolicy(minimumSampleCount: 3, maximumP95FrameDurationMilliseconds: 20, maximumWorstFrameDurationMilliseconds: 30, maximumDroppedFrameRatio: 0.1, requiresPhysicalDevice: true)
        guard case let .blocked(blockers) = VisualPerformanceEvidenceEvaluator.evaluate(receipt: receipt, policy: policy) else { return XCTFail("expected blocked") }
        XCTAssertEqual(blockers.count, 5)
    }

    func testPerformanceRejectsScreenshotAndUnorderedFrames() throws {
        XCTAssertThrowsError(try VisualPerformanceReceipt(
            capture: capture(kind: .runtimeScreenshot), environment: environment(),
            samples: [try .init(frameOrdinal: 1, frameDurationMilliseconds: 16, dropped: false)]
        ))
        XCTAssertThrowsError(try VisualPerformanceReceipt(
            capture: capture(), environment: environment(),
            samples: [
                try .init(frameOrdinal: 2, frameDurationMilliseconds: 16, dropped: false),
                try .init(frameOrdinal: 2, frameDurationMilliseconds: 16, dropped: false),
            ]
        ))
    }

    func testPerformanceRejectsNonFiniteSampleAndInvalidPolicy() throws {
        XCTAssertThrowsError(try VisualFramePerformanceSample(frameOrdinal: 1, frameDurationMilliseconds: .infinity, dropped: false))
        XCTAssertThrowsError(try VisualPerformanceAcceptancePolicy(minimumSampleCount: 0, maximumP95FrameDurationMilliseconds: 16, maximumWorstFrameDurationMilliseconds: 20, maximumDroppedFrameRatio: 0))
    }

    func testDecodedAccessibilityObservationRevalidatesModelAssertion() throws {
        let data = #"{"check":"textContrast","passed":true,"source":"modelAssertion"}"#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(VisualAccessibilityObservation.self, from: data))
    }

    func testPerformanceArchiveRejectsForgedSummary() throws {
        let receipt = try VisualPerformanceReceipt(
            capture: capture(), environment: environment(),
            samples: [try .init(frameOrdinal: 1, frameDurationMilliseconds: 16, dropped: false)]
        )
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)) as? [String: Any])
        var summary = try XCTUnwrap(object["summary"] as? [String: Any])
        summary["worstFrameDurationMilliseconds"] = 1
        object["summary"] = summary
        let tampered = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(VisualPerformanceReceipt.self, from: tampered))
    }

    func testPerformanceComparisonRequiresSameEnvironmentButAllowsNewRevision() throws {
        let sample = try VisualFramePerformanceSample(frameOrdinal: 1, frameDurationMilliseconds: 16, dropped: false)
        let baseline = try VisualPerformanceReceipt(capture: capture(revision: "r1"), environment: environment(.physicalDevice), samples: [sample])
        let candidate = try VisualPerformanceReceipt(capture: capture(revision: "r2"), environment: environment(.physicalDevice), samples: [sample])
        XCTAssertEqual(VisualAcceptanceEvidenceComparator.compare(baseline: baseline, candidate: candidate), .comparable)
        let simulator = try VisualPerformanceReceipt(capture: capture(revision: "r2"), environment: environment(.simulator), samples: [sample])
        XCTAssertEqual(VisualAcceptanceEvidenceComparator.compare(baseline: baseline, candidate: simulator), .notComparable(.differentExecutionEnvironment))
    }
}
