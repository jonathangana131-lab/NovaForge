//
//  NovaFacelift.swift
//  NovaForge
//
//  The facelift design language: a real typographic ramp, HUD-style
//  telemetry readouts (numbers as instruments, not boxes of zeros),
//  reticle-framed screen headers, and orbital empty states.
//
//  Design intent: NovaForge is a Stark-HUD-flavored instrument, not a
//  form-based app. Numbers should read like cockpit gauges — big
//  monospaced digits sitting directly on the surface — and every screen
//  should open with one confident display-scale statement instead of a
//  stack of identical cards. The ramp is built on Dynamic Type text
//  styles so the whole app finally scales, and every level resolves its
//  Font.Design from the active theme (serif display in White Gold, mono
//  everything in Matrix Rain).
//

import SwiftUI
import UIKit

// MARK: - Typographic ramp

enum NovaType {
    /// Screen-level hero title. The one word the screen is about.
    static var hero: Font {
        .system(.largeTitle, design: AgentPalette.displayFontDesign, weight: .heavy)
    }

    /// Card-level headline — the focal statement inside a hero card.
    static var display: Font {
        .system(.title2, design: AgentPalette.displayFontDesign, weight: .heavy)
    }

    /// Section titles.
    static var title: Font {
        .system(.title3, design: AgentPalette.interfaceFontDesign, weight: .bold)
    }

    /// Row / item headlines.
    static var headline: Font {
        .system(.subheadline, design: AgentPalette.interfaceFontDesign, weight: .bold)
    }

    /// Reading text.
    static var body: Font {
        .system(.footnote, design: AgentPalette.interfaceFontDesign, weight: .semibold)
    }

    /// Supporting captions.
    static var caption: Font {
        .system(.caption, design: AgentPalette.interfaceFontDesign, weight: .semibold)
    }

    /// Tracked uppercase micro-labels (use with .novaLabel()).
    static var label: Font {
        .system(.caption2, design: AgentPalette.interfaceFontDesign, weight: .heavy)
    }

    /// Large instrument numerals for telemetry values.
    static var readout: Font {
        .system(.title3, design: AgentPalette.interfaceFontDesign, weight: .heavy).monospacedDigit()
    }

    /// Hero-scale numerals (readiness %, countdowns).
    static var readoutHero: Font {
        .system(.largeTitle, design: AgentPalette.interfaceFontDesign, weight: .heavy).monospacedDigit()
    }

    /// Compact numerals for inline readouts.
    static var readoutSmall: Font {
        .system(.footnote, design: AgentPalette.interfaceFontDesign, weight: .heavy).monospacedDigit()
    }
}

extension View {
    /// Tracked-uppercase HUD label treatment.
    func novaLabel(_ color: Color = AgentPalette.tertiaryText) -> some View {
        font(NovaType.label)
            .tracking(1.3)
            .textCase(.uppercase)
            .foregroundStyle(color)
            .lineLimit(1)
    }

