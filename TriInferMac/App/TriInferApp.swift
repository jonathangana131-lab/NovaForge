import SwiftUI

@main
struct TriInferApp: App {
    @UIApplicationDelegateAdaptor(TriInferAppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    init() {
        _ = BackgroundModelDownloads.shared
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .task { await model.bootstrap() }
        }
    }
}
