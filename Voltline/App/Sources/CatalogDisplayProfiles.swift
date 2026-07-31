import Foundation

extension BatterySegmentProfile {
    /// Provisional 14S KuKirin thresholds. Housing, pack voltage and display
    /// dimensions are reference-backed; bar transitions await measured logs.
    static let kukirin52V = BatterySegmentProfile(
        thresholds: [55.8, 53.4, 51.3, 49.0, 46.5],
        criticalVoltage: 45.0,
        cutoffVoltage: 42.0,
        hysteresisVolts: 0.36,
        voltageFilterSeconds: 1.0,
        downgradeDelaySeconds: 2.0,
        upgradeDelaySeconds: 5.0
    )

    /// Provisional 20S Thunder 3 thresholds. The simulation's 60 V cutoff is
    /// preserved; the segmented EY4 battery strip is derived from this state.
    static let dualtron72V = BatterySegmentProfile(
        thresholds: [79.8, 76.4, 73.3, 70.0, 66.5],
        criticalVoltage: 64.0,
        cutoffVoltage: 60.0,
        hysteresisVolts: 0.48,
        voltageFilterSeconds: 0.9,
        downgradeDelaySeconds: 1.8,
        upgradeDelaySeconds: 4.8
    )
}

extension ScooterDisplayIdentity {
    static let kukirinG2Master = ScooterDisplayIdentity(
        id: "kukirin-g2-master",
        manufacturer: "KuKirin",
        model: "G2 Master",
        family: .kukirinMonochromeLCD,
        batteryProfile: .kukirin52V,
        verifiedReferenceCount: 3,
        calibrationNotes: "The 133 × 76 mm faceted LCD housing, 52 V system and three speed levels are reference-backed. Exact segment thresholds and every illuminated icon remain pending powered-screen and ride-log verification."
    )

    static let dualtronThunder3 = ScooterDisplayIdentity(
        id: "dualtron-thunder-3",
        manufacturer: "Dualtron",
        model: "Thunder 3",
        family: .dualtronEY4,
        batteryProfile: .dualtron72V,
        verifiedReferenceCount: 4,
        calibrationNotes: "Thunder 3 uses the connected EY4 display. The housing, central arc, side fields, status row, bottom battery strip and POWER/SET/MODE buttons are reference-backed; voltage transitions remain provisional."
    )
}

enum CatalogDisplayProfileResolver {
    static func identity(for scooterID: String) -> ScooterDisplayIdentity {
        switch scooterID {
        case ScooterCatalogItem.kukirin.id:
            return .kukirinG2Master
        case ScooterCatalogItem.dualtron.id:
            return .dualtronThunder3
        default:
            return .maxshotV1SPro
        }
    }
}
