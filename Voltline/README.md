# Voltline

Voltline is a physics-first iOS scooter driving game. This directory is a new project isolated from NovaForge while the repository setup is reused for cloud-Mac CI.

## Foundation rule

No throwaway prototype systems. Every phase must leave production code behind stable interfaces. Visual features consume the simulation core; they do not replace it.

## Initial hardware target

The starter scooter is a calibration profile for Joey's Maxshot V1S Pro:

- 36 V nominal, 10.5 Ah battery (provisional until pack label/cell data is verified)
- 31 V controller undervoltage cutoff
- 15 A controller label current
- 350 W controller label / 500 W marketed scooter rating
- front hub motor, direct drive

Every uncertain parameter is explicit and replaceable. No hidden arcade multipliers live inside the physics engine.

## Phase plan

0. **Permanent foundation** — deterministic fixed-step simulation, hardware profiles, tests, CI, save-data schemas.
1. **Maxshot vertical slice** — one accurate scooter, working display, garage, first-person controls, DualSense input, one test road.
2. **Rider and contact physics** — rider mass/pose, hands, braking, tire slip, load transfer, falls and ragdoll handoff.
3. **World and traffic** — streamed district, roads, weather, aware vehicles and scooter riders.
4. **PhoneOS** — draggable phone, home screen, Maps, Weather, Messages bots, Camera, Photos, bank and scooter companion app.
5. **Economy and logistics** — distance earnings, $100 deposits, orders with real progress states, garage inventory.
6. **Upgrade ecosystem** — batteries, motors, controllers, compatibility graph, thermal/electrical limits and VESC-style tuning.
7. **Vehicle catalog and polish** — legally distinct KuKirin/Dualtron-class profiles, authentic instrument behavior, audio, optimization and accessibility.

## Non-negotiable architecture

- `VoltlineSim` is pure Swift and has no SwiftUI, RealityKit or game-loop dependency.
- Simulation advances only through fixed time steps and deterministic input frames.
- Rendering interpolates simulation snapshots; frame rate never changes physics.
- Hardware is data-driven and calibrated from measurements.
- UI displays values emitted by the simulation; it never invents speed, battery bars, range or temperatures.
- Purchases and tuning are validated against connector, voltage, current, thermal and mechanical limits.

## Current state

Phase 0 has begun with a Swift package containing the battery, controller, motor, road-load and drivetrain simulation plus deterministic tests.