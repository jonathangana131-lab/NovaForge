import Foundation

public enum VisualSelectionAuthorityError: Error, Equatable, Sendable {
    case invalidProducerReceipt
    case selectionCaptureMismatch
}

/// Non-Codable producer-authenticated binding for one exact visual selection subject.
///
/// The trusted capture contributes the immutable artifact identity and frame ordinal; `selection`
/// contributes the exact runtime node and source mapping. Candidate `VisualSelectionIdentity`
/// values remain serializable, but only a canonical runtime/Visual Picker adapter inside this
/// module may promote an exact mapping to trusted selection authority.
public struct VisualTrustedSelection: Equatable, Hashable, Sendable {
    public let capture: VisualTrustedCapture
    public let selection: VisualSelectionIdentity
    public let producerReceiptID: String

    init(
        authenticatedCapture: VisualTrustedCapture,
        authenticatedSelection: VisualSelectionIdentity,
        producerReceiptID: String
    ) throws {
        guard authenticatedSelection.isValid(for: authenticatedCapture) else {
            throw VisualSelectionAuthorityError.selectionCaptureMismatch
        }

        let normalizedReceipt = producerReceiptID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedReceipt == producerReceiptID,
              !normalizedReceipt.isEmpty,
              normalizedReceipt.utf8.count <= 512,
              !normalizedReceipt.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw VisualSelectionAuthorityError.invalidProducerReceipt
        }

        self.capture = authenticatedCapture
        self.selection = authenticatedSelection
        self.producerReceiptID = normalizedReceipt
    }
}
