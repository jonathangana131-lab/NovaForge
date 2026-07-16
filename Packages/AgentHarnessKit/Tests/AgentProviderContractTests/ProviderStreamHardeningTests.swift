import AgentDomain
@testable import AgentProviders
import XCTest

final class ProviderStreamHardeningTests: XCTestCase {
    func testResponsesOutputBeforeCreatedFailsClosed() throws {
        var session = responsesSession()
        XCTAssertThrowsError(try session.receive(.json(.object([
            "type": .string("response.output_text.delta"),
            "output_index": .number(.integer(0)),
            "delta": .string("too early"),
        ])))) { error in
            XCTAssertEqual(
                (error as? ProviderFailure)?.code,
                "provider_responses_event_before_start"
            )
        }
    }

    func testResponsesArgumentsDoneMustMatchStreamedFragments() throws {
        var session = toolResponsesSession()
        _ = try session.receive(responseCreated())
        _ = try session.receive(toolItemAdded())
        _ = try session.receive(.json(.object([
            "type": .string("response.function_call_arguments.delta"),
            "output_index": .number(.integer(0)),
            "item_id": .string("item-1"),
            "delta": .string("{\"path\":\"a\"}"),
        ])))

        XCTAssertThrowsError(try session.receive(.json(.object([
            "type": .string("response.function_call_arguments.done"),
            "output_index": .number(.integer(0)),
            "item_id": .string("item-1"),
            "arguments": .string("{\"path\":\"different\"}"),
        ])))) { error in
            XCTAssertEqual(
                (error as? ProviderFailure)?.code,
                "provider_tool_arguments_done_mismatch"
            )
        }
    }

    func testResponsesToolCallIsImmutableAfterCompletion() throws {
        var session = toolResponsesSession()
        _ = try session.receive(responseCreated())
        _ = try session.receive(toolItemAdded())
        _ = try session.receive(toolArgumentsDone("{\"path\":\"a\"}"))

        XCTAssertThrowsError(try session.receive(.json(.object([
            "type": .string("response.function_call_arguments.delta"),
            "output_index": .number(.integer(0)),
            "item_id": .string("item-1"),
            "delta": .string(" "),
        ])))) { error in
            XCTAssertEqual(
                (error as? ProviderFailure)?.code,
                "provider_tool_event_after_completion"
            )
        }
    }

    func testExactTerminalToolReplayIsNoOpButConflictFails() throws {
        var session = toolResponsesSession()
        _ = try session.receive(responseCreated())
        _ = try session.receive(toolItemAdded())
        _ = try session.receive(toolArgumentsDone("{\"path\":\"a\"}"))
        XCTAssertEqual(
            try session.receive(toolItemDone(arguments: "{\"path\":\"a\"}")),
            []
        )
        XCTAssertThrowsError(try session.receive(
            toolItemDone(arguments: "{\"path\":\"b\"}")
        )) { error in
            XCTAssertEqual(
                (error as? ProviderFailure)?.code,
                "provider_tool_completion_replay_mismatch"
            )
        }
    }

    func testChatRejectsNonzeroOuterChoiceIndex() throws {
        var session = chatSession()
        XCTAssertThrowsError(try session.receive(chatFrame(
            index: 1,
            delta: ["content": .string("hidden candidate")],
            finishReason: nil
        ))) { error in
            XCTAssertEqual(
                (error as? ProviderFailure)?.code,
                "provider_chat_choice_index_not_supported"
            )
        }
    }

    func testHostedChatRejectsUnknownFinishReason() throws {
        var session = chatSession()
        XCTAssertThrowsError(try session.receive(chatFrame(
            index: 0,
            delta: [:],
            finishReason: "future_reason"
        ))) { error in
            XCTAssertEqual(
                (error as? ProviderFailure)?.code,
                "provider_finish_reason_invalid"
            )
        }
    }

    func testBuiltInChatRejectsUnknownOutputBearingDeltaField() throws {
        var session = chatSession()
        XCTAssertThrowsError(try session.receive(chatFrame(
            index: 0,
            delta: ["audio": .string("opaque-output")],
            finishReason: nil
        ))) { error in
            XCTAssertEqual(
                (error as? ProviderFailure)?.code,
                "provider_chat_delta_field_unknown"
            )
        }
    }

