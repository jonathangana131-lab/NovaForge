import AgentDomain
@testable import AgentProviders
import XCTest

final class ProviderFailureMappingContractTests: XCTestCase {
    private let providerID = ProviderID(rawValue: "fixture-provider")
    private let adapterID = ProviderAdapterID(rawValue: "fixture-adapter")

    func testHTTPStatusAcceptanceMatrixUsesStableCategoriesAndCodes() {
        let cases: [(status: Int, category: ProviderFailureCategory, code: String)] = [
            (401, .authentication, "provider_authentication_failed"),
            (402, .authorization, "provider_payment_required"),
            (403, .authorization, "provider_authorization_failed"),
            (404, .invalidRequest, "provider_invalid_request"),
            (408, .timeout, "provider_timeout"),
            (413, .contextLimit, "provider_context_limit"),
            (422, .invalidRequest, "provider_invalid_request"),
            (429, .rateLimited, "provider_rate_limited"),
            (500, .unavailable, "provider_unavailable"),
            (503, .unavailable, "provider_unavailable"),
            (504, .timeout, "provider_timeout"),
            (505, .providerInternal, "provider_internal_error"),
        ]

        for item in cases {
            let failure = ProviderFailureMapper.httpFailure(
                statusCode: item.status,
                providerID: providerID,
                adapterID: adapterID
            )
            XCTAssertEqual(failure.category, item.category, "HTTP \(item.status)")
            XCTAssertEqual(failure.code, item.code, "HTTP \(item.status)")
            XCTAssertEqual(failure.statusCode, item.status, "HTTP \(item.status)")
        }
    }

    func testHTTP413MapsToRecoverableContextLimit() {
        let failure = ProviderFailureMapper.httpFailure(
            statusCode: 413,
            providerID: providerID,
            adapterID: adapterID
        )

        XCTAssertEqual(failure.category, .contextLimit)
        XCTAssertEqual(failure.code, "provider_context_limit")
        XCTAssertTrue(failure.publicMessage.contains("too large"))
        XCTAssertFalse(failure.retryableOnSameRoute)
        XCTAssertTrue(failure.recoverableByFallback)
    }

    func testProviderCodesOverrideGenericHTTPClassification() {
        let context = ProviderFailureMapper.httpFailure(
            statusCode: 400,
            providerCode: "context_length_exceeded",
            providerID: providerID,
            adapterID: adapterID
        )
        XCTAssertEqual(context.category, .contextLimit)
        XCTAssertEqual(context.code, "provider_context_limit")

        let filtered = ProviderFailureMapper.httpFailure(
            statusCode: 400,
            providerCode: "content_policy_violation",
            providerID: providerID,
            adapterID: adapterID
        )
        XCTAssertEqual(filtered.category, .contentFiltered)
        XCTAssertEqual(filtered.code, "provider_content_filtered")
    }
}
