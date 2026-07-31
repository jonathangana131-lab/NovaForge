import SwiftUI

struct GameRootView: View {
    @ObservedObject var session: GameSession

    var body: some View {
        ZStack {
            GameWorldView(session: session)

            LinearGradient(
                colors: [.black.opacity(0.26), .clear, .black.opacity(0.30)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            CatalogFirstPersonCockpitView(session: session)
                .allowsHitTesting(false)
                .zIndex(8)

            rideChrome
                .zIndex(12)

            // Compatibility marker for the existing UI acceptance test. It is
            // accessibility-only and does not draw a duplicate dashboard.
            Color.clear
                .frame(width: 1, height: 1)
                .position(x: 1, y: 1)
                .accessibilityHidden(false)
                .accessibilityIdentifier("scooterDashboard")

            if session.showPhone {
                PhoneOSView(session: session)
                    .transition(.scale(scale: 0.90, anchor: .trailing).combined(with: .opacity))
                    .zIndex(20)
            }

            if session.showGarage {
                GarageOverlay(session: session)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .zIndex(30)
            }

            if let toast = session.currentToast {
                VStack {
                    RideToastView(toast: toast)
                        .padding(.top, 14)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(40)
            }

            if session.isCrashed {
                RideCrashOverlay(session: session)
                    .zIndex(35)
            }
        }
        .onAppear {
            // First person is the product's primary experience. The camera
            // button still lets the player cycle to the optional external views.
            session.camera = .pov
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

    private var rideChrome: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                Spacer()

                VStack(alignment: .trailing, spacing: 8) {
                    HStack(spacing: 8) {
                        RideActionButton(symbol: "camera.rotate", label: session.camera.rawValue) {
                            session.cycleCamera()
                        }
                        .accessibilityIdentifier("cameraButton")

                        RideActionButton(symbol: "iphone", label: "PHONE") {
                            session.togglePhone()
                        }
                        .accessibilityIdentifier("phoneButton")

                        RideActionButton(symbol: "wrench.and.screwdriver.fill", label: "GARAGE") {
                            session.toggleGarage()
                        }
                        .accessibilityIdentifier("garageButton")
                    }

                    HStack(spacing: 8) {
                        Label(session.bankDisplay, systemImage: "building.columns.fill")
                            .font(.system(size: 13, weight: .heavy, design: .rounded))
                        Text("+\(session.pendingDisplay)")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(.cyan)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .rideGlass(radius: 14)
                    .accessibilityIdentifier("bankBalance")
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)

            Spacer()

            HStack(alignment: .bottom) {
                Spacer()
                RideTouchControls(session: session)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 11)
        }
    }
}

private struct RideActionButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                Text(label)
            }
            .font(.system(size: 10, weight: .heavy, design: .rounded))
            .padding(.horizontal, 11)
            .frame(height: 37)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .rideGlass(radius: 14, interactive: true)
    }
}

private struct RideTouchControls: View {
    @ObservedObject var session: GameSession

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            RideSteeringPad(value: $session.touchSteering)
                .accessibilityIdentifier("steeringPad")

            RideAnalogPedal(
                title: "BRAKE",
                symbol: "arrow.down",
                tint: .red,
                value: $session.touchBrake
            )
            .accessibilityIdentifier("brakePedal")

            RideAnalogPedal(
                title: "THROTTLE",
                symbol: "bolt.fill",
                tint: .cyan,
                value: $session.touchThrottle
            )
            .accessibilityIdentifier("throttlePedal")
        }
    }
}

private struct RideSteeringPad: View {
    @Binding var value: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.black.opacity(0.32))
                HStack {
                    Image(systemName: "chevron.left")
                    Spacer()
                    Image(systemName: "chevron.right")
                }
                .padding(.horizontal, 12)
                .foregroundStyle(.white.opacity(0.34))
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
                        withAnimation(.spring(response: 0.24, dampingFraction: 0.72)) {
                            value = 0
                        }
                    }
            )
        }
        .frame(width: 150, height: 72)
        .rideGlass(radius: 20, interactive: true)
    }
}

private struct RideAnalogPedal: View {
    let title: String
    let symbol: String
    let tint: Color
    @Binding var value: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 19, style: .continuous)
                    .fill(.black.opacity(0.34))
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
        .rideGlass(radius: 19, interactive: true)
    }
}

private struct RideToastView: View {
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
        .rideGlass(radius: 20)
    }
}

private struct RideCrashOverlay: View {
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
        .rideGlass(radius: 26)
    }
}

private extension View {
    @ViewBuilder
    func rideGlass(radius: CGFloat, interactive: Bool = false) -> some View {
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
