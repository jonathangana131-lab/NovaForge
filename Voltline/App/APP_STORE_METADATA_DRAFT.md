# Voltline App Store Metadata Draft

## Product identity

- **App name (27/30):** Voltline: Scooter Simulator
- **Subtitle (27/30):** Real electric street riding
- **Primary category:** Games — Simulation
- **Secondary category:** Games — Racing
- **Bundle ID:** `com.joey.VoltlineGame`
- **Version:** `0.2.0`
- **SKU suggestion:** `VOLTLINE-IOS-001`

## Promotional text (under 170 characters)

Ride a physics-driven electric scooter through a living night district, tune real drivetrain limits, earn upgrades, and switch between chase and true POV cameras.

## Description

Voltline is a native electric scooter driving simulator built around believable hardware, rider movement, and road grip instead of fake speed numbers.

Start on a compact front-drive commuter scooter with a five-bar dashboard. Feel battery voltage sag, controller and motor heat, traction limits, braking, steering geometry, rider lean, and crashes through a deterministic high-rate simulation.

Explore a night district with traffic, tunnels, streetlights, slalom areas, and other scooter riders. Drive from chase, close, or first-person cameras with speed-reactive field of view.

Open the draggable in-game phone to check telemetry, bank deposits, deliveries, messages, maps, photos, weather and road grip. Earn money by riding, order compatible parts, wait for distance-based delivery, install upgrades in the garage, and tune supported smart-controller limits.

Features:

- Physics-driven battery, controller, motor, tire and chassis behavior
- Five-step battery display with critical-state blinking
- Analog touch throttle, braking and steering
- DualSense and Apple game-controller support
- Chase, close and first-person cameras
- Traffic and AI scooter riders
- Rider lean, grip loss, collision crashes and reset
- Persistent garage, inventory, deliveries, bank and saves
- Offline simulated PhoneOS apps
- Original procedural motor and wind audio with haptic feedback
- No account, ads, analytics or tracking in the current build

Voltline is an original simulation. Hardware values that have not been physically measured are treated as calibration estimates rather than advertised as verified specifications.

## Keywords (under 100 bytes)

scooter,driving,simulation,electric,physics,traffic,garage,controller,first person,city

## App Review notes

- The game is landscape-only and designed for iPhone.
- No login or test account is required.
- The app works offline and does not contact network services in the current build.
- In-game banking, purchases, deliveries and messages use fictional game currency and simulated offline systems. There are no real-money purchases.
- The VESC-style controller screen uses original artwork and generic simulation terminology; it does not connect to real hardware.
- Use launch arguments `--qa-rich`, `--qa-garage`, `--qa-bank`, `--qa-vesc`, and `--qa-crash` only for automated screenshot fixtures.

## URLs still required in App Store Connect

- **Support URL:** publish a support page or repository issue page.
- **Privacy Policy URL:** publish `PRIVACY_POLICY.md` at a stable public HTTPS URL.
- **Marketing URL:** optional.

## Submission answers to verify at release

- App Privacy: Data Not Collected, provided the final binary still has no network analytics, accounts, advertising or external services.
- Export compliance: `ITSAppUsesNonExemptEncryption` is `false`; re-check if networking or cryptography is later added.
- Age rating: complete Apple’s current questionnaire honestly; simulated traffic collisions and rider falls are non-graphic.
- Content rights: all final models, textures, sounds, fonts, icons and branding need documented commercial rights.
