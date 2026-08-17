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
            "TriInfer.ngramSpeculation": false,
            "TriInfer.speculationVerified": false,
        ])

        // Hybrid recurrent Qwen targets need exact recurrent-state rollback for rejected drafts.
        // Never inherit an experimental `true` from an older build unless this exact device/model
        // has passed a future correctness + throughput verification workflow.
        if !UserDefaults.standard.bool(forKey: "TriInfer.speculationVerified") {
            UserDefaults.standard.set(false, forKey: "TriInfer.ngramSpeculation")
        }

        // Keep cold launch deterministic. ModelsView creates BackgroundModelDownloads on demand;
        // iOS background-session relaunches reconnect through TriInferAppDelegate below.
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .task { await model.bootstrap() }
        }
    }
}
