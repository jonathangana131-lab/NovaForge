import Foundation

public enum VisualAnalysisAuthorityError: Error, Equatable, Sendable {
    case invalidAnalyzerReceipt
    case tooManyObservations(maximum: Int)
    case duplicateObservationCriterion(FirstMinuteCriterion)
    case observationCaptureMismatch(FirstMinuteCriterion)
    case tooManyFindings(maximum: Int)
    case duplicateFindingID(UUID)
    case findingCaptureMismatch(UUID)
    case invalidImprovementScore
}

/// Non-Codable producer-authenticated visual-analysis authority for one exact trusted capture.
///
/// `FirstMinuteObservation`, `VisualFinding`, and improvement scores remain caller/model-shaped
/// candidate metadata on their own. They become acceptance-authoritative only after a canonical
/// analyzer/harness adapter inside this module authenticates the complete analysis subject and
/// constructs this binding. Holding a genuine screenshot artifact is deliberately insufficient.
public struct VisualTrustedAnalysis: Equatable, Sendable, Identifiable {
    public static let maximumFindings = 512

    public let capture: VisualTrustedCapture
    public let observations: [FirstMinuteObservation]
    public let findings: [VisualFinding]
    public let improvementScore: Double
    public let analyzerReceiptID: String

    public var id: String { analyzerReceiptID }

    init(
        authenticatedCapture: VisualTrustedCapture,
        observations: [FirstMinuteObservation],
        findings: [VisualFinding],
        improvementScore: Double,
        analyzerReceiptID: String
    ) throws {
        let normalizedReceipt = analyzerReceiptID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedReceipt == analyzerReceiptID,
              !normalizedReceipt.isEmpty,
              normalizedReceipt.utf8.count <= 512,
              !normalizedReceipt.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw VisualAnalysisAuthorityError.invalidAnalyzerReceipt
        }
        guard observations.count <= FirstMinuteCriterion.allCases.count else {
            throw VisualAnalysisAuthorityError.tooManyObservations(
                maximum: FirstMinuteCriterion.allCases.count
            )
        }

        let visualCriteria: Set<FirstMinuteCriterion> = [
            .purposeIsClear,
            .primaryActionIsDiscoverable,
            .projectFeelsAlive,
            .noBlockingVisualDefect,
            .touchTargetsAreUsable,
            .safeAreasAreRespected,
            .textIsReadable,
        ]
        var observedCriteria = Set<FirstMinuteCriterion>()
        for observation in observations {
            guard observedCriteria.insert(observation.criterion).inserted else {
                throw VisualAnalysisAuthorityError.duplicateObservationCriterion(observation.criterion)
            }
            if visualCriteria.contains(observation.criterion) {
                guard observation.captureID == authenticatedCapture.id else {
                    throw VisualAnalysisAuthorityError.observationCaptureMismatch(observation.criterion)
                }
            } else if let captureID = observation.captureID, captureID != authenticatedCapture.id {
                throw VisualAnalysisAuthorityError.observationCaptureMismatch(observation.criterion)
            }
        }

        guard findings.count <= Self.maximumFindings else {
            throw VisualAnalysisAuthorityError.tooManyFindings(maximum: Self.maximumFindings)
        }
        var findingIDs = Set<UUID>()
        for finding in findings {
            guard findingIDs.insert(finding.id).inserted else {
                throw VisualAnalysisAuthorityError.duplicateFindingID(finding.id)
            }
            guard finding.captureID == authenticatedCapture.id else {
                throw VisualAnalysisAuthorityError.findingCaptureMismatch(finding.id)
            }
        }

        guard improvementScore.isFinite, (0...1).contains(improvementScore) else {
            throw VisualAnalysisAuthorityError.invalidImprovementScore
        }

        self.capture = authenticatedCapture
        self.observations = observations.sorted { $0.criterion.rawValue < $1.criterion.rawValue }
        self.findings = findings.sorted { lhs, rhs in
            if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
            if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        self.improvementScore = improvementScore
        self.analyzerReceiptID = normalizedReceipt
    }
}
