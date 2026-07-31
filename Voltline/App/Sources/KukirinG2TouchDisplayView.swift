import SwiftUI

/// 2026 KuKirin G2 155 × 55 mm touchscreen dashboard.
/// Layout is based on the official powered product reference rather than the
/// G2 Master LCD. The two scooters deliberately do not share artwork.
struct KukirinG2TouchDisplayView: View {
    let frame: ScooterDisplayFrame

    private let whiteLED = Color(red: 0.90, green: 0.97, blue: 1.0)
    private let orange = Color(red: 1.0, green: 0.30, blue: 0.025)
    private let inactive = Color(red: 0.12, green: 0.17, blue: 0.19)

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                KukirinG2HousingShape()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.13, green: 0.14, blue: 0.15),
                                Color(red: 0.022, green: 0.024, blue: 0.027),
                                .black
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                KukirinG2HousingShape()
                    .stroke(.white.opacity(0.20), lineWidth: max(1, size.height * 0.014))

                RoundedRectangle(cornerRadius: size.height * 0.085, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.012, green: 0.019, blue: 0.022), .black],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: size.height * 0.085, style: .continuous)
                            .stroke(.white.opacity(0.08), lineWidth: 1)
                    }
                    .padding(.horizontal, size.width * 0.042)
                    .padding(.vertical, size.height * 0.10)

                cornerChevron(mirrored: false)
                    .position(x: size.width * 0.09, y: size.height * 0.20)
                cornerChevron(mirrored: true)
                    .position(x: size.width * 0.91, y: size.height * 0.20)

                displayContent
                    .padding(.horizontal, size.width * 0.075)
                    .padding(.top, size.height * 0.14)
                    .padding(.bottom, size.height * 0.12)
            }
            .drawingGroup(opaque: false, colorMode: .extendedLinear)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilitySummary)
            .accessibilityIdentifier("kukirinG2TouchPhysicalDisplay")
        }
        .aspectRatio(155.0 / 55.0, contentMode: .fit)
    }

    @ViewBuilder
    private var displayContent: some View {
        switch frame.bootPhase {
        case .off:
            EmptyView()
        case .logo(let progress):
            Text("KuKirin")
                .font(.system(size: 28, weight: .black, design: .rounded).italic())
                .foregroundStyle(orange)
                .shadow(color: orange.opacity(0.82), radius: 7)
                .opacity(min(1, progress * 2.5))
        case .segmentTest:
            dashboard(speed: "88", forceAll: true, forcedBattery: 10)
        case .batterySweep(let progress):
            dashboard(speed: "00", forcedBattery: max(1, min(10, Int(progress * 11))))
        case .ready:
            dashboard(speed: String(format: "%02d", displayedKPH))
        }
    }

    private func dashboard(
        speed: String,
        forceAll: Bool = false,
        forcedBattery: Int? = nil
    ) -> some View {
        VStack(spacing: 1) {
            HStack(alignment: .top, spacing: 5) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        icon("speedometer", active: forceAll || frame.telemetry.cruiseActive)
                        icon("light.max", active: forceAll || frame.telemetry.headlightOn)
                    }
                    HStack(spacing: 6) {
                        icon("eye", active: forceAll)
                        Image(systemName: "figure.walk")
                            .foregroundStyle((forceAll || frame.telemetry.mode == .walk ? orange : inactive).opacity(frame.brightness))
                    }
                }
                .font(.system(size: 8, weight: .black))
                .frame(width: 38, alignment: .leading)

                Spacer(minLength: 2)

                HStack(alignment: .lastTextBaseline, spacing: 3) {
                    KukirinG2SegmentText(
                        text: speed,
                        active: whiteLED.opacity(frame.brightness),
                        inactive: inactive.opacity(0.34)
                    )
                    .frame(width: 88, height: 58)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("mph")
                        Text("km/h")
                    }
                    .font(.system(size: 6.2, weight: .black, design: .rounded))
                    .foregroundStyle(whiteLED.opacity(0.74))
                    .padding(.bottom, 5)
                }

                Spacer(minLength: 2)

                Text("KuKirin")
                    .font(.system(size: 14, weight: .black, design: .rounded).italic())
                    .foregroundStyle(orange)
                    .shadow(color: orange.opacity(0.68), radius: 4)
                    .frame(width: 52, alignment: .trailing)
            }

            HStack(spacing: 6) {
                Text("mode")
                    .foregroundStyle(orange)
                Text(modeLabel)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 1.5)
                    .background(orange, in: Capsule())
                    .foregroundStyle(.black)
                Spacer()
            }
            .font(.system(size: 6.2, weight: .black, design: .rounded))

            HStack(alignment: .bottom, spacing: 5) {
                batteryStrip(count: forcedBattery ?? batterySections)
                Spacer(minLength: 6)
                HStack(alignment: .lastTextBaseline, spacing: 1) {
                    Text(String(format: "%05d", Int(frame.telemetry.odometerMiles.rounded())))
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(whiteLED.opacity(frame.brightness))
                    Text("mi")
                        .font(.system(size: 5.5, weight: .black, design: .rounded))
                        .foregroundStyle(whiteLED.opacity(0.64))
                }
            }

            HStack(spacing: 13) {
                touchZone("light")
                touchZone("mode")
                touchZone("set")
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.top, 1)
        }
    }

    private func icon(_ symbol: String, active: Bool) -> some View {
        Image(systemName: symbol)
            .foregroundStyle((active ? whiteLED : inactive).opacity(frame.brightness))
            .shadow(color: active ? whiteLED.opacity(0.55) : .clear, radius: 3)
    }

    private func touchZone(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 5.8, weight: .black, design: .rounded))
            .foregroundStyle(whiteLED.opacity(0.78))
            .frame(width: 37, height: 11)
            .overlay {
                Capsule().stroke(.white.opacity(0.36), lineWidth: 0.8)
            }
    }

    private func batteryStrip(count: Int) -> some View {
        HStack(spacing: 2) {
            Image(systemName: "bolt.slash.circle.fill")
                .font(.system(size: 8, weight: .black))
                .foregroundStyle(orange)
            ForEach(0..<10, id: \.self) { index in
                let active = index < count
                let critical = count <= 2 && index < 2 && frame.filteredVoltage < 42.0
                RoundedRectangle(cornerRadius: 0.7)
                    .fill(
                        active && (!critical || frame.criticalBarVisible)
                            ? (index < 2 ? orange : whiteLED.opacity(frame.brightness))
                            : inactive
                    )
                    .frame(width: 8.5, height: 7)
                    .shadow(
                        color: active ? (index < 2 ? orange.opacity(0.72) : whiteLED.opacity(0.45)) : .clear,
                        radius: 2
                    )
            }
        }
    }

    private func cornerChevron(mirrored: Bool) -> some View {
        KukirinCornerChevron()
            .fill(orange)
            .frame(width: 13, height: 10)
            .rotation3DEffect(.degrees(mirrored ? 180 : 0), axis: (x: 0, y: 1, z: 0))
            .shadow(color: orange.opacity(0.68), radius: 3)
    }

    private var displayedKPH: Int {
        max(0, min(99, Int((frame.telemetry.speedMPH * 1.609344).rounded())))
    }

    private var modeLabel: String {
        switch frame.telemetry.mode {
        case .walk: return "WALK"
        case .eco: return "ECO"
        case .drive: return "DRIVE"
        case .sport: return "RACE"
        }
    }

    private var batterySections: Int {
        min(10, max(1, frame.batterySegments * 2))
    }

    private var accessibilitySummary: String {
        "KuKirin G2 touchscreen, \(displayedKPH) kilometers per hour, \(modeLabel) mode, \(batterySections) battery sections"
    }
}

