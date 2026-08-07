import Foundation

public enum Forge2DKitError: Error, Equatable, Sendable {
    case invalidLoopConfiguration
    case invalidPerformanceBudget
    case invalidWorldBudget
    case duplicateActionID(String)
    case duplicateBindingID(String)
    case emptyIdentifier
    case invalidAxisRange
    case invalidCollisionLayer
    case duplicateCollisionRule
    case invalidSaveEnvelope
    case savePayloadTooLarge(maximumBytes: Int)
}

public struct Forge2DFixedStepPolicy: Codable, Equatable, Sendable {
    public let simulationHz: Int
    public let maximumCatchUpSteps: Int
    public let maximumFrameDelta: TimeInterval

    public init(
        simulationHz: Int = 60,
        maximumCatchUpSteps: Int = 4,
        maximumFrameDelta: TimeInterval = 0.25
    ) throws {
        guard (15...240).contains(simulationHz),
              (1...12).contains(maximumCatchUpSteps),
              maximumFrameDelta.isFinite,
              maximumFrameDelta > 0,
              maximumFrameDelta <= 1 else {
            throw Forge2DKitError.invalidLoopConfiguration
        }
        self.simulationHz = simulationHz
        self.maximumCatchUpSteps = maximumCatchUpSteps
        self.maximumFrameDelta = maximumFrameDelta
    }

    public var fixedDelta: TimeInterval { 1 / TimeInterval(simulationHz) }

    private enum CodingKeys: String, CodingKey { case simulationHz, maximumCatchUpSteps, maximumFrameDelta }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            simulationHz: container.decode(Int.self, forKey: .simulationHz),
            maximumCatchUpSteps: container.decode(Int.self, forKey: .maximumCatchUpSteps),
            maximumFrameDelta: container.decode(TimeInterval.self, forKey: .maximumFrameDelta)
        )
    }
}

public struct Forge2DFrameAdvance: Equatable, Sendable {
    public let simulationSteps: Int
    public let remainder: TimeInterval
    public let interpolationAlpha: Double
    public let droppedTime: TimeInterval
}

public struct Forge2DFixedStepAccumulator: Equatable, Sendable {
    public private(set) var remainder: TimeInterval

    public init(remainder: TimeInterval = 0) {
        self.remainder = max(0, remainder.isFinite ? remainder : 0)
    }

    public mutating func advance(
        elapsed: TimeInterval,
        policy: Forge2DFixedStepPolicy,
        executionState: Forge2DExecutionState
    ) -> Forge2DFrameAdvance {
        guard executionState == .running else {
            return Forge2DFrameAdvance(
                simulationSteps: 0,
                remainder: remainder,
                interpolationAlpha: min(max(remainder / policy.fixedDelta, 0), 1),
                droppedTime: 0
            )
        }

        let safeElapsed = elapsed.isFinite ? max(0, elapsed) : 0
        let acceptedElapsed = min(safeElapsed, policy.maximumFrameDelta)
        let frameClampDrop = max(0, safeElapsed - acceptedElapsed)
        var total = remainder + acceptedElapsed
        let availableSteps = Int(total / policy.fixedDelta)
        let executedSteps = min(availableSteps, policy.maximumCatchUpSteps)
        total -= TimeInterval(executedSteps) * policy.fixedDelta

        var catchUpDrop: TimeInterval = 0
        if availableSteps > policy.maximumCatchUpSteps {
            let skipped = availableSteps - policy.maximumCatchUpSteps
            catchUpDrop = TimeInterval(skipped) * policy.fixedDelta
            total -= catchUpDrop
        }

        // Floating point drift must never produce a negative remainder.
        remainder = max(0, total)
        let alpha = min(max(remainder / policy.fixedDelta, 0), 1)
        return Forge2DFrameAdvance(
            simulationSteps: executedSteps,
            remainder: remainder,
            interpolationAlpha: alpha,
            droppedTime: frameClampDrop + catchUpDrop
        )
    }
}

public enum Forge2DExecutionState: String, Codable, Sendable {
    case running
    case pausedByUser
    case suspendedByHost
    case stopped
}

public struct Forge2DPerformanceBudget: Codable, Equatable, Sendable {
    public enum DeviceTarget: String, Codable, Sendable {
        case iPhone12Baseline
        case modernPhone
        case conservative
    }

