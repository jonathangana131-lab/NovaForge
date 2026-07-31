import Foundation

extension GameSession {
    var physicalDisplayTelemetry: ScooterDisplayTelemetry {
        ScooterDisplayTelemetry(
            speedMPH: speedMPH,
            packVoltage: simulationState.batteryVoltage,
            stateOfCharge: simulationState.batteryStateOfCharge,
            batteryCurrentAmps: simulationState.batteryCurrentAmps,
            motorCurrentAmps: simulationState.motorCurrentAmps,
            electricalPowerWatts: simulationState.electricalPowerWatts,
            controllerTemperatureC: simulationState.controllerTemperatureCelsius,
            motorTemperatureC: simulationState.motorTemperatureCelsius,
            tripMiles: tripMiles,
            odometerMiles: odometerMiles,
            estimatedRangeMiles: max(0, simulationState.batteryStateOfCharge * 20.0),
            mode: physicalDisplayRideMode,
            headlightOn: false,
            cruiseActive: false,
            brakeActive: touchBrake > 0.05,
            bluetoothConnected: controllerName != nil,
            tractionControlActive: false,
            fault: physicalDisplayFault,
            isPoweredOn: true
        )
    }

    private var physicalDisplayRideMode: ScooterRideMode {
        switch driveMode.rawValue.uppercased() {
        case "ECO": return .eco
        case "S", "SPORT": return .sport
        case "WALK": return .walk
        default: return .drive
        }
    }

    private var physicalDisplayFault: ScooterDisplayFault? {
        if simulationState.controllerCutoff { return .lowVoltage }
        if simulationState.controllerTemperatureCelsius >= 100 { return .controllerOverTemperature }
        if simulationState.motorTemperatureCelsius >= 115 { return .motorOverTemperature }
        return nil
    }
}
