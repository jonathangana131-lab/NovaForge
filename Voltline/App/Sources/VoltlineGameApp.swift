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
        }
    }
}
