import Foundation

public struct VisualProjectIdentity: Codable, Equatable, Hashable, Sendable {
    public let projectID: String
    public let sourceRevision: String

    public init(projectID: String, sourceRevision: String) {
        self.projectID = projectID
        self.sourceRevision = sourceRevision
    }

    public var isValid: Bool {
        !projectID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !sourceRevision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public enum VisualOrientation: String, Codable, CaseIterable, Sendable {
    case portrait
    case landscape
}

public struct VisualInsets: Codable, Equatable, Hashable, Sendable {
    public let top: Double
    public let leading: Double
    public let bottom: Double
    public let trailing: Double

    public init(top: Double, leading: Double, bottom: Double, trailing: Double) {
        self.top = top
        self.leading = leading
        self.bottom = bottom
        self.trailing = trailing
    }

    public var isValid: Bool {
        [top, leading, bottom, trailing].allSatisfy { $0.isFinite && $0 >= 0 }
    }
}

public struct VisualViewport: Codable, Equatable, Hashable, Sendable {
    public let width: Double
    public let height: Double
    public let scale: Double
    public let orientation: VisualOrientation
    public let safeArea: VisualInsets

    public init(
        width: Double,
        height: Double,
        scale: Double,
        orientation: VisualOrientation,
        safeArea: VisualInsets
    ) {
        self.width = width
        self.height = height
        self.scale = scale
        self.orientation = orientation
        self.safeArea = safeArea
    }

    public var isValid: Bool {
        width.isFinite && height.isFinite && scale.isFinite &&
            width > 0 && height > 0 && scale > 0 && safeArea.isValid
    }
}

public struct VisualAccessibilityState: Codable, Equatable, Hashable, Sendable {
    public let reduceMotion: Bool
    public let reduceTransparency: Bool
    public let increaseContrast: Bool
    public let differentiateWithoutColor: Bool
    public let dynamicTypeCategory: String

    public init(
        reduceMotion: Bool,
        reduceTransparency: Bool,
        increaseContrast: Bool,
        differentiateWithoutColor: Bool,
        dynamicTypeCategory: String
    ) {
        self.reduceMotion = reduceMotion
        self.reduceTransparency = reduceTransparency
        self.increaseContrast = increaseContrast
        self.differentiateWithoutColor = differentiateWithoutColor
        self.dynamicTypeCategory = dynamicTypeCategory
    }

    public var isValid: Bool {
        !dynamicTypeCategory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public enum VisualEvidenceKind: String, Codable, CaseIterable, Sendable {
    case runtimeScreenshot
    case runtimeFrameSequence
    case sourceInspection

    /// Structural claim carried by candidate metadata. This is not producer authentication.
    public var claimsRuntimeVisualEvidence: Bool {
        self == .runtimeScreenshot || self == .runtimeFrameSequence
    }
}

/// Codable candidate metadata describing a visual capture.
///
/// `evidenceKind` is caller-provided metadata and does not prove that screenshot/frame artifacts
/// exist. Evidence-authoritative APIs in this package therefore consume `VisualTrustedCapture`
/// instead of this candidate value directly.
public struct VisualCaptureReceipt: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let project: VisualProjectIdentity
    public let runtimeSessionID: String
    public let frameOrdinal: UInt64
    public let viewport: VisualViewport
    public let accessibility: VisualAccessibilityState
    public let evidenceKind: VisualEvidenceKind
    public let capturedAt: Date

    public init(
        id: UUID = UUID(),
        project: VisualProjectIdentity,
        runtimeSessionID: String,
        frameOrdinal: UInt64,
        viewport: VisualViewport,
        accessibility: VisualAccessibilityState,
        evidenceKind: VisualEvidenceKind,
        capturedAt: Date
    ) throws {
        guard project.isValid else { throw VisualQAInvariantError.invalidProjectIdentity }
        guard !runtimeSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VisualQAInvariantError.invalidRuntimeSession
        }
        guard viewport.isValid else { throw VisualQAInvariantError.invalidViewport }
        guard accessibility.isValid else { throw VisualQAInvariantError.invalidAccessibilityState }
        self.id = id
        self.project = project
        self.runtimeSessionID = runtimeSessionID
        self.frameOrdinal = frameOrdinal
        self.viewport = viewport
        self.accessibility = accessibility
        self.evidenceKind = evidenceKind
        self.capturedAt = capturedAt
    }

    public var claimsRuntimeVisualEvidence: Bool { evidenceKind.claimsRuntimeVisualEvidence }
}

/// Non-Codable host-accepted binding between complete capture metadata and an immutable artifact.
///
/// Construction is module-internal on purpose. Candidate/model-authored `VisualCaptureReceipt`
/// bytes cannot mint trusted visual proof merely by declaring `.runtimeScreenshot` or
/// `.runtimeFrameSequence`. A future canonical host capture adapter inside this module must create
/// this value only after authenticating the runtime producer and SHA-256 artifact identity.
public struct VisualTrustedCapture: Equatable, Hashable, Sendable, Identifiable {
    public let capture: VisualCaptureReceipt
    public let artifactSHA256: String

    public var id: UUID { capture.id }
    public var project: VisualProjectIdentity { capture.project }
    public var runtimeSessionID: String { capture.runtimeSessionID }
    public var frameOrdinal: UInt64 { capture.frameOrdinal }
    public var viewport: VisualViewport { capture.viewport }
    public var accessibility: VisualAccessibilityState { capture.accessibility }
    public var evidenceKind: VisualEvidenceKind { capture.evidenceKind }
    public var capturedAt: Date { capture.capturedAt }

    init(authenticatedCapture: VisualCaptureReceipt, artifactSHA256: String) throws {
        guard authenticatedCapture.project.isValid else {
            throw VisualQAInvariantError.invalidProjectIdentity
        }
        guard !authenticatedCapture.runtimeSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VisualQAInvariantError.invalidRuntimeSession
        }
        guard authenticatedCapture.viewport.isValid else {
            throw VisualQAInvariantError.invalidViewport
        }
        guard authenticatedCapture.accessibility.isValid else {
            throw VisualQAInvariantError.invalidAccessibilityState
        }
        guard authenticatedCapture.claimsRuntimeVisualEvidence else {
            throw VisualQAInvariantError.nonRuntimeCaptureCannotBeTrusted
        }
        guard Self.isCanonicalSHA256(artifactSHA256) else {
            throw VisualQAInvariantError.invalidArtifactDigest
        }
        self.capture = authenticatedCapture
        self.artifactSHA256 = artifactSHA256
    }

    private static func isCanonicalSHA256(_ value: String) -> Bool {
        guard value.utf8.count == 64 else { return false }
        return value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }
}

public enum VisualQAInvariantError: Error, Equatable, Sendable {
    case invalidProjectIdentity
    case invalidRuntimeSession
    case invalidViewport
    case invalidAccessibilityState
    case invalidSourceLocation
    case invalidRuntimeNode
    case invalidArtifactDigest
    case nonRuntimeCaptureCannotBeTrusted
}

public enum VisualComparisonMismatch: String, Codable, Equatable, Sendable {
    case insufficientVisualEvidence
    case differentProject
    case differentEvidenceKind
    case differentViewport
    case differentAccessibilityState
}

public enum VisualComparisonDecision: Equatable, Sendable {
    case comparable
    case notComparable(VisualComparisonMismatch)
}

public enum VisualRegressionComparator {
    public static func compare(
        baseline: VisualTrustedCapture,
        candidate: VisualTrustedCapture
    ) -> VisualComparisonDecision {
        guard baseline.project.projectID == candidate.project.projectID else {
            return .notComparable(.differentProject)
        }
        guard baseline.evidenceKind == candidate.evidenceKind else {
            return .notComparable(.differentEvidenceKind)
        }
        guard baseline.viewport == candidate.viewport else {
            return .notComparable(.differentViewport)
        }
        guard baseline.accessibility == candidate.accessibility else {
            return .notComparable(.differentAccessibilityState)
        }
        return .comparable
    }
}

public enum VisualFindingSeverity: Int, Codable, CaseIterable, Comparable, Sendable {
    case cosmetic = 0
    case minor = 1
    case major = 2
    case blocker = 3

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum VisualFindingKind: String, Codable, CaseIterable, Sendable {
    case runtimeCrash
    case primaryFunctionMissing
    case orientationFailure
    case safeAreaViolation
    case clipping
    case overlap
    case tinyTouchTarget
    case unreadableContrast
    case unreadableTypography
    case brokenResponsiveLayout
    case missingLoadingState
    case missingErrorState
    case missingEmptyState
    case browserDefaultResidue
    case awkwardSpacing
    case motionDefect
    case cosmeticPolish

    public var requiresFunctionalRepairBeforePolish: Bool {
        self == .runtimeCrash || self == .primaryFunctionMissing
    }

    fileprivate var priority: Int {
        switch self {
        case .runtimeCrash: 100
        case .primaryFunctionMissing: 95
        case .orientationFailure: 90
        case .safeAreaViolation: 85
        case .clipping: 80
        case .overlap: 75
        case .tinyTouchTarget: 70
        case .unreadableContrast: 65
        case .unreadableTypography: 60
        case .brokenResponsiveLayout: 55
        case .missingLoadingState, .missingErrorState, .missingEmptyState: 50
        case .browserDefaultResidue: 40
        case .awkwardSpacing: 30
        case .motionDefect: 20
        case .cosmeticPolish: 10
        }
    }
}

public struct VisualFinding: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let kind: VisualFindingKind
    public let severity: VisualFindingSeverity
    public let summary: String
    public let captureID: UUID?

