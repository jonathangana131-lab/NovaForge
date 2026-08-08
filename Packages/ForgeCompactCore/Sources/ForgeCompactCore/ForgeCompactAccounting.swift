import Foundation

public enum ForgeCompactAccountingError: Error, Equatable, Sendable {
    case invalidIdentifier(field: String)
    case invalidBasis
    case invalidProvenanceForBasis
    case invalidReceiptShape
    case duplicateSelectedItemID(String)
    case utf8ByteCountMismatch(expected: UInt64, observed: UInt64)
    case counterFailed
}

/// Describes what one context-counting unit actually means.
///
/// An exact tokenizer basis binds tokenizer identity + revision. A heuristic remains explicitly
/// estimated, and UTF-8 bytes remain bytes; neither may be presented as an exact token count.
public struct ForgeCompactAccountingBasis: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case utf8Bytes
        case exactTokenizer
        case heuristic
    }

    public let kind: Kind
    public let counterID: String?
    public let counterRevision: String?

    public static let utf8Bytes = try! ForgeCompactAccountingBasis(kind: .utf8Bytes)

    public static func exactTokenizer(
        tokenizerID: String,
        tokenizerRevision: String
    ) throws -> ForgeCompactAccountingBasis {
        try .init(
            kind: .exactTokenizer,
            counterID: tokenizerID,
            counterRevision: tokenizerRevision
        )
    }

    public static func heuristic(
        estimatorID: String,
        estimatorRevision: String
    ) throws -> ForgeCompactAccountingBasis {
        try .init(
            kind: .heuristic,
            counterID: estimatorID,
            counterRevision: estimatorRevision
        )
    }

    private init(
        kind: Kind,
        counterID: String? = nil,
        counterRevision: String? = nil
    ) throws {
        switch kind {
        case .utf8Bytes:
            guard counterID == nil, counterRevision == nil else {
                throw ForgeCompactAccountingError.invalidBasis
            }
        case .exactTokenizer, .heuristic:
            guard let counterID,
                  let counterRevision,
                  Self.isCanonicalIdentifier(counterID),
                  Self.isCanonicalIdentifier(counterRevision)
            else {
                throw ForgeCompactAccountingError.invalidBasis
            }
        }

        self.kind = kind
        self.counterID = counterID
        self.counterRevision = counterRevision
    }

    public var isExactTokenizer: Bool {
        kind == .exactTokenizer
    }

    private enum CodingKeys: String, CodingKey {
        case kind, counterID, counterRevision
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            kind: c.decode(Kind.self, forKey: .kind),
            counterID: c.decodeIfPresent(String.self, forKey: .counterID),
            counterRevision: c.decodeIfPresent(String.self, forKey: .counterRevision)
        )
    }

    private static func isCanonicalIdentifier(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && trimmed == value
            && trimmed.utf8.count <= 512
            && !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
}

/// Identity of the exact baseline context snapshot being compared with a Project Capsule.
/// The revision is deliberately caller-owned: raw conversation history, a Project Brain snapshot,
/// or another baseline must advance its revision when its content changes.
public struct ForgeCompactAccountingBaselineIdentity: Codable, Equatable, Hashable, Sendable {
    public let contextID: String
    public let contextRevision: String

    public init(contextID: String, contextRevision: String) throws {
        guard Self.isCanonicalIdentifier(contextID) else {
            throw ForgeCompactAccountingError.invalidIdentifier(field: "baseline.contextID")
        }
        guard Self.isCanonicalIdentifier(contextRevision) else {
            throw ForgeCompactAccountingError.invalidIdentifier(field: "baseline.contextRevision")
        }
        self.contextID = contextID
        self.contextRevision = contextRevision
    }

    private enum CodingKeys: String, CodingKey {
        case contextID, contextRevision
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            contextID: c.decode(String.self, forKey: .contextID),
            contextRevision: c.decode(String.self, forKey: .contextRevision)
        )
    }

    private static func isCanonicalIdentifier(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && trimmed == value
            && trimmed.utf8.count <= 512
            && !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
}

