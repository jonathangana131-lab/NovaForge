import Foundation

public struct SimulationInput: Sendable, Hashable, Codable {
    public var throttle: Double
    public var brake: Double
    public var roadGradeRadians: Double
    public var ambientCelsius: Double
    public var airDensityKilogramsPerCubicMeter: Double

    public init(
        throttle: Double,
        brake: Double = 0,
        roadGradeRadians: Double = 0,
        ambientCelsius: Double = 20,
        airDensityKilogramsPerCubicMeter: Double = 1.225
    ) {
        self.throttle = throttle.clamped(to: 0...1)
        self.brake = brake.clamped(to: 0...1)
        self.roadGradeRadians = roadGradeRadians
        self.ambientCelsius = ambientCelsius
        self.airDensityKilogramsPerCubicMeter = airDensityKilogramsPerCubicMeter
    }
}

public struct SimulationState: Sendable, Hashable, Codable {
    public var elapsedSeconds: Double
    public var distanceMeters: Double
    public var speedMetersPerSecond: Double
    public var accelerationMetersPerSecondSquared: Double
    public var batteryStateOfCharge: Double
    public var batteryVoltage: Double
    public var batteryCurrentAmps: Double
    public var motorCurrentAmps: Double
    public var motorRPM: Double
    public var motorTorqueNewtonMeters: Double
    public var batteryTemperatureCelsius: Double
    public var controllerTemperatureCelsius: Double
    public var motorTemperatureCelsius: Double
    public var electricalPowerWatts: Double
    public var mechanicalPowerWatts: Double
    public var tractionLimited: Bool
    public var controllerCutoff: Bool

    public init(
        elapsedSeconds: Double = 0,
        distanceMeters: Double = 0,
        speedMetersPerSecond: Double = 0,
        accelerationMetersPerSecondSquared: Double = 0,
        batteryStateOfCharge: Double = 1,
        batteryVoltage: Double = 42,
        batteryCurrentAmps: Double = 0,
        motorCurrentAmps: Double = 0,
        motorRPM: Double = 0,
        motorTorqueNewtonMeters: Double = 0,
        batteryTemperatureCelsius: Double = 20,
        controllerTemperatureCelsius: Double = 20,
        motorTemperatureCelsius: Double = 20,
        electricalPowerWatts: Double = 0,
        mechanicalPowerWatts: Double = 0,
        tractionLimited: Bool = false,
        controllerCutoff: Bool = false
    ) {
        self.elapsedSeconds = elapsedSeconds
        self.distanceMeters = distanceMeters
        self.speedMetersPerSecond = speedMetersPerSecond
        self.accelerationMetersPerSecondSquared = accelerationMetersPerSecondSquared
        self.batteryStateOfCharge = batteryStateOfCharge.clamped(to: 0...1)
        self.batteryVoltage = batteryVoltage
        self.batteryCurrentAmps = batteryCurrentAmps
        self.motorCurrentAmps = motorCurrentAmps
        self.motorRPM = motorRPM
        self.motorTorqueNewtonMeters = motorTorqueNewtonMeters
        self.batteryTemperatureCelsius = batteryTemperatureCelsius
        self.controllerTemperatureCelsius = controllerTemperatureCelsius
        self.motorTemperatureCelsius = motorTemperatureCelsius
        self.electricalPowerWatts = electricalPowerWatts
        self.mechanicalPowerWatts = mechanicalPowerWatts
        self.tractionLimited = tractionLimited
        self.controllerCutoff = controllerCutoff
    }
}

public struct ScooterSimulation: Sendable {
    public let hardware: ScooterHardwareProfile
    public let fixedTimeStep: Double
    public private(set) var state: SimulationState

    public init(
        hardware: ScooterHardwareProfile,
        fixedTimeStep: Double = 1.0 / 120.0,
        initialState: SimulationState? = nil
    ) {
        precondition(fixedTimeStep > 0)
        self.hardware = hardware
        self.fixedTimeStep = fixedTimeStep
        self.state = initialState ?? SimulationState(
            batteryVoltage: Double(hardware.battery.seriesCells) * hardware.battery.cellFullVoltage
        )
    }

