@testable import AgentProviders
import XCTest

final class ProviderRouteReceiptAuthorityTests: XCTestCase {
    func testHistoricalVerificationDoesNotMintDispatchAuthorityForUnavailableStates() throws {
        let unavailableStates: [ProviderProductSupportState] = [
            .legacy,
            .broken,
            .unverified,
            .removedDoNotOffer,
        ]

        for supportState in unavailableStates {
            let profile = try makeProfile(supportState: supportState)
            let registry = try ProviderRouteRegistry([profile])
            let receipt = profile.receiptProjection

            let verification = try registry.verify(receipt: receipt)
            XCTAssertEqual(verification.key, profile.key)
            XCTAssertEqual(verification.supportState, supportState)

            XCTAssertThrowsError(try registry.profile(matching: receipt)) { error in
                XCTAssertEqual(
                    error as? ProviderRouteRegistryFailure,
                    .unavailableSupportState(profile.key, supportState)
                )
            }
        }
    }

    func testExperimentalReceiptRequiresExplicitDispatchPolicy() throws {
        let profile = try makeProfile(supportState: .experimental)
        let registry = try ProviderRouteRegistry([profile])
        let receipt = profile.receiptProjection

        XCTAssertEqual(
            try registry.verify(receipt: receipt).supportState,
            .experimental
        )
        XCTAssertThrowsError(try registry.profile(matching: receipt)) { error in
            XCTAssertEqual(
                error as? ProviderRouteRegistryFailure,
                .unavailableSupportState(profile.key, .experimental)
            )
        }
        XCTAssertEqual(
            try registry.profile(matching: receipt, allowExperimental: true),
            profile
        )
    }

    func testSupportedReceiptCanBecomeDispatchAuthorityAfterExactVerification() throws {
        let profile = try makeProfile(supportState: .supported)
        let registry = try ProviderRouteRegistry([profile])
        let receipt = profile.receiptProjection

        XCTAssertEqual(try registry.verify(receipt: receipt).supportState, .supported)
        XCTAssertEqual(try registry.profile(matching: receipt), profile)
    }

    private func makeProfile(
        supportState: ProviderProductSupportState
    ) throws -> ProviderRouteProfile {
        let model = ProviderModelID(rawValue: "receipt-authority-\(supportState.rawValue.lowercased())")
        let descriptor = OpenAIChatCompletionsAdapter(model: model).descriptor

        return try ProviderRouteProfile(
            descriptor: descriptor,
            endpoint: .init(
                authorityID: "receipt-authority-origin",
                relativePath: descriptor.requestPath
            ),
            authenticationMode: .apiKeyBearer,
            dataHandling: .init(
                policyID: "receipt-authority-policy",
                classification: .standardHosted,
                requiresPreUseDisclosure: false,
                sourceID: "receipt-authority-source",
                verifiedAtISO8601: "2026-08-19T00:00:00Z"
            ),
            replayPolicy: .none,
            retryBehavior: .transientSameRoute,
            cancellationBehavior: .unavailable,
            supportState: supportState,
            evidence: .init(
                catalogSourceID: "receipt-authority-catalog",
                healthSourceID: "receipt-authority-health",
                revision: "receipt-authority-r1"
            )
        )
    }
}
