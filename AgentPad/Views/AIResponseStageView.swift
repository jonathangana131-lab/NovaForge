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
    let runtime: AgentRuntime

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var frame: ForgeLiveFeedFrame {
        stream.displayFrame
    }

    private var activeToolPresentation: (title: String, target: String?)? {
        guard let toolName = runtime.activeToolName else { return nil }
        return LiveChatSessionReducer.presentation(
            forToolName: toolName,
            detail: runtime.activeToolDetail
        )
    }

    private var stageStatus: AIStreamStatus {
        if runtime.pendingTool != nil {
            return .waitingApproval("Review required")
        }
        if let activeToolPresentation {
            return .usingTool(activeToolPresentation.title)
        }
        if frame.displayText.isEmpty {
            return .connecting("NovaForge")
        }
        return .composing
    }

    private var statusLine: String {
        switch stageStatus {
        case .waitingApproval:
            return "Waiting for your approval"
        case .usingTool(let title):
            return title
        case .finalizing:
            return "Finishing response…"
        case .connecting:
            return "Preparing response…"
        default:
            return frame.statusLine
        }
    }

    private var artifacts: [LiveChatArtifactHandoff] {
        Array(stream.responseDocument.artifacts.prefix(2))
    }

    var body: some View {
        if isWorking || isHandoffActive {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 9) {
                        AIResponseStatusGlyph(status: stageStatus, tint: AgentPalette.primaryAccent)
                            .accessibilityHidden(true)

                        Text(statusLine)
                            .font(.system(size: 11, weight: .bold, design: AgentPalette.interfaceFontDesign))
                            .tracking(0.15)
                            .foregroundStyle(AgentPalette.tertiaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                            .contentTransition(.interpolate)
                            .accessibilityIdentifier("liveStreamingStatusText")

                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 25)

                    AIResponseLetterFlowView(
                        frame: frame
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if !artifacts.isEmpty {
                        AIResponseArtifactShelf(artifacts: artifacts, tint: AgentPalette.primaryAccent)
                    }
                }
                .padding(.horizontal, 15)
                .padding(.vertical, 13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .chatMessageSurface(radius: 22, tint: AgentPalette.primaryAccent, emphasis: .live)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("aiResponseStage")

                Spacer(minLength: 36)
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
        Group {
            if frame.displayText.isEmpty {
                Text("Preparing response")
                    .font(.system(.body, design: AgentPalette.interfaceFontDesign, weight: .regular))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineSpacing(5)
            } else {
                LiquidStreamingTextReveal(frame: frame)
            }
        }
        // Collapse the renderer's visual children into one readable response.
        // This keeps its legacy visible-text identifier while preventing the
        // one-pixel diagnostics label from becoming a VoiceOver stop.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(frame.displayText.isEmpty ? "Preparing response" : frame.displayText)
        .accessibilityValue("\(frame.characterCount) characters streamed")
        .accessibilityHint("Response is still arriving")
        .accessibilityIdentifier("streamingTextReveal")
    }
}

private struct AIResponseStatusGlyph: View {
    let status: AIStreamStatus
    let tint: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(foreground.opacity(0.10))
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(foreground)
        }
        .frame(width: 25, height: 25)
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(foreground.opacity(0.20), lineWidth: 0.55)
        }
    }

    private var symbol: String {
        switch status {
        case .idle, .connecting:
            return "sparkles"
        case .composing:
            return "text.bubble.fill"
        case .usingTool:
            return "wrench.and.screwdriver.fill"
        case .waitingApproval:
            return "hand.raised.fill"
        case .finalizing:
            return "checkmark.seal.fill"
        case .complete:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    private var foreground: Color {
        switch status {
        case .waitingApproval:
            return AgentPalette.approval
        case .complete, .finalizing:
            return AgentPalette.green
        case .failed:
            return AgentPalette.rose
        default:
            return tint
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
