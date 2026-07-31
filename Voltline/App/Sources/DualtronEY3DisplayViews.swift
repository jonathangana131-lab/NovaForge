import SwiftUI

enum DualtronEY3VisualVariant: String, CaseIterable, Sendable {
    case legacyGreenLCD
    case newColorLED
}

/// Complete EY3 display/throttle assembly. Legacy green LCD and the newer
/// color-arc EY3 are separate visual variants because real units differ.
struct DualtronEY3AssemblyView: View {
    let frame: ScooterDisplayFrame
    let variant: DualtronEY3VisualVariant

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            HStack(spacing: size.width * 0.025) {
                displayFace
                    .frame(width: size.height, height: size.height)

                controlPod
                    .frame(width: size.width - size.height - size.width * 0.025)
            }
            .frame(width: size.width, height: size.height)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilitySummary)
            .accessibilityIdentifier("dualtronEY3-\(variant.rawValue)")
        }
        .aspectRatio(1.78, contentMode: .fit)
    }

    private var displayFace: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color(red: 0.12, green: 0.13, blue: 0.14), .black],
                        center: .topLeading,
                        startRadius: 3,
                        endRadius: 92
                    )
                )
                .overlay { Circle().stroke(.white.opacity(0.16), lineWidth: 1.4) }

            ForEach(0..<6, id: \.self) { index in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color(red: 0.05, green: 0.055, blue: 0.062))
                    .frame(width: 25, height: 12)
                    .offset(y: -87)
                    .rotationEffect(.degrees(Double(index) * 60))
            }

            Circle()
                .fill(screenBackground)
                .frame(width: 146, height: 146)
                .overlay { Circle().stroke(.white.opacity(0.13), lineWidth: 1) }

            faceContent
                .frame(width: 132, height: 132)

            VStack {
                Text("EY3")
                    .font(.system(size: 10, weight: .black, design: .rounded))
                    .foregroundStyle(.white.opacity(0.82))
                    .padding(.top, 5)
                Spacer()
                Text("MINIMOTORS")
                    .font(.system(size: 9, weight: .black, design: .rounded).italic())
                    .foregroundStyle(.white.opacity(0.82))
                    .padding(.bottom, 4)
            }
        }
    }

    @ViewBuilder
    private var faceContent: some View {
        switch frame.bootPhase {
        case .off:
            EmptyView()
        case .logo(let progress):
            Text("MINIMOTORS")
                .font(.system(size: 12, weight: .black, design: .rounded).italic())
                .foregroundStyle(primaryLED)
                .shadow(color: primaryLED.opacity(0.72), radius: 5)
                .opacity(min(1, progress * 2.5))
        case .segmentTest:
            dashboard(speed: "88", forceAll: true)
        case .batterySweep:
            dashboard(speed: "00", forceAll: true)
        case .ready:
            dashboard(speed: String(format: "%02d", displayedSpeed))
        }
    }

    @ViewBuilder
    private func dashboard(speed: String, forceAll: Bool = false) -> some View {
        switch variant {
        case .legacyGreenLCD:
            legacyDashboard(speed: speed, forceAll: forceAll)
        case .newColorLED:
            colorDashboard(speed: speed, forceAll: forceAll)
        }
    }

    private func legacyDashboard(speed: String, forceAll: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 2) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("VOL")
                    Text(frame.telemetry.speedMPH > 0 ? "Mph" : "Km/h")
                }
                .font(.system(size: 5.5, weight: .black, design: .rounded))
                .foregroundStyle(primaryLED.opacity(0.72))

                Spacer(minLength: 1)

                EY3SegmentText(text: speed, color: primaryLED, inactive: primaryLED.opacity(0.08))
                    .frame(width: 70, height: 52)

                Text("3")
                    .font(.system(size: 20, weight: .black, design: .rounded))
                    .foregroundStyle(primaryLED)
                    .padding(.top, 12)
            }

            HStack(spacing: 3) {
                legacyBatteryBars(count: forceAll ? 5 : frame.batterySegments)
                Spacer()
                Text("\(Int(frame.telemetry.stateOfCharge * 100))%")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .foregroundStyle(primaryLED)
            }

            Text(String(format: "%06.1f", frame.telemetry.odometerMiles))
                .font(.system(size: 20, weight: .black, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(primaryLED)
                .padding(.top, 1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 15)
    }

    private func colorDashboard(speed: String, forceAll: Bool) -> some View {
        VStack(spacing: 1) {
            HStack(spacing: 2) {
                ForEach(0..<6, id: \.self) { index in
                    Capsule()
                        .fill(arcColors[index])
                        .frame(width: 15, height: 6)
                        .rotationEffect(.degrees(Double(index - 2) * 5))
                }
            }
            .padding(.top, 12)

            HStack(alignment: .top, spacing: 1) {
                Text("\(modeNumber)")
                    .font(.system(size: 7, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 12, height: 12)
                    .background(.blue, in: RoundedRectangle(cornerRadius: 2))

                EY3SegmentText(text: speed, color: primaryLED, inactive: primaryLED.opacity(0.05))
                    .frame(width: 76, height: 55)

                Text("km/h")
                    .font(.system(size: 5.5, weight: .black, design: .rounded))
                    .foregroundStyle(primaryLED.opacity(0.72))
                    .padding(.top, 36)
            }

            HStack {
                Text(String(format: "%.0f", frame.filteredVoltage))
                    .font(.system(size: 15, weight: .black, design: .monospaced))
                    .foregroundStyle(primaryLED)
                Spacer()
                Text("V")
                    .font(.system(size: 7, weight: .black, design: .rounded))
                    .foregroundStyle(primaryLED.opacity(0.62))
            }
            .padding(.horizontal, 23)
        }
    }

    private var controlPod: some View {
        ZStack(alignment: .top) {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color(red: 0.13, green: 0.14, blue: 0.15), .black],
                        center: .topLeading,
                        startRadius: 2,
                        endRadius: 70
                    )
                )
                .overlay { Circle().stroke(.white.opacity(0.12), lineWidth: 1) }
                .frame(width: 106, height: 106)

            VStack(spacing: 4) {
                HStack(spacing: 15) {
                    podButton("●")
                    podButton("POWER")
                }
                podButton("MODE")
            }
            .padding(.top, 18)

            Capsule()
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.16, green: 0.17, blue: 0.18), .black],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 34, height: 102)
                .rotationEffect(.degrees(-27), anchor: .top)
                .offset(x: 39, y: 74)
                .shadow(color: .black.opacity(0.72), radius: 5)
        }
    }

    private func podButton(_ text: String) -> some View {
        Text(text)
            .font(.system(size: text.count > 2 ? 5.5 : 11, weight: .black, design: .rounded))
            .foregroundStyle(.white.opacity(0.78))
            .frame(width: 34, height: 23)
            .background(Color(red: 0.035, green: 0.038, blue: 0.044), in: RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.13), lineWidth: 0.7) }
    }

    private func legacyBatteryBars(count: Int) -> some View {
        HStack(spacing: 1.5) {
            ForEach(0..<5, id: \.self) { index in
                RoundedRectangle(cornerRadius: 0.6)
                    .fill(index < count ? primaryLED : primaryLED.opacity(0.11))
                    .frame(width: 8, height: 7)
            }
        }
        .padding(2)
        .overlay { RoundedRectangle(cornerRadius: 2).stroke(primaryLED.opacity(0.72), lineWidth: 0.8) }
    }

    private var screenBackground: Color {
        switch variant {
        case .legacyGreenLCD:
            return Color(red: 0.34, green: 0.88, blue: 0.48).opacity(0.92)
        case .newColorLED:
            return Color(red: 0.005, green: 0.012, blue: 0.020)
        }
    }

    private var primaryLED: Color {
        switch variant {
        case .legacyGreenLCD: return Color(red: 0.025, green: 0.18, blue: 0.11)
        case .newColorLED: return Color(red: 0.27, green: 0.53, blue: 1.0)
        }
    }

    private var arcColors: [Color] {
        [.red, .orange, .green, .blue, .cyan, .mint]
    }

    private var displayedSpeed: Int {
        max(0, min(99, Int(frame.telemetry.speedMPH.rounded())))
    }

    private var modeNumber: Int {
        switch frame.telemetry.mode {
        case .walk, .eco: return 1
        case .drive: return 2
        case .sport: return 3
        }
    }

    private var accessibilitySummary: String {
        "Dualtron EY3 \(variant.rawValue), \(displayedSpeed) miles per hour, \(frame.batterySegments) battery bars"
    }
}

