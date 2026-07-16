import AgentDomain
@testable import AgentProviders
import XCTest

final class ProviderSingleAttemptTests: XCTestCase {
    func testRequestDigestRequiresExactlyLowercaseASCIIHex() throws {
        XCTAssertNoThrow(try ProviderRequestDigest(
            "sha256:" + String(repeating: "0a", count: 32)
        ))
        XCTAssertThrowsError(try ProviderRequestDigest(
            "sha256:" + String(repeating: "A", count: 64)
        ))
        // Thirty-two Arabic-Indic digits occupy exactly sixty-four UTF-8
        // bytes. Character-level `isHexDigit` used to accept this shape even
        // though the journal contract requires lowercase ASCII hex.
        XCTAssertThrowsError(try ProviderRequestDigest(
            "sha256:" + String(repeating: "١", count: 32)
        ))
    }

    func testSingleAttemptAwaitsBarrierAndPreservesCallerScope() async throws {
        let adapter = OpenAIChatCompletionsAdapter(
            model: .init(rawValue: "fixture-model")
        )
        let barrier = RecordingDispatchBarrier()
        let transport = SingleAttemptFixtureTransport(outcomes: [
            .success(successFrames(text: "one-attempt")),
        ])
        let gateway = ModelGateway(
            catalog: try ProviderAdapterCatalog([adapter]),
            transport: transport
        )
        let scope = ProviderAttemptScope(
            requestID: "durable-request",
            attemptID: .init(rawValue: "engine-attempt-7")
        )

        let stream = await gateway.streamAttempt(.init(
            request: request(id: scope.requestID),
            adapterID: adapter.descriptor.route.adapterID,
            scope: scope,
            barrier: barrier
        ))
        let events = try await collect(stream)

        XCTAssertTrue(events.allSatisfy { $0.scope == scope })
        XCTAssertEqual(events.map(\.sequence), Array(0 ..< UInt64(events.count)))
        XCTAssertEqual(events.compactMap { event -> String? in
            if case let .textDelta(delta) = event.event { delta.text } else { nil }
        }.joined(), "one-attempt")
        XCTAssertEqual(events.last?.event, .responseCompleted(.init(
            responseID: "single-response",
            finishReason: .completed
        )))

        let dispatches = await barrier.dispatches()
        XCTAssertEqual(dispatches.count, 1)
        let dispatch = try XCTUnwrap(dispatches.first)
        XCTAssertEqual(dispatch.scope, scope)
        XCTAssertEqual(dispatch.route, adapter.descriptor.route)
        XCTAssertEqual(dispatch.relativePath, "/v1/chat/completions")
        XCTAssertEqual(
            dispatch.requestSHA256.rawValue,
            "sha256:1d168d0314ee46619d2a3c616288f83a072425574ee88c6a263e50957f3e95d4"
        )
        XCTAssertTrue(dispatch.requestSHA256.rawValue.hasPrefix("sha256:"))
        XCTAssertEqual(dispatch.requestSHA256.rawValue.count, 71)
        XCTAssertFalse(dispatch.requestSHA256.rawValue.contains("secret prompt"))
        let journalMetadata = try dispatch.journalMetadata(
            ordinal: 7,
            recoverySeed: 0xC0DE
        )
        XCTAssertEqual(
            journalMetadata,
            .recordedV1_1(
                requestDigest: try AgentCanonicalSHA256Digest(
                    dispatch.requestSHA256.rawValue
                ),
                scope: try ProviderAttemptScopeReference(
                    requestID: scope.requestID,
                    attemptID: scope.attemptID.rawValue
                ),
                ordinal: 7,
                recoverySeed: 0xC0DE
            )
        )
        let callCount = await transport.calls()
        XCTAssertEqual(callCount, 1)
    }

