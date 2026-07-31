import CryptoKit
import Foundation

/// A canonical identity for one physical workspace root. Only the hash-derived
/// resource key and deterministic UUID escape this initializer; the raw root
/// path is never retained in a request or persisted receipt.
struct WorkspaceResourceIdentity: Equatable, Hashable, Sendable {
    let resourceKey: String
    let persistentID: UUID

    init(workspace: SandboxWorkspace) throws {
        let resolvedRoot = try workspace.resolve("")
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let canonicalRoot = resolvedRoot.path.precomposedStringWithCanonicalMapping
        let digest = Array(SHA256.hash(data: Data(canonicalRoot.utf8)))
        let digestHex = digest.map { String(format: "%02x", $0) }.joined()
        resourceKey = "workspace:sha256:\(digestHex)"

        // RFC 9562 UUIDv8 is reserved for application-defined hashes. Set the
        // version and RFC variant bits explicitly so the persisted scalar is a
        // valid, deterministic UUID rather than a raw truncated digest.
        var uuidBytes = Array(digest.prefix(16))
        uuidBytes[6] = (uuidBytes[6] & 0x0f) | 0x80
        uuidBytes[8] = (uuidBytes[8] & 0x3f) | 0x80
        persistentID = UUID(uuid: (
            uuidBytes[0], uuidBytes[1], uuidBytes[2], uuidBytes[3],
            uuidBytes[4], uuidBytes[5], uuidBytes[6], uuidBytes[7],
            uuidBytes[8], uuidBytes[9], uuidBytes[10], uuidBytes[11],
            uuidBytes[12], uuidBytes[13], uuidBytes[14], uuidBytes[15]
        ))
    }
}
