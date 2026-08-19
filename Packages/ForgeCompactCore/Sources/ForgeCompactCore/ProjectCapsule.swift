import Foundation

public struct ProjectCapsule: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1
    /// Conservative outer envelope for one compaction selection pass. This is a safety cap,
    /// not a recommended working-set size or a device-performance claim.
    public static let maximumSourceItems = 4_096

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
        let sourceItemCount = try Self.checkedSourceItemCount(
            selectedCount: selectedItems.count,
            omittedCount: omittedItems.count
        )

        self.schemaVersion = Self.currentSchemaVersion
        self.authority = authority
        self.budgetBytes = budgetBytes
        self.selectedItems = selectedItems
        self.omittedItems = omittedItems
        self.renderedContext = ProjectCapsuleRenderer.renderedContext(for: selectedItems)
        self.renderedUTF8Bytes = renderedContext.utf8.count
        self.sourceItemCount = sourceItemCount
        try validate()
    }

    static func checkedSourceItemCount(selectedCount: Int, omittedCount: Int) throws -> Int {
        guard selectedCount >= 0, omittedCount >= 0 else {
            throw ForgeCompactError.collectionTooLarge(
                field: "capsule.sourceItems",
                maximum: Self.maximumSourceItems
            )
        }
        let (sourceItemCount, overflow) = selectedCount.addingReportingOverflow(omittedCount)
        guard !overflow else {
            throw ForgeCompactError.collectionTooLarge(
                field: "capsule.sourceItems",
                maximum: Self.maximumSourceItems
            )
        }
        try ForgeCompactValidation.maximumCount(
            sourceItemCount,
            field: "capsule.sourceItems",
            maximum: Self.maximumSourceItems
        )
        return sourceItemCount
    }

    private func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ForgeCompactError.invalidCapsuleSchema(schemaVersion)
        }
        let validatedSourceItemCount = try Self.checkedSourceItemCount(
            selectedCount: selectedItems.count,
            omittedCount: omittedItems.count
        )
        guard budgetBytes >= 0, sourceItemCount == validatedSourceItemCount else {
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
            guard item.sourceRevision == authority.sourceRevision else {
                throw ForgeCompactError.sourceRevisionMismatch(itemID: item.id)
            }
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

        let recomputed = ProjectCapsuleRenderer.renderedContext(for: selectedItems)
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
        let schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        let authority = try c.decode(ProjectCapsuleAuthority.self, forKey: .authority)
        let budgetBytes = try c.decode(Int.self, forKey: .budgetBytes)

        var selectedContainer = try c.nestedUnkeyedContainer(forKey: .selectedItems)
        if let count = selectedContainer.count {
            try ForgeCompactValidation.maximumCount(
                count,
                field: "capsule.sourceItems",
                maximum: Self.maximumSourceItems
            )
        }
        var selectedItems: [ForgeCompactContextItem] = []
        selectedItems.reserveCapacity(min(selectedContainer.count ?? 0, Self.maximumSourceItems))
        while !selectedContainer.isAtEnd {
            guard selectedItems.count < Self.maximumSourceItems else {
                throw ForgeCompactError.collectionTooLarge(
                    field: "capsule.sourceItems",
                    maximum: Self.maximumSourceItems
                )
            }
            selectedItems.append(try selectedContainer.decode(ForgeCompactContextItem.self))
        }

        var omittedContainer = try c.nestedUnkeyedContainer(forKey: .omittedItems)
        if let omittedCount = omittedContainer.count {
            _ = try Self.checkedSourceItemCount(
                selectedCount: selectedItems.count,
                omittedCount: omittedCount
            )
        }
        var omittedItems: [ForgeCompactOmittedItem] = []
        omittedItems.reserveCapacity(
            min(
                omittedContainer.count ?? 0,
                Self.maximumSourceItems - selectedItems.count
            )
        )
        while !omittedContainer.isAtEnd {
            _ = try Self.checkedSourceItemCount(
                selectedCount: selectedItems.count,
                omittedCount: omittedItems.count + 1
            )
            omittedItems.append(try omittedContainer.decode(ForgeCompactOmittedItem.self))
        }

        let storedRenderedContext = try c.decode(String.self, forKey: .renderedContext)
        let storedRenderedUTF8Bytes = try c.decode(Int.self, forKey: .renderedUTF8Bytes)
        let storedSourceItemCount = try c.decode(Int.self, forKey: .sourceItemCount)

        guard schemaVersion == Self.currentSchemaVersion else {
            throw ForgeCompactError.invalidCapsuleSchema(schemaVersion)
        }
        let validatedSourceItemCount = try Self.checkedSourceItemCount(
            selectedCount: selectedItems.count,
            omittedCount: omittedItems.count
        )
        guard storedSourceItemCount == validatedSourceItemCount else {
            throw ForgeCompactError.invalidCapsuleShape
        }

        let canonicalRenderedContext = ProjectCapsuleRenderer.renderedContext(for: selectedItems)
        let legacyRenderedContext = ProjectCapsuleRenderer.legacyRenderedContext(for: selectedItems)
        let storedRenderingIsKnown =
            (storedRenderedContext == canonicalRenderedContext
                && storedRenderedUTF8Bytes == canonicalRenderedContext.utf8.count)
            || (storedRenderedContext == legacyRenderedContext
                && storedRenderedUTF8Bytes == legacyRenderedContext.utf8.count)
        guard storedRenderingIsKnown else {
            throw ForgeCompactError.invalidCapsuleShape
        }

        try self.init(
            authority: authority,
            budgetBytes: budgetBytes,
            selectedItems: selectedItems,
            omittedItems: omittedItems
        )
    }
}

