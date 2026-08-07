import AgentDomain
@testable import AgentProviders
import XCTest

final class ProviderFailureMappingContractTests: XCTestCase {
    func testHTTP413MapsToRecoverableContextLimit() {
        let failure = ProviderFailureMapper.httpFailure(
            statusCode: 413,
            providerID: ProviderID(rawValue: "fixture-provider"),
            adapterID: ProviderAdapterID(rawValue: "fixture-adapter")
        )

        XCTAssertEqual(failure.category, .contextLimit)
        XCTAssertEqual(failure.code, "provider_context_limit")
        XCTAssertEqual(failure.statusCode, 413)
        XCTAssertTrue(failure.publicMessage.contains("too large"))
        XCTAssertFalse(failure.retryableOnSameRoute)
        XCTAssertTrue(failure.recoverableByFallback)
    }
}
