# Voltline physics calibration

The simulation architecture is permanent; parameter values improve as evidence improves.

## Confidence levels

Every hardware value will eventually carry one of these sources:

1. **Printed** — visible on the battery, controller, motor, tire or scooter label.
2. **Measured** — obtained from dimensions, scale weight, voltage/current logging, resistance tests or controlled runs.
3. **Manufacturer published** — tied to an exact model/revision and preserved with source notes.
4. **Inferred** — calculated from measured behavior, with uncertainty recorded.
5. **Provisional** — a clearly marked starting estimate used only until better data exists.

## Joey's Maxshot V1S Pro: currently known

- 36 V system label
- 10.5 Ah reported battery capacity
- 15 A controller label
- 31 V controller undervoltage label
- 350 W controller label
- 500 W scooter-side/listing rating
- front hub motor
- solid stock tires
- observed top speed around 22 mph under Joey's real riding conditions

## Measurements needed for high-confidence calibration

### Geometry and mass

- scooter mass
- rider mass used for the profile
- loaded tire radius
- wheelbase
- deck height and rider center-of-mass estimate
- front/rear static weight distribution

### Battery

- resting voltage at each display bar
- loaded voltage and current at full throttle
- voltage recovery after load
- charge energy from empty to full
- pack temperature during a repeatable route
- exact battery label and connector details

### Motor and controller

- no-load wheel speed at known pack voltage
- phase-to-phase resistance where safely measurable
- peak battery current and sustained battery current
- controller temperature response
- motor shell temperature response
- throttle mapping and drive-mode current/speed behavior

### Road-load test

A coast-down test on level ground records speed versus time after releasing throttle. Fitting that curve separates rolling resistance from aerodynamic drag. Multiple passes in opposite directions reduce wind and grade error.

## Calibration acceptance

A Maxshot profile is considered calibrated when it reproduces, within recorded uncertainty:

- launch acceleration versus time
- top speed at several battery states
- loaded voltage sag
- battery use over a repeatable route
- coast-down behavior
- thermal rise during sustained operation
- display speed, battery bars, trip and odometer behavior

## Architecture consequence

Rendering, display UI, PhoneOS, economy and audio consume `SimulationState`. Calibration updates data profiles or lookup tables; they do not require replacing those systems.