    func testRequestDigestIsStableAcrossCallerOwnedAttemptScopes() async throws {
        let adapter = OpenAIChatCompletionsAdapter(
            model: .init(rawValue: "fixture-model")
        )
        let barrier = RecordingDispatchBarrier()
        let transport = SingleAttemptFixtureTransport(outcomes: [
            .success(successFrames(text: "first")),
            .success(successFrames(text: "second")),
        ])
        let gateway = ModelGateway(
            catalog: try ProviderAdapterCatalog([adapter]),
            transport: transport
        )
        let firstScope = ProviderAttemptScope(
            requestID: "stable-request",
            attemptID: .init(rawValue: "attempt-1")
        )
        let secondScope = ProviderAttemptScope(
            requestID: "stable-request",
            attemptID: .init(rawValue: "attempt-2")
        )

        _ = try await collect(await gateway.streamAttempt(.init(
            request: request(id: "stable-request"),
            adapterID: adapter.descriptor.route.adapterID,
            scope: firstScope,
            barrier: barrier
        )))
        _ = try await collect(await gateway.streamAttempt(.init(
            request: request(id: "stable-request"),
            adapterID: adapter.descriptor.route.adapterID,
            scope: secondScope,
            barrier: barrier
        )))

        let dispatches = await barrier.dispatches()
        XCTAssertEqual(dispatches.map(\.scope), [firstScope, secondScope])
        let firstDispatch = try XCTUnwrap(dispatches.first)
        let secondDispatch = try XCTUnwrap(dispatches.dropFirst().first)
        XCTAssertEqual(firstDispatch.requestSHA256, secondDispatch.requestSHA256)
    }

    func testRequestDigestChangesForBodyAndSafePathMutations() async throws {
        let adapter = OpenAIChatCompletionsAdapter(
            model: .init(rawValue: "fixture-model")
        )
        let originalRequest = request(id: "digest-sensitivity")
        let originalBodyDispatch = try await captureDispatch(
            adapter: adapter,
            request: originalRequest,
            attemptID: "body-original"
        )
        let mutatedBodyDispatch = try await captureDispatch(
            adapter: adapter,
            request: request(
                id: originalRequest.requestID,
                prompt: "secret prompt with a body mutation"
            ),
            attemptID: "body-mutated"
        )

        XCTAssertEqual(originalBodyDispatch.route, mutatedBodyDispatch.route)
        XCTAssertEqual(originalBodyDispatch.method, mutatedBodyDispatch.method)
        XCTAssertEqual(originalBodyDispatch.relativePath, mutatedBodyDispatch.relativePath)
        XCTAssertNotEqual(
            originalBodyDispatch.requestSHA256,
            mutatedBodyDispatch.requestSHA256
        )

        let originalPathAdapter = OpenAICompatibleAdapter(configuration: .init(
            providerID: .init(rawValue: "digest-fixture"),
            adapterID: .init(rawValue: "digest-safe-path"),
            modelID: .init(rawValue: "fixture-model"),
            requestPath: "/v1/chat/completions"
        ))
        let mutatedPathAdapter = OpenAICompatibleAdapter(configuration: .init(
            providerID: .init(rawValue: "digest-fixture"),
            adapterID: .init(rawValue: "digest-safe-path"),
            modelID: .init(rawValue: "fixture-model"),
            requestPath: "/v1/chat/completions-alternate"
        ))
        let originalPathDispatch = try await captureDispatch(
            adapter: originalPathAdapter,
            request: originalRequest,
            attemptID: "path-original"
        )
        let mutatedPathDispatch = try await captureDispatch(
            adapter: mutatedPathAdapter,
            request: originalRequest,
            attemptID: "path-mutated"
        )

        XCTAssertEqual(originalPathDispatch.route, mutatedPathDispatch.route)
        XCTAssertEqual(originalPathDispatch.method, mutatedPathDispatch.method)
        XCTAssertEqual(originalPathDispatch.relativePath, "/v1/chat/completions")
        XCTAssertEqual(
            mutatedPathDispatch.relativePath,
            "/v1/chat/completions-alternate"
        )
        XCTAssertNotEqual(
            originalPathDispatch.requestSHA256,
            mutatedPathDispatch.requestSHA256
        )
    }

