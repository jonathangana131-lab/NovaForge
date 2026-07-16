import AgentDomain
import Foundation

/// Stateful translation of one provider wire attempt into canonical events.
/// Sessions are never reused across attempts.
struct ProviderStreamSession: Sendable {
    private static let maximumWireFrames = 16_384
    private static let maximumWireJSONNodes = 200_000
    private static let maximumWireUTF8Bytes = 16 * 1_024 * 1_024
    private static let maximumToolArgumentBytesPerCall = 1 * 1_024 * 1_024
    private static let maximumToolArgumentFragmentsPerCall = 4_096
    private static let maximumTotalToolArgumentBytes = 4 * 1_024 * 1_024
    private static let maximumTotalToolArgumentFragments = 16_384

    let descriptor: ProviderAdapterDescriptor
    let scope: ProviderAttemptScope

    private let request: CanonicalProviderRequest
    private var sequence: UInt64 = 0
    private var responseID: String?
    private var responseModel: ProviderModelID?
    private var wireClosed = false
    private var responseCompleted = false
    private var chatFinishReason: ModelFinishReason?
    private var usageReported = false
    private var responsesTextByPart: [ResponsesContentKey: String] = [:]
    private var responsesReasoningByPart: [ResponsesContentKey: String] = [:]
    private var completedResponsesTextParts: Set<ResponsesContentKey> = []
    private var completedResponsesReasoningParts: Set<ResponsesContentKey> = []
    private var toolCalls: [Int: PartialToolCall] = [:]
    private var toolOrder: [Int] = []
    private var wireFrameCount = 0
    private var wireJSONNodeCount = 0
    private var wireUTF8ByteCount = 0
    private var outputUTF8ByteCount = 0
    private var totalToolArgumentBytes = 0
    private var totalToolArgumentFragments = 0

    init(
        descriptor: ProviderAdapterDescriptor,
        scope: ProviderAttemptScope,
        request: CanonicalProviderRequest
    ) {
        self.descriptor = descriptor
        self.scope = scope
        self.request = request
    }

    mutating func receive(_ frame: ProviderWireFrame) throws -> [ProviderAttemptEvent] {
        switch frame {
        case let .json(value):
            guard !wireClosed, !responseCompleted else {
                throw ProviderFailureMapper.protocolViolation(
                    "provider_event_after_terminal",
                    descriptor: descriptor
                )
            }
            try recordWireJSON(value)
            if let failure = providerErrorFromEvent(value, descriptor: descriptor) {
                throw failure
            }
            let canonical: [ProviderStreamEvent]
            switch descriptor.dialect {
            case .openAIChatCompletions, .openAICompatibleChat:
                canonical = try receiveChat(value)
            case .openAIResponses:
                canonical = try receiveResponses(value)
            }
            return wrap(canonical)

        case .done:
            guard !wireClosed else {
                throw ProviderFailureMapper.protocolViolation(
                    "provider_duplicate_stream_end",
                    descriptor: descriptor
                )
            }
            try recordWireFrame()
            wireClosed = true
            return wrap(try finishWire())

        case let .cancelled(reason):
            guard !wireClosed, !responseCompleted else {
                throw ProviderFailureMapper.protocolViolation(
                    "provider_cancellation_after_terminal",
                    descriptor: descriptor
                )
            }
            try recordWireFrame(additionalUTF8Bytes: reason?.utf8.count ?? 0)
            wireClosed = true
            responseCompleted = true
            return wrap([
                .cancelled(ProviderCancellation(responseID: responseID, reason: reason)),
            ])
        }
    }

    /// Signals transport EOF when no explicit `.done` frame was received.
    mutating func finish() throws -> [ProviderAttemptEvent] {
        guard !wireClosed else { return [] }
        wireClosed = true
        return wrap(try finishWire())
    }

    private mutating func finishWire() throws -> [ProviderStreamEvent] {
        if responseCompleted { return [] }

        switch descriptor.dialect {
        case .openAIChatCompletions, .openAICompatibleChat:
            guard let responseID else {
                throw ProviderFailureMapper.malformed(
                    "provider_chat_missing_response",
                    descriptor: descriptor
                )
            }
            var events = try completePendingToolCalls()
            guard let reason = chatFinishReason else {
                throw ProviderFailureMapper.malformed(
                    "provider_chat_missing_finish_reason",
                    descriptor: descriptor
                )
            }
            try validateTerminal(reason: reason)
            try requireLocalUsageIfNeeded()
            events.append(.responseCompleted(.init(responseID: responseID, finishReason: reason)))
            responseCompleted = true
            return events

        case .openAIResponses:
            throw ProviderFailureMapper.malformed(
                "provider_responses_missing_completion",
                descriptor: descriptor
            )
        }
    }

