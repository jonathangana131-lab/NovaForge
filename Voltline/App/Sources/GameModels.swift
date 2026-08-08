import Foundation
import SwiftUI
import VoltlineSim

enum DriveMode: String, CaseIterable, Codable, Identifiable {
    case walk = "WALK"
    case eco = "ECO"
    case drive = "D"
    case sport = "S"

    var id: String { rawValue }

    var speedLimitMetersPerSecond: Double {
        switch self {
        case .walk: return 6 / 3.6
        case .eco: return 12 / 3.6
        case .drive: return 18 / 3.6
        case .sport: return 35 / 3.6
        }
    }

    var throttleScale: Double {
        switch self {
        case .walk: return 0.22
        case .eco: return 0.48
        case .drive: return 0.72
        case .sport: return 1.0
        }
    }
}

enum RideSurface: String, CaseIterable, Codable, Identifiable {
    case dryAsphalt = "Dry Asphalt"
    case wetAsphalt = "Wet Asphalt"
    case paintedLine = "Painted Line"
    case gravel = "Loose Gravel"

    var id: String { rawValue }

    var frictionCoefficient: Double {
        switch self {
        case .dryAsphalt: return 0.82
        case .wetAsphalt: return 0.56
        case .paintedLine: return 0.42
        case .gravel: return 0.38
        }
    }

    var rollingMultiplier: Double {
        switch self {
        case .dryAsphalt: return 1
        case .wetAsphalt: return 1.04
        case .paintedLine: return 1.0
        case .gravel: return 1.75
        }
    }
}

enum RideCamera: String, CaseIterable, Codable, Identifiable {
    case chase = "CHASE"
    case close = "CLOSE"
    case pov = "POV"

    var id: String { rawValue }

    mutating func cycle() {
        let values = Self.allCases
        let index = values.firstIndex(of: self) ?? 0
        self = values[(index + 1) % values.count]
    }
}

enum PhoneApp: String, CaseIterable, Identifiable {
    case home = "Home"
    case messages = "Messages"
    case maps = "Maps"
    case camera = "Camera"
    case photos = "Photos"
    case weather = "Weather"
    case bank = "Bank"
    case market = "Market"
    case scooter = "Scooter"
    case vesc = "VESC"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .home: return "square.grid.3x3.fill"
        case .messages: return "message.fill"
        case .maps: return "map.fill"
        case .camera: return "camera.fill"
        case .photos: return "photo.on.rectangle.angled"
        case .weather: return "cloud.sun.fill"
        case .bank: return "dollarsign.circle.fill"
        case .market: return "bag.fill"
        case .scooter: return "scooter"
        case .vesc: return "slider.horizontal.3"
        }
    }
}

enum StoreCategory: String, CaseIterable, Codable, Identifiable {
    case scooters = "Scooters"
    case controllers = "Controllers"
    case batteries = "Batteries"
    case motors = "Motors"
    case tires = "Tires"

    var id: String { rawValue }
}

struct StoreItem: Identifiable, Codable, Hashable {
    let id: String
    let category: StoreCategory
    let name: String
    let detail: String
    let price: Double
    let deliveryDistanceMeters: Double
    let compatibleScooterIDs: [String]
    let controllerBatteryLimitAmps: Double?
    let controllerMotorLimitAmps: Double?
    let batteryCapacityAmpHours: Double?
    let motorKV: Double?

    static let catalog: [StoreItem] = [
        .init(
            id: "vesc-75-100",
            category: .controllers,
            name: "75/100 Smart FOC Controller",
            detail: "Unlocks live current limits, regen, throttle curves, temperature limits and data logging.",
            price: 540,
            deliveryDistanceMeters: 6_400,
            compatibleScooterIDs: ["maxshot-v1s-pro-joey"],
            controllerBatteryLimitAmps: 35,
            controllerMotorLimitAmps: 100,
            batteryCapacityAmpHours: nil,
            motorKV: nil
        ),
        .init(
            id: "maxshot-10s-15ah",
            category: .batteries,
            name: "10S 15 Ah Deck Pack",
            detail: "A higher-capacity 36 V pack with a simulated 35 A BMS and calibrated pack resistance.",
            price: 395,
            deliveryDistanceMeters: 4_800,
            compatibleScooterIDs: ["maxshot-v1s-pro-joey"],
            controllerBatteryLimitAmps: nil,
            controllerMotorLimitAmps: nil,
            batteryCapacityAmpHours: 15,
            motorKV: nil
        ),
        .init(
            id: "maxshot-500w-hub",
            category: .motors,
            name: "500 W 10-inch Hub Motor",
            detail: "Replacement front hub with the stock-like winding profile and temperature model.",
            price: 230,
            deliveryDistanceMeters: 3_500,
            compatibleScooterIDs: ["maxshot-v1s-pro-joey"],
            controllerBatteryLimitAmps: nil,
            controllerMotorLimitAmps: nil,
            batteryCapacityAmpHours: nil,
            motorKV: 14.5
        ),
        .init(
            id: "street-tire-soft",
            category: .tires,
            name: "10-inch Soft Street Tire Set",
            detail: "More dry grip and progressive breakaway, with increased rolling loss and wear.",
            price: 88,
            deliveryDistanceMeters: 2_600,
            compatibleScooterIDs: ["maxshot-v1s-pro-joey", "kukirin-g2-master"],
            controllerBatteryLimitAmps: nil,
            controllerMotorLimitAmps: nil,
            batteryCapacityAmpHours: nil,
            motorKV: nil
        )
    ]
}