    public let deviceTarget: DeviceTarget
    public let targetFramesPerSecond: Int
    public let maximumEntities: Int
    public let maximumDynamicBodies: Int
    public let maximumParticles: Int
    public let maximumAudioVoices: Int
    public let maximumDecodedTextureBytes: Int

    public init(
        deviceTarget: DeviceTarget,
        targetFramesPerSecond: Int,
        maximumEntities: Int,
        maximumDynamicBodies: Int,
        maximumParticles: Int,
        maximumAudioVoices: Int,
        maximumDecodedTextureBytes: Int
    ) throws {
        guard [30, 60, 120].contains(targetFramesPerSecond),
              maximumEntities > 0,
              maximumDynamicBodies >= 0,
              maximumDynamicBodies <= maximumEntities,
              maximumParticles >= 0,
              maximumAudioVoices >= 0,
              maximumDecodedTextureBytes > 0 else {
            throw Forge2DKitError.invalidPerformanceBudget
        }
        self.deviceTarget = deviceTarget
        self.targetFramesPerSecond = targetFramesPerSecond
        self.maximumEntities = maximumEntities
        self.maximumDynamicBodies = maximumDynamicBodies
        self.maximumParticles = maximumParticles
        self.maximumAudioVoices = maximumAudioVoices
        self.maximumDecodedTextureBytes = maximumDecodedTextureBytes
    }

    private enum CodingKeys: String, CodingKey {
        case deviceTarget, targetFramesPerSecond, maximumEntities, maximumDynamicBodies, maximumParticles, maximumAudioVoices, maximumDecodedTextureBytes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            deviceTarget: container.decode(DeviceTarget.self, forKey: .deviceTarget),
            targetFramesPerSecond: container.decode(Int.self, forKey: .targetFramesPerSecond),
            maximumEntities: container.decode(Int.self, forKey: .maximumEntities),
            maximumDynamicBodies: container.decode(Int.self, forKey: .maximumDynamicBodies),
            maximumParticles: container.decode(Int.self, forKey: .maximumParticles),
            maximumAudioVoices: container.decode(Int.self, forKey: .maximumAudioVoices),
            maximumDecodedTextureBytes: container.decode(Int.self, forKey: .maximumDecodedTextureBytes)
        )
    }

    public static func iPhone12Baseline() -> Forge2DPerformanceBudget {
        // These are conservative generation/runtime budgets, not measured device limits.
        // Physical-device telemetry is required before NovaForge labels them measured capacity.
        try! Forge2DPerformanceBudget(
            deviceTarget: .iPhone12Baseline,
            targetFramesPerSecond: 60,
            maximumEntities: 512,
            maximumDynamicBodies: 128,
            maximumParticles: 2_000,
            maximumAudioVoices: 24,
            maximumDecodedTextureBytes: 96 * 1_024 * 1_024
        )
    }
}

public struct Forge2DWorldLoad: Codable, Equatable, Sendable {
    public let entities: Int
    public let dynamicBodies: Int
    public let particles: Int
    public let audioVoices: Int
    public let decodedTextureBytes: Int

    public init(
        entities: Int,
        dynamicBodies: Int,
        particles: Int,
        audioVoices: Int,
        decodedTextureBytes: Int
    ) throws {
        guard entities >= 0,
              dynamicBodies >= 0,
              particles >= 0,
              audioVoices >= 0,
              decodedTextureBytes >= 0,
              dynamicBodies <= entities else {
            throw Forge2DKitError.invalidWorldBudget
        }
        self.entities = entities
        self.dynamicBodies = dynamicBodies
        self.particles = particles
        self.audioVoices = audioVoices
        self.decodedTextureBytes = decodedTextureBytes
    }