    private mutating func receiveChat(_ value: JSONValue) throws -> [ProviderStreamEvent] {
        guard let object = value.providerObject else {
            throw ProviderFailureMapper.malformed("provider_chat_event_not_object", descriptor: descriptor)
        }
        if isStrictBuiltInRoute {
            try rejectUnknownFields(
                object,
                allowed: [
                    "id", "object", "created", "model", "choices", "usage",
                    "system_fingerprint", "service_tier",
                ],
                code: "provider_chat_event_field_unknown"
            )
        }

        var events: [ProviderStreamEvent] = []
        if responseID == nil {
            guard let id = object["id"]?.providerString, !id.isEmpty,
                  let model = object["model"]?.providerString, !model.isEmpty
            else {
                throw ProviderFailureMapper.malformed(
                    "provider_chat_start_metadata_missing",
                    descriptor: descriptor
                )
            }
            try validateResponseIdentity(id: id, model: model)
            responseID = id
            responseModel = ProviderModelID(rawValue: model)
            events.append(.responseStarted(.init(responseID: id, model: .init(rawValue: model))))
        } else {
            if let id = object["id"]?.providerString, id != responseID {
                throw ProviderFailureMapper.protocolViolation(
                    "provider_chat_response_id_changed",
                    descriptor: descriptor
                )
            }
            if let model = object["model"]?.providerString,
               ProviderModelID(rawValue: model) != responseModel {
                throw ProviderFailureMapper.protocolViolation(
                    "provider_chat_model_changed",
                    descriptor: descriptor
                )
            }
        }

        guard let choicesValue = object["choices"],
              let choices = choicesValue.providerArray
        else {
            throw ProviderFailureMapper.malformed("provider_chat_choices_missing", descriptor: descriptor)
        }
        guard choices.count <= 1 else {
            throw ProviderFailureMapper.protocolViolation(
                "provider_chat_multiple_choices_not_supported",
                descriptor: descriptor
            )
        }

        for choiceValue in choices {
            guard let choice = choiceValue.providerObject,
                  let outputIndex = choice["index"]?.providerInt,
                  outputIndex >= 0
            else {
                throw ProviderFailureMapper.malformed("provider_chat_choice_invalid", descriptor: descriptor)
            }
            guard outputIndex == 0 else {
                throw ProviderFailureMapper.protocolViolation(
                    "provider_chat_choice_index_not_supported",
                    descriptor: descriptor
                )
            }
            if isStrictBuiltInRoute {
                try rejectUnknownFields(
                    choice,
                    allowed: ["index", "delta", "finish_reason", "logprobs"],
                    code: "provider_chat_choice_field_unknown"
                )
            }
            if let logprobs = choice["logprobs"], !logprobs.isProviderNull {
                throw ProviderFailureMapper.protocolViolation(
                    "provider_chat_unrequested_logprobs",
                    descriptor: descriptor
                )
            }

            if let deltaValue = choice["delta"], !deltaValue.isProviderNull {
                guard let delta = deltaValue.providerObject else {
                    throw ProviderFailureMapper.malformed("provider_chat_delta_invalid", descriptor: descriptor)
                }
                if isStrictBuiltInRoute {
                    try rejectUnknownFields(
                        delta,
                        allowed: [
                            "role", "content", "refusal", "reasoning_content",
                            "reasoning", "tool_calls",
                        ],
                        code: "provider_chat_delta_field_unknown"
                    )
                }
                if let roleValue = delta["role"], !roleValue.isProviderNull {
                    guard roleValue.providerString == "assistant" else {
                        throw ProviderFailureMapper.protocolViolation(
                            "provider_chat_delta_role_invalid",
                            descriptor: descriptor
                        )
                    }
                }
                if let refusal = delta["refusal"], !refusal.isProviderNull {
                    throw ProviderFailureMapper.protocolViolation(
                        "provider_nontext_output_not_supported",
                        descriptor: descriptor
                    )
                }
                if let contentValue = delta["content"], !contentValue.isProviderNull {
                    guard let text = contentValue.providerString else {
                        throw ProviderFailureMapper.protocolViolation(
                            "provider_nontext_output_not_supported",
                            descriptor: descriptor
                        )
                    }
                    if !text.isEmpty {
                        try requireChatOutputOpen()
                        try requireOutputBeforeUsage()
                        try recordOutput(text)
                        events.append(.textDelta(.init(outputIndex: outputIndex, text: text)))
                    }
                }
                let reasoningContent = delta["reasoning_content"]
                let reasoningValue = delta["reasoning"]
                if let reasoningContent, !reasoningContent.isProviderNull,
                   reasoningContent.providerString == nil {
                    throw ProviderFailureMapper.protocolViolation(
                        "provider_nontext_output_not_supported",
                        descriptor: descriptor
                    )
                }
                if let reasoningValue, !reasoningValue.isProviderNull,
                   reasoningValue.providerString == nil {
                    throw ProviderFailureMapper.protocolViolation(
                        "provider_nontext_output_not_supported",
                        descriptor: descriptor
                    )
                }
                if let first = reasoningContent?.providerString,
                   let second = reasoningValue?.providerString,
                   first != second {
                    throw ProviderFailureMapper.protocolViolation(
                        "provider_reasoning_output_conflict",
                        descriptor: descriptor
                    )
                }
                let reasoning = reasoningContent?.providerString
                    ?? reasoningValue?.providerString
                if let reasoning, !reasoning.isEmpty {
                    try requireChatOutputOpen()
                    try requireOutputBeforeUsage()
                    try requireCapability(.reasoning, code: "provider_reasoning_output_not_supported")
                    try recordOutput(reasoning)
                    events.append(.reasoningDelta(.init(outputIndex: outputIndex, text: reasoning)))
                }
                if let callsValue = delta["tool_calls"], !callsValue.isProviderNull {
                    guard let calls = callsValue.providerArray else {
                        throw ProviderFailureMapper.malformed(
                            "provider_chat_tool_calls_invalid",
                            descriptor: descriptor
                        )
                    }
                    if !calls.isEmpty {
                        try requireChatOutputOpen()
                        try requireOutputBeforeUsage()
                    }
                    for call in calls {
                        events.append(contentsOf: try receiveChatToolDelta(call))
                    }
                }
            }

            if let rawFinish = choice["finish_reason"]?.providerString {
                let reason = Self.finishReason(rawFinish)
                if reason == .unknown || reason == .cancelled {
                    throw ProviderFailureMapper.protocolViolation(
                        isBuiltInLocalRoute
                            ? "provider_local_finish_reason_invalid"
                            : "provider_finish_reason_invalid",
                        descriptor: descriptor
                    )
                }
                if let previous = chatFinishReason, previous != reason {
                    throw ProviderFailureMapper.protocolViolation(
                        "provider_chat_finish_reason_changed",
                        descriptor: descriptor
                    )
                }
                chatFinishReason = reason
                if reason == .toolCalls {
                    events.append(contentsOf: try completePendingToolCalls())
                }
            }
        }
        if let usageValue = object["usage"], !usageValue.isProviderNull {
            try requireCompletedChatToolsBeforeUsage()
            events.append(.usage(try recordUsage(usageValue)))
        }
        return events
    }

    private mutating func receiveChatToolDelta(_ value: JSONValue) throws -> [ProviderStreamEvent] {
        guard let object = value.providerObject,
              let index = object["index"]?.providerInt,
              index >= 0
        else {
            throw ProviderFailureMapper.malformed("provider_chat_tool_delta_invalid", descriptor: descriptor)
        }

        let isNew = toolCalls[index] == nil
        if isNew { try validateNewToolCall(outputIndex: index) }
        var partial = toolCalls[index] ?? PartialToolCall(outputIndex: index)
        guard !partial.completed else {
            throw ProviderFailureMapper.protocolViolation(
                "provider_tool_event_after_completion",
                descriptor: descriptor
            )
        }

        if let id = object["id"]?.providerString, !id.isEmpty {
            try partial.setCallID(id, descriptor: descriptor)
        }
        if let functionValue = object["function"], !functionValue.isProviderNull {
            guard let function = functionValue.providerObject else {
                throw ProviderFailureMapper.malformed("provider_chat_tool_function_invalid", descriptor: descriptor)
            }
            if let name = function["name"]?.providerString, !name.isEmpty {
                try partial.setName(name, descriptor: descriptor)
            }
            if let fragment = function["arguments"]?.providerString, !fragment.isEmpty {
                try appendToolFragment(fragment, to: &partial)
            }
        }

        var events = try startAndFlush(&partial)
        if partial.started, let callID = partial.callID, !partial.pendingFragments.isEmpty {
            // `startAndFlush` normally consumes these. This branch is retained
            // for a fragment arriving after an already-started call.
            events.append(contentsOf: partial.pendingFragments.map {
                .toolCallArgumentsDelta(.init(outputIndex: index, callID: callID, fragment: $0))
            })
            partial.pendingFragments.removeAll(keepingCapacity: true)
        }
        try validateToolIdentityUniqueness(partial, excluding: index)
        try validateRequestedToolName(partial.name)
        if isNew { toolOrder.append(index) }
        toolCalls[index] = partial
        return events
    }

