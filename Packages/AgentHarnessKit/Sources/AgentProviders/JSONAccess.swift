import AgentDomain
import Foundation

extension JSONValue {
    var providerObject: [String: JSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    var providerArray: [JSONValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    var providerString: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    var providerInt: Int? {
        guard case let .number(number) = self else { return nil }
        switch number {
        case let .integer(value):
            return Int(exactly: value)
        case let .unsignedInteger(value):
            return Int(exactly: value)
        case let .floatingPoint(value):
            guard value.rounded(.towardZero) == value else { return nil }
            return Int(exactly: value)
        }
    }

    var providerUInt64: UInt64? {
        guard case let .number(number) = self else { return nil }
        switch number {
        case let .integer(value):
            return UInt64(exactly: value)
        case let .unsignedInteger(value):
            return value
        case let .floatingPoint(value):
            guard value.isFinite, value >= 0, value.rounded(.towardZero) == value else { return nil }
            return UInt64(exactly: value)
        }
    }

    var isProviderNull: Bool {
        if case .null = self { true } else { false }
    }
}

func decodeToolArguments(
    _ source: String,
    descriptor: ProviderAdapterDescriptor
) throws -> JSONValue {
    guard !source.isEmpty else {
        throw ProviderFailureMapper.malformed("provider_tool_arguments_empty", descriptor: descriptor)
    }
    guard source.utf8.count <= 1 * 1_024 * 1_024,
          hasBoundedJSONNesting(source, maximumDepth: 64)
    else {
        throw ProviderFailureMapper.protocolViolation(
            "provider_tool_arguments_budget_exceeded",
            descriptor: descriptor
        )
    }
    do {
        let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(source.utf8))
        guard case .object = decoded else {
            throw ProviderFailureMapper.malformed(
                "provider_tool_arguments_not_object",
                descriptor: descriptor
            )
        }
        return decoded
    } catch let failure as ProviderFailure {
        throw failure
    } catch {
        throw ProviderFailureMapper.malformed(
            "provider_tool_arguments_invalid_json",
            descriptor: descriptor
        )
    }
}

private func hasBoundedJSONNesting(
    _ source: String,
    maximumDepth: Int
) -> Bool {
    var depth = 0
    var inString = false
    var escaped = false
    for byte in source.utf8 {
        if inString {
            if escaped {
                escaped = false
            } else if byte == 0x5C {
                escaped = true
            } else if byte == 0x22 {
                inString = false
            }
            continue
        }
        switch byte {
        case 0x22:
            inString = true
        case 0x7B, 0x5B:
            depth += 1
            if depth > maximumDepth { return false }
        case 0x7D, 0x5D:
            depth = max(0, depth - 1)
        default:
            break
        }
    }
    // Syntax validity (including unbalanced strings/delimiters) belongs to
    // JSONDecoder so malformed input keeps its stable malformed-event code.
    // This pass exists only to reject excessive nesting before decoding.
    return true
}

func providerErrorFromEvent(
    _ value: JSONValue,
    descriptor: ProviderAdapterDescriptor
) -> ProviderFailure? {
    guard let object = value.providerObject,
          let error = object["error"]?.providerObject
    else { return nil }

    let code = error["code"]?.providerString
    let status = error["status"]?.providerInt ?? 500
    return ProviderFailureMapper.httpFailure(
        statusCode: status,
        providerCode: code,
        providerID: descriptor.route.providerID,
        adapterID: descriptor.route.adapterID
    )
}
