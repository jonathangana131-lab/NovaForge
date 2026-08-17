import SwiftUI

extension View {
    @ViewBuilder
    func triGlass(radius: CGFloat = 22) -> some View {
        if #available(iOS 26.0, *) {
            self
                .padding(1)
                .glassEffect()
        } else {
            self
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
    }
}

struct MetricPill: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.system(.callout, design: .rounded, weight: .semibold)).contentTransition(.numericText())
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct EmptyState: View {
    let symbol: String; let title: String; let message: String
    var body: some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(message))
    }
}
