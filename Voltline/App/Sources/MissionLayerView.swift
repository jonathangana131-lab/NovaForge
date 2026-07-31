import Combine
import SwiftUI

struct MissionLayerView: View {
    @ObservedObject var session: GameSession
    @StateObject private var director = MissionDirector.shared

    private let updateTimer = Timer.publish(every: 0.10, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            compactHUD

            if director.isBoardPresented {
                MissionBoardView(session: session, director: director) {
                    closeBoard()
                }
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
                .zIndex(5)
            }

            if let completion = director.recentCompletion {
                MissionCompletionBanner(completion: completion) {
                    director.dismissCompletion()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(8)
            }
        }
        .onReceive(updateTimer) { _ in
            director.update(session: session)
        }
        .onAppear {
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("--qa-mission") {
                director.isBoardPresented = true
                session.isPaused = true
            }
            if arguments.contains("--qa-route") && director.activeMission == nil,
               let route = VoltlineMission.catalog.first(where: { $0.kind == .route }) {
                director.activate(route, session: session)
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: director.isBoardPresented)
        .animation(.spring(response: 0.34, dampingFraction: 0.80), value: director.recentCompletion)
    }

    private var compactHUD: some View {
        VStack {
            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    if let mission = director.activeMission {
                        Button {
                            openBoard()
                        } label: {
                            HStack(spacing: 10) {
                                checkpointArrow(for: mission)

                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text("OBJECTIVE")
                                            .font(.system(size: 8, weight: .black, design: .rounded))
                                            .tracking(1)
                                            .foregroundStyle(.cyan)
                                        Text(mission.title)
                                            .font(.system(size: 11, weight: .black, design: .rounded))
                                            .lineLimit(1)
                                    }

                                    Text(director.progressLabel(session: session))
                                        .font(.system(size: 9, weight: .bold, design: .rounded))
                                        .foregroundStyle(.white.opacity(0.62))
                                        .lineLimit(1)

                                    ProgressView(value: director.progress)
                                        .tint(.cyan)
                                        .frame(width: 225)
                                }

                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .black))
                                    .foregroundStyle(.white.opacity(0.42))
                            }
                            .padding(.horizontal, 12)
                            .frame(height: 64)
                            .missionGlass(radius: 18, interactive: true)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("missionHUD")
                    } else {
                        Button {
                            openBoard()
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "flag.checkered")
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundStyle(.cyan)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("CHOOSE AN OBJECTIVE")
                                        .font(.system(size: 10, weight: .black, design: .rounded))
                                    Text("\(director.completionCount)/\(VoltlineMission.catalog.count) complete")
                                        .font(.system(size: 8, weight: .bold, design: .rounded))
                                        .foregroundStyle(.white.opacity(0.52))
                                }
                            }
                            .padding(.horizontal, 13)
                            .frame(height: 50)
                            .missionGlass(radius: 17, interactive: true)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("missionHUD")
                    }
                    Spacer()
                }
                .padding(.leading, 14)
                .padding(.top, 146)

                Spacer()
            }
            Spacer()
        }
        .allowsHitTesting(!director.isBoardPresented)
    }

    @ViewBuilder
    private func checkpointArrow(for mission: VoltlineMission) -> some View {
        if mission.kind == .route, let bearing = director.bearingToNextCheckpoint(session: session) {
            Image(systemName: "location.north.fill")
                .font(.system(size: 19, weight: .black))
                .foregroundStyle(.cyan)
                .rotationEffect(.radians(bearing))
                .frame(width: 34, height: 34)
                .background(.cyan.opacity(0.12), in: Circle())
        } else {
            Image(systemName: mission.symbol)
                .font(.system(size: 17, weight: .black))
                .foregroundStyle(.cyan)
                .frame(width: 34, height: 34)
                .background(.cyan.opacity(0.12), in: Circle())
        }
    }

    private func openBoard() {
        director.isBoardPresented = true
        session.isPaused = true
        session.touchThrottle = 0
        session.touchBrake = 0
        session.touchSteering = 0
    }

    private func closeBoard() {
        director.isBoardPresented = false
        session.isPaused = session.showGarage
    }
}

private struct MissionBoardView: View {
    @ObservedObject var session: GameSession
    @ObservedObject var director: MissionDirector
    let onClose: () -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        GeometryReader { proxy in
            let widthScale = max(0.72, min(1, (proxy.size.width - 18) / 770))
            let heightScale = max(0.72, min(1, (proxy.size.height - 12) / 382))
            let scale = min(widthScale, heightScale)

            ZStack {
                Color.black.opacity(0.80)
                    .ignoresSafeArea()
                    .onTapGesture(perform: onClose)

                HStack(spacing: 0) {
                    summaryRail
                    missionGrid
                }
                .frame(width: 770, height: 382)
                .background(
                    LinearGradient(
                        colors: [Color(red: 0.02, green: 0.045, blue: 0.075), .black],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 28, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(.white.opacity(0.18), lineWidth: 1)
                }
                .overlay(alignment: .topTrailing) {
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 25, weight: .bold))
                            .foregroundStyle(.white.opacity(0.70))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("closeMissionBoardButton")
                    .padding(14)
                }
                .shadow(color: .black.opacity(0.75), radius: 36, y: 16)
                .scaleEffect(scale)
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .accessibilityIdentifier("missionBoard")
    }

