import Foundation
import SwiftUI

@main
struct VoltlineGameApp: App {
    @StateObject private var session = GameSession()
    @StateObject private var settings = PlayerExperienceSettings.shared
    @StateObject private var missions = MissionDirector.shared

    var body: some Scene {
        WindowGroup {
            ZStack {
                VoltlineShellView(session: session)

                if settings.hasCompletedOnboarding {
                    MissionLayerView(session: session)
                        .opacity(
                            session.isPaused && !missions.isBoardPresented
                                ? 0
                                : 1
                        )
                        .allowsHitTesting(
                            !session.isPaused || missions.isBoardPresented
                        )
                }

                if isControlQALaunch {
                    Text(String(format: "%.3f", session.speedMPH))
                        .font(.system(size: 1))
                        .opacity(0.01)
                        .frame(width: 1, height: 1)
                        .position(x: 2, y: 2)
                        .allowsHitTesting(false)
                        .accessibilityHidden(false)
                        .accessibilityIdentifier("qaSpeedMPH")
                }
            }
            .preferredColorScheme(.dark)
            .persistentSystemOverlays(.hidden)
            .onAppear {
                session.applyQAPresentationFixture()
                Task { @MainActor in
                    await Task.yield()
                    session.applyQAPresentationFixture()
                }
            }
        }
    }

    private var isControlQALaunch: Bool {
        ProcessInfo.processInfo.arguments.contains("--qa-controls")
    }
}
