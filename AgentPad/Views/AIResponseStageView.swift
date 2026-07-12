import SwiftUI

/// The one live-response surface used by Forge.
///
/// The response is an open typefield. Liquid Glass marks the active reading
/// boundary; it never becomes a card, outline, rail, or status pill around the
/// text itself.
struct AIResponseStageView: View {
    @ObservedObject var stream: LiveStreamBuffer
    let isWorking: Bool
    let isHandoffActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var snapshot: LiveTranscriptSnapshot {
        stream.transcriptSnapshot
    }

    var body: some View {
        if isWorking || isHandoffActive {
            HStack {
                LiveTranscriptView(
                    snapshot: snapshot,
                    showsActivity: isWorking && !isHandoffActive
                )
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 44)
            }
            .padding(.horizontal, 18)
            .liquidResponseEntrance(enabled: NovaMotion.enabled(reduceMotion: reduceMotion))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("liveResponseField")
        }
    }
}
