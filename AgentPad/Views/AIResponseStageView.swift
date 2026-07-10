import SwiftUI

/// The one live-response surface used by Forge.
///
/// Provider deltas are already normalized and display-paced by
/// `ForgeLiveFeedEngine`. This view deliberately renders that single frame as
/// one `Text` layout: no per-token tasks, particle canvases, shimmer masks, or
/// parallel reveal timeline. Keeping the settled prefix stable is both easier
/// to read and considerably cheaper while the transcript is scrolling.
struct AIResponseStageView: View {
    @ObservedObject var stream: LiveStreamBuffer
    let isWorking: Bool
    let isHandoffActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var frame: ForgeLiveFeedFrame {
        stream.displayFrame
    }

    private var artifacts: [LiveChatArtifactHandoff] {
        Array(stream.responseDocument.artifacts.prefix(2))
    }

    var body: some View {
        if isWorking || isHandoffActive {
            HStack {
                HStack(alignment: .top, spacing: 11) {
                    NovaReticleGlyph(symbol: "sparkles", tint: AgentPalette.primaryAccent, size: 30)
                        .padding(.top, 1)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 10) {
                        AIResponseLetterFlowView(frame: frame)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if !artifacts.isEmpty {
                            AIResponseArtifactShelf(artifacts: artifacts, tint: AgentPalette.primaryAccent)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .chatMessageSurface(radius: 20, tint: AgentPalette.primaryAccent, emphasis: .assistant)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("aiResponseStage")

                Spacer(minLength: 44)
            }
            .padding(.horizontal, 18)
            .liquidResponseEntrance(enabled: NovaMotion.enabled(reduceMotion: reduceMotion))
            .accessibilityElement(children: .contain)
            // Keep one stable, exposed live-bubble identity across both the
            // response-stage and compatibility renderers. Nested SwiftUI
            // accessibility containers do not expose the inner identifier.
            .accessibilityIdentifier("liveStreamingBubble")
        }
    }
}

/// Compatibility name retained for UI tests and previews. The implementation
/// is intentionally phrase-paced rather than letter-paced.
struct AIResponseLetterFlowView: View {
    let frame: ForgeLiveFeedFrame

    var body: some View {
        if frame.displayText.isEmpty {
            Text("Preparing response")
                .font(.system(.body, design: AgentPalette.interfaceFontDesign, weight: .regular))
                .foregroundStyle(AgentPalette.secondaryText)
                .lineSpacing(5)
                .accessibilityIdentifier("streamingTextReveal")
                .accessibilityLabel("Preparing response")
                .accessibilityValue("\(frame.characterCount) characters streamed")
                .accessibilityHint("Response is still arriving")
        } else {
            LiquidStreamingTextReveal(frame: frame)
                .accessibilityHint("Response is still arriving")
        }
    }
}

private struct AIResponseArtifactShelf: View {
    let artifacts: [LiveChatArtifactHandoff]
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(artifacts) { artifact in
                HStack(spacing: 8) {
                    Image(systemName: symbol(for: artifact.typeName))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(tint)
                        .frame(width: 20, height: 20)
                        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                    VStack(alignment: .leading, spacing: 1) {
                        Text(artifact.title)
                            .font(.system(size: 11.5, weight: .bold, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(AgentPalette.ink)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(artifact.subtitle)
                            .font(.system(size: 10, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(AgentPalette.tertiaryText)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)

                    Text(artifact.primaryActionTitle)
                        .font(.system(size: 10, weight: .bold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(tint)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(AgentPalette.surfaceElevated.opacity(0.52))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(AgentPalette.glassStroke.opacity(0.55), lineWidth: 0.55)
                }
                .accessibilityLabel("\(artifact.title). \(artifact.subtitle).")
            }
        }
        .accessibilityIdentifier("aiResponseArtifactShelf")
    }

    private func symbol(for typeName: String) -> String {
        let lower = typeName.lowercased()
        if lower.contains("video") { return "play.rectangle.fill" }
        if lower.contains("image") { return "photo.fill" }
        if lower.contains("html") || lower.contains("web") { return "safari.fill" }
        if lower.contains("code") || lower.contains("swift") { return "chevron.left.forwardslash.chevron.right" }
        return "doc.text.fill"
    }
}