private struct KukirinG2HousingShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.08, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.08, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.22),
            control: CGPoint(x: rect.maxX - rect.width * 0.02, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.018, y: rect.maxY - rect.height * 0.15))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - rect.width * 0.09, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.09, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + rect.width * 0.018, y: rect.maxY - rect.height * 0.15),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.22))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + rect.width * 0.08, y: rect.minY),
            control: CGPoint(x: rect.minX + rect.width * 0.02, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}

private struct KukirinCornerChevron: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX * 0.58, y: rect.maxY * 0.46))
        path.addLine(to: CGPoint(x: rect.maxX * 0.28, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct KukirinG2SegmentText: View {
    let text: String
    let active: Color
    let inactive: Color

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Array(text.enumerated()), id: \.offset) { _, character in
                KukirinG2SegmentDigit(character: character, active: active, inactive: inactive)
            }
        }
    }
}

private struct KukirinG2SegmentDigit: View {
    let character: Character
    let active: Color
    let inactive: Color

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let thickness = min(width, height) * 0.13
            let segments = activeSegments

            ZStack {
                horizontal(segments.contains(.a)).position(x: width * 0.5, y: thickness * 0.55)
                horizontal(segments.contains(.g)).position(x: width * 0.5, y: height * 0.5)
                horizontal(segments.contains(.d)).position(x: width * 0.5, y: height - thickness * 0.55)
                vertical(segments.contains(.f)).position(x: thickness * 0.55, y: height * 0.27)
                vertical(segments.contains(.b)).position(x: width - thickness * 0.55, y: height * 0.27)
                vertical(segments.contains(.e)).position(x: thickness * 0.55, y: height * 0.73)
                vertical(segments.contains(.c)).position(x: width - thickness * 0.55, y: height * 0.73)
            }

