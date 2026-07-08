import SwiftUI

struct AIResponseStageView: View {
    @ObservedObject var stream: LiveStreamBuffer
    let isWorking: Bool
    let isHandoffActive: Bool
    let runtime: AgentRuntime

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var document: AIStreamDocument {
        let semantic = stream.responseDocument
        if !semantic.isEmpty { return semantic }

        let frame = stream.displayFrame
        if !frame.displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return AIStreamDocument(
                title: nil,
                visibleParagraphs: [],
                activeFragment: frame.displayText,
                status: .composing,
                artifacts: [],
                characterCount: frame.characterCount,
                isComplete: false
            )
        }

        if isWorking {
            return AIStreamDocument(
                title: nil,
                visibleParagraphs: [],
                activeFragment: "Preparing response",
                status: activeToolStatus ?? .connecting("NovaForge"),
                artifacts: [],
                characterCount: 0,
                isComplete: false
            )
        }

        return semantic
    }

    private var activeToolStatus: AIStreamStatus? {
        guard let toolName = runtime.activeToolName else { return nil }
        let presentation = LiveChatSessionReducer.presentation(
            forToolName: toolName,
            detail: runtime.activeToolDetail
        )
        return .usingTool(presentation.title)
    }

    private var statusLine: String {
        if document.status == .composing, let activeToolStatus {
            if case .usingTool(let title) = activeToolStatus { return title }
        }
        return document.stageStatusLine
    }

    private var allowsEntranceMotion: Bool {
        NovaMotion.enabled(reduceMotion: reduceMotion)
    }

    var body: some View {
        if isWorking || isHandoffActive {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 13) {
                    HStack(alignment: .center, spacing: 9) {
                        AIResponseStatusGlyph(status: document.status, tint: AgentPalette.primaryAccent)
                            .accessibilityHidden(true)

                        Text(statusLine)
                            .font(.system(size: 11, weight: .black, design: AgentPalette.interfaceFontDesign))
                            .tracking(0.2)
                            .foregroundStyle(AgentPalette.tertiaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                            .accessibilityIdentifier("liveStreamingStatusText")

                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 22)

                    AIResponseLetterFlowView(
                        document: document,
                        queuedCharacterCount: stream.revealBacklog,
                        tint: AgentPalette.primaryAccent
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if !document.artifacts.isEmpty {
                        AIResponseArtifactShelf(artifacts: Array(document.artifacts.prefix(2)), tint: AgentPalette.primaryAccent)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .padding(.horizontal, 15)
                .padding(.top, 13)
                .padding(.bottom, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .chatMessageSurface(radius: 22, tint: AgentPalette.primaryAccent, emphasis: .live)
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(AgentPalette.primaryAccent.opacity(0.16), lineWidth: 0.55)
                        .allowsHitTesting(false)
                }
                .shadow(
                    color: AgentPerformance.prefersReducedVisualEffects ? .clear : AgentPalette.primaryAccent.opacity(0.08),
                    radius: 16,
                    x: 0,
                    y: 5
                )
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("liveStreamingBubble")

                Spacer(minLength: 44)
            }
            .padding(.horizontal, 18)
            .liquidResponseEntrance(enabled: allowsEntranceMotion)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("aiResponseStage")
        }
    }
}

struct AIResponseLetterFlowView: View {
    let document: AIStreamDocument
    var queuedCharacterCount: Int = 0
    var tint: Color = AgentPalette.primaryAccent

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var settledParagraphs: [String] {
        let paragraphs = document.visibleParagraphs.map(\.text).filter { !$0.isEmpty }
        guard AgentPerformance.prefersReducedVisualEffects else { return paragraphs }
        var compacted: [String] = []
        var remaining = 520
        for paragraph in paragraphs.reversed() {
            guard remaining > 0 else { break }
            let clipped = Self.suffixWindow(paragraph, limit: remaining)
            compacted.insert(clipped, at: 0)
            remaining -= clipped.count
        }
        return compacted
    }

    private var activeText: String {
        let text = document.activeFragment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AgentPerformance.prefersReducedVisualEffects else { return text }
        return Self.suffixWindow(text, limit: 520)
    }

    private var allowsLetterFlow: Bool {
        NovaMotion.enabled(reduceMotion: reduceMotion) &&
            !AgentPerformance.prefersReducedVisualEffects &&
            !activeText.isEmpty &&
            activeText.count <= maxAnimatedGlyphs
    }

    private var maxAnimatedGlyphs: Int {
        AgentPerformance.shouldProfileFrameRate ? 44 : 72
    }

    private static func suffixWindow(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let suffix = text.suffix(limit)
        return "…" + String(suffix)
    }

    private var accessibilityText: String {
        document.visibleText.isEmpty ? "Preparing response" : document.visibleText
    }

    private var fallbackText: Text {
        guard !settledParagraphs.isEmpty || !activeText.isEmpty else {
            var placeholder = AttributedString("Preparing response")
            placeholder.foregroundColor = AgentPalette.secondaryText
            return Text(placeholder)
        }

        var attributed = AttributedString()
        for (index, paragraph) in settledParagraphs.enumerated() {
            if index > 0 { attributed.append(AttributedString("\n\n")) }
            var settled = AttributedString(paragraph)
            settled.foregroundColor = AgentPalette.ink.opacity(0.94)
            attributed.append(settled)
        }

        if !activeText.isEmpty {
            if !settledParagraphs.isEmpty { attributed.append(AttributedString("\n\n")) }
            var activeRun = AttributedString(activeText)
            activeRun.foregroundColor = tint.opacity(0.88)
            attributed.append(activeRun)
        }

        return Text(attributed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if allowsLetterFlow {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(settledParagraphs.enumerated()), id: \.offset) { _, paragraph in
                            Text(paragraph)
                                .foregroundStyle(AgentPalette.ink.opacity(0.94))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        AIResponseActivePhraseLetterFlow(text: activeText, tint: tint)
                    }
                } else {
                    fallbackText
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.system(size: 16, weight: .regular, design: AgentPalette.interfaceFontDesign))
            .lineSpacing(5)
            .transaction { transaction in
                transaction.animation = nil
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
            .accessibilityIdentifier("streamingTextReveal")
            .accessibilityValue("\(document.characterCount) characters, \(queuedCharacterCount) queued")

            Text("characters \(document.characterCount) queued \(queuedCharacterCount)")
                .font(.system(size: 1, weight: .regular, design: AgentPalette.interfaceFontDesign))
                .frame(width: 1, height: 1, alignment: .leading)
                .opacity(0.01)
                .accessibilityIdentifier("streamingTextRevealMetrics")
                .accessibilityLabel("characters \(document.characterCount) queued \(queuedCharacterCount)")
                .accessibilityValue("characters \(document.characterCount) queued \(queuedCharacterCount)")
        }
    }
}

private struct AIResponseActivePhraseLetterFlow: View {
    let text: String
    let tint: Color

    @State private var materialized = true
    @State private var signature = ""

    private var letters: [Character] { Array(text) }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            ForEach(Array(letters.enumerated()), id: \.offset) { index, character in
                Text(String(character))
                    .foregroundStyle(tint.opacity(character.isWhitespace ? 0.0 : 0.98))
                    .opacity(materialized ? 1 : 0.18)
                    .blur(radius: materialized ? 0 : 0.45)
                    .offset(y: materialized ? 0 : 2.5)
                    .animation(
                        .easeOut(duration: 0.34).delay(min(Double(index) * 0.012, 0.32)),
                        value: materialized
                    )
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityHidden(true)
        .onAppear(perform: runFlowIfNeeded)
        .onChange(of: text) { _, _ in
            runFlowIfNeeded()
        }
    }

    private func runFlowIfNeeded() {
        guard signature != text else { return }
        signature = text
        materialized = false
        DispatchQueue.main.async {
            guard signature == text else { return }
            materialized = true
        }
    }
}

private struct AIResponseStatusGlyph: View {
    let status: AIStreamStatus
    let tint: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(tint.opacity(0.10))
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .black))
                .foregroundStyle(foreground)
        }
        .frame(width: 25, height: 25)
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(foreground.opacity(0.22), lineWidth: 0.55)
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
                        .font(.system(size: 10, weight: .black))
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
                        .font(.system(size: 10, weight: .black, design: AgentPalette.interfaceFontDesign))
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
