import Foundation
import Testing
@testable import ForgeRepairCore

@Test func decodedVerificationReceiptsCannotReuseOneReceiptAcrossGates() {
    let data = Data(#"{"focusedTest":"same-receipt","fullJourney":"same-receipt"}"#.utf8)
    #expect(throws: ForgeRepairError.invalidEvidence) {
        _ = try JSONDecoder().decode(RepairVerificationReceipts.self, from: data)
    }
}
