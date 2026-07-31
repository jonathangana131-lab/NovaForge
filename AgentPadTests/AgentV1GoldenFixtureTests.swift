import CryptoKit
import Foundation
import SwiftData
import XCTest

@MainActor
final class AgentV1GoldenFixtureTests: XCTestCase {
    func testManifestFreezesSchemaEngineAndRollbackReference() throws {
        let manifest: V1FixtureManifest = try decodeFixture("manifest.json")

        XCTAssertEqual(manifest.formatVersion, 1)
        XCTAssertEqual(manifest.fixtureSet, "AgentHarnessV1")
        XCTAssertEqual(manifest.source.baseCommit, "05cb2b2c4c43955e9c329e4e197c0fbd22026bcf")
        XCTAssertEqual(manifest.compatibility.swiftDataSchema, "NovaForgeSchemaV1")
        XCTAssertEqual(manifest.compatibility.schemaVersion, "1.0.0")
        XCTAssertEqual(manifest.compatibility.engineVersion, "v1")
        XCTAssertEqual(manifest.routing.defaultEngineVersion, "v1")
        XCTAssertTrue(manifest.routing.enabledFeatures.isEmpty)
        XCTAssertTrue(manifest.routing.activeRunRoutingIsImmutable)
        XCTAssertEqual(manifest.rollback.referenceCommit, manifest.source.baseCommit)
        XCTAssertEqual(manifest.rollback.engineForNewRuns, "v1")
        XCTAssertFalse(manifest.rollback.databaseDowngradeAllowed)
        XCTAssertFalse(manifest.rollback.deleteV2EvidenceAllowed)
        XCTAssertFalse(manifest.rollback.replayAmbiguousEffectsAllowed)
        XCTAssertEqual(manifest.determinism.providerCalls, "none")

        let v1ModelNames = Set(NovaForgeSchemaV1.models.map { String(describing: $0) })
        XCTAssertTrue(v1ModelNames.isSuperset(of: [
            "AgentRunRecord",
            "ToolOperationRecord",
            "ProjectOSRun",
            "ProjectOSStep",
            "ChatMessage",
            "ToolRun"
        ]))

        let defaultRecord = AgentRunRecord(
            id: try XCTUnwrap(UUID(uuidString: "10000000-0000-4000-8000-000000000099")),
            now: Date(timeIntervalSince1970: 1_784_000_000)
        )
        XCTAssertEqual(defaultRecord.status, .queued)
        XCTAssertEqual(defaultRecord.origin, .user)
        XCTAssertNil(defaultRecord.provider)
        XCTAssertNil(defaultRecord.modelID)
    }

