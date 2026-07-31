import Foundation
import SwiftUI

// MARK: - Shared live display contract

/// Renderer-independent telemetry consumed by every physical scooter dashboard.
/// Each scooter owns its own renderer and layout, but all displays read the same
/// physically simulated values instead of duplicated UI-only state.
struct ScooterDisplayTelemetry: Equatable, Sendable {
    var speedMPH: Double
    var packVoltage: Double
    var stateOfCharge: Double
    var batteryCurrentAmps: Double
    var motorCurrentAmps: Double
    var electricalPowerWatts: Double
    var controllerTemperatureC: Double
    var motorTemperatureC: Double
    var tripMiles: Double
    var odometerMiles: Double
    var estimatedRangeMiles: Double
    var mode: ScooterRideMode
    var headlightOn: Bool
    var cruiseActive: Bool
    var brakeActive: Bool
    var bluetoothConnected: Bool
    var tractionControlActive: Bool
    var fault: ScooterDisplayFault?
    var isPoweredOn: Bool

    static let preview = ScooterDisplayTelemetry(
        speedMPH: 22,
        packVoltage: 40.3,
        stateOfCharge: 0.86,
        batteryCurrentAmps: 14.6,
        motorCurrentAmps: 21.4,
        electricalPowerWatts: 588,
        controllerTemperatureC: 42,
        motorTemperatureC: 48,
        tripMiles: 3.7,
        odometerMiles: 142.2,
        estimatedRangeMiles: 14.6,
        mode: .sport,
        headlightOn: true,
        cruiseActive: false,
        brakeActive: false,
        bluetoothConnected: true,
        tractionControlActive: false,
        fault: nil,
        isPoweredOn: true
    )
}

enum ScooterRideMode: String, CaseIterable, Codable, Sendable {
    case eco = "ECO"
    case drive = "D"
    case sport = "S"
    case walk = "WALK"

    var displayColor: Color {
        switch self {
        case .eco: return Color(red: 0.15, green: 1.0, blue: 0.43)
        case .drive: return Color(red: 0.22, green: 0.80, blue: 1.0)
        case .sport: return .white
        case .walk: return Color(red: 1.0, green: 0.72, blue: 0.18)
        }
    }
}

enum ScooterDisplayFault: Equatable, Sendable {
    case lowVoltage
    case batteryOverTemperature
    case controllerOverTemperature
    case motorOverTemperature
    case overCurrent
    case hallSensor
    case throttle
    case brakeSensor
    case communication
    case custom(code: String)

    var code: String {
        switch self {
        case .lowVoltage: return "E01"
        case .batteryOverTemperature: return "E02"
        case .controllerOverTemperature: return "E03"
        case .motorOverTemperature: return "E04"
        case .overCurrent: return "E05"
        case .hallSensor: return "E06"
        case .throttle: return "E07"
        case .brakeSensor: return "E08"
        case .communication: return "E09"
        case .custom(let code): return code
        }
    }
}

enum ScooterDisplayBootPhase: Equatable, Sendable {
    case off
    case logo(progress: Double)
    case segmentTest(progress: Double)
    case batterySweep(progress: Double)
    case ready
}

struct ScooterDisplayFrame: Equatable, Sendable {
    var telemetry: ScooterDisplayTelemetry
    var filteredVoltage: Double
    var batterySegments: Int
    var criticalBarVisible: Bool
    var bootPhase: ScooterDisplayBootPhase
    var brightness: Double
}

// MARK: - Voltage-based five-segment battery behavior

struct BatterySegmentProfile: Equatable, Sendable {
    /// Descending loaded-voltage thresholds for 5, 4, 3, 2 and 1 bars.
    let thresholds: [Double]
    let criticalVoltage: Double
    let cutoffVoltage: Double
    let hysteresisVolts: Double
    let voltageFilterSeconds: Double
    let downgradeDelaySeconds: Double
    let upgradeDelaySeconds: Double

    static let maxshot36V = BatterySegmentProfile(
        thresholds: [39.2, 37.8, 36.5, 35.2, 33.5],
        criticalVoltage: 33.5,
        cutoffVoltage: 31.0,
        hysteresisVolts: 0.28,
        voltageFilterSeconds: 1.15,
        downgradeDelaySeconds: 2.2,
        upgradeDelaySeconds: 5.5
    )

    func rawSegments(for voltage: Double) -> Int {
        for (index, threshold) in thresholds.enumerated() where voltage >= threshold {
            return max(1, 5 - index)
        }
        return 1
    }
}

