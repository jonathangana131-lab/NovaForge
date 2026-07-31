import SwiftUI

@main
struct VoltlineGameApp: App {
    @StateObject private var session = GameSession()

    var body: some Scene {
        WindowGroup {
            GameRootView(session: session)
                .background(GameFeedbackBridge(session: session))
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