    func testCanonicalRunFreezesTranscriptEventAndToolOrder() throws {
        let fixture: V1CanonicalRunFixture = try decodeFixture("canonical_mutating_run.json")

        XCTAssertEqual(fixture.formatVersion, 1)
        XCTAssertEqual(fixture.run.engineVersion, "v1")
        XCTAssertTrue(fixture.run.enabledFeatures.isEmpty)
        XCTAssertEqual(fixture.run.responseMessageID, fixture.transcript.last?.id)
        XCTAssertNotNil(UUID(uuidString: fixture.run.id))
        XCTAssertNotNil(UUID(uuidString: fixture.run.conversationID))
        XCTAssertNotNil(UUID(uuidString: fixture.run.projectID))
        XCTAssertNotNil(UUID(uuidString: fixture.run.workspaceID))

        XCTAssertEqual(fixture.run.statusHistory.map(\.status), ["running", "completed"])
        XCTAssertTrue(fixture.run.statusHistory.allSatisfy { AgentRunStatus(rawValue: $0.status) != nil })
        try assertStrictlyIncreasing(fixture.run.statusHistory.map(\.at))

        XCTAssertEqual(fixture.transcript.map(\.sequence), Array(fixture.transcript.indices))
        XCTAssertEqual(
            fixture.transcript.map(\.semanticKind),
            ["request", "toolPlan", "toolReceipt", "toolResult", "finalResponse"]
        )
        XCTAssertEqual(fixture.transcript.map(\.recordKind), ["message", "message", "toolRun", "message", "message"])
        XCTAssertEqual(fixture.transcript.compactMap(\.role), ["user", "assistant", "tool", "assistant"])
        XCTAssertEqual(Set(fixture.transcript.map(\.id)).count, fixture.transcript.count)
        XCTAssertTrue(fixture.transcript.compactMap(\.role).allSatisfy { ChatRole(rawValue: $0) != nil })
        XCTAssertTrue(fixture.transcript.allSatisfy { AgentRunStatus(rawValue: $0.runStatus) == .completed })
        try assertStrictlyIncreasing(fixture.transcript.map(\.createdAt))

        let linkedCallIDs = fixture.transcript.compactMap(\.toolCallID)
        XCTAssertEqual(linkedCallIDs, Array(repeating: fixture.tool.callID, count: 3))
        XCTAssertEqual(fixture.tool.toolRunID, fixture.transcript[2].id)
        XCTAssertEqual(fixture.tool.name, "write_file")
        XCTAssertEqual(fixture.tool.targetPaths, ["README.md"])
        XCTAssertTrue(fixture.tool.isMutating)
        XCTAssertTrue(fixture.tool.requiresApproval)
        XCTAssertEqual(ToolRunStatus(rawValue: fixture.tool.toolRunStatus), .completed)

        let argumentDigest = SHA256.hash(data: Data(fixture.tool.argumentsJSON.utf8)).hexString
        XCTAssertEqual(argumentDigest, fixture.tool.argumentsSHA256)
        XCTAssertEqual(fixture.tool.phaseHistory.map(\.phase), ["scheduled", "executing", "applied", "completed"])
        XCTAssertTrue(fixture.tool.phaseHistory.allSatisfy { ToolOperationPhase(rawValue: $0.phase) != nil })
        try assertStrictlyIncreasing(fixture.tool.phaseHistory.map(\.at))

        XCTAssertEqual(fixture.projectEvents.map(\.sequence), Array(fixture.projectEvents.indices))
        XCTAssertEqual(
            fixture.projectEvents.map(\.kind),
            [
                "promptQueued", "responseSaved", "agentPlanCreated", "missionCheckpoint",
                "toolCompleted", "fileChanged", "responseSaved", "runCompleted",
                "agentProofCreated", "missionCheckpoint"
            ]
        )
        XCTAssertTrue(fixture.projectEvents.allSatisfy { ProjectEventKind(rawValue: $0.kind) != nil })
        XCTAssertTrue(fixture.projectEvents.allSatisfy { ProjectEventSeverity(rawValue: $0.severity) != nil })
        try assertStrictlyIncreasing(fixture.projectEvents.map(\.at))

        XCTAssertTrue(fixture.invariants.acceptanceCommittedBeforeProviderWork)
        XCTAssertTrue(fixture.invariants.operationScheduledBeforeEffect)
        XCTAssertTrue(fixture.invariants.effectAppliedAtMostOnce)
        XCTAssertTrue(fixture.invariants.terminalReceiptAfterEvidence)
        XCTAssertTrue(fixture.invariants.oneRunTimelineClock)
        XCTAssertEqual(fixture.invariants.providerCallsDuringFixtureTest, 0)
    }

