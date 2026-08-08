import Foundation

public enum ForgeCompletionDefectSeverity: Int, Codable, Comparable, Sendable {
    case low = 0
    case medium = 1
    case high = 2
    case critical = 3

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum ForgeCompletionDefectState: String, Codable, Sendable {
    case open
    case deferred
    case resolved
}

public struct ForgeCompletionDefect: Codable, Sendable {
    public let defectID: String
    public let scope: ForgeCompletionScope
    public let severity: ForgeCompletionDefectSeverity
    public let state: ForgeCompletionDefectState
    public let summary: String

    public init(defectID: String, scope: ForgeCompletionScope, severity: ForgeCompletionDefectSeverity, state: ForgeCompletionDefectState, summary: String) throws {
        self.defectID = try validatedCanonicalID(defectID, field: "defectID")
        self.scope = scope
        self.severity = severity
        self.state = state
        self.summary = try validatedNonblank(summary, field: "defect.summary")
    }

    private enum CodingKeys: String, CodingKey { case defectID, scope, severity, state, summary }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            defectID: container.decode(String.self, forKey: .defectID),
            scope: container.decode(ForgeCompletionScope.self, forKey: .scope),
            severity: container.decode(ForgeCompletionDefectSeverity.self, forKey: .severity),
            state: container.decode(ForgeCompletionDefectState.self, forKey: .state),
            summary: container.decode(String.self, forKey: .summary)
        )
    }
}

public struct ForgeCompletionKnownLimitation: Codable, Sendable {
    public let limitationID: String
    public let scope: ForgeCompletionScope
    public let relatedDefectID: String?
    public let summary: String

    public init(limitationID: String, scope: ForgeCompletionScope, relatedDefectID: String? = nil, summary: String) throws {
        self.limitationID = try validatedCanonicalID(limitationID, field: "limitationID")
        self.scope = scope
        if let relatedDefectID {
            self.relatedDefectID = try validatedCanonicalID(relatedDefectID, field: "relatedDefectID")
        } else {
            self.relatedDefectID = nil
        }
        self.summary = try validatedNonblank(summary, field: "limitation.summary")
    }

    private enum CodingKeys: String, CodingKey { case limitationID, scope, relatedDefectID, summary }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            limitationID: container.decode(String.self, forKey: .limitationID),
            scope: container.decode(ForgeCompletionScope.self, forKey: .scope),
            relatedDefectID: container.decodeIfPresent(String.self, forKey: .relatedDefectID),
            summary: container.decode(String.self, forKey: .summary)
        )
    }
}

public struct ForgeCompletionDefectSnapshot: Codable, Sendable {
    public let scope: ForgeCompletionScope
    public let defectAuditReceiptID: String
    public let defects: [ForgeCompletionDefect]
    public let knownLimitations: [ForgeCompletionKnownLimitation]

    public init(
        scope: ForgeCompletionScope,
        defectAuditReceiptID: String,
        defects: [ForgeCompletionDefect],
        knownLimitations: [ForgeCompletionKnownLimitation]
    ) throws {
        self.scope = scope
        self.defectAuditReceiptID = try validatedCanonicalID(defectAuditReceiptID, field: "defectAuditReceiptID")
        var defectIDs = Set<String>()
        for defect in defects {
            guard defect.scope == scope else { throw ForgeCompletionValidationError.invalidLimitationDefectID }
            guard defectIDs.insert(defect.defectID).inserted else {
                throw ForgeCompletionValidationError.duplicateDefectID(defect.defectID)
            }
        }
        var limitationIDs = Set<String>()
        for limitation in knownLimitations {
            guard limitation.scope == scope else { throw ForgeCompletionValidationError.invalidLimitationDefectID }
            guard limitationIDs.insert(limitation.limitationID).inserted else {
                throw ForgeCompletionValidationError.duplicateLimitationID(limitation.limitationID)
            }
        }
        self.defects = defects.sorted { $0.defectID < $1.defectID }
        self.knownLimitations = knownLimitations.sorted { $0.limitationID < $1.limitationID }
    }

    private enum CodingKeys: String, CodingKey { case scope, defectAuditReceiptID, defects, knownLimitations }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            scope: container.decode(ForgeCompletionScope.self, forKey: .scope),
            defectAuditReceiptID: container.decode(String.self, forKey: .defectAuditReceiptID),
            defects: container.decode([ForgeCompletionDefect].self, forKey: .defects),
            knownLimitations: container.decode([ForgeCompletionKnownLimitation].self, forKey: .knownLimitations)
        )
    }
}