            func horizontal(_ on: Bool) -> some View {
                KukirinLEDBar(horizontal: true)
                    .fill(on ? active : inactive)
                    .frame(width: width - thickness * 1.1, height: thickness)
                    .shadow(color: on ? active.opacity(0.72) : .clear, radius: 3)
            }

            func vertical(_ on: Bool) -> some View {
                KukirinLEDBar(horizontal: false)
                    .fill(on ? active : inactive)
                    .frame(width: thickness, height: height * 0.39)
                    .shadow(color: on ? active.opacity(0.72) : .clear, radius: 3)
            }
        }
    }

    private var activeSegments: Set<Segment> {
        switch character {
        case "0": return [.a, .b, .c, .d, .e, .f]
        case "1": return [.b, .c]
        case "2": return [.a, .b, .d, .e, .g]
        case "3": return [.a, .b, .c, .d, .g]
        case "4": return [.b, .c, .f, .g]
        case "5": return [.a, .c, .d, .f, .g]
        case "6": return [.a, .c, .d, .e, .f, .g]
        case "7": return [.a, .b, .c]
        case "8": return Set(Segment.allCases)
        case "9": return [.a, .b, .c, .d, .f, .g]
        default: return []
        }
    }

    private enum Segment: CaseIterable, Hashable {
        case a, b, c, d, e, f, g
    }
}

private struct KukirinLEDBar: Shape {
    let horizontal: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        if horizontal {
            let bevel = rect.height * 0.46
            path.move(to: CGPoint(x: bevel, y: 0))
            path.addLine(to: CGPoint(x: rect.maxX - bevel, y: 0))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX - bevel, y: rect.maxY))
            path.addLine(to: CGPoint(x: bevel, y: rect.maxY))
            path.addLine(to: CGPoint(x: 0, y: rect.midY))
        } else {
            let bevel = rect.width * 0.46
            path.move(to: CGPoint(x: rect.midX, y: 0))
            path.addLine(to: CGPoint(x: rect.maxX, y: bevel))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bevel))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: 0, y: rect.maxY - bevel))
            path.addLine(to: CGPoint(x: 0, y: bevel))
        }
        path.closeSubpath()
        return path
    }
}
