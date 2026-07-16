import AgentDomain
@testable import AgentPolicy
import AgentTools
import XCTest

final class AgentPolicySecurityTests: XCTestCase {
    func testAgentPolicyTargetIsLinked() {
        XCTAssertTrue(RiskPolicyDecision.deny([]).isFailClosed)
    }
}