    private mutating func receiveResponses(_ value: JSONValue) throws -> [ProviderStreamEvent] {
        guard let object = value.providerObject,
              let type = object["type"]?.providerString
        else {
            throw ProviderFailureMapper.malformed("provider_responses_event_invalid", descriptor: descriptor)
        }
        if type != "response.created", type != "error" {
            try requireResponsesStarted()
        }

        switch type {
        case "response.created":
            guard let response = object["response"]?.providerObject else {
                throw ProviderFailureMapper.malformed("provider_responses_created_missing_response", descriptor: descriptor)
            }
            return try startResponse(from: response, permitExisting: false)

        case "response.in_progress", "response.queued":
            return []

        case "response.output_text.done":
            try requireOutputBeforeUsage()
            let key = try responsesContentKey(
                object,
                partIndexKeys: ["content_index"],
                code: "provider_responses_text_index_missing"
            )
            guard let text = object["text"]?.providerString else {
                throw ProviderFailureMapper.malformed(
                    "provider_responses_text_done_missing",
                    descriptor: descriptor
                )
            }
            guard responsesTextByPart[key, default: ""] == text else {
                throw ProviderFailureMapper.protocolViolation(
                    "provider_responses_text_done_mismatch",
                    descriptor: descriptor
                )
            }
            completedResponsesTextParts.insert(key)
            return []

        case "response.reasoning_summary_text.done":
            try requireOutputBeforeUsage()
            try requireCapability(.reasoning, code: "provider_reasoning_output_not_supported")
            let key = try responsesContentKey(
                object,
                partIndexKeys: ["summary_index", "content_index"],
                code: "provider_responses_reasoning_index_missing"
            )
            guard let text = object["text"]?.providerString else {
                throw ProviderFailureMapper.malformed(
                    "provider_responses_reasoning_done_missing",
                    descriptor: descriptor
                )
            }
            guard responsesReasoningByPart[key, default: ""] == text else {
                throw ProviderFailureMapper.protocolViolation(
                    "provider_responses_reasoning_done_mismatch",
                    descriptor: descriptor
                )
            }
            completedResponsesReasoningParts.insert(key)
            return []

        case "response.content_part.added", "response.content_part.done":
            if let part = object["part"]?.providerObject,
               let partType = part["type"]?.providerString,
               partType != "output_text" {
                throw ProviderFailureMapper.protocolViolation(
                    "provider_nontext_output_not_supported",
                    descriptor: descriptor
                )
            }
            return []

        case "response.output_text.delta":
            let key = try responsesContentKey(
                object,
                partIndexKeys: ["content_index"],
                code: "provider_responses_text_index_missing"
            )
            guard let delta = object["delta"]?.providerString else {
                throw ProviderFailureMapper.malformed("provider_responses_text_delta_missing", descriptor: descriptor)
            }
            try requireOutputBeforeUsage()
            if !delta.isEmpty {
                guard !completedResponsesTextParts.contains(key) else {
                    throw ProviderFailureMapper.protocolViolation(
                        "provider_responses_output_after_done",
                        descriptor: descriptor
                    )
                }
                try recordOutput(delta)
                responsesTextByPart[key, default: ""].append(delta)
            }
            return delta.isEmpty ? [] : [.textDelta(.init(outputIndex: key.outputIndex, text: delta))]

        case "response.reasoning_summary_text.delta", "response.reasoning_summary.delta",
             "response.reasoning_text.delta":
            let key = try responsesContentKey(
                object,
                partIndexKeys: ["summary_index", "content_index"],
                code: "provider_responses_reasoning_index_missing"
            )
            guard let delta = object["delta"]?.providerString else {
                throw ProviderFailureMapper.malformed(
                    "provider_responses_reasoning_delta_missing",
                    descriptor: descriptor
                )
            }
            try requireOutputBeforeUsage()
            try requireCapability(.reasoning, code: "provider_reasoning_output_not_supported")
            if !delta.isEmpty {
                guard !completedResponsesReasoningParts.contains(key) else {
                    throw ProviderFailureMapper.protocolViolation(
                        "provider_responses_output_after_done",
                        descriptor: descriptor
                    )
                }
                try recordOutput(delta)
                responsesReasoningByPart[key, default: ""].append(delta)
            }
            return delta.isEmpty ? [] : [.reasoningDelta(.init(outputIndex: key.outputIndex, text: delta))]

        case "response.output_item.added":
            guard let item = object["item"]?.providerObject else {
                throw ProviderFailureMapper.malformed("provider_responses_item_missing", descriptor: descriptor)
            }
            guard item["type"]?.providerString == "function_call" else {
                try validateResponsesNonToolItem(item)
                return []
            }
            let index = try requiredIndex(object, code: "provider_responses_tool_index_missing")
            return try receiveResponsesToolItem(item, outputIndex: index, complete: false)

        case "response.function_call_arguments.delta":
            let index = try requiredIndex(object, code: "provider_responses_tool_index_missing")
            guard let delta = object["delta"]?.providerString else {
                throw ProviderFailureMapper.malformed("provider_responses_tool_delta_missing", descriptor: descriptor)
            }
            return try receiveResponsesArgumentsDelta(
                outputIndex: index,
                itemID: object["item_id"]?.providerString,
                callID: object["call_id"]?.providerString,
                fragment: delta
            )

        case "response.function_call_arguments.done":
            let index = try requiredIndex(object, code: "provider_responses_tool_index_missing")
            guard let arguments = object["arguments"]?.providerString else {
                throw ProviderFailureMapper.malformed("provider_responses_tool_arguments_missing", descriptor: descriptor)
            }
            return try finishResponsesTool(
                outputIndex: index,
                itemID: object["item_id"]?.providerString,
                callID: object["call_id"]?.providerString,
                name: object["name"]?.providerString,
                arguments: arguments
            )

        case "response.output_item.done":
            guard let item = object["item"]?.providerObject else {
                throw ProviderFailureMapper.malformed(
                    "provider_responses_item_missing",
                    descriptor: descriptor
                )
            }
            guard item["type"]?.providerString == "function_call" else {
                let index = try requiredIndex(
                    object,
                    code: "provider_responses_item_index_missing"
                )
                try validateResponsesNonToolItem(
                    item,
                    reconcilingOutputIndex: index
                )
                return []
            }
            let index = try requiredIndex(object, code: "provider_responses_tool_index_missing")
            return try receiveResponsesToolItem(item, outputIndex: index, complete: true)

        case "response.completed", "response.incomplete":
            guard let response = object["response"]?.providerObject else {
                throw ProviderFailureMapper.malformed(
                    "provider_responses_completion_missing_response",
                    descriptor: descriptor
                )
            }
            return try completeResponses(response, incomplete: type == "response.incomplete")

        case "response.cancelled":
            if let response = object["response"]?.providerObject {
                try validateActiveResponseIdentity(response)
            }
            let id = object["response"]?.providerObject?["id"]?.providerString ?? responseID
            responseCompleted = true
            return [.cancelled(.init(responseID: id, reason: "provider_cancelled"))]

        case "response.failed":
            if let response = object["response"]?.providerObject,
               let error = response["error"]?.providerObject {
                try validateActiveResponseIdentity(response)
                throw mappedResponsesFailure(error)
            }
            throw ProviderFailureMapper.malformed("provider_responses_failure_missing_error", descriptor: descriptor)

        case "error":
            if let error = object["error"]?.providerObject {
                throw mappedResponsesFailure(error)
            }
            throw ProviderFailureMapper.malformed("provider_responses_error_missing_body", descriptor: descriptor)

        default:
            throw ProviderFailureMapper.malformed(
                "provider_responses_event_type_unknown",
                descriptor: descriptor
            )
        }
    }

