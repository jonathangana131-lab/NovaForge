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
        AgentPerformance.shouldProfileFrameRate ? 44 : 260
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
            activeRun.foregroundColor = AgentPalette.ink.opacity(0.94)
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
                        AIResponseActivePhraseDustFlow(text: activeText, tint: tint)
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

private struct AIResponseActivePhraseDustFlow: View {
    let text: String
    let tint: Color

    @State private var signature = ""
    @State private var visibleTokenCount = 0
    @State private var sequenceTask: Task<Void, Never>?
    @State private var sequenceStart = Date()

    private var tokens: [String] {
        text
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
    }

    var body: some View {
        AIResponseDustWrapLayout(horizontalSpacing: 4, verticalSpacing: 5) {
            ForEach(Array(tokens.enumerated()), id: \.offset) { index, token in
                let isVisible = index < visibleTokenCount
                Text(token)
                    .foregroundStyle(AgentPalette.ink.opacity(isVisible ? 0.97 : 0.24))
                    .blur(radius: isVisible ? 0 : 4.8)
                    .scaleEffect(isVisible ? 1.0 : 0.982, anchor: .center)
                    .shadow(color: isVisible ? AgentPalette.ink.opacity(0.10) : AgentPalette.ink.opacity(0.26), radius: isVisible ? 4 : 12, x: 0, y: 0)
                    .animation(.easeOut(duration: 0.34), value: isVisible)
            }
        }
        .overlay(alignment: .topLeading) {
            AIResponseDustConstellation(
                signature: signature,
                tokenCount: tokens.count,
                startDate: sequenceStart,
                tint: tint,
                enabled: !tokens.isEmpty
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityHidden(true)
        .onAppear(perform: restartSequenceIfNeeded)
        .onChange(of: text) { _, _ in
            restartSequenceIfNeeded()
        }
        .onDisappear {
            sequenceTask?.cancel()
            sequenceTask = nil
        }
    }

    private func restartSequenceIfNeeded() {
        guard signature != text else { return }
        let previousSignature = signature
        let previousVisibleCount = visibleTokenCount
        let nextTokenCount = tokens.count
        let preservedTokenCount: Int
        if !previousSignature.isEmpty, text.hasPrefix(previousSignature) {
            let previousTokenCount = previousSignature
                .replacingOccurrences(of: "\n", with: " ")
                .split(whereSeparator: { $0.isWhitespace })
                .count
            preservedTokenCount = min(nextTokenCount, max(previousVisibleCount, previousTokenCount))
        } else {
            preservedTokenCount = 0
        }

        signature = text
        sequenceTask?.cancel()
        visibleTokenCount = preservedTokenCount
        sequenceStart = Date()
        guard nextTokenCount > preservedTokenCount else { return }
        sequenceTask = Task { @MainActor in
            for index in (preservedTokenCount + 1)...nextTokenCount {
                if Task.isCancelled { return }
                try? await Task.sleep(for: .milliseconds(index == preservedTokenCount + 1 ? 42 : 76))
                if Task.isCancelled { return }
                withAnimation(.easeOut(duration: 0.34)) {
                    visibleTokenCount = index
                }
            }
        }
    }
}

private struct AIResponseDustWrapLayout: Layout {
    var horizontalSpacing: CGFloat = 4
    var verticalSpacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let maxWidth = max(1, proposal.width ?? 312)
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var measuredWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX > 0, currentX + size.width > maxWidth {
                currentX = 0
                currentY += lineHeight + verticalSpacing
                lineHeight = 0
            }
            measuredWidth = max(measuredWidth, currentX + size.width)
            currentX += size.width + horizontalSpacing
            lineHeight = max(lineHeight, size.height)
        }

        return CGSize(width: min(maxWidth, max(measuredWidth, 1)), height: currentY + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let maxWidth = max(1, bounds.width)
        var currentX = bounds.minX
        var currentY = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX > bounds.minX, currentX + size.width > bounds.minX + maxWidth {
                currentX = bounds.minX
                currentY += lineHeight + verticalSpacing
                lineHeight = 0
            }
            subview.place(
                at: CGPoint(x: currentX, y: currentY),
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
            currentX += size.width + horizontalSpacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

private struct AIResponseDustConstellation: View {
    let signature: String
    let tokenCount: Int
    let startDate: Date
    let tint: Color
    let enabled: Bool

    var body: some View {
        if enabled && tokenCount > 0 && !AgentPerformance.prefersReducedVisualEffects {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                Canvas { context, size in
                    let elapsed = max(0, timeline.date.timeIntervalSince(startDate))
                    let particles = AIResponseDustSeed.particles(signature: signature, tokenCount: tokenCount)
                    for particle in particles {
                        let cycle = particle.duration + particle.rest
                        let phaseAge = (elapsed + particle.delay).truncatingRemainder(dividingBy: cycle)
                        guard phaseAge < particle.duration else { continue }
                        let localAge = max(0, min(1, phaseAge / particle.duration))
                        let ease = 1 - pow(1 - localAge, 3)
                        let target = CGPoint(x: size.width * particle.targetX, y: max(4, size.height * particle.targetY))
                        let origin = CGPoint(x: target.x + particle.driftX, y: target.y + particle.driftY)
                        let x = origin.x + (target.x - origin.x) * CGFloat(ease)
                        let y = origin.y + (target.y - origin.y) * CGFloat(ease)
                        let sparkle = sin(localAge * .pi)
                        var particleContext = context
                        particleContext.opacity = particle.opacity * sparkle
                        let rect = CGRect(x: x, y: y, width: particle.size, height: particle.size)
                        particleContext.addFilter(.blur(radius: particle.blur))
                        particleContext.fill(
                            Path(ellipseIn: rect),
                            with: .color(particle.isWarm ? AgentPalette.ink.opacity(0.96) : tint.opacity(0.82))
                        )
                        if particle.sparkle {
                            particleContext.opacity = particle.opacity * sparkle * 0.55
                            let horizontalRect = CGRect(x: x - particle.size * 0.85, y: y + particle.size * 0.42, width: particle.size * 2.3, height: 0.65)
                            let verticalRect = CGRect(x: x + particle.size * 0.42, y: y - particle.size * 0.85, width: 0.65, height: particle.size * 2.3)
                            var horizontalPath = Path()
                            horizontalPath.addRect(horizontalRect)
                            var verticalPath = Path()
                            verticalPath.addRect(verticalRect)
                            particleContext.fill(horizontalPath, with: .color(AgentPalette.ink.opacity(0.80)))
                            particleContext.fill(verticalPath, with: .color(AgentPalette.ink.opacity(0.72)))
                        }
                    }
                }
                .blendMode(.screen)
            }
            .id(signature)
        }
    }
}

private struct AIResponseDustParticleSeed {
    let targetX: CGFloat
    let targetY: CGFloat
    let driftX: CGFloat
    let driftY: CGFloat
    let size: CGFloat
    let delay: TimeInterval
    let duration: TimeInterval
    let rest: TimeInterval
    let opacity: Double
    let isWarm: Bool
    let blur: CGFloat
    let sparkle: Bool
}

private enum AIResponseDustSeed {
    static func particles(signature: String, tokenCount: Int) -> [AIResponseDustParticleSeed] {
        let unicodeSeed = signature.unicodeScalars.prefix(24).reduce(0) { $0 &+ Int($1.value) }
        let count = min(118, max(36, tokenCount * 7))
        return (0..<count).map { index in
            let value = abs(unicodeSeed &+ index * 97 &+ tokenCount * 43)
            let row = CGFloat((value / 11) % 4)
            let column = CGFloat((value * 37) % 100) / 100
            return AIResponseDustParticleSeed(
                targetX: min(0.98, max(0.02, column)),
                targetY: min(0.94, 0.16 + row * 0.22 + CGFloat((value * 19) % 12) / 100),
                driftX: CGFloat(-34 + (value * 13) % 69),
                driftY: CGFloat(16 + (value * 17) % 44),
                size: CGFloat(1.9 + Double((value * 23) % 32) / 10.0),
                delay: Double(index % max(tokenCount, 1)) * 0.082 + Double((value * 7) % 12) / 100.0,
                duration: 0.92 + Double((value * 5) % 42) / 100.0,
                rest: 0.28 + Double((value * 3) % 22) / 100.0,
                opacity: 0.48 + Double((value * 29) % 42) / 100.0,
                isWarm: index % 5 != 0,
                blur: CGFloat(Double((value * 31) % 10) / 10.0),
                sparkle: index.isMultiple(of: 6)
            )
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