    /// Kicker line treatment — the tracked strapline above a hero title.
    func novaKickerText(_ color: Color) -> some View {
        font(NovaType.label)
            .tracking(1.8)
            .textCase(.uppercase)
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

// MARK: - Kicker

/// Accent tick + tracked strapline: `▮ PROOF ENGINE // NOVAFORGE`
struct NovaKicker: View {
    let text: String
    var tint: Color = AgentPalette.accent

    var body: some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(tint)
                .frame(width: 3, height: 10)
            Text(text)
                .novaKickerText(AgentPalette.tertiaryText)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Reticle glyph

/// A symbol framed by a targeting reticle — thin circle with four corner
/// ticks. The Stark-HUD replacement for the filled rounded-square icon tile.
struct NovaReticleGlyph: View {
    let symbol: String
    var tint: Color = AgentPalette.accent
    var size: CGFloat = 46
    var isActive: Bool = false

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(tint.opacity(0.34), lineWidth: 1.1)
                .padding(5)
            Circle()
                .trim(from: 0.06, to: 0.19)
                .stroke(tint.opacity(0.85), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .rotationEffect(.degrees(isActive ? 128 : 8))
                .padding(5)
            NovaCornerTicks(tint: tint.opacity(0.55))
            Image(systemName: symbol)
                .font(.system(size: size * 0.36, weight: .semibold))
                .foregroundStyle(tint)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Four corner ticks, the recurring targeting-bracket motif.
struct NovaCornerTicks: View {
    var tint: Color
    var length: CGFloat = 7
    var thickness: CGFloat = 1.4
    var inset: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            let l = length
            Path { path in
                // top-left
                path.move(to: CGPoint(x: inset, y: inset + l))
                path.addLine(to: CGPoint(x: inset, y: inset))
                path.addLine(to: CGPoint(x: inset + l, y: inset))
                // top-right
                path.move(to: CGPoint(x: w - inset - l, y: inset))
                path.addLine(to: CGPoint(x: w - inset, y: inset))
                path.addLine(to: CGPoint(x: w - inset, y: inset + l))
                // bottom-right
                path.move(to: CGPoint(x: w - inset, y: h - inset - l))
                path.addLine(to: CGPoint(x: w - inset, y: h - inset))
                path.addLine(to: CGPoint(x: w - inset - l, y: h - inset))
                // bottom-left
                path.move(to: CGPoint(x: inset + l, y: h - inset))
                path.addLine(to: CGPoint(x: inset, y: h - inset))
                path.addLine(to: CGPoint(x: inset, y: h - inset - l))
            }
            .stroke(tint, style: StrokeStyle(lineWidth: thickness, lineCap: .round, lineJoin: .round))
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Screen header

/// The facelift screen opener: kicker strapline, hero title, status line,
/// and a reticle-framed tab glyph. Replaces HeaderView + banner stacks.
struct NovaScreenHeader<Trailing: View>: View {
    let kicker: String
    let title: String
    let subtitle: String
    let symbol: String
    var tint: Color = AgentPalette.accent
    var isActive: Bool = false
    var showsGlyph: Bool = true
    @ViewBuilder var trailing: Trailing
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(
        kicker: String,
        title: String,
        subtitle: String,
        symbol: String,
        tint: Color = AgentPalette.accent,
        isActive: Bool = false,
        showsGlyph: Bool = true,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.kicker = kicker
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.tint = tint
        self.isActive = isActive
        self.showsGlyph = showsGlyph
        self.trailing = trailing()
    }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    headerText

                    HStack(spacing: 10) {
                        trailing
                        Spacer(minLength: 0)
                        if showsGlyph {
                            NovaReticleGlyph(symbol: symbol, tint: tint, isActive: isActive)
                        }
                    }
                }
            } else {
                HStack(alignment: .center, spacing: 12) {
                    headerText

                    trailing

                    if showsGlyph {
                        NovaReticleGlyph(symbol: symbol, tint: tint, isActive: isActive)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var headerText: some View {
        VStack(alignment: .leading, spacing: 3) {
            NovaKicker(text: kicker, tint: tint)
            Text(title)
                .font(NovaType.hero)
                .foregroundStyle(AgentPalette.ink)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 1 : 0.7)
                .layoutPriority(1)
            Text(subtitle)
                .font(NovaType.caption)
                .foregroundStyle(AgentPalette.secondaryText)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .layoutPriority(1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(subtitle)")
    }
}

// MARK: - Telemetry

struct NovaTelemetryItem: Identifiable, Equatable {
    let label: String
    let value: String
    var tint: Color = AgentPalette.accent
    /// Dim the value when it carries no signal ("0", "—").
    var isEmphasized: Bool = true

    var id: String { label }

    init(_ label: String, _ value: String, tint: Color = AgentPalette.accent, isEmphasized: Bool? = nil) {
        self.label = label
        self.value = value
        self.tint = tint
        self.isEmphasized = isEmphasized ?? !(value == "0" || value == "—" || value.isEmpty)
    }
}

/// The HUD readout line that replaces stat-tile grids: big monospaced
/// numerals sitting directly on the surface, separated by hairlines.
/// Zero-signal values dim to quaternary so live numbers carry the light.
struct NovaTelemetryStrip: View {
    let items: [NovaTelemetryItem]
    var compact: Bool = false
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                    Rectangle()
                        .fill(AgentPalette.divider.opacity(0.55))
                        .frame(width: 1, height: compact ? 20 : 26)
                        .padding(.horizontal, compact ? 10 : 12)
                }
                VStack(alignment: alignment == .center ? .center : .leading, spacing: 2) {
                    Text(item.value)
                        .font(compact ? NovaType.readoutSmall : NovaType.readout)
                        .foregroundStyle(item.isEmphasized ? item.tint : AgentPalette.quaternaryText)
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(item.label)
                        .font(NovaType.label)
                        .tracking(compact ? 0.7 : 1.1)
                        .textCase(.uppercase)
                        .foregroundStyle(item.isEmphasized ? AgentPalette.tertiaryText : AgentPalette.quaternaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.68)
                }
                .frame(maxWidth: .infinity, alignment: alignment == .center ? .center : .leading)
            }
        }
        .animation(.snappy(duration: 0.3), value: items)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(items.map { "\($0.label): \($0.value)" }.joined(separator: ", "))
    }
}

// MARK: - Mission microstrip

/// One quiet line of mission telemetry for screen headers — a radial
/// readiness gauge, phase label, directive, and percent. Replaces the
/// full-width Mission OS banner that used to be pasted on three tabs.
struct NovaMissionMicroStrip: View {
    let phaseName: String
    let directive: String
    let readiness: Int
    var tint: Color = AgentPalette.accent
    var onTap: (() -> Void)? = nil

    var body: some View {
        Button {
            NovaHaptics.tick()
            onTap?()
        } label: {
            HStack(spacing: 9) {
                ZStack {
                    Circle()
                        .stroke(tint.opacity(0.22), lineWidth: 2.4)
                    Circle()
                        .trim(from: 0, to: max(0.04, CGFloat(readiness) / 100))
                        .stroke(tint, style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 15, height: 15)

                Text(phaseName)
                    .novaLabel(tint)
                    .layoutPriority(1)

                Text(directive)
                    .font(NovaType.caption)
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 8)

                Text("\(readiness)%")
                    .font(NovaType.readoutSmall)
                    .foregroundStyle(tint)
                    .contentTransition(.numericText())

                if onTap != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(AgentPalette.quaternaryText)
                }
            }
            .padding(.vertical, 8)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(AgentPalette.divider.opacity(0.5))
                    .frame(height: 0.7)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(onTap == nil)
        .accessibilityLabel("Mission \(phaseName). \(readiness) percent ready. \(directive)")
    }
}

// MARK: - Orbital empty state

/// Empty states as a moment: a glyph inside slow-turning orbital rings
/// with a scanning arc, one display-scale line, and clear actions.
struct NovaOrbitalEmptyState: View {
    struct Action: Identifiable {
        let title: String
        let symbol: String
        var tint: Color = AgentPalette.accent
        var accessibilityIdentifier: String? = nil
        let handler: () -> Void
        var id: String { title }
    }

    let symbol: String
    let title: String
    let detail: String
    var tint: Color = AgentPalette.accent
    var actions: [Action] = []

    @State private var spin = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var allowsMotion: Bool {
        AgentPerformance.allowsDecorativeMotion && !reduceMotion
    }

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .stroke(tint.opacity(0.30), style: StrokeStyle(lineWidth: 1, dash: [1, 6.5]))
                    .frame(width: 118, height: 118)
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(
                        allowsMotion ? .linear(duration: 46).repeatForever(autoreverses: false) : nil,
                        value: spin
                    )
                Circle()
                    .strokeBorder(tint.opacity(0.22), lineWidth: 1)
                    .frame(width: 86, height: 86)
                Circle()
                    .trim(from: 0.60, to: 0.86)
                    .stroke(
                        AngularGradient(
                            colors: [tint.opacity(0), tint.opacity(0.9)],
                            center: .center,
                            startAngle: .degrees(216),
                            endAngle: .degrees(310)
                        ),
                        style: StrokeStyle(lineWidth: 1.8, lineCap: .round)
                    )
                    .frame(width: 86, height: 86)
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(
                        allowsMotion ? .linear(duration: 7).repeatForever(autoreverses: false) : nil,
                        value: spin
                    )
                Circle()
                    .fill(tint.opacity(0.10))
                    .frame(width: 58, height: 58)
                Image(systemName: symbol)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .onAppear { spin = true }
            .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text(title)
                    .font(NovaType.title)
                    .foregroundStyle(AgentPalette.ink)
                    .multilineTextAlignment(.center)
                Text(detail)
                    .font(NovaType.body)
                    .foregroundStyle(AgentPalette.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 300)
            }

            if !actions.isEmpty {
                HStack(spacing: 10) {
                    ForEach(actions) { action in
                        NovaCapsuleButton(
                            title: action.title,
                            symbol: action.symbol,
                            tint: action.tint,
                            accessibilityIdentifier: action.accessibilityIdentifier,
                            action: action.handler
                        )
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 34)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Reactor gauge

/// The arc-reactor progress instrument: a fine tick ring, a glowing
/// progress arc, and instrument numerals in the core. Replaces linear
/// progress bars on hero surfaces — the same mark as the app icon.
struct NovaReactorGauge: View {
    let fraction: Double
    let value: String
    let label: String
    var tint: Color = AgentPalette.accent
    var size: CGFloat = 76
    var isLive: Bool = false

    private var clamped: Double { min(1, max(0, fraction)) }

    var body: some View {
        ZStack {
            // fine tick ring
            ForEach(0..<36, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(
                        Double(index) / 36.0 <= clamped && clamped > 0
                            ? tint.opacity(0.55)
                            : AgentPalette.quaternaryText.opacity(0.35)
                    )
                    .frame(width: 1.4, height: index % 9 == 0 ? 6 : 3.5)
                    .offset(y: -size / 2 + 3)
                    .rotationEffect(.degrees(Double(index) * 10))
            }

            // track + progress arc
            Circle()
                .stroke(tint.opacity(0.14), lineWidth: 4.5)
                .padding(size * 0.14)
            Circle()
                .trim(from: 0, to: max(0.02, clamped))
                .stroke(
                    AngularGradient(
                        colors: [tint.opacity(0.35), tint],
                        center: .center,
                        startAngle: .degrees(0),
                        endAngle: .degrees(360 * clamped)
                    ),
                    style: StrokeStyle(lineWidth: 4.5, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .padding(size * 0.14)
                .shadow(
                    color: AgentPerformance.prefersReducedVisualEffects || !isLive ? .clear : tint.opacity(0.55),
                    radius: 5
                )

            // core numerals
            VStack(spacing: 0) {
                Text(value)
                    .font(.system(size: size * 0.21, weight: .heavy, design: AgentPalette.interfaceFontDesign))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(label)
                    .font(.system(size: size * 0.095, weight: .heavy, design: AgentPalette.interfaceFontDesign))
                    .tracking(1.0)
                    .textCase(.uppercase)
                    .foregroundStyle(AgentPalette.tertiaryText)
                    .lineLimit(1)
            }
            .padding(.horizontal, size * 0.2)
        }
        .frame(width: size, height: size)
        .animation(.smooth(duration: 0.5), value: clamped)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value)")
        .accessibilityValue("\(Int((clamped * 100).rounded())) percent")
    }
}

// MARK: - Capsule button

struct NovaCapsuleButton: View {
    let title: String
    var symbol: String? = nil
    var tint: Color = AgentPalette.accent
    var prominent: Bool = true
    var accessibilityIdentifier: String? = nil
    let action: () -> Void

    var body: some View {
        Button {
            NovaHaptics.tick()
            action()
        } label: {
            HStack(spacing: 7) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .bold))
                }
                Text(title)
                    .font(NovaType.headline)
                    .lineLimit(1)
            }
            .foregroundStyle(prominent ? tint : AgentPalette.secondaryText)
            .padding(.horizontal, 18)
            .frame(minHeight: AgentDesign.minimumTouchTarget)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background(
            Capsule(style: .continuous)
                .fill(tint.opacity(prominent ? 0.14 : 0.05))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(tint.opacity(prominent ? 0.32 : 0.14), lineWidth: 0.8)
        )
        .accessibilityIdentifier(accessibilityIdentifier ?? title)
    }
}

// MARK: - Section header (facelift)

/// Display-weight section marker: hairline rule + tracked title + optional
/// trailing readout. Sits directly on the background — no card.
struct NovaSectionMark: View {
    let title: String
    var detail: String? = nil
    var tint: Color = AgentPalette.accent

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .novaKickerText(AgentPalette.secondaryText)
                .layoutPriority(1)
            Rectangle()
                .fill(AgentPalette.divider.opacity(0.5))
                .frame(height: 0.7)
            if let detail {
                Text(detail)
                    .font(NovaType.readoutSmall)
                    .foregroundStyle(tint)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(detail == nil ? title : "\(title). \(detail ?? "")")
    }
}

// MARK: - Haptics vocabulary extension

extension NovaHaptics {
    /// Lens/filter change — the light ratchet click.
    static func lensChanged() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    /// A sheet or drawer surfacing.
    static func surfaceRevealed() {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.8)
    }
}

// MARK: - Mission-requested glass primitives

/// Reusable high-level glass panel. Prefer this for large screen regions that
/// need one readable surface without re-creating gradients in feature views.
struct NovaGlassPanel<Content: View>: View {
    var tint: Color = AgentPalette.accent
    var radius: CGFloat = AgentDesign.panelRadius
    private let content: Content

    init(tint: Color = AgentPalette.accent, radius: CGFloat = AgentDesign.panelRadius, @ViewBuilder content: () -> Content) {
        self.tint = tint
        self.radius = radius
        self.content = content()
    }

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .agentSurface(radius: radius, tint: tint.opacity(0.07))
    }
}

/// Compact card primitive for rows, receipts, and inline proof blocks.
struct NovaGlassCard<Content: View>: View {
    var tint: Color = AgentPalette.accent
    var selected = false
    private let content: Content

    init(tint: Color = AgentPalette.accent, selected: Bool = false, @ViewBuilder content: () -> Content) {
        self.tint = tint
        self.selected = selected
        self.content = content()
    }

    var body: some View {
        content
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .agentRowSurface(radius: AgentDesign.rowRadius, tint: tint.opacity(0.08), selected: selected)
    }
}

struct NovaGlassToolbar<Content: View>: View {
    var tint: Color = AgentPalette.accent
    private let content: Content

    init(tint: Color = AgentPalette.accent, @ViewBuilder content: () -> Content) {
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 8) { content }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .agentGlass(radius: 22, interactive: true, tint: tint.opacity(0.08))
    }
}

struct NovaGlassSheetBackground: View {
    var tint: Color = AgentPalette.accent
    var lightweight = false

