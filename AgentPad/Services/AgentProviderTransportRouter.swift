import AgentProviders
import Foundation

enum AgentProviderTransportRouterError: Error, Equatable, Sendable {
    case duplicateAdapter(ProviderAdapterID)
    case mixedHostedAndOnDeviceBindings
    case unknownAdapter(ProviderAdapterID)
    case descriptorMismatch(ProviderAdapterID)
}

/// Immutable app-side transport multiplexer for one `ModelGateway` catalog.
///
/// Routing is exact by adapter ID and then by the complete descriptor value.
/// A single router may never straddle the hosted-service/on-device trust
/// boundary: Local Only must not acquire a hidden cloud fallback merely because
/// another adapter is added to the same gateway later. Explicit hosted-only and
/// on-device-only catalogs remain valid, as do caller-managed test catalogs.
/// The selected transport remains responsible for its own credential and
/// package-capability validation, so this type cannot widen authority or rewrite
/// an endpoint.
struct AgentProviderTransportRouter: ProviderTransport, Sendable {
    struct Binding: Sendable {
        let descriptor: ProviderAdapterDescriptor
        let transport: any ProviderTransport

        init(
            descriptor: ProviderAdapterDescriptor,
            transport: any ProviderTransport
        ) {
            self.descriptor = descriptor
            self.transport = transport
        }
    }

    private let bindings: [ProviderAdapterID: Binding]

    init(bindings: [Binding]) throws {
        var indexed: [ProviderAdapterID: Binding] = [:]
        indexed.reserveCapacity(bindings.count)
        var containsHostedService = false
        var containsOnDevice = false

        for binding in bindings {
            let route = binding.descriptor.route
            switch route.deployment {
            case .hostedService:
                containsHostedService = true
            case .onDevice:
                containsOnDevice = true
            default:
                break
            }
            guard !(containsHostedService && containsOnDevice) else {
                throw AgentProviderTransportRouterError
                    .mixedHostedAndOnDeviceBindings
            }

            let adapterID = route.adapterID
            guard indexed[adapterID] == nil else {
                throw AgentProviderTransportRouterError
                    .duplicateAdapter(adapterID)
            }
            indexed[adapterID] = binding
        }
        self.bindings = indexed
    }

    func stream(
        request: ProviderEncodedRequest,
        descriptor: ProviderAdapterDescriptor,
        scope: ProviderAttemptScope
    ) async throws -> AsyncThrowingStream<ProviderWireFrame, any Error> {
        let adapterID = descriptor.route.adapterID
        guard let binding = bindings[adapterID] else {
            throw AgentProviderTransportRouterError.unknownAdapter(adapterID)
        }
        guard binding.descriptor == descriptor else {
            throw AgentProviderTransportRouterError
                .descriptorMismatch(adapterID)
        }
        return try await binding.transport.stream(
            request: request,
            descriptor: descriptor,
            scope: scope
        )
    }
}
