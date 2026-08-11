import AgentDomain
import AgentProviders
import XCTest
@testable import NovaForge

final class AgentProviderTransportRouterTests: XCTestCase {
    func testRoutesOnlyToExactBoundDescriptor() async throws {
        let firstDescriptor = descriptor(adapterID: "first")
        let secondDescriptor = descriptor(adapterID: "second")
        let first = RecordingProviderTransport()
        let second = RecordingProviderTransport()
        let router = try AgentProviderTransportRouter(bindings: [
            .init(descriptor: firstDescriptor, transport: first),
            .init(descriptor: secondDescriptor, transport: second),
        ])

        _ = try await router.stream(
            request: request(path: secondDescriptor.requestPath),
            descriptor: secondDescriptor,
            scope: scope("route-exact")
        )

        let firstCount = await first.callCount()
        let secondCount = await second.callCount()
        let routedDescriptor = await second.lastDescriptor()
        XCTAssertEqual(firstCount, 0)
        XCTAssertEqual(secondCount, 1)
        XCTAssertEqual(routedDescriptor, secondDescriptor)
    }

    func testRejectsUnknownAndSameIDDescriptorSpoofBeforeTransport()
        async throws
    {
        let trusted = descriptor(adapterID: "trusted")
        let transport = RecordingProviderTransport()
        let router = try AgentProviderTransportRouter(bindings: [
            .init(descriptor: trusted, transport: transport),
        ])

        let unknown = descriptor(adapterID: "unknown")
        do {
            _ = try await router.stream(
                request: request(path: unknown.requestPath),
                descriptor: unknown,
                scope: scope("route-unknown")
            )
            XCTFail("Unknown adapter unexpectedly routed")
        } catch {
            XCTAssertEqual(
                error as? AgentProviderTransportRouterError,
                .unknownAdapter(.init(rawValue: "unknown"))
            )
        }

        let spoof = ProviderAdapterDescriptor(
            route: ProviderRoute(
                providerID: trusted.route.providerID,
                modelID: .init(rawValue: "different-model"),
                adapterID: trusted.route.adapterID,
                capabilities: trusted.route.capabilities,
                deployment: trusted.route.deployment,
                provenance: trusted.route.provenance
            ),
            dialect: trusted.dialect,
            requestPath: trusted.requestPath
        )
        do {
            _ = try await router.stream(
                request: request(path: spoof.requestPath),
                descriptor: spoof,
                scope: scope("route-spoof")
            )
            XCTFail("Descriptor spoof unexpectedly routed")
        } catch {
            XCTAssertEqual(
                error as? AgentProviderTransportRouterError,
                .descriptorMismatch(.init(rawValue: "trusted"))
            )
        }
        let callCount = await transport.callCount()
        XCTAssertEqual(callCount, 0)
    }

    func testRejectsDuplicateBindings() {
        let descriptor = descriptor(adapterID: "duplicate")
        XCTAssertThrowsError(try AgentProviderTransportRouter(bindings: [
            .init(
                descriptor: descriptor,
                transport: RecordingProviderTransport()
            ),
            .init(
                descriptor: descriptor,
                transport: RecordingProviderTransport()
            ),
        ])) { error in
            XCTAssertEqual(
                error as? AgentProviderTransportRouterError,
                .duplicateAdapter(.init(rawValue: "duplicate"))
            )
        }
    }

    func testLocalTransportRejectsEveryNonOnDeviceDeploymentBeforeInference()
        async throws
    {
        let variant = LocalModelCatalog.defaultVariant
        let localDescriptor = try LocalModelAdapter(configuration: .init(
            modelID: .init(rawValue: variant.id),
            contextWindowTokens: UInt64(variant.contextTokens),
            maximumOutputTokens: UInt64(variant.maxNewTokens),
            toolMode: .textOnly
        )).descriptor
        let inference = RecordingLocalModelInference()
        let transport = AgentLocalModelProviderTransport(inference: inference)
        let encoded = ProviderEncodedRequest(
            relativePath: localDescriptor.requestPath,
            body: .object([:])
        )

        for deployment in [
            ProviderDeployment.hostedService,
            .remoteWorker,
            .callerManaged,
        ] {
            let nonDeviceDescriptor = ProviderAdapterDescriptor(
                route: ProviderRoute(
                    providerID: localDescriptor.route.providerID,
                    modelID: localDescriptor.route.modelID,
                    adapterID: localDescriptor.route.adapterID,
                    capabilities: localDescriptor.route.capabilities,
                    deployment: deployment,
                    provenance: localDescriptor.route.provenance
                ),
                dialect: localDescriptor.dialect,
                requestPath: localDescriptor.requestPath
            )

            do {
                _ = try await transport.stream(
                    request: encoded,
                    descriptor: nonDeviceDescriptor,
                    scope: scope("local-non-device-\(deployment.rawValue)")
                )
                XCTFail(
                    "Local transport accepted non-device deployment \(deployment.rawValue)"
                )
            } catch {
                XCTAssertEqual(
                    error as? AgentLocalModelProviderTransportError,
                    .invalidDescriptor,
                    deployment.rawValue
                )
            }
        }

        let callCount = await inference.callCount()
        XCTAssertEqual(callCount, 0)
    }
}

private actor RecordingProviderTransport: ProviderTransport {
    private var descriptors: [ProviderAdapterDescriptor] = []

    func stream(
        request _: ProviderEncodedRequest,
        descriptor: ProviderAdapterDescriptor,
        scope _: ProviderAttemptScope
    ) async throws -> AsyncThrowingStream<ProviderWireFrame, any Error> {
        descriptors.append(descriptor)
        return AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func callCount() -> Int { descriptors.count }
    func lastDescriptor() -> ProviderAdapterDescriptor? { descriptors.last }
}

private actor RecordingLocalModelInference: AgentLocalModelInferenceStreaming {
    private var streamRequests: [AgentLocalModelInferenceRequest] = []

    func stream(
        request: AgentLocalModelInferenceRequest,
        onEvent _: @escaping @Sendable (AgentLocalModelInferenceEvent) async throws -> Void
    ) async throws {
        streamRequests.append(request)
    }

    func stop(request _: AgentLocalModelInferenceRequest) async {}

    func callCount() -> Int { streamRequests.count }
}

private func descriptor(adapterID: String) -> ProviderAdapterDescriptor {
    ProviderAdapterDescriptor(
        route: ProviderRoute(
            providerID: .init(rawValue: "test-provider"),
            modelID: .init(rawValue: "test-model"),
            adapterID: .init(rawValue: adapterID),
            capabilities: ProviderModelCapabilities(
                features: ProviderCapabilitySet([.streaming]),
                contextWindowTokens: 4_096,
                maximumOutputTokens: 1_024,
                maximumToolDefinitions: 0,
                maximumToolCallsPerTurn: 0
            ),
            deployment: .callerManaged,
            provenance: .callerConfigured
        ),
        dialect: .openAICompatibleChat,
        requestPath: "/v1/chat/completions"
    )
}

private func request(path: String) -> ProviderEncodedRequest {
    ProviderEncodedRequest(
        relativePath: path,
        body: .object(["stream": .bool(true)])
    )
}

private func scope(_ requestID: String) -> ProviderAttemptScope {
    ProviderAttemptScope(
        requestID: requestID,
        attemptID: .init(rawValue: requestID + ":provider-attempt:1")
    )
}
