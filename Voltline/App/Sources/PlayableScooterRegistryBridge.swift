import Foundation

extension ScooterModelRegistry {
    /// Resolves a broad playable catalog item to the exact evidence record used
    /// by its current in-game configuration. Future model-year choices can
    /// change this mapping without erasing the underlying revision records.
    static func playableRecord(for scooterID: String) -> ScooterModelRecord? {
        switch scooterID {
        case ScooterCatalogItem.maxshot.id:
            return record(id: "maxshot-v1s-pro-joey")
        case ScooterCatalogItem.kukirin.id:
            return record(id: "kukirin-g2-master")
        case ScooterCatalogItem.dualtron.id:
            return record(id: "dualtron-thunder-3-ey4")
        default:
            return nil
        }
    }
}