    private mutating func startResponse(
        from response: [String: JSONValue],
        permitExisting: Bool
    ) throws -> [ProviderStreamEvent] {
        guard let id = response["id"]?.providerString, !id.isEmpty,
              let model = response["model"]?.providerString, !model.isEmpty
        else {
            throw ProviderFailureMapper.malformed("provider_responses_start_metadata_missing", descriptor: descriptor)
        }
        try validateResponseIdentity(id: id, model: model)
        if let responseID {
            guard responseID == id, responseModel == ProviderModelID(rawValue: model) else {
                throw ProviderFailureMapper.protocolViolation(
                    "provider_responses_identity_changed",
                    descriptor: descriptor
                )
            }
            guard permitExisting else {
                throw ProviderFailureMapper.protocolViolation(
                    "provider_responses_duplicate_start",
                    descriptor: descriptor
                )
            }
            return []
        }
        responseID = id
        responseModel = ProviderModelID(rawValue: model)
        return [.responseStarted(.init(responseID: id, model: .init(rawValue: model)))]
    }

    private mutating func completeResponses(
        _ response: [String: JSONValue],
        incomplete: Bool
    ) throws -> [ProviderStreamEvent] {
        var events = try startResponse(from: response, permitExisting: true)
        if let outputValue = response["output"], !outputValue.isProviderNull {
            guard let output = outputValue.providerArray else {
                throw ProviderFailureMapper.malformed(
                    "provider_responses_output_invalid",
                    descriptor: descriptor
                )
            }
            for (fallbackIndex, value) in output.enumerated() {
                guard let item = value.providerObject else {
                    throw ProviderFailureMapper.malformed(
                        "provider_responses_output_item_invalid",
                        descriptor: descriptor
                    )
                }
                let index: Int
                if let rawIndex = item["output_index"], !rawIndex.isProviderNull {
                    guard let explicitIndex = rawIndex.providerInt, explicitIndex >= 0 else {
                        throw ProviderFailureMapper.malformed(
                            "provider_responses_item_index_invalid",
                            descriptor: descriptor
                        )
                    }
                    index = explicitIndex
                } else {
                    index = fallbackIndex
                }
                if item["type"]?.providerString == "function_call" {
                    events.append(contentsOf: try receiveResponsesToolItem(
                        item,
                        outputIndex: index,
                        complete: true
                    ))
                } else {
                    try validateResponsesNonToolItem(
                        item,
                        reconcilingOutputIndex: index
                    )
                }
            }
        }
        events.append(contentsOf: try completePendingToolCalls())
        if let usageValue = response["usage"], !usageValue.isProviderNull {
            events.append(.usage(try recordUsage(usageValue)))
        }

        guard let id = responseID else {
            throw ProviderFailureMapper.protocolViolation("provider_responses_identity_missing", descriptor: descriptor)
        }
        let reason: ModelFinishReason
        if incomplete {
            let raw = response["incomplete_details"]?.providerObject?["reason"]?.providerString
            reason = Self.finishReason(raw ?? "length")
        } else if !toolCalls.isEmpty {
            reason = .toolCalls
        } else {
            let status = response["status"]?.providerString ?? "completed"
            reason = Self.finishReason(status)
        }
        try validateTerminal(reason: reason)
        try requireLocalUsageIfNeeded()
        events.append(.responseCompleted(.init(responseID: id, finishReason: reason)))
        responseCompleted = true
        return events
    }

    private mutating func receiveResponsesToolItem(
        _ item: [String: JSONValue],
        outputIndex: Int,
        complete: Bool
    ) throws -> [ProviderStreamEvent] {
        try requireOutputBeforeUsage()
        let isNew = toolCalls[outputIndex] == nil
        if isNew { try validateNewToolCall(outputIndex: outputIndex) }
        var partial = toolCalls[outputIndex] ?? PartialToolCall(outputIndex: outputIndex)
        if partial.completed {
            guard complete else {
                throw ProviderFailureMapper.protocolViolation(
                    "provider_tool_event_after_completion",
                    descriptor: descriptor
                )
            }
            try validateCompletedToolReplay(item, partial: partial)
            return []
        }
        if let itemID = item["id"]?.providerString, !itemID.isEmpty {
            try partial.setItemID(itemID, descriptor: descriptor)
        }
        if let callID = item["call_id"]?.providerString, !callID.isEmpty {
            try partial.setCallID(callID, descriptor: descriptor)
        }
        if let name = item["name"]?.providerString, !name.isEmpty {
            try partial.setName(name, descriptor: descriptor)
        }
        try validateToolIdentityUniqueness(partial, excluding: outputIndex)
        try validateRequestedToolName(partial.name)
        var events = try startAndFlush(&partial)
        if complete, let arguments = item["arguments"]?.providerString {
            try setOrValidateFinalArguments(arguments, for: &partial)
            if isNew { toolOrder.append(outputIndex) }
            toolCalls[outputIndex] = partial
            events.append(contentsOf: try completeTool(at: outputIndex))
            return events
        }
        if isNew { toolOrder.append(outputIndex) }
        toolCalls[outputIndex] = partial
        return events
    }