    func testBarrierFailurePreventsTransportDispatch() async throws {
        let adapter = OpenAIChatCompletionsAdapter(
            model: .init(rawValue: "fixture-model")
        )
        let barrier = RecordingDispatchBarrier(failure: .journalUnavailable)
        let transport = SingleAttemptFixtureTransport(outcomes: [])
        let gateway = ModelGateway(
            catalog: try ProviderAdapterCatalog([adapter]),
            transport: transport
        )
        let scope = ProviderAttemptScope(
            requestID: "barrier-request",
            attemptID: .init(rawValue: "attempt-1")
        )
        let stream = await gateway.streamAttempt(.init(
            request: request(id: scope.requestID),
            adapterID: adapter.descriptor.route.adapterID,
            scope: scope,
            barrier: barrier
        ))

        do {
            _ = try await collect(stream)
            XCTFail("Expected the durable dispatch barrier to fail")
        } catch {
            XCTAssertEqual(error as? DispatchBarrierFixtureError, .journalUnavailable)
        }
        let callCount = await transport.calls()
        XCTAssertEqual(callCount, 0)
        let dispatches = await barrier.dispatches()
        XCTAssertEqual(dispatches.map(\.scope), [scope])
    }

    func testMismatchedRequestAndScopeIdentityFailsBeforeBarrierOrTransport() async throws {
        let adapter = OpenAIChatCompletionsAdapter(
            model: .init(rawValue: "fixture-model")
        )
        let barrier = RecordingDispatchBarrier()
        let transport = SingleAttemptFixtureTransport(outcomes: [])
        let gateway = ModelGateway(
            catalog: try ProviderAdapterCatalog([adapter]),
            transport: transport
        )
        let stream = await gateway.streamAttempt(.init(
            request: request(id: "canonical-request"),
            adapterID: adapter.descriptor.route.adapterID,
            scope: .init(
                requestID: "different-request",
                attemptID: .init(rawValue: "attempt-1")
            ),
            barrier: barrier
        ))

        do {
            _ = try await collect(stream)
            XCTFail("Expected mismatched request identity to fail closed")
        } catch {
            XCTAssertEqual(
                error as? ProviderGatewayContractFailure,
                .requestScopeMismatch
            )
        }
        let dispatches = await barrier.dispatches()
        let callCount = await transport.calls()
        XCTAssertEqual(dispatches, [])
        XCTAssertEqual(callCount, 0)
    }

    func testInvalidAttemptIdentityFailsBeforeBarrierOrTransport() async throws {
        let adapter = OpenAIChatCompletionsAdapter(
            model: .init(rawValue: "fixture-model")
        )
        let barrier = RecordingDispatchBarrier()
        let transport = SingleAttemptFixtureTransport(outcomes: [])
        let gateway = ModelGateway(
            catalog: try ProviderAdapterCatalog([adapter]),
            transport: transport
        )
        let stream = await gateway.streamAttempt(.init(
            request: request(id: "scope-request"),
            adapterID: adapter.descriptor.route.adapterID,
            scope: .init(
                requestID: "scope-request",
                attemptID: .init(rawValue: "  ")
            ),
            barrier: barrier
        ))

        do {
            _ = try await collect(stream)
            XCTFail("Expected invalid attempt identity to fail closed")
        } catch {
            XCTAssertEqual(
                error as? ProviderGatewayContractFailure,
                .invalidAttemptScope
            )
        }
        let dispatches = await barrier.dispatches()
        let callCount = await transport.calls()
        XCTAssertEqual(dispatches, [])
        XCTAssertEqual(callCount, 0)
    }

