import Foundation

public enum ForgeDesignValidationError: Error, Equatable, Sendable {
    case blankIdentifier(String)
    case blankText(String)
    case identifierTooLong(String, Int)
    case textTooLong(String, Int)
    case invalidControlCharacter(String)
    case invalidRevision(Int)
    case revisionOverflow
    case invalidTimestamp(String)
    case duplicateRuleID(DesignRuleID)
    case duplicateProtectedComponentID(ProtectedDesignComponentID)
    case duplicateNeverRuleID(NeverRuleID)
    case tooManyIntentTraits(Int)
    case tooManyRules(Int)
    case tooManyProtectedComponents(Int)
    case tooManyNeverRules(Int)
    case duplicateIntentTrait(String)
    case provenanceCannotProtectRule(DesignRuleID)
    case provenanceCannotProtectComponent(ProtectedDesignComponentID)
    case protectedRuleMutationRequiresUserAuthority(DesignRuleID)
    case protectedComponentMutationRequiresUserAuthority(ProtectedDesignComponentID)
    case neverRuleRequiresUserDecision(NeverRuleID)
    case userAuthorityRequired(String)
    case authenticatedUserAuthorityRequired(String)
    case projectIdentityMismatch
    case revisionMustAdvance
    case archiveTooLarge(Int)
    case invalidArchiveTransition(String)
    case unsupportedSchemaVersion(Int)
}

public enum ForgeDesignLimits {
    public static let maximumIdentifierUTF8Bytes = 192
    public static let maximumProductPromiseUTF8Bytes = 2_048
    public static let maximumTextUTF8Bytes = 4_096
    public static let maximumTraitUTF8Bytes = 256
    public static let maximumRules = 256
    public static let maximumProtectedComponents = 128
    public static let maximumNeverRules = 128
    public static let maximumArchiveSnapshots = 512
}

public protocol ForgeDesignOpaqueID: RawRepresentable, Codable, Hashable, Sendable where RawValue == String {
    init(rawValue: String)
}

func canonicalString(_ value: String) -> String {
    value.precomposedStringWithCanonicalMapping
}

func containsDisallowedControl(_ value: String, allowLineBreaks: Bool) -> Bool {
    value.unicodeScalars.contains { scalar in
        guard CharacterSet.controlCharacters.contains(scalar) else { return false }
        if allowLineBreaks && (scalar.value == 0x09 || scalar.value == 0x0A) { return false }
        return true
    }
}

func validatedIdentifier<T: ForgeDesignOpaqueID>(_ value: T, field: String) throws -> T {
    let trimmed = canonicalString(value.rawValue.trimmingCharacters(in: .whitespacesAndNewlines))
    guard !trimmed.isEmpty else { throw ForgeDesignValidationError.blankIdentifier(field) }
    guard trimmed.utf8.count <= ForgeDesignLimits.maximumIdentifierUTF8Bytes else {
        throw ForgeDesignValidationError.identifierTooLong(field, trimmed.utf8.count)
    }
    guard !trimmed.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) else {
        throw ForgeDesignValidationError.invalidControlCharacter(field)
    }
    return T(rawValue: trimmed)
}

func validatedText(
    _ value: String,
    field: String,
    maximumUTF8Bytes: Int = ForgeDesignLimits.maximumTextUTF8Bytes,
    allowLineBreaks: Bool = true
) throws -> String {
    let trimmed = canonicalString(value.trimmingCharacters(in: .whitespacesAndNewlines))
    guard !trimmed.isEmpty else { throw ForgeDesignValidationError.blankText(field) }
    guard trimmed.utf8.count <= maximumUTF8Bytes else {
        throw ForgeDesignValidationError.textTooLong(field, trimmed.utf8.count)
    }
    guard !containsDisallowedControl(trimmed, allowLineBreaks: allowLineBreaks) else {
        throw ForgeDesignValidationError.invalidControlCharacter(field)
    }
    return trimmed
}

func validatedDate(_ value: Date, field: String) throws -> Date {
    guard value.timeIntervalSinceReferenceDate.isFinite else {
        throw ForgeDesignValidationError.invalidTimestamp(field)
    }
    return value
}

public struct DesignProjectID: ForgeDesignOpaqueID { public let rawValue: String; public init(rawValue: String) { self.rawValue = rawValue } }
public struct DesignRuleID: ForgeDesignOpaqueID { public let rawValue: String; public init(rawValue: String) { self.rawValue = rawValue } }
public struct ProtectedDesignComponentID: ForgeDesignOpaqueID { public let rawValue: String; public init(rawValue: String) { self.rawValue = rawValue } }
public struct NeverRuleID: ForgeDesignOpaqueID { public let rawValue: String; public init(rawValue: String) { self.rawValue = rawValue } }
public struct DesignReceiptID: ForgeDesignOpaqueID { public let rawValue: String; public init(rawValue: String) { self.rawValue = rawValue } }

public enum DesignProvenanceKind: String, Codable, CaseIterable, Sendable {
    case userDecision, acceptedSourceCheckpoint, acceptedRuntimeCapture, importedReference, modelSuggestion
    public var isUserAuthority: Bool { self == .userDecision }
    public var mayProtectAcceptedDesign: Bool {
        switch self {
        case .userDecision, .acceptedSourceCheckpoint, .acceptedRuntimeCapture: true
        case .importedReference, .modelSuggestion: false
        }
    }
}

public struct DesignProvenance: Codable, Equatable, Hashable, Sendable {
    public let kind: DesignProvenanceKind
    public let receiptID: DesignReceiptID
    public let recordedAt: Date
    public init(kind: DesignProvenanceKind, receiptID: DesignReceiptID, recordedAt: Date) throws {
        self.kind = kind
        self.receiptID = try validatedIdentifier(receiptID, field: "provenance.receiptID")
        self.recordedAt = try validatedDate(recordedAt, field: "provenance.recordedAt")
    }
}
