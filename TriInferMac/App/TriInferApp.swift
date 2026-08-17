import SwiftUI

@main
struct TriInferApp: App {
    @UIApplicationDelegateAdaptor(TriInferAppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    init() {
        UserDefaults.standard.register(defaults: [
            "TriInfer.thermalGuard": true,
            "TriInfer.autoCompact": true,
            "TriInfer.performanceOverlay": true,
            "TriInfer.fastNoThink": true,
            // Multi-token prompt lookup needs recurrent-state rollback snapshots on Qwen3.8's
            // hybrid DeltaNet layers. Keep it off until the device auto-benchmark provisions the
            // rollback budget; never trade correctness for a speculative speed badge.
            "TriInfer.ngramSpeculation": false,
        ])
        _ = BackgroundModelDownloads.shared
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .task { await model.bootstrap() }
        }
    }
}