    private var summaryRail: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "flag.checkered.2.crossed")
                .font(.system(size: 32, weight: .black))
                .foregroundStyle(.cyan)

            Text("VOLTLINE\nOBJECTIVES")
                .font(.system(size: 25, weight: .black, design: .rounded))
                .tracking(0.8)

            Text("Real movement, speed, purchases, deposits, and photos drive progress. No countdown filler.")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.56))
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 7) {
                Label("\(director.completionCount) / \(VoltlineMission.catalog.count) finished", systemImage: "checkmark.seal.fill")
                ProgressView(value: director.completionFraction)
                    .tint(.cyan)
            }
            .font(.system(size: 10, weight: .bold, design: .rounded))

            if let active = director.activeMission {
                VStack(alignment: .leading, spacing: 5) {
                    Text("ACTIVE")
                        .font(.system(size: 8, weight: .black, design: .rounded))
                        .foregroundStyle(.cyan)
                    Text(active.title)
                        .font(.system(size: 12, weight: .black, design: .rounded))
                    Text(director.progressLabel(session: session))
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                    Button("ABANDON") {
                        director.abandonActiveMission()
                    }
                    .font(.system(size: 9, weight: .black, design: .rounded))
                    .buttonStyle(.bordered)
                }
                .padding(11)
                .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 15))
            }

            Spacer()
        }
        .padding(23)
        .frame(width: 232, alignment: .leading)
        .background(.white.opacity(0.035))
    }

    private var missionGrid: some View {
        ScrollView(showsIndicators: false) {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(VoltlineMission.catalog) { mission in
                    MissionCard(
                        mission: mission,
                        completed: director.isCompleted(mission),
                        active: director.activeMissionID == mission.id
                    ) {
                        director.activate(mission, session: session)
                    }
                }
            }
            .padding(20)
            .padding(.top, 17)
        }
        .frame(width: 538)
    }
}

private struct MissionCard: View {
    let mission: VoltlineMission
    let completed: Bool
    let active: Bool
    let onStart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top) {
                Image(systemName: completed ? "checkmark.seal.fill" : mission.symbol)
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(completed ? .green : .cyan)
                    .frame(width: 38, height: 38)
                    .background((completed ? Color.green : Color.cyan).opacity(0.11), in: RoundedRectangle(cornerRadius: 11))
                Spacer()
                Text(mission.reward.formatted(.currency(code: "USD").precision(.fractionLength(0))))
                    .font(.system(size: 10, weight: .black, design: .rounded))
                    .foregroundStyle(.green)
            }

            Text(mission.title)
                .font(.system(size: 13, weight: .black, design: .rounded))
            Text(mission.detail)
                .font(.system(size: 8.5, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.50))
                .lineLimit(3)
                .frame(minHeight: 32, alignment: .top)

            Button(completed ? "COMPLETED" : active ? "ACTIVE" : "START") {
                guard !completed else { return }
                onStart()
            }
            .font(.system(size: 9, weight: .black, design: .rounded))
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background(
                completed ? Color.green.opacity(0.18) : active ? Color.cyan.opacity(0.20) : Color.cyan,
                in: Capsule()
            )
            .foregroundStyle(completed ? .green : active ? .cyan : .black)
            .buttonStyle(.plain)
            .disabled(completed)
            .accessibilityIdentifier("missionStartButton-\(mission.id)")
        }
        .padding(12)
        .frame(minHeight: 166)
        .background(.white.opacity(active ? 0.085 : 0.052), in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(active ? .cyan.opacity(0.65) : .white.opacity(0.08), lineWidth: active ? 1.5 : 1)
        }
    }
}

private struct MissionCompletionBanner: View {
    let completion: MissionCompletion
    let onDismiss: () -> Void

    var body: some View {
        VStack {
            Button(action: onDismiss) {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 24, weight: .black))
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("OBJECTIVE COMPLETE")
                            .font(.system(size: 9, weight: .black, design: .rounded))
                            .tracking(1.1)
                            .foregroundStyle(.green)
                        Text(completion.missionTitle)
                            .font(.system(size: 14, weight: .black, design: .rounded))
                        Text("+\(completion.reward.formatted(.currency(code: \"USD\").precision(.fractionLength(0))))")
                            .font(.system(size: 11, weight: .black, design: .rounded))
                            .foregroundStyle(.cyan)
                    }
                }
                .padding(.horizontal, 17)
                .frame(height: 70)
                .missionGlass(radius: 21, interactive: true)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("missionCompletionBanner")
            .padding(.top, 14)
            Spacer()
        }
    }
}

private extension View {
    @ViewBuilder
    func missionGlass(radius: CGFloat, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            if interactive {
                self.glassEffect(.regular.interactive(), in: .rect(cornerRadius: radius))
            } else {
                self.glassEffect(.regular, in: .rect(cornerRadius: radius))
            }
        } else {
            self
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .stroke(.white.opacity(0.13), lineWidth: 1)
                }
        }
    }
}