    public init(
        id: UUID = UUID(),
        kind: VisualFindingKind,
        severity: VisualFindingSeverity,
        summary: String,
        captureID: UUID?
    ) {
        self.id = id
        self.kind = kind
        self.severity = severity
        self.summary = summary
        self.captureID = captureID
    }

    public var hasRuntimeVisualEvidence: Bool { captureID != nil }
}

public enum FirstMinuteCriterion: String, Codable, CaseIterable, Sendable {
    case purposeIsClear
    case primaryActionIsDiscoverable
    case projectFeelsAlive
    case noRuntimeCrash
    case noBlockingVisualDefect
    case touchTargetsAreUsable
    case safeAreasAreRespected
    case textIsReadable
}

public struct FirstMinuteObservation: Codable, Equatable, Hashable, Sendable {
    public let criterion: FirstMinuteCriterion
    public let passed: Bool
    public let captureID: UUID?

    public init(criterion: FirstMinuteCriterion, passed: Bool, captureID: UUID?) {
        self.criterion = criterion
        self.passed = passed
        self.captureID = captureID
    }
}

/// First-minute acceptance derived only from producer-authenticated visual analysis.
/// The analysis binding is non-Codable, so authority must be reacquired after relaunch.
public struct FirstMinuteAssessment: Equatable, Sendable {
    public let analysis: VisualTrustedAnalysis

