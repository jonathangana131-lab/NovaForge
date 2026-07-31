import SwiftUI

struct GameRootView: View {
    @ObservedObject var session: GameSession

    var body: some View {
        ZStack {
            GameWorldView(session: session)

            LinearGradient(
                colors: [.black.opacity(0.35), .clear, .black.opacity(0.32)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    ScooterDashboardView(session: session)
                        .accessibilityIdentifier("scooterDashboard")

                    Spacer(minLength: 10)

                    VStack(alignment: .trailing, spacing: 9) {
                        HStack(spacing: 8) {
                            TopActionButton(symbol: "camera.rotate", label: session.camera.rawValue) {
                                session.cycleCamera()
                            }
                            .accessibilityIdentifier("cameraButton")

                            TopActionButton(symbol: "iphone", label: "PHONE") {
                                session.togglePhone()
                            }
                            .accessibilityIdentifier("phoneButton")

                            TopActionButton(symbol: "wrench.and.screwdriver.fill", label: "GARAGE") {
                                session.toggleGarage()
                            }
                            .accessibilityIdentifier("garageButton")
                        }

                        HStack(spacing: 8) {
                            Label(session.bankDisplay, systemImage: "building.columns.fill")
                                .font(.system(size: 14, weight: .heavy, design: .rounded))
                            Text("+\(session.pendingDisplay)")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundStyle(.cyan)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .gameGlass(radius: 16)
                        .accessibilityIdentifier("bankBalance")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)

                Spacer()

                HStack(alignment: .bottom, spacing: 12) {
                    TelemetryCard(session: session)

                    Spacer()

                    TouchDrivingControls(session: session)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 11)
            }

            if session.showPhone {
                PhoneOSView(session: session)
                    .transition(.scale(scale: 0.84).combined(with: .opacity))
                    .zIndex(20)
            }

            if session.showGarage {
                GarageOverlay(session: session)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .zIndex(30)
            }

            if let toast = session.currentToast {
                VStack {
                    ToastView(toast: toast)
                        .padding(.top, 14)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(40)
            }

            if session.isCrashed {
                CrashOverlay(session: session)
                    .zIndex(35)
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: session.showPhone)
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: session.showGarage)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: session.currentToast)
        .onChange(of: session.showGarage) { _, showing in
            session.isPaused = showing
            if showing {
                session.touchThrottle = 0
                session.touchBrake = 0
                session.touchSteering = 0
            }
        }
    }
}

private struct TopActionButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                Text(label)
            }
            .font(.system(size: 11, weight: .heavy, design: .rounded))
            .padding(.horizontal, 12)
            .frame(height: 39)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .gameGlass(radius: 15, interactive: true)
    }
}

private struct ScooterDashboardView: View {
    @ObservedObject var session: GameSession
    @State private var detailPage = 0

