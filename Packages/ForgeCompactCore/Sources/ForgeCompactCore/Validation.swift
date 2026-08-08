import Foundation

public enum ForgeCompactValidationError: Error, Equatable, Sendable {
    case blankField(String)
    case oversizedField(String)
    case invalidContextTokens
    case invalidMetric(String)
    case duplicateReference(String)
    case missingRequiredReference(ForgeCompactCapsuleReference.Kind)
    case capsuleBudgetExceeded
    case invalidQualification(String)
}

func validatedText(_ value: String, field: String, maximumLength: Int = 256) throws -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw ForgeCompactValidationError.blankField(field) }
    guard trimmed.count <= maximumLength else { throw ForgeCompactValidationError.oversizedField(field) }
    return trimmed
}