    public var capture: VisualTrustedCapture { analysis.capture }
    public var observations: [FirstMinuteObservation] { analysis.observations }

    public init(acceptedAnalysis: VisualTrustedAnalysis) {
        self.analysis = acceptedAnalysis
    }

    public var missingCriteria: [FirstMinuteCriterion] {
        let observed = Set(observations.map(\.criterion))
        return FirstMinuteCriterion.allCases.filter { !observed.contains($0) }
    }

    public var failedCriteria: [FirstMinuteCriterion] {
        observations.filter { !$0.passed }.map(\.criterion)
    }

    public var hasRuntimeVisualEvidenceForVisualCriteria: Bool {
        let visualCriteria: Set<FirstMinuteCriterion> = [
            .purposeIsClear,
            .primaryActionIsDiscoverable,
            .projectFeelsAlive,
            .noBlockingVisualDefect,
            .touchTargetsAreUsable,
            .safeAreasAreRespected,
            .textIsReadable,
        ]
        return observations
            .filter { visualCriteria.contains($0.criterion) }
            .allSatisfy { $0.captureID == capture.id }
    }

    public var passes: Bool {
        missingCriteria.isEmpty &&
            failedCriteria.isEmpty &&
            hasRuntimeVisualEvidenceForVisualCriteria
    }
}

public struct VisualSourceLocation: Codable, Equatable, Hashable, Sendable {
    public let path: String
    public let symbol: String?

    public init(path: String, symbol: String? = nil) {
        self.path = path
        self.symbol = symbol
    }

    public var isValid: Bool {
        !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public enum VisualSelectionKind: String, Codable, CaseIterable, Sendable {
    case domElement
    case sceneEntity
    case hudElement
}

public struct VisualSelectionIdentity: Codable, Equatable, Hashable, Sendable {
    public let kind: VisualSelectionKind
    public let project: VisualProjectIdentity
    public let runtimeSessionID: String
    public let runtimeNodeID: String
    public let source: VisualSourceLocation

    public init(
        kind: VisualSelectionKind,
        project: VisualProjectIdentity,
        runtimeSessionID: String,
        runtimeNodeID: String,
        source: VisualSourceLocation
    ) throws {
        guard project.isValid else { throw VisualQAInvariantError.invalidProjectIdentity }
        guard !runtimeSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VisualQAInvariantError.invalidRuntimeSession
        }
        guard !runtimeNodeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VisualQAInvariantError.invalidRuntimeNode
        }
        guard source.isValid else { throw VisualQAInvariantError.invalidSourceLocation }
        self.kind = kind
        self.project = project
        self.runtimeSessionID = runtimeSessionID
        self.runtimeNodeID = runtimeNodeID
        self.source = source
    }