    func testProjectOSProjectionAndRelaunchOutcomesStayFrozen() throws {
        let fixture: V1ProjectOSFixture = try decodeFixture("projectos_projection.json")

        XCTAssertNotNil(UUID(uuidString: fixture.runID))
        XCTAssertEqual(ProjectOSRunStatus(rawValue: fixture.successProjection.initialStatus), .planning)
        XCTAssertEqual(fixture.successProjection.events.map(\.sequence), Array(fixture.successProjection.events.indices))
        XCTAssertTrue(fixture.successProjection.events.allSatisfy { ProjectEventKind(rawValue: $0.kind) != nil })
        try assertStrictlyIncreasing(fixture.successProjection.events.map(\.at))

        let projected = fixture.successProjection.expected
        XCTAssertEqual(ProjectOSRunStatus(rawValue: projected.status), .completed)
        XCTAssertEqual(projected.progressEventCount, fixture.successProjection.events.count)
        XCTAssertTrue(projected.currentCommand.contains("xcodebuild test"))
        XCTAssertTrue(projected.proofSummary.contains("tests passed"))
        XCTAssertTrue(projected.allStepsTerminal)
        XCTAssertEqual(ProjectOSStepStatus(rawValue: projected.proofStepStatus), .completed)
        XCTAssertEqual(projected.intentModesInOrder, ["readingContext", "runningTests", "completedProof"])
        XCTAssertTrue(projected.intentModesInOrder.allSatisfy { ProjectOSIntentMode(rawValue: $0) != nil })

        let recovery = fixture.relaunchRecovery
        XCTAssertEqual(ProjectOSRunStatus(rawValue: recovery.before.status), .running)
        XCTAssertTrue(recovery.before.stepStatuses.allSatisfy { ProjectOSStepStatus(rawValue: $0) != nil })
        XCTAssertEqual(ProjectOSRunStatus(rawValue: recovery.expected.status), .stopped)
        XCTAssertEqual(ProjectOSStepStatus(rawValue: recovery.expected.nonterminalStepStatus), .stopped)
        XCTAssertEqual(ProjectOSStepStatus(rawValue: recovery.expected.previouslyCompletedStepStatus), .completed)
        XCTAssertEqual(ProjectOSIntentMode(rawValue: recovery.expected.intentMode), .stoppedResumable)
        XCTAssertEqual(ProjectOSIntentSource(rawValue: recovery.expected.intentSource), .recovery)
        XCTAssertEqual(recovery.expected.completedAt, recovery.at)
        XCTAssertTrue(recovery.expected.resumeState.contains("Stopped after relaunch"))
        XCTAssertFalse(recovery.expected.automaticallyResumed)
    }

