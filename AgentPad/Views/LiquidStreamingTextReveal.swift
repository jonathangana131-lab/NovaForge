import SwiftUI

/// Marks the one phrase that is still forming. The renderer queries this
/// attribute directly, so ligatures, emoji, RTL text, and wrapping never rely
/// on fragile `String.Index` to glyph-index conversion.
private struct LiveActivePhraseAttribute: TextAttribute {}

/// NovaForge's live answer is an open reading field, not a chat bubble.
///
/// Paragraphs and frozen segments keep stable ordinal identity. Only the
/// bounded tail of the current paragraph is rebuilt as a new semantic phrase
/// arrives, and only its newest phrase receives the optical materialization.
struct LiveTranscriptView: View {
    let snapshot: LiveTranscriptSnapshot
    let showsActivity: Bool

    @ScaledMetric(relativeTo: .body) private var paragraphSpacing: CGFloat = 14
    @State private var accessibleTranscript = ""
    @State private var lastAccessibilityStructureKey = ""

    private var showsActiveRow: Bool {
        showsActivity ||
            !snapshot.activeParagraph.settledSegments.isEmpty ||
            !snapshot.activeParagraph.settledTail.isEmpty ||
            snapshot.activeParagraph.activePhrase != nil
    }

    private var accessibilityStatus: String {
        if !showsActivity { return "Response complete" }
        return snapshot.cadence.statusLine
    }

    private var accessibilityStructureKey: String {
        "\(snapshot.responseID.uuidString)-\(snapshot.settledParagraphs.count)-\(snapshot.activeParagraph.ordinal)-\(snapshot.activeParagraph.settledSegments.count)"
    }