enum ProjectCapsuleRenderer {
    static func renderedContext(for items: [ForgeCompactContextItem]) -> String {
        items.map(renderedLine).joined(separator: "\n")
    }

    static func renderedLine(for item: ForgeCompactContextItem) -> String {
        let authority = item.isAuthoritative ? "truth" : "advisory"
        let freshnessLabel = item.freshness == .current ? "current" : "stale"
        return "[\(item.tier.renderLabel)][\(item.kind.rawValue)][\(authority)][\(freshnessLabel)][\(item.id)] \(escapedContent(item.content))"
    }

    static func renderedUTF8Bytes(for item: ForgeCompactContextItem) -> Int {
        renderedLine(for: item).utf8.count
    }

    static func legacyRenderedContext(for items: [ForgeCompactContextItem]) -> String {
        items.map(\.renderedLine).joined(separator: "\n")
    }

    private static func escapedContent(_ content: String) -> String {
        var result = String()
        result.reserveCapacity(content.utf8.count)

        for scalar in content.unicodeScalars {
            switch scalar.value {
            case 0x5C:
                result.append("\\\\")
            case 0x0A:
                result.append("\\n")
            case 0x0D:
                result.append("\\r")
            case 0x09:
                result.append("\\t")
            case 0x80...0x9F, 0x2028, 0x2029:
                result.append("\\u{")
                result.append(String(scalar.value, radix: 16, uppercase: true))
                result.append("}")
            case 0x01...0x08, 0x0B...0x0C, 0x0E...0x1F, 0x7F:
                result.append("\\u{")
                result.append(String(scalar.value, radix: 16, uppercase: true))
                result.append("}")
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result
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
        try ForgeCompactValidation.maximumCount(
            items.count,
            field: "capsule.sourceItems",
            maximum: ProjectCapsule.maximumSourceItems
        )

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
            let candidateBytes = separatorBytes + ProjectCapsuleRenderer.renderedUTF8Bytes(for: item)
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
        return items.reduce(0) { $0 + ProjectCapsuleRenderer.renderedUTF8Bytes(for: $1) } + (items.count - 1)
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