    func testRecoveryMatrixRemainsFailClosedAndNonReplaying() throws {
        let fixture: V1RecoveryFixture = try decodeFixture("recovery_matrix.json")

        XCTAssertTrue(fixture.agentRuns.allSatisfy {
            AgentRunStatus(rawValue: $0.before) != nil && AgentRunStatus(rawValue: $0.after) != nil
        })
        XCTAssertEqual(
            fixture.agentRuns.map { "\($0.before)->\($0.after)" },
            ["queued->interrupted", "running->interrupted", "awaitingApproval->interrupted", "completed->completed"]
        )
        XCTAssertTrue(try XCTUnwrap(fixture.agentRuns.first { $0.before == "queued" }).startedAtRemainsNil)
        XCTAssertTrue(try XCTUnwrap(fixture.agentRuns.first { $0.before == "completed" }).terminalStatePreserved)

        XCTAssertTrue(fixture.toolOperations.allSatisfy {
            ToolOperationPhase(rawValue: $0.before) != nil && ToolOperationPhase(rawValue: $0.after) != nil
        })
        XCTAssertEqual(
            fixture.toolOperations.map { "\($0.before)->\($0.after)" },
            ["scheduled->interrupted", "executing->interrupted", "applied->interrupted", "completed->completed"]
        )
        XCTAssertFalse(try XCTUnwrap(fixture.toolOperations.first { $0.before == "scheduled" }).mayHaveApplied)
        XCTAssertTrue(try XCTUnwrap(fixture.toolOperations.first { $0.before == "executing" }).mayHaveApplied)
        XCTAssertTrue(try XCTUnwrap(fixture.toolOperations.first { $0.before == "applied" }).mayHaveApplied)
        XCTAssertTrue(fixture.toolOperations.allSatisfy { !$0.automaticallyReplayed })

        XCTAssertEqual(
            fixture.legacyToolRuns.map { "\($0.before)->\($0.after)" },
            ["pendingApproval->rejected", "approved->failed", "completed->completed"]
        )
        XCTAssertEqual(fixture.legacyToolRuns.compactMap(\.projectEvent), ["toolRejected", "toolFailed"])
        XCTAssertTrue(fixture.legacyToolRuns.compactMap(\.projectEvent).allSatisfy { ProjectEventKind(rawValue: $0) != nil })

        XCTAssertEqual(
            fixture.projectOSRuns.map { "\($0.before)->\($0.after)" },
            ["planning->stopped", "running->stopped", "completed->completed"]
        )
        XCTAssertTrue(fixture.projectOSRuns.allSatisfy {
            ProjectOSRunStatus(rawValue: $0.before) != nil && ProjectOSRunStatus(rawValue: $0.after) != nil
        })
        XCTAssertEqual(fixture.autoContinue.count, 1)
        XCTAssertEqual(fixture.autoContinue[0].before, "countdown")
        XCTAssertEqual(fixture.autoContinue[0].after, "paused")
        XCTAssertTrue(fixture.autoContinue[0].paused)
        XCTAssertFalse(fixture.autoContinue[0].automaticallyStarted)

        XCTAssertTrue(fixture.invariants.lateFetchFailureMutatesNothing)
        XCTAssertTrue(fixture.invariants.ambiguousMutationNeverReplays)
        XCTAssertTrue(fixture.invariants.recoveryIsIdempotent)
        XCTAssertTrue(fixture.invariants.noProviderCall)
    }

    func testV1RoutingFeatureSetDefaultsToEmpty() throws {
        let fixture: V1RoutingFixture = try decodeFixture("routing_defaults.json")

        XCTAssertEqual(fixture.schema.name, "NovaForgeSchemaV1")
        XCTAssertEqual(fixture.schema.version, "1.0.0")
        XCTAssertEqual(fixture.acceptanceDefaults.engineVersion, "v1")
        XCTAssertTrue(fixture.acceptanceDefaults.enabledFeatures.isEmpty)
        XCTAssertEqual(fixture.acceptanceDefaults.executionNode, "onDevice")
        XCTAssertFalse(fixture.acceptanceDefaults.shadowMode)
        XCTAssertFalse(fixture.acceptanceDefaults.activeRunMaySwitchEngine)

        let expectedFlags = [
            "v2DarkReplay", "v2HostedText", "v2ReadTools", "v2MutationTools", "v2Local",
            "v2Worker", "v2MemorySkills", "v2Subagents", "v2MCP", "v2Automation"
        ]
        XCTAssertEqual(Set(fixture.featureFlags.keys), Set(expectedFlags))
        XCTAssertTrue(fixture.featureFlags.values.allSatisfy { !$0 })
        XCTAssertEqual(fixture.rollbackDefaults.newRunsUseEngineVersion, "v1")
        XCTAssertTrue(fixture.rollbackDefaults.activeRunsRetainAcceptedEngine)
        XCTAssertFalse(fixture.rollbackDefaults.deleteEvidence)
        XCTAssertFalse(fixture.rollbackDefaults.downgradeStore)
        XCTAssertFalse(fixture.rollbackDefaults.replayAmbiguousMutation)
    }

