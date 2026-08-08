import Foundation

public enum Forge3DValidationError: Error, Equatable, Sendable {
    case invalidIdentifier
    case nonFiniteValue
    case invalidRange
    case duplicateEntity
    case duplicateAction
    case budgetExceeded
}

public struct Forge3DVector3: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let z: Double

    public init(x: Double, y: Double, z: Double) throws {
        guard x.isFinite, y.isFinite, z.isFinite else { throw Forge3DValidationError.nonFiniteValue }
        self.x = x; self.y = y; self.z = z
    }
}

public struct Forge3DTransform: Codable, Equatable, Sendable {
    public let position: Forge3DVector3
    public let rotationRadians: Forge3DVector3
    public let scale: Forge3DVector3

    public init(position: Forge3DVector3, rotationRadians: Forge3DVector3, scale: Forge3DVector3) throws {
        guard scale.x > 0, scale.y > 0, scale.z > 0 else { throw Forge3DValidationError.invalidRange }
        self.position = position
        self.rotationRadians = rotationRadians
        self.scale = scale
    }
}

public struct Forge3DEntity: Codable, Equatable, Sendable {
    public let id: String
    public let transform: Forge3DTransform
    public let dynamicBody: Bool

    public init(id: String, transform: Forge3DTransform, dynamicBody: Bool) throws {
        let normalized = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.count <= 128 else { throw Forge3DValidationError.invalidIdentifier }
        self.id = normalized
        self.transform = transform
        self.dynamicBody = dynamicBody
    }
}

public struct Forge3DSceneBudget: Codable, Equatable, Sendable {
    public let maxEntities: Int
    public let maxDynamicBodies: Int
    public let maxLights: Int
    public let maxTextureMemoryMB: Int
    public let targetFPS: Int

    public init(maxEntities: Int, maxDynamicBodies: Int, maxLights: Int, maxTextureMemoryMB: Int, targetFPS: Int) throws {
        guard maxEntities > 0, maxDynamicBodies >= 0, maxDynamicBodies <= maxEntities,
              maxLights >= 0, maxTextureMemoryMB > 0, [30, 60, 120].contains(targetFPS)
        else { throw Forge3DValidationError.invalidRange }
        self.maxEntities = maxEntities
        self.maxDynamicBodies = maxDynamicBodies
        self.maxLights = maxLights
        self.maxTextureMemoryMB = maxTextureMemoryMB
        self.targetFPS = targetFPS
    }

    /// Conservative generation policy for the V13 baseline. This is not a measured physical-device limit.
    public static var iPhone12Baseline: Forge3DSceneBudget {
        try! Forge3DSceneBudget(maxEntities: 500, maxDynamicBodies: 96, maxLights: 8, maxTextureMemoryMB: 192, targetFPS: 60)
    }
}

public struct Forge3DSceneLoad: Codable, Equatable, Sendable {
    public let entities: Int
    public let dynamicBodies: Int
    public let lights: Int
    public let textureMemoryMB: Int

    public init(entities: Int, dynamicBodies: Int, lights: Int, textureMemoryMB: Int) throws {
        guard entities >= 0, dynamicBodies >= 0, dynamicBodies <= entities, lights >= 0, textureMemoryMB >= 0
        else { throw Forge3DValidationError.invalidRange }
        self.entities = entities
        self.dynamicBodies = dynamicBodies
        self.lights = lights
        self.textureMemoryMB = textureMemoryMB
    }

    public func validate(against budget: Forge3DSceneBudget) throws {
        guard entities <= budget.maxEntities,
              dynamicBodies <= budget.maxDynamicBodies,
              lights <= budget.maxLights,
              textureMemoryMB <= budget.maxTextureMemoryMB
        else { throw Forge3DValidationError.budgetExceeded }
    }
}

public enum Forge3DInputSource: String, Codable, Sendable { case touchAxis, touchButton, controllerAxis, controllerButton }

public struct Forge3DInputBinding: Codable, Equatable, Sendable {
    public let actionID: String
    public let source: Forge3DInputSource
    public let deadZone: Double

    public init(actionID: String, source: Forge3DInputSource, deadZone: Double = 0) throws {
        let normalized = actionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.count <= 128 else { throw Forge3DValidationError.invalidIdentifier }
        guard deadZone.isFinite, (0...0.95).contains(deadZone) else { throw Forge3DValidationError.invalidRange }
        self.actionID = normalized
        self.source = source
        self.deadZone = deadZone
    }

    public func normalizedAxis(_ raw: Double) throws -> Double {
        guard raw.isFinite else { throw Forge3DValidationError.nonFiniteValue }
        let clamped = min(1, max(-1, raw))
        guard abs(clamped) > deadZone else { return 0 }
        let magnitude = (abs(clamped) - deadZone) / (1 - deadZone)
        return clamped.sign == .minus ? -magnitude : magnitude
    }
}

public struct Forge3DProjectSpec: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let projectID: String
    public let sourceRevision: String
    public let entities: [Forge3DEntity]
    public let inputBindings: [Forge3DInputBinding]
    public let budget: Forge3DSceneBudget

    public init(schemaVersion: Int = 1, projectID: String, sourceRevision: String, entities: [Forge3DEntity], inputBindings: [Forge3DInputBinding], budget: Forge3DSceneBudget) throws {
        guard schemaVersion == 1 else { throw Forge3DValidationError.invalidRange }
        let project = projectID.trimmingCharacters(in: .whitespacesAndNewlines)
        let revision = sourceRevision.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !project.isEmpty, !revision.isEmpty else { throw Forge3DValidationError.invalidIdentifier }
        guard Set(entities.map(\.id)).count == entities.count else { throw Forge3DValidationError.duplicateEntity }
        guard Set(inputBindings.map(\.actionID)).count == inputBindings.count else { throw Forge3DValidationError.duplicateAction }
        let load = try Forge3DSceneLoad(entities: entities.count, dynamicBodies: entities.filter(\.dynamicBody).count, lights: 0, textureMemoryMB: 0)
        try load.validate(against: budget)
        self.schemaVersion = schemaVersion
        self.projectID = project
        self.sourceRevision = revision
        self.entities = entities.sorted { $0.id < $1.id }
        self.inputBindings = inputBindings.sorted { $0.actionID < $1.actionID }
        self.budget = budget
    }

    public static func decodeValidated(_ data: Data) throws -> Forge3DProjectSpec {
        let decoded = try JSONDecoder().decode(Forge3DProjectSpec.self, from: data)
        return try Forge3DProjectSpec(projectID: decoded.projectID, sourceRevision: decoded.sourceRevision, entities: decoded.entities, inputBindings: decoded.inputBindings, budget: decoded.budget)
    }
}
