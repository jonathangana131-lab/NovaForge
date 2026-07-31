import SwiftUI

@main
struct VoltlineGameApp: App {
    @StateObject private var session = GameSession()

    var body: some Scene {
        WindowGroup {
            ZStack {
                VoltlineShellView(session: session)
                MissionLayerView(session: session)
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
