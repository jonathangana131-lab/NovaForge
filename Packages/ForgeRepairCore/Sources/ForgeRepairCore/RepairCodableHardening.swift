import Foundation

public extension RepairVerificationReceipts {
    init(from decoder: Decoder) throws {
        enum CodingKeys: String, CodingKey {
            case focusedTest
            case fullJourney
            case visualRegression
            case accessibility
            case performance
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            focusedTest: c.decodeIfPresent(RepairReceiptID.self, forKey: .focusedTest),
            fullJourney: c.decodeIfPresent(RepairReceiptID.self, forKey: .fullJourney),
            visualRegression: c.decodeIfPresent(RepairReceiptID.self, forKey: .visualRegression),
            accessibility: c.decodeIfPresent(RepairReceiptID.self, forKey: .accessibility),
            performance: c.decodeIfPresent(RepairReceiptID.self, forKey: .performance)
        )
    }
}
