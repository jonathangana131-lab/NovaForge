import Foundation

/// Exact identity for prefix/KV reuse. Reuse is allowed only when the stable prefix bytes and
/// every runtime memory-profile dimension are identical. This is a compatibility boundary, not
/// proof that the current runtime actually supports reusable KV state.
public struct ForgeCompactCacheIdentity: Codable, Hashable, Sendable {
    public let modelID: String
    public let modelRevision: String
    public let tokenizerID: String
    public let tokenizerRevision: String
    public let runtimeID: String
    public let runtimeRevision: String
    public let backendProfileID: String
    public let weightProfileID: String
    public let keyCacheType: String
    public let valueCacheType: String
    public let contextCapacityTokens: UInt64
    public let promptTemplateRevision: String
    public let toolSchemaRevision: String
    public let projectID: String
    public let sourceRevision: String
    public let missionRevision: Int
    public let authorityEpoch: Int
    public let capsuleRevision: Int
    public let stablePrefixSHA256: String

    public init(
        modelID: String,
        modelRevision: String,
        tokenizerID: String,
        tokenizerRevision: String,
        runtimeID: String,
        runtimeRevision: String,
        backendProfileID: String,
        weightProfileID: String,
        keyCacheType: String,
        valueCacheType: String,
        contextCapacityTokens: UInt64,
        promptTemplateRevision: String,
        toolSchemaRevision: String,
        projectID: String,
        sourceRevision: String,
        missionRevision: Int,
        authorityEpoch: Int,
        capsuleRevision: Int,
        stablePrefixSHA256: String
    ) throws {
        guard contextCapacityTokens > 0 else {
            throw ForgeCompactError.invalidCacheIdentity(field: "contextCapacityTokens")
        }
        guard missionRevision >= 0 else {
            throw ForgeCompactError.invalidRevision(field: "missionRevision", value: missionRevision)
        }
        guard authorityEpoch >= 0 else {
            throw ForgeCompactError.invalidRevision(field: "authorityEpoch", value: authorityEpoch)
        }
        guard capsuleRevision >= 0 else {
            throw ForgeCompactError.invalidRevision(field: "capsuleRevision", value: capsuleRevision)
        }

        self.modelID = try Self.canonicalIdentifier(modelID, field: "modelID")
        self.modelRevision = try Self.canonicalIdentifier(modelRevision, field: "modelRevision")
        self.tokenizerID = try Self.canonicalIdentifier(tokenizerID, field: "tokenizerID")
        self.tokenizerRevision = try Self.canonicalIdentifier(tokenizerRevision, field: "tokenizerRevision")
        self.runtimeID = try Self.canonicalIdentifier(runtimeID, field: "runtimeID")
        self.runtimeRevision = try Self.canonicalIdentifier(runtimeRevision, field: "runtimeRevision")
        self.backendProfileID = try Self.canonicalIdentifier(backendProfileID, field: "backendProfileID")
        self.weightProfileID = try Self.canonicalIdentifier(weightProfileID, field: "weightProfileID")
        self.keyCacheType = try Self.canonicalIdentifier(keyCacheType, field: "keyCacheType")
        self.valueCacheType = try Self.canonicalIdentifier(valueCacheType, field: "valueCacheType")
        self.contextCapacityTokens = contextCapacityTokens
        self.promptTemplateRevision = try Self.canonicalIdentifier(promptTemplateRevision, field: "promptTemplateRevision")
        self.toolSchemaRevision = try Self.canonicalIdentifier(toolSchemaRevision, field: "toolSchemaRevision")
        self.projectID = try Self.canonicalIdentifier(projectID, field: "projectID")
        self.sourceRevision = try Self.canonicalIdentifier(sourceRevision, field: "sourceRevision")
        self.missionRevision = missionRevision
        self.authorityEpoch = authorityEpoch
        self.capsuleRevision = capsuleRevision
        self.stablePrefixSHA256 = try Self.canonicalSHA256(stablePrefixSHA256, field: "stablePrefixSHA256")
    }

    /// Exact equality is deliberately strict. Any identity, memory-profile, capsule-authority, or
    /// stable-prefix-byte drift invalidates reuse.
    public func canReusePrefixOrKV(with other: ForgeCompactCacheIdentity) -> Bool {
        self == other
    }

    private enum CodingKeys: String, CodingKey {
        case modelID, modelRevision, tokenizerID, tokenizerRevision
        case runtimeID, runtimeRevision, backendProfileID, weightProfileID
        case keyCacheType, valueCacheType, contextCapacityTokens
        case promptTemplateRevision, toolSchemaRevision
        case projectID, sourceRevision, missionRevision, authorityEpoch, capsuleRevision
        case stablePrefixSHA256
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            modelID: c.decode(String.self, forKey: .modelID),
            modelRevision: c.decode(String.self, forKey: .modelRevision),
            tokenizerID: c.decode(String.self, forKey: .tokenizerID),
            tokenizerRevision: c.decode(String.self, forKey: .tokenizerRevision),
            runtimeID: c.decode(String.self, forKey: .runtimeID),
            runtimeRevision: c.decode(String.self, forKey: .runtimeRevision),
            backendProfileID: c.decode(String.self, forKey: .backendProfileID),
            weightProfileID: c.decode(String.self, forKey: .weightProfileID),
            keyCacheType: c.decode(String.self, forKey: .keyCacheType),
            valueCacheType: c.decode(String.self, forKey: .valueCacheType),
            contextCapacityTokens: c.decode(UInt64.self, forKey: .contextCapacityTokens),
            promptTemplateRevision: c.decode(String.self, forKey: .promptTemplateRevision),
            toolSchemaRevision: c.decode(String.self, forKey: .toolSchemaRevision),
            projectID: c.decode(String.self, forKey: .projectID),
            sourceRevision: c.decode(String.self, forKey: .sourceRevision),
            missionRevision: c.decode(Int.self, forKey: .missionRevision),
            authorityEpoch: c.decode(Int.self, forKey: .authorityEpoch),
            capsuleRevision: c.decode(Int.self, forKey: .capsuleRevision),
            stablePrefixSHA256: c.decode(String.self, forKey: .stablePrefixSHA256)
        )
    }

    private static func canonicalIdentifier(_ raw: String, field: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed == raw,
              trimmed.utf8.count <= 512,
              !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            throw ForgeCompactError.invalidCacheIdentity(field: field)
        }
        return raw
    }

    private static func canonicalSHA256(_ value: String, field: String) throws -> String {
        guard value.count == 64,
              value.unicodeScalars.allSatisfy({ scalar in
                  switch scalar.value {
                  case 48...57, 97...102:
                      true
                  default:
                      false
                  }
              })
        else {
            throw ForgeCompactError.invalidCacheIdentity(field: field)
        }
        return value
    }
}
