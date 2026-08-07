import SwiftUI

/// Semantic motion roles for NovaForge 2.0.
///
/// Views should choose the *meaning* of a transition rather than inventing
/// arbitrary timings. This keeps Forge, glass chrome, completion, and ambient
/// activity physically coherent while leaving one accessibility/performance
/// policy in charge of whether custom motion may run at all.
enum NovaMotionRole: String, CaseIterable, Sendable {
    /// Immediate acknowledgement after a direct user action.
    case directResponse
    /// Spatial continuity between related surfaces or control states.
    case spatialTransition
    /// Small layout/content reconciliation after state changes.
    case contentSettle
    /// A real accepted completion resolving into its resting state.
    case completion
    /// Nonessential repeating ambience such as a slow energy trace.
    case continuousAmbient

    var isContinuous: Bool {
        self == .continuousAmbient
    }
}

enum NovaMotionAccessibilityMode: Equatable, Sendable {
    /// Full semantic motion is allowed, subject to scene/activity policy.
    case full
    /// The user requested Reduce Motion. Custom NovaForge motion is removed;
    /// state remains legible through layout, text, symbols, and causal haptics.
    case reduced
    /// NovaForge is in a conservative rendering/performance condition.
    case staticOnly
}

/// Pure policy so accessibility/performance decisions can be tested without a
/// SwiftUI renderer. This intentionally fails toward less motion.
enum NovaMotionPolicy {
    static func mode(
        reduceMotion: Bool,
        prefersReducedVisualEffects: Bool,
        allowsDecorativeMotion: Bool
    ) -> NovaMotionAccessibilityMode {
        if prefersReducedVisualEffects || !allowsDecorativeMotion {
            return .staticOnly
        }
        if reduceMotion {
            return .reduced
        }
        return .full
    }

    static func allows(
        _ role: NovaMotionRole,
        mode: NovaMotionAccessibilityMode,
        sceneIsActive: Bool = true
    ) -> Bool {
        guard mode == .full else { return false }
        if role.isContinuous && !sceneIsActive { return false }
        return true
    }
}

/// Shared motion tokens for NovaForge's native-feeling surfaces.
///
/// These are intentionally quick: every tap should acknowledge immediately,
/// spatial changes should settle rather than drift, and completion should
/// resolve without a long cinematic pause. Existing call sites keep their
/// compatibility names while new work can ask for a semantic role directly.
enum NovaMotion {
    static let directResponseDuration: TimeInterval = 0.16
    static let glassArrivalDuration: TimeInterval = 0.38
    static let contentSettleDuration: TimeInterval = 0.24
    static let spatialResponse: TimeInterval = 0.34
    static let completionResponse: TimeInterval = 0.46

    // Keep the one-shot phrase resolve shorter than the normal 110 ms
    // publication cadence so consecutive phrases never stack animations.
    static let phraseArrivalDuration: TimeInterval = 0.095
    static let sheenDuration: TimeInterval = 1.35

    static var directResponse: Animation {
        .smooth(duration: directResponseDuration)
    }

    static var glassArrival: Animation {
        .smooth(duration: glassArrivalDuration)
    }

    static var phraseArrival: Animation {
        .smooth(duration: phraseArrivalDuration)
    }

    static var contentSettle: Animation {
        .smooth(duration: contentSettleDuration)
    }

    static var spatialTransition: Animation {
        .spring(
            response: spatialResponse,
            dampingFraction: 0.88,
            blendDuration: 0.06
        )
    }

    static var completionSettle: Animation {
        .spring(
            response: completionResponse,
            dampingFraction: 0.90,
            blendDuration: 0.08
        )
    }

    /// Compatibility token used by existing Forge/glass call sites.
    static var softSettleSpring: Animation {
        spatialTransition
    }

    static func accessibilityMode(reduceMotion: Bool) -> NovaMotionAccessibilityMode {
        NovaMotionPolicy.mode(
            reduceMotion: reduceMotion,
            prefersReducedVisualEffects: AgentPerformance.prefersReducedVisualEffects,
            allowsDecorativeMotion: AgentPerformance.allowsDecorativeMotion
        )
    }

    /// Compatibility gate for existing custom transitions. Under Reduce Motion
    /// NovaForge does not substitute another spatial animation; the state change
    /// still happens immediately and remains understandable without motion.
    static func enabled(reduceMotion: Bool) -> Bool {
        NovaMotionPolicy.allows(
            .spatialTransition,
            mode: accessibilityMode(reduceMotion: reduceMotion)
        )
    }

    /// Preferred API for new V13 surfaces. Continuous ambience additionally
    /// stops when the scene is inactive so it cannot burn frames in background.
    static func animation(
        for role: NovaMotionRole,
        reduceMotion: Bool,
        sceneIsActive: Bool = true
    ) -> Animation? {
        let mode = accessibilityMode(reduceMotion: reduceMotion)
        guard NovaMotionPolicy.allows(
            role,
            mode: mode,
            sceneIsActive: sceneIsActive
        ) else {
            return nil
        }

        switch role {
        case .directResponse:
            return directResponse
        case .spatialTransition:
            return spatialTransition
        case .contentSettle:
            return contentSettle
        case .completion:
            return completionSettle
        case .continuousAmbient:
            return .linear(duration: sheenDuration).repeatForever(autoreverses: false)
        }
    }
}

