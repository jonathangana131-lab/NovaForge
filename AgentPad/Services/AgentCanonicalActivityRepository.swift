import AgentDomain
import AgentStore
import Foundation
import SwiftData

enum AgentCanonicalActivityRepositoryError: Error, Equatable, Sendable {
    case scopeTooLarge(maximumEventRecords: Int)
    case invalidRunIdentity(String)
}

/// Loads one exact Forge conversation scope from the canonical journal.
///
/// The repository first discovers run identities from indexed SwiftData
/// columns, then asks `SwiftDataAgentStore` to perform the integrity-checked
/// decode/replay read for each run. UI code therefore never decodes opaque
/// event bytes, trusts a materialized legacy tool row, or treats a project as
/// a wildcard. A nil project means General and matches only nil project rows.
@MainActor
struct AgentCanonicalActivityRepository {
    struct Limits: Equatable, Sendable {
        let maximumEventRecords: Int
        let maximumRuns: Int
        let maximumEventsPerRun: Int

        static let forge = Limits(
            maximumEventRecords: 8_192,
            maximumRuns: 256,
            maximumEventsPerRun: 2_048
        )
    }

    private let container: ModelContainer
    private let limits: Limits

    init(
        container: ModelContainer,
        limits: Limits = .forge
    ) {
        self.container = container
        self.limits = limits
    }

    func groups(
        in scope: AgentActivityProjectionScope
    ) async throws -> [AgentActivityGroup] {
        let context = ModelContext(container)
        context.autosaveEnabled = false

        let conversationID = scope.conversationID.description
        var descriptor = FetchDescriptor<AgentEventRecord>(
            predicate: #Predicate<AgentEventRecord> { record in
                record.conversationIDString == conversationID
            },
            sortBy: [SortDescriptor(\AgentEventRecord.journalOffsetValue)]
        )
        descriptor.fetchLimit = limits.maximumEventRecords + 1
        let indexedRecords = try context.fetch(descriptor)
        guard indexedRecords.count <= limits.maximumEventRecords else {
            throw AgentCanonicalActivityRepositoryError.scopeTooLarge(
                maximumEventRecords: limits.maximumEventRecords
            )
        }

        let expectedProjectID = scope.projectID?.description
        var orderedRunIDs: [RunID] = []
        var seenRunIDs: Set<RunID> = []
        for record in indexedRecords where record.projectIDString == expectedProjectID {
            guard let uuid = UUID(uuidString: record.runIDString) else {
                throw AgentCanonicalActivityRepositoryError.invalidRunIdentity(
                    record.runIDString
                )
            }
            let runID = RunID(rawValue: uuid)
            guard scope.runID == nil || scope.runID == runID else { continue }
            guard seenRunIDs.insert(runID).inserted else { continue }
            orderedRunIDs.append(runID)
            guard orderedRunIDs.count <= limits.maximumRuns else {
                throw AgentCanonicalActivityRepositoryError.scopeTooLarge(
                    maximumEventRecords: limits.maximumEventRecords
                )
            }
        }

        let store = SwiftDataAgentStore(container: container)
        let recordsByRunID = try await store.events(
            forOrderedRunIDs: orderedRunIDs,
            maximumRunCount: limits.maximumRuns
        )
        var events: [AgentEvent] = []
        events.reserveCapacity(indexedRecords.count)
        for runID in orderedRunIDs {
            let stored = recordsByRunID[runID] ?? []
            guard stored.count <= limits.maximumEventsPerRun else {
                throw AgentCanonicalActivityRepositoryError.scopeTooLarge(
                    maximumEventRecords: limits.maximumEventRecords
                )
            }
            events.append(contentsOf: stored.map(\.event))
        }

        return try AgentCanonicalActivityProjector.project(
            orderedEvents: events,
            scope: scope
        )
    }
}