    func testNonRelativeAdapterPathFailsBeforeBarrierOrTransport() async throws {
        let adapter = UnsafePathAdapter()
        let barrier = RecordingDispatchBarrier()
        let transport = SingleAttemptFixtureTransport(outcomes: [])
        let gateway = ModelGateway(
            catalog: try ProviderAdapterCatalog([adapter]),
            transport: transport
        )
        let stream = await gateway.streamAttempt(.init(
            request: request(id: "unsafe-path-request"),
            adapterID: adapter.descriptor.route.adapterID,
            scope: .init(
                requestID: "unsafe-path-request",
                attemptID: .init(rawValue: "attempt-1")
            ),
            barrier: barrier
        ))

        do {
            _ = try await collect(stream)
            XCTFail("Expected a non-relative adapter path to fail closed")
        } catch {
            XCTAssertEqual(
                error as? ProviderGatewayContractFailure,
                .invalidEncodedRequestPath
            )
        }
        let dispatches = await barrier.dispatches()
        let callCount = await transport.calls()
        XCTAssertEqual(dispatches, [])
        XCTAssertEqual(callCount, 0)
    }

    func testSingleAttemptNeverRetriesTransportFailure() async throws {
        let adapter = OpenAIChatCompletionsAdapter(
            model: .init(rawValue: "fixture-model")
        )
        let barrier = RecordingDispatchBarrier()
        let transport = SingleAttemptFixtureTransport(outcomes: [
            .failure(ProviderFailureMapper.transportFailure(
                providerID: adapter.descriptor.route.providerID,
                adapterID: adapter.descriptor.route.adapterID
            )),
            .success(successFrames(text: "must-not-run")),
        ])
        let gateway = ModelGateway(
            catalog: try ProviderAdapterCatalog([adapter]),
            transport: transport
        )
        let stream = await gateway.streamAttempt(.init(
            request: request(id: "failure-request"),
            adapterID: adapter.descriptor.route.adapterID,
            scope: .init(
                requestID: "failure-request",
                attemptID: .init(rawValue: "engine-attempt-99")
            ),
            barrier: barrier
        ))

        do {
            _ = try await collect(stream)
            XCTFail("Expected one transport failure")
        } catch let failure as ProviderFailure {
            XCTAssertEqual(failure.category, .transport)
            XCTAssertEqual(failure.code, "provider_transport_failed")
        }
        let callCount = await transport.calls()
        XCTAssertEqual(callCount, 1)
        let dispatches = await barrier.dispatches()
        XCTAssertEqual(dispatches.count, 1)
    }

    func testCompletionIsWithheldWhenAnIllegalFrameFollowsDone() async throws {
        let adapter = OpenAIChatCompletionsAdapter(
            model: .init(rawValue: "fixture-model")
        )
        let barrier = RecordingDispatchBarrier()
        let illegalTail: ProviderWireFrame = .json(.object([
            "id": .string("single-response"),
            "model": .string("fixture-model"),
            "choices": .array([]),
        ]))
        let transport = SingleAttemptFixtureTransport(outcomes: [
            .success(successFrames(text: "provisional") + [illegalTail]),
        ])
        let gateway = ModelGateway(
            catalog: try ProviderAdapterCatalog([adapter]),
            transport: transport
        )
        let stream = await gateway.streamAttempt(.init(
            request: request(id: "illegal-tail-request"),
            adapterID: adapter.descriptor.route.adapterID,
            scope: .init(
                requestID: "illegal-tail-request",
                attemptID: .init(rawValue: "attempt-1")
            ),
            barrier: barrier
        ))

        var observed: [ProviderAttemptEvent] = []
        do {
            for try await event in stream { observed.append(event) }
            XCTFail("Expected the illegal post-terminal frame to fail")
        } catch let failure as ProviderFailure {
            XCTAssertEqual(failure.category, .protocolViolation)
            XCTAssertEqual(failure.code, "provider_event_after_terminal")
        }
        XCTAssertFalse(observed.contains(where: { event in
            if case .responseCompleted = event.event { true } else { false }
        }))
    }