    /// Structural promotion check for the canonical in-module Visual Picker adapter.
    /// This is intentionally internal: candidate selection metadata is not public trust evidence.
    func isValid(for capture: VisualTrustedCapture) -> Bool {
        project.isValid &&
            !runtimeSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !runtimeNodeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            source.isValid &&
            capture.project == project &&
            capture.runtimeSessionID == runtimeSessionID
    }
}

public struct AutoPolishPolicy: Codable, Equatable, Sendable {
    public let maximumPasses: Int
    public let plateauWindow: Int
    public let minimumMeaningfulImprovement: Double

    public init(
        maximumPasses: Int = 8,
        plateauWindow: Int = 2,
        minimumMeaningfulImprovement: Double = 0.05
    ) {
        self.maximumPasses = max(1, maximumPasses)
        self.plateauWindow = max(1, plateauWindow)
        self.minimumMeaningfulImprovement = max(0, minimumMeaningfulImprovement)
    }
}

/// One visual-polish pass over producer-authenticated analysis of a trusted runtime capture.
/// Non-Codable so accepted analysis authority cannot be restored from candidate bytes.
public struct AutoPolishPass: Equatable, Sendable {
    public let analysis: VisualTrustedAnalysis

    public var capture: VisualTrustedCapture { analysis.capture }
    public var findings: [VisualFinding] { analysis.findings }
    public var improvementScore: Double { analysis.improvementScore }

    public init(acceptedAnalysis: VisualTrustedAnalysis) {
        self.analysis = acceptedAnalysis
    }
}

public enum AutoPolishStopReason: Equatable, Sendable {
    case acceptancePassed
    case userPaused
    case dependencyBlocked
    case maximumPassesReached
    case improvementPlateau
    case insufficientVisualEvidence
}

public enum AutoPolishDecision: Equatable, Sendable {
    case repairFunctionalBlocker(VisualFinding)
    case fixVisualFinding(VisualFinding)
    case stop(AutoPolishStopReason)
}

public enum AutoPolishPlanner {
    public static func decide(
        passes: [AutoPolishPass],
        policy: AutoPolishPolicy = AutoPolishPolicy(),
        userPaused: Bool = false,
        dependencyBlocked: Bool = false
    ) -> AutoPolishDecision {
        if userPaused { return .stop(.userPaused) }
        if dependencyBlocked { return .stop(.dependencyBlocked) }
        guard let latest = passes.last else { return .stop(.insufficientVisualEvidence) }
        guard passes.dropLast().allSatisfy({ prior in
            VisualRegressionComparator.compare(baseline: prior.capture, candidate: latest.capture) == .comparable
        }) else {
            return .stop(.insufficientVisualEvidence)
        }

        let evidencedFindings = latest.findings.filter { $0.captureID == latest.capture.id }
        if !latest.findings.isEmpty && evidencedFindings.isEmpty {
            return .stop(.insufficientVisualEvidence)
        }
        if let blocker = bestFinding(
            in: evidencedFindings.filter { $0.kind.requiresFunctionalRepairBeforePolish }
        ) {
            return .repairFunctionalBlocker(blocker)
        }

        if evidencedFindings.isEmpty { return .stop(.acceptancePassed) }
        if passes.count >= policy.maximumPasses { return .stop(.maximumPassesReached) }

        if passes.count >= policy.plateauWindow {
            let tail = passes.suffix(policy.plateauWindow)
            if tail.allSatisfy({ $0.improvementScore < policy.minimumMeaningfulImprovement }) {
                return .stop(.improvementPlateau)
            }
        }

        guard let finding = bestFinding(in: evidencedFindings) else {
            return .stop(.insufficientVisualEvidence)
        }
        return .fixVisualFinding(finding)
    }

    private static func bestFinding(in findings: [VisualFinding]) -> VisualFinding? {
        findings.sorted { lhs, rhs in
            if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
            if lhs.kind.priority != rhs.kind.priority { return lhs.kind.priority > rhs.kind.priority }
            return lhs.id.uuidString < rhs.id.uuidString
        }.first
    }
}
