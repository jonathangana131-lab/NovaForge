import Combine
import SwiftUI

/// A first-person cockpit that makes the scooter's real handlebar display the
/// primary source of riding information. It never accepts touches, so the
/// existing analog steering, brake and throttle controls remain unobstructed.
struct FirstPersonCockpitView: View {
    @ObservedObject var session: GameSession
    @StateObject private var displayRuntime = LiveMaxshotDisplayRuntime()

    var body: some View {
        GeometryReader { proxy in
            if session.camera == .pov,
               session.selectedScooterID == ScooterCatalogItem.maxshot.id {
                let width = proxy.size.width
                let height = proxy.size.height
                let barWidth = min(width * 0.68, 590)
                let barY = height - 56
                let displayWidth = min(max(width * 0.105, 78), 102)

                ZStack {
                    // Stem and mounting collar sit behind the display, matching
                    // the order a rider sees them on the physical scooter.
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.12, green: 0.14, blue: 0.17),
                                    Color(red: 0.018, green: 0.022, blue: 0.030)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: 32, height: 118)
                        .overlay {
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .stroke(.white.opacity(0.12), lineWidth: 1)
                        }
                        .position(x: width * 0.5, y: height - 61)

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
                        .frame(width: barWidth, height: 18)
                        .overlay {
                            Capsule().stroke(.white.opacity(0.18), lineWidth: 1)
                        }
                        .shadow(color: .black.opacity(0.8), radius: 8, y: 5)
                        .position(x: width * 0.5, y: barY)

                    grip(at: width * 0.5 - barWidth * 0.47, y: barY)
                    grip(at: width * 0.5 + barWidth * 0.47, y: barY)

                    brakeLever(width: barWidth)
                        .position(x: width * 0.5 - barWidth * 0.35, y: barY + 22)

                    throttlePaddle
                        .position(x: width * 0.5 + barWidth * 0.34, y: barY + 21)

                    riderHand(mirrored: false)
                        .position(x: width * 0.5 - barWidth * 0.45, y: barY + 18)
                    riderHand(mirrored: true)
                        .position(x: width * 0.5 + barWidth * 0.45, y: barY + 18)

                    ZStack {
                        RoundedRectangle(cornerRadius: displayWidth * 0.22, style: .continuous)
                            .fill(Color(red: 0.018, green: 0.021, blue: 0.027))
                            .overlay {
                                RoundedRectangle(cornerRadius: displayWidth * 0.22, style: .continuous)
                                    .stroke(
                                        LinearGradient(
                                            colors: [.white.opacity(0.20), .black, .white.opacity(0.06)],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        ),
                                        lineWidth: 2
                                    )
                            }
                            .shadow(color: .black.opacity(0.92), radius: 13, y: 8)

                        MaxshotPhysicalDisplayView(frame: displayRuntime.frame)
                            .padding(displayWidth * 0.055)
                    }
                    .frame(width: displayWidth, height: displayWidth / 0.55)
                    .position(x: width * 0.5, y: height - 122)
                }
                .rotationEffect(.radians(session.renderSnapshot.rollRadians * -0.22), anchor: .bottom)
                .offset(
                    x: CGFloat(session.renderSnapshot.steeringRadians) * 22,
                    y: CGFloat(max(-0.04, min(0.05, session.renderSnapshot.pitchRadians))) * 90
                )
                .shadow(color: .black.opacity(0.45), radius: 12, y: 6)
                .transition(.opacity)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("firstPersonCockpit")
            }
        }
        .allowsHitTesting(false)
        .onAppear {
            displayRuntime.advance(
                telemetry: session.physicalDisplayTelemetry,
                absoluteTime: session.gameSeconds
            )
        }
        .onChange(of: session.gameSeconds) { _, newTime in
            displayRuntime.advance(
                telemetry: session.physicalDisplayTelemetry,
                absoluteTime: newTime
            )
        }
    }

    private func grip(at x: CGFloat, y: CGFloat) -> some View {
        Capsule()
            .fill(
                LinearGradient(
                    colors: [
                        Color(red: 0.055, green: 0.060, blue: 0.070),
                        .black,
                        Color(red: 0.085, green: 0.090, blue: 0.100)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay {
                HStack(spacing: 4) {
                    ForEach(0..<8, id: \.self) { _ in
                        Rectangle()
                            .fill(.white.opacity(0.07))
                            .frame(width: 2)
                    }
                }
                .clipShape(Capsule())
            }
            .frame(width: 118, height: 30)
            .position(x: x, y: y)
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
                LinearGradient(
                    colors: [Color.cyan.opacity(0.85), Color(red: 0.025, green: 0.20, blue: 0.28)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: 31, height: 45)
            .rotationEffect(.degrees(-8 - session.touchThrottle * 8), anchor: .top)
            .overlay {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .shadow(color: .cyan.opacity(0.28), radius: 7)
    }

    private func riderHand(mirrored: Bool) -> some View {
        ZStack {
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.66, green: 0.45, blue: 0.34),
                            Color(red: 0.40, green: 0.24, blue: 0.18)
                        ],
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
}

@MainActor
private final class LiveMaxshotDisplayRuntime: ObservableObject {
    @Published private(set) var frame: ScooterDisplayFrame

    private var computer = ScooterDisplayComputer()
    private var lastAbsoluteTime: Double?

    init() {
        var initialComputer = ScooterDisplayComputer()
        frame = initialComputer.update(
            telemetry: .preview,
            profile: .maxshot36V,
            deltaTime: 0,
            ambientLuminance: 0.06,
            absoluteTime: 0
        )
    }

    func advance(telemetry: ScooterDisplayTelemetry, absoluteTime: Double) {
        let deltaTime: Double
        if let lastAbsoluteTime {
            deltaTime = max(0, min(0.1, absoluteTime - lastAbsoluteTime))
        } else {
            deltaTime = 0
        }
        self.lastAbsoluteTime = absoluteTime

        frame = computer.update(
            telemetry: telemetry,
            profile: .maxshot36V,
            deltaTime: deltaTime,
            ambientLuminance: 0.06,
            absoluteTime: absoluteTime
        )
    }
}
