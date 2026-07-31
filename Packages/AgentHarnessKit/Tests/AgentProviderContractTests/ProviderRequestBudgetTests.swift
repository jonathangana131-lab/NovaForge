import AgentDomain
@testable import AgentProviders
import XCTest

final class ProviderRequestBudgetTests: XCTestCase {
    private let model = ProviderModelID(rawValue: "fixture-model")

    func testRejectsAggregateContentPartCountBeforeEncoding() throws {
        let request = CanonicalProviderRequest(
            requestID: "too-many-parts",
            model: model,
            messages: [
                .init(
                    role: .user,
                    content: Array(repeating: .text("x"), count: 4_097)
                ),
            ]
        )

        assertBudgetExceeded(request)
    }

    func testRejectsAggregateEncodedStringBytesBeforeEncoding() throws {
        let request = CanonicalProviderRequest(
            requestID: "too-many-bytes",
            model: model,
            messages: [
                .init(
                    role: .user,
                    content: [.text(String(repeating: "a", count: 8 * 1_024 * 1_024))]
                ),
            ]
        )

        assertBudgetExceeded(request)
    }

    func testRejectsManyIndividuallyBoundedSchemasWithExcessAggregateNodes() throws {
        let enumValues = (0 ..< 1_600).map { JSONValue.string("value-\($0)") }
        let tools = (0 ..< 128).map { index in
            ProviderToolDefinition(
                name: "tool_\(index)",
                description: "Bounded tool",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "value": .object([
                            "type": .string("string"),
                            "enum": .array(enumValues),
                        ]),
                    ]),
                    "additionalProperties": .bool(false),
                ])
            )
        }
        let request = CanonicalProviderRequest(
            requestID: "aggregate-schema-budget",
            model: model,
            messages: [.init(role: .user, content: [.text("Use a tool")])],
            tools: tools
        )

        assertBudgetExceeded(request)
    }

    func testRejectsAggregateMetadataNodesBeforeCapabilityTraversal() throws {
        let request = CanonicalProviderRequest(
            requestID: "aggregate-metadata-budget",
            model: model,
            messages: [.init(role: .user, content: [.text("Hello")])],
            metadata: .array(Array(repeating: .null, count: 200_001))
        )

        assertBudgetExceeded(request)
    }

    func testRejectsNonFiniteJSONWithoutLeakingEncoderFailure() throws {
        let request = CanonicalProviderRequest(
            requestID: "non-finite-metadata",
            model: model,
            messages: [.init(role: .user, content: [.text("Hello")])],
            metadata: .object([
                "invalid": .number(.floatingPoint(.infinity)),
            ])
        )

        assertBudgetExceeded(request)
    }

    func testGatewayRejectsCanonicalBudgetBeforeBarrierAndTransport() async throws {
        let adapter = BudgetFixtureAdapter(body: .object(["ok": .bool(true)]))
        let barrier = BudgetFixtureBarrier()
        let transport = BudgetFixtureTransport()
        let gateway = ModelGateway(
            catalog: try ProviderAdapterCatalog([adapter]),
            transport: transport
        )
        let request = CanonicalProviderRequest(
            requestID: "gateway-canonical-budget",
            model: model,
            messages: [.init(role: .user, content: [.text("Hello")])],
            metadata: .array(Array(repeating: .null, count: 200_001))
        )

        do {
            for try await _ in await gateway.streamAttempt(.init(
                request: request,
                adapterID: adapter.descriptor.route.adapterID,
                scope: .init(
                    requestID: request.requestID,
                    attemptID: .init(rawValue: "attempt-1")
                ),
                barrier: barrier
            )) {}
            XCTFail("Expected the canonical request budget to fail closed")
        } catch {
            XCTAssertEqual(
                error as? ProviderGatewayContractFailure,
                .requestBudgetExceeded
            )
        }
        let barrierCalls = await barrier.calls()
        let transportCalls = await transport.calls()
        XCTAssertEqual(barrierCalls, 0)
        XCTAssertEqual(transportCalls, 0)
    }

    func testGatewayRejectsCustomAdapterEncodedBudgetBeforeBarrierAndTransport() async throws {
        let adapter = BudgetFixtureAdapter(
            body: .array(Array(repeating: .null, count: 200_001))
        )
        let barrier = BudgetFixtureBarrier()
        let transport = BudgetFixtureTransport()
        let gateway = ModelGateway(
            catalog: try ProviderAdapterCatalog([adapter]),
            transport: transport
        )
        let request = CanonicalProviderRequest(
            requestID: "gateway-encoded-budget",
            model: model,
            messages: [.init(role: .user, content: [.text("Hello")])]
        )

        do {
            for try await _ in await gateway.streamAttempt(.init(
                request: request,
                adapterID: adapter.descriptor.route.adapterID,
                scope: .init(
                    requestID: request.requestID,
                    attemptID: .init(rawValue: "attempt-1")
                ),
                barrier: barrier
            )) {}
            XCTFail("Expected the encoded request budget to fail closed")
        } catch {
            XCTAssertEqual(
                error as? ProviderGatewayContractFailure,
                .encodedRequestBudgetExceeded
            )
        }
        let barrierCalls = await barrier.calls()
        let transportCalls = await transport.calls()
        XCTAssertEqual(barrierCalls, 0)
        XCTAssertEqual(transportCalls, 0)
    }

    private func assertBudgetExceeded(
        _ request: CanonicalProviderRequest,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let adapter = OpenAIResponsesAdapter(model: model)
        XCTAssertThrowsError(try adapter.encode(request), file: file, line: line) { error in
            XCTAssertEqual(
                (error as? ProviderFailure)?.code,
                "provider_request_budget_exceeded",
                file: file,
                line: line
            )
        }
    }
}

private struct BudgetFixtureAdapter: ProviderAdapter {
    let descriptor = OpenAIChatCompletionsAdapter(
        model: .init(rawValue: "fixture-model")
    ).descriptor
    let body: JSONValue

    func encode(_ request: CanonicalProviderRequest) throws -> ProviderEncodedRequest {
        ProviderEncodedRequest(relativePath: descriptor.requestPath, body: body)
    }
}

private actor BudgetFixtureBarrier: ProviderAttemptDispatchBarrier {
    private var callCount = 0

    func beforeDispatch(_ attempt: ProviderAttemptDispatch) async throws {
        callCount += 1
    }

    func calls() -> Int { callCount }
}

private actor BudgetFixtureTransport: ProviderTransport {
    private var callCount = 0

    func stream(
        request: ProviderEncodedRequest,
        descriptor: ProviderAdapterDescriptor,
        scope: ProviderAttemptScope
    ) async throws -> AsyncThrowingStream<ProviderWireFrame, any Error> {
        callCount += 1
        return AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func calls() -> Int { callCount }
}