/// Where the accounting observation came from. This is provenance, not cryptographic trust.
/// Callers remain responsible for authenticating any external measurement receipt they depend on.
public enum ForgeCompactAccountingProvenance: String, Codable, Hashable, Sendable {
    /// Direct count from the runtime/tokenizer implementation named by the exact tokenizer basis.
    case runtimeTokenizer
    /// Deterministic host-side harness that invokes the exact tokenizer implementation.
    case deterministicHarness
    /// Named estimator. Its results are always estimates, never exact token counts.
    case heuristicEstimator
    /// Model-generated/report-only value. Never eligible for exact accounting truth.
    case modelReported
}

/// Stable semantic class for displaying or consuming a receipt without relabeling its units.
public enum ForgeCompactAccountingTruth: String, Codable, Equatable, Sendable {
    case exactUTF8Bytes
    case exactTokenizerTokens
    case estimatedUnits
    case untrustedReportedUnits
}

public enum ForgeCompactAccountingChange: Equatable, Sendable {
    case reduced(units: UInt64)
    case unchanged
    case increased(units: UInt64)
}

/// A host-supplied counter. The package records its exact identity/provenance and applies
/// structural truth rules, but does not claim that an arbitrary implementation is trustworthy.
public protocol ForgeCompactContextCounter: Sendable {
    var basis: ForgeCompactAccountingBasis { get }
    var provenance: ForgeCompactAccountingProvenance { get }
    var measurementReceiptID: String { get }

    func countUnits(in text: String) throws -> UInt64
}

