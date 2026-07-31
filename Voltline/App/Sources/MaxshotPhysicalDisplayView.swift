import SwiftUI

/// High-detail physical dashboard renderer for the Maxshot V1S Pro.
/// This view is intended to be placed on the modeled handlebar display surface,
/// not duplicated as a floating corner HUD.
struct MaxshotPhysicalDisplayView: View {
    let frame: ScooterDisplayFrame

    private let ledWhite = Color(red: 0.78, green: 0.94, blue: 1.0)
    private let ledBlue = Color(red: 0.19, green: 0.72, blue: 1.0)
    private let inactiveIcon = Color(red: 0.10, green: 0.18, blue: 0.24)

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                lens(size: size)

                switch frame.bootPhase {
                case .off:
                    EmptyView()
                case .logo(let progress):
                    bootLogo(progress: progress)
                case .segmentTest:
                    dashboard(speedText: "88", forceAllIcons: true)
                case .batterySweep(let progress):
                    dashboard(
                        speedText: "00",
                        forcedBatterySegments: max(1, min(5, Int(progress * 6)))
                    )
                case .ready:
                    dashboard(speedText: displayedSpeed)
                }
            }
            .frame(width: size.width, height: size.height)
            .drawingGroup(opaque: false, colorMode: .extendedLinear)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilitySummary)
            .accessibilityIdentifier("maxshotPhysicalDisplay")
        }
        .aspectRatio(0.55, contentMode: .fit)
    }

    private func lens(size: CGSize) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: size.width * 0.19, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.018, green: 0.025, blue: 0.034),
                            .black,
                            Color(red: 0.012, green: 0.018, blue: 0.025)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            RoundedRectangle(cornerRadius: size.width * 0.19, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            .white.opacity(0.08),
                            .clear,
                            .cyan.opacity(0.025),
                            .clear
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .blendMode(.screen)

            RoundedRectangle(cornerRadius: size.width * 0.19, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.15), .black, .white.opacity(0.06)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: max(1, size.width * 0.008)
                )
        }
        .shadow(color: .black.opacity(0.9), radius: size.width * 0.10, y: size.height * 0.025)
    }

    @ViewBuilder
    private func dashboard(
        speedText: String,
        forceAllIcons: Bool = false,
        forcedBatterySegments: Int? = nil
    ) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 14)

            HStack(alignment: .bottom, spacing: 5) {
                SevenSegmentText(
                    text: speedText,
                    activeColor: ledWhite.opacity(frame.brightness),
                    inactiveColor: ledBlue.opacity(0.035),
                    thicknessRatio: 0.13,
                    slantRatio: 0.11
                )
                .frame(width: 164, height: 103)

                Text("mph")
                    .font(.system(size: 11, weight: .bold, design: .rounded).italic())
                    .foregroundStyle(ledWhite.opacity(0.94 * frame.brightness))
                    .padding(.bottom, 8)
                    .shadow(color: ledBlue.opacity(0.85), radius: 5)
            }
            .shadow(color: ledBlue.opacity(0.85 * frame.brightness), radius: 9)

            Text(frame.telemetry.mode.rawValue)
                .font(.system(size: frame.telemetry.mode == .eco ? 25 : 22, weight: .heavy, design: .rounded).italic())
                .foregroundStyle(frame.telemetry.mode.displayColor.opacity(frame.brightness))
                .shadow(color: frame.telemetry.mode.displayColor.opacity(0.8), radius: 7)
                .frame(height: 39)

            statusIcons(forceAll: forceAllIcons)
                .frame(height: 42)

            batteryBars(count: forcedBatterySegments ?? frame.batterySegments)
                .frame(height: 27)
                .padding(.top, 3)

            Spacer(minLength: 19)
        }
        .padding(.horizontal, 18)
    }

    private func bootLogo(progress: Double) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 43, weight: .black))
                .foregroundStyle(ledWhite)
                .shadow(color: ledBlue, radius: 13)
                .scaleEffect(0.84 + 0.16 * max(0, min(progress, 1)))
            Text("MAXSHOT")
                .font(.system(size: 15, weight: .black, design: .rounded))
                .tracking(2.4)
                .foregroundStyle(ledWhite)
                .shadow(color: ledBlue, radius: 7)
        }
        .opacity(min(1, progress * 2.5))
    }

    private func statusIcons(forceAll: Bool) -> some View {
        HStack(spacing: 19) {
            displayIcon(
                "thermometer.medium",
                active: forceAll || frame.telemetry.controllerTemperatureC >= 75,
                activeColor: .orange
            )
            displayIcon(
                frame.telemetry.fault == nil ? "wrench.adjustable" : "exclamationmark.triangle.fill",
                active: forceAll || frame.telemetry.fault != nil,
                activeColor: .red
            )
            displayIcon(
                "speedometer",
                active: forceAll || frame.telemetry.cruiseActive,
                activeColor: ledWhite
            )
            displayIcon(
                "lightbulb.max.fill",
                active: forceAll || frame.telemetry.headlightOn,
                activeColor: ledWhite
            )
        }
    }

    private func displayIcon(_ symbol: String, active: Bool, activeColor: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(active ? activeColor.opacity(frame.brightness) : inactiveIcon.opacity(0.50))
            .shadow(color: active ? activeColor.opacity(0.75) : .clear, radius: 6)
            .frame(width: 25)
    }

    private func batteryBars(count: Int) -> some View {
        HStack(spacing: 6) {
            ForEach(0..<5, id: \.self) { index in
                let isOn = index < count
                let critical = count == 1 && index == 0 && frame.filteredVoltage < 33.5
                RoundedRectangle(cornerRadius: 1.8)
                    .fill(
                        isOn && (!critical || frame.criticalBarVisible)
                            ? (critical ? Color.red : ledWhite.opacity(frame.brightness))
                            : ledBlue.opacity(0.035)
                    )
                    .frame(width: 26, height: 10)
                    .shadow(
                        color: isOn
                            ? (critical ? Color.red.opacity(0.9) : ledBlue.opacity(0.82))
                            : .clear,
                        radius: 6
                    )
            }
        }
    }

    private var displayedSpeed: String {
        let rounded = max(0, min(99, Int(frame.telemetry.speedMPH.rounded())))
        return String(format: "%02d", rounded)
    }

    private var accessibilitySummary: String {
        let faultText = frame.telemetry.fault.map { ", fault \($0.code)" } ?? ""
        return "Maxshot display, \(Int(frame.telemetry.speedMPH.rounded())) miles per hour, \(frame.telemetry.mode.rawValue) mode, \(frame.batterySegments) battery bars\(faultText)"
    }
}

