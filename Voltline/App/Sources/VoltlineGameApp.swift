import SwiftUI

@main
struct VoltlineGameApp: App {
    @StateObject private var session = GameSession()
    @StateObject private var settings = PlayerExperienceSettings.shared

    var body: some Scene {
        WindowGroup {
            ZStack {
                VoltlineShellView(session: session)
                if settings.hasCompletedOnboarding {
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
