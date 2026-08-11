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

    func testRejectsMixedHostedAndOnDeviceBindingsBeforeDispatch() async {
        let hosted = descriptor(
            adapterID: "hosted",
            deployment: .hostedService
        )
        let local = descriptor(
            adapterID: "local",
            deployment: .onDevice
        )
        let hostedTransport = RecordingProviderTransport()
        let localTransport = RecordingProviderTransport()

        XCTAssertThrowsError(try AgentProviderTransportRouter(bindings: [
            .init(descriptor: hosted, transport: hostedTransport),
            .init(descriptor: local, transport: localTransport),
        ])) { error in
            XCTAssertEqual(
                error as? AgentProviderTransportRouterError,
                .mixedHostedAndOnDeviceBindings
            )
        }

        let hostedCount = await hostedTransport.callCount()
        let localCount = await localTransport.callCount()
        XCTAssertEqual(hostedCount, 0)
        XCTAssertEqual(localCount, 0)
    }

    func testAllowsMultipleOnDeviceBindingsAndStillRoutesExactly() async throws {
        let firstDescriptor = descriptor(
            adapterID: "local-first",
            deployment: .onDevice
        )
        let secondDescriptor = descriptor(
            adapterID: "local-second",
            deployment: .onDevice
        )
        let first = RecordingProviderTransport()
        let second = RecordingProviderTransport()
        let router = try AgentProviderTransportRouter(bindings: [
            .init(descriptor: firstDescriptor, transport: first),
            .init(descriptor: secondDescriptor, transport: second),
        ])

        _ = try await router.stream(
            request: request(path: secondDescriptor.requestPath),
            descriptor: secondDescriptor,
            scope: scope("route-local-exact")
        )

        let firstCount = await first.callCount()
        let secondCount = await second.callCount()
        XCTAssertEqual(firstCount, 0)
        XCTAssertEqual(secondCount, 1)
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

private func descriptor(
    adapterID: String,
    deployment: ProviderDeployment = .callerManaged
) -> ProviderAdapterDescriptor {
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
            deployment: deployment,
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
