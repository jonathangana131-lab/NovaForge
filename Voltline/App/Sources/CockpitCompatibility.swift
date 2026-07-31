import SwiftUI

/// Compatibility entry point used by the one-shot GameRootView integration.
/// The catalog-aware cockpit will replace this narrow wrapper once the
/// KuKirin and Dualtron dashboard renderers are connected.
struct MaxshotFirstPersonCockpitView: View {
    @ObservedObject var session: GameSession

    var body: some View {
        FirstPersonCockpitView(session: session)
    }
}
