import AgentDomain
import Foundation

/// Version-aware boundary used by stores that persist event bodies as opaque
/// bytes while indexing the envelope/header fields separately.
public protocol AgentEventCodec: Sendable {
    func encode(_ event: AgentEvent) throws -> Data
    func decode(_ data: Data) throws -> AgentEvent
}

public enum AgentEventCodecError: Error, Equatable, Sendable {
    case encodingFailed
    case decodingFailed
}

/// Deterministic JSON representation for V1 events. Domain timestamps are
/// integer milliseconds, so no encoder-specific date strategy is involved.
public struct JSONAgentEventCodec: AgentEventCodec, Sendable {
    public init() {}

    public func encode(_ event: AgentEvent) throws -> Data {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(event)
        } catch {
            throw AgentEventCodecError.encodingFailed
        }
    }

    public func decode(_ data: Data) throws -> AgentEvent {
        do {
            return try JSONDecoder().decode(AgentEvent.self, from: data)
        } catch {
            throw AgentEventCodecError.decodingFailed
        }
    }
}
