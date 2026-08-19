import Foundation

public struct ForgeQualityTarget: Codable, Hashable, Sendable {
    public let metric: ForgeQualityMetric
    public let scope: ForgeQualityScope
    public let comparator: ForgeQualityComparator
    public let threshold: Double
    public let minimumSampleCount: Int
    public let environmentRequirement: ForgeQualityEnvironmentRequirement

    public init(
        metric: ForgeQualityMetric,
        scope: ForgeQualityScope = .run,
        comparator: ForgeQualityComparator,
        threshold: Double,
        minimumSampleCount: Int = 1,
        environmentRequirement: ForgeQualityEnvironmentRequirement = .any
    ) throws {
        guard comparator == metric.requiredComparator else {
            throw ForgeQualityError.unsupportedComparator(metric: metric, comparator: comparator)
        }
        guard metric.acceptsValue(threshold) else {
            throw ForgeQualityError.invalidThreshold(metric)
        }
        guard (1...1_000_000).contains(minimumSampleCount) else {
            throw ForgeQualityError.invalidMinimumSampleCount
        }
        self.metric = metric
        self.scope = scope
        self.comparator = comparator
        self.threshold = threshold
        self.minimumSampleCount = minimumSampleCount
        self.environmentRequirement = environmentRequirement
    }

    internal var key: ForgeQualityTargetKey {
        ForgeQualityTargetKey(metric: metric, scope: scope)
    }

    private enum CodingKeys: String, CodingKey {
        case metric
        case scope
        case comparator
        case threshold
        case minimumSampleCount
        case environmentRequirement
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            metric: container.decode(ForgeQualityMetric.self, forKey: .metric),
            scope: container.decode(ForgeQualityScope.self, forKey: .scope),
            comparator: container.decode(ForgeQualityComparator.self, forKey: .comparator),
            threshold: container.decode(Double.self, forKey: .threshold),
            minimumSampleCount: container.decode(Int.self, forKey: .minimumSampleCount),
            environmentRequirement: container.decode(ForgeQualityEnvironmentRequirement.self, forKey: .environmentRequirement)
        )
    }
}