    private enum CodingKeys: String, CodingKey { case entities, dynamicBodies, particles, audioVoices, decodedTextureBytes }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            entities: container.decode(Int.self, forKey: .entities),
            dynamicBodies: container.decode(Int.self, forKey: .dynamicBodies),
            particles: container.decode(Int.self, forKey: .particles),
            audioVoices: container.decode(Int.self, forKey: .audioVoices),
            decodedTextureBytes: container.decode(Int.self, forKey: .decodedTextureBytes)
        )
    }

    public func violations(against budget: Forge2DPerformanceBudget) -> [Forge2DBudgetViolation] {
        var result: [Forge2DBudgetViolation] = []
        if entities > budget.maximumEntities { result.append(.entities(actual: entities, maximum: budget.maximumEntities)) }
        if dynamicBodies > budget.maximumDynamicBodies { result.append(.dynamicBodies(actual: dynamicBodies, maximum: budget.maximumDynamicBodies)) }
        if particles > budget.maximumParticles { result.append(.particles(actual: particles, maximum: budget.maximumParticles)) }
        if audioVoices > budget.maximumAudioVoices { result.append(.audioVoices(actual: audioVoices, maximum: budget.maximumAudioVoices)) }
        if decodedTextureBytes > budget.maximumDecodedTextureBytes { result.append(.decodedTextureBytes(actual: decodedTextureBytes, maximum: budget.maximumDecodedTextureBytes)) }
        return result
    }
}

public enum Forge2DBudgetViolation: Equatable, Sendable {
    case entities(actual: Int, maximum: Int)
    case dynamicBodies(actual: Int, maximum: Int)
    case particles(actual: Int, maximum: Int)
    case audioVoices(actual: Int, maximum: Int)
    case decodedTextureBytes(actual: Int, maximum: Int)
}

public struct Forge2DActionID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public enum Forge2DInputSource: Codable, Equatable, Sendable {
    case touchButton(id: String)
    case touchAxis(id: String, minimum: Double, maximum: Double)
    case controllerButton(id: String)
    case controllerAxis(id: String, minimum: Double, maximum: Double)
}

public struct Forge2DInputBinding: Codable, Equatable, Sendable {
    public let id: String
    public let action: Forge2DActionID
    public let source: Forge2DInputSource

    public init(id: String, action: Forge2DActionID, source: Forge2DInputSource) throws {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !action.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Forge2DKitError.emptyIdentifier
        }
        switch source {
        case let .touchAxis(sourceID, minimum, maximum), let .controllerAxis(sourceID, minimum, maximum):
            guard !sourceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  minimum.isFinite,
                  maximum.isFinite,
                  minimum < maximum else {
                throw Forge2DKitError.invalidAxisRange
            }
        case let .touchButton(sourceID), let .controllerButton(sourceID):
            guard !sourceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Forge2DKitError.emptyIdentifier
            }
        }
        self.id = id
        self.action = action
        self.source = source
    }

    private enum CodingKeys: String, CodingKey { case id, action, source }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(String.self, forKey: .id),
            action: container.decode(Forge2DActionID.self, forKey: .action),
            source: container.decode(Forge2DInputSource.self, forKey: .source)
        )
    }
}

public struct Forge2DInputMap: Codable, Equatable, Sendable {
    public let actions: [Forge2DActionID]
    public let bindings: [Forge2DInputBinding]

    public init(actions: [Forge2DActionID], bindings: [Forge2DInputBinding]) throws {
        var actionSet = Set<String>()
        for action in actions {
            let id = action.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { throw Forge2DKitError.emptyIdentifier }
            guard actionSet.insert(id).inserted else { throw Forge2DKitError.duplicateActionID(id) }
        }

        var bindingSet = Set<String>()
        for binding in bindings {
            guard actionSet.contains(binding.action.rawValue) else { throw Forge2DKitError.emptyIdentifier }
            guard bindingSet.insert(binding.id).inserted else { throw Forge2DKitError.duplicateBindingID(binding.id) }
        }
        self.actions = actions
        self.bindings = bindings
    }

    private enum CodingKeys: String, CodingKey { case actions, bindings }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            actions: container.decode([Forge2DActionID].self, forKey: .actions),
            bindings: container.decode([Forge2DInputBinding].self, forKey: .bindings)
        )
    }

    public func normalizedAxisValue(_ value: Double, for bindingID: String) -> Double? {
        guard let binding = bindings.first(where: { $0.id == bindingID }) else { return nil }
        let range: (Double, Double)
        switch binding.source {
        case let .touchAxis(_, minimum, maximum), let .controllerAxis(_, minimum, maximum):
            range = (minimum, maximum)
        default:
            return nil
        }
        guard value.isFinite else { return 0 }
        let clamped = min(max(value, range.0), range.1)
        return ((clamped - range.0) / (range.1 - range.0)) * 2 - 1
    }
}

