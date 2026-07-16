import CryptoKit
import Foundation

enum CanonicalShadowDigest {
    static let scheme = "novaforge-shadow-canonical-json-v2"

    enum Domain: String, Codable, CaseIterable, Sendable {
        case ledger = "dark-replay-ledger-v1"
        case state = "dark-replay-state-v1"
        case transcript = "dark-replay-transcript-v1"
        case evidence = "dark-replay-evidence-v1"
        case report = "dark-replay-report-v1"
        case toolContract = "tool-contract-v1"
        case developerCanaryConfiguration = "developer-canary-configuration-v1"
        case developerReadOnlyCanaryConfiguration = "developer-read-only-canary-configuration-v1"
        case developerReadOnlyCanaryInvocation = "developer-read-only-canary-invocation-v1"
        case canonicalFixture = "canonical-fixture-v1"
    }

    static func sha256<Value: Encodable>(
        domain: Domain,
        _ value: Value
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(VersionedDigestMaterial(
            scheme: scheme,
            domain: domain,
            value: value
        ))
        let bytes = SHA256.hash(data: data)
        return "sha256:" + bytes.map { String(format: "%02x", $0) }.joined()
    }
}

private struct VersionedDigestMaterial<Value: Encodable>: Encodable {
    let scheme: String
    let domain: CanonicalShadowDigest.Domain
    let value: Value
}