    private mutating func receiveResponsesArgumentsDelta(
        outputIndex: Int,
        itemID: String?,
        callID: String?,
        fragment: String
    ) throws -> [ProviderStreamEvent] {
        try requireOutputBeforeUsage()
        try requireToolCapabilities()
        guard var partial = toolCalls[outputIndex] else {
            throw ProviderFailureMapper.malformed("provider_responses_tool_delta_before_start", descriptor: descriptor)
        }
        guard !partial.completed else {
            throw ProviderFailureMapper.protocolViolation(
                "provider_tool_event_after_completion",
                descriptor: descriptor
            )
        }
        if let itemID, !itemID.isEmpty { try partial.setItemID(itemID, descriptor: descriptor) }
        if let callID, !callID.isEmpty { try partial.setCallID(callID, descriptor: descriptor) }
        try validateToolIdentityUniqueness(partial, excluding: outputIndex)
        try validateRequestedToolName(partial.name)
        if !fragment.isEmpty { try appendToolFragment(fragment, to: &partial) }
        let events = try startAndFlush(&partial)
        toolCalls[outputIndex] = partial
        return events
    }

    private mutating func finishResponsesTool(
        outputIndex: Int,
        itemID: String?,
        callID: String?,
        name: String?,
        arguments: String
    ) throws -> [ProviderStreamEvent] {
        try requireOutputBeforeUsage()
        try requireToolCapabilities()
        guard var partial = toolCalls[outputIndex] else {
            throw ProviderFailureMapper.malformed("provider_responses_tool_done_before_start", descriptor: descriptor)
        }
        guard !partial.completed else {
            throw ProviderFailureMapper.protocolViolation(
                "provider_tool_event_after_completion",
                descriptor: descriptor
            )
        }
        if let itemID, !itemID.isEmpty { try partial.setItemID(itemID, descriptor: descriptor) }
        if let callID, !callID.isEmpty { try partial.setCallID(callID, descriptor: descriptor) }
        if let name, !name.isEmpty { try partial.setName(name, descriptor: descriptor) }
        try validateToolIdentityUniqueness(partial, excluding: outputIndex)
        try validateRequestedToolName(partial.name)
        var events = try startAndFlush(&partial)
        try setOrValidateFinalArguments(arguments, for: &partial)
        toolCalls[outputIndex] = partial
        events.append(contentsOf: try completeTool(at: outputIndex))
        return events
    }

    private mutating func appendToolFragment(
        _ fragment: String,
        to partial: inout PartialToolCall
    ) throws {
        let byteCount = fragment.utf8.count
        let callBytes = partial.argumentUTF8Bytes.addingReportingOverflow(byteCount)
        let callFragments = partial.argumentFragmentCount.addingReportingOverflow(1)
        let totalBytes = totalToolArgumentBytes.addingReportingOverflow(byteCount)
        let totalFragments = totalToolArgumentFragments.addingReportingOverflow(1)
        guard !callBytes.overflow, !callFragments.overflow,
              !totalBytes.overflow, !totalFragments.overflow,
              callBytes.partialValue <= Self.maximumToolArgumentBytesPerCall,
              callFragments.partialValue <= Self.maximumToolArgumentFragmentsPerCall,
              totalBytes.partialValue <= Self.maximumTotalToolArgumentBytes,
              totalFragments.partialValue <= Self.maximumTotalToolArgumentFragments
        else {
            throw ProviderFailureMapper.protocolViolation(
                "provider_tool_arguments_budget_exceeded",
                descriptor: descriptor
            )
        }
        try recordOutput(fragment)
        partial.arguments.append(fragment)
        partial.pendingFragments.append(fragment)
        partial.argumentUTF8Bytes = callBytes.partialValue
        partial.argumentFragmentCount = callFragments.partialValue
        totalToolArgumentBytes = totalBytes.partialValue
        totalToolArgumentFragments = totalFragments.partialValue
    }

    private mutating func setOrValidateFinalArguments(
        _ arguments: String,
        for partial: inout PartialToolCall
    ) throws {
        if partial.argumentFragmentCount > 0 || !partial.arguments.isEmpty {
            guard partial.arguments == arguments else {
                throw ProviderFailureMapper.protocolViolation(
                    "provider_tool_arguments_done_mismatch",
                    descriptor: descriptor
                )
            }
            return
        }
        try appendToolFragment(arguments, to: &partial)
        // A full `arguments.done` snapshot is not a streamed delta. Preserve
        // it for exact replay validation without inventing a canonical delta.
        partial.pendingFragments.removeAll(keepingCapacity: false)
    }

    private func validateCompletedToolReplay(
        _ item: [String: JSONValue],
        partial: PartialToolCall
    ) throws {
        guard item["id"]?.providerString == partial.itemID,
              item["call_id"]?.providerString == partial.callID,
              item["name"]?.providerString == partial.name,
              item["arguments"]?.providerString == partial.arguments
        else {
            throw ProviderFailureMapper.protocolViolation(
                "provider_tool_completion_replay_mismatch",
                descriptor: descriptor
            )
        }
    }

    private mutating func startAndFlush(_ partial: inout PartialToolCall) throws -> [ProviderStreamEvent] {
        guard let callID = partial.callID, let name = partial.name else { return [] }
        var events: [ProviderStreamEvent] = []
        if !partial.started {
            partial.started = true
            events.append(.toolCallStarted(.init(
                outputIndex: partial.outputIndex,
                itemID: partial.itemID,
                callID: callID,
                name: name
            )))
        }
        if !partial.pendingFragments.isEmpty {
            events.append(contentsOf: partial.pendingFragments.map {
                .toolCallArgumentsDelta(.init(
                    outputIndex: partial.outputIndex,
                    callID: callID,
                    fragment: $0
                ))
            })
            partial.pendingFragments.removeAll(keepingCapacity: true)
        }
        return events
    }

    private mutating func completePendingToolCalls() throws -> [ProviderStreamEvent] {
        var events: [ProviderStreamEvent] = []
        for index in toolOrder where toolCalls[index]?.completed == false {
            events.append(contentsOf: try completeTool(at: index))
        }
        return events
    }

    private mutating func completeTool(at index: Int) throws -> [ProviderStreamEvent] {
        guard var partial = toolCalls[index] else { return [] }
        if partial.completed { return [] }
        var events = try startAndFlush(&partial)
        guard partial.started, let callID = partial.callID, let name = partial.name else {
            throw ProviderFailureMapper.malformed("provider_tool_identity_incomplete", descriptor: descriptor)
        }
        let arguments = try decodeToolArguments(partial.arguments, descriptor: descriptor)
        try validateToolArguments(arguments, name: name)
        partial.completed = true
        toolCalls[index] = partial
        events.append(.toolCallCompleted(.init(
            outputIndex: partial.outputIndex,
            itemID: partial.itemID,
            callID: callID,
            name: name,
            arguments: arguments
        )))
        return events
    }