    var body: some View {
        Button {
            detailPage = (detailPage + 1) % 5
        } label: {
            Group {
                if session.selectedScooterID == ScooterCatalogItem.maxshot.id {
                    maxshotDisplay
                } else {
                    performanceDisplay
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var maxshotDisplay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 27, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.black, Color(red: 0.01, green: 0.06, blue: 0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 27, style: .continuous)
                        .stroke(.white.opacity(0.14), lineWidth: 1)
                }
                .shadow(color: .cyan.opacity(0.18), radius: 18)

            VStack(spacing: 3) {
                HStack(spacing: 9) {
                    Image(systemName: "bluetooth")
                        .foregroundStyle(session.controllerName == nil ? .white.opacity(0.32) : .cyan)
                    Image(systemName: "lightbulb.fill")
                        .foregroundStyle(.white.opacity(0.72))
                    Spacer()
                    Text(session.driveMode.rawValue)
                        .font(.system(size: 15, weight: .black, design: .rounded))
                        .foregroundStyle(.cyan)
                }
                .font(.system(size: 10, weight: .bold))

                HStack(alignment: .lastTextBaseline, spacing: 5) {
                    Text(Int(session.speedMPH.rounded()).formatted())
                        .font(.system(size: 54, weight: .black, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.65)
                    Text("MPH")
                        .font(.system(size: 10, weight: .black, design: .rounded))
                        .foregroundStyle(.white.opacity(0.62))
                        .padding(.bottom, 8)
                    Spacer(minLength: 6)
                    BatteryBars(session: session)
                }

                HStack {
                    Text(detailLabel)
                        .font(.system(size: 9, weight: .black, design: .rounded))
                        .foregroundStyle(.white.opacity(0.42))
                    Spacer()
                    Text(detailValue)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.86))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
        }
        .frame(width: 244, height: 128)
    }

    private var performanceDisplay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.black.opacity(0.93))
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(
                            LinearGradient(colors: [.green, .cyan], startPoint: .leading, endPoint: .trailing),
                            lineWidth: 2
                        )
                }
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.selectedScooter.name.uppercased())
                        .font(.system(size: 8, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white.opacity(0.48))
                    Text(Int(session.speedMPH.rounded()).formatted())
                        .font(.system(size: 50, weight: .black, design: .rounded))
                        .monospacedDigit()
                    Text("MPH · \(session.driveMode.rawValue)")
                        .font(.system(size: 10, weight: .black, design: .rounded))
                        .foregroundStyle(.green)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    Text("\(Int(session.simulationState.batteryVoltage)) V")
                    Text("\(Int(session.simulationState.electricalPowerWatts)) W")
                    Text("\(Int(session.simulationState.motorTemperatureCelsius))° MOTOR")
                    BatteryBars(session: session)
                }
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.78))
            }
            .padding(15)
        }
        .frame(width: 276, height: 128)
    }

    private var detailLabel: String {
        ["ODO", "TRIP", "VOLT", "POWER", "MOTOR"][detailPage]
    }

    private var detailValue: String {
        switch detailPage {
        case 0: return String(format: "%.1f mi", session.odometerMiles)
        case 1: return String(format: "%.1f mi", session.tripMiles)
        case 2: return String(format: "%.1f V", session.simulationState.batteryVoltage)
        case 3: return "\(Int(session.simulationState.electricalPowerWatts)) W"
        default: return "\(Int(session.simulationState.motorTemperatureCelsius))°C"
        }
    }
}

private struct BatteryBars: View {
    @ObservedObject var session: GameSession

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<5, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(barColor(index: index))
                    .frame(width: 6, height: CGFloat(7 + index * 3))
            }
        }
        .padding(4)
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .stroke(.white.opacity(0.46), lineWidth: 1)
        }
    }

    private func barColor(index: Int) -> Color {
        let active = index < session.batteryBars
        guard active else { return .white.opacity(0.10) }
        if session.simulationState.batteryStateOfCharge <= 0.08 {
            return session.isCriticalBatteryVisible ? .red : .clear
        }
        return session.batteryBars <= 1 ? .orange : .cyan
    }
}

private struct TelemetryCard: View {
    @ObservedObject var session: GameSession

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Circle()
                    .fill(session.simulationState.controllerCutoff ? .red : .green)
                    .frame(width: 7, height: 7)
                Text(session.selectedScooter.name)
                    .lineLimit(1)
            }
            .font(.system(size: 10, weight: .heavy, design: .rounded))

            HStack(spacing: 14) {
                stat("BAT", "\(Int(session.simulationState.batteryStateOfCharge * 100))%")
                stat("VOLT", String(format: "%.1f", session.simulationState.batteryVoltage))
                stat("AMPS", String(format: "%.1f", session.simulationState.batteryCurrentAmps))
                stat("MOTOR", "\(Int(session.simulationState.electricalPowerWatts))W")
            }

            HStack(spacing: 8) {
                Label(session.surface.rawValue, systemImage: "road.lanes")
                if let controller = session.controllerName {
                    Label(controller, systemImage: "gamecontroller.fill")
                        .lineLimit(1)
                }
            }
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(.white.opacity(0.56))
        }
        .padding(12)
        .frame(width: 312, alignment: .leading)
        .gameGlass(radius: 18)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 7, weight: .black, design: .rounded))
                .foregroundStyle(.white.opacity(0.36))
            Text(value)
                .font(.system(size: 12, weight: .heavy, design: .monospaced))
        }
    }
}

