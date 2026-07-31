import AgentDomain
import Foundation

public enum LocalModelWireSessionError: Error, Equatable, Sendable {
    case invalidResponseID
    case invalidModelID
    case invalidRequestedOutputLimit
    case routeIsNotBuiltInOnDevice
    case eventBeforeStart
    case duplicateStart
    case eventAfterTerminal
    case negativeOutputIndex
    case toolModeDisabled
    case parallelToolCallsDisabled
    case toolLimitExceeded(UInt32)
    case invalidToolIdentity
    case toolArgumentsNotObject
    case duplicateToolOutputIndex(Int)
    case duplicateToolCallID(String)
    case invalidUsage
    case duplicateUsage
    case missingUsage
    case outputAfterUsage
    case finishReasonMismatch
}

public enum LocalModelCancellationReason: String, Codable, Equatable, Sendable {
    case userRequested
    case deadlineReached
    case appBackgrounded
    case memoryPressure
    case thermalPressure
    case runtimeStopped
}

/// State-checked bridge from an on-device inference backend to the ordinary
/// chat-completions wire stream consumed by `ModelGateway`. Keeping this bridge
/// in AgentProviders prevents the app from inventing a second, local-only
/// attempt protocol or bypassing provisional/commit semantics.
public struct LocalModelWireSession: Sendable {
    public let responseID: String
    public let modelID: ProviderModelID

    private let capabilities: ProviderModelCapabilities
    private let maximumOutputTokens: UInt64
    private var started = false
    private var terminal = false
    private var usageReported = false
    private var toolOutputIndexes: Set<Int> = []
    private var toolCallIDs: Set<String> = []

    public init(
        responseID: String,
        descriptor: ProviderAdapterDescriptor,
        requestedMaximumOutputTokens: UInt64? = nil
    ) throws {
        guard Self.isSafeIdentity(responseID, maximumUTF8Count: 512) else {
            throw LocalModelWireSessionError.invalidResponseID
        }
        guard descriptor.route.deployment == .onDevice,
              descriptor.route.provenance == .builtInLocalModel
        else { throw LocalModelWireSessionError.routeIsNotBuiltInOnDevice }
        let modelID = descriptor.route.modelID
        guard Self.isSafeIdentity(modelID.rawValue, maximumUTF8Count: 256) else {
            throw LocalModelWireSessionError.invalidModelID
        }
        self.responseID = responseID
        self.modelID = modelID
        capabilities = descriptor.route.capabilities
        if let requestedMaximumOutputTokens {
            guard requestedMaximumOutputTokens > 0,
                  requestedMaximumOutputTokens <= capabilities.maximumOutputTokens
            else { throw LocalModelWireSessionError.invalidRequestedOutputLimit }
            maximumOutputTokens = requestedMaximumOutputTokens
        } else {
            maximumOutputTokens = capabilities.maximumOutputTokens
        }
    }

    public mutating func begin() throws -> ProviderWireFrame {
        guard !terminal else { throw LocalModelWireSessionError.eventAfterTerminal }
        guard !started else { throw LocalModelWireSessionError.duplicateStart }
        started = true
        return chatFrame(choices: [])
    }

    public mutating func text(
        _ text: String,
        outputIndex: Int = 0
    ) throws -> ProviderWireFrame? {
        try requireOutputOpen(outputIndex: outputIndex)
        guard !text.isEmpty else { return nil }
        return chatFrame(choices: [choice(
            outputIndex: outputIndex,
            delta: .object(["content": .string(text)]),
            finishReason: nil
        )])
    }

    /// Emits one complete, typed tool call. Grammar-constrained local backends
    /// should call this only after their JSON object has passed schema decoding.
    public mutating func toolCall(
        outputIndex: Int,
        callID: String,
        name: String,
        arguments: JSONValue
    ) throws -> ProviderWireFrame {
        try requireOutputOpen(outputIndex: outputIndex)
        guard capabilities.features.contains(.tools),
              capabilities.features.contains(.typedToolArguments),
              capabilities.features.contains(.strictToolSchema)
        else { throw LocalModelWireSessionError.toolModeDisabled }
        guard Self.isSafeIdentity(callID, maximumUTF8Count: 256),
              Self.isSafeIdentity(name, maximumUTF8Count: 128)
        else { throw LocalModelWireSessionError.invalidToolIdentity }
        guard case .object = arguments else {
            throw LocalModelWireSessionError.toolArgumentsNotObject
        }
        guard !toolOutputIndexes.contains(outputIndex) else {
            throw LocalModelWireSessionError.duplicateToolOutputIndex(outputIndex)
        }
        guard !toolCallIDs.contains(callID) else {
            throw LocalModelWireSessionError.duplicateToolCallID(callID)
        }
        guard toolOutputIndexes.isEmpty ||
                capabilities.features.contains(.parallelToolCalls)
        else { throw LocalModelWireSessionError.parallelToolCallsDisabled }
        guard toolOutputIndexes.count < Int(capabilities.maximumToolCallsPerTurn) else {
            throw LocalModelWireSessionError.toolLimitExceeded(
                capabilities.maximumToolCallsPerTurn
            )
        }
        let encodedArguments = try canonicalJSONString(arguments)
        toolOutputIndexes.insert(outputIndex)
        toolCallIDs.insert(callID)

        return chatFrame(choices: [choice(
            outputIndex: 0,
            delta: .object([
                "tool_calls": .array([.object([
                    "index": .number(.integer(Int64(outputIndex))),
                    "id": .string(callID),
                    "type": .string("function"),
                    "function": .object([
                        "name": .string(name),
                        "arguments": .string(encodedArguments),
                    ]),
                ])]),
            ]),
            finishReason: nil
        )])
    }

