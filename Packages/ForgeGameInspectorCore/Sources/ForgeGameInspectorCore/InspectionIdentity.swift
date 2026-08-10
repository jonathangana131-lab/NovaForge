import Foundation

public enum ForgeGameInspectorError: Error, Equatable, Sendable {
    case invalidIdentity(String)
    case invalidSourceAssociation
    case invalidBounds
    case duplicateEntityID(String)
    case duplicateTunableID(String)
    case tooManyEntities
    case tooManyTunables
    case incompleteReportedProducerMetadata
    case invalidTunableRange
    case nonFiniteNumber
    case selectionTargetMismatch
    case entityNotFound(String)
    case tunableNotFound(String)
    case tuningOutOfRange
}

public struct ForgeGameInspectionTarget: Codable, Equatable, Hashable, Sendable {
    public let projectID: String
    public let sourceRevision: String
    public let runtimeSessionID: String
    public let runtimeVersion: String
    public let captureID: String
    public let frameSequence: UInt64

    public init(
        projectID: String,
        sourceRevision: String,
        runtimeSessionID: String,
        runtimeVersion: String,
        captureID: String,
        frameSequence: UInt64
    ) throws {
        try Self.validateIdentity(projectID, field: "projectID")
        try Self.validateIdentity(sourceRevision, field: "sourceRevision")
        try Self.validateIdentity(runtimeSessionID, field: "runtimeSessionID")
        try Self.validateIdentity(runtimeVersion, field: "runtimeVersion")
        try Self.validateIdentity(captureID, field: "captureID")

        self.projectID = projectID
        self.sourceRevision = sourceRevision
        self.runtimeSessionID = runtimeSessionID
        self.runtimeVersion = runtimeVersion
        self.captureID = captureID
        self.frameSequence = frameSequence
    }

    private enum CodingKeys: String, CodingKey {
        case projectID, sourceRevision, runtimeSessionID, runtimeVersion, captureID, frameSequence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            projectID: container.decode(String.self, forKey: .projectID),
            sourceRevision: container.decode(String.self, forKey: .sourceRevision),
            runtimeSessionID: container.decode(String.self, forKey: .runtimeSessionID),
            runtimeVersion: container.decode(String.self, forKey: .runtimeVersion),
            captureID: container.decode(String.self, forKey: .captureID),
            frameSequence: container.decode(UInt64.self, forKey: .frameSequence)
        )
    }

    static func validateIdentity(_ value: String, field: String) throws {
        guard !value.isEmpty,
              value.count <= 160,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            throw ForgeGameInspectorError.invalidIdentity(field)
        }
    }
}

public struct ForgeGameNormalizedRect: Codable, Equatable, Hashable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) throws {
        let values = [x, y, width, height]
        guard values.allSatisfy(\.isFinite) else {
            throw ForgeGameInspectorError.nonFiniteNumber
        }
        guard x >= 0, y >= 0, width >= 0, height >= 0,
              x <= 1, y <= 1, width <= 1, height <= 1,
              x + width <= 1.000_001,
              y + height <= 1.000_001
        else {
            throw ForgeGameInspectorError.invalidBounds
        }

        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    private enum CodingKeys: String, CodingKey { case x, y, width, height }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            x: container.decode(Double.self, forKey: .x),
            y: container.decode(Double.self, forKey: .y),
            width: container.decode(Double.self, forKey: .width),
            height: container.decode(Double.self, forKey: .height)
        )
    }
}

public struct ForgeGameSourceAssociation: Codable, Equatable, Hashable, Sendable {
    public let relativeFilePath: String
    public let symbolID: String?
    public let configKey: String?

    public init(relativeFilePath: String, symbolID: String? = nil, configKey: String? = nil) throws {
        guard Self.isSafeRelativePath(relativeFilePath) else {
            throw ForgeGameInspectorError.invalidSourceAssociation
        }
        if let symbolID {
            try ForgeGameInspectionTarget.validateIdentity(symbolID, field: "symbolID")
        }
        if let configKey {
            try ForgeGameInspectionTarget.validateIdentity(configKey, field: "configKey")
        }
        self.relativeFilePath = relativeFilePath
        self.symbolID = symbolID
        self.configKey = configKey
    }

    private enum CodingKeys: String, CodingKey { case relativeFilePath, symbolID, configKey }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            relativeFilePath: container.decode(String.self, forKey: .relativeFilePath),
            symbolID: container.decodeIfPresent(String.self, forKey: .symbolID),
            configKey: container.decodeIfPresent(String.self, forKey: .configKey)
        )
    }

    private static func isSafeRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.count <= 512,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.hasPrefix("/"),
              !value.hasPrefix("~"),
              !value.contains("\\"),
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return false }

        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty else { return false }
        return components.allSatisfy { component in
            !component.isEmpty && component != "." && component != ".."
        }
    }
}

public enum ForgeGameEntityKind: String, Codable, CaseIterable, Sendable {
    case sceneObject, hud, control, camera, light, collider, physicsBody, particleEmitter, audioEmitter, other
}

public enum ForgePhysicsTunableKind: String, Codable, CaseIterable, Sendable {
    case gravity, mass, friction, restitution, linearDamping, angularDamping
    case steeringRate, driveTorque, brakeForce, suspensionStiffness, suspensionDamping, cameraFOV, custom
}