    func testChatRejectsEveryOutputKindAfterFinishReason() throws {
        for delta in [
            ["content": JSONValue.string("late text")],
            ["reasoning_content": JSONValue.string("late reasoning")],
        ] {
            var session = chatSession()
            _ = try session.receive(chatFrame(
                index: 0,
                delta: [:],
                finishReason: "stop"
            ))
            XCTAssertThrowsError(try session.receive(chatFrame(
                index: 0,
                delta: delta,
                finishReason: nil
            ))) { error in
                XCTAssertEqual(
                    (error as? ProviderFailure)?.code,
                    "provider_chat_output_after_finish"
                )
            }
        }

        var toolSession = toolChatSession()
        _ = try toolSession.receive(chatFrame(
            index: 0,
            delta: [:],
            finishReason: "stop"
        ))
        XCTAssertThrowsError(try toolSession.receive(chatFrame(
            index: 0,
            delta: [
                "tool_calls": .array([.object([
                    "index": .number(.integer(0)),
                    "id": .string("call-late"),
                    "function": .object([
                        "name": .string("read_file"),
                        "arguments": .string("{\"path\":\"late\"}"),
                    ]),
                ])]),
            ],
            finishReason: nil
        ))) { error in
            XCTAssertEqual(
                (error as? ProviderFailure)?.code,
                "provider_chat_output_after_finish"
            )
        }
    }

    func testChatRejectsUsageWhileToolCallIsIncomplete() throws {
        var session = toolChatSession()
        _ = try session.receive(chatFrame(
            index: 0,
            delta: [
                "tool_calls": .array([.object([
                    "index": .number(.integer(0)),
                    "id": .string("call-partial"),
                    "function": .object([
                        "name": .string("read_file"),
                        "arguments": .string("{\"path\":"),
                    ]),
                ])]),
            ],
            finishReason: nil
        ))

        XCTAssertThrowsError(try session.receive(chatUsageFrame())) { error in
            XCTAssertEqual(
                (error as? ProviderFailure)?.code,
                "provider_chat_usage_before_tool_completion"
            )
        }
    }

    func testChatRejectsSecondToolWhenRequestDisabledParallelCalls() throws {
        var session = toolChatSession(parallelToolCalls: false)
        XCTAssertThrowsError(try session.receive(chatFrame(
            index: 0,
            delta: [
                "tool_calls": .array([
                    .object([
                        "index": .number(.integer(0)),
                        "id": .string("call-a"),
                        "function": .object([
                            "name": .string("read_file"),
                            "arguments": .string("{\"path\":\"a\"}"),
                        ]),
                    ]),
                    .object([
                        "index": .number(.integer(1)),
                        "id": .string("call-b"),
                        "function": .object([
                            "name": .string("read_file"),
                            "arguments": .string("{\"path\":\"b\"}"),
                        ]),
                    ]),
                ]),
            ],
            finishReason: nil
        ))) { error in
            XCTAssertEqual(
                (error as? ProviderFailure)?.code,
                "provider_parallel_tool_output_not_supported"
            )
        }
    }

    func testUnknownResponsesLifecycleEventFailsClosed() throws {
        var session = responsesSession()
        _ = try session.receive(responseCreated())
        XCTAssertThrowsError(try session.receive(.json(.object([
            "type": .string("response.image_generation_call.delta"),
            "delta": .string("opaque-output"),
        ])))) { error in
            XCTAssertEqual(
                (error as? ProviderFailure)?.code,
                "provider_responses_event_type_unknown"
            )
        }
    }

