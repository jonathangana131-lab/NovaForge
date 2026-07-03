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
        HStack(spacing: 10) {
            Image(systemName: "memories")
                .font(.system(size: 16, weight: .black))
                .foregroundStyle(AgentPalette.cyan)
                .frame(width: 38, height: 38)
                .agentControlSurface(radius: 13, tint: AgentPalette.cyan.opacity(0.14), selected: true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Run Replay")
                    .font(.system(size: 16, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                Text(target.name)
                    .font(.system(size: 11, weight: .semibold, design: AgentPalette.interfaceFontDesign))
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
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .frame(width: AgentDesign.minimumTouchTarget, height: AgentDesign.minimumTouchTarget)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close replay")
        }
    }

    private var scrubber: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    if playheadIndex >= tape.count - 1, !isPlaying {
                        playhead = 0
                    }
                    isPlaying.toggle()
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(AgentPalette.ink)
                        .frame(width: AgentDesign.minimumTouchTarget, height: AgentDesign.minimumTouchTarget)
                        .agentControlSurface(radius: 14, tint: AgentPalette.cyan.opacity(0.16), selected: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isPlaying ? "Pause replay" : "Play replay")
                .accessibilityIdentifier("replayPlayButton")

                Slider(
                    value: $playhead,
                    in: 0...Double(max(tape.count - 1, 1)),
                    step: 1
                ) { editing in
                    if editing { isPlaying = false }
                }
                .tint(AgentPalette.cyan)
                .accessibilityLabel("Replay position")

                Text("\(playheadIndex + 1)/\(tape.count)")
                    .font(.system(size: 11, weight: .black, design: .monospaced))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .fixedSize()
            }
            .padding(10)
            .agentSurface(radius: 16, tint: AgentPalette.cyan.opacity(0.06))
        }
    }

    private var frameList: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(tape.enumerated()), id: \.element.id) { index, frame in
                        frameRow(frame, index: index)
                            .id(frame.id)
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: playheadIndex) {
                guard playheadIndex < tape.count else { return }
                withAnimation(.smooth(duration: 0.25)) {
                    proxy.scrollTo(tape[playheadIndex].id, anchor: .center)
                }
            }
        }
    }

    private func frameRow(_ frame: ReplayFrame, index: Int) -> some View {
        let isCurrent = index == playheadIndex
        let isPast = index < playheadIndex
        return HStack(alignment: .top, spacing: 9) {
            Text(frame.offsetText)
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .foregroundStyle(AgentPalette.tertiaryText)
                .frame(width: 48, alignment: .trailing)
                .padding(.top, 3)

            Image(systemName: frame.symbol)
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(isCurrent || isPast ? frame.tint : AgentPalette.quaternaryText)
                .frame(width: 24, height: 24)
                .agentControlSurface(radius: 8, tint: frame.tint.opacity(isCurrent ? 0.18 : 0.07), selected: isCurrent)

            VStack(alignment: .leading, spacing: 1) {
                Text(frame.title)
                    .font(.system(size: 12, weight: isCurrent ? .black : .bold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(isCurrent || isPast ? AgentPalette.ink : AgentPalette.tertiaryText)
                if !frame.detail.isEmpty {
                    Text(frame.detail)
                        .font(.system(size: 10.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(isCurrent || isPast ? AgentPalette.secondaryText : AgentPalette.quaternaryText)
                        .lineLimit(isCurrent ? 3 : 1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .agentRowSurface(radius: 14, tint: frame.tint, selected: isCurrent)
        .opacity(isCurrent || isPast ? 1 : 0.55)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(frame.offsetText): \(frame.title). \(frame.detail)")
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "memories")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(AgentPalette.tertiaryText)
            Text("Nothing to replay")
                .font(.system(size: 13, weight: .black, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(AgentPalette.ink)
            Text("This run didn't record replayable events.")
                .font(.system(size: 11, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(AgentPalette.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .agentSurface(radius: 18, tint: AgentPalette.cyan.opacity(0.05))
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
