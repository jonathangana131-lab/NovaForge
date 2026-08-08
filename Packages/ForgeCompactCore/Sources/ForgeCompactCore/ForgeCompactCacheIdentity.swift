import Foundation

public struct ForgeCompactCacheIdentity: Codable, Hashable, Sendable {
    public let modelID: String
    public let modelRevision: String
    public let tokenizerRevision: String
    public let runtimeID: String
    public let runtimeRevision: String
    public let promptTemplateRevision: String
    public let toolSchemaRevision: String
    public let projectID: String
    public let sourceRevision: String
    public let capsuleRevision: Int

    public init(
        modelID: String,
        modelRevision: String,
        tokenizerRevision: String,
        runtimeID: String,
        runtimeRevision: String,
        promptTemplateRevision: String,
        toolSchemaRevision: String,
        projectID: String,
        sourceRevision: String,
        capsuleRevision: Int
    ) throws {
        func valid(_ value: String, field: String) throws -> String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  trimmed.utf8.count <= 512,
                  !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else {
                throw ForgeCompactError.invalidCacheIdentity(field: field)
            }
            return trimmed
        }

        self.modelID = try valid(modelID, field: "modelID")
        self.modelRevision = try valid(modelRevision, field: "modelRevision")
        self.tokenizerRevision = try valid(tokenizerRevision, field: "tokenizerRevision")
        self.runtimeID = try valid(runtimeID, field: "runtimeID")
        self.runtimeRevision = try valid(runtimeRevision, field: "runtimeRevision")
        self.promptTemplateRevision = try valid(promptTemplateRevision, field: "promptTemplateRevision")
        self.toolSchemaRevision = try valid(toolSchemaRevision, field: "toolSchemaRevision")
        self.projectID = try valid(projectID, field: "projectID")
        self.sourceRevision = try valid(sourceRevision, field: "sourceRevision")
        guard capsuleRevision >= 0 else {
            throw ForgeCompactError.invalidRevision(field: "capsuleRevision", value: capsuleRevision)
        }
        self.capsuleRevision = capsuleRevision
    }

    public func canReusePrefixOrKV(with other: ForgeCompactCacheIdentity) -> Bool {
        self == other
    }

    private enum CodingKeys: String, CodingKey {
        case modelID, modelRevision, tokenizerRevision, runtimeID, runtimeRevision,
             promptTemplateRevision, toolSchemaRevision, projectID, sourceRevision, capsuleRevision
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            modelID: c.decode(String.self, forKey: .modelID),
            modelRevision: c.decode(String.self, forKey: .modelRevision),
            tokenizerRevision: c.decode(String.self, forKey: .tokenizerRevision),
            runtimeID: c.decode(String.self, forKey: .runtimeID),
            runtimeRevision: c.decode(String.self, forKey: .runtimeRevision),
            promptTemplateRevision: c.decode(String.self, forKey: .promptTemplateRevision),
            toolSchemaRevision: c.decode(String.self, forKey: .toolSchemaRevision),
            projectID: c.decode(String.self, forKey: .projectID),
            sourceRevision: c.decode(String.self, forKey: .sourceRevision),
            capsuleRevision: c.decode(Int.self, forKey: .capsuleRevision)
        )
    }
}
