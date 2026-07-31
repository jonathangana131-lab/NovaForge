import SwiftUI

struct CatalogPhysicalDisplayView: View {
    let scooterID: String
    let frame: ScooterDisplayFrame

    @ViewBuilder
    var body: some View {
        switch scooterID {
        case ScooterCatalogItem.kukirin.id:
            KukirinG2MasterDisplayView(frame: frame)
        case ScooterCatalogItem.dualtron.id:
            DualtronThunder3EY4DisplayView(frame: frame)
        default:
            MaxshotPhysicalDisplayView(frame: frame)
        }
    }
}

// MARK: - KuKirin G2 Master 133 × 76 mm LCD

struct KukirinG2MasterDisplayView: View {
    let frame: ScooterDisplayFrame

    private let lcdCyan = Color(red: 0.28, green: 0.95, blue: 1.0)
    private let lcdGreen = Color(red: 0.40, green: 1.0, blue: 0.48)
    private let inactive = Color(red: 0.10, green: 0.19, blue: 0.20)

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                KukirinHousingShape()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.11, green: 0.12, blue: 0.13),
                                Color(red: 0.018, green: 0.021, blue: 0.024),
                                .black
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                KukirinHousingShape()
                    .stroke(.white.opacity(0.18), lineWidth: max(1, size.height * 0.012))

                RoundedRectangle(cornerRadius: size.height * 0.08, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.015, green: 0.055, blue: 0.060),
                                Color(red: 0.008, green: 0.018, blue: 0.020)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: size.height * 0.08, style: .continuous)
                            .stroke(Color(red: 0.11, green: 0.56, blue: 0.45).opacity(0.42), lineWidth: 1)
                    }
                    .padding(.horizontal, size.width * 0.075)
                    .padding(.vertical, size.height * 0.13)

                content
                    .padding(.horizontal, size.width * 0.11)
                    .padding(.vertical, size.height * 0.17)

                Text("KuKirin")
                    .font(.system(size: max(7, size.height * 0.075), weight: .black, design: .rounded).italic())
                    .foregroundStyle(.white.opacity(0.62))
                    .position(x: size.width * 0.5, y: size.height * 0.075)

                Capsule()
                    .fill(Color(red: 0.12, green: 0.72, blue: 0.49))
                    .frame(width: size.width * 0.035, height: size.height * 0.20)
                    .position(x: size.width * 0.935, y: size.height * 0.22)
            }
            .drawingGroup(opaque: false, colorMode: .extendedLinear)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilitySummary)
            .accessibilityIdentifier("kukirinG2MasterPhysicalDisplay")
        }
        .aspectRatio(133.0 / 76.0, contentMode: .fit)
    }

    @ViewBuilder
    private var content: some View {
        switch frame.bootPhase {
        case .off:
            EmptyView()
        case .logo(let progress):
            VStack(spacing: 3) {
                Text("KuKirin")
                    .font(.system(size: 24, weight: .black, design: .rounded).italic())
                Text("G2 MASTER")
                    .font(.system(size: 7, weight: .black, design: .monospaced))
                    .tracking(1.4)
            }
            .foregroundStyle(lcdCyan.opacity(frame.brightness))
            .shadow(color: lcdCyan.opacity(0.75), radius: 7)
            .opacity(min(1, progress * 2.5))
        case .segmentTest:
            dashboard(speed: "88", forceAll: true)
        case .batterySweep(let progress):
            dashboard(speed: "00", forcedBars: max(1, min(5, Int(progress * 6))))
        case .ready:
            dashboard(speed: String(format: "%02d", displayedKPH))
        }
    }

    private func dashboard(speed: String, forceAll: Bool = false, forcedBars: Int? = nil) -> some View {
        VStack(spacing: 1) {
            HStack(spacing: 7) {
                lcdIcon("light.max", active: forceAll || frame.telemetry.headlightOn)
                Text("DUAL")
                    .foregroundStyle(lcdGreen.opacity(frame.brightness))
                Spacer()
                Text("MODE")
                    .foregroundStyle(inactive)
                Text(modeNumber)
                    .foregroundStyle(lcdCyan.opacity(frame.brightness))
                lcdIcon("arrow.left", active: forceAll)
                lcdIcon("arrow.right", active: forceAll)
            }
            .font(.system(size: 7, weight: .black, design: .monospaced))

            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text(speed)
                    .font(.system(size: 47, weight: .black, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(lcdCyan.opacity(frame.brightness))
                    .shadow(color: lcdCyan.opacity(0.70), radius: 6)
                Text("km/h")
                    .font(.system(size: 7, weight: .black, design: .rounded))
                    .foregroundStyle(lcdCyan.opacity(0.72))
                    .padding(.bottom, 7)
            }
            .frame(maxHeight: .infinity)

            HStack(alignment: .bottom, spacing: 7) {
                dataField("TRIP", String(format: "%.1f", frame.telemetry.tripMiles * 1.609344))
                Spacer(minLength: 4)
                batteryBars(count: forcedBars ?? frame.batterySegments)
                Spacer(minLength: 4)
                dataField("VOLT", String(format: "%.1f", frame.filteredVoltage))
            }
        }
    }

    private func lcdIcon(_ symbol: String, active: Bool) -> some View {
        Image(systemName: symbol)
            .foregroundStyle(active ? lcdCyan.opacity(frame.brightness) : inactive)
            .shadow(color: active ? lcdCyan.opacity(0.7) : .clear, radius: 4)
    }

    private func dataField(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(.system(size: 5.5, weight: .black, design: .monospaced))
                .foregroundStyle(inactive)
            Text(value)
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .foregroundStyle(lcdGreen.opacity(frame.brightness))
                .monospacedDigit()
        }
    }

    private func batteryBars(count: Int) -> some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { index in
                let active = index < count
                let critical = count == 1 && index == 0 && frame.filteredVoltage < 45.0
                RoundedRectangle(cornerRadius: 1)
                    .fill(
                        active && (!critical || frame.criticalBarVisible)
                            ? (critical ? Color.red : lcdGreen.opacity(frame.brightness))
                            : inactive
                    )
                    .frame(width: 9, height: 6)
                    .shadow(color: active ? lcdGreen.opacity(0.55) : .clear, radius: 3)
            }
        }
    }

    private var displayedKPH: Int {
        max(0, min(99, Int((frame.telemetry.speedMPH * 1.609344).rounded())))
    }

    private var modeNumber: String {
        switch frame.telemetry.mode {
        case .walk, .eco: return "1"
        case .drive: return "2"
        case .sport: return "3"
        }
    }

    private var accessibilitySummary: String {
        "KuKirin G2 Master display, \(displayedKPH) kilometers per hour, speed level \(modeNumber), \(frame.batterySegments) battery bars"
    }
}

