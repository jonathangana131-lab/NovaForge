import Foundation

public struct BatteryProfile: Sendable, Hashable, Codable {
    public var seriesCells: Int
    public var capacityAmpHours: Double
    public var cellFullVoltage: Double
    public var cellNominalVoltage: Double
    public var cellEmptyVoltage: Double
    public var packResistanceOhms: Double
    public var thermalMassJoulesPerKelvin: Double
    public var coolingWattsPerKelvin: Double
    public var maximumDischargeAmps: Double

    public init(
        seriesCells: Int,
        capacityAmpHours: Double,
        cellFullVoltage: Double = 4.2,
        cellNominalVoltage: Double = 3.6,
        cellEmptyVoltage: Double = 3.0,
        packResistanceOhms: Double,
        thermalMassJoulesPerKelvin: Double,
        coolingWattsPerKelvin: Double,
        maximumDischargeAmps: Double
    ) {
        self.seriesCells = seriesCells
        self.capacityAmpHours = capacityAmpHours
        self.cellFullVoltage = cellFullVoltage
        self.cellNominalVoltage = cellNominalVoltage
        self.cellEmptyVoltage = cellEmptyVoltage
        self.packResistanceOhms = packResistanceOhms
        self.thermalMassJoulesPerKelvin = thermalMassJoulesPerKelvin
        self.coolingWattsPerKelvin = coolingWattsPerKelvin
        self.maximumDischargeAmps = maximumDischargeAmps
    }
}

public struct ControllerProfile: Sendable, Hashable, Codable {
    public var batteryCurrentLimitAmps: Double
    public var motorCurrentLimitAmps: Double
    public var lowVoltageCutoffVolts: Double
    public var efficiency: Double
    public var thermalMassJoulesPerKelvin: Double
    public var coolingWattsPerKelvin: Double
    public var derateStartCelsius: Double
    public var shutdownCelsius: Double

    public init(
        batteryCurrentLimitAmps: Double,
        motorCurrentLimitAmps: Double,
        lowVoltageCutoffVolts: Double,
        efficiency: Double,
        thermalMassJoulesPerKelvin: Double,
        coolingWattsPerKelvin: Double,
        derateStartCelsius: Double,
        shutdownCelsius: Double
    ) {
        self.batteryCurrentLimitAmps = batteryCurrentLimitAmps
        self.motorCurrentLimitAmps = motorCurrentLimitAmps
        self.lowVoltageCutoffVolts = lowVoltageCutoffVolts
        self.efficiency = efficiency
        self.thermalMassJoulesPerKelvin = thermalMassJoulesPerKelvin
        self.coolingWattsPerKelvin = coolingWattsPerKelvin
        self.derateStartCelsius = derateStartCelsius
        self.shutdownCelsius = shutdownCelsius
    }
}

public struct MotorProfile: Sendable, Hashable, Codable {
    public var kvRPMPerVolt: Double
    public var phaseResistanceOhms: Double
    public var noLoadCurrentAmps: Double
    public var torqueEfficiency: Double
    public var thermalMassJoulesPerKelvin: Double
    public var coolingWattsPerKelvin: Double
    public var derateStartCelsius: Double
    public var shutdownCelsius: Double

    public init(
        kvRPMPerVolt: Double,
        phaseResistanceOhms: Double,
        noLoadCurrentAmps: Double,
        torqueEfficiency: Double,
        thermalMassJoulesPerKelvin: Double,
        coolingWattsPerKelvin: Double,
        derateStartCelsius: Double,
        shutdownCelsius: Double
    ) {
        self.kvRPMPerVolt = kvRPMPerVolt
        self.phaseResistanceOhms = phaseResistanceOhms
        self.noLoadCurrentAmps = noLoadCurrentAmps
        self.torqueEfficiency = torqueEfficiency
        self.thermalMassJoulesPerKelvin = thermalMassJoulesPerKelvin
        self.coolingWattsPerKelvin = coolingWattsPerKelvin
        self.derateStartCelsius = derateStartCelsius
        self.shutdownCelsius = shutdownCelsius
    }
}