    func testCapturedV1StoreOpensWithCurrentMigrationPlan() throws {
        let metadata: V1StoreMetadata = try decodeFixture("NovaForgeV1.store.metadata.json")
        let sourceURL = try fixtureURL("NovaForgeV1.store")
        let sourceData = try Data(contentsOf: sourceURL)

        XCTAssertTrue(metadata.capture.containsOnlySyntheticLaunchFixtures)
        XCTAssertEqual(metadata.sourceApp.bundleIdentifier, "com.joey.NovaForge")
        XCTAssertEqual(metadata.store.schema, "NovaForgeSchemaV1")
        XCTAssertEqual(metadata.store.sqliteQuickCheck, "ok")
        XCTAssertEqual(sourceData.count, metadata.store.byteCount)
        XCTAssertEqual(SHA256.hash(data: sourceData).hexString, metadata.store.sha256)

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NovaForgeV1Store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let storeURL = temporaryDirectory.appendingPathComponent("NovaForge.store")
        try FileManager.default.copyItem(at: sourceURL, to: storeURL)

        let container = try ModelContainer(
            for: Schema(versionedSchema: NovaForgeSchemaV1.self),
            migrationPlan: NovaForgeSchemaMigrationPlan.self,
            configurations: [ModelConfiguration(url: storeURL)]
        )
        let context = ModelContext(container)

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Project>()), metadata.store.rowCounts.projects)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Conversation>()), metadata.store.rowCounts.conversations)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ChatMessage>()), metadata.store.rowCounts.messages)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AgentRunRecord>()), metadata.store.rowCounts.agentRuns)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ProjectEvent>()), metadata.store.rowCounts.projectEvents)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ToolOperationRecord>()), metadata.store.rowCounts.toolOperations)
    }

    func testFixtureSHA256LedgerMatchesBundledBytes() throws {
        let manifest: V1FixtureManifest = try decodeFixture("manifest.json")
        let ledgerData = try fixtureData("SHA256SUMS")
        let ledger = try XCTUnwrap(String(data: ledgerData, encoding: .utf8))
        var entries: [String: String] = [:]

        for line in ledger.split(whereSeparator: \Character.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            XCTAssertEqual(parts.count, 2, "Malformed SHA256SUMS line: \(line)")
            guard parts.count == 2 else { continue }
            let name = String(parts[1]).trimmingCharacters(in: .whitespaces)
            entries[name] = String(parts[0])
        }

        let expectedNames = Set(["manifest.json"] + manifest.files)
        XCTAssertEqual(Set(entries.keys), expectedNames)
        for name in expectedNames.sorted() {
            let data = try fixtureData(name)
            XCTAssertEqual(SHA256.hash(data: data).hexString, entries[name], "Fixture digest changed: \(name)")
        }
    }

    private func decodeFixture<T: Decodable>(_ name: String) throws -> T {
        try JSONDecoder().decode(T.self, from: fixtureData(name))
    }

    private func fixtureData(_ name: String) throws -> Data {
        try Data(contentsOf: fixtureURL(name))
    }

    private func fixtureURL(_ name: String) throws -> URL {
        let bundle = Bundle(for: AgentV1GoldenFixtureTests.self)
        let filename = name as NSString
        let resource = filename.deletingPathExtension
        let extensionName = filename.pathExtension.isEmpty ? nil : filename.pathExtension
        let subdirectories: [String?] = ["Fixtures/AgentHarnessV1", "AgentHarnessV1", nil]
        for subdirectory in subdirectories {
            if let url = bundle.url(forResource: resource, withExtension: extensionName, subdirectory: subdirectory) {
                return url
            }
        }
        throw FixtureReadError.missingBundledResource(name)
    }

    private func assertStrictlyIncreasing(
        _ timestamps: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let dates = try timestamps.map { timestamp in
            try XCTUnwrap(formatter.date(from: timestamp), "Invalid fixture timestamp: \(timestamp)", file: file, line: line)
        }
        XCTAssertTrue(
            zip(dates, dates.dropFirst()).allSatisfy { pair in pair.0 < pair.1 },
            file: file,
            line: line
        )
    }
}

private struct V1StoreMetadata: Decodable {
    struct Capture: Decodable {
        let containsOnlySyntheticLaunchFixtures: Bool
    }