/// Stateful display computer. It deliberately smooths only the dashboard signal;
/// the underlying battery simulation remains immediate and physically responsive.
struct ScooterDisplayComputer: Sendable {
    private(set) var filteredVoltage: Double?
    private(set) var displayedSegments = 5
    private var pendingSegments: Int?
    private var pendingDuration = 0.0
    private var poweredDuration = 0.0

    mutating func reset() {
        filteredVoltage = nil
        displayedSegments = 5
        pendingSegments = nil
        pendingDuration = 0
        poweredDuration = 0
    }

    mutating func update(
        telemetry: ScooterDisplayTelemetry,
        profile: BatterySegmentProfile,
        deltaTime: Double,
        ambientLuminance: Double,
        absoluteTime: Double
    ) -> ScooterDisplayFrame {
        guard telemetry.isPoweredOn else {
            reset()
            return ScooterDisplayFrame(
                telemetry: telemetry,
                filteredVoltage: telemetry.packVoltage,
                batterySegments: 0,
                criticalBarVisible: false,
                bootPhase: .off,
                brightness: 0
            )
        }

        let dt = max(0, min(deltaTime, 0.1))
        poweredDuration += dt

        if filteredVoltage == nil { filteredVoltage = telemetry.packVoltage }
        let alpha = 1 - exp(-dt / max(0.05, profile.voltageFilterSeconds))
        filteredVoltage! += (telemetry.packVoltage - filteredVoltage!) * alpha

        updateSegments(profile: profile, deltaTime: dt)

        let bootPhase: ScooterDisplayBootPhase
        switch poweredDuration {
        case ..<0.42:
            bootPhase = .logo(progress: poweredDuration / 0.42)
        case ..<1.05:
            bootPhase = .segmentTest(progress: (poweredDuration - 0.42) / 0.63)
        case ..<1.55:
            bootPhase = .batterySweep(progress: (poweredDuration - 1.05) / 0.50)
        default:
            bootPhase = .ready
        }

        let ambient = max(0, min(ambientLuminance, 1))
        let brightness = 0.72 + (1 - ambient) * 0.28
        let blinkVisible = Int(absoluteTime * 2.4).isMultiple(of: 2)
        let isCritical = filteredVoltage! < profile.criticalVoltage

        return ScooterDisplayFrame(
            telemetry: telemetry,
            filteredVoltage: filteredVoltage!,
            batterySegments: displayedSegments,
            criticalBarVisible: !isCritical || blinkVisible,
            bootPhase: bootPhase,
            brightness: brightness
        )
    }

    private mutating func updateSegments(profile: BatterySegmentProfile, deltaTime: Double) {
        guard let voltage = filteredVoltage else { return }
        var candidate = profile.rawSegments(for: voltage)

        if candidate > displayedSegments {
            let requiredThreshold = profile.thresholds[max(0, 5 - candidate)] + profile.hysteresisVolts
            if voltage < requiredThreshold { candidate = displayedSegments }
        } else if candidate < displayedSegments {
            let currentThreshold = profile.thresholds[max(0, 5 - displayedSegments)] - profile.hysteresisVolts
            if voltage >= currentThreshold { candidate = displayedSegments }
        }

        guard candidate != displayedSegments else {
            pendingSegments = nil
            pendingDuration = 0
            return
        }

        if pendingSegments != candidate {
            pendingSegments = candidate
            pendingDuration = 0
        }
        pendingDuration += deltaTime

        let requiredDelay = candidate < displayedSegments
            ? profile.downgradeDelaySeconds
            : profile.upgradeDelaySeconds

        if pendingDuration >= requiredDelay {
            displayedSegments = candidate
            pendingSegments = nil
            pendingDuration = 0
        }
    }
}

// MARK: - Catalog identity and renderer metadata

enum ScooterDisplayFamily: String, CaseIterable, Codable, Sendable {
    case maxshotLED
    case kukirinMonochromeLCD
    case kukirinColorTFT
    case dualtronEY3
    case dualtronEY4
    case namiTFT
    case segwayColorTFT
    case apolloColorTFT
}

struct ScooterDisplayIdentity: Identifiable, Equatable, Sendable {
    let id: String
    let manufacturer: String
    let model: String
    let family: ScooterDisplayFamily
    let batteryProfile: BatterySegmentProfile
    let verifiedReferenceCount: Int
    let calibrationNotes: String

    static let maxshotV1SPro = ScooterDisplayIdentity(
        id: "maxshot-v1s-pro",
        manufacturer: "Maxshot",
        model: "V1S Pro 500W",
        family: .maxshotLED,
        batteryProfile: .maxshot36V,
        verifiedReferenceCount: 3,
        calibrationNotes: "Display geometry and ECO/D/S color layout are based on owner-provided photographs. Voltage thresholds remain provisional until ride logs are recorded."
    )
}
