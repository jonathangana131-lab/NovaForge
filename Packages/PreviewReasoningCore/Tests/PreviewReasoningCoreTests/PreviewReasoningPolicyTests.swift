import XCTest
@testable import PreviewReasoningCore

final class PreviewReasoningPolicyTests: XCTestCase {
    func testPublicScaleIsExactlyFiveOrderedProductLevels() {
        XCTAssertEqual(
            PreviewReasoningLevel.allCases.map(\.title),
            ["Low", "Medium", "High", "Extra High", "Ultra"]
        )
        XCTAssertEqual(
            PreviewReasoningLevel.allCases.map(\.rank),
            Array(0..<5)
        )
    }

    func testUltraIsTheUniqueStrongestExecutionProfile() {
        let profiles = PreviewReasoningLevel.allCases.map(PreviewReasoningProfile.init)
        let ultra = PreviewReasoningProfile(level: .ultra)

        XCTAssertEqual(ultra.orchestration, .isolatedParallelReview)
        XCTAssertEqual(ultra.contextDepth, .maximumUseful)
        XCTAssertEqual(ultra.verification, .strictest)
        XCTAssertEqual(ultra.verifierPasses, 2)
        XCTAssertTrue(ultra.requiresMaximumAvailableReasoning)
        XCTAssertTrue(ultra.requiresIsolatedWorkspaces)

        for profile in profiles where profile.level != .ultra {
            XCTAssertFalse(profile.requiresMaximumAvailableReasoning)
            XCTAssertFalse(profile.requiresIsolatedWorkspaces)
            XCTAssertLessThan(profile.verifierPasses, ultra.verifierPasses)
        }
    }

    func testLegacyUltraVariantsPreserveStrongestModeIntent() {
        for orchestration in [
            LegacyPreviewReasoningSelection.Orchestration.ultra,
            .ultraCode,
        ] {
            let selection = LegacyPreviewReasoningSelection(
                effort: .medium,
                orchestration: orchestration
            )
            XCTAssertEqual(selection.canonicalLevel, .ultra)
        }
    }

    func testLegacyStandardEffortsMapWithoutInventingASecondUltraStop() {
        let expectations: [(LegacyPreviewReasoningSelection.Effort, PreviewReasoningLevel)] = [
            (.none, .low),
            (.low, .low),
            (.medium, .medium),
            (.high, .high),
            (.xhigh, .extraHigh),
            (.max, .extraHigh),
        ]

        for (effort, expected) in expectations {
            let selection = LegacyPreviewReasoningSelection(
                effort: effort,
                orchestration: .standard
            )
            XCTAssertEqual(selection.canonicalLevel, expected, "legacy effort: \(effort)")
        }
    }

    func testCodableRoundTripRetainsCanonicalLevelAndProfile() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for level in PreviewReasoningLevel.allCases {
            let levelData = try encoder.encode(level)
            XCTAssertEqual(try decoder.decode(PreviewReasoningLevel.self, from: levelData), level)

            let profile = PreviewReasoningProfile(level: level)
            let profileData = try encoder.encode(profile)
            XCTAssertEqual(try decoder.decode(PreviewReasoningProfile.self, from: profileData), profile)
        }
    }

    func testUnknownPersistedLevelFailsClosed() throws {
        let data = Data("\"ultraCode\"".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(PreviewReasoningLevel.self, from: data))
    }
}
