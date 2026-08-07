import Foundation
import Testing
@testable import Forge2DKit

@Test func resourceAndEntityIDsRejectEscapesAndWhitespace() throws {
    #expect(throws: Forge2DSceneContractError.invalidIdentifier) { try Forge2DResourceID("../secret.png") }
    #expect(throws: Forge2DSceneContractError.invalidIdentifier) { try Forge2DResourceID("/absolute.png") }
    #expect(throws: Forge2DSceneContractError.invalidIdentifier) { try Forge2DResourceID("sprites//player.png") }
    #expect(throws: Forge2DSceneContractError.invalidIdentifier) { try Forge2DResourceID("https://example.com/player.png") }
    #expect(try Forge2DResourceID("sprites/player..alt.png").rawValue == "sprites/player..alt.png")
    #expect(throws: Forge2DSceneContractError.invalidIdentifier) { try Forge2DEntityID(" player") }
    #expect(try Forge2DResourceID("sprites/player.png").rawValue == "sprites/player.png")
}

@Test func spriteDescriptorValidatesGeometryAndLayer() throws {
    let entity = try Forge2DEntityID("player")
    let resource = try Forge2DResourceID("sprites/player.png")
    let transform = try Forge2DTransform()
    let sprite = try Forge2DSpriteDescriptor(
        entityID: entity,
        resourceID: resource,
        transform: transform,
        size: Forge2DVector(x: 64, y: 64)
    )
    #expect(sprite.anchor == Forge2DVector(x: 0.5, y: 0.5))

    #expect(throws: Forge2DSceneContractError.invalidSprite) {
        try Forge2DSpriteDescriptor(
            entityID: entity,
            resourceID: resource,
            transform: transform,
            size: .zero
        )
    }
}

@Test func transformDecodeCannotBypassValidation() throws {
    let invalidScale = Data(#"{"position":{"x":0,"y":0},"rotationRadians":0,"scale":{"x":0,"y":1}}"#.utf8)
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(Forge2DTransform.self, from: invalidScale)
    }

    let decoder = JSONDecoder()
    decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "INF", negativeInfinity: "-INF", nan: "NaN")
    let invalidPosition = Data(#"{"position":{"x":"NaN","y":0},"rotationRadians":0,"scale":{"x":1,"y":1}}"#.utf8)
    #expect(throws: DecodingError.self) {
        try decoder.decode(Forge2DTransform.self, from: invalidPosition)
    }
}

@Test func audioCueValidatesGainAndPausePolicy() throws {
    let cue = try Forge2DAudioCue(
        resourceID: Forge2DResourceID("audio/engine.wav"),
        role: .effect,
        gain: 0.8,
        loops: true,
        pausesWithSimulation: true
    )
    #expect(cue.gain == 0.8)
    #expect(cue.pausesWithSimulation)

    #expect(throws: Forge2DSceneContractError.invalidAudioCue) {
        try Forge2DAudioCue(resourceID: Forge2DResourceID("audio/engine.wav"), role: .effect, gain: 1.01)
    }
}

@Test func particleEmitterRejectsUnboundedSteadyState() throws {
    let entity = try Forge2DEntityID("dust")
    #expect(throws: Forge2DSceneContractError.invalidParticleEmitter) {
        try Forge2DParticleEmitter(
            entityID: entity,
            emissionRatePerSecond: 5_000,
            particleLifetimeSeconds: 10,
            maxLiveParticles: 100
        )
    }

    let bounded = try Forge2DParticleEmitter(
        entityID: entity,
        emissionRatePerSecond: 20,
        particleLifetimeSeconds: 2,
        maxLiveParticles: 100
    )
    #expect(bounded.maxLiveParticles == 100)
}

@Test func runStateMakesPauseAndBackgroundAuthorityExplicit() {
    #expect(Forge2DRunState.running.shouldAdvanceSimulation)
    #expect(Forge2DRunState.running.acceptsGameplayInput)
    #expect(!Forge2DRunState.paused.shouldAdvanceSimulation)
    #expect(!Forge2DRunState.paused.acceptsGameplayInput)
    #expect(Forge2DRunState.paused.shouldAdvancePauseIndependentAudio)
    #expect(!Forge2DRunState.backgrounded.shouldAdvancePauseIndependentAudio)
}

@Test func sceneManifestRejectsDuplicateEntityAuthority() throws {
    let entity = try Forge2DEntityID("shared")
    let resource = try Forge2DResourceID("sprites/shared.png")
    let sprite = try Forge2DSpriteDescriptor(
        entityID: entity,
        resourceID: resource,
        transform: Forge2DTransform(),
        size: Forge2DVector(x: 32, y: 32)
    )
    let emitter = try Forge2DParticleEmitter(
        entityID: entity,
        emissionRatePerSecond: 10,
        particleLifetimeSeconds: 1,
        maxLiveParticles: 20
    )

    #expect(throws: Forge2DSceneContractError.duplicateEntityID) {
        try Forge2DSceneManifest(sprites: [sprite], particleEmitters: [emitter])
    }
}

@Test func sceneManifestRoundTripsThroughValidatedDecode() throws {
    let sprite = try Forge2DSpriteDescriptor(
        entityID: Forge2DEntityID("player"),
        resourceID: Forge2DResourceID("sprites/player.png"),
        transform: Forge2DTransform(position: Forge2DVector(x: 12, y: 18)),
        size: Forge2DVector(x: 48, y: 48),
        layer: 4
    )
    let audio = try Forge2DAudioCue(
        resourceID: Forge2DResourceID("audio/theme.m4a"),
        role: .music,
        gain: 0.7,
        loops: true,
        pausesWithSimulation: false
    )
    let manifest = try Forge2DSceneManifest(sprites: [sprite], audioCues: [audio])
    let encoded = try JSONEncoder().encode(manifest)
    #expect(try JSONDecoder().decode(Forge2DSceneManifest.self, from: encoded) == manifest)
}

private struct OversizedScenePayload: Encodable {
    let sprites: [Forge2DSpriteDescriptor]
    let audioCues: [Forge2DAudioCue] = []
    let particleEmitters: [Forge2DParticleEmitter] = []
}

@Test func sceneManifestDecodeRejectsOversizedCollection() throws {
    let sprite = try Forge2DSpriteDescriptor(
        entityID: Forge2DEntityID("template"),
        resourceID: Forge2DResourceID("sprites/template.png"),
        transform: Forge2DTransform(),
        size: Forge2DVector(x: 1, y: 1)
    )
    let oversized = Array(repeating: sprite, count: Forge2DSceneManifest.maxSpriteCount + 1)
    let encoded = try JSONEncoder().encode(OversizedScenePayload(sprites: oversized))
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(Forge2DSceneManifest.self, from: encoded)
    }
}
