import SwiftUI

struct VoltlineShellView: View {
    @ObservedObject var session: GameSession
    @ObservedObject private var settings = PlayerExperienceSettings.shared
    @StateObject private var frameDriver = VoltlineFrameDriver()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false

    var body: some View {
        ZStack {
            GameRootView(session: session)
                .transaction { transaction in
                    if settings.reduceMotion {
                        transaction.disablesAnimations = true
                    }
                }

            settingsButton

            if showSettings {
                PlayerSettingsOverlay(
                    settings: settings,
                    activeFramesPerSecond: frameDriver.activeFramesPerSecond,
                    onClose: closeSettings
                )
                .transition(settings.reduceMotion ? .opacity : .scale(scale: 0.96).combined(with: .opacity))
                .zIndex(90)
            }

            if !settings.hasCompletedOnboarding {
                VoltlineOnboardingView {
                    settings.finishOnboarding()
                    session.isPaused = false
                }
                .transition(.opacity)
                .zIndex(100)
            }

            GameFeedbackBridge(session: session)
        }
        .background(.black)
        .onAppear {
            frameDriver.start(
                session: session,
                framesPerSecond: settings.effectiveFramesPerSecond
            )
            if !settings.hasCompletedOnboarding {
                session.isPaused = true
            }
        }
        .onDisappear {
            frameDriver.stop()
        }
        .onChange(of: settings.effectiveFramesPerSecond) { _, newValue in
            frameDriver.configure(framesPerSecond: newValue)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                if !showSettings && settings.hasCompletedOnboarding && !session.showGarage {
                    session.isPaused = false
                }
            case .inactive, .background:
                session.isPaused = true
                session.touchThrottle = 0
                session.touchBrake = 0
                session.touchSteering = 0
            @unknown default:
                session.isPaused = true
            }
        }
        .animation(
            settings.reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.86),
            value: showSettings
        )
        .animation(
            settings.reduceMotion ? nil : .easeOut(duration: 0.22),
            value: settings.hasCompletedOnboarding
        )
    }

    private var settingsButton: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button {
                    showSettings = true
                    session.showPhone = false
                    session.showGarage = false
                    session.isPaused = true
                    session.touchThrottle = 0
                    session.touchBrake = 0
                    session.touchSteering = 0
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 15, weight: .bold))
                        .frame(width: 43, height: 43)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay {
                            Circle().stroke(.white.opacity(0.22), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Game settings")
                .accessibilityIdentifier("settingsButton")
                .padding(.trailing, 15)
                .padding(.bottom, 74)
            }
        }
        .zIndex(80)
    }

    private func closeSettings() {
        showSettings = false
        session.isPaused = session.showGarage || !settings.hasCompletedOnboarding
    }
}

private struct VoltlineOnboardingView: View {
    let onStart: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let widthScale = max(0.76, min(1, (proxy.size.width - 16) / 754))
            let heightScale = max(0.76, min(1, (proxy.size.height - 12) / 360))
            let contentScale = min(widthScale, heightScale)

            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.01, green: 0.04, blue: 0.08),
                        Color(red: 0.02, green: 0.13, blue: 0.19),
                        .black
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                HStack(spacing: 24) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 10) {
                            Image(systemName: "bolt.circle.fill")
                                .font(.system(size: 36, weight: .black))
                                .foregroundStyle(.cyan)
                            Text("VOLTLINE")
                                .font(.system(size: 40, weight: .black, design: .rounded))
                                .tracking(2)
                        }

                        Text("A physics-driven electric scooter game")
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.72))

                        Text("Ride the Maxshot, feel voltage sag and tire grip, earn upgrades, tune the controller, and explore the night district from chase or true POV cameras.")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.60))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 390, alignment: .leading)

                        Button(action: onStart) {
                            HStack(spacing: 9) {
                                Text("START RIDING")
                                Image(systemName: "arrow.right")
                            }
                            .font(.system(size: 15, weight: .black, design: .rounded))
                            .padding(.horizontal, 24)
                            .frame(height: 49)
                            .background(.cyan, in: Capsule())
                            .foregroundStyle(.black)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("startRidingButton")
                    }
                    .frame(width: 390, alignment: .leading)

                    VStack(alignment: .leading, spacing: 12) {
                        OnboardingControlRow(symbol: "arrow.left.and.right", title: "Steer", detail: "Left pad or controller left stick")
                        OnboardingControlRow(symbol: "bolt.fill", title: "Throttle", detail: "Right pedal or R2")
                        OnboardingControlRow(symbol: "hand.raised.fill", title: "Brake", detail: "Left pedal or L2")
                        OnboardingControlRow(symbol: "camera.rotate", title: "Camera", detail: "HUD button or R3")
                        OnboardingControlRow(symbol: "iphone", title: "PhoneOS", detail: "Telemetry, bank, market and tuning")

                        Divider().overlay(.white.opacity(0.16))

                        Label("In-game riding only—never copy risky riding on real roads.", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(.yellow.opacity(0.86))
                    }
                    .padding(19)
                    .frame(width: 300)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 25, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 25, style: .continuous)
                            .stroke(.white.opacity(0.16), lineWidth: 1)
                    }
                }
                .padding(20)
                .frame(width: 754)
                .scaleEffect(contentScale)
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .accessibilityIdentifier("onboardingOverlay")
    }
}

