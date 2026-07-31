import AgentDomain
import Foundation

public protocol AgentToolArguments: Codable, Equatable, Sendable {
    static var jsonSchema: JSONSchema { get }
}

public protocol AgentTool: Sendable {
    associatedtype Arguments: AgentToolArguments
    static var metadata: ToolDescriptorMetadata { get }
}

public extension AgentTool {
    static var descriptor: ToolDescriptor {
        ToolDescriptor(metadata: metadata, argumentSchema: Arguments.jsonSchema)
    }

    static func decodeArguments(_ value: JSONValue) throws -> Arguments {
        try ToolArgumentValidator.validate(value, against: Arguments.jsonSchema)
        do {
            return try JSONDecoder().decode(Arguments.self, from: AgentToolJSON.data(for: value))
        } catch {
            throw ToolArgumentValidationError(issues: [
                .init(
                    code: .typedDecodingFailed,
                    path: [],
                    message: "Validated arguments could not be decoded into the tool's typed contract."
                ),
            ])
        }
    }
}

public enum DecodedToolArgumentsError: Error, Equatable, Sendable {
    case unexpectedType(expected: String)
}

public struct DecodedToolArguments: Sendable {
    private let storage: any Sendable

    init<T: Sendable>(_ value: T) {
        storage = value
    }

    public func value<T: Sendable>(as type: T.Type = T.self) throws -> T {
        guard let typed = storage as? T else {
            throw DecodedToolArgumentsError.unexpectedType(expected: String(reflecting: type))
        }
        return typed
    }
}

public struct AnyAgentTool: Sendable {
    public let descriptor: ToolDescriptor
    private let decodeImplementation: @Sendable (JSONValue) throws -> DecodedToolArguments

    public init<T: AgentTool>(_ tool: T.Type) {
        descriptor = T.descriptor
        decodeImplementation = { arguments in
            DecodedToolArguments(try T.decodeArguments(arguments))
        }
    }

    public func decodeArguments(_ arguments: JSONValue) throws -> DecodedToolArguments {
        try decodeImplementation(arguments)
    }
}
