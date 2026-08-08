import Foundation

public struct ProjectCapsuleFact: Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let kind: ProjectCapsuleFactKind
    public let layer: ProjectCapsuleLayer
    public let summary: String
    public let estimatedTokens: Int
    public let relevance: Int
    public let freshness: ProjectCapsuleFreshness
    public let provenance: [ProjectCapsuleProvenance]

    public init(
        id: String,
        kind: ProjectCapsuleFactKind,
        layer: ProjectCapsuleLayer,
        summary: String,
        estimatedTokens: Int,
        relevance: Int,
        freshness: ProjectCapsuleFreshness = .current,
        provenance: [ProjectCapsuleProvenance]
    ) throws {
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else { throw ForgeCompactError.blankFactID }
        let normalizedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSummary.isEmpty else { throw ForgeCompactError.blankFactSummary(id: normalizedID) }
        guard estimatedTokens > 0 else { throw ForgeCompactError.invalidTokenEstimate(id: normalizedID) }
        guard (0...1_000).contains(relevance) else { throw ForgeCompactError.invalidRelevance(id: normalizedID) }
        guard !provenance.isEmpty else { throw ForgeCompactError.missingProvenance(id: normalizedID) }
        for source in provenance where source.stableID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ForgeCompactError.blankProvenanceID(factID: normalizedID)
        }
        if kind.isProtectedTruth, freshness != .current {
            throw ForgeCompactError.staleProtectedTruth(normalizedID)
        }

        self.id = normalizedID
        self.kind = kind
        self.layer = layer
        self.summary = normalizedSummary
        self.estimatedTokens = estimatedTokens
        self.relevance = relevance
        self.freshness = freshness
        self.provenance = provenance.sorted {
            if $0.kind.rawValue != $1.kind.rawValue { return $0.kind.rawValue < $1.kind.rawValue }
            return $0.stableID < $1.stableID
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, layer, summary, estimatedTokens, relevance, freshness, provenance
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(String.self, forKey: .id),
            kind: container.decode(ProjectCapsuleFactKind.self, forKey: .kind),
            layer: container.decode(ProjectCapsuleLayer.self, forKey: .layer),
            summary: container.decode(String.self, forKey: .summary),
            estimatedTokens: container.decode(Int.self, forKey: .estimatedTokens),
            relevance: container.decode(Int.self, forKey: .relevance),
            freshness: container.decode(ProjectCapsuleFreshness.self, forKey: .freshness),
            provenance: container.decode([ProjectCapsuleProvenance].self, forKey: .provenance)
        )
    }
}

public struct ProjectCapsuleBudget: Codable, Equatable, Sendable {
    public let contextWindowTokens: Int
    public let reservedSystemToolTokens: Int
    public let reservedGenerationTokens: Int
    public let maxCapsuleTokens: Int
    public let maxFactCount: Int

    public var availableCapsuleTokens: Int {
        min(maxCapsuleTokens, contextWindowTokens - reservedSystemToolTokens - reservedGenerationTokens)
    }

    public init(
        contextWindowTokens: Int,
        reservedSystemToolTokens: Int,
        reservedGenerationTokens: Int,
        maxCapsuleTokens: Int,
        maxFactCount: Int = 256
    ) throws {
        guard contextWindowTokens > 0,
              reservedSystemToolTokens >= 0,
              reservedGenerationTokens >= 0,
              maxCapsuleTokens > 0,
              maxFactCount > 0,
              reservedSystemToolTokens + reservedGenerationTokens < contextWindowTokens,
              min(maxCapsuleTokens, contextWindowTokens - reservedSystemToolTokens - reservedGenerationTokens) > 0
        else { throw ForgeCompactError.invalidBudget }

        self.contextWindowTokens = contextWindowTokens
        self.reservedSystemToolTokens = reservedSystemToolTokens
        self.reservedGenerationTokens = reservedGenerationTokens
        self.maxCapsuleTokens = maxCapsuleTokens
        self.maxFactCount = maxFactCount
    }

    private enum CodingKeys: String, CodingKey {
        case contextWindowTokens, reservedSystemToolTokens, reservedGenerationTokens, maxCapsuleTokens, maxFactCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            contextWindowTokens: container.decode(Int.self, forKey: .contextWindowTokens),
            reservedSystemToolTokens: container.decode(Int.self, forKey: .reservedSystemToolTokens),
            reservedGenerationTokens: container.decode(Int.self, forKey: .reservedGenerationTokens),
            maxCapsuleTokens: container.decode(Int.self, forKey: .maxCapsuleTokens),
            maxFactCount: container.decode(Int.self, forKey: .maxFactCount)
        )
    }
}