struct DeliveryOrder: Identifiable, Codable, Hashable {
    let id: UUID
    let itemID: String
    let orderedAtOdometerMeters: Double
    let requiredDistanceMeters: Double
    var delivered: Bool

    func progress(currentOdometerMeters: Double) -> Double {
        guard requiredDistanceMeters > 0 else { return 1 }
        return min(1, max(0, (currentOdometerMeters - orderedAtOdometerMeters) / requiredDistanceMeters))
    }
}

struct VESCConfiguration: Codable, Hashable {
    var batteryCurrentLimitAmps: Double = 20
    var motorCurrentLimitAmps: Double = 45
    var regenCurrentLimitAmps: Double = 8
    var throttleExpo: Double = 0.18
    var rampSeconds: Double = 0.32
    var maximumERPM: Double = 32_000
    var motorTemperatureCutoffCelsius: Double = 125
    var controllerTemperatureCutoffCelsius: Double = 100
}

struct GameToast: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let detail: String
    let symbol: String
}

struct DepositRecord: Identifiable, Codable, Hashable {
    let id: UUID
    let amount: Double
    let odometerMeters: Double
    let gameSeconds: Double
}

struct ChatLine: Identifiable, Codable, Hashable {
    enum Sender: String, Codable {
        case player
        case max
        case partsBot
        case ridingCrew
    }

    let id: UUID
    let sender: Sender
    let text: String
}

struct CapturedPhoto: Identifiable, Codable, Hashable {
    let id: UUID
    let title: String
    let odometerMeters: Double
    let speedMPH: Double
    let gameSeconds: Double
}

struct TrafficAgent: Identifiable, Codable, Hashable {
    let id: UUID
    var laneX: Double
    var z: Double
    var speedMetersPerSecond: Double
    var desiredSpeedMetersPerSecond: Double
    var direction: Double
    var bodyHue: Double
}

struct ScooterRiderAgent: Identifiable, Codable, Hashable {
    let id: UUID
    var x: Double
    var z: Double
    var speedMetersPerSecond: Double
    var direction: Double
    var scooterHue: Double
}

struct RenderSnapshot: Equatable {
    var playerX: Double = 0
    var playerZ: Double = 0
    var yawRadians: Double = 0
    var rollRadians: Double = 0
    var pitchRadians: Double = 0
    var steeringRadians: Double = 0
    var speedMetersPerSecond: Double = 0
    var camera: RideCamera = .chase
    var cameraYawOffset: Double = 0
    var cameraPitchOffset: Double = 0
    var crashed: Bool = false
    var crashSeconds: Double = 0
    var traffic: [TrafficAgent] = []
    var scooterRiders: [ScooterRiderAgent] = []
}

struct ScooterCatalogItem: Identifiable, Hashable {
    let id: String
    let name: String
    let subtitle: String
    let price: Double
    let hardware: ScooterHardwareProfile
    let calibrationNote: String

    static let maxshot = ScooterCatalogItem(
        id: "maxshot-v1s-pro-joey",
        name: "MAXSHOT V1S Pro 500W",
        subtitle: "Joey's starting scooter · front hub · 36 V",
        price: 0,
        hardware: .joeyMaxshotV1SPro,
        calibrationNote: "36 V, 10.5 Ah, 15 A and 31 V cutoff are label-backed. Motor winding, pack resistance and aero values remain measurement-calibrated estimates."
    )

    static let kukirin = ScooterCatalogItem(
        id: "kukirin-g2-master",
        name: "KuKirin G2 Master",
        subtitle: "Dual-motor all-road performance scooter",
        price: 2_450,
        hardware: .kukirinG2MasterEstimate,
        calibrationNote: "Performance reference profile pending exact production-revision measurements and licensed model art."
    )

