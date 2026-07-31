# Voltline 1.0 Release Checklist

## Automated gate

- [ ] `Voltline Simulation Core` passes deterministic Swift package tests.
- [ ] `Voltline iOS Game` completes with Xcode 26 or newer.
- [ ] Simulator build and test bundles compile.
- [ ] All native unit tests pass.
- [ ] All native UI tests pass on the SDK-matched iPhone simulator.
- [ ] Mission selection closes the objective board and returns usable throttle control.
- [ ] Transparent mission HUD and completion layers pass steering, brake, and throttle touches outside their visible buttons.
- [ ] Unsigned generic iPhoneOS compilation passes.
- [ ] At least nine real XCUITest screenshots are exported for onboarding, ride HUD, settings, garage, Bank, VESC, crash, objective board, and active objective HUD.
- [ ] The simulator `.app`, app icon, screenshots, logs, and `.xcresult` bundles are uploaded.

## Manual iPhone 12 pass

- [ ] Install using `Scripts/install_connected_iphone.sh`.
- [ ] Confirm landscape launch and onboarding fit without clipping.
- [ ] Verify steering, throttle, brake, camera, phone, garage, settings, and pause/resume.
- [ ] Verify audio and haptics toggles disable their actual systems.
- [ ] Verify Battery Saver targets 30 FPS and Balanced targets 60 FPS.
- [ ] Ride for at least 15 minutes and confirm thermal protection reduces the target when needed.
- [ ] Complete Tunnel Line and confirm ordered checkpoint progress plus bank reward.
- [ ] Trigger and reset a crash.
- [ ] Purchase, deliver, and install one compatible part.
- [ ] Write a VESC configuration and verify limits persist after relaunch.
- [ ] Capture a photo and confirm it appears in Photos.
- [ ] Confirm backgrounding pauses physics and releases every touch input.

## Archive pass

- [ ] Confirm Apple development team and bundle registration.
- [ ] Run `DEVELOPMENT_TEAM=<team-id> bash Scripts/archive_app_store.sh`.
- [ ] Confirm the archive contains `PrivacyInfo.xcprivacy`.
- [ ] Confirm the archive bundle identifier is `com.joey.VoltlineGame`.
- [ ] Confirm an IPA is produced.
- [ ] Run App Store Connect validation before submission.

## Calibration disclosure

- [ ] Re-check any physically measured Maxshot battery, controller, motor, wheel, rider-mass, and tire values.
- [ ] Update the data profile when a measured value differs from a provisional value.
- [ ] Do not hide uncertainty with an unexplained performance multiplier.
