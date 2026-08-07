import Foundation

/// Fail-closed limits for serialized/generated 2D-kit configuration crossing into host-owned runtime state.
/// These are authority and memory-safety policy bounds, not physical-device performance measurements.
public enum Forge2DUntrustedProjectLimits {
    public static let maximumIdentifierUTF8Bytes = 128
    public static let maximumInputMapBytes = 256 * 1_024
    public static let maximumCollisionTableBytes = 256 * 1_024
    public static let maximumEncodedSaveBytes = 1_500_000
    public static let maximumActions = 128
    public static let maximumBindings = 512
    public static let maximumCollisionRules = 1_024
    public static let maximumSavePayloadBytes = 1_048_576
}

public enum Forge2DUntrustedProjectError: Error, Equatable, Sendable {
    case serializedDataTooLarge(kind: String, maximumBytes: Int)
    case collectionTooLarge(kind: String, maximumCount: Int)
    case invalidIdentifier(field: String)
    case unknownBindingAction(String)
}

public enum Forge2DUntrustedProjectPolicy {
    public static func decodeInputMap(
        _ data: Data,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> Forge2DInputMap {
        try requireSerializedSize(data, kind: "inputMap", maximumBytes: Forge2DUntrustedProjectLimits.maximumInputMapBytes)
        let map = try decoder.decode(Forge2DInputMap.self, from: data)
        try validate(map)
        return map
    }

    public static func validate(_ map: Forge2DInputMap) throws {
        guard map.actions.count <= Forge2DUntrustedProjectLimits.maximumActions else {
            throw Forge2DUntrustedProjectError.collectionTooLarge(
                kind: "actions",
                maximumCount: Forge2DUntrustedProjectLimits.maximumActions
            )
        }
        guard map.bindings.count <= Forge2DUntrustedProjectLimits.maximumBindings else {
            throw Forge2DUntrustedProjectError.collectionTooLarge(
                kind: "bindings",
                maximumCount: Forge2DUntrustedProjectLimits.maximumBindings
            )
        }

        let actionIDs = Set(map.actions.map(\.rawValue))
        for action in map.actions {
            try requireIdentifier(action.rawValue, field: "action")
        }
        for binding in map.bindings {
            try requireIdentifier(binding.id, field: "binding")
            try requireIdentifier(binding.action.rawValue, field: "binding.action")
            guard actionIDs.contains(binding.action.rawValue) else {
                throw Forge2DUntrustedProjectError.unknownBindingAction(binding.action.rawValue)
            }
            switch binding.source {
            case let .touchButton(id), let .controllerButton(id):
                try requireIdentifier(id, field: "inputSource")
            case let .touchAxis(id, _, _), let .controllerAxis(id, _, _):
                try requireIdentifier(id, field: "inputSource")
            }
        }
    }

    public static func decodeCollisionTable(
        _ data: Data,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> Forge2DCollisionTable {
        try requireSerializedSize(data, kind: "collisionTable", maximumBytes: Forge2DUntrustedProjectLimits.maximumCollisionTableBytes)
        let table = try decoder.decode(Forge2DCollisionTable.self, from: data)
        try validate(table)
        return table
    }

    public static func validate(_ table: Forge2DCollisionTable) throws {
        guard table.rules.count <= Forge2DUntrustedProjectLimits.maximumCollisionRules else {
            throw Forge2DUntrustedProjectError.collectionTooLarge(
                kind: "collisionRules",
                maximumCount: Forge2DUntrustedProjectLimits.maximumCollisionRules
            )
        }
    }

    public static func decodeSaveEnvelope(
        _ data: Data,
        expectedProjectID: String,
        expectedSourceRevision: String,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> Forge2DSaveEnvelope {
        try requireIdentifier(expectedProjectID, field: "expectedProjectID")
        try requireIdentifier(expectedSourceRevision, field: "expectedSourceRevision")
        try requireSerializedSize(data, kind: "saveEnvelope", maximumBytes: Forge2DUntrustedProjectLimits.maximumEncodedSaveBytes)

        let envelope = try Forge2DSaveEnvelope.decodeValidated(
            data,
            expectedProjectID: expectedProjectID,
            expectedSourceRevision: expectedSourceRevision,
            maximumPayloadBytes: Forge2DUntrustedProjectLimits.maximumSavePayloadBytes,
            decoder: decoder
        )
        try requireIdentifier(envelope.projectID, field: "projectID")
        try requireIdentifier(envelope.slotID, field: "slotID")
        try requireIdentifier(envelope.sourceRevision, field: "sourceRevision")
        return envelope
    }

    private static func requireSerializedSize(_ data: Data, kind: String, maximumBytes: Int) throws {
        guard data.count <= maximumBytes else {
            throw Forge2DUntrustedProjectError.serializedDataTooLarge(kind: kind, maximumBytes: maximumBytes)
        }
    }

    private static func requireIdentifier(_ value: String, field: String) throws {
        guard !value.isEmpty,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.utf8.count <= Forge2DUntrustedProjectLimits.maximumIdentifierUTF8Bytes,
              value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw Forge2DUntrustedProjectError.invalidIdentifier(field: field)
        }
    }
}