    static let dualtron = ScooterCatalogItem(
        id: "dualtron-thunder-3",
        name: "Dualtron Thunder 3",
        subtitle: "High-voltage dual-motor flagship",
        price: 5_900,
        hardware: .dualtronThunder3Estimate,
        calibrationNote: "Performance reference profile pending exact production-revision measurements and licensed model art."
    )

    static let all: [ScooterCatalogItem] = [.maxshot, .kukirin, .dualtron]
}

struct VoltlineSave: Codable {
    var bankBalance: Double
    var pendingDriveEarnings: Double
    var lifetimeEarnings: Double
    var selectedScooterID: String
    var ownedScooterIDs: Set<String>
    var installedItemIDs: Set<String>
    var inventoryItemIDs: Set<String>
    var orders: [DeliveryOrder]
    var deposits: [DepositRecord]
    var odometerMeters: Double
    var tripMeters: Double
    var driveMode: DriveMode
    var surface: RideSurface
    var vescConfiguration: VESCConfiguration
    var photos: [CapturedPhoto]
    var messages: [ChatLine]
}

extension ScooterHardwareProfile {
    static let kukirinG2MasterEstimate = ScooterHardwareProfile(
        id: "kukirin-g2-master",
        displayName: "KuKirin G2 Master",
        battery: BatteryProfile(
            seriesCells: 14,
            capacityAmpHours: 20.8,
            packResistanceOhms: 0.095,
            thermalMassJoulesPerKelvin: 12_000,
            coolingWattsPerKelvin: 4.2,
            maximumDischargeAmps: 55
        ),
        controller: ControllerProfile(
            batteryCurrentLimitAmps: 42,
            motorCurrentLimitAmps: 70,
            lowVoltageCutoffVolts: 42,
            efficiency: 0.95,
            thermalMassJoulesPerKelvin: 780,
            coolingWattsPerKelvin: 5.2,
            derateStartCelsius: 82,
            shutdownCelsius: 108
        ),
        motor: MotorProfile(
            kvRPMPerVolt: 12.8,
            phaseResistanceOhms: 0.16,
            noLoadCurrentAmps: 1.3,
            torqueEfficiency: 0.92,
            thermalMassJoulesPerKelvin: 4_800,
            coolingWattsPerKelvin: 7.0,
            derateStartCelsius: 110,
            shutdownCelsius: 145
        ),
        chassis: ChassisProfile(
            scooterMassKilograms: 41.5,
            riderMassKilograms: 68,
            wheelRadiusMeters: 0.127,
            wheelbaseMeters: 1.28,
            centerOfMassHeightMeters: 0.88,
            staticFrontWeightFraction: 0.48,
            dragAreaSquareMeters: 0.58,
            rollingResistanceCoefficient: 0.020,
            tireFrictionCoefficient: 0.86
        ),
        drivenWheel: .both
    )

    static let dualtronThunder3Estimate = ScooterHardwareProfile(
        id: "dualtron-thunder-3",
        displayName: "Dualtron Thunder 3",
        battery: BatteryProfile(
            seriesCells: 20,
            capacityAmpHours: 40,
            packResistanceOhms: 0.060,
            thermalMassJoulesPerKelvin: 18_000,
            coolingWattsPerKelvin: 5.5,
            maximumDischargeAmps: 95
        ),
        controller: ControllerProfile(
            batteryCurrentLimitAmps: 75,
            motorCurrentLimitAmps: 120,
            lowVoltageCutoffVolts: 60,
            efficiency: 0.96,
            thermalMassJoulesPerKelvin: 1_100,
            coolingWattsPerKelvin: 8.0,
            derateStartCelsius: 85,
            shutdownCelsius: 112
        ),
        motor: MotorProfile(
            kvRPMPerVolt: 10.8,
            phaseResistanceOhms: 0.095,
            noLoadCurrentAmps: 1.8,
            torqueEfficiency: 0.93,
            thermalMassJoulesPerKelvin: 6_400,
            coolingWattsPerKelvin: 9.5,
            derateStartCelsius: 115,
            shutdownCelsius: 150
        ),
        chassis: ChassisProfile(
            scooterMassKilograms: 51.8,
            riderMassKilograms: 68,
            wheelRadiusMeters: 0.14,
            wheelbaseMeters: 1.34,
            centerOfMassHeightMeters: 0.92,
            staticFrontWeightFraction: 0.49,
            dragAreaSquareMeters: 0.61,
            rollingResistanceCoefficient: 0.021,
            tireFrictionCoefficient: 0.90
        ),
        drivenWheel: .both
    )
}