public struct Forge2DCollisionLayer: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static func singleBit(_ bit: Int) throws -> Forge2DCollisionLayer {
        guard (0..<32).contains(bit) else { throw Forge2DKitError.invalidCollisionLayer }
        return Forge2DCollisionLayer(rawValue: UInt32(1) << UInt32(bit))
    }

    public var isSingleBit: Bool {
        rawValue != 0 && (rawValue & (rawValue - 1)) == 0
    }
}

public struct Forge2DCollisionRule: Codable, Hashable, Sendable {
    public let first: Forge2DCollisionLayer
    public let second: Forge2DCollisionLayer
    public let shouldCollide: Bool

    public init(first: Forge2DCollisionLayer, second: Forge2DCollisionLayer, shouldCollide: Bool) throws {
        guard first.isSingleBit, second.isSingleBit else { throw Forge2DKitError.invalidCollisionLayer }
        if first.rawValue <= second.rawValue {
            self.first = first
            self.second = second
        } else {
            self.first = second
            self.second = first
        }
        self.shouldCollide = shouldCollide
    }

    private enum CodingKeys: String, CodingKey { case first, second, shouldCollide }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            first: container.decode(Forge2DCollisionLayer.self, forKey: .first),
            second: container.decode(Forge2DCollisionLayer.self, forKey: .second),
            shouldCollide: container.decode(Bool.self, forKey: .shouldCollide)
        )
    }
}

public struct Forge2DCollisionTable: Codable, Equatable, Sendable {
    public let rules: [Forge2DCollisionRule]

    public init(rules: [Forge2DCollisionRule]) throws {
        var seen = Set<String>()
        for rule in rules {
            let key = "\(rule.first.rawValue):\(rule.second.rawValue)"
            guard seen.insert(key).inserted else { throw Forge2DKitError.duplicateCollisionRule }
        }
        self.rules = rules.sorted {
            if $0.first.rawValue == $1.first.rawValue { return $0.second.rawValue < $1.second.rawValue }
            return $0.first.rawValue < $1.first.rawValue
        }
    }

    private enum CodingKeys: String, CodingKey { case rules }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(rules: container.decode([Forge2DCollisionRule].self, forKey: .rules))
    }

    public func shouldCollide(_ lhs: Forge2DCollisionLayer, _ rhs: Forge2DCollisionLayer, default defaultValue: Bool = false) -> Bool {
        let low = min(lhs.rawValue, rhs.rawValue)
        let high = max(lhs.rawValue, rhs.rawValue)
        return rules.first(where: { $0.first.rawValue == low && $0.second.rawValue == high })?.shouldCollide ?? defaultValue
    }
}

public struct Forge2DSaveEnvelope: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let projectID: String
    public let slotID: String
    public let sourceRevision: String
    public let payload: Data

    public init(
        schemaVersion: Int = Forge2DSaveEnvelope.currentSchemaVersion,
        projectID: String,
        slotID: String,
        sourceRevision: String,
        payload: Data,
        maximumPayloadBytes: Int = 1_048_576
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion,
              maximumPayloadBytes > 0,
              !projectID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !slotID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !sourceRevision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Forge2DKitError.invalidSaveEnvelope
        }
        guard payload.count <= maximumPayloadBytes else {
            throw Forge2DKitError.savePayloadTooLarge(maximumBytes: maximumPayloadBytes)
        }
        self.schemaVersion = schemaVersion
        self.projectID = projectID
        self.slotID = slotID
        self.sourceRevision = sourceRevision
        self.payload = payload
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, projectID, slotID, sourceRevision, payload }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
            projectID: container.decode(String.self, forKey: .projectID),
            slotID: container.decode(String.self, forKey: .slotID),
            sourceRevision: container.decode(String.self, forKey: .sourceRevision),
            payload: container.decode(Data.self, forKey: .payload)
        )
    }

    public static func decodeValidated(
        _ data: Data,
        expectedProjectID: String,
        expectedSourceRevision: String,
        maximumPayloadBytes: Int = 1_048_576,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> Forge2DSaveEnvelope {
        let decoded = try decoder.decode(Forge2DSaveEnvelope.self, from: data)
        guard decoded.schemaVersion == currentSchemaVersion,
              decoded.projectID == expectedProjectID,
              decoded.sourceRevision == expectedSourceRevision,
              !decoded.slotID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              decoded.payload.count <= maximumPayloadBytes else {
            throw Forge2DKitError.invalidSaveEnvelope
        }
        return decoded
    }
}