    private var activePhraseEndsSemanticBoundary: Bool {
        guard let text = snapshot.activeParagraph.activePhrase?.text else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.last?.isNewline == true { return true }
        guard let last = trimmed.last else { return false }
        return ".!?\u{2026}\u{3002}\u{FF01}\u{FF1F}".contains(last)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: paragraphSpacing) {
            ForEach(snapshot.settledParagraphs) { paragraph in
                if !paragraph.text.isEmpty {
                    LiveSettledParagraphRow(paragraph: paragraph)
                }
            }

            if showsActiveRow {
                LiveActiveParagraphRow(
                    paragraph: snapshot.activeParagraph,
                    cadence: snapshot.cadence,
                    showsActivity: showsActivity
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The custom renderer is visual only. VoiceOver gets one coherent
        // response value rather than a separate stop for every phrase/bead.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibleTranscript.isEmpty ? "Preparing response" : accessibleTranscript)
        .accessibilityValue(accessibilityStatus)
        .accessibilityHint("NovaForge response.")
        .accessibilityIdentifier("liveResponseTranscript")
        .task(id: snapshot.responseID) {
            accessibleTranscript = ""
            lastAccessibilityStructureKey = accessibilityStructureKey
            publishAccessibilityCheckpoint(force: !showsActivity)
        }
        .onChange(of: snapshot.revision) {
            publishAccessibilityCheckpoint()
        }
        .onChange(of: showsActivity) {
            publishAccessibilityCheckpoint(force: !showsActivity)
        }
    }

    /// VoiceOver receives the first readable phrase, then updates only at
    /// sentence/paragraph/segment boundaries. Completion always publishes the
    /// exact final transcript instead of changing a multi-thousand-character
    /// accessibility label on every visual frame.
    private func publishAccessibilityCheckpoint(force: Bool = false) {
        let hasFirstReadableText = accessibleTranscript.isEmpty && !snapshot.visibleText.isEmpty
        let structureChanged = lastAccessibilityStructureKey != accessibilityStructureKey
        guard force || hasFirstReadableText || structureChanged || activePhraseEndsSemanticBoundary else {
            return
        }
        // Growing prefixes are ephemeral. Parsing them through the durable
        // settled-row cache would insert a new overlapping document at every
        // sentence boundary and evict the rows that actually benefit from reuse.
        accessibleTranscript = assistantLiveMarkdownPresentation(snapshot.visibleText).accessibilityText
        lastAccessibilityStructureKey = accessibilityStructureKey
    }
}

private struct LiveSettledParagraphRow: View {
    let paragraph: LiveTranscriptSnapshot.Paragraph

    @ScaledMetric(relativeTo: .body) private var lineSpacing: CGFloat = 5

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Color.clear
                .frame(width: 24, height: 1)
                .accessibilityHidden(true)

            Text(assistantMarkdownPresentation(paragraph.text).attributedText)
                .font(.system(.body, design: .default, weight: .regular))
                .lineSpacing(lineSpacing)
                .foregroundStyle(AgentPalette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LiveActiveParagraphRow: View {
    let paragraph: LiveTranscriptSnapshot.ActiveParagraph
    let cadence: LiveTranscriptSnapshot.Cadence
    let showsActivity: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(paragraph.settledSegments) { segment in
                LiveSettledSegmentRow(segment: segment)
            }

            HStack(alignment: .top, spacing: 9) {
                LiveTranscriptBead(isVisible: showsActivity)
                    .frame(width: 24)
                    .frame(minHeight: 22, alignment: .top)

                if paragraph.settledTail.isEmpty, paragraph.activePhrase == nil {
                    Color.clear
                        .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                        .accessibilityHidden(true)
                } else {
                    LiveActivePhraseText(
                        settledTail: paragraph.settledTail,
                        activePhrase: paragraph.activePhrase,
                        cadence: cadence
                    )
                    // New phrase identity resets only the bounded active leaf.
                    // Frozen segment siblings never replay or re-layout.
                    .id(paragraph.activePhrase?.id)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LiveSettledSegmentRow: View {
    let segment: LiveTranscriptSnapshot.SettledSegment

    @ScaledMetric(relativeTo: .body) private var lineSpacing: CGFloat = 5

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Color.clear
                .frame(width: 24, height: 1)
                .accessibilityHidden(true)

            Group {
                if let fallback = segment.fallbackPresentationText {
                    Text(verbatim: fallback)
                } else {
                    Text(assistantMarkdownPresentation(segment.text).attributedText)
                }
            }
            .font(.system(.body, design: .default, weight: .regular))
            .lineSpacing(lineSpacing)
            .foregroundStyle(AgentPalette.ink)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LiveActivePhraseText: View {
    let settledTail: String
    let activePhrase: LiveTranscriptSnapshot.Phrase?
    let cadence: LiveTranscriptSnapshot.Cadence

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ScaledMetric(relativeTo: .body) private var lineSpacing: CGFloat = 5
    @State private var progress = 0.0

    private var effectMode: LivePhraseEffectMode {
        LivePhraseEffectPolicy.mode(
            prefersReducedVisualEffects: AgentPerformance.prefersReducedVisualEffects,
            usesMatrixTheme: AgentTheme.current == .matrixRain,
            usesConservativeRendering: AgentPlatformCompatibility.usesConservativeRendering,
            reduceMotion: reduceMotion,
            reduceTransparency: reduceTransparency
        )
    }

    private var animationDuration: TimeInterval {
        switch effectMode {
        case .none:
            return 0
        case .fadeOnly:
            return 0.10
        case .dustMaterialize:
            switch cadence {
            case .catchingUp, .burst:
                return 0.075
            case .idle, .reading:
                return NovaMotion.phraseArrivalDuration
            }
        }
    }

    private var dustSeed: UInt64 {
        guard let id = activePhrase?.id else { return 0 }
        return LivePhraseDustGeometry.phraseSeed(
            responseID: id.responseID,
            paragraphOrdinal: id.paragraphOrdinal,
            phraseOrdinal: id.ordinal
        )
    }

    private var renderedText: Text {
        guard let activePhrase else {
            return Text(assistantMarkdownPresentation(settledTail).attributedText)
        }

        // Parse one combined leaf. Provider chunks routinely split inside an
        // inline-code filename or emphasis delimiter; parsing the two halves
        // independently makes punctuation flash and then reflow on completion.
        let source = settledTail + activePhrase.text
        let presentation = assistantLiveMarkdownPresentation(source)
        let attributed = presentation.attributedText
        let sourceBoundary = source.index(
            source.endIndex,
            offsetBy: -activePhrase.text.count
        )
        let split = activeAttributedIndex(
            in: attributed,
            source: source,
            sourceBoundary: sourceBoundary
        )
        let settled = Text(AttributedString(attributed[..<split]))
        let active = Text(AttributedString(attributed[split...]))
            .customAttribute(LiveActivePhraseAttribute())
        return Text("\(settled)\(active)")
    }

    /// Performance and accessibility fallbacks request no materialization at
    /// all. Keep that path as ordinary text so SwiftUI can use its native draw
    /// pipeline instead of paying for a no-op custom renderer every frame.
    private var plainText: Text {
        guard let activePhrase else {
            return Text(assistantMarkdownPresentation(settledTail).attributedText)
        }
        return Text(
            assistantLiveMarkdownPresentation(settledTail + activePhrase.text).attributedText
        )
    }

    /// Markdown source positions exclude syntax delimiters. That lets the
    /// visual split land inside a coalesced plain-text run without replaying
    /// the whole settled tail. If a phrase starts inside one semantic token,
    /// only the genuinely new visible suffix receives the dust attribute.
    private func activeAttributedIndex(
        in attributed: AttributedString,
        source: String,
        sourceBoundary: String.Index
    ) -> AttributedString.Index {
        if attributed.characters.count == source.count {
            let visibleDistance = source.distance(from: source.startIndex, to: sourceBoundary)
            return attributed.characters.index(
                attributed.startIndex,
                offsetBy: visibleDistance
            )
        }

        for run in attributed.runs {
            guard let position = run.markdownSourcePosition,
                  let sourceRange = Range<String.Index>(position, in: source),
                  sourceRange.upperBound > sourceBoundary else {
                continue
            }

            if sourceBoundary <= sourceRange.lowerBound {
                return run.range.lowerBound
            }

            let sourceDistance = source.distance(
                from: sourceRange.lowerBound,
                to: sourceBoundary
            )
            let visibleCount = attributed[run.range].characters.count
            let visibleDistance = min(max(sourceDistance, 0), visibleCount)
            return attributed.characters.index(
                run.range.lowerBound,
                offsetBy: visibleDistance
            )
        }
        return attributed.endIndex
    }

    private func styledText(_ text: Text) -> some View {
        text
            .font(.system(.body, design: .default, weight: .regular))
            .lineSpacing(lineSpacing)
            .foregroundStyle(AgentPalette.ink)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    var body: some View {
        if effectMode == .none {
            styledText(plainText)
                .accessibilityHidden(true)
        } else {
            styledText(renderedText)
                .textRenderer(
                    LivePhraseMaterializationRenderer(
                        progress: progress,
                        mode: effectMode,
                        phraseSeed: dustSeed
                    )
                )
                .task {
                    guard activePhrase != nil else {
                        progress = 1
                        return
                    }
                    progress = 0
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    withAnimation(.linear(duration: animationDuration)) {
                        progress = 1
                    }
                }
                .accessibilityHidden(true)
        }
    }
}

/// A single animatable render pass. The active phrase condenses into readable
/// ink while a bounded, phrase-seeded dust path gathers into the glyphs. The
/// dust reaches zero before completion, so settled text becomes ordinary ink
/// and performs no continuing animation or drawing work.
private struct LivePhraseMaterializationRenderer: TextRenderer {
    var progress: Double
    let mode: LivePhraseEffectMode
    let phraseSeed: UInt64

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var displayPadding: EdgeInsets {
        EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        let clamped = min(max(progress, 0), 1)
        let eased = UnitCurve.easeOut.value(at: clamped)
        let dustPhase = LivePhraseDustGeometry.phase(progress: clamped)

        for (lineOrdinal, line) in layout.enumerated() {
            for (runOrdinal, run) in line.enumerated() {
                guard run[LiveActivePhraseAttribute.self] != nil else {
                    context.draw(run)
                    continue
                }

                if mode == .dustMaterialize, dustPhase.dustOpacity > 0 {
                    drawDust(
                        for: run,
                        phase: dustPhase,
                        discriminator: (lineOrdinal * 257) + runOrdinal,
                        in: &context
                    )
                }

                var activeContext = context
                switch mode {
                case .dustMaterialize:
                    activeContext.opacity = dustPhase.textOpacity
                    activeContext.translateBy(x: 0, y: dustPhase.verticalOffset)
                    if dustPhase.blurRadius > 0 {
                        activeContext.addFilter(.blur(radius: dustPhase.blurRadius))
                    }
                case .fadeOnly:
                    activeContext.opacity = 0.72 + (0.28 * eased)
                case .none:
                    activeContext.opacity = 1
                }

                activeContext.draw(run, options: .disablesSubpixelQuantization)
            }
        }
    }

    private func drawDust(
        for run: Text.Layout.Run,
        phase: LivePhraseDustGeometry.Phase,
        discriminator: Int,
        in context: inout GraphicsContext
    ) {
        guard !run.isEmpty else { return }
        let requestedCount = max(5, run.count)
        let particleCount = LivePhraseDustGeometry.particleCount(requested: requestedCount)
        guard particleCount > 0 else { return }

        let runSeed = LivePhraseDustGeometry.mixedSeed(
            phraseSeed,
            discriminator: discriminator
        )
        var dustPath = Path()

        for particleOrdinal in 0..<particleCount {
            let glyphIndex = LivePhraseDustGeometry.sampledGlyphIndex(
                particleOrdinal: particleOrdinal,
                glyphCount: run.count,
                particleCount: particleCount
            )
            let particle = LivePhraseDustGeometry.particle(
                seed: runSeed,
                particleOrdinal: particleOrdinal,
                targetBounds: run[glyphIndex].typographicBounds.rect,
                progress: progress
            )
            dustPath.addEllipse(
                in: CGRect(
                    x: particle.center.x - particle.radius,
                    y: particle.center.y - particle.radius,
                    width: particle.radius * 2,
                    height: particle.radius * 2
                )
            )
        }

        var dustContext = context
        dustContext.opacity = phase.dustOpacity
        dustContext.blendMode = AgentPalette.isLight ? .normal : .plusLighter
        let tint = AgentPalette.isLight
            ? AgentPalette.ink.opacity(0.72)
            : Color.white.opacity(0.92)
        dustContext.fill(dustPath, with: .color(tint))
    }
}

/// The only native Liquid Glass element in the transcript. Glass acts as the
/// current reading boundary; it never becomes a frame around ordinary text.
private struct LiveTranscriptBead: View {
    let isVisible: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var arrived = false

    private var usesFallback: Bool {
        reduceTransparency ||
            AgentPerformance.prefersReducedVisualEffects ||
            AgentTheme.current == .matrixRain ||
            AgentPlatformCompatibility.usesConservativeRendering
    }

    var body: some View {
        bead
            .scaleEffect(arrived || reduceMotion ? 1 : 0.84)
            .opacity(isVisible ? 1 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isVisible)
            .task(id: isVisible) {
                guard isVisible else {
                    arrived = false
                    return
                }
                guard !reduceMotion, !AgentPerformance.prefersReducedVisualEffects else {
                    arrived = true
                    return
                }
                arrived = false
                await Task.yield()
                guard !Task.isCancelled else { return }
                withAnimation(.smooth(duration: NovaMotion.phraseArrivalDuration)) {
                    arrived = true
                }
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var bead: some View {
        if #available(iOS 26.0, *), !usesFallback {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(AgentPalette.isLight ? 0.18 : 0.13),
                            Color.white.opacity(0.015)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 16, height: 16)
                .overlay(alignment: .topLeading) {
                    Circle()
                        .fill(Color.white.opacity(0.74))
                        .frame(width: 3.2, height: 3.2)
                        .offset(x: 3.2, y: 3.0)
                }
                .glassEffect(.regular, in: .circle)
        } else {
            Circle()
                .fill(AgentPalette.surfaceElevated)
                .frame(width: 16, height: 16)
                .overlay {
                    Circle()
                        .strokeBorder(AgentPalette.glassStroke.opacity(0.72), lineWidth: 0.75)
                }
                .overlay(alignment: .topLeading) {
                    Circle()
                        .fill(AgentPalette.ink.opacity(0.52))
                        .frame(width: 3, height: 3)
                        .offset(x: 3.2, y: 3.0)
                }
        }
    }
}

struct LiquidResponseEntranceModifier: ViewModifier {
    let enabled: Bool
    @State private var appeared = false

    func body(content: Content) -> some View {
        content
            .opacity(!enabled || appeared ? 1 : 0)
            .offset(y: !enabled || appeared ? 0 : 4)
            .animation(enabled ? NovaMotion.glassArrival : nil, value: appeared)
            .onAppear { appeared = true }
    }
}

extension View {
    func liquidResponseEntrance(enabled: Bool) -> some View {
        modifier(LiquidResponseEntranceModifier(enabled: enabled))
    }
}
