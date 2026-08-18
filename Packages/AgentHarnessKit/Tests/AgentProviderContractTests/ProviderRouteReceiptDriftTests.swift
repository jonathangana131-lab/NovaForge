@testable import AgentProviders
import XCTest

final class ProviderRouteReceiptDriftTests: XCTestCase {
    func testHistoricalReceiptRejectsEveryDescriptorAuthorityDrift() throws {
        let model = ProviderModelID(rawValue: "receipt-descriptor-drift")
        let acceptedDescriptor = OpenAIChatCompletionsAdapter(model: model).descriptor
        let accepted = try makeProfile(descriptor: acceptedDescriptor)
        let route = acceptedDescriptor.route

        let driftedRoutes = [
            ProviderRoute(
                providerID: route.providerID,
                modelID: route.modelID,
                adapterID: route.adapterID,
                capabilities: .openAICompatibleBaseline,
                deployment: route.deployment,
                provenance: route.provenance
            ),
            ProviderRoute(
                providerID: route.providerID,
                modelID: route.modelID,
                adapterID: route.adapterID,
                capabilities: route.capabilities,
                deployment: .callerManaged,
                provenance: route.provenance
            ),
            ProviderRoute(
                providerID: route.providerID,
                modelID: route.modelID,
                adapterID: route.adapterID,
                capabilities: route.capabilities,
                deployment: route.deployment,
                provenance: .callerConfigured
            ),
        ]

        for driftedRoute in driftedRoutes {
            let driftedDescriptor = ProviderAdapterDescriptor(
                route: driftedRoute,
                dialect: acceptedDescriptor.dialect,
                requestPath: acceptedDescriptor.requestPath
            )
            let current = try makeProfile(descriptor: driftedDescriptor)
            let registry = try ProviderRouteRegistry([current])

            XCTAssertNotEqual(
                accepted.receiptProjection.routeDescriptor,
                current.receiptProjection.routeDescriptor
            )
            XCTAssertThrowsError(
                try registry.profile(matching: accepted.receiptProjection)
            ) { error in
                XCTAssertEqual(
                    error as? ProviderRouteRegistryFailure,
                    .receiptDrift(accepted.key)
                )
            }
        }
    }

    private func makeProfile(
        descriptor: ProviderAdapterDescriptor
    ) throws -> ProviderRouteProfile {
        try ProviderRouteProfile(
            descriptor: descriptor,
            endpoint: ProviderEndpointAuthority(
                authorityID: "fixture-origin",
                relativePath: descriptor.requestPath
            ),
            authenticationMode: .apiKeyBearer,
            dataHandling: ProviderDataHandlingPolicy(
                policyID: "fixture-standard-hosted",
                classification: .standardHosted,
                requiresPreUseDisclosure: false,
                sourceID: "fixture-privacy-source",
                verifiedAtISO8601: "2026-08-18T00:00:00Z"
            ),
            replayPolicy: .none,
            retryBehavior: .transientSameRoute,
            cancellationBehavior: .cooperativeTransportAbort,
            supportState: .supported,
            evidence: ProviderRouteEvidence(
                catalogSourceID: "fixture-catalog",
                healthSourceID: "fixture-health",
                revision: "fixture-r1"
            )
        )
    }
}