    @ViewBuilder
    var body: some View {
        if lightweight {
            ZStack {
                Rectangle()
                    .fill(.thinMaterial)
                AgentPalette.surface.opacity(AgentPalette.isLight ? 0.72 : 0.54)
                LinearGradient(
                    colors: [tint.opacity(0.15), Color.clear, AgentPalette.surface.opacity(0.24)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            .ignoresSafeArea()
        } else {
            AgentBackground()
                .overlay(
                    LinearGradient(
                        colors: [tint.opacity(0.12), Color.clear, AgentPalette.surface.opacity(0.30)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .ignoresSafeArea()
        }
    }
}

struct NovaGlassStatusChip: View {
    let title: String
    var symbol: String = "sparkles"
    var tint: Color = AgentPalette.accent

    var body: some View {
        StatusChip(text: title, symbol: symbol, tint: tint)
            .minimumTapTarget()
    }
}

struct NovaGlassTextFieldBackground: ViewModifier {
    var focused: Bool
    var tint: Color = AgentPalette.accent

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .composerGlassSurface(focused: focused, tint: tint, style: .default)
    }
}

struct NovaGlassDivider: View {
    var tint: Color = AgentPalette.accent

    var body: some View {
        LinearGradient(
            colors: [Color.clear, tint.opacity(0.34), AgentPalette.divider.opacity(0.55), Color.clear],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(height: 1)
        .accessibilityHidden(true)
    }
}

struct NovaGlassEmptyState: View {
    let symbol: String
    let title: String
    let detail: String
    var tint: Color = AgentPalette.accent
    var actions: [NovaOrbitalEmptyState.Action] = []

    var body: some View {
        NovaOrbitalEmptyState(
            symbol: symbol,
            title: title,
            detail: detail,
            tint: tint,
            actions: actions
        )
    }
}

extension View {
    func novaGlassTextFieldBackground(focused: Bool, tint: Color = AgentPalette.accent) -> some View {
        modifier(NovaGlassTextFieldBackground(focused: focused, tint: tint))
    }
}
