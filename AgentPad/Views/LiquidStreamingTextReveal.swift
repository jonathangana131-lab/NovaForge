import SwiftUI

/// Live response text that keeps the semantic word-tree renderer stable while
/// giving each active phrase a subtle Liquid Glass materialization treatment.
///
/// The text itself stays a single SwiftUI `Text` run for wrapping/performance;
/// motion is layered as tiny opacity/blur settling plus a deterministic dust
/// overlay so we never reintroduce cursor/progress-line artifacts.
struct LiquidStreamingTextReveal: View {
    let frame: ForgeLiveFeedFrame

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lastAnimatedRevision = -1
    @State private var phraseSettled = true

    private var motionEnabled: Bool {
        NovaMotion.enabled(reduceMotion: reduceMotion)
    }

    private var hasAnimatedTail: Bool {
        motionEnabled &&
            !frame.activeTail.isEmpty &&
            frame.displayText.hasSuffix(frame.activeTail)
    }

    private var flowingText: Text {
        guard !frame.displayText.isEmpty else {
            return Text(" ").foregroundColor(AgentPalette.ink)
        }
        guard !AgentPerformance.prefersReducedVisualEffects,
              !frame.activeTail.isEmpty,
              frame.displayText.hasSuffix(frame.activeTail) else {
            return Text(frame.displayText).foregroundColor(AgentPalette.ink)
        }

        let settledEnd = frame.displayText.index(
            frame.displayText.endIndex,
            offsetBy: -frame.activeTail.count
        )
        let settledPrefix = String(frame.displayText[..<settledEnd])
        var attributed = AttributedString(settledPrefix)
        attributed.foregroundColor = AgentPalette.ink

        var highlightedTail = AttributedString(frame.activeTail)
        highlightedTail.foregroundColor = AgentPalette.primaryAccent.opacity(motionEnabled ? 0.96 : 0.82)
        attributed.append(highlightedTail)
        return Text(attributed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            flowingText
                .font(.system(size: 16, weight: .regular, design: AgentPalette.interfaceFontDesign))
                .lineSpacing(5)
                .accessibilityIdentifier("streamingTextReveal")
                .accessibilityValue("\(frame.characterCount) characters, \(frame.backlogCharacters) queued")
                .opacity(hasAnimatedTail ? (phraseSettled ? 1 : 0.985) : 1)
                .blur(radius: hasAnimatedTail ? (phraseSettled ? 0 : 0.28) : 0)
                .scaleEffect(hasAnimatedTail ? (phraseSettled ? 1 : 0.999) : 1, anchor: .leading)
                .animation(hasAnimatedTail ? NovaMotion.phraseArrival : nil, value: phraseSettled)
                .overlay(alignment: .bottomLeading) {
                    LiquidPhraseDustLayer(
                        revision: frame.revision,
                        activeTail: frame.activeTail,
                        enabled: hasAnimatedTail
                    )
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
                .transaction { transaction in
                    // LiveStreamBuffer already paces semantic text frames. Avoid
                    // implicit layout interpolation that can make the transcript
                    // feel rubbery or break bottom-pinning under XCTest.
                    transaction.animation = nil
                }

            Text("characters \(frame.characterCount) queued \(frame.backlogCharacters)")
                .font(.system(size: 1, weight: .regular, design: AgentPalette.interfaceFontDesign))
                .frame(width: 1, height: 1, alignment: .leading)
                .opacity(0.01)
                .accessibilityIdentifier("streamingTextRevealMetrics")
                .accessibilityLabel("characters \(frame.characterCount) queued \(frame.backlogCharacters)")
                .accessibilityValue("characters \(frame.characterCount) queued \(frame.backlogCharacters)")
        }
        .onAppear(perform: materializeCurrentRevision)
        .onChange(of: frame.revision) { _, _ in
            materializeCurrentRevision()
        }
    }

    private func materializeCurrentRevision() {
        guard lastAnimatedRevision != frame.revision else { return }
        lastAnimatedRevision = frame.revision
        guard hasAnimatedTail else {
            phraseSettled = true
            return
        }
        phraseSettled = false
        DispatchQueue.main.async {
            guard lastAnimatedRevision == frame.revision else { return }
            withAnimation(NovaMotion.phraseArrival) {
                phraseSettled = true
            }
        }
    }
}

struct LiquidPhraseDustLayer: View {
    let revision: Int
    let activeTail: String
    let enabled: Bool

