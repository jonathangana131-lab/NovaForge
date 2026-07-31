import Foundation

enum ScooterManufacturer: String, Codable, CaseIterable, Sendable {
    case maxshot = "Maxshot"
    case kukirin = "KuKirin"
    case dualtron = "Dualtron"
    case nami = "NAMI"
    case segway = "Segway"
    case apollo = "Apollo"
}

enum DashboardTechnology: String, Codable, CaseIterable, Sendable {
    case maxshotVerticalSevenSegmentLED
    case kukirinTouchLED155x55
    case kukirinLCD118x73
    case kukirinG2MasterLCD133x76
    case kukirinG2MaxRevisionedDashboard
    case kukirinLegacyMonochromeLCD
    case kukirinColorTouchDisplay
    case dualtronEY3
    case dualtronEY4
    case namiColorTFT
    case segwayColorTFT
    case apolloColorTFT
    case referenceRequired
}

enum DashboardVerificationState: String, Codable, Sendable {
    /// Powered owner photos/video and manufacturer documentation cover every
    /// visible state needed by the game renderer.
    case verified
    /// Housing and core layout are documented, but one or more illuminated
    /// states, menus or exact battery transitions still need evidence.
    case partial
    /// No renderer may ship for this model until a powered reference set is
    /// obtained. This prevents attractive but fabricated dashboards.
    case blockedPendingReference
}

struct ScooterModelRecord: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let manufacturer: ScooterManufacturer
    let model: String
    let revision: String?
    let nominalVoltage: Double?
    let dashboardTechnology: DashboardTechnology
    let displayWidthMillimeters: Double?
    let displayHeightMillimeters: Double?
    let verification: DashboardVerificationState
    let referenceNotes: String
    let sourceBackedFeatures: [String]

    var canShipAuthenticRenderer: Bool {
        verification == .verified
    }
}

