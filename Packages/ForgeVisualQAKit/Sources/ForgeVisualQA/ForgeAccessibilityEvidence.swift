import Foundation

public enum VisualAccessibilityCheckKind: String, Codable, CaseIterable, Sendable {
    case voiceOverTraversal
    case focusReachability
    case dynamicTypeLayout
    case reduceMotionBehavior
    case reduceTransparencyBehavior
    case increaseContrastBehavior
    case differentiateWithoutColor
    case minimumTouchTarget
    case textContrast

    public func accepts(source: VisualAccessibilityObservationSource) -> Bool {
        switch self {
        case .voiceOverTraversal, .focusReachability:
            return source == .accessibilityTree || source == .runtimeInteraction
        case .dynamicTypeLayout, .reduceMotionBehavior, .reduceTransparencyBehavior,
             .increaseContrastBehavior, .differentiateWithoutColor:
            return source == .systemPreferenceExercise || source == .runtimeInteraction
        case .minimumTouchTarget:
            return source == .measuredGeometry || source == .accessibilityTree
        case .textContrast:
            return source == .screenshotMeasurement || source == .measuredGeometry
        }
    }
}

public enum VisualAccessibilityObservationSource: String, Codable, CaseIterable, Sendable {
    case accessibilityTree
    case runtimeInteraction
    case measuredGeometry
    case screenshotMeasurement
    case systemPreferenceExercise
    case modelAssertion

    public var isConcreteRuntimeEvidence: Bool { self != .modelAssertion }
}

public struct VisualAccessibilityObservation: Codable, Equatable, Hashable, Sendable {
    public let check: VisualAccessibilityCheckKind
    public let passed: Bool
    public let source: VisualAccessibilityObservationSource

    public init(
        check: VisualAccessibilityCheckKind,
        passed: Bool,
        source: VisualAccessibilityObservationSource
    ) throws {
        guard source.isConcreteRuntimeEvidence, check.accepts(source: source) else {
            throw VisualAcceptanceEvidenceError.invalidAccessibilityObservation
        }
        self.check = check
        self.passed = passed
        self.source = source
    }

    private enum CodingKeys: String, CodingKey { case check, passed, source }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            check: values.decode(VisualAccessibilityCheckKind.self, forKey: .check),
            passed: values.decode(Bool.self, forKey: .passed),
            source: values.decode(VisualAccessibilityObservationSource.self, forKey: .source)
        )
    }
}

public struct VisualAccessibilityReceipt: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let capture: VisualCaptureReceipt
    public let environment: VisualExecutionEnvironmentIdentity
    public let observations: [VisualAccessibilityObservation]

    public init(
        id: UUID = UUID(),
        capture: VisualCaptureReceipt,
        environment: VisualExecutionEnvironmentIdentity,
        observations: [VisualAccessibilityObservation]
    ) throws {
        guard Self.validRuntimeCapture(capture) else {
            throw VisualAcceptanceEvidenceError.invalidRuntimeCapture
        }
        guard !observations.isEmpty, observations.count <= VisualAccessibilityCheckKind.allCases.count else {
            throw VisualAcceptanceEvidenceError.invalidAccessibilityObservation
        }
        guard observations.allSatisfy({ $0.source.isConcreteRuntimeEvidence }) else {
            throw VisualAcceptanceEvidenceError.invalidAccessibilityObservation
        }
        let checks = Set(observations.map(\.check))
        guard checks.count == observations.count else {
            throw VisualAcceptanceEvidenceError.duplicateAccessibilityCheck
        }
        self.id = id
        self.capture = capture
        self.environment = environment
        self.observations = observations.sorted { $0.check.rawValue < $1.check.rawValue }
    }

    static func validRuntimeCapture(_ capture: VisualCaptureReceipt) -> Bool {
        capture.isRuntimeVisualProof && capture.project.isValid &&
            !capture.runtimeSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            capture.viewport.isValid && capture.accessibility.isValid
    }

    private enum CodingKeys: String, CodingKey { case id, capture, environment, observations }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: values.decode(UUID.self, forKey: .id),
            capture: values.decode(VisualCaptureReceipt.self, forKey: .capture),
            environment: values.decode(VisualExecutionEnvironmentIdentity.self, forKey: .environment),
            observations: values.decode([VisualAccessibilityObservation].self, forKey: .observations)
        )
    }
}

public struct VisualAccessibilityAcceptancePolicy: Codable, Equatable, Sendable {
    public let requiredChecks: Set<VisualAccessibilityCheckKind>
    public let requiresPhysicalDevice: Bool

    public init(
        requiredChecks: Set<VisualAccessibilityCheckKind>,
        requiresPhysicalDevice: Bool = false
    ) throws {
        guard !requiredChecks.isEmpty else { throw VisualAcceptanceEvidenceError.invalidAccessibilityPolicy }
        self.requiredChecks = requiredChecks
        self.requiresPhysicalDevice = requiresPhysicalDevice
    }

    private enum CodingKeys: String, CodingKey { case requiredChecks, requiresPhysicalDevice }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            requiredChecks: values.decode(Set<VisualAccessibilityCheckKind>.self, forKey: .requiredChecks),
            requiresPhysicalDevice: values.decode(Bool.self, forKey: .requiresPhysicalDevice)
        )
    }
}

public enum VisualAccessibilityAcceptanceBlocker: Equatable, Sendable {
    case physicalDeviceRequired
    case missingChecks([VisualAccessibilityCheckKind])
    case failedChecks([VisualAccessibilityCheckKind])
}

public enum VisualAccessibilityAcceptanceVerdict: Equatable, Sendable {
    case accepted(receiptID: UUID)
    case blocked([VisualAccessibilityAcceptanceBlocker])
}

public enum VisualAccessibilityEvidenceEvaluator {
    public static func evaluate(
        receipt: VisualAccessibilityReceipt,
        policy: VisualAccessibilityAcceptancePolicy
    ) -> VisualAccessibilityAcceptanceVerdict {
        var blockers: [VisualAccessibilityAcceptanceBlocker] = []
        if policy.requiresPhysicalDevice && receipt.environment.kind != .physicalDevice {
            blockers.append(.physicalDeviceRequired)
        }
        let byCheck = Dictionary(uniqueKeysWithValues: receipt.observations.map { ($0.check, $0) })
        let missing = policy.requiredChecks.filter { byCheck[$0] == nil }.sorted { $0.rawValue < $1.rawValue }
        if !missing.isEmpty { blockers.append(.missingChecks(missing)) }
        let failed = policy.requiredChecks.compactMap { check -> VisualAccessibilityCheckKind? in
            guard let observation = byCheck[check], !observation.passed else { return nil }
            return check
        }.sorted { $0.rawValue < $1.rawValue }
        if !failed.isEmpty { blockers.append(.failedChecks(failed)) }
        return blockers.isEmpty ? .accepted(receiptID: receipt.id) : .blocked(blockers)
    }
}
