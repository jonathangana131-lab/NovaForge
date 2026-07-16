import AgentDomain
import Foundation

/// A single pre-encoding budget for the complete canonical request. Individual
/// schema limits are not sufficient: a caller could otherwise submit many
/// individually valid schemas or structured transcript parts and multiply the
/// encoder/validator work.
enum ProviderRequestBudget {
    private static let maximumMessages = 512
    private static let maximumContentParts = 4_096
    private static let maximumTools = 128
    private static let maximumNodes = 200_000
    private static let maximumEncodedUTF8Bytes = 8 * 1_024 * 1_024
    private static let maximumJSONDepth = 64

    enum Failure: Error, Equatable, Sendable {
        case exceeded
    }

    static func validate(_ request: CanonicalProviderRequest) throws {
        guard request.messages.count <= maximumMessages,
              request.tools.count <= maximumTools
        else { throw Failure.exceeded }

        var meter = Meter()
        try meter.recordContainer()
        try meter.recordString(request.requestID)
        try meter.recordString(request.model.rawValue)

        var contentPartCount = 0
        for message in request.messages {
            let next = contentPartCount.addingReportingOverflow(message.content.count)
            guard !next.overflow, next.partialValue <= maximumContentParts else {
                throw Failure.exceeded
            }
            contentPartCount = next.partialValue

            try meter.recordContainer()
            try meter.recordString(message.role.rawValue)
            if let callID = message.toolCallID { try meter.recordString(callID) }
            if let name = message.name { try meter.recordString(name) }
            for part in message.content {
                try meter.recordContainer()
                switch part {
                case let .text(text):
                    try meter.recordString(text)
                case let .structured(value):
                    try meter.recordJSON(value, depth: 0)
                case let .image(image):
                    try meter.recordString(image.mediaType)
                    try meter.recordString(image.source)
                    if let detail = image.detail { try meter.recordString(detail) }
                case let .toolCall(call):
                    try meter.recordString(call.callID)
                    try meter.recordString(call.name)
                    try meter.recordJSON(call.arguments, depth: 0)
                }
            }
        }

        for tool in request.tools {
            try meter.recordContainer()
            try meter.recordString(tool.name)
            try meter.recordString(tool.description)
            try meter.recordJSON(tool.parameters, depth: 0)
        }

        try meter.recordContainer()
        switch request.options.toolChoice {
        case let .named(name): try meter.recordString(name)
        case .auto, .none, .required: break
        }
        if let key = request.options.promptCacheKey { try meter.recordString(key) }
        if let responseID = request.options.previousResponseID { try meter.recordString(responseID) }
        try meter.recordJSON(request.metadata, depth: 0)
    }

    static func validateEncodedBody(_ body: JSONValue) throws {
        var meter = Meter()
        try meter.recordJSON(body, depth: 0)
    }

    private struct Meter {
        private var nodes = 0
        private var encodedUTF8Bytes = 0

        mutating func recordContainer() throws {
            // Reserve punctuation/key overhead as well as the logical node.
            try spend(nodes: 1, bytes: 16)
        }

        mutating func recordString(_ value: String) throws {
            var bytes = 2 // surrounding JSON quotes
            for scalar in value.unicodeScalars {
                let increment: Int
                switch scalar.value {
                case 0 ... 0x1F:
                    // JSON escapes control scalars; six bytes is the safe
                    // upper bound (for example, "\\u0000").
                    increment = 6
                case 0x22, 0x5C:
                    increment = 2
                default:
                    increment = scalar.utf8.count
                }
                let next = bytes.addingReportingOverflow(increment)
                guard !next.overflow else { throw Failure.exceeded }
                bytes = next.partialValue
            }
            try spend(nodes: 1, bytes: bytes)
        }

        mutating func recordJSON(_ value: JSONValue, depth: Int) throws {
            guard depth <= ProviderRequestBudget.maximumJSONDepth else {
                throw Failure.exceeded
            }
            switch value {
            case .null:
                try spend(nodes: 1, bytes: 4)
            case .bool:
                try spend(nodes: 1, bytes: 5)
            case let .number(number):
                if case let .floatingPoint(value) = number, !value.isFinite {
                    throw Failure.exceeded
                }
                try spend(nodes: 1, bytes: 32)
            case let .string(string):
                try recordString(string)
            case let .array(values):
                guard values.count <= ProviderRequestBudget.maximumEncodedUTF8Bytes - 2 else {
                    throw Failure.exceeded
                }
                try spend(nodes: 1, bytes: 2 + values.count)
                for child in values {
                    try recordJSON(child, depth: depth + 1)
                }
            case let .object(object):
                guard object.count <= (ProviderRequestBudget.maximumEncodedUTF8Bytes - 2) / 2 else {
                    throw Failure.exceeded
                }
                // One colon per pair and one comma between pairs, plus braces.
                try spend(nodes: 1, bytes: 2 + (object.count * 2))
                for (key, child) in object {
                    try recordString(key)
                    try recordJSON(child, depth: depth + 1)
                }
            }
        }

        private mutating func spend(nodes additionalNodes: Int, bytes additionalBytes: Int) throws {
            let nextNodes = nodes.addingReportingOverflow(additionalNodes)
            let nextBytes = encodedUTF8Bytes.addingReportingOverflow(additionalBytes)
            guard !nextNodes.overflow, !nextBytes.overflow,
                  nextNodes.partialValue <= ProviderRequestBudget.maximumNodes,
                  nextBytes.partialValue <= ProviderRequestBudget.maximumEncodedUTF8Bytes
            else { throw Failure.exceeded }
            nodes = nextNodes.partialValue
            encodedUTF8Bytes = nextBytes.partialValue
        }
    }
}