private struct EY3SegmentText: View {
    let text: String
    let color: Color
    let inactive: Color

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(text.enumerated()), id: \.offset) { _, character in
                EY3SegmentDigit(character: character, color: color, inactive: inactive)
            }
        }
    }
}

private struct EY3SegmentDigit: View {
    let character: Character
    let color: Color
    let inactive: Color

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let thickness = min(width, height) * 0.14
            let segments = activeSegments
            ZStack {
                bar(horizontal: true, on: segments.contains(.a), width: width - thickness, height: thickness)
                    .position(x: width / 2, y: thickness / 2)
                bar(horizontal: true, on: segments.contains(.g), width: width - thickness, height: thickness)
                    .position(x: width / 2, y: height / 2)
                bar(horizontal: true, on: segments.contains(.d), width: width - thickness, height: thickness)
                    .position(x: width / 2, y: height - thickness / 2)
                bar(horizontal: false, on: segments.contains(.f), width: thickness, height: height * 0.39)
                    .position(x: thickness / 2, y: height * 0.27)
                bar(horizontal: false, on: segments.contains(.b), width: thickness, height: height * 0.39)
                    .position(x: width - thickness / 2, y: height * 0.27)
                bar(horizontal: false, on: segments.contains(.e), width: thickness, height: height * 0.39)
                    .position(x: thickness / 2, y: height * 0.73)
                bar(horizontal: false, on: segments.contains(.c), width: thickness, height: height * 0.39)
                    .position(x: width - thickness / 2, y: height * 0.73)
            }
        }
    }

    private func bar(horizontal: Bool, on: Bool, width: CGFloat, height: CGFloat) -> some View {
        EY3SegmentBar(horizontal: horizontal)
            .fill(on ? color : inactive)
            .frame(width: width, height: height)
            .shadow(color: on ? color.opacity(0.68) : .clear, radius: 2.5)
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

private struct EY3SegmentBar: Shape {
    let horizontal: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        if horizontal {
            let bevel = rect.height * 0.48
            path.move(to: CGPoint(x: bevel, y: 0))
            path.addLine(to: CGPoint(x: rect.maxX - bevel, y: 0))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX - bevel, y: rect.maxY))
            path.addLine(to: CGPoint(x: bevel, y: rect.maxY))
            path.addLine(to: CGPoint(x: 0, y: rect.midY))
        } else {
            let bevel = rect.width * 0.48
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
