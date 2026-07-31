import SwiftUI

/// Catalog-aware first-person cockpit. The handlebar display is the normal
/// source of speed, mode and battery information; no duplicate corner gauge is
/// needed. Every display keeps its own physical aspect ratio and state machine.
struct CatalogFirstPersonCockpitView: View {
    @ObservedObject var session: GameSession
    @StateObject private var runtime = LiveCatalogDisplayRuntime()

    var body: some View {
        GeometryReader { proxy in
            if session.camera == .pov {
                let width = proxy.size.width
                let height = proxy.size.height
                let barWidth = min(width * 0.70, 610)
                let barY = height - 54
                let geometry = displayGeometry(width: width, height: height)

                ZStack {
                    cockpitStem(width: geometry.width)
                        .position(x: width * 0.5, y: height - 60)

                    handlebar(width: barWidth)
                        .position(x: width * 0.5, y: barY)

                    grip
                        .position(x: width * 0.5 - barWidth * 0.47, y: barY)
                    grip
                        .position(x: width * 0.5 + barWidth * 0.47, y: barY)

                    brakeLever(width: barWidth)
                        .position(x: width * 0.5 - barWidth * 0.35, y: barY + 22)

                    throttlePaddle
                        .position(x: width * 0.5 + barWidth * 0.34, y: barY + 21)

                    riderHand(mirrored: false)
                        .position(x: width * 0.5 - barWidth * 0.45, y: barY + 18)
                    riderHand(mirrored: true)
                        .position(x: width * 0.5 + barWidth * 0.45, y: barY + 18)

                    displayMount(width: geometry.width, height: geometry.height)
                        .position(x: width * 0.5, y: geometry.centerY)
                }
                .rotationEffect(.radians(session.renderSnapshot.rollRadians * -0.22), anchor: .bottom)
                .offset(
                    x: CGFloat(session.renderSnapshot.steeringRadians) * 22,
                    y: CGFloat(max(-0.04, min(0.05, session.renderSnapshot.pitchRadians))) * 90
                )
                .shadow(color: .black.opacity(0.46), radius: 12, y: 6)
                .transition(.opacity)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("catalogFirstPersonCockpit")
            }
        }
        .allowsHitTesting(false)
        .onAppear { updateRuntime(at: session.gameSeconds, reset: true) }
        .onChange(of: session.gameSeconds) { _, time in
            updateRuntime(at: time, reset: false)
        }
        .onChange(of: session.selectedScooterID) { _, _ in
            updateRuntime(at: session.gameSeconds, reset: true)
        }
    }

    private func updateRuntime(at time: Double, reset: Bool) {
        runtime.advance(
            telemetry: session.physicalDisplayTelemetry,
            identity: CatalogDisplayProfileResolver.identity(for: session.selectedScooterID),
            absoluteTime: time,
            reset: reset
        )
    }

    private func displayGeometry(width: CGFloat, height: CGFloat) -> (width: CGFloat, height: CGFloat, centerY: CGFloat) {
        switch session.selectedScooterID {
        case ScooterCatalogItem.kukirin.id:
            let displayWidth = min(max(width * 0.205, 152), 190)
            return (displayWidth, displayWidth / (133.0 / 76.0), height - 112)
        case ScooterCatalogItem.dualtron.id:
            let displayWidth = min(max(width * 0.245, 190), 235)
            return (displayWidth, displayWidth / 2.05, height - 112)
        default:
            let displayWidth = min(max(width * 0.105, 78), 102)
            return (displayWidth, displayWidth / 0.55, height - 122)
        }
    }

