import Foundation

public enum ForgeQualityError: Error, Equatable, Sendable {
    case invalidIdentifier(field: String)
    case invalidRevision(field: String)
    case emptyPolicy
    case tooManyTargets
    case duplicateTarget(metric: ForgeQualityMetric, scope: ForgeQualityScope)
    case invalidThreshold(ForgeQualityMetric)
    case unsupportedComparator(metric: ForgeQualityMetric, comparator: ForgeQualityComparator)
    case invalidMinimumSampleCount
    case invalidMeasurement(ForgeQualityMetric)
    case invalidSampleCount
    case evidenceKindMismatch(metric: ForgeQualityMetric, expected: ForgeQualityEvidenceKind, actual: ForgeQualityEvidenceKind)
    case duplicateMeasurement(metric: ForgeQualityMetric, scope: ForgeQualityScope)
    case duplicateMeasurementID(ForgeQualityID)
    case duplicateProducerReceiptID(ForgeQualityID)
    case unexpectedMeasurement(metric: ForgeQualityMetric, scope: ForgeQualityScope)
    case evidenceBindingMismatch(measurementID: ForgeQualityID)
    case measurementProtocolMismatch(measurementID: ForgeQualityID)
    case completionBindingMismatch
    case unsupportedSchemaVersion(Int)
}

public struct ForgeQualityID: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String, field: String = "id") throws {
        guard Self.isCanonical(rawValue) else {
            throw ForgeQualityError.invalidIdentifier(field: field)
        }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    public static func < (lhs: ForgeQualityID, rhs: ForgeQualityID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private static func isCanonical(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 512 else { return false }
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}

/// Exact producer protocol identity shared by an accepted quality policy and every measurement
/// evaluated against it. A metric name or evidence-kind label alone is not enough to prove that
/// collection semantics are still current after the profiler/audit protocol changes.
public struct ForgeQualityMeasurementProtocolIdentity: Codable, Hashable, Sendable {
    public let protocolID: ForgeQualityID
    public let revision: UInt64

    public init(protocolID: ForgeQualityID, revision: UInt64) throws {
        guard revision > 0 else {
            throw ForgeQualityError.invalidRevision(field: "measurementProtocol.revision")
        }
        self.protocolID = protocolID
        self.revision = revision
    }

    private enum CodingKeys: String, CodingKey {
        case protocolID
        case revision
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            protocolID: container.decode(ForgeQualityID.self, forKey: .protocolID),
            revision: container.decode(UInt64.self, forKey: .revision)
        )
    }
}

public struct ForgeQualityCompletionTarget: Codable, Hashable, Sendable {
    public let missionID: ForgeQualityID
    public let projectID: ForgeQualityID
    public let sourceRevision: ForgeQualityID
    public let constitutionRevision: UInt64
    public let constitutionReceiptID: ForgeQualityID

    public init(
        missionID: ForgeQualityID,
        projectID: ForgeQualityID,
        sourceRevision: ForgeQualityID,
        constitutionRevision: UInt64,
        constitutionReceiptID: ForgeQualityID
    ) throws {
        guard constitutionRevision > 0 else {
            throw ForgeQualityError.invalidRevision(field: "completionTarget.constitutionRevision")
        }
        self.missionID = missionID
        self.projectID = projectID
        self.sourceRevision = sourceRevision
        self.constitutionRevision = constitutionRevision
        self.constitutionReceiptID = constitutionReceiptID
    }

    private enum CodingKeys: String, CodingKey {
        case missionID
        case projectID
        case sourceRevision
        case constitutionRevision
        case constitutionReceiptID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            missionID: container.decode(ForgeQualityID.self, forKey: .missionID),
            projectID: container.decode(ForgeQualityID.self, forKey: .projectID),
            sourceRevision: container.decode(ForgeQualityID.self, forKey: .sourceRevision),
            constitutionRevision: container.decode(UInt64.self, forKey: .constitutionRevision),
            constitutionReceiptID: container.decode(ForgeQualityID.self, forKey: .constitutionReceiptID)
        )
    }
}
