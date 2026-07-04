//
//  RunReplaySheet.swift
//  NovaForge
//
//  Replay a completed run's recorded event tape: scrub the timeline, play
//  it back with haptic ticks, and watch the run reconstruct step by step.
//

import SwiftData
import SwiftUI

struct RunReplayTarget: Identifiable, Equatable {
    let id: UUID
    let name: String
    let status: ToolRunStatus
    let windowStart: Date
    let windowEnd: Date
}

struct RunReplaySheet: View {
    let target: RunReplayTarget
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var tape: [ReplayFrame] = []
    @State private var playhead: Double = 0
    @State private var isPlaying = false
    @State private var didLoad = false

    struct ReplayFrame: Identifiable, Equatable {
        let id: UUID
        let title: String
        let detail: String
        let symbol: String
        let tint: Color
        let offsetText: String
        let createdAt: Date

        static func == (lhs: ReplayFrame, rhs: ReplayFrame) -> Bool { lhs.id == rhs.id }
    }

    private var playheadIndex: Int {
        guard !tape.isEmpty else { return 0 }
        return min(tape.count - 1, max(0, Int(playhead.rounded())))
    }

    var body: some View {
        ZStack {
            AgentBackground()
            VStack(alignment: .leading, spacing: 14) {
                header

                if tape.isEmpty {
                    emptyState
                } else {
                    scrubber
                    frameList
                }

                Spacer(minLength: 0)
            }
            .padding(.top, 22)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .task {
            guard !didLoad else { return }
            didLoad = true
            loadTape()
        }
        .task(id: isPlaying) {
            guard isPlaying else { return }
            while isPlaying, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(620))
                guard isPlaying, !Task.isCancelled else { return }
                if playheadIndex >= tape.count - 1 {
                    isPlaying = false
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    return
                }
                withAnimation(.smooth(duration: 0.25)) {
                    playhead = Double(playheadIndex + 1)
                }
                UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.7)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("runReplaySheet")
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                NovaKicker(text: "Flight Recorder", tint: AgentPalette.cyan)
                Text("Run Replay")
                    .font(NovaType.display)
                    .foregroundStyle(AgentPalette.ink)
                Text(target.name)
                    .font(NovaType.caption)
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(AgentPalette.controlFill.opacity(0.5)))
                    .overlay(Circle().strokeBorder(AgentPalette.controlBorder.opacity(0.7), lineWidth: 0.9))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close replay")
        }
    }

    private var scrubber: some View {
        VStack(spacing: 4) {
            HStack(spacing: 12) {
                Button {
                    if playheadIndex >= tape.count - 1, !isPlaying {
                        playhead = 0
                    }
                    isPlaying.toggle()
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundStyle(AgentPalette.pearl)
                        .frame(width: AgentDesign.minimumTouchTarget, height: AgentDesign.minimumTouchTarget)
                        .background(Circle().fill(AgentPalette.cyan))
                        .shadow(
                            color: AgentPerformance.prefersReducedVisualEffects ? .clear : AgentPalette.cyan.opacity(0.4),
                            radius: 9, x: 0, y: 2
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isPlaying ? "Pause replay" : "Play replay")
                .accessibilityIdentifier("replayPlayButton")

                VStack(spacing: 3) {
                    Slider(
                        value: $playhead,
                        in: 0...Double(max(tape.count - 1, 1)),
                        step: 1
                    ) { editing in
                        if editing { isPlaying = false }
                    }
                    .tint(AgentPalette.cyan)
                    .accessibilityLabel("Replay position")

                    // event tick marks under the transport track
                    GeometryReader { proxy in
                        let count = max(tape.count - 1, 1)
                        ForEach(0..<tape.count, id: \.self) { index in
                            Rectangle()
                                .fill(index <= playheadIndex ? AgentPalette.cyan.opacity(0.9) : AgentPalette.quaternaryText.opacity(0.5))
                                .frame(width: 1.4, height: index <= playheadIndex ? 7 : 5)
                                .position(
                                    x: proxy.size.width * CGFloat(index) / CGFloat(count),
                                    y: 4
                                )
                        }
                    }
                    .frame(height: 9)
                    .accessibilityHidden(true)
                }

                VStack(alignment: .trailing, spacing: 0) {
                    Text("\(playheadIndex + 1)/\(tape.count)")
                        .font(NovaType.readoutSmall)
                        .foregroundStyle(AgentPalette.cyan)
                        .contentTransition(.numericText())
                    Text("Frame")
                        .novaLabel(AgentPalette.quaternaryText)
                }
                .fixedSize()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .agentSurface(radius: 20, tint: AgentPalette.cyan.opacity(0.06))
            .overlay(NovaCornerTicks(tint: AgentPalette.cyan.opacity(0.35), length: 8, thickness: 1.2, inset: 6))
        }
    }

    private var frameList: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(tape.enumerated()), id: \.element.id) { index, frame in
                        frameRow(frame, index: index)
                            .id(frame.id)
                    }
                }
                .padding(.top, 8)
                .padding(.horizontal, 2)
            }
            .onChange(of: playheadIndex) {
                guard playheadIndex < tape.count else { return }
                withAnimation(.smooth(duration: 0.25)) {
                    proxy.scrollTo(tape[playheadIndex].id, anchor: .center)
                }
            }
        }
    }

    /// Timeline node row: a continuous rail with event nodes that light up
    /// as the playhead passes them. The current frame gets a soft halo
    /// instead of a boxed row.
    private func frameRow(_ frame: ReplayFrame, index: Int) -> some View {
        let isCurrent = index == playheadIndex
        let isPast = index < playheadIndex
        let isLit = isCurrent || isPast
        return HStack(alignment: .top, spacing: 10) {
            Text(frame.offsetText)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(isLit ? AgentPalette.tertiaryText : AgentPalette.quaternaryText)
                .frame(width: 50, alignment: .trailing)
                .padding(.top, 4)

            VStack(spacing: 0) {
                ZStack {
                    if isCurrent {
                        Circle()
                            .fill(frame.tint.opacity(0.18))
                            .frame(width: 22, height: 22)
                    }
                    Circle()
                        .strokeBorder(isLit ? frame.tint : AgentPalette.quaternaryText.opacity(0.5), lineWidth: 1.4)
                        .frame(width: 11, height: 11)
                    if isLit {
                        Circle()
                            .fill(frame.tint)
                            .frame(width: 5, height: 5)
                    }
                }
                .frame(width: 22, height: 22)

                if index < tape.count - 1 {
                    Rectangle()
                        .fill(isPast ? frame.tint.opacity(0.45) : AgentPalette.divider.opacity(0.5))
                        .frame(width: 1.2)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: frame.symbol)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(isLit ? frame.tint : AgentPalette.quaternaryText)
                    Text(frame.title)
                        .font(isCurrent ? NovaType.headline : NovaType.body)
                        .foregroundStyle(isLit ? AgentPalette.ink : AgentPalette.tertiaryText)
                }
                if !frame.detail.isEmpty {
                    Text(frame.detail)
                        .font(NovaType.caption)
                        .foregroundStyle(isLit ? AgentPalette.secondaryText : AgentPalette.quaternaryText)
                        .lineLimit(isCurrent ? 3 : 1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 14)
        }
        .fixedSize(horizontal: false, vertical: true)
        .opacity(isLit ? 1 : 0.6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(frame.offsetText): \(frame.title). \(frame.detail)")
    }

    private var emptyState: some View {
        NovaOrbitalEmptyState(
            symbol: "memories",
            title: "Nothing to replay",
            detail: "This run didn't record replayable events.",
            tint: AgentPalette.cyan
        )
    }

    // MARK: - Tape

    private func loadTape() {
        let start = target.windowStart.addingTimeInterval(-2)
        let end = target.windowEnd.addingTimeInterval(2)
        var descriptor = FetchDescriptor<ProjectEvent>(
            predicate: #Predicate<ProjectEvent> { event in
                event.createdAt >= start && event.createdAt <= end
            },
            sortBy: [SortDescriptor(\ProjectEvent.createdAt, order: .forward)]
        )
        descriptor.fetchLimit = 400
        let events = (try? modelContext.fetch(descriptor)) ?? []
        let anchor = events.first?.createdAt ?? target.windowStart

        tape = events.map { event in
            ReplayFrame(
                id: event.id,
                title: event.title,
                detail: event.detail,
                symbol: Self.symbol(for: event.kind),
                tint: Self.tint(for: event.severity),
                offsetText: Self.offsetText(from: anchor, to: event.createdAt),
                createdAt: event.createdAt
            )
        }
        playhead = tape.isEmpty ? 0 : Double(tape.count - 1)
    }

    private static func offsetText(from anchor: Date, to date: Date) -> String {
        let seconds = max(0, date.timeIntervalSince(anchor))
        if seconds < 60 { return String(format: "+%.1fs", seconds) }
        return String(format: "+%dm%02ds", Int(seconds) / 60, Int(seconds) % 60)
    }

    private static func symbol(for kind: ProjectEventKind) -> String {
        switch kind {
        case .toolQueued: "tray.and.arrow.down.fill"
        case .toolApprovalRequested: "checkmark.shield.fill"
        case .toolApproved: "hand.thumbsup.fill"
        case .toolRejected: "hand.thumbsdown.fill"
        case .toolCompleted: "checkmark.circle.fill"
        case .toolFailed: "exclamationmark.triangle.fill"
        case .runCompleted: "flag.checkered"
        case .runFailed: "exclamationmark.octagon.fill"
        case .fileChanged: "doc.text.fill"
        case .artifactCreated, .artifactPreviewed: "shippingbox.fill"
        case .terminalCommand: "terminal.fill"
        case .promptQueued: "text.bubble.fill"
        case .responseSaved: "bubble.left.and.text.bubble.right.fill"
        case .agentPlanCreated: "list.clipboard.fill"
        case .agentProofCreated: "checkmark.seal.fill"
        default: "circle.fill"
        }
    }

    private static func tint(for severity: ProjectEventSeverity) -> Color {
        switch severity {
        case .success: AgentPalette.green
        case .warning: AgentPalette.warning
        case .failure: AgentPalette.rose
        case .info, .running: AgentPalette.cyan
        }
    }
}