    @discardableResult
    public mutating func step(input: SimulationInput) -> SimulationState {
        let dt = fixedTimeStep
        let battery = hardware.battery
        let controller = hardware.controller
        let motor = hardware.motor
        let chassis = hardware.chassis
        let mass = chassis.totalMassKilograms
        let gravity = 9.80665

        let openCircuitVoltage = Self.openCircuitVoltage(
            stateOfCharge: state.batteryStateOfCharge,
            profile: battery
        )

        let wheelAngularVelocity = state.speedMetersPerSecond / chassis.wheelRadiusMeters
        let motorRPM = wheelAngularVelocity * 60 / (2 * .pi)
        let backEMFVolts = motorRPM / motor.kvRPMPerVolt

        let controllerThermalFactor = Self.thermalDerate(
            temperature: state.controllerTemperatureCelsius,
            start: controller.derateStartCelsius,
            stop: controller.shutdownCelsius
        )
        let motorThermalFactor = Self.thermalDerate(
            temperature: state.motorTemperatureCelsius,
            start: motor.derateStartCelsius,
            stop: motor.shutdownCelsius
        )
        let availableFactor = min(controllerThermalFactor, motorThermalFactor)

        let estimatedTerminalVoltage = max(
            0,
            openCircuitVoltage - state.batteryCurrentAmps * battery.packResistanceOhms
        )
        let lowVoltageCutoff = estimatedTerminalVoltage <= controller.lowVoltageCutoffVolts
        let commandedDuty = lowVoltageCutoff ? 0 : input.throttle * availableFactor
        let motorAppliedVoltage = commandedDuty * estimatedTerminalVoltage
        let rawMotorCurrent = max(0, (motorAppliedVoltage - backEMFVolts) / motor.phaseResistanceOhms)

        let batteryLimitedMotorCurrent = controller.efficiency * controller.batteryCurrentLimitAmps / max(commandedDuty, 0.08)
        let motorCurrentLimit = min(
            controller.motorCurrentLimitAmps,
            min(battery.maximumDischargeAmps / max(commandedDuty, 0.08), batteryLimitedMotorCurrent)
        ) * availableFactor
        let motorCurrent = min(rawMotorCurrent, motorCurrentLimit)

        let torqueConstant = 60 / (2 * .pi * motor.kvRPMPerVolt)
        let motorTorque = max(0, motorCurrent - motor.noLoadCurrentAmps) * torqueConstant * motor.torqueEfficiency
        let unconstrainedDriveForce = motorTorque / chassis.wheelRadiusMeters

        let previousAcceleration = state.accelerationMetersPerSecondSquared
        let frontNormal = mass * gravity * chassis.staticFrontWeightFraction
            - mass * previousAcceleration * chassis.centerOfMassHeightMeters / chassis.wheelbaseMeters
        let rearNormal = mass * gravity - frontNormal
        let drivenNormal: Double
        switch hardware.drivenWheel {
        case .front: drivenNormal = max(0, frontNormal)
        case .rear: drivenNormal = max(0, rearNormal)
        case .both: drivenNormal = mass * gravity
        }
        let maximumTireForce = chassis.tireFrictionCoefficient * drivenNormal
        let driveForce = min(unconstrainedDriveForce, maximumTireForce)
        let tractionLimited = unconstrainedDriveForce > maximumTireForce

        let aerodynamicDrag = 0.5
            * input.airDensityKilogramsPerCubicMeter
            * chassis.dragAreaSquareMeters
            * state.speedMetersPerSecond * state.speedMetersPerSecond
        let rollingResistance = state.speedMetersPerSecond > 0.01
            ? chassis.rollingResistanceCoefficient * mass * gravity * cos(input.roadGradeRadians)
            : 0
        let gradeForce = mass * gravity * sin(input.roadGradeRadians)
        let brakingForce = input.brake * chassis.tireFrictionCoefficient * mass * gravity

        let netForce = driveForce - aerodynamicDrag - rollingResistance - gradeForce - brakingForce
        let acceleration = netForce / mass
        let nextSpeed = max(0, state.speedMetersPerSecond + acceleration * dt)
        let averageSpeed = 0.5 * (state.speedMetersPerSecond + nextSpeed)

        let motorElectricalPower = motorAppliedVoltage * motorCurrent
        let batteryPower = motorElectricalPower / max(controller.efficiency, 0.01)
        let batteryCurrent = commandedDuty > 0
            ? min(battery.maximumDischargeAmps, batteryPower / max(estimatedTerminalVoltage, 0.1))
            : 0
        let terminalVoltage = max(0, openCircuitVoltage - batteryCurrent * battery.packResistanceOhms)

        let usedAmpHours = batteryCurrent * dt / 3600
        let nextSOC = max(0, state.batteryStateOfCharge - usedAmpHours / battery.capacityAmpHours)

        let batteryHeat = batteryCurrent * batteryCurrent * battery.packResistanceOhms
        let controllerLoss = max(0, batteryPower - motorElectricalPower)
        let copperLoss = motorCurrent * motorCurrent * motor.phaseResistanceOhms
        let batteryTemperature = Self.integrateTemperature(
            current: state.batteryTemperatureCelsius,
            heatWatts: batteryHeat,
            ambient: input.ambientCelsius,
            thermalMass: battery.thermalMassJoulesPerKelvin,
            cooling: battery.coolingWattsPerKelvin,
            dt: dt
        )
        let controllerTemperature = Self.integrateTemperature(
            current: state.controllerTemperatureCelsius,
            heatWatts: controllerLoss,
            ambient: input.ambientCelsius,
            thermalMass: controller.thermalMassJoulesPerKelvin,
            cooling: controller.coolingWattsPerKelvin,
            dt: dt
        )
        let motorTemperature = Self.integrateTemperature(
            current: state.motorTemperatureCelsius,
            heatWatts: copperLoss,
            ambient: input.ambientCelsius,
            thermalMass: motor.thermalMassJoulesPerKelvin,
            cooling: motor.coolingWattsPerKelvin,
            dt: dt
        )

        state = SimulationState(
            elapsedSeconds: state.elapsedSeconds + dt,
            distanceMeters: state.distanceMeters + averageSpeed * dt,
            speedMetersPerSecond: nextSpeed,
            accelerationMetersPerSecondSquared: acceleration,
            batteryStateOfCharge: nextSOC,
            batteryVoltage: terminalVoltage,
            batteryCurrentAmps: batteryCurrent,
            motorCurrentAmps: motorCurrent,
            motorRPM: motorRPM,
            motorTorqueNewtonMeters: motorTorque,
            batteryTemperatureCelsius: batteryTemperature,
            controllerTemperatureCelsius: controllerTemperature,
            motorTemperatureCelsius: motorTemperature,
            electricalPowerWatts: batteryPower,
            mechanicalPowerWatts: motorTorque * wheelAngularVelocity,
            tractionLimited: tractionLimited,
            controllerCutoff: lowVoltageCutoff
        )
        return state
    }