// MARK: - Dualtron Thunder 3 EY4

struct DualtronThunder3EY4DisplayView: View {
    let frame: ScooterDisplayFrame

    private let cyan = Color(red: 0.08, green: 0.77, blue: 1.0)
    private let green = Color(red: 0.20, green: 1.0, blue: 0.35)
    private let red = Color(red: 1.0, green: 0.16, blue: 0.12)
    private let dim = Color(red: 0.10, green: 0.18, blue: 0.24)

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                EY4HousingShape()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.12, green: 0.13, blue: 0.15),
                                Color(red: 0.025, green: 0.027, blue: 0.032),
                                .black
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                EY4HousingShape()
                    .stroke(.white.opacity(0.16), lineWidth: 1.4)

                EY4HousingShape()
                    .inset(by: size.height * 0.025)
                    .stroke(cyan.opacity(0.78), lineWidth: max(1, size.height * 0.018))

                RoundedRectangle(cornerRadius: size.height * 0.035, style: .continuous)
                    .fill(Color(red: 0.004, green: 0.012, blue: 0.020))
                    .overlay {
                        RoundedRectangle(cornerRadius: size.height * 0.035, style: .continuous)
                            .stroke(.white.opacity(0.08), lineWidth: 1)
                    }
                    .padding(.horizontal, size.width * 0.075)
                    .padding(.top, size.height * 0.155)
                    .padding(.bottom, size.height * 0.245)

                content
                    .padding(.horizontal, size.width * 0.09)
                    .padding(.top, size.height * 0.17)
                    .padding(.bottom, size.height * 0.25)

                HStack(spacing: size.width * 0.09) {
                    ey4Button("POWER", symbol: "power")
                    ey4Button("SET", symbol: "gearshape")
                    ey4Button("MODE", symbol: "m.circle")
                }
                .position(x: size.width * 0.5, y: size.height * 0.885)

                HStack(spacing: 7) {
                    Text("MINIMOTORS")
                    Text("EY4 · IPX7")
                }
                .font(.system(size: max(6, size.height * 0.055), weight: .black, design: .rounded).italic())
                .foregroundStyle(.white.opacity(0.70))
                .position(x: size.width * 0.5, y: size.height * 0.085)
            }
            .drawingGroup(opaque: false, colorMode: .extendedLinear)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilitySummary)
            .accessibilityIdentifier("dualtronThunder3EY4PhysicalDisplay")
        }
        .aspectRatio(2.05, contentMode: .fit)
    }

    @ViewBuilder
    private var content: some View {
        switch frame.bootPhase {
        case .off:
            EmptyView()
        case .logo(let progress):
            VStack(spacing: 3) {
                Text("DUALTRON")
                    .font(.system(size: 22, weight: .black, design: .rounded).italic())
                    .tracking(1.4)
                Text("EY4")
                    .font(.system(size: 9, weight: .black, design: .monospaced))
            }
            .foregroundStyle(cyan.opacity(frame.brightness))
            .shadow(color: cyan.opacity(0.75), radius: 8)
            .opacity(min(1, progress * 2.5))
        case .segmentTest:
            dashboard(speed: "88", forceAll: true, forcedBars: 10)
        case .batterySweep(let progress):
            dashboard(speed: "00", forcedBars: max(1, min(10, Int(progress * 11))))
        case .ready:
            dashboard(speed: String(format: "%02d", displayedSpeedMPH))
        }
    }

    private func dashboard(speed: String, forceAll: Bool = false, forcedBars: Int? = nil) -> some View {
        VStack(spacing: 1) {
            HStack(spacing: 6) {
                ey4Icon("gauge.with.dots.needle.33percent", text: "FAS", active: forceAll)
                ey4Icon("shield.checkered", text: "ABS", active: forceAll)
                ey4Icon("light.max", text: nil, active: forceAll || frame.telemetry.headlightOn)
                Image(systemName: "arrow.left")
                    .foregroundStyle((forceAll ? green : dim).opacity(frame.brightness))
                Spacer()
                Text("SAFE")
                    .foregroundStyle((forceAll ? green : dim).opacity(frame.brightness))
                Text("GPS")
                    .foregroundStyle((forceAll || frame.telemetry.bluetoothConnected ? green : dim).opacity(frame.brightness))
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle((forceAll || frame.telemetry.fault != nil ? red : dim).opacity(frame.brightness))
                Image(systemName: "arrow.right")
                    .foregroundStyle((forceAll ? green : dim).opacity(frame.brightness))
            }
            .font(.system(size: 6.2, weight: .black, design: .monospaced))

            HStack(spacing: 4) {
                VStack(alignment: .leading, spacing: 2) {
                    ey4Data("TRIP", String(format: "%.1f", frame.telemetry.tripMiles))
                    ey4Data("BATTERY", String(format: "%.1fV", frame.filteredVoltage))
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                ZStack {
                    Circle()
                        .trim(from: 0.12, to: 0.88)
                        .stroke(
                            AngularGradient(colors: [red, .orange, green, cyan, cyan], center: .center),
                            style: StrokeStyle(lineWidth: 5, lineCap: .round)
                        )
                        .rotationEffect(.degrees(90))

                    VStack(spacing: -1) {
                        Text(frame.telemetry.mode == .eco ? "ECO" : "CCS")
                            .font(.system(size: 7, weight: .black, design: .monospaced).italic())
                            .foregroundStyle(frame.telemetry.mode == .eco ? green : cyan)
                        Text(speed)
                            .font(.system(size: 38, weight: .black, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(frame.brightness))
                            .shadow(color: cyan.opacity(0.55), radius: 4)
                        Text("km/h   mph")
                            .font(.system(size: 5.5, weight: .black, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.65))
                    }
                }
                .frame(width: 84, height: 74)

                VStack(alignment: .trailing, spacing: 2) {
                    ey4Data("ODO", String(format: "%.0f", frame.telemetry.odometerMiles))
                    ey4Data("RANGE", String(format: "%.0f", frame.telemetry.estimatedRangeMiles))
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(maxHeight: .infinity)

            batteryStrip(count: forcedBars ?? min(10, max(1, frame.batterySegments * 2)))
        }
    }

    private func ey4Icon(_ symbol: String, text: String?, active: Bool) -> some View {
        HStack(spacing: 2) {
            Image(systemName: symbol)
            if let text { Text(text) }
        }
        .foregroundStyle((active ? cyan : dim).opacity(frame.brightness))
    }

    private func ey4Data(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(.system(size: 5.5, weight: .black, design: .monospaced))
                .foregroundStyle(cyan.opacity(0.78))
            Text(value)
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .foregroundStyle(.white.opacity(frame.brightness))
                .monospacedDigit()
        }
    }

    private func batteryStrip(count: Int) -> some View {
        HStack(spacing: 2) {
            ForEach(0..<10, id: \.self) { index in
                let active = index < count
                let critical = count <= 2 && index < 2 && frame.filteredVoltage < 64
                RoundedRectangle(cornerRadius: 1)
                    .fill(
                        active && (!critical || frame.criticalBarVisible)
                            ? (index < 2 ? red : green)
                            : dim
                    )
                    .frame(height: 5)
                    .shadow(color: active ? (index < 2 ? red.opacity(0.65) : green.opacity(0.55)) : .clear, radius: 2)
            }
        }
    }

    private func ey4Button(_ text: String, symbol: String) -> some View {
        VStack(spacing: 1) {
            RoundedRectangle(cornerRadius: 3)
                .fill(
                    LinearGradient(colors: [.white.opacity(0.62), .gray.opacity(0.20)], startPoint: .top, endPoint: .bottom)
                )
                .frame(width: 30, height: 8)
                .overlay {
                    Image(systemName: symbol)
                        .font(.system(size: 4.5, weight: .black))
                        .foregroundStyle(.black.opacity(0.72))
                }
            Text(text)
                .font(.system(size: 4.5, weight: .black, design: .rounded))
                .foregroundStyle(.white.opacity(0.58))
        }
    }

    private var displayedSpeedMPH: Int {
        max(0, min(99, Int(frame.telemetry.speedMPH.rounded())))
    }

    private var accessibilitySummary: String {
        "Dualtron Thunder 3 EY4 display, \(displayedSpeedMPH) miles per hour, \(frame.batterySegments) battery level"
    }
}

// MARK: - Housings

private struct KukirinHousingShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.14, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.10, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.28))
        path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.05, y: rect.maxY - rect.height * 0.12))
        path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.14, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.10, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - rect.height * 0.24))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.04, y: rect.minY + rect.height * 0.20))
        path.closeSubpath()
        return path
    }
}

private struct EY4HousingShape: InsettableShape {
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
        var path = Path()
        path.move(to: CGPoint(x: r.minX + r.width * 0.08, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX - r.width * 0.08, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX, y: r.minY + r.height * 0.18))
        path.addLine(to: CGPoint(x: r.maxX - r.width * 0.025, y: r.maxY - r.height * 0.12))
        path.addLine(to: CGPoint(x: r.maxX - r.width * 0.08, y: r.maxY))
        path.addLine(to: CGPoint(x: r.minX + r.width * 0.08, y: r.maxY))
        path.addLine(to: CGPoint(x: r.minX + r.width * 0.025, y: r.maxY - r.height * 0.12))
        path.addLine(to: CGPoint(x: r.minX, y: r.minY + r.height * 0.18))
        path.closeSubpath()
        return path
    }

    func inset(by amount: CGFloat) -> EY4HousingShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }
}