// MARK: - Beveled seven-segment rendering

private struct SevenSegmentText: View {
    let text: String
    let activeColor: Color
    let inactiveColor: Color
    let thicknessRatio: CGFloat
    let slantRatio: CGFloat

    var body: some View {
        HStack(spacing: 7) {
            ForEach(Array(text.enumerated()), id: \.offset) { _, character in
                SevenSegmentDigit(
                    character: character,
                    activeColor: activeColor,
                    inactiveColor: inactiveColor,
                    thicknessRatio: thicknessRatio,
                    slantRatio: slantRatio
                )
            }
        }
    }
}

private struct SevenSegmentDigit: View {
    let character: Character
    let activeColor: Color
    let inactiveColor: Color
    let thicknessRatio: CGFloat
    let slantRatio: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let thickness = min(width, height) * thicknessRatio
            let slant = thickness * (1 + slantRatio)
            let inset = thickness * 0.42
            let segmentLength = height * 0.40
            let active = activeSegments

            ZStack {
                segment(.a, active: active.contains(.a), width: width - thickness * 1.05, height: thickness, slant: slant)
                    .position(x: width / 2, y: inset + thickness / 2)
                segment(.g, active: active.contains(.g), width: width - thickness * 1.05, height: thickness, slant: slant)
                    .position(x: width / 2, y: height / 2)
                segment(.d, active: active.contains(.d), width: width - thickness * 1.05, height: thickness, slant: slant)
                    .position(x: width / 2, y: height - inset - thickness / 2)

                verticalSegment(active: active.contains(.f), width: thickness, height: segmentLength, slant: slant)
                    .position(x: inset + thickness / 2, y: height * 0.265)
                verticalSegment(active: active.contains(.b), width: thickness, height: segmentLength, slant: slant)
                    .position(x: width - inset - thickness / 2, y: height * 0.265)
                verticalSegment(active: active.contains(.e), width: thickness, height: segmentLength, slant: slant)
                    .position(x: inset + thickness / 2, y: height * 0.735)
                verticalSegment(active: active.contains(.c), width: thickness, height: segmentLength, slant: slant)
                    .position(x: width - inset - thickness / 2, y: height * 0.735)
            }
        }
    }

    private func segment(
        _ segment: Segment,
        active: Bool,
        width: CGFloat,
        height: CGFloat,
        slant: CGFloat
    ) -> some View {
        BeveledSegment(horizontal: true, slant: slant)
            .fill(active ? activeColor : inactiveColor)
            .frame(width: width, height: height)
            .shadow(color: active ? activeColor.opacity(0.92) : .clear, radius: 4)
    }

    private func verticalSegment(active: Bool, width: CGFloat, height: CGFloat, slant: CGFloat) -> some View {
        BeveledSegment(horizontal: false, slant: slant)
            .fill(active ? activeColor : inactiveColor)
            .frame(width: width, height: height)
            .shadow(color: active ? activeColor.opacity(0.92) : .clear, radius: 4)
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

private struct BeveledSegment: Shape {
    let horizontal: Bool
    let slant: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        if horizontal {
            let bevel = min(rect.height * 0.50, slant)
            path.move(to: CGPoint(x: bevel, y: 0))
            path.addLine(to: CGPoint(x: rect.maxX - bevel, y: 0))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX - bevel, y: rect.maxY))
            path.addLine(to: CGPoint(x: bevel, y: rect.maxY))
            path.addLine(to: CGPoint(x: 0, y: rect.midY))
        } else {
            let bevel = min(rect.width * 0.50, slant)
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

#Preview("Maxshot Sport") {
    var computer = ScooterDisplayComputer()
    let frame = computer.update(
        telemetry: .preview,
        profile: .maxshot36V,
        deltaTime: 2,
        ambientLuminance: 0.05,
        absoluteTime: 2
    )
    return MaxshotPhysicalDisplayView(frame: frame)
        .frame(width: 240)
        .padding(40)
        .background(Color(red: 0.01, green: 0.015, blue: 0.025))
}
