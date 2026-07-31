import AgentDomain
import AgentStore
import Foundation
import SwiftData
import XCTest

@MainActor
final class AgentStoreMigrationTests: XCTestCase {
    func testV2V3AndV4AreAdditiveCompanionSchemas() {
        let v1Names = Set(NovaForgeSchemaV1.models.map { String(describing: $0) })
        let v2Names = Set(NovaForgeSchemaV2.models.map { String(describing: $0) })
        let v3Names = Set(NovaForgeSchemaV3.models.map { String(describing: $0) })
        let v4Names = Set(NovaForgeSchemaV4.models.map { String(describing: $0) })

        XCTAssertTrue(v2Names.isSuperset(of: v1Names))
        XCTAssertEqual(v2Names.subtracting(v1Names), [
            "AgentEventRecord",
            "PersistedAgentRunMetadataRecord",
            "ApprovalRequestRecord",
            "ExecutionNodeRecord",
            "ProjectionCursorRecord",
            "ProjectionSnapshotRecord",
            "ToolEffectEvidenceRecord"
        ])
        XCTAssertTrue(v3Names.isSuperset(of: v2Names))
        XCTAssertEqual(v3Names.subtracting(v2Names), [
            "AgentArtifactProjectionRecord",
            "AgentMaterializationDispositionRecord",
            "ProjectMaterializedEvidenceRevisionRecord"
        ])
        XCTAssertTrue(v4Names.isSuperset(of: v3Names))
        XCTAssertEqual(v4Names.subtracting(v3Names), [
            "PersistedAgentRunExecutionCompositionRecord"
        ])
        XCTAssertEqual(NovaForgeSchemaMigrationPlan.schemas.count, 4)
        XCTAssertEqual(NovaForgeSchemaMigrationPlan.stages.count, 3)
    }

    func testCapturedV1StoreMigratesToV4WithoutChangingLegacyRows() throws {
        let sourceURL = try fixtureURL("NovaForgeV1.store")
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NovaForgeV4Migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let storeURL = temporaryDirectory.appendingPathComponent("NovaForge.store")
        try FileManager.default.copyItem(at: sourceURL, to: storeURL)

        let firstV4OpenDigest = try inspectMigratedV4Store(at: storeURL)
        XCTAssertEqual(firstV4OpenDigest, expectedV1StableDigest)

        // The first container is released by inspectMigratedV4Store before this
        // second open, exercising the already-migrated store as a fresh launch.
        let secondV4ReopenDigest = try inspectMigratedV4Store(at: storeURL)
        XCTAssertEqual(secondV4ReopenDigest, expectedV1StableDigest)
        XCTAssertEqual(secondV4ReopenDigest, firstV4OpenDigest)
    }

    func testPopulatedV1RunAndToolOperationSurviveV4MigrationAndSecondReopen() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "NovaForgePopulatedV1Migration-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let storeURL = temporaryDirectory.appendingPathComponent("NovaForge.store")

        let v1 = try createPopulatedV1Store(at: storeURL)
        XCTAssertEqual(v1.counts["AgentRunRecord"], 1)
        XCTAssertEqual(v1.counts["ToolOperationRecord"], 1)

        let firstV4Open = try inspectPopulatedV4Store(at: storeURL)
        XCTAssertEqual(firstV4Open, v1)