    private mutating func recordUsage(_ value: JSONValue) throws -> ProviderUsage {
        guard !usageReported else {
            throw ProviderFailureMapper.protocolViolation(
                "provider_usage_reported_more_than_once",
                descriptor: descriptor
            )
        }
        let usage = try parseUsage(value)
        guard usage.cachedInputTokens <= usage.inputTokens,
              usage.reasoningTokens <= usage.outputTokens,
              usage.outputTokens <= descriptor.route.capabilities.maximumOutputTokens
        else {
            throw ProviderFailureMapper.protocolViolation(
                "provider_usage_counts_invalid",
                descriptor: descriptor
            )
        }
        let total = usage.inputTokens.addingReportingOverflow(usage.outputTokens)
        guard !total.overflow,
              total.partialValue <= descriptor.route.capabilities.contextWindowTokens
        else {
            throw ProviderFailureMapper.protocolViolation(
                "provider_usage_context_limit_exceeded",
                descriptor: descriptor
            )
        }
        if let requestedMaximum = request.options.maximumOutputTokens,
           usage.outputTokens > requestedMaximum {
            throw ProviderFailureMapper.protocolViolation(
                "provider_usage_request_output_limit_exceeded",
                descriptor: descriptor
            )
        }
        usageReported = true
        return usage
    }

    private func parseUsage(_ value: JSONValue) throws -> ProviderUsage {
        guard let usage = value.providerObject else {
            throw ProviderFailureMapper.malformed("provider_usage_invalid", descriptor: descriptor)
        }
        let input = usage["input_tokens"]?.providerUInt64
            ?? usage["prompt_tokens"]?.providerUInt64
        let output = usage["output_tokens"]?.providerUInt64
            ?? usage["completion_tokens"]?.providerUInt64
        guard let input, let output else {
            throw ProviderFailureMapper.malformed("provider_usage_counts_missing", descriptor: descriptor)
        }
        let inputDetails = usage["input_tokens_details"]?.providerObject
            ?? usage["prompt_tokens_details"]?.providerObject
        let outputDetails = usage["output_tokens_details"]?.providerObject
            ?? usage["completion_tokens_details"]?.providerObject
        return ProviderUsage(
            inputTokens: input,
            cachedInputTokens: inputDetails?["cached_tokens"]?.providerUInt64 ?? 0,
            outputTokens: output,
            reasoningTokens: outputDetails?["reasoning_tokens"]?.providerUInt64 ?? 0
        )
    }

    private var isBuiltInLocalRoute: Bool {
        descriptor.route.deployment == .onDevice &&
            descriptor.route.provenance == .builtInLocalModel
    }

    private var isStrictBuiltInRoute: Bool {
        descriptor.route.provenance != .callerConfigured
    }

    private func rejectUnknownFields(
        _ object: [String: JSONValue],
        allowed: Set<String>,
        code: String
    ) throws {
        guard object.keys.allSatisfy(allowed.contains) else {
            throw ProviderFailureMapper.protocolViolation(
                code,
                descriptor: descriptor
            )
        }
    }

    private func validateResponseIdentity(id: String, model: String) throws {
        guard !isBuiltInLocalRoute ||
                (Self.isSafeWireIdentity(id, maximumUTF8Count: 512) &&
                    Self.isSafeWireIdentity(model, maximumUTF8Count: 256) &&
                    ProviderModelID(rawValue: model) == descriptor.route.modelID)
        else {
            throw ProviderFailureMapper.protocolViolation(
                "provider_local_response_identity_invalid",
                descriptor: descriptor
            )
        }
    }

    private func requireResponsesStarted() throws {
        guard responseID != nil else {
            throw ProviderFailureMapper.protocolViolation(
                "provider_responses_event_before_start",
                descriptor: descriptor
            )
        }
    }

    private func validateActiveResponseIdentity(
        _ response: [String: JSONValue]
    ) throws {
        if let id = response["id"]?.providerString, id != responseID {
            throw ProviderFailureMapper.protocolViolation(
                "provider_responses_identity_changed",
                descriptor: descriptor
            )
        }
        if let model = response["model"]?.providerString,
           ProviderModelID(rawValue: model) != responseModel {
            throw ProviderFailureMapper.protocolViolation(
                "provider_responses_identity_changed",
                descriptor: descriptor
            )
        }
    }

    private func validateResponsesNonToolItem(
        _ item: [String: JSONValue],
        reconcilingOutputIndex outputIndex: Int? = nil
    ) throws {
        guard let type = item["type"]?.providerString else {
            throw ProviderFailureMapper.malformed(
                "provider_responses_item_type_missing",
                descriptor: descriptor
            )
        }
        switch type {
        case "message":
            if let role = item["role"]?.providerString, role != "assistant" {
                throw ProviderFailureMapper.protocolViolation(
                    "provider_responses_message_role_invalid",
                    descriptor: descriptor
                )
            }
            guard let content = item["content"]?.providerArray else {
                if outputIndex == nil { return }
                throw ProviderFailureMapper.malformed(
                    "provider_responses_message_content_missing",
                    descriptor: descriptor
                )
            }
            var representedParts: Set<ResponsesContentKey> = []
            for (contentIndex, partValue) in content.enumerated() {
                guard let part = partValue.providerObject,
                      part["type"]?.providerString == "output_text"
                else {
                    throw ProviderFailureMapper.protocolViolation(
                        "provider_nontext_output_not_supported",
                        descriptor: descriptor
                    )
                }
                guard let text = part["text"]?.providerString else {
                    if outputIndex == nil { continue }
                    throw ProviderFailureMapper.malformed(
                        "provider_responses_message_text_missing",
                        descriptor: descriptor
                    )
                }
                if let outputIndex {
                    let key = ResponsesContentKey(
                        outputIndex: outputIndex,
                        partIndex: contentIndex
                    )
                    representedParts.insert(key)
                    guard responsesTextByPart[key, default: ""] == text else {
                        throw ProviderFailureMapper.protocolViolation(
                            "provider_responses_text_snapshot_mismatch",
                            descriptor: descriptor
                        )
                    }
                }
            }
            if let outputIndex {
                let hasUnrepresentedText = responsesTextByPart.contains { key, text in
                    key.outputIndex == outputIndex &&
                        !text.isEmpty &&
                        !representedParts.contains(key)
                }
                guard !hasUnrepresentedText else {
                    throw ProviderFailureMapper.protocolViolation(
                        "provider_responses_text_snapshot_mismatch",
                        descriptor: descriptor
                    )
                }
            }

        case "reasoning":
            try requireCapability(
                .reasoning,
                code: "provider_reasoning_output_not_supported"
            )
            guard let outputIndex else { return }
            let summary = item["summary"]?.providerArray ?? []
            var representedParts: Set<ResponsesContentKey> = []
            for (summaryIndex, partValue) in summary.enumerated() {
                guard let part = partValue.providerObject,
                      part["type"]?.providerString == "summary_text",
                      let text = part["text"]?.providerString
                else {
                    throw ProviderFailureMapper.protocolViolation(
                        "provider_responses_reasoning_snapshot_invalid",
                        descriptor: descriptor
                    )
                }
                let key = ResponsesContentKey(
                    outputIndex: outputIndex,
                    partIndex: summaryIndex
                )
                representedParts.insert(key)
                guard responsesReasoningByPart[key, default: ""] == text else {
                    throw ProviderFailureMapper.protocolViolation(
                        "provider_responses_reasoning_snapshot_mismatch",
                        descriptor: descriptor
                    )
                }
            }
            let hasUnrepresentedReasoning = responsesReasoningByPart.contains { key, text in
                key.outputIndex == outputIndex &&
                    !text.isEmpty &&
                    !representedParts.contains(key)
            }
            guard !hasUnrepresentedReasoning else {
                throw ProviderFailureMapper.protocolViolation(
                    "provider_responses_reasoning_snapshot_mismatch",
                    descriptor: descriptor
                )
            }

        default:
            throw ProviderFailureMapper.protocolViolation(
                "provider_responses_output_item_not_supported",
                descriptor: descriptor
            )
        }
    }