/// Pure policy for the bounded live-phrase effect. Keeping the decision out of
/// the view makes accessibility and conservative rendering behavior explicit
/// and testable.
enum LivePhraseEffectMode: Equatable {
    case dustMaterialize
    case fadeOnly
    case none
}

enum LivePhraseEffectPolicy {
    static func mode(
        prefersReducedVisualEffects: Bool,
        usesMatrixTheme: Bool,
        usesConservativeRendering: Bool,
        reduceMotion: Bool,
        reduceTransparency: Bool
    ) -> LivePhraseEffectMode {
        if prefersReducedVisualEffects || usesMatrixTheme || usesConservativeRendering {
            return .none
        }
        if reduceMotion || reduceTransparency {
            return .fadeOnly
        }
        return .dustMaterialize
    }
}

/// Deterministic geometry for the active phrase's one-shot dust resolve.
///
/// There is no particle state, timer, random generator, or repeating loop.
/// The text renderer samples this math while its existing 75-95 ms progress
/// value animates, appends every mote to one Path, and performs one fill.
struct LivePhraseDustGeometry {
    static let maximumParticleCount = 12

    struct Phase: Equatable {
        let textOpacity: Double
        let dustOpacity: Double
        let blurRadius: CGFloat
        let verticalOffset: CGFloat

        var isSettled: Bool {
            textOpacity == 1 && dustOpacity == 0 && blurRadius == 0 && verticalOffset == 0
        }
    }

    struct Particle: Equatable {
        let center: CGPoint
        let radius: CGFloat
    }

    static func phraseSeed(
        responseID: UUID,
        paragraphOrdinal: Int,
        phraseOrdinal: Int
    ) -> UInt64 {
        var seed: UInt64 = 0xcbf29ce484222325
        for byte in responseID.uuidString.utf8 {
            seed ^= UInt64(byte)
            seed &*= 0x100000001b3
        }
        seed = mixedSeed(seed, discriminator: paragraphOrdinal)
        return mixedSeed(seed, discriminator: phraseOrdinal)
    }

    static func mixedSeed(_ seed: UInt64, discriminator: Int) -> UInt64 {
        mix(seed &+ UInt64(bitPattern: Int64(discriminator)) &* 0x9e3779b97f4a7c15)
    }

    static func particleCount(requested: Int) -> Int {
        min(max(requested, 0), maximumParticleCount)
    }

    static func sampledGlyphIndex(
        particleOrdinal: Int,
        glyphCount: Int,
        particleCount: Int
    ) -> Int {
        guard glyphCount > 0, particleCount > 0 else { return 0 }
        let ordinal = min(max(particleOrdinal, 0), particleCount - 1)
        return min(glyphCount - 1, (ordinal * glyphCount) / particleCount)
    }

    static func phase(progress: Double) -> Phase {
        let clamped = min(max(progress, 0), 1)
        let eased = 1 - pow(1 - clamped, 3)
        let dustEnd = 0.82
        let dustProgress = min(clamped / dustEnd, 1)
        let dustOpacity = clamped >= dustEnd
            ? 0
            : 0.58 * pow(1 - dustProgress, 1.35)

        return Phase(
            textOpacity: 0.60 + (0.40 * eased),
            dustOpacity: dustOpacity,
            blurRadius: 0.28 * (1 - eased),
            verticalOffset: 1.4 * (1 - eased)
        )
    }

    static func particle(
        seed: UInt64,
        particleOrdinal: Int,
        targetBounds: CGRect,
        progress: Double
    ) -> Particle {
        let clamped = min(max(progress, 0), 1)
        let eased = 1 - pow(1 - clamped, 3)
        let unitX = randomUnit(seed: seed, stream: particleOrdinal * 5)
        let unitY = randomUnit(seed: seed, stream: particleOrdinal * 5 + 1)
        let direction = randomUnit(seed: seed, stream: particleOrdinal * 5 + 2) * .pi * 2
        let distance = 4 + (3 * randomUnit(seed: seed, stream: particleOrdinal * 5 + 3))
        let radius = 0.6 + (0.9 * randomUnit(seed: seed, stream: particleOrdinal * 5 + 4))

        let insetX = min(targetBounds.width * 0.22, 2.2)
        let insetY = min(targetBounds.height * 0.26, 3.2)
        let target = CGPoint(
            x: targetBounds.midX + ((unitX - 0.5) * insetX * 2),
            y: targetBounds.midY + ((unitY - 0.5) * insetY * 2)
        )
        let unresolved = 1 - eased

        return Particle(
            center: CGPoint(
                x: target.x + (cos(direction) * distance * unresolved),
                y: target.y + (sin(direction) * distance * unresolved)
            ),
            radius: radius
        )
    }

    private static func randomUnit(seed: UInt64, stream: Int) -> Double {
        let value = mix(seed &+ UInt64(stream) &* 0x9e3779b97f4a7c15)
        return Double(value >> 11) / Double(UInt64(1) << 53)
    }

    private static func mix(_ input: UInt64) -> UInt64 {
        var value = input
        value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
        value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
        return value ^ (value >> 31)
    }
}