/// Durable comparison of one named/revisioned baseline snapshot against one rendered Project
/// Capsule using one and only one accounting basis. Byte counts are also carried independently so
/// a token/estimate result can never overwrite the package's exact UTF-8 accounting.
public struct ForgeCompactAccountingReceipt: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let authority: ProjectCapsuleAuthority
    public let selectedItemIDs: [String]
    public let baselineIdentity: ForgeCompactAccountingBaselineIdentity
    public let measurementReceiptID: String
    public let basis: ForgeCompactAccountingBasis
    public let provenance: ForgeCompactAccountingProvenance
    public let baselineUTF8Bytes: UInt64
    public let capsuleUTF8Bytes: UInt64
    public let baselineUnits: UInt64
    public let capsuleUnits: UInt64

    public var truth: ForgeCompactAccountingTruth {
        switch provenance {
        case .modelReported:
            return .untrustedReportedUnits
        case .heuristicEstimator:
            return .estimatedUnits
        case .runtimeTokenizer, .deterministicHarness:
            switch basis.kind {
            case .utf8Bytes:
                return .exactUTF8Bytes
            case .exactTokenizer:
                return .exactTokenizerTokens
            case .heuristic:
                return .estimatedUnits
            }
        }
    }

    /// True only when the receipt structurally represents a direct/deterministic count from the
    /// exact tokenizer identity named by `basis`. Authentication of the external receipt remains
    /// a host responsibility.
    public var hasExactTokenizerProvenance: Bool {
        truth == .exactTokenizerTokens
    }

    public var change: ForgeCompactAccountingChange {
        if capsuleUnits < baselineUnits {
            return .reduced(units: baselineUnits - capsuleUnits)
        }
        if capsuleUnits > baselineUnits {
            return .increased(units: capsuleUnits - baselineUnits)
        }
        return .unchanged
    }

    init(
        authority: ProjectCapsuleAuthority,
        selectedItemIDs: [String],
        baselineIdentity: ForgeCompactAccountingBaselineIdentity,
        measurementReceiptID: String,
        basis: ForgeCompactAccountingBasis,
        provenance: ForgeCompactAccountingProvenance,
        baselineUTF8Bytes: UInt64,
        capsuleUTF8Bytes: UInt64,
        baselineUnits: UInt64,
        capsuleUnits: UInt64
    ) throws {
        self.schemaVersion = Self.currentSchemaVersion
        self.authority = authority
        self.selectedItemIDs = selectedItemIDs
        self.baselineIdentity = baselineIdentity
        self.measurementReceiptID = measurementReceiptID
        self.basis = basis
        self.provenance = provenance
        self.baselineUTF8Bytes = baselineUTF8Bytes
        self.capsuleUTF8Bytes = capsuleUTF8Bytes
        self.baselineUnits = baselineUnits
        self.capsuleUnits = capsuleUnits
        try validate()
    }

    private init(
        schemaVersion: Int,
        authority: ProjectCapsuleAuthority,
        selectedItemIDs: [String],
        baselineIdentity: ForgeCompactAccountingBaselineIdentity,
        measurementReceiptID: String,
        basis: ForgeCompactAccountingBasis,
        provenance: ForgeCompactAccountingProvenance,
        baselineUTF8Bytes: UInt64,
        capsuleUTF8Bytes: UInt64,
        baselineUnits: UInt64,
        capsuleUnits: UInt64
    ) throws {
        self.schemaVersion = schemaVersion
        self.authority = authority
        self.selectedItemIDs = selectedItemIDs
        self.baselineIdentity = baselineIdentity
        self.measurementReceiptID = measurementReceiptID
        self.basis = basis
        self.provenance = provenance
        self.baselineUTF8Bytes = baselineUTF8Bytes
        self.capsuleUTF8Bytes = capsuleUTF8Bytes
        self.baselineUnits = baselineUnits
        self.capsuleUnits = capsuleUnits
        try validate()
    }

    /// Binds this measurement back to the exact capsule authority/selection/byte rendering that
    /// was measured. A persisted receipt is not accepted merely because its IDs look plausible.
    public func matches(capsule: ProjectCapsule) -> Bool {
        authority == capsule.authority
            && selectedItemIDs == capsule.selectedItems.map(\.id)
            && capsuleUTF8Bytes == UInt64(capsule.renderedUTF8Bytes)
    }

    public func matches(baselineIdentity: ForgeCompactAccountingBaselineIdentity) -> Bool {
        self.baselineIdentity == baselineIdentity
    }

    private func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion,
              Self.isCanonicalIdentifier(measurementReceiptID),
              selectedItemIDs.allSatisfy(Self.isCanonicalIdentifier)
        else {
            throw ForgeCompactAccountingError.invalidReceiptShape
        }

        var seen = Set<String>()
        for id in selectedItemIDs where !seen.insert(id).inserted {
            throw ForgeCompactAccountingError.duplicateSelectedItemID(id)
        }

        guard Self.provenanceIsCompatible(provenance, basis: basis) else {
            throw ForgeCompactAccountingError.invalidProvenanceForBasis
        }

        if basis.kind == .utf8Bytes {
            guard baselineUnits == baselineUTF8Bytes else {
                throw ForgeCompactAccountingError.utf8ByteCountMismatch(
                    expected: baselineUTF8Bytes,
                    observed: baselineUnits
                )
            }
            guard capsuleUnits == capsuleUTF8Bytes else {
                throw ForgeCompactAccountingError.utf8ByteCountMismatch(
                    expected: capsuleUTF8Bytes,
                    observed: capsuleUnits
                )
            }
        }
    }

    fileprivate static func provenanceIsCompatible(
        _ provenance: ForgeCompactAccountingProvenance,
        basis: ForgeCompactAccountingBasis
    ) -> Bool {
        switch (basis.kind, provenance) {
        case (.utf8Bytes, .deterministicHarness):
            true
        case (.exactTokenizer, .runtimeTokenizer),
             (.exactTokenizer, .deterministicHarness),
             (.exactTokenizer, .modelReported):
            true
        case (.heuristic, .heuristicEstimator),
             (.heuristic, .modelReported):
            true
        default:
            false
        }
    }

    private static func isCanonicalIdentifier(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && trimmed == value
            && trimmed.utf8.count <= 512
            && !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case authority
        case selectedItemIDs
        case baselineIdentity
        case measurementReceiptID
        case basis
        case provenance
        case baselineUTF8Bytes
        case capsuleUTF8Bytes
        case baselineUnits
        case capsuleUnits
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: c.decode(Int.self, forKey: .schemaVersion),
            authority: c.decode(ProjectCapsuleAuthority.self, forKey: .authority),
            selectedItemIDs: c.decode([String].self, forKey: .selectedItemIDs),
            baselineIdentity: c.decode(ForgeCompactAccountingBaselineIdentity.self, forKey: .baselineIdentity),
            measurementReceiptID: c.decode(String.self, forKey: .measurementReceiptID),
            basis: c.decode(ForgeCompactAccountingBasis.self, forKey: .basis),
            provenance: c.decode(ForgeCompactAccountingProvenance.self, forKey: .provenance),
            baselineUTF8Bytes: c.decode(UInt64.self, forKey: .baselineUTF8Bytes),
            capsuleUTF8Bytes: c.decode(UInt64.self, forKey: .capsuleUTF8Bytes),
            baselineUnits: c.decode(UInt64.self, forKey: .baselineUnits),
            capsuleUnits: c.decode(UInt64.self, forKey: .capsuleUnits)
        )
    }
}