    private func displayMount(width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            mountHousing(width: width, height: height)

            CatalogPhysicalDisplayView(
                scooterID: session.selectedScooterID,
                frame: runtime.frame
            )
            .padding(mountPadding(width: width))
        }
        .frame(width: width, height: height)
    }

    private func mountHousing(width: CGFloat, height: CGFloat) -> some View {
        Group {
            if session.selectedScooterID == ScooterCatalogItem.kukirin.id {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color(red: 0.015, green: 0.018, blue: 0.021))
                    .overlay {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(.green.opacity(0.20), lineWidth: 2)
                    }
            } else if session.selectedScooterID == ScooterCatalogItem.dualtron.id {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(red: 0.018, green: 0.020, blue: 0.024))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(.cyan.opacity(0.38), lineWidth: 2)
                    }
            } else {
                RoundedRectangle(cornerRadius: width * 0.22, style: .continuous)
                    .fill(Color(red: 0.018, green: 0.021, blue: 0.027))
                    .overlay {
                        RoundedRectangle(cornerRadius: width * 0.22, style: .continuous)
                            .stroke(.white.opacity(0.14), lineWidth: 2)
                    }
            }
        }
        .shadow(color: .black.opacity(0.92), radius: 13, y: 8)
    }

    private func mountPadding(width: CGFloat) -> CGFloat {
        session.selectedScooterID == ScooterCatalogItem.maxshot.id ? width * 0.055 : width * 0.025
    }

    private func cockpitStem(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 13, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [accent.opacity(0.36), Color(red: 0.018, green: 0.022, blue: 0.030)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(width: max(34, min(58, width * 0.30)), height: 120)
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(.white.opacity(0.12), lineWidth: 1)
            }
    }

    private func handlebar(width: CGFloat) -> some View {
        Capsule()
            .fill(
                LinearGradient(
                    colors: [
                        Color(red: 0.40, green: 0.43, blue: 0.48),
                        Color(red: 0.045, green: 0.052, blue: 0.065),
                        Color(red: 0.26, green: 0.28, blue: 0.32)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: width, height: session.selectedScooterID == ScooterCatalogItem.maxshot.id ? 18 : 22)
            .overlay { Capsule().stroke(.white.opacity(0.18), lineWidth: 1) }
            .shadow(color: .black.opacity(0.8), radius: 8, y: 5)
    }

    private var grip: some View {
        Capsule()
            .fill(
                LinearGradient(
                    colors: [Color(red: 0.055, green: 0.060, blue: 0.070), .black, Color(red: 0.085, green: 0.090, blue: 0.100)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay {
                HStack(spacing: 4) {
                    ForEach(0..<8, id: \.self) { _ in
                        Rectangle().fill(.white.opacity(0.07)).frame(width: 2)
                    }
                }
                .clipShape(Capsule())
            }
            .frame(width: 118, height: 30)
    }

    private func brakeLever(width: CGFloat) -> some View {
        Capsule()
            .fill(
                LinearGradient(
                    colors: [.white.opacity(0.55), Color(red: 0.10, green: 0.11, blue: 0.13)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: width * 0.17, height: 9)
            .rotationEffect(.degrees(12 + session.touchBrake * 12), anchor: .trailing)
            .shadow(color: .black.opacity(0.8), radius: 4, y: 3)
    }

    private var throttlePaddle: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(
                LinearGradient(colors: [accent.opacity(0.88), accent.opacity(0.28)], startPoint: .top, endPoint: .bottom)
            )
            .frame(width: 31, height: 45)
            .rotationEffect(.degrees(-8 - session.touchThrottle * 8), anchor: .top)
            .overlay {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(.white.opacity(0.86))
            }
            .shadow(color: accent.opacity(0.32), radius: 7)
    }

    private func riderHand(mirrored: Bool) -> some View {
        ZStack {
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.66, green: 0.45, blue: 0.34), Color(red: 0.40, green: 0.24, blue: 0.18)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 74, height: 38)

            ForEach(0..<4, id: \.self) { index in
                Capsule()
                    .fill(Color(red: 0.55, green: 0.35, blue: 0.26))
                    .frame(width: 13, height: 42)
                    .offset(x: CGFloat(index - 2) * 11, y: -11)
                    .rotationEffect(.degrees(Double(index - 2) * 2))
            }
        }
        .rotation3DEffect(.degrees(mirrored ? 180 : 0), axis: (x: 0, y: 1, z: 0))
        .rotationEffect(.degrees(mirrored ? -5 : 5))
        .shadow(color: .black.opacity(0.65), radius: 7, y: 5)
    }

    private var accent: Color {
        switch session.selectedScooterID {
        case ScooterCatalogItem.kukirin.id: return Color(red: 0.20, green: 0.82, blue: 0.48)
        case ScooterCatalogItem.dualtron.id: return Color(red: 0.05, green: 0.70, blue: 1.0)
        default: return .cyan
        }
    }
}

@MainActor
private final class LiveCatalogDisplayRuntime: ObservableObject {
    @Published private(set) var frame: ScooterDisplayFrame

    private var computer = ScooterDisplayComputer()
    private var lastAbsoluteTime: Double?
    private var activeIdentityID: String?

    init() {
        var initial = ScooterDisplayComputer()
        frame = initial.update(
            telemetry: .preview,
            profile: .maxshot36V,
            deltaTime: 0,
            ambientLuminance: 0.06,
            absoluteTime: 0
        )
    }

    func advance(
        telemetry: ScooterDisplayTelemetry,
        identity: ScooterDisplayIdentity,
        absoluteTime: Double,
        reset: Bool
    ) {
        if reset || activeIdentityID != identity.id {
            computer.reset()
            lastAbsoluteTime = nil
            activeIdentityID = identity.id
        }

        let deltaTime: Double
        if let lastAbsoluteTime {
            deltaTime = max(0, min(0.1, absoluteTime - lastAbsoluteTime))
        } else {
            deltaTime = 0
        }
        self.lastAbsoluteTime = absoluteTime

        frame = computer.update(
            telemetry: telemetry,
            profile: identity.batteryProfile,
            deltaTime: deltaTime,
            ambientLuminance: 0.06,
            absoluteTime: absoluteTime
        )
    }
}
