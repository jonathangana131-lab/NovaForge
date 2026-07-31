import AgentDomain
import AgentStore
import Foundation
import SwiftData
import XCTest
@testable import NovaForge

@MainActor
final class AgentCanonicalActivityRepositoryTests: XCTestCase {
    func testConversationAndProjectScopeAreExactAndGeneralIsNotWildcard() async throws {
        let container = try makeContainer()
        let generalConversationID = ConversationID(rawValue: uuid(10))
        let projectAConversationID = ConversationID(rawValue: uuid(13))
        let projectBConversationID = ConversationID(rawValue: uuid(14))
        let projectA = ProjectID(rawValue: uuid(11))
        let projectB = ProjectID(rawValue: uuid(12))
        let store = NovaForge.SwiftDataAgentStore(container: container)

        let general = fixture(
            seed: 100,
            conversationID: generalConversationID,
            projectID: nil
        )
        let first = fixture(
            seed: 200,
            conversationID: projectAConversationID,
            projectID: projectA
        )
        let second = fixture(
            seed: 300,
            conversationID: projectBConversationID,
            projectID: projectB
        )
        try await accept(general, using: store, in: container)
        try await accept(first, using: store, in: container)
        try await accept(second, using: store, in: container)

        let repository = NovaForge.AgentCanonicalActivityRepository(container: container)
        let generalGroups = try await repository.groups(in: NovaForge.AgentActivityProjectionScope(
            projectID: nil,
            conversationID: generalConversationID
        ))
        let firstGroups = try await repository.groups(in: NovaForge.AgentActivityProjectionScope(
            projectID: projectA,
            conversationID: projectAConversationID
        ))
        let secondGroups = try await repository.groups(in: NovaForge.AgentActivityProjectionScope(
            projectID: projectB,
            conversationID: projectBConversationID
        ))
        let generalAsProject = try await repository.groups(in: NovaForge.AgentActivityProjectionScope(
            projectID: projectA,
            conversationID: generalConversationID
        ))
        let firstAsGeneral = try await repository.groups(in: NovaForge.AgentActivityProjectionScope(
            projectID: nil,
            conversationID: projectAConversationID
        ))
        let firstAsOtherProject = try await repository.groups(in: NovaForge.AgentActivityProjectionScope(
            projectID: projectB,
            conversationID: projectAConversationID
        ))

        XCTAssertEqual(generalGroups.map(\.id), [general.runID])
        XCTAssertEqual(firstGroups.map(\.id), [first.runID])
        XCTAssertEqual(secondGroups.map(\.id), [second.runID])
        XCTAssertTrue(generalAsProject.isEmpty)
        XCTAssertTrue(firstAsGeneral.isEmpty)
        XCTAssertTrue(firstAsOtherProject.isEmpty)
    }

    func testExplicitRunScopeCannotBorrowAnotherRun() async throws {
        let container = try makeContainer()
        let conversationID = ConversationID(rawValue: uuid(20))
        let projectID = ProjectID(rawValue: uuid(21))
        let first = fixture(seed: 400, conversationID: conversationID, projectID: projectID)
        let second = fixture(seed: 500, conversationID: conversationID, projectID: projectID)
        let store = NovaForge.SwiftDataAgentStore(container: container)
        try await accept(first, using: store, in: container)
        try await accept(second, using: store, in: container)

        let groups = try await NovaForge.AgentCanonicalActivityRepository(
            container: container
        ).groups(in: NovaForge.AgentActivityProjectionScope(
            projectID: projectID,
            conversationID: conversationID,
            runID: second.runID
        ))

        XCTAssertEqual(groups.map(\.id), [second.runID])
    }