public enum ForgeCompactAccounting {
    /// Measures one named/revisioned baseline and one rendered capsule through the same counter
    /// identity. `counterFailed` deliberately hides counter-specific error types from durable state.
    public static func measure<C: ForgeCompactContextCounter>(
        baselineContext: String,
        baselineIdentity: ForgeCompactAccountingBaselineIdentity,
        capsule: ProjectCapsule,
        counter: C
    ) throws -> ForgeCompactAccountingReceipt {
        guard ForgeCompactAccountingReceipt.provenanceIsCompatible(
            counter.provenance,
            basis: counter.basis
        ) else {
            throw ForgeCompactAccountingError.invalidProvenanceForBasis
        }

        let baselineUnits: UInt64
        let capsuleUnits: UInt64
        do {
            baselineUnits = try counter.countUnits(in: baselineContext)
            capsuleUnits = try counter.countUnits(in: capsule.renderedContext)
        } catch {
            throw ForgeCompactAccountingError.counterFailed
        }

        let baselineUTF8Bytes = UInt64(baselineContext.utf8.count)
        let capsuleUTF8Bytes = UInt64(capsule.renderedContext.utf8.count)

        return try ForgeCompactAccountingReceipt(
            authority: capsule.authority,
            selectedItemIDs: capsule.selectedItems.map(\.id),
            baselineIdentity: baselineIdentity,
            measurementReceiptID: counter.measurementReceiptID,
            basis: counter.basis,
            provenance: counter.provenance,
            baselineUTF8Bytes: baselineUTF8Bytes,
            capsuleUTF8Bytes: capsuleUTF8Bytes,
            baselineUnits: baselineUnits,
            capsuleUnits: capsuleUnits
        )
    }

    /// Exact byte accounting that never passes through a tokenizer/estimator and therefore cannot
    /// accidentally be presented as tokens.
    public static func measureUTF8Bytes(
        baselineContext: String,
        baselineIdentity: ForgeCompactAccountingBaselineIdentity,
        capsule: ProjectCapsule,
        measurementReceiptID: String
    ) throws -> ForgeCompactAccountingReceipt {
        let baselineBytes = UInt64(baselineContext.utf8.count)
        let capsuleBytes = UInt64(capsule.renderedContext.utf8.count)
        return try ForgeCompactAccountingReceipt(
            authority: capsule.authority,
            selectedItemIDs: capsule.selectedItems.map(\.id),
            baselineIdentity: baselineIdentity,
            measurementReceiptID: measurementReceiptID,
            basis: .utf8Bytes,
            provenance: .deterministicHarness,
            baselineUTF8Bytes: baselineBytes,
            capsuleUTF8Bytes: capsuleBytes,
            baselineUnits: baselineBytes,
            capsuleUnits: capsuleBytes
        )
    }
}
