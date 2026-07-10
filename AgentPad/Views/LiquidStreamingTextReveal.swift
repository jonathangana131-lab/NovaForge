import SwiftUI

/// A stable, display-paced live transcript.
///
/// `ForgeLiveFeedEngine` publishes complete word/phrase frames. Rendering the
/// frame as one attributed `Text` keeps wrapping deterministic and lets only
/// the active tail carry a restrained accent. There is intentionally no
/// per-character state, timer, canvas, blur, or repeating animation here.
struct LiquidStreamingTextReveal: View {
    let frame: ForgeLiveFeedFrame

    private var spokenText: String {
        frame.displayText.isEmpty ? "Preparing response" : frame.displayText
    }

    private var flowingText: Text {
        guard !frame.displayText.isEmpty else {
            return Text("Preparing response").foregroundColor(AgentPalette.secondaryText)
        }

        guard !frame.activeTail.isEmpty,
              frame.displayText.hasSuffix(frame.activeTail) else {
            return Text(frame.displayText).foregroundColor(AgentPalette.ink)
        }

        let settledEnd = frame.displayText.index(
            frame.displayText.endIndex,
            offsetBy: -frame.activeTail.count
        )
        var attributed = AttributedString(String(frame.displayText[..<settledEnd]))
        attributed.foregroundColor = AgentPalette.ink

        var activeTail = AttributedString(frame.activeTail)
        activeTail.foregroundColor = AgentPalette.primaryAccent.opacity(0.88)
        attributed.append(activeTail)
        return Text(attributed)
    }

    var body: some View {
        flowingText
            .font(.system(size: 16, weight: .regular, design: AgentPalette.interfaceFontDesign))
            .lineSpacing(5)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 2)
            .accessibilityIdentifier("streamingTextReveal")
            .accessibilityLabel(spokenText)
            .accessibilityValue("\(frame.characterCount) characters streamed")
            .accessibilityHint("Response is still arriving")
            .transaction { transaction in
                // The feed engine owns cadence. Layout interpolation here
                // would make line wrapping wobble while the chat autoscrolls.
                transaction.animation = nil
            }
    }
}

struct LiquidResponseEntranceModifier: ViewModifier {
    let enabled: Bool
    @State private var appeared = false

    func body(content: Content) -> some View {
        content
            .opacity(!enabled || appeared ? 1 : 0)
            .offset(y: !enabled || appeared ? 0 : 4)
            .animation(enabled ? NovaMotion.glassArrival : nil, value: appeared)
            .onAppear { appeared = true }
    }
}

extension View {
    func liquidResponseEntrance(enabled: Bool) -> some View {
        modifier(LiquidResponseEntranceModifier(enabled: enabled))
    }
}