    func testResponsesCompletionIsWithheldWhenIllegalJSONFollows() async throws {
        let adapter = OpenAIResponsesAdapter(
            model: .init(rawValue: "fixture-model")
        )
        let barrier = RecordingDispatchBarrier()
        let frames: [ProviderWireFrame] = [
            .json(.object([
                "type": .string("response.created"),
                "response": .object([
                    "id": .string("responses-terminal"),
                    "model": .string("fixture-model"),
                ]),
            ])),
            .json(.object([
                "type": .string("response.output_text.delta"),
                "output_index": .number(.integer(0)),
                "delta": .string("provisional"),
            ])),
            .json(.object([
                "type": .string("response.completed"),
                "response": .object([
                    "id": .string("responses-terminal"),
                    "model": .string("fixture-model"),
                    "status": .string("completed"),
                    "usage": .object([
                        "input_tokens": .number(.integer(4)),
                        "output_tokens": .number(.integer(1)),
                    ]),
                    "output": .array([]),
                ]),
            ])),
            .json(.object([
                "type": .string("response.output_text.delta"),
                "output_index": .number(.integer(0)),
                "delta": .string("illegal-tail"),
            ])),
        ]
        let transport = SingleAttemptFixtureTransport(outcomes: [.success(frames)])
        let gateway = ModelGateway(
            catalog: try ProviderAdapterCatalog([adapter]),
            transport: transport
        )
        let stream = await gateway.streamAttempt(.init(
            request: request(id: "responses-illegal-tail"),
            adapterID: adapter.descriptor.route.adapterID,
            scope: .init(
                requestID: "responses-illegal-tail",
                attemptID: .init(rawValue: "attempt-1")
            ),
            barrier: barrier
        ))

        var observed: [ProviderAttemptEvent] = []
        do {
            for try await event in stream { observed.append(event) }
            XCTFail("Expected illegal JSON after Responses completion to fail")
        } catch let failure as ProviderFailure {
            XCTAssertEqual(failure.code, "provider_event_after_terminal")
        }
        XCTAssertFalse(observed.contains(where: { event in
            if case .responseCompleted = event.event { true } else { false }
        }))
    }

    func testChatEOFWithoutFinishReasonCannotBecomeUnknownSuccess() async throws {
        let adapter = OpenAIChatCompletionsAdapter(
            model: .init(rawValue: "fixture-model")
        )
        let barrier = RecordingDispatchBarrier()
        let transport = SingleAttemptFixtureTransport(outcomes: [
            .success([.json(.object([
                "id": .string("truncated-response"),
                "model": .string("fixture-model"),
                "choices": .array([.object([
                    "index": .number(.integer(0)),
                    "delta": .object(["content": .string("truncated")]),
                    "finish_reason": .null,
                ])]),
            ]))]),
        ])
        let gateway = ModelGateway(
            catalog: try ProviderAdapterCatalog([adapter]),
            transport: transport
        )
        let stream = await gateway.streamAttempt(.init(
            request: request(id: "truncated-request"),
            adapterID: adapter.descriptor.route.adapterID,
            scope: .init(
                requestID: "truncated-request",
                attemptID: .init(rawValue: "attempt-1")
            ),
            barrier: barrier
        ))

        var observed: [ProviderAttemptEvent] = []
        do {
            for try await event in stream { observed.append(event) }
            XCTFail("Expected truncated chat EOF to fail")
        } catch let failure as ProviderFailure {
            XCTAssertEqual(failure.category, .malformedEvent)
            XCTAssertEqual(failure.code, "provider_chat_missing_finish_reason")
        }
        XCTAssertFalse(observed.contains(where: { event in
            if case .responseCompleted = event.event { true } else { false }
        }))
    }

