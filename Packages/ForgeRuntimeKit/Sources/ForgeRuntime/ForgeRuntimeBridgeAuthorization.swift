import Foundation

public enum ForgeRuntimeBridgeOperation: String, Codable, CaseIterable, Sendable {
    case performHaptic = "haptics.perform"
    case presentShareSheet = "share.present"
    case readStorage = "storage.read"
    case writeStorage = "storage.write"
    case readControllerSnapshot = "controller.snapshot"

    public var requiredCapabilityID: String {
        switch self {
        case .performHaptic:
            "haptics"
        case .presentShareSheet:
            "share"
        case .readStorage, .writeStorage:
            "storage"
        case .readControllerSnapshot:
            "controller"
        }
    }
}

/// Wire envelope received from untrusted generated project code before operation-specific payload
/// decoding. Capability is deliberately absent: the host maps each operation to its own required
/// capability and never trusts project code to self-declare a weaker permission.
public struct ForgeRuntimeBridgeRequestEnvelope: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let requestID: String
    public let operation: String

    public init(protocolVersion: Int = 1, requestID: String, operation: String) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.operation = operation
    }
}

public struct ForgeRuntimeBridgeRequest: Equatable, Sendable {
    public let protocolVersion: Int
    public let requestID: String
    public let operation: ForgeRuntimeBridgeOperation

    init(protocolVersion: Int, requestID: String, operation: ForgeRuntimeBridgeOperation) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.operation = operation
    }
}

public enum ForgeRuntimeBridgeRequestError: Error, Equatable, Sendable {
    case requestTooLarge(actualBytes: Int, maximumBytes: Int)
    case invalidJSON
    case unsupportedProtocolVersion(Int)
    case invalidRequestID
    case unknownOperation(String)
}

public struct ForgeRuntimeBridgeRequestDecoder: Sendable {
    public let supportedProtocolVersion: Int
    public let maximumRequestBytes: Int

    public init(supportedProtocolVersion: Int = 1, maximumRequestBytes: Int = 32 * 1024) {
        self.supportedProtocolVersion = supportedProtocolVersion
        self.maximumRequestBytes = maximumRequestBytes
    }

    public func decode(_ data: Data) throws -> ForgeRuntimeBridgeRequest {
        guard data.count <= maximumRequestBytes else {
            throw ForgeRuntimeBridgeRequestError.requestTooLarge(
                actualBytes: data.count,
                maximumBytes: maximumRequestBytes
            )
        }

        let envelope: ForgeRuntimeBridgeRequestEnvelope
        do {
            envelope = try JSONDecoder().decode(ForgeRuntimeBridgeRequestEnvelope.self, from: data)
        } catch {
            throw ForgeRuntimeBridgeRequestError.invalidJSON
        }

        guard envelope.protocolVersion == supportedProtocolVersion else {
            throw ForgeRuntimeBridgeRequestError.unsupportedProtocolVersion(envelope.protocolVersion)
        }
        guard Self.isValidRequestID(envelope.requestID) else {
            throw ForgeRuntimeBridgeRequestError.invalidRequestID
        }
        guard let operation = ForgeRuntimeBridgeOperation(rawValue: envelope.operation) else {
            throw ForgeRuntimeBridgeRequestError.unknownOperation(envelope.operation)
        }

        return ForgeRuntimeBridgeRequest(
            protocolVersion: envelope.protocolVersion,
            requestID: envelope.requestID,
            operation: operation
        )
    }

    private static func isValidRequestID(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 64 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            let isUpper = scalar.value >= 65 && scalar.value <= 90
            let isLower = scalar.value >= 97 && scalar.value <= 122
            let isDigit = scalar.value >= 48 && scalar.value <= 57
            return isUpper || isLower || isDigit || scalar == "-" || scalar == "_" || scalar == "."
        }
    }
}

public enum ForgeRuntimeBridgeAuthorizationError: Error, Equatable, Sendable {
    case capabilityNotGranted(requiredCapabilityID: String)
}

public struct ForgeRuntimeBridgeAuthorizer: Sendable {
    public init() {}

    public func authorize(
        _ request: ForgeRuntimeBridgeRequest,
        launchAuthorization: ForgeRuntimeLaunchAuthorization
    ) throws {
        let required = request.operation.requiredCapabilityID
        guard launchAuthorization.grantedCapabilityIDs.contains(required) else {
            throw ForgeRuntimeBridgeAuthorizationError.capabilityNotGranted(
                requiredCapabilityID: required
            )
        }
    }
}