    public mutating func advance(seconds: Double, input: SimulationInput) -> SimulationState {
        precondition(seconds >= 0)
        let stepCount = Int((seconds / fixedTimeStep).rounded(.down))
        for _ in 0..<stepCount { step(input: input) }
        return state
    }

    static func openCircuitVoltage(stateOfCharge: Double, profile: BatteryProfile) -> Double {
        let soc = stateOfCharge.clamped(to: 0...1)
        // Smooth approximation of a lithium-ion discharge curve. The profile remains
        // replaceable by measured lookup tables without changing callers.
        let shaped = 0.08 * soc + 0.92 * pow(soc, 0.32)
        let cellVoltage = profile.cellEmptyVoltage
            + (profile.cellFullVoltage - profile.cellEmptyVoltage) * shaped
        return Double(profile.seriesCells) * cellVoltage
    }

    static func thermalDerate(temperature: Double, start: Double, stop: Double) -> Double {
        guard temperature > start else { return 1 }
        guard temperature < stop else { return 0 }
        return 1 - (temperature - start) / (stop - start)
    }

    static func integrateTemperature(
        current: Double,
        heatWatts: Double,
        ambient: Double,
        thermalMass: Double,
        cooling: Double,
        dt: Double
    ) -> Double {
        let coolingPower = cooling * (current - ambient)
        return current + (heatWatts - coolingPower) / thermalMass * dt
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