    func testGatewayRejectsSequentialReuseOfOneAttemptScope() async throws {
        let adapter = OpenAIChatCompletionsAdapter(
            model: .init(rawValue: "fixture-model")
        )
        let barrier = RecordingDispatchBarrier()
        let transport = SingleAttemptFixtureTransport(outcomes: [
            .success(successFrames(text: "first")),
            .success(successFrames(text: "must-not-dispatch")),
        ])
        let gateway = ModelGateway(
            catalog: try ProviderAdapterCatalog([adapter]),
            transport: transport
        )
        let scope = ProviderAttemptScope(
            requestID: "reused-scope-request",
            attemptID: .init(rawValue: "attempt-1")
        )
        let invocation = ProviderSingleAttemptInvocation(
            request: request(id: scope.requestID),
            adapterID: adapter.descriptor.route.adapterID,
            scope: scope,
            barrier: barrier
        )

        _ = try await collect(await gateway.streamAttempt(invocation))
        do {
            _ = try await collect(await gateway.streamAttempt(invocation))
            XCTFail("Expected repeated attempt scope to fail closed")
        } catch {
            XCTAssertEqual(
                error as? ProviderGatewayContractFailure,
                .duplicateAttemptScope
            )
        }
        let callCount = await transport.calls()
        XCTAssertEqual(callCount, 1)
    }

    func testConcurrentReuseOfOneAttemptScopeDispatchesTransportOnlyOnce() async throws {
        let adapter = OpenAIChatCompletionsAdapter(
            model: .init(rawValue: "fixture-model")
        )
        let barrier = DelayedDispatchBarrier()
        let transport = SingleAttemptFixtureTransport(outcomes: [
            .success(successFrames(text: "winner")),
        ])
        let gateway = ModelGateway(
            catalog: try ProviderAdapterCatalog([adapter]),
            transport: transport
        )
        let scope = ProviderAttemptScope(
            requestID: "concurrent-reuse-request",
            attemptID: .init(rawValue: "attempt-1")
        )
        let invocation = ProviderSingleAttemptInvocation(
            request: request(id: scope.requestID),
            adapterID: adapter.descriptor.route.adapterID,
            scope: scope,
            barrier: barrier
        )

        let outcomes = await withTaskGroup(
            of: ProviderGatewayContractFailure?.self,
            returning: [ProviderGatewayContractFailure?].self
        ) { group in
            for _ in 0 ..< 2 {
                group.addTask {
                    do {
                        _ = try await collectAttemptEvents(
                            await gateway.streamAttempt(invocation)
                        )
                        return nil
                    } catch {
                        return error as? ProviderGatewayContractFailure
                    }
                }
            }
            var values: [ProviderGatewayContractFailure?] = []
            for await value in group { values.append(value) }
            return values
        }

        XCTAssertEqual(outcomes.filter { $0 == nil }.count, 1)
        XCTAssertEqual(outcomes.compactMap { $0 }, [.duplicateAttemptScope])
        let callCount = await transport.calls()
        XCTAssertEqual(callCount, 1)
        let dispatchCount = await barrier.count()
        XCTAssertEqual(dispatchCount, 2)
    }

    func testSlowConsumerFailsClosedWhenBoundedGatewayBufferOverflows() async throws {
        let adapter = OpenAIChatCompletionsAdapter(
            model: .init(rawValue: "fixture-model")
        )
        let barrier = RecordingDispatchBarrier()
        var frames: [ProviderWireFrame] = []
        for index in 0 ..< 300 {
            frames.append(.json(.object([
                "id": .string("buffered-response"),
                "model": .string("fixture-model"),
                "choices": .array([.object([
                    "index": .number(.integer(0)),
                    "delta": .object(["content": .string("x\(index)")]),
                    "finish_reason": .null,
                ])]),
            ])))
        }
        frames.append(.json(.object([
            "id": .string("buffered-response"),
            "model": .string("fixture-model"),
            "choices": .array([.object([
                "index": .number(.integer(0)),
                "delta": .object([:]),
                "finish_reason": .string("stop"),
            ])]),
        ])))
        frames.append(.done)
        let transport = SingleAttemptFixtureTransport(outcomes: [.success(frames)])
        let gateway = ModelGateway(
            catalog: try ProviderAdapterCatalog([adapter]),
            transport: transport
        )
        let scope = ProviderAttemptScope(
            requestID: "backpressure-request",
            attemptID: .init(rawValue: "attempt-1")
        )
        let stream = await gateway.streamAttempt(.init(
            request: request(id: scope.requestID),
            adapterID: adapter.descriptor.route.adapterID,
            scope: scope,
            barrier: barrier
        ))

        // The producer starts when the stream is created. Deliberately avoid
        // consuming until it has exceeded the bounded gateway queue.
        try await Task.sleep(for: .milliseconds(50))
        var observedTerminal = false
        do {
            for try await event in stream {
                if case .responseCompleted = event.event { observedTerminal = true }
            }
            XCTFail("Expected bounded buffering to fail the slow consumer")
        } catch {
            XCTAssertEqual(
                error as? ProviderGatewayContractFailure,
                .consumerBackpressureExceeded
            )
        }
        XCTAssertFalse(observedTerminal)
        let callCount = await transport.calls()
        XCTAssertEqual(callCount, 1)
    }