private struct OnboardingControlRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.cyan)
                .frame(width: 32, height: 32)
                .background(.cyan.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .black, design: .rounded))
                Text(detail)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.52))
            }
        }
    }
}

private struct PlayerSettingsOverlay: View {
    @ObservedObject var settings: PlayerExperienceSettings
    let activeFramesPerSecond: Int
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.72)
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)

            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("SETTINGS")
                        .font(.system(size: 30, weight: .black, design: .rounded))
                    Text("Performance changes affect the actual game update loop.")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.52))

                    Label("Active target: \(activeFramesPerSecond) FPS", systemImage: "speedometer")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.cyan)

                    Label("Thermal state: \(settings.thermalLabel)", systemImage: "thermometer.medium")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(thermalColor)

                    Spacer()

                    Button("REPLAY INTRO") {
                        settings.resetOnboarding()
                        onClose()
                    }
                    .font(.system(size: 11, weight: .black, design: .rounded))
                    .buttonStyle(.bordered)
                }
                .frame(width: 235, alignment: .leading)
                .padding(24)
                .background(Color.white.opacity(0.035))

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("PERFORMANCE")
                            .settingsSectionTitle()

                        ForEach(VoltlinePerformanceMode.allCases) { mode in
                            Button {
                                settings.performanceMode = mode
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: mode.symbol)
                                        .font(.system(size: 18, weight: .bold))
                                        .foregroundStyle(settings.performanceMode == mode ? .black : .cyan)
                                        .frame(width: 40, height: 40)
                                        .background(
                                            settings.performanceMode == mode ? Color.cyan : Color.cyan.opacity(0.10),
                                            in: RoundedRectangle(cornerRadius: 12)
                                        )
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(mode.rawValue)
                                            .font(.system(size: 13, weight: .black, design: .rounded))
                                        Text(mode.detail)
                                            .font(.system(size: 9, weight: .medium, design: .rounded))
                                            .foregroundStyle(.white.opacity(0.50))
                                    }
                                    Spacer()
                                    if settings.performanceMode == mode {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.cyan)
                                    }
                                }
                                .padding(10)
                                .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
                            }
                            .buttonStyle(.plain)
                        }

                        Toggle("Automatic thermal protection", isOn: $settings.automaticThermalProtection)
                        Divider().overlay(.white.opacity(0.10))

                        Text("FEEDBACK & ACCESSIBILITY")
                            .settingsSectionTitle()

                        Toggle("Procedural motor and wind audio", isOn: $settings.rideAudioEnabled)
                        Toggle("Crash and mode haptics", isOn: $settings.hapticsEnabled)
                        Toggle("Reduce interface motion", isOn: $settings.reduceMotion)
                    }
                    .toggleStyle(.switch)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .padding(22)
                }
                .frame(width: 475)
            }
            .frame(height: 390)
            .background(
                LinearGradient(
                    colors: [Color(red: 0.035, green: 0.05, blue: 0.075), .black],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 28, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(.white.opacity(0.20), lineWidth: 1)
            }
            .overlay(alignment: .topTrailing) {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 25, weight: .bold))
                        .foregroundStyle(.white.opacity(0.68))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("closeSettingsButton")
                .padding(15)
            }
            .shadow(color: .black.opacity(0.72), radius: 34, y: 15)
        }
        .accessibilityIdentifier("settingsOverlay")
    }

    private var thermalColor: Color {
        switch settings.thermalState {
        case .nominal: return .green
        case .fair: return .yellow
        case .serious, .critical: return .red
        @unknown default: return .orange
        }
    }
}

private extension View {
    func settingsSectionTitle() -> some View {
        self
            .font(.system(size: 10, weight: .black, design: .rounded))
            .tracking(1.2)
            .foregroundStyle(.white.opacity(0.46))
    }
}