    func testOversizedScopeFailsClosedInsteadOfReturningPartialActivity() async throws {
        let container = try makeContainer()
        let conversationID = ConversationID(rawValue: uuid(30))
        let projectID = ProjectID(rawValue: uuid(31))
        let store = NovaForge.SwiftDataAgentStore(container: container)
        let first = fixture(
            seed: 600,
            conversationID: conversationID,
            projectID: projectID
        )
        let second = fixture(
            seed: 700,
            conversationID: conversationID,
            projectID: projectID
        )
        try await accept(first, using: store, in: container)
        try await accept(second, using: store, in: container)

        do {
            _ = try await NovaForge.AgentCanonicalActivityRepository(
                container: container,
                limits: .init(
                    maximumEventRecords: 1,
                    maximumRuns: 1,
                    maximumEventsPerRun: 1
                )
            ).groups(in: NovaForge.AgentActivityProjectionScope(
                projectID: projectID,
                conversationID: conversationID
            ))
            XCTFail("Oversized scope unexpectedly returned a partial projection")
        } catch let error as NovaForge.AgentCanonicalActivityRepositoryError {
            XCTAssertEqual(error, .scopeTooLarge(maximumEventRecords: 1))
        }
    }

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Schema(versionedSchema: NovaForge.NovaForgeSchemaV4.self),
            migrationPlan: NovaForge.NovaForgeSchemaMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
    }

    private func fixture(
        seed: UInt64,
        conversationID: ConversationID,
        projectID: ProjectID?
    ) -> Fixture {
        let runID = RunID(rawValue: uuid(seed + 1))
        let acceptedAt = AgentInstant(rawValue: 1_800_000_000_000 + Int64(seed))
        let requestText = "Scoped request"
        let context = AgentRunContext(
            schemaVersion: .current,
            lineage: .root(runID),
            conversationID: conversationID,
            projectID: projectID,
            workspaceID: WorkspaceID(rawValue: uuid(seed + 2)),
            executionNodeID: ExecutionNodeID(rawValue: uuid(seed + 3)),
            engineVersion: .agentHarnessV2,
            acceptedAt: acceptedAt,
            features: AgentFeatureSet(["v2HostedText"]),
            cancellation: CancellationLineage(
                scopeID: CancellationScopeID(rawValue: uuid(seed + 4))
            ),
            initialBudget: AgentBudget(limits: .standard)
        )
        let eventID = EventID(rawValue: uuid(seed + 5))
        let item = ModelItem(
            id: ModelItemID(rawValue: uuid(seed + 6)),
            createdAt: acceptedAt,
            payload: .message(ModelMessage(
                role: .user,
                content: [.text(requestText)]
            ))
        )
        let event = AgentEvent(
            header: AgentEventHeader(
                eventID: eventID,
                context: context,
                sequence: .first,
                timestamp: acceptedAt,
                causationID: nil,
                correlationID: CorrelationID(rawValue: uuid(seed + 7))
            ),
            payload: .runAccepted(RunAcceptedEvent(
                context: context,
                initialItems: [item]
            ))
        )
        let writerID = AgentEventWriterID(runID: runID)
        let envelope = AgentEventEnvelope(
            writerID: writerID,
            writerSequence: .first,
            idempotencyKey: "accept-\(seed)",
            event: event
        )
        let acceptance = AgentRunAcceptance(
            metadata: AgentStore.AgentRunMetadataRecord(
                context: context,
                writerID: writerID,
                acceptanceCommandID: CommandID(rawValue: uuid(seed + 8)),
                acceptanceEventID: eventID
            ),
            envelope: envelope
        )
        let legacyProjection = NovaForge.SwiftDataLegacyAcceptanceProjection(
            runID: runID.rawValue,
            conversationID: conversationID.rawValue,
            projectID: projectID?.rawValue,
            workspaceID: context.workspaceID.rawValue,
            workspaceName: "Repository Workspace",
            requestMessageID: uuid(seed + 9),
            requestText: requestText
        )
        return Fixture(
            runID: runID,
            acceptance: acceptance,
            legacyProjection: legacyProjection
        )
    }

    private func accept(
        _ fixture: Fixture,
        using store: NovaForge.SwiftDataAgentStore,
        in container: ModelContainer
    ) async throws {
        try seedLegacyContext(for: fixture, in: container)
        _ = try await store.accept(
            fixture.acceptance,
            legacyProjection: fixture.legacyProjection
        )
    }

    private func seedLegacyContext(
        for fixture: Fixture,
        in container: ModelContainer
    ) throws {
        let context = ModelContext(container)
        let projectedProjectID = fixture.legacyProjection.projectID
        let project: NovaForge.Project?
        if let projectedProjectID {
            var projectDescriptor = FetchDescriptor<NovaForge.Project>(
                predicate: #Predicate { project in
                    project.id == projectedProjectID
                }
            )
            projectDescriptor.fetchLimit = 1
            if let existing = try context.fetch(projectDescriptor).first {
                project = existing
            } else {
                let inserted = NovaForge.Project(
                    name: "Repository scope",
                    workspaceName: fixture.legacyProjection.workspaceName
                )
                inserted.id = projectedProjectID
                context.insert(inserted)
                project = inserted
            }
        } else {
            project = nil
        }

        let projectedConversationID = fixture.legacyProjection.conversationID
        var conversationDescriptor = FetchDescriptor<NovaForge.Conversation>(
            predicate: #Predicate { conversation in
                conversation.id == projectedConversationID
            }
        )
        conversationDescriptor.fetchLimit = 1
        if let existing = try context.fetch(conversationDescriptor).first {
            XCTAssertEqual(existing.project?.id, projectedProjectID)
            return
        }

        let conversation = NovaForge.Conversation(
            title: "Canonical activity repository",
            project: project
        )
        conversation.id = projectedConversationID
        context.insert(conversation)
        try context.save()
    }

    private func uuid(_ value: UInt64) -> UUID {
        let suffix = String(format: "%012llx", value)
        return UUID(uuidString: "00000000-0000-4000-8000-\(suffix)")!
    }
}

private struct Fixture {
    let runID: RunID
    let acceptance: AgentRunAcceptance
    let legacyProjection: NovaForge.SwiftDataLegacyAcceptanceProjection
}
