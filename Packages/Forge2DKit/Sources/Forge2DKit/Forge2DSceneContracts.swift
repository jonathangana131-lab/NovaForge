import Foundation

public enum Forge2DSceneContractError: Error, Equatable, Sendable {
    case invalidIdentifier
    case invalidTransform
    case invalidSprite
    case invalidAudioCue
    case invalidParticleEmitter
    case duplicateEntityID
    case sceneTooLarge
}

public struct Forge2DResourceID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let pathComponents = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard trimmed == rawValue,
              !trimmed.isEmpty,
              trimmed.count <= 160,
              !trimmed.hasPrefix("/"),
              !trimmed.contains("\\"),
              pathComponents.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw Forge2DSceneContractError.invalidIdentifier
        }
        self.rawValue = trimmed
    }

    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        do {
            try self.init(rawValue)
        } catch {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid Forge2D resource identifier")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct Forge2DEntityID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == rawValue,
              !trimmed.isEmpty,
              trimmed.count <= 96,
              !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw Forge2DSceneContractError.invalidIdentifier
        }
        self.rawValue = trimmed
    }

    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        do {
            try self.init(rawValue)
        } catch {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid Forge2D entity identifier")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct Forge2DTransform: Codable, Hashable, Sendable {
    public let position: Forge2DVector
    public let rotationRadians: Double
    public let scale: Forge2DVector

    public init(
        position: Forge2DVector = .zero,
        rotationRadians: Double = 0,
        scale: Forge2DVector = Forge2DVector(x: 1, y: 1)
    ) throws {
        guard position.x.isFinite, position.y.isFinite,
              rotationRadians.isFinite,
              scale.x.isFinite, scale.y.isFinite,
              scale.x > 0, scale.y > 0,
              scale.x <= 1_000, scale.y <= 1_000 else {
            throw Forge2DSceneContractError.invalidTransform
        }
        self.position = position
        self.rotationRadians = rotationRadians
        self.scale = scale
    }

    private enum CodingKeys: String, CodingKey { case position, rotationRadians, scale }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                position: container.decode(Forge2DVector.self, forKey: .position),
                rotationRadians: container.decode(Double.self, forKey: .rotationRadians),
                scale: container.decode(Forge2DVector.self, forKey: .scale)
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorruptedError(forKey: .scale, in: container, debugDescription: "Invalid Forge2D transform")
        }
    }
}

public struct Forge2DSpriteDescriptor: Codable, Hashable, Sendable {
    public let entityID: Forge2DEntityID
    public let resourceID: Forge2DResourceID
    public let transform: Forge2DTransform
    public let size: Forge2DVector
    public let anchor: Forge2DVector
    public let layer: Int

    public init(
        entityID: Forge2DEntityID,
        resourceID: Forge2DResourceID,
        transform: Forge2DTransform,
        size: Forge2DVector,
        anchor: Forge2DVector = Forge2DVector(x: 0.5, y: 0.5),
        layer: Int = 0
    ) throws {
        guard size.x.isFinite, size.y.isFinite,
              size.x > 0, size.y > 0,
              size.x <= 16_384, size.y <= 16_384,
              anchor.x.isFinite, anchor.y.isFinite,
              (0...1).contains(anchor.x), (0...1).contains(anchor.y),
              (-4_096...4_096).contains(layer) else {
            throw Forge2DSceneContractError.invalidSprite
        }
        self.entityID = entityID
        self.resourceID = resourceID
        self.transform = transform
        self.size = size
        self.anchor = anchor
        self.layer = layer
    }

    private enum CodingKeys: String, CodingKey { case entityID, resourceID, transform, size, anchor, layer }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                entityID: container.decode(Forge2DEntityID.self, forKey: .entityID),
                resourceID: container.decode(Forge2DResourceID.self, forKey: .resourceID),
                transform: container.decode(Forge2DTransform.self, forKey: .transform),
                size: container.decode(Forge2DVector.self, forKey: .size),
                anchor: container.decode(Forge2DVector.self, forKey: .anchor),
                layer: container.decode(Int.self, forKey: .layer)
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorruptedError(forKey: .size, in: container, debugDescription: "Invalid Forge2D sprite descriptor")
        }
    }
}

public enum Forge2DAudioRole: String, Codable, CaseIterable, Sendable {
    case effect
    case music
    case ambient
}

public struct Forge2DAudioCue: Codable, Hashable, Sendable {
    public let resourceID: Forge2DResourceID
    public let role: Forge2DAudioRole
    public let gain: Double
    public let loops: Bool
    public let pausesWithSimulation: Bool

    public init(
        resourceID: Forge2DResourceID,
        role: Forge2DAudioRole,
        gain: Double = 1,
        loops: Bool = false,
        pausesWithSimulation: Bool = true
    ) throws {
        guard gain.isFinite, (0...1).contains(gain) else {
            throw Forge2DSceneContractError.invalidAudioCue
        }
        self.resourceID = resourceID
        self.role = role
        self.gain = gain
        self.loops = loops
        self.pausesWithSimulation = pausesWithSimulation
    }