        // A separate helper releases the first V4 container before this call,
        // proving that an already-migrated store survives a fresh relaunch.
        let secondV4Reopen = try inspectPopulatedV4Store(at: storeURL)
        XCTAssertEqual(secondV4Reopen, v1)
        XCTAssertEqual(secondV4Reopen, firstV4Open)
    }

    func testPopulatedV2StoreMigratesToV4AndSurvivesSecondReopen() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NovaForgePopulatedV2Migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let storeURL = temporaryDirectory.appendingPathComponent("NovaForge.store")
        let v2Snapshot = try createPopulatedV2Store(at: storeURL)

        let firstV4Open = try inspectV2MigratedToV4Store(at: storeURL)
        XCTAssertEqual(firstV4Open, v2Snapshot)

        let secondV4Reopen = try inspectV2MigratedToV4Store(at: storeURL)
        XCTAssertEqual(secondV4Reopen, v2Snapshot)
        XCTAssertEqual(secondV4Reopen, firstV4Open)
    }

    func testPopulatedV3StoreMigratesToV4WithoutInventingExecutionComposition() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "NovaForgePopulatedV3ToV4Migration-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let storeURL = temporaryDirectory.appendingPathComponent("NovaForge.store")
        let v2Snapshot = try createPopulatedV2Store(at: storeURL)
        XCTAssertEqual(try inspectV2MigratedToV3Store(at: storeURL), v2Snapshot)

        let firstV4Open = try inspectV3MigratedToV4Store(at: storeURL)
        XCTAssertEqual(firstV4Open, v2Snapshot)
        let secondV4Reopen = try inspectV3MigratedToV4Store(at: storeURL)
        XCTAssertEqual(secondV4Reopen, v2Snapshot)
        XCTAssertEqual(secondV4Reopen, firstV4Open)

        let recoveryContainer = try ModelContainer(
            for: Schema(versionedSchema: NovaForgeSchemaV4.self),
            migrationPlan: NovaForgeSchemaMigrationPlan.self,
            configurations: [ModelConfiguration(url: storeURL)]
        )
        let migratedRunID = RunID(rawValue: migrationUUID(71))
        do {
            _ = try await SwiftDataAgentStore(container: recoveryContainer)
                .acceptedRunRecoveryRecord(for: migratedRunID)
            XCTFail("V3 recovery invented execution inputs that were never accepted")
        } catch let error as AgentStoreError {
            XCTAssertEqual(
                error,
                .persistenceFailure(
                    operation: .readMetadata,
                    code: "execution_composition_missing"
                )
            )
        }
    }

    func testReleasedV2StoreMigratesWithoutChangingSemanticRowsWhenAvailable() throws {
        let explicitStoreURL = explicitReleasedV2StoreURL()
        let candidateURLs = releasedV2StoreCandidates()
        guard !candidateURLs.isEmpty else {
            throw XCTSkip(
                "Set NOVAFORGE_RELEASED_V2_STORE to a released NovaForge V2 store " +
                    "or make a recovered/bundled V2 fixture available."
            )
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NovaForgeReleasedV2Migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        // Recovery folders may contain multiple generations. Copy candidates
        // newest-first and use an actual frozen-V2 open as the compatibility
        // matcher without ever mutating the source artifact.
        var selectedStoreURL: URL?
        var releasedV2Snapshot: ReleasedV2Snapshot?
        for (index, sourceURL) in candidateURLs.enumerated() {
            let candidateDirectory = temporaryDirectory
                .appendingPathComponent("candidate-\(index)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(
                    at: candidateDirectory,
                    withIntermediateDirectories: true
                )
                let candidateStoreURL = candidateDirectory.appendingPathComponent("NovaForge.store")
                try copyPersistentStore(from: sourceURL, to: candidateStoreURL)
                let snapshot = try inspectReleasedV2Store(at: candidateStoreURL)
                selectedStoreURL = candidateStoreURL
                releasedV2Snapshot = snapshot
                break
            } catch {
                try? FileManager.default.removeItem(at: candidateDirectory)
                if let explicitStoreURL,
                   sourceURL.standardizedFileURL == explicitStoreURL.standardizedFileURL {
                    throw error
                }
            }
        }
        guard let storeURL = selectedStoreURL, let releasedV2Snapshot else {
            throw XCTSkip("No available recovery artifact matched the frozen released V2 schema.")
        }

        let firstV4Open = try inspectV2MigratedToV4Store(at: storeURL)
        XCTAssertEqual(firstV4Open, releasedV2Snapshot)

        let secondV4Reopen = try inspectV2MigratedToV4Store(at: storeURL)
        XCTAssertEqual(secondV4Reopen, releasedV2Snapshot)
        XCTAssertEqual(secondV4Reopen, firstV4Open)
    }

    func testDashboardSnapshotKeyIncludesMaterializedEvidenceRevision() {
        let projectID = migrationUUID(80)
        let timestamp = Date(timeIntervalSinceReferenceDate: 800_000_080)
        let baseline = ProjectDashboardSnapshotKey(
            projectID: projectID,
            materializedEvidenceRevision: 4,
            projectUpdatedAt: timestamp,
            projectLastActivityAt: timestamp,
            activeProjectOSRunID: nil,
            activeProjectOSRunUpdatedAt: nil,
            activeProjectOSRunStatusRawValue: nil
        )
        let advanced = ProjectDashboardSnapshotKey(
            projectID: projectID,
            materializedEvidenceRevision: 5,
            projectUpdatedAt: timestamp,
            projectLastActivityAt: timestamp,
            activeProjectOSRunID: nil,
            activeProjectOSRunUpdatedAt: nil,
            activeProjectOSRunStatusRawValue: nil
        )

        XCTAssertNotEqual(baseline, advanced)
    }

    private func inspectMigratedV4Store(at storeURL: URL) throws -> [String] {
        let container = try ModelContainer(
            for: Schema(versionedSchema: NovaForgeSchemaV4.self),
            migrationPlan: NovaForgeSchemaMigrationPlan.self,
            configurations: [ModelConfiguration(url: storeURL)]
        )
        let context = ModelContext(container)

        try assertV1RowCounts(in: context)
        try assertV3CompanionRowsAreEmpty(in: context)
        try assertV4AddedRowsAreEmpty(in: context)
        return try stableV1Digest(in: context)
    }

    private func createPopulatedV1Store(
        at storeURL: URL
    ) throws -> PopulatedV1Snapshot {
        let container = try ModelContainer(
            for: Schema(versionedSchema: NovaForgeSchemaV1.self),
            configurations: [ModelConfiguration(url: storeURL)]
        )
        let context = ModelContext(container)
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let projectID = migrationUUID(1)
        let conversationID = migrationUUID(2)
        let requestID = migrationUUID(3)
        let responseID = migrationUUID(4)
        let runID = migrationUUID(5)
        let operationID = migrationUUID(6)
        let workspaceID = migrationUUID(7)

        let project = Project(
            name: "Populated migration project",
            mission: "Preserve legacy run receipts",
            workspaceName: "Migration Workspace"
        )
        project.id = projectID
        let conversation = Conversation(
            title: "Populated migration conversation",
            project: project
        )
        conversation.id = conversationID
        let request = ChatMessage(
            id: requestID,
            role: .user,
            content: "Migrate this accepted request.",
            conversation: conversation,
            runID: runID,
            runSequence: 0,
            runStatus: .completed
        )
        request.createdAt = now
        let response = ChatMessage(
            id: responseID,
            role: .assistant,
            content: "Migration proof complete.",
            conversation: conversation,
            runID: runID,
            runSequence: 3,
            runStatus: .completed
        )
        response.createdAt = now.addingTimeInterval(3)
        conversation.appendMessages(
            [request, response],
            updateTimestamp: response.createdAt
        )
        let run = AgentRunRecord(
            id: runID,
            status: .completed,
            origin: .user,
            conversationID: conversationID,
            projectID: projectID,
            workspaceID: workspaceID,
            workspaceName: "Migration Workspace",
            requestMessageID: requestID,
            responseMessageID: responseID,
            provider: .openAI,
            modelID: "migration-model",
            now: now
        )
        let operation = ToolOperationRecord(
            id: operationID,
            runID: runID,
            projectID: projectID,
            conversationID: conversationID,
            workspaceID: workspaceID,
            workspaceName: "Migration Workspace",
            toolCallID: "migration-call",
            toolName: "workspace.writeFile",
            argumentsJSON: "{\"path\":\"Sources/Migrated.swift\"}",
            argumentsHash: "migration-arguments-digest",
            targetPaths: ["Sources/Migrated.swift"],
            phase: .completed,
            resultSummary: "Applied and verified",
            now: now.addingTimeInterval(1)
        )

        context.insert(project)
        context.insert(conversation)
        context.insert(request)
        context.insert(response)
        context.insert(run)
        context.insert(operation)
        try context.save()
        return try populatedV1Snapshot(in: context)
    }

    private func inspectPopulatedV4Store(
        at storeURL: URL
    ) throws -> PopulatedV1Snapshot {
        let container = try ModelContainer(
            for: Schema(versionedSchema: NovaForgeSchemaV4.self),
            migrationPlan: NovaForgeSchemaMigrationPlan.self,
            configurations: [ModelConfiguration(url: storeURL)]
        )
        let context = ModelContext(container)
        try assertV3CompanionRowsAreEmpty(in: context)
        try assertV4AddedRowsAreEmpty(in: context)
        return try populatedV1Snapshot(in: context)
    }

    private func createPopulatedV2Store(at storeURL: URL) throws -> ReleasedV2Snapshot {
        let container = try ModelContainer(
            for: Schema(versionedSchema: NovaForgeSchemaV2.self),
            configurations: [ModelConfiguration(url: storeURL)]
        )
        let context = ModelContext(container)
        let project = Project(
            name: "V2 migration project",
            mission: "Prove the additive V3 stage",
            workspaceName: "Migration Workspace"
        )
        project.id = migrationUUID(70)
        let timestamp = Date(timeIntervalSinceReferenceDate: 800_000_070)
        let runID = migrationUUID(71).uuidString.lowercased()
        let eventID = migrationUUID(72).uuidString.lowercased()
        let workspaceID = migrationUUID(73).uuidString.lowercased()
        let conversationID = migrationUUID(74).uuidString.lowercased()
        let nodeID = migrationUUID(75).uuidString.lowercased()
        context.insert(project)
        context.insert(AgentEventRecord(
            journalOffsetValue: 7,
            eventIDString: eventID,
            writerIDString: "v2-migration-writer",
            writerSequenceValue: 1,
            idempotencyKey: "v2-migration-idempotency",
            runIDString: runID,
            rootRunIDString: runID,
            parentRunIDString: nil,
            sequenceValue: 1,
            timestampMilliseconds: 800_000_070_000,
            executionNodeIDString: nodeID,
            conversationIDString: conversationID,
            projectIDString: project.id.uuidString.lowercased(),
            workspaceIDString: workspaceID,
            causationIDString: nil,
            correlationIDString: runID,
            schemaMajor: 2,
            schemaMinor: 0,
            engineVersion: "v2-migration-engine",
            eventKind: "runAccepted",
            encodingName: "json",
            encodingVersion: 1,
            encodedEvent: Data("{\"fixture\":\"event\"}".utf8),
            payloadDigest: "v2-event-digest",
            committedAtMilliseconds: 800_000_070_001,
            insertedAt: timestamp
        ))
        context.insert(PersistedAgentRunMetadataRecord(
            runIDString: runID,
            rootRunIDString: runID,
            parentRunIDString: nil,
            writerIDString: "v2-migration-writer",
            acceptanceCommandIDString: migrationUUID(76).uuidString.lowercased(),
            engineVersion: "v2-migration-engine",
            enabledFeaturesJSON: Data("[\"ledger\"]".utf8),
            executionNodeIDString: nodeID,
            conversationIDString: conversationID,
            projectIDString: project.id.uuidString.lowercased(),
            workspaceIDString: workspaceID,
            acceptedEventIDString: eventID,
            acceptedAtMilliseconds: 800_000_070_000,
            encodingName: "json",
            encodingVersion: 1,
            encodedMetadata: Data("{\"fixture\":\"metadata\"}".utf8),
            metadataDigest: "v2-metadata-digest",
            createdAt: timestamp
        ))
        context.insert(ApprovalRequestRecord(
            approvalRequestIDString: migrationUUID(77).uuidString.lowercased(),
            runIDString: runID,
            toolCallIDString: "v2-tool-call",
            workspaceIDString: workspaceID,
            requestedEventIDString: eventID,
            statusRawValue: "pending",
            encodedRequest: Data("{\"fixture\":\"approval\"}".utf8),
            requestedAtMilliseconds: 800_000_070_002,
            updatedAt: timestamp
        ))
        context.insert(ToolEffectEvidenceRecord(
            runIDString: runID,
            toolCallIDString: "v2-tool-call",
            appliedEventIDString: eventID,
            workspaceIDString: workspaceID,
            evidenceKind: "fixture",
            encodedEvidence: Data("{\"fixture\":\"evidence\"}".utf8),
            evidenceDigest: "v2-evidence-digest",
            appliedAtMilliseconds: 800_000_070_003,
            createdAt: timestamp
        ))
        context.insert(ProjectionCursorRecord(
            projectionIDString: "v2-migration-projection",
            throughOffsetValue: 7,
            updatedAtMilliseconds: 800_000_070_000,
            updatedAt: timestamp
        ))
        context.insert(ProjectionSnapshotRecord(
            projectionName: "v2-migration-projection",
            projectionVersion: 2,
            runIDString: runID,
            throughSequenceValue: 1,
            throughEventIDString: eventID,
            stateEncodingName: "json",
            stateEncodingVersion: 1,
            encodedState: Data("{\"fixture\":\"snapshot\"}".utf8),
            stateDigest: "v2-snapshot-digest",
            createdAt: timestamp
        ))
        context.insert(ExecutionNodeRecord(
            executionNodeIDString: nodeID,
            kindRawValue: "local",
            displayName: "V2 migration node",
            capabilityManifest: Data("{\"tools\":[]}".utf8),
            manifestDigest: "v2-node-digest",
            lastSeenAtMilliseconds: 800_000_070_004,
            updatedAt: timestamp
        ))
        try context.save()
        return try releasedV2Snapshot(in: context)
    }

    private func inspectReleasedV2Store(at storeURL: URL) throws -> ReleasedV2Snapshot {
        let container = try ModelContainer(
            for: Schema(versionedSchema: NovaForgeSchemaV2.self),
            configurations: [ModelConfiguration(url: storeURL)]
        )
        return try releasedV2Snapshot(in: ModelContext(container))
    }

    private func inspectV2MigratedToV4Store(at storeURL: URL) throws -> ReleasedV2Snapshot {
        let container = try ModelContainer(
            for: Schema(versionedSchema: NovaForgeSchemaV4.self),
            migrationPlan: NovaForgeSchemaMigrationPlan.self,
            configurations: [ModelConfiguration(url: storeURL)]
        )
        let context = ModelContext(container)
        try assertV3AddedRowsAreEmpty(in: context)
        XCTAssertEqual(
            try context.fetchCount(
                FetchDescriptor<PersistedAgentRunExecutionCompositionRecord>()
            ),
            0
        )
        return try releasedV2Snapshot(in: context)
    }

    private func inspectV2MigratedToV3Store(at storeURL: URL) throws -> ReleasedV2Snapshot {
        let container = try ModelContainer(
            for: Schema(versionedSchema: NovaForgeSchemaV3.self),
            migrationPlan: NovaForgeThroughV3MigrationPlan.self,
            configurations: [ModelConfiguration(url: storeURL)]
        )
        let context = ModelContext(container)
        try assertV3AddedRowsAreEmpty(in: context)
        return try releasedV2Snapshot(in: context)
    }

    private func inspectV3MigratedToV4Store(at storeURL: URL) throws -> ReleasedV2Snapshot {
        let container = try ModelContainer(
            for: Schema(versionedSchema: NovaForgeSchemaV4.self),
            migrationPlan: NovaForgeSchemaMigrationPlan.self,
            configurations: [ModelConfiguration(url: storeURL)]
        )
        let context = ModelContext(container)
        XCTAssertEqual(
            try context.fetchCount(
                FetchDescriptor<PersistedAgentRunExecutionCompositionRecord>()
            ),
            0,
            "A V3 run has no trustworthy route/tool/policy/instruction digests to backfill."
        )
        return try releasedV2Snapshot(in: context)
    }

    private func populatedV1Snapshot(
        in context: ModelContext
    ) throws -> PopulatedV1Snapshot {
        PopulatedV1Snapshot(
            counts: [
                "Project": try context.fetchCount(FetchDescriptor<Project>()),
                "ProjectEvent": try context.fetchCount(FetchDescriptor<ProjectEvent>()),
                "ProjectArtifact": try context.fetchCount(FetchDescriptor<ProjectArtifact>()),
                "TerminalCommandRecord": try context.fetchCount(FetchDescriptor<TerminalCommandRecord>()),
                "ProjectFileChange": try context.fetchCount(FetchDescriptor<ProjectFileChange>()),
                "ProjectOSRun": try context.fetchCount(FetchDescriptor<ProjectOSRun>()),
                "ProjectOSStep": try context.fetchCount(FetchDescriptor<ProjectOSStep>()),
                "Conversation": try context.fetchCount(FetchDescriptor<Conversation>()),
                "ChatMessage": try context.fetchCount(FetchDescriptor<ChatMessage>()),
                "ToolRun": try context.fetchCount(FetchDescriptor<ToolRun>()),
                "AgentRunRecord": try context.fetchCount(FetchDescriptor<AgentRunRecord>()),
                "ToolOperationRecord": try context.fetchCount(FetchDescriptor<ToolOperationRecord>()),
                "AgentSettings": try context.fetchCount(FetchDescriptor<AgentSettings>())
            ],
            digest: try stableV1Digest(in: context)
        )
    }

    private func releasedV2Snapshot(
        in context: ModelContext
    ) throws -> ReleasedV2Snapshot {
        ReleasedV2Snapshot(
            counts: [
                "Project": try context.fetchCount(FetchDescriptor<Project>()),
                "ProjectEvent": try context.fetchCount(FetchDescriptor<ProjectEvent>()),
                "ProjectArtifact": try context.fetchCount(FetchDescriptor<ProjectArtifact>()),
                "TerminalCommandRecord": try context.fetchCount(FetchDescriptor<TerminalCommandRecord>()),
                "ProjectFileChange": try context.fetchCount(FetchDescriptor<ProjectFileChange>()),
                "ProjectOSRun": try context.fetchCount(FetchDescriptor<ProjectOSRun>()),
                "ProjectOSStep": try context.fetchCount(FetchDescriptor<ProjectOSStep>()),
                "Conversation": try context.fetchCount(FetchDescriptor<Conversation>()),
                "ChatMessage": try context.fetchCount(FetchDescriptor<ChatMessage>()),
                "ToolRun": try context.fetchCount(FetchDescriptor<ToolRun>()),
                "AgentRunRecord": try context.fetchCount(FetchDescriptor<AgentRunRecord>()),
                "ToolOperationRecord": try context.fetchCount(FetchDescriptor<ToolOperationRecord>()),
                "AgentSettings": try context.fetchCount(FetchDescriptor<AgentSettings>()),
                "AgentEventRecord": try context.fetchCount(FetchDescriptor<AgentEventRecord>()),
                "PersistedAgentRunMetadataRecord": try context.fetchCount(
                    FetchDescriptor<PersistedAgentRunMetadataRecord>()
                ),
                "ApprovalRequestRecord": try context.fetchCount(FetchDescriptor<ApprovalRequestRecord>()),
                "ToolEffectEvidenceRecord": try context.fetchCount(FetchDescriptor<ToolEffectEvidenceRecord>()),
                "ProjectionCursorRecord": try context.fetchCount(FetchDescriptor<ProjectionCursorRecord>()),
                "ProjectionSnapshotRecord": try context.fetchCount(FetchDescriptor<ProjectionSnapshotRecord>()),
                "ExecutionNodeRecord": try context.fetchCount(FetchDescriptor<ExecutionNodeRecord>())
            ],
            digest: try stableV1Digest(in: context) + stableV2CompanionDigest(in: context)
        )
    }

    private func assertV1RowCounts(in context: ModelContext) throws {
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Project>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ProjectEvent>()), 9)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ProjectArtifact>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<TerminalCommandRecord>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ProjectFileChange>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ProjectOSRun>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ProjectOSStep>()), 5)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Conversation>()), 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ChatMessage>()), 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ToolRun>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AgentRunRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ToolOperationRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AgentSettings>()), 1)
    }

    private func assertV3CompanionRowsAreEmpty(in context: ModelContext) throws {
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AgentEventRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PersistedAgentRunMetadataRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ApprovalRequestRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ToolEffectEvidenceRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ProjectionCursorRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ProjectionSnapshotRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ExecutionNodeRecord>()), 0)
        try assertV3AddedRowsAreEmpty(in: context)
    }

    private func assertV3AddedRowsAreEmpty(in context: ModelContext) throws {
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AgentArtifactProjectionRecord>()), 0)
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<ProjectMaterializedEvidenceRevisionRecord>()),
            0
        )
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<AgentMaterializationDispositionRecord>()),
            0
        )
    }

    private func assertV4AddedRowsAreEmpty(in context: ModelContext) throws {
        XCTAssertEqual(
            try context.fetchCount(
                FetchDescriptor<PersistedAgentRunExecutionCompositionRecord>()
            ),
            0
        )
    }

    private func stableV2CompanionDigest(in context: ModelContext) throws -> [String] {
        let events = try context.fetch(FetchDescriptor<AgentEventRecord>()).sorted {
            ($0.journalOffsetValue, $0.eventIDString) < ($1.journalOffsetValue, $1.eventIDString)
        }
        let metadata = try context.fetch(FetchDescriptor<PersistedAgentRunMetadataRecord>()).sorted {
            $0.runIDString < $1.runIDString
        }
        let approvals = try context.fetch(FetchDescriptor<ApprovalRequestRecord>()).sorted {
            $0.approvalRequestIDString < $1.approvalRequestIDString
        }
        let evidence = try context.fetch(FetchDescriptor<ToolEffectEvidenceRecord>()).sorted {
            $0.evidenceKey < $1.evidenceKey
        }
        let cursors = try context.fetch(FetchDescriptor<ProjectionCursorRecord>()).sorted {
            $0.cursorKey < $1.cursorKey
        }
        let snapshots = try context.fetch(FetchDescriptor<ProjectionSnapshotRecord>()).sorted {
            $0.snapshotKey < $1.snapshotKey
        }
        let executionNodes = try context.fetch(FetchDescriptor<ExecutionNodeRecord>()).sorted {
            $0.executionNodeIDString < $1.executionNodeIDString
        }

        var digest: [String] = []
        digest.append(contentsOf: events.map { event in
            "agentEvent|\(event.journalOffsetValue)|\(event.eventIDString)|\(event.runSequenceKey)" +
                "|\(event.writerSequenceKey)|\(event.writerIdempotencyKey)|\(event.writerIDString)" +
                "|\(event.writerSequenceValue)|\(event.idempotencyKey)|\(event.runIDString)" +
                "|\(event.rootRunIDString)|\(event.parentRunIDString ?? "nil")|\(event.sequenceValue)" +
                "|\(event.timestampMilliseconds)|\(event.executionNodeIDString)" +
                "|\(event.conversationIDString)|\(event.projectIDString ?? "nil")" +
                "|\(event.workspaceIDString)|\(event.causationIDString ?? "nil")" +
                "|\(event.correlationIDString)|\(event.schemaMajor).\(event.schemaMinor)" +
                "|\(event.engineVersion)|\(event.eventKind)|\(event.encodingName):\(event.encodingVersion)" +
                "|\(event.encodedEvent.base64EncodedString())|\(event.payloadDigest)" +
                "|\(event.committedAtMilliseconds)|\(stableDateDigest(event.insertedAt))"
        })
        digest.append(contentsOf: metadata.map { record in
            "runMetadata|\(record.runIDString)|\(record.rootRunIDString)" +
                "|\(record.parentRunIDString ?? "nil")|\(record.writerIDString)" +
                "|\(record.acceptanceCommandIDString)|\(record.engineVersion)" +
                "|\(record.enabledFeaturesJSON.base64EncodedString())|\(record.executionNodeIDString)" +
                "|\(record.conversationIDString)|\(record.projectIDString ?? "nil")" +
                "|\(record.workspaceIDString)|\(record.acceptedEventIDString)" +
                "|\(record.acceptedAtMilliseconds)|\(record.encodingName):\(record.encodingVersion)" +
                "|\(record.encodedMetadata.base64EncodedString())|\(record.metadataDigest)" +
                "|\(stableDateDigest(record.createdAt))"
        })
        digest.append(contentsOf: approvals.map { approval in
            "approval|\(approval.approvalRequestIDString)|\(approval.runIDString)" +
                "|\(approval.toolCallIDString)|\(approval.workspaceIDString)" +
                "|\(approval.requestedEventIDString)|\(approval.resolvedEventIDString ?? "nil")" +
                "|\(approval.statusRawValue)|\(approval.encodedRequest.base64EncodedString())" +
                "|\(approval.encodedResolution?.base64EncodedString() ?? "nil")" +
                "|\(approval.requestedAtMilliseconds)|\(approval.resolvedAtMilliseconds.map { String($0) } ?? "nil")" +
                "|\(stableDateDigest(approval.updatedAt))"
        })
        digest.append(contentsOf: evidence.map { record in
            "effectEvidence|\(record.evidenceKey)|\(record.runIDString)|\(record.toolCallIDString)" +
                "|\(record.appliedEventIDString)|\(record.workspaceIDString)|\(record.evidenceKind)" +
                "|\(record.encodedEvidence.base64EncodedString())|\(record.evidenceDigest)" +
                "|\(record.appliedAtMilliseconds)|\(stableDateDigest(record.createdAt))"
        })
        digest.append(contentsOf: cursors.map { cursor in
            "cursor|\(cursor.cursorKey)|\(cursor.projectionIDString)|\(cursor.throughOffsetValue)" +
                "|\(cursor.updatedAtMilliseconds)|\(stableDateDigest(cursor.updatedAt))"
        })
        digest.append(contentsOf: snapshots.map { snapshot in
            "snapshot|\(snapshot.snapshotKey)|\(snapshot.projectionName)|\(snapshot.projectionVersion)" +
                "|\(snapshot.runIDString)|\(snapshot.throughSequenceValue)|\(snapshot.throughEventIDString)" +
                "|\(snapshot.stateEncodingName):\(snapshot.stateEncodingVersion)" +
                "|\(snapshot.encodedState.base64EncodedString())|\(snapshot.stateDigest)" +
                "|\(stableDateDigest(snapshot.createdAt))"
        })
        digest.append(contentsOf: executionNodes.map { node in
            "executionNode|\(node.executionNodeIDString)|\(node.kindRawValue)|\(node.displayName)" +
                "|\(node.capabilityManifest.base64EncodedString())|\(node.manifestDigest)" +
                "|\(node.isRevoked)|\(node.lastSeenAtMilliseconds)|\(stableDateDigest(node.updatedAt))"
        })
        return digest
    }

    private func stableDateDigest(_ date: Date) -> String {
        String(date.timeIntervalSinceReferenceDate.bitPattern, radix: 16)
    }

    private func stableV1Digest(in context: ModelContext) throws -> [String] {
        let projects = try context.fetch(FetchDescriptor<Project>()).sorted { $0.name < $1.name }
        let events = try context.fetch(FetchDescriptor<ProjectEvent>()).sorted {
            ($0.kindRawValue, $0.title) < ($1.kindRawValue, $1.title)
        }
        let artifacts = try context.fetch(FetchDescriptor<ProjectArtifact>()).sorted { $0.path < $1.path }
        let terminalCommands = try context.fetch(FetchDescriptor<TerminalCommandRecord>()).sorted {
            $0.command < $1.command
        }
        let fileChanges = try context.fetch(FetchDescriptor<ProjectFileChange>()).sorted {
            ($0.path, $0.action) < ($1.path, $1.action)
        }
        let projectOSRuns = try context.fetch(FetchDescriptor<ProjectOSRun>()).sorted {
            $0.projectName < $1.projectName
        }
        let projectOSSteps = try context.fetch(FetchDescriptor<ProjectOSStep>()).sorted {
            ($0.orderIndex, $0.key) < ($1.orderIndex, $1.key)
        }
        let conversations = try context.fetch(FetchDescriptor<Conversation>()).sorted { $0.title < $1.title }
        let messages = try context.fetch(FetchDescriptor<ChatMessage>()).sorted {
            ($0.roleRawValue, $0.content) < ($1.roleRawValue, $1.content)
        }
        let toolRuns = try context.fetch(FetchDescriptor<ToolRun>()).sorted { $0.name < $1.name }
        let agentRuns = try context.fetch(FetchDescriptor<AgentRunRecord>()).sorted {
            $0.id.uuidString < $1.id.uuidString
        }
        let toolOperations = try context.fetch(FetchDescriptor<ToolOperationRecord>()).sorted {
            $0.id.uuidString < $1.id.uuidString
        }
        let settings = try context.fetch(FetchDescriptor<AgentSettings>()).sorted {
            $0.modelID < $1.modelID
        }

        let projectNamesByID = Dictionary(uniqueKeysWithValues: projects.map { ($0.id.uuidString, $0.name) })
        let conversationTitlesByID = Dictionary(
            uniqueKeysWithValues: conversations.map { ($0.id.uuidString, $0.title) }
        )
        let messageContentByID = Dictionary(
            uniqueKeysWithValues: messages.map { ($0.id.uuidString, $0.content) }
        )
        var digest: [String] = []

        digest.append(contentsOf: projects.map { project in
            "project|\(project.name)|\(project.statusRawValue)|\(project.workspaceName)" +
                "|conversations=\(project.conversations.count)|toolRuns=\(project.toolRuns.count)" +
                "|events=\(project.events.count)|artifacts=\(project.artifacts.count)" +
                "|terminalCommands=\(project.terminalCommands.count)|fileChanges=\(project.fileChanges.count)" +
                "|projectOSRuns=\(project.projectOSRuns.count)"
        })
        digest.append(contentsOf: events.map { event in
            "event|\(event.kindRawValue)|\(event.severityRawValue)|\(event.title)" +
                "|project=\(event.project?.name ?? "nil")"
        })
        digest.append(contentsOf: artifacts.map { artifact in
            "artifact|\(artifact.path)|\(artifact.kindRawValue)|\(artifact.typeRawValue ?? "nil")" +
                "|\(artifact.statusRawValue ?? "nil")|version=\(artifact.version ?? -1)" +
                "|project=\(artifact.project?.name ?? "nil")"
        })
        digest.append(contentsOf: terminalCommands.map { command in
            "terminalCommand|\(command.command)|\(command.statusRawValue)|\(command.workspaceName)" +
                "|project=\(command.project?.name ?? "nil")"
        })
        digest.append(contentsOf: fileChanges.map { change in
            "fileChange|\(change.action)|\(change.path)|project=\(change.project?.name ?? "nil")"
        })
        digest.append(contentsOf: projectOSRuns.map { run in
            let sourceConversation = run.sourceConversationIDString
                .flatMap { conversationTitlesByID[$0] } ?? "nil"
            return "projectOSRun|\(run.projectName)|\(run.statusRawValue)|\(run.originRawValue)" +
                "|\(run.planningState)|\(run.currentAction)|progress=\(run.progressEventCount)" +
                "|steps=\(run.steps.count)|project=\(run.project?.name ?? "nil")" +
                "|sourceConversation=\(sourceConversation)"
        })
        digest.append(contentsOf: projectOSSteps.map { step in
            "projectOSStep|\(step.orderIndex)|\(step.key)|\(step.title)|\(step.statusRawValue)" +
                "|run=\(step.run?.projectName ?? "nil")"
        })
        digest.append(contentsOf: conversations.map { conversation in
            "conversation|\(conversation.title)|messageCount=\(conversation.messageCount)" +
                "|hasUserMessages=\(conversation.hasUserMessages)|messages=\(conversation.messages.count)" +
                "|project=\(conversation.project?.name ?? "nil")"
        })
        digest.append(contentsOf: messages.map { message in
            "message|\(message.roleRawValue)|\(message.content)" +
                "|conversation=\(message.conversation?.title ?? "nil")"
        })
        digest.append(contentsOf: toolRuns.map { toolRun in
            "toolRun|\(toolRun.name)|\(toolRun.argumentsJSON)|\(toolRun.statusRawValue)" +
                "|requiresApproval=\(toolRun.requiresApproval)|isMutating=\(toolRun.isMutating)" +
                "|project=\(toolRun.project?.name ?? "nil")"
        })
        digest.append(contentsOf: agentRuns.map { run in
            "agentRun|\(run.statusRawValue)|\(run.originRawValue)" +
                "|conversation=\(run.conversationIDString.flatMap { conversationTitlesByID[$0] } ?? "nil")" +
                "|project=\(run.projectIDString.flatMap { projectNamesByID[$0] } ?? "nil")" +
                "|workspace=\(run.workspaceName ?? "nil")" +
                "|request=\(run.requestMessageIDString.flatMap { messageContentByID[$0] } ?? "nil")" +
                "|response=\(run.responseMessageIDString.flatMap { messageContentByID[$0] } ?? "nil")" +
                "|provider=\(run.providerRawValue ?? "nil")|model=\(run.modelID ?? "nil")" +
                "|error=\(run.errorKindRawValue ?? "nil"):\(run.errorMessage ?? "nil")"
        })
        digest.append(contentsOf: toolOperations.map { operation in
            "toolOperation|\(operation.toolName)|\(operation.argumentsJSON)" +
                "|hash=\(operation.argumentsHash)|phase=\(operation.phaseRawValue)" +
                "|targets=\(operation.targetPaths.joined(separator: ","))" +
                "|workspace=\(operation.workspaceName ?? "nil")" +
                "|project=\(operation.projectIDString.flatMap { projectNamesByID[$0] } ?? "nil")" +
                "|conversation=\(operation.conversationIDString.flatMap { conversationTitlesByID[$0] } ?? "nil")" +
                "|call=\(operation.toolCallID ?? "nil")" +
                "|result=\(operation.resultSummary ?? "nil")|error=\(operation.errorMessage ?? "nil")"
        })
        digest.append(contentsOf: settings.map { setting in
            let activeProject = setting.activeProjectIDString
                .flatMap { projectNamesByID[$0] } ?? "nil"
            return "settings|\(setting.providerRawValue ?? "nil")|\(setting.modelID)" +
                "|autoApproveWrites=\(setting.autoApproveWrites)|workspace=\(setting.activeWorkspaceName)" +
                "|activeProject=\(activeProject)"
        })

        return digest
    }

    private var expectedV1StableDigest: [String] {
        [
            "project|Proof Receipt|active|Default|conversations=1|toolRuns=1|events=9|artifacts=1|terminalCommands=1|fileChanges=1|projectOSRuns=1",
            "event|agentPlanCreated|running|Agent plan prepared|project=Proof Receipt",
            "event|agentProofCreated|success|Agent proof captured|project=Proof Receipt",
            "event|artifactCreated|success|Web artifact ready|project=Proof Receipt",
            "event|conversationStarted|info|Conversation started|project=Proof Receipt",
            "event|fileChanged|success|Saved proof|project=Proof Receipt",
            "event|missionCheckpoint|success|Mission OS checkpoint: Ready to review|project=Proof Receipt",
            "event|projectCreated|success|Default project created|project=Proof Receipt",
            "event|runCompleted|success|Run completed|project=Proof Receipt",
            "event|terminalCommand|success|Agent command completed|project=Proof Receipt",
            "artifact|project-os-proof.html|web|html|generated|version=1|project=Proof Receipt",
            "terminalCommand|validate_html_file project-os-proof.html|completed|Default|project=Proof Receipt",
            "fileChange|Saved proof|project-os-proof.html|project=Proof Receipt",
            "projectOSRun|Proof Receipt|completed|fixture|Agent-authored plan recorded|Run complete|progress=5|steps=5|project=Proof Receipt|sourceConversation=NovaForge Project",
            "projectOSStep|0|context|Read project context|completed|run=Proof Receipt",
            "projectOSStep|1|plan|Create agent plan|completed|run=Proof Receipt",
            "projectOSStep|2|review-evidence|Review evidence|completed|run=Proof Receipt",
            "projectOSStep|3|recommend|Recommend action|completed|run=Proof Receipt",
            "projectOSStep|4|proof|Capture proof|completed|run=Proof Receipt",
            "conversation|NovaForge Project|messageCount=2|hasUserMessages=true|messages=2|project=Proof Receipt",
            "conversation|NovaForge Ready|messageCount=0|hasUserMessages=false|messages=0|project=nil",
            "message|assistant|Agent Proof: checked project-os-proof.html, captured durable proof, and found no active blocker.|conversation=NovaForge Project",
            "message|user|Verify the Project OS proof loop.|conversation=NovaForge Project",
            "toolRun|validate_html_file|{\"path\":\"project-os-proof.html\"}|completed|requiresApproval=false|isMutating=false|project=Proof Receipt",
            "settings|local|WeiboAI/VibeThinker-3B-Q2_K|autoApproveWrites=false|workspace=Default|activeProject=Proof Receipt"
        ]
    }

    private func fixtureURL(_ name: String) throws -> URL {
        let bundle = Bundle(for: AgentStoreMigrationTests.self)
        let filename = name as NSString
        let resource = filename.deletingPathExtension
        let extensionName = filename.pathExtension.isEmpty ? nil : filename.pathExtension
        for subdirectory in ["Fixtures/AgentHarnessV1", "AgentHarnessV1", nil] as [String?] {
            if let url = bundle.url(
                forResource: resource,
                withExtension: extensionName,
                subdirectory: subdirectory
            ) {
                return url
            }
        }
        throw AgentStoreMigrationTestError.missingFixture(name)
    }

    private func releasedV2StoreCandidates() -> [URL] {
        var candidates: [URL] = []
        if let configuredURL = explicitReleasedV2StoreURL() {
            candidates.append(configuredURL)
        }

        let bundle = Bundle(for: AgentStoreMigrationTests.self)
        for subdirectory in ["Fixtures/AgentHarnessV2", "AgentHarnessV2", nil] as [String?] {
            if let url = bundle.url(
                forResource: "NovaForgeV2",
                withExtension: "store",
                subdirectory: subdirectory
            ) {
                candidates.append(url)
                break
            }
        }

        for supportURL in FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ) {
            let recoveryDirectory = supportURL.appendingPathComponent(
                "RecoveredStores",
                isDirectory: true
            )
            let recovered = (try? FileManager.default.contentsOfDirectory(
                at: recoveryDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            candidates.append(contentsOf: recovered.filter { url in
                let name = url.lastPathComponent
                guard name.hasPrefix("NovaForge.store."),
                      !name.hasSuffix("-wal"),
                      !name.hasSuffix("-shm"),
                      !name.hasSuffix(".recovery.txt") else {
                    return false
                }
                return (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }.sorted { lhs, rhs in
                let lhsDate = try? lhs.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate
                let rhsDate = try? rhs.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate
                if lhsDate == rhsDate {
                    return lhs.path > rhs.path
                }
                return (lhsDate ?? .distantPast) > (rhsDate ?? .distantPast)
            })
        }

        var seenPaths: Set<String> = []
        return candidates.filter { seenPaths.insert($0.standardizedFileURL.path).inserted }
    }

    private func explicitReleasedV2StoreURL() -> URL? {
        if let configuredPath = ProcessInfo.processInfo.environment["NOVAFORGE_RELEASED_V2_STORE"],
           !configuredPath.isEmpty {
            return URL(fileURLWithPath: configuredPath)
        }
        return nil
    }

    private func copyPersistentStore(from sourceURL: URL, to destinationURL: URL) throws {
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        for suffix in ["-wal", "-shm"] {
            let sourceSidecar = URL(fileURLWithPath: sourceURL.path + suffix)
            guard FileManager.default.fileExists(atPath: sourceSidecar.path) else { continue }
            try FileManager.default.copyItem(
                at: sourceSidecar,
                to: URL(fileURLWithPath: destinationURL.path + suffix)
            )
        }
    }
}

/// Test-only historical target used to materialize an actual V3 source store
/// before exercising the production V3 -> V4 stage.
private enum NovaForgeThroughV3MigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [NovaForgeSchemaV1.self, NovaForgeSchemaV2.self, NovaForgeSchemaV3.self]
    }

    static var stages: [MigrationStage] {
        [
            .lightweight(
                fromVersion: NovaForgeSchemaV1.self,
                toVersion: NovaForgeSchemaV2.self
            ),
            .lightweight(
                fromVersion: NovaForgeSchemaV2.self,
                toVersion: NovaForgeSchemaV3.self
            ),
        ]
    }
}

private enum AgentStoreMigrationTestError: Error {
    case missingFixture(String)
}

private struct PopulatedV1Snapshot: Equatable {
    let counts: [String: Int]
    let digest: [String]
}

private struct ReleasedV2Snapshot: Equatable {
    let counts: [String: Int]
    let digest: [String]
}

private func migrationUUID(_ value: UInt64) -> UUID {
    let suffix = String(format: "%012llX", value)
    return UUID(uuidString: "20000000-0000-0000-0000-\(suffix)")!
}