    var body: some View {
        if enabled && !activeTail.isEmpty {
            GeometryReader { proxy in
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                    Canvas { context, size in
                        let renderSize = CGSize(
                            width: max(size.width, proxy.size.width, 1),
                            height: max(size.height, min(max(proxy.size.height, 22), 68))
                        )
                        let time = timeline.date.timeIntervalSinceReferenceDate
                        let particles = LiquidPhraseDustSeed.particles(for: revision, text: activeTail)
                        for particle in particles {
                            var particleContext = context
                            let lifetime = max(NovaMotion.dustLifetime, 0.1)
                            let age = (time + particle.phase)
                                .truncatingRemainder(dividingBy: lifetime) / lifetime
                            let fade = max(0, sin(age * .pi))
                            let x = renderSize.width * particle.x + CGFloat(age) * particle.driftX
                            let y = renderSize.height * particle.y - CGFloat(age) * particle.lift
                            let rect = CGRect(x: x, y: y, width: particle.size, height: particle.size)
                            particleContext.opacity = particle.opacity * fade
                            particleContext.fill(Path(ellipseIn: rect), with: .color(particle.color))
                        }
                    }
                    .blendMode(.screen)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 64, alignment: .bottomLeading)
            .id(revision)
            .transition(.opacity)
        }
    }
}

private struct LiquidPhraseDustParticle {
    let x: CGFloat
    let y: CGFloat
    let size: CGFloat
    let driftX: CGFloat
    let lift: CGFloat
    let opacity: Double
    let phase: Double
    let color: Color
}

private enum LiquidPhraseDustSeed {
    static func particles(for revision: Int, text: String) -> [LiquidPhraseDustParticle] {
        let base = abs(revision * 31 + text.count * 17 + text.unicodeScalars.prefix(5).reduce(0) { $0 + Int($1.value) })
        let count = min(12, max(6, text.count / 4))
        return (0..<count).map { index in
            let value = base + index * 73
            return LiquidPhraseDustParticle(
                x: CGFloat(Double((value * 37) % 100) / 100.0),
                y: CGFloat(0.28 + Double((value * 19) % 52) / 100.0),
                size: CGFloat(1.0 + Double((value * 11) % 14) / 10.0),
                driftX: CGFloat(-7 + (value * 13) % 15),
                lift: CGFloat(5 + (value * 29) % 16),
                opacity: 0.10 + Double((value * 7) % 14) / 100.0,
                phase: Double((value * 5) % 100) / 100.0,
                color: index.isMultiple(of: 3) ? .white : AgentPalette.primaryAccent
            )
        }
    }
}

struct LiquidResponseEntranceModifier: ViewModifier {
    let enabled: Bool
    @State private var appeared = false

    func body(content: Content) -> some View {
        content
            .opacity(!enabled || appeared ? 1 : 0)
            .blur(radius: !enabled || appeared ? 0 : 7)
            .scaleEffect(!enabled || appeared ? 1 : 0.986, anchor: .bottomLeading)
            .offset(y: !enabled || appeared ? 0 : 10)
            .animation(enabled ? NovaMotion.glassArrival : nil, value: appeared)
            .onAppear {
                if enabled {
                    appeared = true
                } else {
                    appeared = true
                }
            }
    }
}

extension View {
    func liquidResponseEntrance(enabled: Bool) -> some View {
        modifier(LiquidResponseEntranceModifier(enabled: enabled))
    }
}