enum ScooterModelRegistry {
    static let records: [ScooterModelRecord] = [
        .init(
            id: "maxshot-v1s-pro-joey",
            manufacturer: .maxshot,
            model: "V1S Pro 500W",
            revision: "Joey owner reference",
            nominalVoltage: 36,
            dashboardTechnology: .maxshotVerticalSevenSegmentLED,
            displayWidthMillimeters: nil,
            displayHeightMillimeters: nil,
            verification: .partial,
            referenceNotes: "Three powered owner references verify lens geometry, ECO/D/S colors, speed placement and five battery blocks. Exact voltage transitions remain ride-log calibration work.",
            sourceBackedFeatures: ["ECO", "D", "S", "mph", "five battery blocks", "headlight icon", "critical final-bar blink"]
        ),

        // MARK: KuKirin current official catalog
        .init(
            id: "kukirin-g2-2026",
            manufacturer: .kukirin,
            model: "G2",
            revision: "2026 touchscreen",
            nominalVoltage: 48,
            dashboardTechnology: .kukirinTouchLED155x55,
            displayWidthMillimeters: 155,
            displayHeightMillimeters: 55,
            verification: .partial,
            referenceNotes: "Official documentation verifies a 155 × 55 mm touch LED and its feature categories. Powered pixel-level captures and all settings pages are still required.",
            sourceBackedFeatures: ["headlight", "cruise", "non-zero start", "gear", "battery", "range", "speed", "turn signal", "gear selector", "settings", "brightness"]
        ),
        .init(
            id: "kukirin-g2-ultra",
            manufacturer: .kukirin,
            model: "G2 Ultra",
            revision: nil,
            nominalVoltage: nil,
            dashboardTechnology: .referenceRequired,
            displayWidthMillimeters: nil,
            displayHeightMillimeters: nil,
            verification: .blockedPendingReference,
            referenceNotes: "Official catalog presence is verified; powered dashboard reference set and exact production-revision specifications are required before implementation.",
            sourceBackedFeatures: []
        ),
        .init(
            id: "kukirin-g2-pro-standard",
            manufacturer: .kukirin,
            model: "G2 Pro",
            revision: "standard 600 W",
            nominalVoltage: 48,
            dashboardTechnology: .kukirinLegacyMonochromeLCD,
            displayWidthMillimeters: nil,
            displayHeightMillimeters: nil,
            verification: .partial,
            referenceNotes: "Official product documentation verifies a multifunction display and controls, but exact dimensions and every illuminated state still need a powered capture set.",
            sourceBackedFeatures: ["real-time ride data", "mode switching", "headlight control", "turn signal", "horn"]
        ),
        .init(
            id: "kukirin-g2-pro-vmp",
            manufacturer: .kukirin,
            model: "G2 Pro",
            revision: "VMP / DGT-certified",
            nominalVoltage: 48,
            dashboardTechnology: .kukirinLCD118x73,
            displayWidthMillimeters: 118,
            displayHeightMillimeters: 73,
            verification: .partial,
            referenceNotes: "Official specifications verify the 118 × 73 mm LCD and three legal speed levels. Exact segment/icon geometry awaits powered references.",
            sourceBackedFeatures: ["15 km/h", "20 km/h", "25 km/h", "mode switching", "ride data"]
        ),
        .init(
            id: "kukirin-g2-pro-abe",
            manufacturer: .kukirin,
            model: "G2 Pro",
            revision: "ABE road-legal",
            nominalVoltage: 48,
            dashboardTechnology: .kukirinLCD118x73,
            displayWidthMillimeters: 118,
            displayHeightMillimeters: 73,
            verification: .partial,
            referenceNotes: "Official ABE specifications verify the 118 × 73 mm LCD and 10/15/20 km/h levels; powered icon/menu references are still required.",
            sourceBackedFeatures: ["10 km/h", "15 km/h", "20 km/h", "ride data"]
        ),
        .init(
            id: "kukirin-g2-max-b",
            manufacturer: .kukirin,
            model: "G2 Max",
            revision: "B dashboard / 4-pin",
            nominalVoltage: 48,
            dashboardTechnology: .kukirinG2MaxRevisionedDashboard,
            displayWidthMillimeters: nil,
            displayHeightMillimeters: nil,
            verification: .blockedPendingReference,
            referenceNotes: "Official parts catalog proves distinct B, C and D dashboard revisions. B must be captured and implemented separately; connector count alone is not enough to infer its UI.",
            sourceBackedFeatures: ["4-pin connector"]
        ),
        .init(
            id: "kukirin-g2-max-c",
            manufacturer: .kukirin,
            model: "G2 Max",
            revision: "C dashboard / 6-pin",
            nominalVoltage: 48,
            dashboardTechnology: .kukirinG2MaxRevisionedDashboard,
            displayWidthMillimeters: nil,
            displayHeightMillimeters: nil,
            verification: .blockedPendingReference,
            referenceNotes: "C revision requires its own powered reference set and connector-aware configuration.",
            sourceBackedFeatures: ["6-pin connector"]
        ),
        .init(
            id: "kukirin-g2-max-d",
            manufacturer: .kukirin,
            model: "G2 Max",
            revision: "D dashboard / 4-pin",
            nominalVoltage: 48,
            dashboardTechnology: .kukirinG2MaxRevisionedDashboard,
            displayWidthMillimeters: nil,
            displayHeightMillimeters: nil,
            verification: .blockedPendingReference,
            referenceNotes: "D revision requires its own powered reference set even though it also uses four pins.",
            sourceBackedFeatures: ["4-pin connector"]
        ),
        .init(
            id: "kukirin-g2-master",
            manufacturer: .kukirin,
            model: "G2 Master",
            revision: nil,
            nominalVoltage: 52,
            dashboardTechnology: .kukirinG2MasterLCD133x76,
            displayWidthMillimeters: 133,
            displayHeightMillimeters: 76,
            verification: .partial,
            referenceNotes: "Housing dimensions and core dashboard geometry are implemented. Powered references for every warning state and factory voltage bar transition are still required.",
            sourceBackedFeatures: ["three speed modes", "speed", "battery", "trip", "voltage", "lighting status"]
        ),
        .init(
            id: "kukirin-g3",
            manufacturer: .kukirin,
            model: "G3",
            revision: nil,
            nominalVoltage: nil,
            dashboardTechnology: .referenceRequired,
            displayWidthMillimeters: nil,
            displayHeightMillimeters: nil,
            verification: .blockedPendingReference,
            referenceNotes: "Official catalog entry is verified; exact display assembly and powered states require reference acquisition.",
            sourceBackedFeatures: []
        ),
        .init(
            id: "kukirin-g3-pro",
            manufacturer: .kukirin,
            model: "G3 Pro",
            revision: nil,
            nominalVoltage: nil,
            dashboardTechnology: .referenceRequired,
            displayWidthMillimeters: nil,
            displayHeightMillimeters: nil,
            verification: .blockedPendingReference,
            referenceNotes: "Do not infer the G3 Pro display from G3 or G2 Master; obtain dedicated powered references first.",
            sourceBackedFeatures: []
        ),
        .init(
            id: "kukirin-g4-2026",
            manufacturer: .kukirin,
            model: "G4",
            revision: "2026 touchscreen / B replacement dashboard listed",
            nominalVoltage: 60,
            dashboardTechnology: .kukirinTouchLED155x55,
            displayWidthMillimeters: 155,
            displayHeightMillimeters: 55,
            verification: .partial,
            referenceNotes: "Official 2026 product page verifies a 155 × 55 mm touch LED, three speed modes and a distinct B replacement dashboard. Full page/state captures are still needed.",
            sourceBackedFeatures: ["20 km/h", "40 km/h", "70 km/h", "ride modes", "touch controls", "ride data", "lighting controls"]
        ),
        .init(
            id: "kukirin-s1-max",
            manufacturer: .kukirin,
            model: "S1 Max",
            revision: nil,
            nominalVoltage: nil,
            dashboardTechnology: .referenceRequired,
            displayWidthMillimeters: nil,
            displayHeightMillimeters: nil,
            verification: .blockedPendingReference,
            referenceNotes: "Catalog presence alone is insufficient; obtain exact dashboard and battery behavior references.",
            sourceBackedFeatures: []
        ),
        .init(
            id: "kukirin-a1",
            manufacturer: .kukirin,
            model: "A1",
            revision: nil,
            nominalVoltage: nil,
            dashboardTechnology: .referenceRequired,
            displayWidthMillimeters: nil,
            displayHeightMillimeters: nil,
            verification: .blockedPendingReference,
            referenceNotes: "Dedicated references required.",
            sourceBackedFeatures: []
        ),
        .init(
            id: "kukirin-m4-max",
            manufacturer: .kukirin,
            model: "M4 Max",
            revision: nil,
            nominalVoltage: nil,
            dashboardTechnology: .referenceRequired,
            displayWidthMillimeters: nil,
            displayHeightMillimeters: nil,
            verification: .blockedPendingReference,
            referenceNotes: "Dedicated references required.",
            sourceBackedFeatures: []
        ),
        .init(
            id: "kukirin-t3",
            manufacturer: .kukirin,
            model: "T3",
            revision: nil,
            nominalVoltage: nil,
            dashboardTechnology: .referenceRequired,
            displayWidthMillimeters: nil,
            displayHeightMillimeters: nil,
            verification: .blockedPendingReference,
            referenceNotes: "Dedicated references required.",
            sourceBackedFeatures: []
        ),

        // MARK: Dualtron display systems and revision families
        .init(
            id: "dualtron-thunder-3-ey4",
            manufacturer: .dualtron,
            model: "Thunder 3",
            revision: "factory EY4",
            nominalVoltage: 72,
            dashboardTechnology: .dualtronEY4,
            displayWidthMillimeters: nil,
            displayHeightMillimeters: nil,
            verification: .partial,
            referenceNotes: "Factory EY4 use, housing, color arc, status row, side fields, controls and battery strip are reference-backed. All settings pages and exact warning animations remain to be captured.",
            sourceBackedFeatures: ["app connectivity", "speed", "battery strip", "trip", "odometer", "range", "status icons", "POWER", "SET", "MODE"]
        ),
        .init(
            id: "dualtron-x-limited-ey4",
            manufacturer: .dualtron,
            model: "X Limited",
            revision: "fourth-generation EY4",
            nominalVoltage: 84,
            dashboardTechnology: .dualtronEY4,
            displayWidthMillimeters: nil,
            displayHeightMillimeters: nil,
            verification: .partial,
            referenceNotes: "Official manufacturer documentation confirms fourth-generation EY4 and app connectivity. Model-specific settings and 84 V battery mapping still require captures.",
            sourceBackedFeatures: ["color LCD", "app connectivity", "ride data", "diagnostics", "performance settings"]
        ),
        .init(
            id: "dualtron-ey4-current-family",
            manufacturer: .dualtron,
            model: "EY4-equipped model family",
            revision: "model/revision-specific",
            nominalVoltage: nil,
            dashboardTechnology: .dualtronEY4,
            displayWidthMillimeters: nil,
            displayHeightMillimeters: nil,
            verification: .blockedPendingReference,
            referenceNotes: "EY4 compatibility includes newer Achilleus, City, Mini, Spider Max, Storm, Thunder 2/3, Ultra 2 Upgrade, Victor and X variants, but each scooter revision must be resolved individually before shipping.",
            sourceBackedFeatures: ["EY4 display family", "app-capable variants"]
        ),
        .init(
            id: "dualtron-ey3-legacy-family",
            manufacturer: .dualtron,
            model: "EY3-equipped model family",
            revision: "model/revision-specific",
            nominalVoltage: nil,
            dashboardTechnology: .dualtronEY3,
            displayWidthMillimeters: nil,
            displayHeightMillimeters: nil,
            verification: .blockedPendingReference,
            referenceNotes: "EY3 compatibility spans numerous earlier Dualtron variants. Model year, connector and original display photos must resolve each record; no automatic EY4 substitution is allowed.",
            sourceBackedFeatures: ["speed", "power mode", "system readouts", "trigger throttle assembly"]
        )
    ]

    static func record(id: String) -> ScooterModelRecord? {
        records.first { $0.id == id }
    }

    static func records(manufacturer: ScooterManufacturer) -> [ScooterModelRecord] {
        records.filter { $0.manufacturer == manufacturer }
    }

    static var blockedRecords: [ScooterModelRecord] {
        records.filter { $0.verification == .blockedPendingReference }
    }
}
