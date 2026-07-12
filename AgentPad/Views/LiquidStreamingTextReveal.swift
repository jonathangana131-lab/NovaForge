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
        accessibleTranscript = snapshot.visibleText
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

            Text(verbatim: paragraph.text)
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

            Text(verbatim: segment.text)
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
        if AgentPerformance.prefersReducedVisualEffects ||
            AgentTheme.current == .matrixRain ||
            AgentPlatformCompatibility.usesConservativeRendering {
            return .none
        }
        if reduceMotion || reduceTransparency {
            return .fadeOnly
        }
        return .materialize
    }

    private var animationDuration: TimeInterval {
        switch effectMode {
        case .none:
            return 0
        case .fadeOnly:
            return 0.10
        case .materialize:
            switch cadence {
            case .catchingUp, .burst:
                return 0.075
            case .idle, .reading:
                return NovaMotion.phraseArrivalDuration
            }
        }
    }

    private var renderedText: Text {
        let settled = Text(verbatim: settledTail)
        guard let activePhrase else { return settled }
        let active = Text(verbatim: activePhrase.text)
            .customAttribute(LiveActivePhraseAttribute())
        return Text("\(settled)\(active)")
    }

    var body: some View {
        renderedText
            .font(.system(.body, design: .default, weight: .regular))
            .lineSpacing(lineSpacing)
            .foregroundStyle(AgentPalette.ink)
            .fixedSize(horizontal: false, vertical: true)
            .textRenderer(
                LivePhraseMaterializationRenderer(
                    progress: effectMode == .none ? 1 : progress,
                    mode: effectMode
                )
            )
            .task {
                guard activePhrase != nil else {
                    progress = 1
                    return
                }
                guard effectMode != .none else {
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

private enum LivePhraseEffectMode: Equatable {
    case materialize
    case fadeOnly
    case none
}

/// A single animatable render pass. The active phrase condenses into readable
/// ink, receives one brief neutral pearl caustic, and then becomes visually
/// identical to all settled text. Nothing loops after progress reaches 1.
private struct LivePhraseMaterializationRenderer: TextRenderer {
    var progress: Double
    let mode: LivePhraseEffectMode

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var displayPadding: EdgeInsets {
        EdgeInsets(top: 3, leading: 4, bottom: 8, trailing: 4)
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        let clamped = min(max(progress, 0), 1)
        let eased = UnitCurve.easeOut.value(at: clamped)

        for line in layout {
            for run in line {
                guard run[LiveActivePhraseAttribute.self] != nil else {
                    context.draw(run)
                    continue
                }

                var activeContext = context
                // Never make the newest words difficult to read. The phrase
                // starts as translucent pearl ink, then resolves to the same
                // opacity as the settled transcript.
                activeContext.opacity = mode == .none ? 1 : 0.78 + (0.22 * eased)

                if mode == .materialize {
                    activeContext.translateBy(x: 0, y: 1.4 * (1 - eased))
                    activeContext.addFilter(.blur(radius: 0.24 * (1 - eased)))
                }

                activeContext.draw(run, options: .disablesSubpixelQuantization)

                if mode == .materialize, clamped < 1 {
                    // A short, neutral optical lift through the glyphs. It is
                    // deliberately not cyan and falls to zero at completion.
                    let caustic = (0.12 * (1 - eased)) + (max(0, sin(.pi * clamped)) * 0.35)
                    if caustic > 0.001 {
                        var pearlContext = context
                        pearlContext.opacity = caustic
                        pearlContext.blendMode = .plusLighter
                        pearlContext.translateBy(x: -1.5 * (1 - eased), y: -0.4)
                        pearlContext.addFilter(.brightness(0.28))
                        pearlContext.addFilter(.blur(radius: 0.35))
                        pearlContext.draw(run, options: .disablesSubpixelQuantization)
                    }
                }
            }
        }
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