private struct TouchDrivingControls: View {
    @ObservedObject var session: GameSession

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            SteeringPad(value: $session.touchSteering)
                .accessibilityIdentifier("steeringPad")

            AnalogPedal(
                title: "BRAKE",
                symbol: "arrow.down",
                tint: .red,
                value: $session.touchBrake
            )
            .accessibilityIdentifier("brakePedal")

            AnalogPedal(
                title: "THROTTLE",
                symbol: "bolt.fill",
                tint: .cyan,
                value: $session.touchThrottle
            )
            .accessibilityIdentifier("throttlePedal")
        }
    }
}

private struct SteeringPad: View {
    @Binding var value: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.black.opacity(0.35))
                HStack {
                    Image(systemName: "chevron.left")
                    Spacer()
                    Image(systemName: "chevron.right")
                }
                .padding(.horizontal, 12)
                .foregroundStyle(.white.opacity(0.35))
                Circle()
                    .fill(.white.opacity(0.88))
                    .frame(width: 38, height: 38)
                    .shadow(color: .cyan.opacity(0.42), radius: 10)
                    .offset(x: CGFloat(value) * max(0, proxy.size.width * 0.5 - 26))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let center = proxy.size.width * 0.5
                        value = min(1, max(-1, Double((gesture.location.x - center) / max(1, center))))
                    }
                    .onEnded { _ in
                        withAnimation(.spring(response: 0.24, dampingFraction: 0.72)) { value = 0 }
                    }
            )
        }
        .frame(width: 150, height: 72)
        .gameGlass(radius: 20, interactive: true)
    }
}

private struct AnalogPedal: View {
    let title: String
    let symbol: String
    let tint: Color
    @Binding var value: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 19, style: .continuous)
                    .fill(.black.opacity(0.36))
                RoundedRectangle(cornerRadius: 19, style: .continuous)
                    .fill(tint.opacity(0.52))
                    .frame(height: max(0, proxy.size.height * CGFloat(value)))
                VStack(spacing: 5) {
                    Image(systemName: symbol)
                        .font(.system(size: 17, weight: .bold))
                    Text(title)
                        .font(.system(size: 8, weight: .black, design: .rounded))
                }
                .padding(.bottom, 11)
                .foregroundStyle(.white)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        value = min(1, max(0, Double(1 - gesture.location.y / max(1, proxy.size.height))))
                    }
                    .onEnded { _ in value = 0 }
            )
        }
        .frame(width: 68, height: 118)
        .gameGlass(radius: 19, interactive: true)
    }
}

private struct ToastView: View {
    let toast: GameToast

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: toast.symbol)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.cyan)
                .frame(width: 34, height: 34)
                .background(.cyan.opacity(0.13), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title)
                    .font(.system(size: 14, weight: .heavy, design: .rounded))
                Text(toast.detail)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.66))
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 390, alignment: .leading)
        .gameGlass(radius: 20)
    }
}

private struct CrashOverlay: View {
    @ObservedObject var session: GameSession

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "figure.fall")
                .font(.system(size: 38, weight: .bold))
            Text("YOU'RE COOKED")
                .font(.system(size: 24, weight: .black, design: .rounded))
            Text("The rider and scooter are in crash physics. Reset when you're ready.")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.65))
            Button("RESET UPRIGHT") {
                session.resetRide()
            }
            .font(.system(size: 12, weight: .black, design: .rounded))
            .padding(.horizontal, 22)
            .frame(height: 42)
            .background(.red, in: Capsule())
            .buttonStyle(.plain)
            .accessibilityIdentifier("resetCrashButton")
        }
        .padding(22)
        .frame(width: 330)
        .gameGlass(radius: 26)
    }
}

private extension View {
    @ViewBuilder
    func gameGlass(radius: CGFloat, interactive: Bool = false) -> some View {
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