    private func responsesContentKey(
        _ object: [String: JSONValue],
        partIndexKeys: [String],
        code: String
    ) throws -> ResponsesContentKey {
        let outputIndex = try requiredIndex(object, code: code)
        var partIndex = 0
        for name in partIndexKeys {
            guard let raw = object[name], !raw.isProviderNull else { continue }
            guard let value = raw.providerInt, value >= 0 else {
                throw ProviderFailureMapper.malformed(code, descriptor: descriptor)
            }
            partIndex = value
            break
        }
        return ResponsesContentKey(
            outputIndex: outputIndex,
            partIndex: partIndex
        )
    }

    private func requireChatOutputOpen() throws {
        guard chatFinishReason == nil else {
            throw ProviderFailureMapper.protocolViolation(
                "provider_chat_output_after_finish",
                descriptor: descriptor
            )
        }
    }

    private func requireCompletedChatToolsBeforeUsage() throws {
        guard toolCalls.values.allSatisfy(\.completed) else {
            throw ProviderFailureMapper.protocolViolation(
                "provider_chat_usage_before_tool_completion",
                descriptor: descriptor
            )
        }
    }

    private func requireOutputBeforeUsage() throws {
        guard !usageReported else {
            throw ProviderFailureMapper.protocolViolation(
                "provider_output_after_usage",
                descriptor: descriptor
            )
        }
    }

    private mutating func recordWireFrame(
        additionalUTF8Bytes: Int = 0
    ) throws {
        let nextFrames = wireFrameCount.addingReportingOverflow(1)
        let nextBytes = wireUTF8ByteCount.addingReportingOverflow(additionalUTF8Bytes)
        guard !nextFrames.overflow, !nextBytes.overflow,
              nextFrames.partialValue <= Self.maximumWireFrames,
              nextBytes.partialValue <= Self.maximumWireUTF8Bytes
        else {
            throw ProviderFailureMapper.protocolViolation(
                "provider_stream_budget_exceeded",
                descriptor: descriptor
            )
        }
        wireFrameCount = nextFrames.partialValue
        wireUTF8ByteCount = nextBytes.partialValue
    }

    private mutating func recordWireJSON(_ value: JSONValue) throws {
        try recordWireFrame()
        var nodes = 0
        var bytes = 0
        guard Self.measureWireJSON(
            value,
            depth: 0,
            nodes: &nodes,
            bytes: &bytes
        ) else {
            throw ProviderFailureMapper.protocolViolation(
                "provider_stream_budget_exceeded",
                descriptor: descriptor
            )
        }
        let nextNodes = wireJSONNodeCount.addingReportingOverflow(nodes)
        let nextBytes = wireUTF8ByteCount.addingReportingOverflow(bytes)
        guard !nextNodes.overflow, !nextBytes.overflow,
              nextNodes.partialValue <= Self.maximumWireJSONNodes,
              nextBytes.partialValue <= Self.maximumWireUTF8Bytes
        else {
            throw ProviderFailureMapper.protocolViolation(
                "provider_stream_budget_exceeded",
                descriptor: descriptor
            )
        }
        wireJSONNodeCount = nextNodes.partialValue
        wireUTF8ByteCount = nextBytes.partialValue
    }

    private mutating func recordOutput(_ value: String) throws {
        let next = outputUTF8ByteCount.addingReportingOverflow(value.utf8.count)
        guard !next.overflow, next.partialValue <= maximumOutputUTF8Bytes else {
            throw ProviderFailureMapper.protocolViolation(
                "provider_output_budget_exceeded",
                descriptor: descriptor
            )
        }
        outputUTF8ByteCount = next.partialValue
    }

    private var maximumOutputUTF8Bytes: Int {
        let routeLimit = descriptor.route.capabilities.maximumOutputTokens
        let tokenLimit = min(request.options.maximumOutputTokens ?? routeLimit, routeLimit)
        let multiplied = tokenLimit.multipliedReportingOverflow(by: 64)
        let proposed = multiplied.overflow ? UInt64.max : multiplied.partialValue
        return Int(min(UInt64(8 * 1_024 * 1_024), max(UInt64(64 * 1_024), proposed)))
    }

    private static func measureWireJSON(
        _ value: JSONValue,
        depth: Int,
        nodes: inout Int,
        bytes: inout Int
    ) -> Bool {
        guard depth <= 64 else { return false }
        nodes += 1
        guard nodes <= maximumWireJSONNodes else { return false }
        switch value {
        case .null:
            bytes += 4
        case .bool:
            bytes += 5
        case .number:
            bytes += 32
        case let .string(string):
            bytes += string.utf8.count
        case let .array(values):
            for child in values {
                guard measureWireJSON(
                    child,
                    depth: depth + 1,
                    nodes: &nodes,
                    bytes: &bytes
                ) else { return false }
            }
        case let .object(object):
            for (key, child) in object {
                bytes += key.utf8.count
                guard measureWireJSON(
                    child,
                    depth: depth + 1,
                    nodes: &nodes,
                    bytes: &bytes
                ) else { return false }
            }
        }
        return bytes <= maximumWireUTF8Bytes
    }

    private func requireCapability(
        _ capability: ProviderCapability,
        code: String
    ) throws {
        guard descriptor.route.capabilities.features.contains(capability) else {
            throw ProviderFailureMapper.protocolViolation(code, descriptor: descriptor)
        }
    }

    private func requireToolCapabilities() throws {
        for capability in [
            ProviderCapability.tools,
            .typedToolArguments,
        ] {
            try requireCapability(
                capability,
                code: "provider_tool_output_not_supported"
            )
        }
    }

