import SwiftUI

/// Shared motion tokens for NovaForge's native-feeling Liquid Glass surfaces.
///
/// Keep animation timing centralized so live chat, glass chrome, and proof gates
/// can stay consistent while still respecting accessibility and performance
/// modes. The values lean smooth/subtle rather than flashy: the UI should feel
/// like it condenses into place, never like a cursor/progress-line gimmick.
enum NovaMotion {
    static let glassArrivalDuration: TimeInterval = 0.54
    // Keep the one-shot phrase resolve shorter than the normal 110 ms
    // publication cadence so consecutive phrases never stack animations.
    static let phraseArrivalDuration: TimeInterval = 0.095
    static let sheenDuration: TimeInterval = 1.35

    static var glassArrival: Animation {
        .smooth(duration: glassArrivalDuration)
    }

    static var phraseArrival: Animation {
        .smooth(duration: phraseArrivalDuration)
    }

    static var softSettleSpring: Animation {
        .spring(response: 0.42, dampingFraction: 0.86, blendDuration: 0.10)
    }

    static func enabled(reduceMotion: Bool) -> Bool {
        AgentPerformance.allowsDecorativeMotion &&
            !AgentPerformance.prefersReducedVisualEffects &&
            !reduceMotion
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

// MARK: - Forge Plan Space

/// Build depth is deliberately separate from provider reasoning effort. These
/// values describe the product work NovaForge should perform around a mission;
/// they never pretend that a model exposes a native reasoning parameter.
enum ForgeBuildDepth: String, CaseIterable, Identifiable, Equatable, Sendable {
    case prototype
    case polished
    case obsessive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .prototype: "Prototype"
        case .polished: "Polished"
        case .obsessive: "Go Crazy"
        }
    }

    var symbol: String {
        switch self {
        case .prototype: "bolt.fill"
        case .polished: "checkmark.seal.fill"
        case .obsessive: "sparkles"
        }
    }

    var impact: String {
        switch self {
        case .prototype:
            "Build, basic test, and get to a runnable result quickly."
        case .polished:
            "Build, test, run, inspect, repair, and cover accessibility basics."
        case .obsessive:
            "Deep architecture, adversarial tests, runtime inspection, performance, accessibility, and repeated polish."
        }
    }
}

/// Creativity changes how freely NovaForge may reinterpret the user's intent.
/// It is a planning choice, not permission to ignore product or safety rules.
enum ForgeCreativity: String, CaseIterable, Identifiable, Equatable, Sendable {
    case faithful
    case inventive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .faithful: "Faithful"
        case .inventive: "Inventive"
        }
    }

    var symbol: String {
        switch self {
        case .faithful: "scope"
        case .inventive: "wand.and.stars"
        }
    }

    var impact: String {
        switch self {
        case .faithful:
            "Stay close to the request and make conservative product choices."
        case .inventive:
            "Protect the goal, but explore stronger original product and visual ideas."
        }
    }
}

/// A small, truthful first-generation Plan Space contract. The draft remains
/// editable until the user explicitly hands it back to the normal Forge
/// composer; this layer does not create a run or mutate a workspace itself.
struct ForgePlanSpaceDraft: Equatable, Sendable {
    var intent = ""
    var buildDepth: ForgeBuildDepth?
    var creativity: ForgeCreativity?

    var trimmedIntent: String {
        intent.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var answeredDecisionCount: Int {
        (buildDepth == nil ? 0 : 1) + (creativity == nil ? 0 : 1)
    }

    var isReady: Bool {
        !trimmedIntent.isEmpty && buildDepth != nil && creativity != nil
    }

    var compactSummary: String {
        let depth = buildDepth?.title ?? "Choose depth"
        let creativity = creativity?.title ?? "Choose creativity"
        return "\(depth) · \(creativity)"
    }

    mutating func decideForMe() {
        buildDepth = .polished
        creativity = .faithful
    }

    var composerHandoff: String? {
        guard let buildDepth, let creativity, !trimmedIntent.isEmpty else {
            return nil
        }
        return [
            trimmedIntent,
            "",
            "NovaForge build preferences:",
            "- Build depth: \(buildDepth.title) — \(buildDepth.impact)",
            "- Creativity: \(creativity.title) — \(creativity.impact)",
        ].joined(separator: "\n")
    }

    static var debugDemo: ForgePlanSpaceDraft {
        ForgePlanSpaceDraft(
            intent: "Build a touch-first driving game that feels excellent on iPhone.",
            buildDepth: .polished,
            creativity: .inventive
        )
    }
}