    func testLegacyGatewayRejectsUnsafePathBeforeTransport() async throws {
        let adapter = UnsafePathAdapter()
        let transport = SingleAttemptFixtureTransport(outcomes: [])
        let gateway = ModelGateway(
            catalog: try ProviderAdapterCatalog([adapter]),
            transport: transport
        )

        do {
            _ = try await gateway.generate(.init(
                request: request(id: "legacy-unsafe-path"),
                preferredAdapterIDs: [adapter.descriptor.route.adapterID],
                recoveryPolicy: .init(
                    maximumAttemptsPerRoute: 1,
                    maximumFallbacks: 0,
                    baseBackoffMilliseconds: 0,
                    maximumBackoffMilliseconds: 0,
                    jitterBasisPoints: 0
                ),
                deterministicSeed: 1
            ))
            XCTFail("Expected unsafe legacy adapter path to fail closed")
        } catch {
            XCTAssertEqual(
                error as? ProviderGatewayContractFailure,
                .invalidEncodedRequestPath
            )
        }
        let callCount = await transport.calls()
        XCTAssertEqual(callCount, 0)
    }

    func testRouteNegotiationDoesNotDispatchTransport() async throws {
        let local = try LocalModelAdapter(configuration: .init(
            modelID: .init(rawValue: "local-model")
        ))
        let hosted = OpenAIChatCompletionsAdapter(
            model: .init(rawValue: "hosted-model")
        )
        let transport = SingleAttemptFixtureTransport(outcomes: [])
        let gateway = ModelGateway(
            catalog: try ProviderAdapterCatalog([hosted, local]),
            transport: transport
        )

        let routes = try await gateway.negotiateRoutes(
            preferredAdapterIDs: [
                local.descriptor.route.adapterID,
                hosted.descriptor.route.adapterID,
            ],
            requirements: request(id: "route-only").capabilityRequirements
        )

        XCTAssertEqual(routes.map(\.adapterID), [
            local.descriptor.route.adapterID,
            hosted.descriptor.route.adapterID,
        ])
        let callCount = await transport.calls()
        XCTAssertEqual(callCount, 0)
    }

    private func request(
        id: String,
        prompt: String = "secret prompt"
    ) -> CanonicalProviderRequest {
        CanonicalProviderRequest(
            requestID: id,
            model: .init(rawValue: "caller-placeholder"),
            messages: [.init(role: .user, content: [.text(prompt)])]
        )
    }

    private func captureDispatch(
        adapter: any ProviderAdapter,
        request: CanonicalProviderRequest,
        attemptID: String
    ) async throws -> ProviderAttemptDispatch {
        let barrier = RecordingDispatchBarrier()
        let transport = SingleAttemptFixtureTransport(outcomes: [
            .success(successFrames(text: "digest-fixture")),
        ])
        let gateway = ModelGateway(
            catalog: try ProviderAdapterCatalog([adapter]),
            transport: transport
        )
        let scope = ProviderAttemptScope(
            requestID: request.requestID,
            attemptID: .init(rawValue: attemptID)
        )

        _ = try await collect(await gateway.streamAttempt(.init(
            request: request,
            adapterID: adapter.descriptor.route.adapterID,
            scope: scope,
            barrier: barrier
        )))

        let dispatches = await barrier.dispatches()
        XCTAssertEqual(dispatches.count, 1)
        return try XCTUnwrap(dispatches.first)
    }