    struct SourceApp: Decodable {
        let bundleIdentifier: String
    }

    struct Store: Decodable {
        struct RowCounts: Decodable {
            let projects: Int
            let conversations: Int
            let messages: Int
            let agentRuns: Int
            let projectEvents: Int
            let toolOperations: Int

            enum CodingKeys: String, CodingKey {
                case projects = "ZPROJECT"
                case conversations = "ZCONVERSATION"
                case messages = "ZCHATMESSAGE"
                case agentRuns = "ZAGENTRUNRECORD"
                case projectEvents = "ZPROJECTEVENT"
                case toolOperations = "ZTOOLOPERATIONRECORD"
            }
        }

        let schema: String
        let sqliteQuickCheck: String
        let byteCount: Int
        let sha256: String
        let rowCounts: RowCounts
    }

    let capture: Capture
    let sourceApp: SourceApp
    let store: Store
}

private enum FixtureReadError: Error, CustomStringConvertible {
    case missingBundledResource(String)

    var description: String {
        switch self {
        case .missingBundledResource(let name):
            "Missing AgentHarnessV1 test-bundle resource: \(name)"
        }
    }
}

private extension Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

private struct V1FixtureManifest: Decodable {
    struct Source: Decodable {
        let baseCommit: String
        let baseCommitSubject: String
        let captureState: String
        let plan: String
    }

    struct Compatibility: Decodable {
        let swiftDataSchema: String
        let schemaVersion: String
        let engineVersion: String
        let eventEncodingVersion: Int
        let minimumFixtureReaderVersion: Int
    }

    struct Routing: Decodable {
        let defaultEngineVersion: String
        let enabledFeatures: [String]
        let activeRunRoutingIsImmutable: Bool
    }

    struct Determinism: Decodable {
        let clock: String
        let identifiers: String
        let providerCalls: String
        let workspaceEffects: String
    }

    struct Rollback: Decodable {
        let referenceCommit: String
        let engineForNewRuns: String
        let databaseDowngradeAllowed: Bool
        let deleteV2EvidenceAllowed: Bool
        let replayAmbiguousEffectsAllowed: Bool
    }

    struct Integrity: Decodable {
        let algorithm: String
        let ledger: String
        let manifestIsCovered: Bool
    }

    let formatVersion: Int
    let fixtureSet: String
    let capturedAt: String
    let source: Source
    let compatibility: Compatibility
    let routing: Routing
    let determinism: Determinism
    let rollback: Rollback
    let files: [String]
    let integrity: Integrity
}

private struct V1CanonicalRunFixture: Decodable {
    struct Run: Decodable {
        let id: String
        let conversationID: String
        let projectID: String
        let workspaceID: String
        let requestMessageID: String
        let responseMessageID: String
        let origin: String
        let provider: String
        let modelID: String
        let engineVersion: String
        let enabledFeatures: [String]
        let statusHistory: [StatusEntry]
    }

    struct StatusEntry: Decodable {
        let status: String
        let at: String
    }

    struct TimelineEntry: Decodable {
        let sequence: Int
        let recordKind: String
        let id: String
        let role: String?
        let semanticKind: String
        let toolCallID: String?
        let runStatus: String
        let createdAt: String
    }

    struct EventEntry: Decodable {
        let sequence: Int
        let kind: String
        let severity: String
        let at: String
    }

    struct Tool: Decodable {
        let toolRunID: String
        let operationID: String
        let callID: String
        let name: String
        let argumentsJSON: String
        let argumentsSHA256: String
        let targetPaths: [String]
        let isMutating: Bool
        let requiresApproval: Bool
        let toolRunStatus: String
        let resultSummary: String
        let phaseHistory: [PhaseEntry]
    }

    struct PhaseEntry: Decodable {
        let phase: String
        let at: String
    }

