import Foundation

enum ForgePlaytestValidation {
    static func stableValue(_ value: String, field: String, maximum: Int) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw ForgePlaytestError.blankValue(field: field) }
        guard normalized.utf8.count <= maximum else {
            throw ForgePlaytestError.valueTooLong(field: field, maximum: maximum)
        }
        guard !normalized.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ForgePlaytestError.controlCharacter(field: field)
        }
        return normalized
    }

    static func userFacingValue(_ value: String, field: String, maximum: Int) throws -> String {
        try stableValue(value, field: field, maximum: maximum)
    }

    static func maximumCount(_ count: Int, field: String, maximum: Int) throws {
        guard count <= maximum else {
            throw ForgePlaytestError.collectionTooLarge(field: field, maximum: maximum)
        }
    }

    static func receiptIDs(_ values: Set<String>) throws -> Set<String> {
        var normalized = Set<String>()
        for value in values {
            let receiptID = try stableValue(value, field: "receiptID", maximum: 200)
            guard normalized.insert(receiptID).inserted else {
                throw ForgePlaytestError.duplicateReceiptID(receiptID)
            }
        }
        return normalized
    }
}