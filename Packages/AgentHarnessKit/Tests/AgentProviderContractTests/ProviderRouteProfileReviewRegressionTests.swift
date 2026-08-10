@testable import AgentProviders
import XCTest

final class ProviderRouteProfileReviewRegressionTests: XCTestCase {
    func testExperimentalRouteRejectsUnverifiedAuthenticationBeforeOptInCanSelectIt() throws {
        XCTAssertThrowsError(
            try makeProfile(
                supportState: .experimental,
                authenticationMode: .unverified
            )
        ) { error in
            XCTAssertEqual(
                error as? ProviderRouteProfileValidationError,
                .supportedRouteHasUnverifiedAuthentication
            )
        }
    }

    func testExperimentalRouteRejectsUnverifiedDataHandlingBeforeOptInCanSelectIt() throws {
        XCTAssertThrowsError(
            try makeProfile(
                supportState: .experimental,
                dataHandlingClassification: .unverified
            )
        ) { error in
            XCTAssertEqual(
                error as? ProviderRouteProfileValidationError,
                .supportedRouteHasUnverifiedDataHandling
            )
        }
    }

    func testRouteProfileRejectsBlankCatalogEvidenceSource() throws {
        XCTAssertThrowsError(
            try makeProfile(catalogSourceID: "  \n")
        ) { error in
            XCTAssertEqual(
                error as? ProviderRouteProfileValidationError,
                .emptyCatalogSourceID
            )
        }
    }

    func testRouteProfileRejectsBlankHealthEvidenceSource() throws {
        XCTAssertThrowsError(
            try makeProfile(healthSourceID: "\t")
        ) { error in
            XCTAssertEqual(
                error as? ProviderRouteProfileValidationError,
                .emptyHealthSourceID
            )
        }
    }

    private func makeProfile(
        supportState: ProviderProductSupportState = .supported,
        authenticationMode: ProviderAuthenticationMode = .apiKeyBearer,
        dataHandlingClassification: ProviderDataHandlingClassification = .standardHosted,
        catalogSourceID: String = "fixture-catalog",
        healthSourceID: String = "fixture-health"
    ) throws -> ProviderRouteProfile {
        let descriptor = OpenAIChatCompletionsAdapter(
            model: ProviderModelID(rawValue: "review-route")
        ).descriptor
        return try ProviderRouteProfile(
            descriptor: descriptor,
            endpoint: ProviderEndpointAuthority(
                authorityID: "fixture-origin",
                relativePath: descriptor.requestPath
            ),
            authenticationMode: authenticationMode,
            dataHandling: ProviderDataHandlingPolicy(
                policyID: "fixture-policy",
                classification: dataHandlingClassification,
                requiresPreUseDisclosure: dataHandlingClassification == .unverified,
                sourceID: "fixture-privacy-source",
                verifiedAtISO8601: "2026-08-10T00:00:00Z"
            ),
            replayPolicy: .none,
            retryBehavior: .transientSameRoute,
            cancellationBehavior: .cooperativeTransportAbort,
            supportState: supportState,
            evidence: ProviderRouteEvidence(
                catalogSourceID: catalogSourceID,
                healthSourceID: healthSourceID,
                revision: "review-r1"
            )
        )
    }
}
