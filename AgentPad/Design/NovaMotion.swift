import SwiftUI

/// Shared motion tokens for NovaForge's native-feeling Liquid Glass surfaces.
///
/// Keep animation timing centralized so live chat, glass chrome, and proof gates
/// can stay consistent while still respecting accessibility and performance
/// modes. The values lean smooth/subtle rather than flashy: the UI should feel
/// like it condenses into place, never like a cursor/progress-line gimmick.
enum NovaMotion {
    static let glassArrivalDuration: TimeInterval = 0.54
    static let phraseArrivalDuration: TimeInterval = 0.22
    static let phraseStagger: TimeInterval = 0.018
    static let dustLifetime: TimeInterval = 0.72
    static let sheenDuration: TimeInterval = 1.35

    static var glassArrival: Animation {
        .smooth(duration: glassArrivalDuration)
    }

    static var phraseArrival: Animation {
        .smooth(duration: phraseArrivalDuration)
    }

    static var dustFade: Animation {
        .easeOut(duration: dustLifetime)
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
