import CryptoKit
import Foundation

public enum LocalModelArtifactIntegrityProducerError: Error, Equatable, Sendable {
    case artifactNotRegularFile
}

/// One independently measured artifact-integrity result plus its transient host-trust binding.
///
/// The candidate evidence remains persistable through `LocalModelQualificationRecord`. The trusted receipt
/// is intentionally non-Codable and can only be minted inside `LocalModelQualificationCore`, so callers
/// cannot upgrade a persisted/model-shaped artifact claim into qualification authority.
public struct LocalModelArtifactIntegrityVerification: Sendable {
    public let evidence: LocalModelQualificationEvidence
    public let trustedReceipt: LocalModelTrustedEvidenceReceipt

    public var passed: Bool { evidence.status == .passed }

    fileprivate init(
        evidence: LocalModelQualificationEvidence,
        trustedReceipt: LocalModelTrustedEvidenceReceipt
    ) {
        self.evidence = evidence
        self.trustedReceipt = trustedReceipt
    }
}

/// Canonical static producer for exact model-artifact byte integrity.
///
/// This producer proves only that a regular, non-symlink file read by this process had the SHA-256 bound
/// into the exact qualification subject. It does not prove model load, runtime behavior, physical-device
/// execution, performance, memory, thermal behavior, task quality, network locality, or path persistence.
public enum LocalModelArtifactIntegrityProducer {
    private static let readChunkBytes = 4 * 1_024 * 1_024

    public static func verify(
        subject: LocalModelQualificationSubject,
        artifactURL: URL
    ) throws -> LocalModelArtifactIntegrityVerification {
        let values = try artifactURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true else {
            throw LocalModelArtifactIntegrityProducerError.artifactNotRegularFile
        }

        let handle = try FileHandle(forReadingFrom: artifactURL)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: readChunkBytes) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }

        let actualDigest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let status: LocalModelEvidenceStatus = actualDigest == subject.artifact.artifactSHA256
            ? .passed
            : .failed
        let evidence = try LocalModelQualificationEvidence(
            evidenceID: "artifact-integrity-sha256-\(subject.artifact.artifactSHA256)",
            subject: subject,
            evidenceClass: .artifactIntegrity,
            source: .staticAnalysis,
            authority: .deterministicHarness,
            status: status,
            payload: .none
        )
        let trustedReceipt = LocalModelTrustedEvidenceReceipt(
            authenticatedEvidence: evidence
        )
        return .init(evidence: evidence, trustedReceipt: trustedReceipt)
    }
}