    func testResponsesTerminalSnapshotRejectsNonTextOutputItems() throws {
        let hostileItems: [(JSONValue, String)] = [
            (
                .object(["type": .string("image_generation_call")]),
                "provider_responses_output_item_not_supported"
            ),
            (
                .object(["type": .string("future_output")]),
                "provider_responses_output_item_not_supported"
            ),
            (
                .object([
                    "type": .string("message"),
                    "role": .string("assistant"),
                    "content": .array([.object([
                        "type": .string("refusal"),
                        "refusal": .string("hidden refusal"),
                    ])]),
                ]),
                "provider_nontext_output_not_supported"
            ),
        ]

        for (item, expectedCode) in hostileItems {
            var session = responsesSession()
            _ = try session.receive(responseCreated())
            XCTAssertThrowsError(try session.receive(
                responsesCompletion(output: [item])
            )) { error in
                XCTAssertEqual((error as? ProviderFailure)?.code, expectedCode)
            }
        }
    }

    func testResponsesTerminalMessageMustMatchStreamedText() throws {
        var session = responsesSession()
        _ = try session.receive(responseCreated())
        _ = try session.receive(.json(.object([
            "type": .string("response.output_text.delta"),
            "output_index": .number(.integer(0)),
            "content_index": .number(.integer(0)),
            "delta": .string("visible"),
        ])))

        XCTAssertThrowsError(try session.receive(responsesCompletion(output: [
            .object([
                "type": .string("message"),
                "role": .string("assistant"),
                "content": .array([.object([
                    "type": .string("output_text"),
                    "text": .string("different"),
                ])]),
            ]),
        ]))) { error in
            XCTAssertEqual(
                (error as? ProviderFailure)?.code,
                "provider_responses_text_snapshot_mismatch"
            )
        }
    }

    func testResponsesOutputTextDoneCannotIntroduceUnstreamedText() throws {
        var session = responsesSession()
        _ = try session.receive(responseCreated())

        XCTAssertThrowsError(try session.receive(.json(.object([
            "type": .string("response.output_text.done"),
            "output_index": .number(.integer(0)),
            "content_index": .number(.integer(0)),
            "text": .string("hidden terminal text"),
        ])))) { error in
            XCTAssertEqual(
                (error as? ProviderFailure)?.code,
                "provider_responses_text_done_mismatch"
            )
        }
    }

    func testResponsesCancellationRejectsConflictingIdentity() throws {
        var session = responsesSession()
        _ = try session.receive(responseCreated())
        XCTAssertThrowsError(try session.receive(.json(.object([
            "type": .string("response.cancelled"),
            "response": .object([
                "id": .string("different-response"),
                "model": .string("fixture-model"),
            ]),
        ])))) { error in
            XCTAssertEqual(
                (error as? ProviderFailure)?.code,
                "provider_responses_identity_changed"
            )
        }
    }

    func testToolArgumentAccumulatorHasHardByteLimit() throws {
        var session = toolChatSession()
        let oversized = String(repeating: "x", count: 1_048_577)
        XCTAssertThrowsError(try session.receive(chatFrame(
            index: 0,
            delta: [
                "tool_calls": .array([.object([
                    "index": .number(.integer(0)),
                    "id": .string("call-1"),
                    "function": .object([
                        "name": .string("read_file"),
                        "arguments": .string(oversized),
                    ]),
                ])]),
            ],
            finishReason: nil
        ))) { error in
            XCTAssertEqual(
                (error as? ProviderFailure)?.code,
                "provider_tool_arguments_budget_exceeded"
            )
        }
    }

    private func responsesSession() -> ProviderStreamSession {
        let adapter = OpenAIResponsesAdapter(model: .init(rawValue: "fixture-model"))
        let request = textRequest(model: "fixture-model")
        return ProviderStreamSession(
            descriptor: adapter.descriptor,
            scope: .init(
                requestID: request.requestID,
                attemptID: .init(rawValue: "attempt-1")
            ),
            request: request
        )
    }

    private func toolResponsesSession() -> ProviderStreamSession {
        let adapter = OpenAIResponsesAdapter(model: .init(rawValue: "fixture-model"))
        let request = toolRequest(model: "fixture-model")
        return ProviderStreamSession(
            descriptor: adapter.descriptor,
            scope: .init(
                requestID: request.requestID,
                attemptID: .init(rawValue: "attempt-1")
            ),
            request: request
        )
    }

