@testable import AgentEngine
import Foundation
import XCTest

final class AgentEngineEffortModeTests: XCTestCase {
    func testEffortPresetsExposeStableIncreasingRoundBudgets() {
        XCTAssertEqual(
            AgentEngineEffortMode.allCases.map(\.maximumModelRounds),
            [32, 128, 256, 512]
        )
    }

    func testBalancedPresetPreservesLegacyDefaultRoundBudget() {
        let legacy = AgentEngineConfiguration()
        let balanced = AgentEngineConfiguration(effortMode: .balanced)

        XCTAssertEqual(legacy.maximumModelRounds, 128)
        XCTAssertEqual(balanced.maximumModelRounds, legacy.maximumModelRounds)
    }

    func testUltraPresetIsExtendedButStillBounded() {
        let configuration = AgentEngineConfiguration(effortMode: .ultra)

        XCTAssertEqual(configuration.maximumModelRounds, 512)
        XCTAssertLessThan(configuration.maximumModelRounds, UInt32.max)
    }

    func testEffortModeCodableRoundTripPreservesExactPreset() throws {
        let encoded = try JSONEncoder().encode(AgentEngineEffortMode.ultra)
        let decoded = try JSONDecoder().decode(
            AgentEngineEffortMode.self,
            from: encoded
        )

        XCTAssertEqual(decoded, .ultra)
    }
}
