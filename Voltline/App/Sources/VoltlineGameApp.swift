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
                if settings.hasCompletedOnboarding,
                   !session.isPaused || missions.isBoardPresented {
                    MissionLayerView(session: session)
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
}