    struct Invariants: Decodable {
        let acceptanceCommittedBeforeProviderWork: Bool
        let operationScheduledBeforeEffect: Bool
        let effectAppliedAtMostOnce: Bool
        let terminalReceiptAfterEvidence: Bool
        let oneRunTimelineClock: Bool
        let providerCallsDuringFixtureTest: Int
    }

    let formatVersion: Int
    let caseName: String
    let run: Run
    let transcript: [TimelineEntry]
    let projectEvents: [EventEntry]
    let tool: Tool
    let invariants: Invariants
}

private struct V1ProjectOSFixture: Decodable {
    struct SuccessProjection: Decodable {
        struct Expected: Decodable {
            let status: String
            let progressEventCount: Int
            let currentCommand: String
            let proofSummary: String
            let allStepsTerminal: Bool
            let proofStepStatus: String
            let intentModesInOrder: [String]
        }

        let initialStatus: String
        let events: [V1CanonicalRunFixture.EventEntry]
        let expected: Expected
    }

    struct RelaunchRecovery: Decodable {
        struct Before: Decodable {
            let status: String
            let stepStatuses: [String]
            let intentMode: String
        }

        struct Expected: Decodable {
            let status: String
            let nonterminalStepStatus: String
            let previouslyCompletedStepStatus: String
            let intentMode: String
            let intentSource: String
            let resumeState: String
            let completedAt: String
            let automaticallyResumed: Bool
        }

        let at: String
        let before: Before
        let expected: Expected
    }

    let formatVersion: Int
    let caseName: String
    let runID: String
    let projectID: String
    let sourceConversationID: String
    let successProjection: SuccessProjection
    let relaunchRecovery: RelaunchRecovery
}

private struct V1RecoveryFixture: Decodable {
    struct AgentRun: Decodable {
        let before: String
        let after: String
        let startedAtRemainsNil: Bool
        let terminalStatePreserved: Bool
    }

    struct ToolOperation: Decodable {
        let before: String
        let after: String
        let startedAtRemainsNil: Bool
        let mayHaveApplied: Bool
        let automaticallyReplayed: Bool
        let diagnosticContains: String
    }

    struct LegacyToolRun: Decodable {
        let before: String
        let after: String
        let projectEvent: String?
    }

    struct ProjectOSRun: Decodable {
        let before: String
        let after: String
        let nonterminalStepsAfter: String?
    }

    struct AutoContinue: Decodable {
        let before: String
        let after: String
        let paused: Bool
        let automaticallyStarted: Bool
    }

    struct Invariants: Decodable {
        let lateFetchFailureMutatesNothing: Bool
        let ambiguousMutationNeverReplays: Bool
        let recoveryIsIdempotent: Bool
        let noProviderCall: Bool
    }

    let formatVersion: Int
    let caseName: String
    let recoveredAt: String
    let agentRuns: [AgentRun]
    let toolOperations: [ToolOperation]
    let legacyToolRuns: [LegacyToolRun]
    let projectOSRuns: [ProjectOSRun]
    let autoContinue: [AutoContinue]
    let invariants: Invariants
}

private struct V1RoutingFixture: Decodable {
    struct Schema: Decodable {
        let name: String
        let version: String
    }

    struct AcceptanceDefaults: Decodable {
        let engineVersion: String
        let enabledFeatures: [String]
        let executionNode: String
        let shadowMode: Bool
        let activeRunMaySwitchEngine: Bool
    }

    struct RollbackDefaults: Decodable {
        let newRunsUseEngineVersion: String
        let activeRunsRetainAcceptedEngine: Bool
        let deleteEvidence: Bool
        let downgradeStore: Bool
        let replayAmbiguousMutation: Bool
    }

    let formatVersion: Int
    let caseName: String
    let schema: Schema
    let acceptanceDefaults: AcceptanceDefaults
    let featureFlags: [String: Bool]
    let rollbackDefaults: RollbackDefaults
}