    private enum CodingKeys: String, CodingKey { case resourceID, role, gain, loops, pausesWithSimulation }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                resourceID: container.decode(Forge2DResourceID.self, forKey: .resourceID),
                role: container.decode(Forge2DAudioRole.self, forKey: .role),
                gain: container.decode(Double.self, forKey: .gain),
                loops: container.decode(Bool.self, forKey: .loops),
                pausesWithSimulation: container.decode(Bool.self, forKey: .pausesWithSimulation)
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorruptedError(forKey: .gain, in: container, debugDescription: "Invalid Forge2D audio cue")
        }
    }
}

public struct Forge2DParticleEmitter: Codable, Hashable, Sendable {
    public let entityID: Forge2DEntityID
    public let resourceID: Forge2DResourceID?
    public let emissionRatePerSecond: Double
    public let particleLifetimeSeconds: Double
    public let maxLiveParticles: Int
    public let pausesWithSimulation: Bool

    public init(
        entityID: Forge2DEntityID,
        resourceID: Forge2DResourceID? = nil,
        emissionRatePerSecond: Double,
        particleLifetimeSeconds: Double,
        maxLiveParticles: Int,
        pausesWithSimulation: Bool = true
    ) throws {
        guard emissionRatePerSecond.isFinite,
              particleLifetimeSeconds.isFinite,
              emissionRatePerSecond >= 0, emissionRatePerSecond <= 10_000,
              particleLifetimeSeconds > 0, particleLifetimeSeconds <= 60,
              (0...20_000).contains(maxLiveParticles),
              emissionRatePerSecond * particleLifetimeSeconds <= Double(maxLiveParticles) else {
            throw Forge2DSceneContractError.invalidParticleEmitter
        }
        self.entityID = entityID
        self.resourceID = resourceID
        self.emissionRatePerSecond = emissionRatePerSecond
        self.particleLifetimeSeconds = particleLifetimeSeconds
        self.maxLiveParticles = maxLiveParticles
        self.pausesWithSimulation = pausesWithSimulation
    }

    private enum CodingKeys: String, CodingKey {
        case entityID, resourceID, emissionRatePerSecond, particleLifetimeSeconds, maxLiveParticles, pausesWithSimulation
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                entityID: container.decode(Forge2DEntityID.self, forKey: .entityID),
                resourceID: container.decodeIfPresent(Forge2DResourceID.self, forKey: .resourceID),
                emissionRatePerSecond: container.decode(Double.self, forKey: .emissionRatePerSecond),
                particleLifetimeSeconds: container.decode(Double.self, forKey: .particleLifetimeSeconds),
                maxLiveParticles: container.decode(Int.self, forKey: .maxLiveParticles),
                pausesWithSimulation: container.decode(Bool.self, forKey: .pausesWithSimulation)
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorruptedError(forKey: .emissionRatePerSecond, in: container, debugDescription: "Invalid Forge2D particle emitter")
        }
    }
}

public enum Forge2DRunState: String, Codable, CaseIterable, Sendable {
    case running
    case paused
    case backgrounded

    public var shouldAdvanceSimulation: Bool { self == .running }
    public var acceptsGameplayInput: Bool { self == .running }
    public var shouldAdvancePauseIndependentAudio: Bool { self != .backgrounded }
}

public struct Forge2DSceneManifest: Codable, Equatable, Sendable {
    public static let maxSpriteCount = 4_096
    public static let maxAudioCueCount = 256
    public static let maxEmitterCount = 512

    public let sprites: [Forge2DSpriteDescriptor]
    public let audioCues: [Forge2DAudioCue]
    public let particleEmitters: [Forge2DParticleEmitter]

    public init(
        sprites: [Forge2DSpriteDescriptor] = [],
        audioCues: [Forge2DAudioCue] = [],
        particleEmitters: [Forge2DParticleEmitter] = []
    ) throws {
        guard sprites.count <= Self.maxSpriteCount,
              audioCues.count <= Self.maxAudioCueCount,
              particleEmitters.count <= Self.maxEmitterCount else {
            throw Forge2DSceneContractError.sceneTooLarge
        }

        let entityIDs = sprites.map(\.entityID) + particleEmitters.map(\.entityID)
        guard Set(entityIDs).count == entityIDs.count else {
            throw Forge2DSceneContractError.duplicateEntityID
        }

        self.sprites = sprites
        self.audioCues = audioCues
        self.particleEmitters = particleEmitters
    }

    private enum CodingKeys: String, CodingKey { case sprites, audioCues, particleEmitters }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                sprites: container.decode([Forge2DSpriteDescriptor].self, forKey: .sprites),
                audioCues: container.decode([Forge2DAudioCue].self, forKey: .audioCues),
                particleEmitters: container.decode([Forge2DParticleEmitter].self, forKey: .particleEmitters)
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorruptedError(forKey: .sprites, in: container, debugDescription: "Invalid Forge2D scene manifest")
        }
    }
}