    private func validateNewToolCall(outputIndex: Int) throws {
        try requireOutputBeforeUsage()
        try requireToolCapabilities()
        let capabilities = descriptor.route.capabilities
        guard capabilities.maximumToolCallsPerTurn > 0,
              toolCalls.count < Int(capabilities.maximumToolCallsPerTurn)
        else {
            throw ProviderFailureMapper.protocolViolation(
                "provider_tool_output_limit_exceeded",
                descriptor: descriptor
            )
        }
        guard toolCalls.isEmpty ||
                (request.options.parallelToolCalls == true &&
                    capabilities.features.contains(.parallelToolCalls))
        else {
            throw ProviderFailureMapper.protocolViolation(
                "provider_parallel_tool_output_not_supported",
                descriptor: descriptor
            )
        }
        guard outputIndex >= 0 else {
            throw ProviderFailureMapper.malformed(
                "provider_tool_output_index_invalid",
                descriptor: descriptor
            )
        }
    }

    private func validateToolIdentityUniqueness(
        _ candidate: PartialToolCall,
        excluding outputIndex: Int
    ) throws {
        for (index, existing) in toolCalls where index != outputIndex {
            if let callID = candidate.callID, existing.callID == callID {
                throw ProviderFailureMapper.protocolViolation(
                    "provider_tool_call_id_reused",
                    descriptor: descriptor
                )
            }
            if let itemID = candidate.itemID, existing.itemID == itemID {
                throw ProviderFailureMapper.protocolViolation(
                    "provider_tool_item_id_reused",
                    descriptor: descriptor
                )
            }
        }
    }

    private func validateRequestedToolName(_ name: String?) throws {
        guard let name else { return }
        guard request.tools.contains(where: { $0.name == name }) else {
            throw ProviderFailureMapper.protocolViolation(
                "provider_tool_name_not_requested",
                descriptor: descriptor
            )
        }
        switch request.options.toolChoice {
        case .auto, .required:
            break
        case .none:
            throw ProviderFailureMapper.protocolViolation(
                "provider_tool_output_forbidden",
                descriptor: descriptor
            )
        case let .named(expected) where expected == name:
            break
        case .named:
            throw ProviderFailureMapper.protocolViolation(
                "provider_tool_choice_mismatch",
                descriptor: descriptor
            )
        }
    }

    private func validateToolArguments(_ arguments: JSONValue, name: String) throws {
        guard let definition = request.tools.first(where: { $0.name == name }) else {
            throw ProviderFailureMapper.protocolViolation(
                "provider_tool_name_not_requested",
                descriptor: descriptor
            )
        }
        do {
            try ProviderJSONSchemaValidator.validate(
                arguments,
                against: definition.parameters
            )
        } catch {
            throw ProviderFailureMapper.protocolViolation(
                "provider_tool_arguments_schema_mismatch",
                descriptor: descriptor
            )
        }
    }

    private func validateTerminal(reason: ModelFinishReason) throws {
        let hasToolCalls = !toolCalls.isEmpty
        guard reason != .cancelled, reason != .unknown,
              (reason == .toolCalls) == hasToolCalls
        else {
            throw ProviderFailureMapper.protocolViolation(
                "provider_finish_reason_output_mismatch",
                descriptor: descriptor
            )
        }
        switch request.options.toolChoice {
        case .required where !hasToolCalls:
            throw ProviderFailureMapper.protocolViolation(
                "provider_required_tool_call_missing",
                descriptor: descriptor
            )
        case .named where !hasToolCalls:
            throw ProviderFailureMapper.protocolViolation(
                "provider_required_tool_call_missing",
                descriptor: descriptor
            )
        case .none where hasToolCalls:
            throw ProviderFailureMapper.protocolViolation(
                "provider_tool_output_forbidden",
                descriptor: descriptor
            )
        default:
            break
        }
    }

    private func requireLocalUsageIfNeeded() throws {
        guard !isBuiltInLocalRoute || usageReported else {
            throw ProviderFailureMapper.protocolViolation(
                "provider_local_usage_missing",
                descriptor: descriptor
            )
        }
    }

    private func requiredIndex(_ object: [String: JSONValue], code: String) throws -> Int {
        guard let index = object["output_index"]?.providerInt, index >= 0 else {
            throw ProviderFailureMapper.malformed(code, descriptor: descriptor)
        }
        return index
    }

    private func mappedResponsesFailure(_ error: [String: JSONValue]) -> ProviderFailure {
        ProviderFailureMapper.httpFailure(
            statusCode: error["status"]?.providerInt ?? 500,
            providerCode: error["code"]?.providerString,
            providerID: descriptor.route.providerID,
            adapterID: descriptor.route.adapterID
        )
    }

    private mutating func wrap(_ events: [ProviderStreamEvent]) -> [ProviderAttemptEvent] {
        events.map { event in
            defer { sequence &+= 1 }
            return ProviderAttemptEvent(scope: scope, sequence: sequence, event: event)
        }
    }

    private static func finishReason(_ raw: String) -> ModelFinishReason {
        switch raw {
        case "stop", "completed": .completed
        case "tool_calls", "function_call": .toolCalls
        case "length", "max_output_tokens": .length
        case "content_filter", "content_filtered": .contentFilter
        case "cancelled", "canceled": .cancelled
        default: .unknown
        }
    }

    private static func isSafeWireIdentity(
        _ value: String,
        maximumUTF8Count: Int
    ) -> Bool {
        guard !value.isEmpty, value.utf8.count <= maximumUTF8Count,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar) &&
                !CharacterSet.controlCharacters.contains(scalar) &&
                scalar.properties.generalCategory != .format
        }
    }
}

private struct ResponsesContentKey: Hashable, Sendable {
    let outputIndex: Int
    let partIndex: Int
}

private struct PartialToolCall: Sendable {
    let outputIndex: Int
    var itemID: String?
    var callID: String?
    var name: String?
    var arguments = ""
    var pendingFragments: [String] = []
    var argumentUTF8Bytes = 0
    var argumentFragmentCount = 0
    var started = false
    var completed = false

    mutating func setItemID(_ value: String, descriptor: ProviderAdapterDescriptor) throws {
        if let itemID, itemID != value {
            throw ProviderFailureMapper.protocolViolation("provider_tool_item_id_changed", descriptor: descriptor)
        }
        itemID = value
    }

    mutating func setCallID(_ value: String, descriptor: ProviderAdapterDescriptor) throws {
        if let callID, callID != value {
            throw ProviderFailureMapper.protocolViolation("provider_tool_call_id_changed", descriptor: descriptor)
        }
        callID = value
    }

    mutating func setName(_ value: String, descriptor: ProviderAdapterDescriptor) throws {
        if let name, name != value {
            throw ProviderFailureMapper.protocolViolation("provider_tool_name_changed", descriptor: descriptor)
        }
        name = value
    }
}