public struct ChassisProfile: Sendable, Hashable, Codable {
    public var scooterMassKilograms: Double
    public var riderMassKilograms: Double
    public var wheelRadiusMeters: Double
    public var wheelbaseMeters: Double
    public var centerOfMassHeightMeters: Double
    public var staticFrontWeightFraction: Double
    public var dragAreaSquareMeters: Double
    public var rollingResistanceCoefficient: Double
    public var tireFrictionCoefficient: Double

    public var totalMassKilograms: Double { scooterMassKilograms + riderMassKilograms }

    public init(
        scooterMassKilograms: Double,
        riderMassKilograms: Double,
        wheelRadiusMeters: Double,
        wheelbaseMeters: Double,
        centerOfMassHeightMeters: Double,
        staticFrontWeightFraction: Double,
        dragAreaSquareMeters: Double,
        rollingResistanceCoefficient: Double,
        tireFrictionCoefficient: Double
    ) {
        self.scooterMassKilograms = scooterMassKilograms
        self.riderMassKilograms = riderMassKilograms
        self.wheelRadiusMeters = wheelRadiusMeters
        self.wheelbaseMeters = wheelbaseMeters
        self.centerOfMassHeightMeters = centerOfMassHeightMeters
        self.staticFrontWeightFraction = staticFrontWeightFraction
        self.dragAreaSquareMeters = dragAreaSquareMeters
        self.rollingResistanceCoefficient = rollingResistanceCoefficient
        self.tireFrictionCoefficient = tireFrictionCoefficient
    }
}

public struct ScooterHardwareProfile: Sendable, Hashable, Codable {
    public var id: String
    public var displayName: String
    public var battery: BatteryProfile
    public var controller: ControllerProfile
    public var motor: MotorProfile
    public var chassis: ChassisProfile
    public var drivenWheel: DrivenWheel

    public enum DrivenWheel: String, Sendable, Hashable, Codable {
        case front
        case rear
        case both
    }

    public init(
        id: String,
        displayName: String,
        battery: BatteryProfile,
        controller: ControllerProfile,
        motor: MotorProfile,
        chassis: ChassisProfile,
        drivenWheel: DrivenWheel
    ) {
        self.id = id
        self.displayName = displayName
        self.battery = battery
        self.controller = controller
        self.motor = motor
        self.chassis = chassis
        self.drivenWheel = drivenWheel
    }
}

public extension ScooterHardwareProfile {
    /// Provisional calibration profile. Values that are not printed on Joey's hardware
    /// remain explicit estimates and must be replaced from measurements, teardown data,
    /// coast-down tests and loaded-voltage logs.
    static let joeyMaxshotV1SPro = ScooterHardwareProfile(
        id: "maxshot-v1s-pro-joey",
        displayName: "Maxshot V1S Pro",
        battery: BatteryProfile(
            seriesCells: 10,
            capacityAmpHours: 10.5,
            packResistanceOhms: 0.18,
            thermalMassJoulesPerKelvin: 7_500,
            coolingWattsPerKelvin: 2.5,
            maximumDischargeAmps: 20
        ),
        controller: ControllerProfile(
            batteryCurrentLimitAmps: 15,
            motorCurrentLimitAmps: 22,
            lowVoltageCutoffVolts: 31,
            efficiency: 0.94,
            thermalMassJoulesPerKelvin: 420,
            coolingWattsPerKelvin: 2.8,
            derateStartCelsius: 80,
            shutdownCelsius: 105
        ),
        motor: MotorProfile(
            kvRPMPerVolt: 14.5,
            phaseResistanceOhms: 0.42,
            noLoadCurrentAmps: 0.8,
            torqueEfficiency: 0.90,
            thermalMassJoulesPerKelvin: 2_600,
            coolingWattsPerKelvin: 4.0,
            derateStartCelsius: 105,
            shutdownCelsius: 135
        ),
        chassis: ChassisProfile(
            scooterMassKilograms: 16.5,
            riderMassKilograms: 68,
            wheelRadiusMeters: 0.108,
            wheelbaseMeters: 1.02,
            centerOfMassHeightMeters: 0.92,
            staticFrontWeightFraction: 0.46,
            dragAreaSquareMeters: 0.52,
            rollingResistanceCoefficient: 0.018,
            tireFrictionCoefficient: 0.82
        ),
        drivenWheel: .front
    )
}
