import Foundation

public struct ProjectCapsule: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let authority: ProjectCapsuleAuthority
    public let budgetBytes: Int
    public let selectedItems: [ForgeCompactContextItem]
    public let omittedItems: [ForgeCompactOmittedItem]
    public let renderedContext: String
    public let renderedUTF8Bytes: Int
    public let sourceItemCount: Int

    init(
        authority: ProjectCapsuleAuthority,
        budgetBytes: Int,
        selectedItems: [ForgeCompactContextItem],
        omittedItems: [ForgeCompactOmittedItem]
    ) throws {
        self.schemaVersion = Self.currentSchemaVersion
        self.authority = authority
        self.budgetBytes = budgetBytes
        self.selectedItems = selectedItems
        self.omittedItems = omittedItems
        self.renderedContext = selectedItems.map(\.renderedLine).joined(separator: "\n")
        self.renderedUTF8Bytes = renderedContext.utf8.count
        self.sourceItemCount = selectedItems.count + omittedItems.count
        try validate()
    }

    private init(
        schemaVersion: Int,
        authority: ProjectCapsuleAuthority,
        budgetBytes: Int,
        selectedItems: [ForgeCompactContextItem],
        omittedItems: [ForgeCompactOmittedItem],
        renderedContext: String,
        renderedUTF8Bytes: Int,
        sourceItemCount: Int
    ) throws {
        self.schemaVersion = schemaVersion
        self.authority = authority
        self.budgetBytes = budgetBytes
        self.selectedItems = selectedItems
        self.omittedItems = omittedItems
        self.renderedContext = renderedContext
        self.renderedUTF8Bytes = renderedUTF8Bytes
        self.sourceItemCount = sourceItemCount
        try validate()
    }

    private func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ForgeCompactError.invalidCapsuleSchema(schemaVersion)
        }
        guard budgetBytes >= 0, sourceItemCount == selectedItems.count + omittedItems.count else {
            throw ForgeCompactError.invalidCapsuleShape
        }

        var selectedIDs = Set<String>()
        for item in selectedItems {
            guard item.sourceRevision == authority.sourceRevision else {
                throw ForgeCompactError.sourceRevisionMismatch(itemID: item.id)
            }
            guard selectedIDs.insert(item.id).inserted else {
                throw ForgeCompactError.duplicateItemID(item.id)
            }
        }

        var omittedIDs = Set<String>()
        for item in omittedItems {
            guard !item.mustRetain else {
                throw ForgeCompactError.invalidCapsuleShape
            }
            guard omittedIDs.insert(item.id).inserted, !selectedIDs.contains(item.id) else {
                throw ForgeCompactError.invalidCapsuleShape
            }
        }

        guard selectedItems == selectedItems.sorted(by: ProjectCapsuleBuilder.canonicalOrder),
              omittedItems == omittedItems.sorted(by: ProjectCapsuleBuilder.canonicalOrder)
        else {
            throw ForgeCompactError.invalidCapsuleShape
        }

        let recomputed = selectedItems.map(\.renderedLine).joined(separator: "\n")
        guard recomputed == renderedContext,
              recomputed.utf8.count == renderedUTF8Bytes,
              renderedUTF8Bytes <= budgetBytes
        else {
            throw ForgeCompactError.invalidCapsuleShape
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, authority, budgetBytes, selectedItems, omittedItems, renderedContext, renderedUTF8Bytes, sourceItemCount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: c.decode(Int.self, forKey: .schemaVersion),
            authority: c.decode(ProjectCapsuleAuthority.self, forKey: .authority),
            budgetBytes: c.decode(Int.self, forKey: .budgetBytes),
            selectedItems: c.decode([ForgeCompactContextItem].self, forKey: .selectedItems),
            omittedItems: c.decode([ForgeCompactOmittedItem].self, forKey: .omittedItems),
            renderedContext: c.decode(String.self, forKey: .renderedContext),
            renderedUTF8Bytes: c.decode(Int.self, forKey: .renderedUTF8Bytes),
            sourceItemCount: c.decode(Int.self, forKey: .sourceItemCount)
        )
    }
}

public enum ProjectCapsuleBuilder {
    public static func build(
        authority: ProjectCapsuleAuthority,
        items: [ForgeCompactContextItem],
        budgetBytes: Int
    ) throws -> ProjectCapsule {
        guard (0...2_000_000).contains(budgetBytes) else {
            throw ForgeCompactError.invalidBudget(budgetBytes)
        }

        var IDs = Set<String>()
        for item in items {
            guard IDs.insert(item.id).inserted else {
                throw ForgeCompactError.duplicateItemID(item.id)
            }
            guard item.sourceRevision == authority.sourceRevision else {
                throw ForgeCompactError.sourceRevisionMismatch(itemID: item.id)
            }
        }

        let canonical = items.sorted(by: canonicalOrder)
        let mandatory = canonical.filter(\.mustRetain)
        let optional = canonical.filter { !$0.mustRetain }

        let requiredBytes = renderedBytes(for: mandatory)
        guard requiredBytes <= budgetBytes else {
            throw ForgeCompactError.budgetCannotHoldMandatoryTruth(
                requiredBytes: requiredBytes,
                budgetBytes: budgetBytes
            )
        }

        var selected = mandatory
        var omitted: [ForgeCompactContextItem] = []
        var usedBytes = requiredBytes

        for item in optional {
            let separatorBytes = selected.isEmpty ? 0 : 1
            let candidateBytes = separatorBytes + item.renderedUTF8Bytes
            if usedBytes + candidateBytes <= budgetBytes {
                selected.append(item)
                usedBytes += candidateBytes
            } else {
                omitted.append(item)
            }
        }

        selected.sort(by: canonicalOrder)
        omitted.sort(by: canonicalOrder)
        return try ProjectCapsule(
            authority: authority,
            budgetBytes: budgetBytes,
            selectedItems: selected,
            omittedItems: omitted.map(ForgeCompactOmittedItem.init(item:))
        )
    }

    private static func renderedBytes(for items: [ForgeCompactContextItem]) -> Int {
        guard !items.isEmpty else { return 0 }
        return items.reduce(0) { $0 + $1.renderedUTF8Bytes } + (items.count - 1)
    }

    fileprivate static func canonicalOrder(_ lhs: ForgeCompactContextItem, _ rhs: ForgeCompactContextItem) -> Bool {
        if lhs.tier.selectionRank != rhs.tier.selectionRank {
            return lhs.tier.selectionRank < rhs.tier.selectionRank
        }
        if lhs.priority != rhs.priority {
            return lhs.priority > rhs.priority
        }
        return lhs.id < rhs.id
    }

    fileprivate static func canonicalOrder(_ lhs: ForgeCompactOmittedItem, _ rhs: ForgeCompactOmittedItem) -> Bool {
        if lhs.tier.selectionRank != rhs.tier.selectionRank {
            return lhs.tier.selectionRank < rhs.tier.selectionRank
        }
        if lhs.priority != rhs.priority {
            return lhs.priority > rhs.priority
        }
        return lhs.id < rhs.id
    }
}