    public mutating func usage(_ usage: ProviderUsage) throws -> ProviderWireFrame {
        try requireOpen()
        guard !usageReported else { throw LocalModelWireSessionError.duplicateUsage }
        guard usage.cachedInputTokens <= usage.inputTokens,
              usage.reasoningTokens <= usage.outputTokens,
              usage.outputTokens <= maximumOutputTokens
        else { throw LocalModelWireSessionError.invalidUsage }
        let total = usage.inputTokens.addingReportingOverflow(usage.outputTokens)
        guard !total.overflow,
              total.partialValue <= capabilities.contextWindowTokens
        else { throw LocalModelWireSessionError.invalidUsage }
        usageReported = true
        let finishChoices: [JSONValue] = toolOutputIndexes.isEmpty
            ? []
            : [choice(
                outputIndex: 0,
                delta: .object([:]),
                finishReason: "tool_calls"
            )]
        return chatFrame(
            choices: finishChoices,
            usage: .object([
                "prompt_tokens": .number(.unsignedInteger(usage.inputTokens)),
                "completion_tokens": .number(.unsignedInteger(usage.outputTokens)),
                "prompt_tokens_details": .object([
                    "cached_tokens": .number(.unsignedInteger(usage.cachedInputTokens)),
                ]),
                "completion_tokens_details": .object([
                    "reasoning_tokens": .number(.unsignedInteger(usage.reasoningTokens)),
                ]),
            ])
        )
    }

    public mutating func complete(
        _ reason: ModelFinishReason
    ) throws -> [ProviderWireFrame] {
        try requireOpen()
        guard usageReported else { throw LocalModelWireSessionError.missingUsage }
        let hasToolCalls = !toolOutputIndexes.isEmpty
        switch (reason, hasToolCalls) {
        case (.toolCalls, true),
             (.completed, false),
             (.length, false),
             (.contentFilter, false):
            break
        case (.cancelled, _), (.unknown, _), (.toolCalls, false),
             (.completed, true), (.length, true), (.contentFilter, true):
            throw LocalModelWireSessionError.finishReasonMismatch
        }
        terminal = true
        let rawReason: String
        switch reason {
        case .completed: rawReason = "stop"
        case .toolCalls: rawReason = "tool_calls"
        case .length: rawReason = "length"
        case .contentFilter: rawReason = "content_filter"
        case .cancelled: rawReason = "cancelled"
        case .unknown: rawReason = "unknown"
        }
        return [
            chatFrame(choices: [choice(
                outputIndex: 0,
                delta: .object([:]),
                finishReason: rawReason
            )]),
            .done,
        ]
    }

    public mutating func cancel(
        reason: LocalModelCancellationReason = .userRequested
    ) throws -> ProviderWireFrame {
        try requireOpen()
        terminal = true
        return .cancelled(reason: reason.rawValue)
    }

    private func requireOpen(outputIndex: Int? = nil) throws {
        guard started else { throw LocalModelWireSessionError.eventBeforeStart }
        guard !terminal else { throw LocalModelWireSessionError.eventAfterTerminal }
        if let outputIndex, outputIndex < 0 {
            throw LocalModelWireSessionError.negativeOutputIndex
        }
    }

    private func requireOutputOpen(outputIndex: Int? = nil) throws {
        try requireOpen(outputIndex: outputIndex)
        guard !usageReported else {
            throw LocalModelWireSessionError.outputAfterUsage
        }
    }

    private func choice(
        outputIndex: Int,
        delta: JSONValue,
        finishReason: String?
    ) -> JSONValue {
        .object([
            "index": .number(.integer(Int64(outputIndex))),
            "delta": delta,
            "finish_reason": finishReason.map(JSONValue.string) ?? .null,
        ])
    }

    private func chatFrame(
        choices: [JSONValue],
        usage: JSONValue? = nil
    ) -> ProviderWireFrame {
        var body: [String: JSONValue] = [
            "id": .string(responseID),
            "model": .string(modelID.rawValue),
            "choices": .array(choices),
        ]
        if let usage { body["usage"] = usage }
        return .json(.object(body))
    }

    private func canonicalJSONString(_ value: JSONValue) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private static func isSafeIdentity(
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
