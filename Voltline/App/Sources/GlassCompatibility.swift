import SwiftUI

#if compiler(<6.2)
/// A source-compatible fallback for the iOS 26 Liquid Glass API when the
/// project is compiled by Xcode 16.x. Xcode 26 excludes this declaration and
/// uses SwiftUI's native Glass API instead.
struct VoltlineLegacyGlassStyle {
    static let regular = Self()

    func interactive() -> Self { self }
}

struct VoltlineLegacyGlassShape {
    let cornerRadius: CGFloat

    static func rect(cornerRadius: CGFloat) -> Self {
        Self(cornerRadius: cornerRadius)
    }
}

extension View {
    func glassEffect(
        _ style: VoltlineLegacyGlassStyle,
        in shape: VoltlineLegacyGlassShape
    ) -> some View {
        self
            .background(
                .ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: shape.cornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: shape.cornerRadius, style: .continuous)
                    .stroke(.white.opacity(0.14), lineWidth: 1)
            }
    }
}
#endif
