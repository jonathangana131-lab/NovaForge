# Voltline 1.0

Voltline is a native, landscape iPhone scooter-driving game built with SwiftUI, RealityKit, UIKit feedback systems, and a deterministic pure-Swift simulation core. The game lives inside this repository as an isolated project while GitHub Actions provides real macOS/Xcode simulator validation.

## Release target

- Version: **1.0.0 (build 100)**
- Minimum OS: **iOS 18**
- Primary device target: **iPhone 12 in landscape**
- Current release toolchain gate: **Xcode 26 or newer**
- Bundle identifier: `com.joey.VoltlineGame`

## Finished game systems

### Physics and riding

- Deterministic 120 Hz fixed-step scooter drivetrain simulation
- Data-driven battery, controller, motor, chassis, tire, drag, rolling resistance, voltage sag, thermal, cutoff, regen, and road-load behavior
- Touch throttle, brake, steering, drive modes, camera switching, controller input, and first-person/chase cameras
- Tire-grip limits, steering load, rider lean, crashes, reset behavior, traffic collisions, and simulated AI traffic/scooter riders
- Frame-rate-independent game state with selectable 30/60/120 FPS presentation and thermal protection

### World and vehicles

- Native RealityKit night district with boulevard, tunnel, buildings, streetlights, traffic, AI scooter riders, and slalom landmarks
- Maxshot V1S Pro calibration profile plus additional legally distinct scooter profiles
- Hardware-aware garage, purchases, deliveries, compatible parts, installation, and selectable scooters

### PhoneOS and progression

- Draggable in-game phone with Home, Maps, Weather, Messages, Camera, Photos, Bank, Market, Scooter, and VESC-style tuning apps
- Distance earnings, $100 bank deposits, delivery progress, inventory, and permanent save data
- Seven physics-backed objectives covering route checkpoints, distance, speed, clean riding, deposits, photos, and controller upgrades
- Persistent objective completion, checkpoint navigation, real bank rewards, and completion feedback

### Player experience and release quality

- First-run onboarding, permanent settings, reduced motion, procedural ride audio, haptics, lifecycle pausing, control release, and iPhone thermal handling
- App icon generation, privacy manifest, App Store archive/export script, connected-iPhone install script, unsigned device compilation, unit tests, UI tests, and real simulator screenshot artifacts

## Hardware calibration note

The starter Maxshot profile currently uses the confirmed controller markings and the best available scooter/battery information:

- 36 V nominal battery
- 10.5 Ah provisional pack capacity
- 31 V controller undervoltage cutoff
- 15 A controller label current
- 350 W controller label / 500 W marketed scooter rating
- Front direct-drive hub motor

Values that have not been physically measured remain explicit data fields. They can be replaced without rewriting gameplay or adding hidden arcade multipliers.

## Build and test

From `Voltline/App` on a Mac with Xcode 26 or newer:

```bash
chmod +x Scripts/bootstrap.sh
Scripts/bootstrap.sh
xcodebuild \
  -project VoltlineGame.xcodeproj \
  -scheme VoltlineGame \
  -destination 'platform=iOS Simulator,name=iPhone 12' \
  test
```

The repository's `Voltline iOS Game` workflow also creates an SDK-matched iPhone simulator, compiles the app and test bundles, runs native unit/UI tests, verifies unsigned iPhoneOS compilation, launches deterministic QA fixtures, captures real screenshots, and uploads the simulator app plus proof logs.

## Install on a connected iPhone

```bash
cd Voltline/App
xcrun devicectl list devices
bash Scripts/install_connected_iphone.sh <device-identifier>
```

A valid Apple development team and provisioning access are required for a physical-device build.

## Create an App Store archive

```bash
cd Voltline/App
DEVELOPMENT_TEAM=<team-id> bash Scripts/archive_app_store.sh
```

The script verifies Xcode, privacy metadata, bundle identity, the archived app, and the exported IPA before reporting success.

## Architecture rules

- `VoltlineSim` contains no SwiftUI, RealityKit, or display-loop dependency.
- Physics advances only through deterministic fixed steps.
- Frame rate changes presentation frequency, never physics behavior.
- UI reads values emitted by the simulation rather than inventing speed, battery, range, current, or temperature.
- Purchases and tuning remain constrained by compatible hardware and electrical/thermal limits.
