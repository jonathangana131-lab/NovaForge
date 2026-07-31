import SwiftUI

struct DisplayAcceptanceGalleryView: View {
    let fixture: DisplayAcceptanceFixture

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.006, green: 0.012, blue: 0.022),
                        Color(red: 0.018, green: 0.045, blue: 0.070),
                        .black
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                VStack(spacing: 13) {
                    VStack(spacing: 3) {
                        Text(fixture.title)
                            .font(.system(size: 23, weight: .black, design: .rounded))
                        Text(fixture.subtitle)
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.52))
                    }

                    display
                        .frame(
                            width: min(proxy.size.width * fixture.widthFraction, fixture.maximumWidth),
                            height: min(proxy.size.height * 0.58, fixture.maximumHeight)
                        )

                    HStack(spacing: 14) {
                        value("SPEED", fixture.speedLabel)
                        value("MODE", fixture.mode.rawValue)
                        value("VOLTAGE", String(format: "%.1f V", fixture.voltage))
                        value("BATTERY", "\(fixture.bars) / 5")
                    }
                    .padding(.horizontal, 15)
                    .frame(height: 45)
                    .acceptanceGlass(radius: 17)
                }
                .padding(15)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("displayAcceptanceGallery")
    }

    @ViewBuilder
    private var display: some View {
        let frame = fixture.frame
        switch fixture.scooterID {
        case ScooterCatalogItem.kukirin.id:
            KukirinG2MasterDisplayView(frame: frame)
                .accessibilityIdentifier("acceptance-kukirin-g2-master")
        case ScooterCatalogItem.dualtron.id:
            DualtronThunder3EY4DisplayView(frame: frame)
                .accessibilityIdentifier("acceptance-dualtron-thunder-3")
        default:
            MaxshotPhysicalDisplayView(frame: frame)
                .accessibilityIdentifier("acceptance-maxshot-v1s-pro")
        }
    }

    private func value(_ title: String, _ value: String) -> some View {
        VStack(spacing: 1) {
            Text(title)
                .font(.system(size: 6.5, weight: .black, design: .rounded))
                .foregroundStyle(.white.opacity(0.42))
            Text(value)
                .font(.system(size: 11, weight: .heavy, design: .monospaced))
        }
    }
}

struct DisplayAcceptanceFixture {
    let id: String
    let scooterID: String
    let title: String
    let subtitle: String
    let mode: ScooterRideMode
    let speedMPH: Double
    let voltage: Double
    let bars: Int
    let criticalVisible: Bool
    let fault: ScooterDisplayFault?

    var speedLabel: String {
        scooterID == ScooterCatalogItem.kukirin.id
            ? "\(Int((speedMPH * 1.609344).rounded())) km/h"
            : "\(Int(speedMPH.rounded())) mph"
    }

    var widthFraction: CGFloat {
        scooterID == ScooterCatalogItem.maxshot.id ? 0.28 : 0.58
    }

    var maximumWidth: CGFloat {
        scooterID == ScooterCatalogItem.maxshot.id ? 190 : 430
    }

    var maximumHeight: CGFloat {
        scooterID == ScooterCatalogItem.maxshot.id ? 285 : 235
    }

    var frame: ScooterDisplayFrame {
        let telemetry = ScooterDisplayTelemetry(
            speedMPH: speedMPH,
            packVoltage: voltage,
            stateOfCharge: Double(bars) / 5.0,
            batteryCurrentAmps: speedMPH > 0 ? 14.4 : 0,
            motorCurrentAmps: speedMPH > 0 ? 22.0 : 0,
            electricalPowerWatts: speedMPH > 0 ? 590 : 0,
            controllerTemperatureC: 44,
            motorTemperatureC: 51,
            tripMiles: 3.7,
            odometerMiles: 142.2,
            estimatedRangeMiles: 14.6,
            mode: mode,
            headlightOn: true,
            cruiseActive: false,
            brakeActive: false,
            bluetoothConnected: true,
            tractionControlActive: false,
            fault: fault,
            isPoweredOn: true
        )
        return ScooterDisplayFrame(
            telemetry: telemetry,
            filteredVoltage: voltage,
            batterySegments: bars,
            criticalBarVisible: criticalVisible,
            bootPhase: .ready,
            brightness: 1
        )
    }

    static func current(arguments: [String]) -> DisplayAcceptanceFixture? {
        if arguments.contains("--qa-display-maxshot-eco") {
            return .init(
                id: "maxshot-eco",
                scooterID: ScooterCatalogItem.maxshot.id,
                title: "MAXSHOT V1S PRO · ECO",
                subtitle: "Reference-matched LED layout · five discrete voltage bars",
                mode: .eco,
                speedMPH: 0,
                voltage: 41.3,
                bars: 5,
                criticalVisible: true,
                fault: nil
            )
        }
        if arguments.contains("--qa-display-maxshot-drive") {
            return .init(
                id: "maxshot-drive",
                scooterID: ScooterCatalogItem.maxshot.id,
                title: "MAXSHOT V1S PRO · DRIVE",
                subtitle: "Blue D mode · live seven-segment speed",
                mode: .drive,
                speedMPH: 14,
                voltage: 37.2,
                bars: 3,
                criticalVisible: true,
                fault: nil
            )
        }
        if arguments.contains("--qa-display-maxshot-sport") {
            return .init(
                id: "maxshot-sport",
                scooterID: ScooterCatalogItem.maxshot.id,
                title: "MAXSHOT V1S PRO · SPORT",
                subtitle: "White S mode · full-throttle loaded voltage",
                mode: .sport,
                speedMPH: 22,
                voltage: 35.7,
                bars: 2,
                criticalVisible: true,
                fault: nil
            )
        }
        if arguments.contains("--qa-display-maxshot-critical") {
            return .init(
                id: "maxshot-critical",
                scooterID: ScooterCatalogItem.maxshot.id,
                title: "MAXSHOT V1S PRO · CRITICAL",
                subtitle: "Blinking final red segment before 31 V controller cutoff",
                mode: .eco,
                speedMPH: 5,
                voltage: 32.8,
                bars: 1,
                criticalVisible: true,
                fault: .lowVoltage
            )
        }
        if arguments.contains("--qa-display-kukirin") {
            return .init(
                id: "kukirin-g2-master",
                scooterID: ScooterCatalogItem.kukirin.id,
                title: "KUKIRIN G2 MASTER",
                subtitle: "133 × 76 mm faceted LCD · speed level 3 · 52 V system",
                mode: .sport,
                speedMPH: 34,
                voltage: 51.4,
                bars: 3,
                criticalVisible: true,
                fault: nil
            )
        }
        if arguments.contains("--qa-display-dualtron") {
            return .init(
                id: "dualtron-thunder-3-ey4",
                scooterID: ScooterCatalogItem.dualtron.id,
                title: "DUALTRON THUNDER 3 · EY4",
                subtitle: "Connected color display · central arc · ten-section battery strip",
                mode: .sport,
                speedMPH: 47,
                voltage: 73.6,
                bars: 3,
                criticalVisible: true,
                fault: nil
            )
        }
        return nil
    }
}

private extension View {
    @ViewBuilder
    func acceptanceGlass(radius: CGFloat) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: radius))
        } else {
            self
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .stroke(.white.opacity(0.13), lineWidth: 1)
                }
        }
    }
}
