# Voltline App Store Readiness

Voltline is being built as a permanent native iOS game, not a disposable prototype. A phase is complete only when its code compiles, its automated checks pass, and its user-facing surface is captured from a real iOS Simulator. Physical-device performance gates require an actual iPhone.

## Implemented architecture

- Native SwiftUI application target with RealityKit rendering.
- Pure-Swift `VoltlineSim` hardware simulation package separated from UI/rendering.
- Fixed 120 Hz deterministic electrical and longitudinal physics.
- Data-driven scooter, battery, motor, controller, chassis and tire profiles.
- Maxshot starting scooter and authentic five-step battery-display behavior.
- Analog touch controls and Apple Game Controller / DualSense mappings.
- Chase, close and first-person cameras with speed-reactive field of view.
- Rider pose, hands, steering, lean, loss-of-grip crash and crash reset.
- AI cars and AI scooter riders with basic collision awareness.
- Persistent garage, purchases, inventory, installs, orders and saves.
- Distance-derived earnings with $100 bank deposits.
- Draggable in-game PhoneOS with offline simulated apps.
- VESC-style tuning that changes simulated controller/motor limits.
- Generated regular, dark and tinted 1024-pixel app icons.
- macOS CI for Simulator tests, unsigned iPhoneOS compilation and screenshot artifacts.

## Gates before TestFlight or App Store submission

### 1. Build and automated validation

- Native Simulator build must pass from a clean checkout.
- Unit and UI tests must pass.
- Screenshot artifacts must show the ride HUD, garage, PhoneOS, VESC screen and crash state.
- Unsigned generic iPhoneOS compilation must pass.

### 2. Physical iPhone validation

Required on Joey's iPhone 12:

- Install a signed development build.
- Verify launch, app icon and landscape rotation.
- Measure sustained frame rate and frame pacing in each camera.
- Measure thermal behavior, memory pressure and battery drain during a 30-minute ride.
- Verify touch steering, partial throttle and partial braking.
- Verify DualSense analog triggers, sticks, reconnect and all mapped actions.
- Verify speaker/headphone audio levels once final audio is implemented.

A Simulator screenshot cannot prove real-device GPU performance or touch feel.

### 3. Maxshot accuracy calibration

The following label-backed values are currently treated as verified:

- 36 V nominal pack class.
- 10.5 Ah capacity.
- 15 A controller battery-current label.
- 31 V undervoltage cutoff.
- Front-driven wheel architecture.
- Five discrete battery bars with a blinking red critical state.
- Walk, Eco, Drive and Sport behavior with a known 35 km/h upper setting.

The following must be measured or sourced from an exact matching production revision before claiming exact simulation:

- Scooter mass and Joey's selected rider mass.
- Wheel loaded radius and wheelbase.
- Battery open-circuit curve and pack resistance at several states of charge.
- Loaded-voltage/current logs under full throttle.
- Motor KV, winding resistance, no-load current and thermal constants.
- Controller phase-current behavior, current ramps and thermal limits.
- Coast-down drag and rolling resistance.
- Tire friction on dry asphalt, wet asphalt, paint and gravel.
- Brake-force curve, cable/free-play behavior and regen behavior.
- Exact display dimensions, glyphs, indicators, button pages and blink timing.

Measured data can replace calibration tables without rewriting game systems.

### 4. Art and licensing

- Replace or refine procedural scooter models with production-quality, legally licensed models.
- Do not use manufacturer logos, app artwork, proprietary UI assets or exact product branding without permission.
- The in-game VESC-style tool must use original branding and artwork unless trademark/open-source license requirements are reviewed and satisfied.
- Vehicle, city, rider, sound and texture assets must have documented commercial licenses.

### 5. App Store product requirements

- Final unique app name and subtitle.
- Support URL and privacy-policy URL.
- App Privacy answers based on the final build.
- Age rating questionnaire.
- App Store screenshots for required iPhone display classes.
- Promotional text, description and keywords.
- Export-compliance answers.
- Signed Release archive using the correct distribution certificate/profile.
- TestFlight external-testing review before public release.
- Crash-free and performance validation on the supported device range.

## Current distribution status

The repository can produce a Simulator app without signing. Installing on a physical iPhone requires opening the generated Xcode project on the user's Mac, selecting the user's Apple team, connecting and unlocking the iPhone with Developer Mode enabled, and running the `VoltlineGame` scheme. App Store distribution additionally requires Apple Developer Program/App Store Connect access and distribution signing.