    private func chatSession() -> ProviderStreamSession {
        let adapter = OpenAIChatCompletionsAdapter(model: .init(rawValue: "fixture-model"))
        let request = textRequest(model: "fixture-model")
        return ProviderStreamSession(
            descriptor: adapter.descriptor,
            scope: .init(
                requestID: request.requestID,
                attemptID: .init(rawValue: "attempt-1")
            ),
            request: request
        )
    }

    private func toolChatSession(
        parallelToolCalls: Bool? = nil
    ) -> ProviderStreamSession {
        let adapter = OpenAIChatCompletionsAdapter(model: .init(rawValue: "fixture-model"))
        let request = toolRequest(
            model: "fixture-model",
            parallelToolCalls: parallelToolCalls
        )
        return ProviderStreamSession(
            descriptor: adapter.descriptor,
            scope: .init(
                requestID: request.requestID,
                attemptID: .init(rawValue: "attempt-1")
            ),
            request: request
        )
    }

    private func toolRequest(
        model: String,
        parallelToolCalls: Bool? = nil
    ) -> CanonicalProviderRequest {
        CanonicalProviderRequest(
            requestID: "request-1",
            model: .init(rawValue: model),
            messages: [.init(role: .user, content: [.text("Read")])],
            tools: [.init(
                name: "read_file",
                description: "Read one file",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object(["type": .string("string")]),
                    ]),
                    "required": .array([.string("path")]),
                    "additionalProperties": .bool(false),
                ])
            )],
            options: .init(parallelToolCalls: parallelToolCalls)
        )
    }

    private func textRequest(model: String) -> CanonicalProviderRequest {
        CanonicalProviderRequest(
            requestID: "request-1",
            model: .init(rawValue: model),
            messages: [.init(role: .user, content: [.text("Reply")])]
        )
    }

    private func responseCreated() -> ProviderWireFrame {
        .json(.object([
            "type": .string("response.created"),
            "response": .object([
                "id": .string("response-1"),
                "model": .string("fixture-model"),
            ]),
        ]))
    }

    private func toolItemAdded() -> ProviderWireFrame {
        .json(.object([
            "type": .string("response.output_item.added"),
            "output_index": .number(.integer(0)),
            "item": .object([
                "id": .string("item-1"),
                "type": .string("function_call"),
                "call_id": .string("call-1"),
                "name": .string("read_file"),
                "arguments": .string(""),
            ]),
        ]))
    }

    private func toolArgumentsDone(_ arguments: String) -> ProviderWireFrame {
        .json(.object([
            "type": .string("response.function_call_arguments.done"),
            "output_index": .number(.integer(0)),
            "item_id": .string("item-1"),
            "call_id": .string("call-1"),
            "name": .string("read_file"),
            "arguments": .string(arguments),
        ]))
    }

    private func toolItemDone(arguments: String) -> ProviderWireFrame {
        .json(.object([
            "type": .string("response.output_item.done"),
            "output_index": .number(.integer(0)),
            "item": .object([
                "id": .string("item-1"),
                "type": .string("function_call"),
                "call_id": .string("call-1"),
                "name": .string("read_file"),
                "arguments": .string(arguments),
            ]),
        ]))
    }

    private func responsesCompletion(output: [JSONValue]) -> ProviderWireFrame {
        .json(.object([
            "type": .string("response.completed"),
            "response": .object([
                "id": .string("response-1"),
                "model": .string("fixture-model"),
                "status": .string("completed"),
                "output": .array(output),
            ]),
        ]))
    }

    private func chatUsageFrame() -> ProviderWireFrame {
        .json(.object([
            "id": .string("chat-response"),
            "model": .string("fixture-model"),
            "choices": .array([]),
            "usage": .object([
                "prompt_tokens": .number(.integer(2)),
                "completion_tokens": .number(.integer(1)),
            ]),
        ]))
    }

    private func chatFrame(
        index: Int,
        delta: [String: JSONValue],
        finishReason: String?
    ) -> ProviderWireFrame {
        .json(.object([
            "id": .string("chat-response"),
            "model": .string("fixture-model"),
            "choices": .array([.object([
                "index": .number(.integer(Int64(index))),
                "delta": .object(delta),
                "finish_reason": finishReason.map(JSONValue.string) ?? .null,
            ])]),
        ]))
    }
}
