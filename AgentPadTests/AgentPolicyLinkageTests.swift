import AgentPolicy
import AgentTools
import XCTest

final class AgentPolicyLinkageTests: XCTestCase {
    func testAgentPolicyProductIsLinkedIntoTheAppTestGraph() throws {
        let target = try NormalizedToolTarget(
            path: "Sources/App.swift",
            access: .write
        )

        XCTAssertEqual(target.path, "Sources/App.swift")
        XCTAssertTrue(target.isWithin(prefix: "Sources"))
    }
}
