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

    func testOpenCodeZenAcceptsLiveReasoningContentFrames() throws {
        var session = zenReasoningChatSession()
        let responseID = "0f0147ea-07e8-4b39-854d-dad783dbf42f"
        let model = "deepseek-v4-flash-free"

        let first = try session.receive(.json(.object([
            "id": .string(responseID),
            "object": .string("chat.completion.chunk"),
            "created": .number(.integer(1_784_501_832)),
            "model": .string(model),
            "choices": .array([.object([
                "index": .number(.integer(0)),
                "finish_reason": .null,
                "logprobs": .null,
                "delta": .object([
                    "role": .string("assistant"),
                    "content": .null,
                    "reasoning_content": .string(""),
                ]),
            ])]),
            "usage": .null,
        ])))
        XCTAssertEqual(first.map(\.event), [
            .responseStarted(.init(
                responseID: responseID,
                model: .init(rawValue: model)
            )),
        ])

        let second = try session.receive(.json(.object([
            "id": .string(responseID),
            "object": .string("chat.completion.chunk"),
            "created": .number(.integer(1_784_501_832)),
            "model": .string(model),
            "choices": .array([.object([
                "index": .number(.integer(0)),
                "finish_reason": .null,
                "logprobs": .null,
                "delta": .object([
                    "content": .null,
                    "reasoning_content": .string("The"),
                ]),
            ])]),
            "usage": .null,
        ])))
        XCTAssertEqual(second.map(\.event), [
            .reasoningDelta(.init(outputIndex: 0, text: "The")),
        ])
    }

    func testGenericChatDoesNotGainZenReasoningAuthority() throws {
        var session = chatSession()
        XCTAssertThrowsError(try session.receive(chatFrame(
            index: 0,
            delta: ["reasoning_content": .string("private reasoning")],
            finishReason: nil
        ))) { error in
            XCTAssertEqual(
                (error as? ProviderFailure)?.code,
                "provider_reasoning_output_not_supported"
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

    func testChatGPTMetadataBeforeCreatedBindsResponseIdentity() throws {
        var session = codexResponsesSession()
        XCTAssertEqual(try session.receive(.json(.object([
            "type": .string("response.metadata"),
            "sequence_number": .number(.integer(1)),
            "response_id": .string("response-1"),
            "headers": .object(["x-codex-turn-state": .string("turn-1")]),
            "metadata": .object([
                "openai_verification_recommendation": .array([]),
            ]),
            "safety_buffering": .object(["retry_model": .string("fixture-model")]),
        ]))), [])

        let events = try session.receive(responseCreated())
        XCTAssertEqual(events.map(\.event), [
            .responseStarted(.init(
                responseID: "response-1",
                model: .init(rawValue: "fixture-model")
            )),
        ])
    }

    func testChatGPTMetadataBetweenTextDeltasIsIgnoredAsControlPlaneData() throws {
        var session = codexResponsesSession()
        _ = try session.receive(responseCreated())
        _ = try session.receive(.json(.object([
            "type": .string("response.output_text.delta"),
            "output_index": .number(.integer(0)),
            "content_index": .number(.integer(0)),
            "delta": .string("hello"),
        ])))

        XCTAssertEqual(try session.receive(.json(.object([
            "type": .string("response.metadata"),
            "response_id": .string("response-1"),
            "metadata": .object([
                "openai_chatgpt_moderation_metadata": .object([:]),
            ]),
        ]))), [])

        _ = try session.receive(.json(.object([
            "type": .string("response.output_text.delta"),
            "output_index": .number(.integer(0)),
            "content_index": .number(.integer(0)),
            "delta": .string(" world"),
        ])))
        XCTAssertNoThrow(try session.receive(responsesCompletion(output: [])))
    }

    func testChatGPTLiveReasoningAndMessageLifecycleShapeCompletes() throws {
        var session = codexResponsesSession()
        let reasoningItem: JSONValue = .object([
            "id": .string("reasoning-1"),
            "type": .string("reasoning"),
            "summary": .array([.object([
                "type": .string("summary_text"),
                "text": .string("R"),
            ])]),
        ])
        let messageItem: JSONValue = .object([
            "id": .string("message-1"),
            "type": .string("message"),
            "role": .string("assistant"),
            "status": .string("completed"),
            "content": .array([.object([
                "type": .string("output_text"),
                "text": .string("OK"),
            ])]),
        ])
        let frames: [ProviderWireFrame] = [
            responseCreated(),
            .json(.object([
                "type": .string("response.in_progress"),
            ])),
            .json(.object([
                "type": .string("response.output_item.added"),
                "output_index": .number(.integer(0)),
                "item": .object([
                    "id": .string("reasoning-1"),
                    "type": .string("reasoning"),
                    "summary": .array([]),
                ]),
            ])),
            .json(.object([
                "type": .string("response.reasoning_summary_part.added"),
                "output_index": .number(.integer(0)),
                "summary_index": .number(.integer(0)),
                "part": .object([
                    "type": .string("summary_text"),
                    "text": .string(""),
                ]),
            ])),
            .json(.object([
                "type": .string("response.reasoning_summary_text.delta"),
                "output_index": .number(.integer(0)),
                "summary_index": .number(.integer(0)),
                "delta": .string("R"),
            ])),
            .json(.object([
                "type": .string("response.reasoning_summary_text.done"),
                "output_index": .number(.integer(0)),
                "summary_index": .number(.integer(0)),
                "text": .string("R"),
            ])),
            .json(.object([
                "type": .string("response.reasoning_summary_part.done"),
                "output_index": .number(.integer(0)),
                "summary_index": .number(.integer(0)),
                "part": .object([
                    "type": .string("summary_text"),
                    "text": .string("R"),
                ]),
            ])),
            .json(.object([
                "type": .string("response.output_item.done"),
                "output_index": .number(.integer(0)),
                "item": reasoningItem,
            ])),
            .json(.object([
                "type": .string("response.output_item.added"),
                "output_index": .number(.integer(1)),
                "item": .object([
                    "id": .string("message-1"),
                    "type": .string("message"),
                    "role": .string("assistant"),
                    "status": .string("in_progress"),
                    "content": .array([]),
                ]),
            ])),
            .json(.object([
                "type": .string("response.content_part.added"),
                "output_index": .number(.integer(1)),
                "content_index": .number(.integer(0)),
                "part": .object([
                    "type": .string("output_text"),
                    "text": .string(""),
                ]),
            ])),
            .json(.object([
                "type": .string("response.output_text.delta"),
                "output_index": .number(.integer(1)),
                "content_index": .number(.integer(0)),
                "delta": .string("O"),
            ])),
            .json(.object([
                "type": .string("response.output_text.delta"),
                "output_index": .number(.integer(1)),
                "content_index": .number(.integer(0)),
                "delta": .string("K"),
            ])),
            .json(.object([
                "type": .string("response.output_text.done"),
                "output_index": .number(.integer(1)),
                "content_index": .number(.integer(0)),
                "text": .string("OK"),
            ])),
            .json(.object([
                "type": .string("response.content_part.done"),
                "output_index": .number(.integer(1)),
                "content_index": .number(.integer(0)),
                "part": .object([
                    "type": .string("output_text"),
                    "text": .string("OK"),
                ]),
            ])),
            .json(.object([
                "type": .string("response.output_item.done"),
                "output_index": .number(.integer(1)),
                "item": messageItem,
            ])),
            responsesCompletion(
                output: [reasoningItem, messageItem],
                inputTokens: 2,
                outputTokens: 3
            ),
        ]

        var canonical: [ProviderStreamEvent] = []
        for frame in frames {
            canonical.append(contentsOf: try session.receive(frame).map(\.event))
        }
        XCTAssertEqual(canonical.compactMap { event -> String? in
            guard case let .reasoningDelta(delta) = event else { return nil }
            return delta.text
        }.joined(), "R")
        XCTAssertEqual(canonical.compactMap { event -> String? in
            guard case let .textDelta(delta) = event else { return nil }
            return delta.text
        }.joined(), "OK")
        XCTAssertTrue(canonical.contains { event in
            guard case let .responseCompleted(completion) = event else {
                return false
            }
            return completion.responseID == "response-1" &&
                completion.finishReason == .completed
        })
    }

    func testChatGPTMetadataRejectsMismatchedResponseIdentity() throws {
        var session = codexResponsesSession()
        _ = try session.receive(responseCreated())
        XCTAssertThrowsError(try session.receive(.json(.object([
            "type": .string("response.metadata"),
            "response_id": .string("response-other"),
        ])))) { error in
            XCTAssertEqual(
                (error as? ProviderFailure)?.code,
                "provider_responses_metadata_identity_changed"
            )
        }
    }

    func testChatGPTMetadataRejectsScalarControlObjects() throws {
        for field in ["headers", "metadata", "safety_buffering"] {
            var session = codexResponsesSession()
            XCTAssertThrowsError(try session.receive(.json(.object([
                "type": .string("response.metadata"),
                field: .string("not-an-object"),
            ])))) { error in
                XCTAssertEqual(
                    (error as? ProviderFailure)?.code,
                    "provider_responses_metadata_\(field)_invalid"
                )
            }
        }
    }

    func testChatGPTMetadataRejectsInvalidSequenceNumbers() throws {
        for sequenceNumber in [
            JSONValue.number(.integer(-1)),
            .number(.floatingPoint(1.5)),
        ] {
            var session = codexResponsesSession()
            XCTAssertThrowsError(try session.receive(.json(.object([
                "type": .string("response.metadata"),
                "sequence_number": sequenceNumber,
            ])))) { error in
                XCTAssertEqual(
                    (error as? ProviderFailure)?.code,
                    "provider_responses_metadata_sequence_invalid"
                )
            }
        }
    }

    func testGenericResponsesRouteDoesNotGainChatGPTMetadataAuthority() throws {
        var session = responsesSession()
        XCTAssertThrowsError(try session.receive(.json(.object([
            "type": .string("response.metadata"),
            "metadata": .object([:]),
        ])))) { error in
            XCTAssertEqual(
                (error as? ProviderFailure)?.code,
                "provider_responses_metadata_not_supported"
            )
        }
    }

    func testChatGPTUsageUsesRouteLimitWhenRequestLimitWasNotSent() throws {
        var session = codexResponsesSession(maximumOutputTokens: 4_096)
        _ = try session.receive(responseCreated())
        XCTAssertNoThrow(try session.receive(responsesCompletion(
            output: [],
            inputTokens: 1,
            outputTokens: 4_097
        )))
    }

    func testChatGPTUsageStillRejectsOutputBeyondPinnedRouteLimit() throws {
        var session = codexResponsesSession(maximumOutputTokens: 4_096)
        _ = try session.receive(responseCreated())
        XCTAssertThrowsError(try session.receive(responsesCompletion(
            output: [],
            inputTokens: 1,
            outputTokens: 16_385
        ))) { error in
            XCTAssertEqual(
                (error as? ProviderFailure)?.code,
                "provider_usage_counts_invalid"
            )
        }
    }

    func testGenericResponsesUsageStillEnforcesSentRequestLimit() throws {
        var session = responsesSession(maximumOutputTokens: 4_096)
        _ = try session.receive(responseCreated())
        XCTAssertThrowsError(try session.receive(responsesCompletion(
            output: [],
            inputTokens: 1,
            outputTokens: 4_097
        ))) { error in
            XCTAssertEqual(
                (error as? ProviderFailure)?.code,
                "provider_usage_request_output_limit_exceeded"
            )
        }
    }

    func testResponsesReasoningSummaryPartLifecycleIsAcceptedAndReconciled() throws {
        var session = reasoningResponsesSession()
        _ = try session.receive(responseCreated())

        XCTAssertEqual(try session.receive(.json(.object([
            "type": .string("response.reasoning_summary_part.added"),
            "output_index": .number(.integer(0)),
            "summary_index": .number(.integer(0)),
            "part": .object([
                "type": .string("summary_text"),
                "text": .string(""),
            ]),
        ]))), [])

        let delta = try session.receive(.json(.object([
            "type": .string("response.reasoning_summary_text.delta"),
            "output_index": .number(.integer(0)),
            "summary_index": .number(.integer(0)),
            "delta": .string("Checked the constraints."),
        ])))
        XCTAssertEqual(delta.count, 1)

        XCTAssertEqual(try session.receive(.json(.object([
            "type": .string("response.reasoning_summary_text.done"),
            "output_index": .number(.integer(0)),
            "summary_index": .number(.integer(0)),
            "text": .string("Checked the constraints."),
        ]))), [])
        XCTAssertEqual(try session.receive(.json(.object([
            "type": .string("response.reasoning_summary_part.done"),
            "output_index": .number(.integer(0)),
            "summary_index": .number(.integer(0)),
            "part": .object([
                "type": .string("summary_text"),
                "text": .string("Checked the constraints."),
            ]),
        ]))), [])
    }

    func testResponsesReasoningSummaryPartCannotSmuggleUnstreamedText() throws {
        var session = reasoningResponsesSession()
        _ = try session.receive(responseCreated())

        XCTAssertThrowsError(try session.receive(.json(.object([
            "type": .string("response.reasoning_summary_part.added"),
            "output_index": .number(.integer(0)),
            "summary_index": .number(.integer(0)),
            "part": .object([
                "type": .string("summary_text"),
                "text": .string("unaccounted output"),
            ]),
        ])))) { error in
            XCTAssertEqual(
                (error as? ProviderFailure)?.code,
                "provider_responses_reasoning_part_added_mismatch"
            )
        }
    }

    func testResponsesReasoningSummaryAndTextReconcileAsDistinctChannels() throws {
        var session = reasoningResponsesSession()
        let item: JSONValue = .object([
            "id": .string("reasoning-1"),
            "type": .string("reasoning"),
            "summary": .array([.object([
                "type": .string("summary_text"),
                "text": .string("Summary"),
            ])]),
            "content": .array([.object([
                "type": .string("reasoning_text"),
                "text": .string("Full reasoning"),
            ])]),
        ])
        let frames: [ProviderWireFrame] = [
            responseCreated(),
            .json(.object([
                "type": .string("response.reasoning_summary_text.delta"),
                "output_index": .number(.integer(0)),
                "summary_index": .number(.integer(0)),
                "delta": .string("Summary"),
            ])),
            .json(.object([
                "type": .string("response.content_part.added"),
                "output_index": .number(.integer(0)),
                "content_index": .number(.integer(0)),
                "part": .object([
                    "type": .string("reasoning_text"),
                    "text": .string(""),
                ]),
            ])),
            .json(.object([
                "type": .string("response.reasoning_text.delta"),
                "output_index": .number(.integer(0)),
                "content_index": .number(.integer(0)),
                "delta": .string("Full reasoning"),
            ])),
            .json(.object([
                "type": .string("response.reasoning_summary_text.done"),
                "output_index": .number(.integer(0)),
                "summary_index": .number(.integer(0)),
                "text": .string("Summary"),
            ])),
            .json(.object([
                "type": .string("response.reasoning_text.done"),
                "output_index": .number(.integer(0)),
                "content_index": .number(.integer(0)),
                "text": .string("Full reasoning"),
            ])),
            .json(.object([
                "type": .string("response.content_part.done"),
                "output_index": .number(.integer(0)),
                "content_index": .number(.integer(0)),
                "part": .object([
                    "type": .string("reasoning_text"),
                    "text": .string("Full reasoning"),
                ]),
            ])),
            .json(.object([
                "type": .string("response.output_item.done"),
                "output_index": .number(.integer(0)),
                "item": item,
            ])),
            responsesCompletion(output: [item]),
        ]

        var canonical: [ProviderStreamEvent] = []
        for frame in frames {
            canonical.append(contentsOf: try session.receive(frame).map(\.event))
        }

        XCTAssertEqual(canonical.compactMap { event -> String? in
            guard case let .reasoningDelta(delta) = event else { return nil }
            return delta.text
        }, ["Summary", "Full reasoning"])
        XCTAssertTrue(canonical.contains { event in
            guard case .responseCompleted = event else { return false }
            return true
        })
    }

    func testResponsesReasoningTextContentPartDoneMustMatchStream() throws {
        var session = reasoningResponsesSession()
        _ = try session.receive(responseCreated())
        _ = try session.receive(.json(.object([
            "type": .string("response.content_part.added"),
            "output_index": .number(.integer(0)),
            "content_index": .number(.integer(0)),
            "part": .object([
                "type": .string("reasoning_text"),
                "text": .string(""),
            ]),
        ])))
        _ = try session.receive(.json(.object([
            "type": .string("response.reasoning_text.delta"),
            "output_index": .number(.integer(0)),
            "content_index": .number(.integer(0)),
            "delta": .string("streamed reasoning"),
        ])))

        XCTAssertThrowsError(try session.receive(.json(.object([
            "type": .string("response.content_part.done"),
            "output_index": .number(.integer(0)),
            "content_index": .number(.integer(0)),
            "part": .object([
                "type": .string("reasoning_text"),
                "text": .string("different reasoning"),
            ]),
        ])))) { error in
            XCTAssertEqual(
                (error as? ProviderFailure)?.code,
                "provider_responses_reasoning_text_part_done_mismatch"
            )
        }
    }

    func testResponsesReasoningTextRejectsUnstreamedSnapshotContent() throws {
        var session = reasoningResponsesSession()
        _ = try session.receive(responseCreated())

        XCTAssertThrowsError(try session.receive(.json(.object([
            "type": .string("response.output_item.done"),
            "output_index": .number(.integer(0)),
            "item": .object([
                "id": .string("reasoning-1"),
                "type": .string("reasoning"),
                "summary": .array([]),
                "content": .array([.object([
                    "type": .string("reasoning_text"),
                    "text": .string("not streamed"),
                ])]),
            ]),
        ])))) { error in
            XCTAssertEqual(
                (error as? ProviderFailure)?.code,
                "provider_responses_reasoning_snapshot_mismatch"
            )
        }
    }

    func testResponsesReasoningTextRejectsStreamedContentMissingFromSnapshot() throws {
        var session = reasoningResponsesSession()
        _ = try session.receive(responseCreated())
        _ = try session.receive(.json(.object([
            "type": .string("response.reasoning_text.delta"),
            "output_index": .number(.integer(0)),
            "content_index": .number(.integer(0)),
            "delta": .string("streamed reasoning"),
        ])))
        _ = try session.receive(.json(.object([
            "type": .string("response.reasoning_text.done"),
            "output_index": .number(.integer(0)),
            "content_index": .number(.integer(0)),
            "text": .string("streamed reasoning"),
        ])))

        XCTAssertThrowsError(try session.receive(.json(.object([
            "type": .string("response.output_item.done"),
            "output_index": .number(.integer(0)),
            "item": .object([
                "id": .string("reasoning-1"),
                "type": .string("reasoning"),
                "summary": .array([]),
            ]),
        ])))) { error in
            XCTAssertEqual(
                (error as? ProviderFailure)?.code,
                "provider_responses_reasoning_snapshot_mismatch"
            )
        }
    }

    func testResponsesReasoningTerminalSnapshotRequiresSummaryArray() throws {
        var session = reasoningResponsesSession()
        _ = try session.receive(responseCreated())

        XCTAssertThrowsError(try session.receive(.json(.object([
            "type": .string("response.output_item.done"),
            "output_index": .number(.integer(0)),
            "item": .object([
                "id": .string("reasoning-1"),
                "type": .string("reasoning"),
                "content": .array([]),
            ]),
        ])))) { error in
            XCTAssertEqual(
                (error as? ProviderFailure)?.code,
                "provider_responses_reasoning_snapshot_invalid"
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

    private func responsesSession(
        maximumOutputTokens: UInt64? = nil
    ) -> ProviderStreamSession {
        let adapter = OpenAIResponsesAdapter(model: .init(rawValue: "fixture-model"))
        let request = textRequest(
            model: "fixture-model",
            maximumOutputTokens: maximumOutputTokens
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

    private func codexResponsesSession(
        maximumOutputTokens: UInt64 = 4_096
    ) -> ProviderStreamSession {
        let adapter = OpenAICodexResponsesAdapter(
            model: .init(rawValue: "fixture-model")
        )
        let request = textRequest(
            model: "fixture-model",
            maximumOutputTokens: maximumOutputTokens
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

    private func reasoningResponsesSession() -> ProviderStreamSession {
        let adapter = OpenAIResponsesAdapter(model: .init(rawValue: "fixture-model"))
        let request = CanonicalProviderRequest(
            requestID: "request-1",
            model: .init(rawValue: "fixture-model"),
            messages: [.init(role: .user, content: [.text("Reply")])],
            options: .init(reasoningSummary: true)
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

    private func zenReasoningChatSession() -> ProviderStreamSession {
        let model = "deepseek-v4-flash-free"
        let adapter = OpenCodeZenChatCompletionsAdapter(
            model: .init(rawValue: model),
            capabilities: .hostedOpenCodeZenChatSingleCallToolsBaseline
        )
        let request = textRequest(model: model)
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

    private func textRequest(
        model: String,
        maximumOutputTokens: UInt64? = nil
    ) -> CanonicalProviderRequest {
        CanonicalProviderRequest(
            requestID: "request-1",
            model: .init(rawValue: model),
            messages: [.init(role: .user, content: [.text("Reply")])],
            options: .init(maximumOutputTokens: maximumOutputTokens)
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
        responsesCompletion(
            output: output,
            inputTokens: nil,
            outputTokens: nil
        )
    }

    private func responsesCompletion(
        output: [JSONValue],
        inputTokens: UInt64?,
        outputTokens: UInt64?
    ) -> ProviderWireFrame {
        var response: [String: JSONValue] = [
            "id": .string("response-1"),
            "model": .string("fixture-model"),
            "status": .string("completed"),
            "output": .array(output),
        ]
        if let inputTokens, let outputTokens {
            response["usage"] = .object([
                "input_tokens": .number(.unsignedInteger(inputTokens)),
                "output_tokens": .number(.unsignedInteger(outputTokens)),
            ])
        }
        return .json(.object([
            "type": .string("response.completed"),
            "response": .object(response),
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