/// Candidate policy data is durable, but is not accepted authority by itself.
public struct ForgeQualityPolicy: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 2
    public static let maximumTargets = 64

    public let schemaVersion: Int
    public let policyID: ForgeQualityID
    public let policyRevision: UInt64
    public let policyAuthorityReceiptID: ForgeQualityID
    public let criterionID: ForgeQualityID
    public let completionTarget: ForgeQualityCompletionTarget
    public let checkpointID: ForgeQualityID
    public let measurementProtocol: ForgeQualityMeasurementProtocolIdentity
    public let targets: [ForgeQualityTarget]

    public init(
        policyID: ForgeQualityID,
        policyRevision: UInt64,
        policyAuthorityReceiptID: ForgeQualityID,
        criterionID: ForgeQualityID,
        completionTarget: ForgeQualityCompletionTarget,
        checkpointID: ForgeQualityID,
        measurementProtocol: ForgeQualityMeasurementProtocolIdentity,
        targets: [ForgeQualityTarget]
    ) throws {
        guard policyRevision > 0 else {
            throw ForgeQualityError.invalidRevision(field: "policy.policyRevision")
        }
        guard !targets.isEmpty else { throw ForgeQualityError.emptyPolicy }
        guard targets.count <= Self.maximumTargets else { throw ForgeQualityError.tooManyTargets }

        var seen = Set<ForgeQualityTargetKey>()
        for target in targets {
            guard seen.insert(target.key).inserted else {
                throw ForgeQualityError.duplicateTarget(metric: target.metric, scope: target.scope)
            }
        }

        self.schemaVersion = Self.currentSchemaVersion
        self.policyID = policyID
        self.policyRevision = policyRevision
        self.policyAuthorityReceiptID = policyAuthorityReceiptID
        self.criterionID = criterionID
        self.completionTarget = completionTarget
        self.checkpointID = checkpointID
        self.measurementProtocol = measurementProtocol
        self.targets = targets.sorted { lhs, rhs in
            if lhs.scope.sortKey == rhs.scope.sortKey {
                return lhs.metric.rawValue < rhs.metric.rawValue
            }
            return lhs.scope.sortKey < rhs.scope.sortKey
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case policyID
        case policyRevision
        case policyAuthorityReceiptID
        case criterionID
        case completionTarget
        case checkpointID
        case measurementProtocol
        case targets
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ForgeQualityError.unsupportedSchemaVersion(schemaVersion)
        }

        // Decode the untrusted collection incrementally so the public 64-target limit is a
        // real allocation boundary rather than a post-allocation check. Codable archives can be
        // model-shaped or persisted input; an oversized array must fail before materializing it.
        var targetsContainer = try container.nestedUnkeyedContainer(forKey: .targets)
        if let count = targetsContainer.count, count > Self.maximumTargets {
            throw ForgeQualityError.tooManyTargets
        }
        var decodedTargets: [ForgeQualityTarget] = []
        decodedTargets.reserveCapacity(min(targetsContainer.count ?? Self.maximumTargets, Self.maximumTargets))
        while !targetsContainer.isAtEnd {
            // `UnkeyedDecodingContainer.count` is optional. Retain the pre-append guard so custom
            // decoders that cannot report a count still cannot materialize a 65th target.
            guard decodedTargets.count < Self.maximumTargets else {
                throw ForgeQualityError.tooManyTargets
            }
            decodedTargets.append(try targetsContainer.decode(ForgeQualityTarget.self))
        }

        try self.init(
            policyID: container.decode(ForgeQualityID.self, forKey: .policyID),
            policyRevision: container.decode(UInt64.self, forKey: .policyRevision),
            policyAuthorityReceiptID: container.decode(ForgeQualityID.self, forKey: .policyAuthorityReceiptID),
            criterionID: container.decode(ForgeQualityID.self, forKey: .criterionID),
            completionTarget: container.decode(ForgeQualityCompletionTarget.self, forKey: .completionTarget),
            checkpointID: container.decode(ForgeQualityID.self, forKey: .checkpointID),
            measurementProtocol: container.decode(ForgeQualityMeasurementProtocolIdentity.self, forKey: .measurementProtocol),
            targets: decodedTargets
        )
    }
}

/// Host-accepted binding to the complete policy subject. This deliberately cannot be decoded or
/// constructed by ordinary external consumers. A later canonical Mission/Completion adapter inside
/// this module must create it only after authenticating the current policy authority and target.
public struct ForgeQualityTrustedPolicy: Equatable, Sendable {
    private let authenticatedPolicy: ForgeQualityPolicy

    public var policyID: ForgeQualityID { authenticatedPolicy.policyID }
    public var policyRevision: UInt64 { authenticatedPolicy.policyRevision }
    public var policyAuthorityReceiptID: ForgeQualityID { authenticatedPolicy.policyAuthorityReceiptID }
    public var criterionID: ForgeQualityID { authenticatedPolicy.criterionID }
    public var completionTarget: ForgeQualityCompletionTarget { authenticatedPolicy.completionTarget }
    public var checkpointID: ForgeQualityID { authenticatedPolicy.checkpointID }
    public var measurementProtocol: ForgeQualityMeasurementProtocolIdentity { authenticatedPolicy.measurementProtocol }
    public var targets: [ForgeQualityTarget] { authenticatedPolicy.targets }

    init(authenticatedPolicy: ForgeQualityPolicy) {
        self.authenticatedPolicy = authenticatedPolicy
    }

    func exactlyMatches(_ candidate: ForgeQualityPolicy) -> Bool {
        authenticatedPolicy == candidate
    }
}

/// Candidate producer measurement. Structural validation and an evidence-kind label do not prove
/// provenance; quality acceptance separately requires a host-authenticated whole-measurement binding.
