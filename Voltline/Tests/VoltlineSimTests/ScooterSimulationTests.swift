import Testing
@testable import VoltlineSim

@Suite("Voltline scooter simulation")
struct ScooterSimulationTests {
    @Test("Simulation is deterministic for identical inputs")
    func deterministicReplay() {
        var first = ScooterSimulation(hardware: .joeyMaxshotV1SPro)
        var second = ScooterSimulation(hardware: .joeyMaxshotV1SPro)
        let input = SimulationInput(throttle: 0.73, roadGradeRadians: 0.015, ambientCelsius: 24)

        first.advance(seconds: 45, input: input)
        second.advance(seconds: 45, input: input)

        #expect(first.state == second.state)
    }

    @Test("Loaded battery voltage sags and state of charge falls")
    func loadedBatteryBehavior() {
        var simulation = ScooterSimulation(hardware: .joeyMaxshotV1SPro)
        let restingVoltage = simulation.state.batteryVoltage

        simulation.advance(seconds: 20, input: SimulationInput(throttle: 1))

        #expect(simulation.state.batteryCurrentAmps > 0)
        #expect(simulation.state.batteryVoltage < restingVoltage)
        #expect(simulation.state.batteryStateOfCharge < 1)
        #expect(simulation.state.batteryTemperatureCelsius > 20)
    }

    @Test("Low pack voltage activates controller cutoff")
    func lowVoltageCutoff() {
        var initial = SimulationState(batteryStateOfCharge: 0, batteryVoltage: 30)
        initial.speedMetersPerSecond = 0
        var simulation = ScooterSimulation(
            hardware: .joeyMaxshotV1SPro,
            initialState: initial
        )

        simulation.step(input: SimulationInput(throttle: 1))

        #expect(simulation.state.controllerCutoff)
        #expect(simulation.state.motorCurrentAmps == 0)
    }

    @Test("Full throttle reaches a stable finite road speed")
    func terminalSpeed() {
        var simulation = ScooterSimulation(hardware: .joeyMaxshotV1SPro)
        simulation.advance(seconds: 180, input: SimulationInput(throttle: 1))

        let speedMPH = simulation.state.speedMetersPerSecond * 2.2369362921
        #expect(speedMPH > 10)
        #expect(speedMPH < 35)
        #expect(simulation.state.distanceMeters > 500)
    }

    @Test("Braking cannot produce negative vehicle speed")
    func brakingStopsAtZero() {
        var initial = SimulationState(speedMetersPerSecond: 4, batteryVoltage: 40)
        initial.motorRPM = 350
        var simulation = ScooterSimulation(
            hardware: .joeyMaxshotV1SPro,
            initialState: initial
        )

        simulation.advance(seconds: 10, input: SimulationInput(throttle: 0, brake: 1))

        #expect(simulation.state.speedMetersPerSecond == 0)
        #expect(simulation.state.distanceMeters > 0)
    }
}