    private func successFrames(text: String) -> [ProviderWireFrame] {
        [
            .json(.object([
                "id": .string("single-response"),
                "model": .string("fixture-model"),
                "choices": .array([.object([
                    "index": .number(.integer(0)),
                    "delta": .object(["content": .string(text)]),
                    "finish_reason": .null,
                ])]),
            ])),
            .json(.object([
                "id": .string("single-response"),
                "model": .string("fixture-model"),
                "choices": .array([.object([
                    "index": .number(.integer(0)),
                    "delta": .object([:]),
                    "finish_reason": .string("stop"),
                ])]),
            ])),
            .done,
        ]
    }

    private func collect(
        _ stream: AsyncThrowingStream<ProviderAttemptEvent, any Error>
    ) async throws -> [ProviderAttemptEvent] {
        var events: [ProviderAttemptEvent] = []
        for try await event in stream {
            events.append(event)
        }
        return events
    }
}

private enum DispatchBarrierFixtureError: Error, Equatable, Sendable {
    case journalUnavailable
}

private struct UnsafePathAdapter: ProviderAdapter {
    private let base = OpenAIChatCompletionsAdapter(
        model: .init(rawValue: "fixture-model")
    )

    var descriptor: ProviderAdapterDescriptor { base.descriptor }

    func encode(_ request: CanonicalProviderRequest) throws -> ProviderEncodedRequest {
        ProviderEncodedRequest(
            relativePath: "https://untrusted.example/v1/chat/completions",
            body: .object(["model": .string(request.model.rawValue)])
        )
    }

}

private actor RecordingDispatchBarrier: ProviderAttemptDispatchBarrier {
    private let failure: DispatchBarrierFixtureError?
    private var values: [ProviderAttemptDispatch] = []

    init(failure: DispatchBarrierFixtureError? = nil) {
        self.failure = failure
    }

    func beforeDispatch(_ attempt: ProviderAttemptDispatch) async throws {
        values.append(attempt)
        if let failure { throw failure }
    }

    func dispatches() -> [ProviderAttemptDispatch] { values }
}

private actor DelayedDispatchBarrier: ProviderAttemptDispatchBarrier {
    private var dispatchCount = 0

    func beforeDispatch(_ attempt: ProviderAttemptDispatch) async throws {
        _ = attempt
        dispatchCount += 1
        try await Task.sleep(for: .milliseconds(20))
    }

    func count() -> Int { dispatchCount }
}

private func collectAttemptEvents(
    _ stream: AsyncThrowingStream<ProviderAttemptEvent, any Error>
) async throws -> [ProviderAttemptEvent] {
    var events: [ProviderAttemptEvent] = []
    for try await event in stream { events.append(event) }
    return events
}

private actor SingleAttemptFixtureTransport: ProviderTransport {
    enum Outcome: Sendable {
        case success([ProviderWireFrame])
        case failure(ProviderFailure)
    }

    private let outcomes: [Outcome]
    private var callCount = 0

    init(outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    func stream(
        request: ProviderEncodedRequest,
        descriptor: ProviderAdapterDescriptor,
        scope: ProviderAttemptScope
    ) async throws -> AsyncThrowingStream<ProviderWireFrame, any Error> {
        let index = callCount
        callCount += 1
        guard outcomes.indices.contains(index) else {
            throw ProviderFailureMapper.transportFailure(
                providerID: descriptor.route.providerID,
                adapterID: descriptor.route.adapterID
            )
        }
        switch outcomes[index] {
        case let .success(frames):
            return AsyncThrowingStream { continuation in
                for frame in frames { continuation.yield(frame) }
                continuation.finish()
            }
        case let .failure(failure):
            throw failure
        }
    }

    func calls() -> Int { callCount }
}
