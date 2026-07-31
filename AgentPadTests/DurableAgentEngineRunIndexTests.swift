import AgentDomain
import AgentEngine
import Darwin
import Dispatch
import Foundation
import XCTest
@testable import NovaForge

final class DurableAgentEngineRunIndexTests: XCTestCase {
    func testCompleteProtectionPostconditionIsStrictOutsideSimulatorFallback()
    {
        XCTAssertTrue(
            AgentCompleteDataProtection.satisfiesPostcondition(
                FileProtectionType.complete
            )
        )
        #if targetEnvironment(simulator)
        XCTAssertTrue(
            AgentCompleteDataProtection.satisfiesPostcondition(
                FileProtectionType.completeUntilFirstUserAuthentication
            )
        )
        XCTAssertTrue(
            AgentCompleteDataProtection.satisfiesPostcondition(nil)
        )
        #else
        XCTAssertFalse(
            AgentCompleteDataProtection.satisfiesPostcondition(
                FileProtectionType.completeUntilFirstUserAuthentication
            )
        )
        XCTAssertFalse(
            AgentCompleteDataProtection.satisfiesPostcondition(nil)
        )
        #endif
    }

    #if targetEnvironment(simulator)
    func testSimulatorProductionStorePathAcceptsCoercedCompleteProtection()
        throws
    {
        let paths: AgentEngineRunIndexStorePaths
        do {
            paths = try AgentEngineRunIndexStorePaths.prepare()
        } catch {
            let support = try XCTUnwrap(
                FileManager.default.urls(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask
                ).first
            )
            let engine = support.appendingPathComponent("AgentEngine")
            let attributes = try FileManager.default.attributesOfItem(
                atPath: engine.path
            )
            XCTFail(
                "Production path rejected simulator protection value "
                    + "\(String(describing: attributes[.protectionKey])); "
                    + "error: \(error)"
            )
            return
        }

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: paths.versionDirectory.path
            )
        )
        XCTAssertTrue(
            try paths.versionDirectory.resourceValues(
                forKeys: [.isExcludedFromBackupKey]
            ).isExcludedFromBackup == true
        )
        let attributes = try FileManager.default.attributesOfItem(
            atPath: paths.versionDirectory.path
        )
        XCTAssertTrue(
            AgentCompleteDataProtection.satisfiesPostcondition(
                attributes[.protectionKey]
            )
        )
    }
    #endif

    func testStorePathDirectoryCreateRaceAcceptsOnlyWinningDirectory() throws {
        let root = try RunIndexDiskFixture.makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("Application Support")
        try FileManager.default.createDirectory(
            at: support,
            withIntermediateDirectories: false
        )
        let manager = RunIndexDirectoryRaceFileManager(
            supportURL: support,
            winner: .directory
        )

        let paths = try AgentEngineRunIndexStorePaths.prepare(
            fileManager: manager
        )

        XCTAssertEqual(
            paths.applicationSupportDirectory.standardizedFileURL.path,
            support.standardizedFileURL.path
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: paths.engineDirectory.path)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: paths.versionDirectory.path)
        )
    }

    func testStorePathDirectoryCreateRaceRejectsWinningRegularFile() throws {
        let root = try RunIndexDiskFixture.makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("Application Support")
        try FileManager.default.createDirectory(
            at: support,
            withIntermediateDirectories: false
        )
        let manager = RunIndexDirectoryRaceFileManager(
            supportURL: support,
            winner: .regularFile
        )

        XCTAssertThrowsError(
            try AgentEngineRunIndexStorePaths.prepare(fileManager: manager)
        ) { error in
            XCTAssertEqual(
                error as? AgentEngineRunIndexStorePathError,
                .invalidEntryType
            )
        }
    }

    func testClaimPersistsAcrossReopenAndRecoveryFencesOldOwner() async throws {
        let fixture = try RunIndexDiskFixture()
        defer { fixture.remove() }
        let runID: RunID = runIndexTagged(1)
        let first = try DurableAgentEngineRunIndex(fileURL: fixture.ledgerURL)
        let fence1 = try await first.claim(
            runID: runID,
            ownerID: runIndexUUID(11),
            mode: .newRun
        )

        let reopened = try DurableAgentEngineRunIndex(fileURL: fixture.ledgerURL)
        try await reopened.validate(fence1)
        let fence2 = try await reopened.claim(
            runID: runID,
            ownerID: runIndexUUID(12),
            mode: .recovery
        )

        XCTAssertEqual(fence1.generation, 1)
        XCTAssertEqual(fence2.generation, 2)
        await assertRunIndexError(.staleOwner(fence1)) {
            try await first.validate(fence1)
        }
        try await first.validate(fence2)
    }

    func testAbandonRetainsGenerationTombstoneAndFreshClaimAdvancesIt() async throws {
        let fixture = try RunIndexDiskFixture()
        defer { fixture.remove() }
        let runID: RunID = runIndexTagged(2)
        let index = try DurableAgentEngineRunIndex(fileURL: fixture.ledgerURL)
        let first = try await index.claim(
            runID: runID,
            ownerID: runIndexUUID(21),
            mode: .newRun
        )
        try await index.abandonDurably(first)

        await assertRunIndexError(.staleOwner(first)) {
            try await index.validate(first)
        }
        let second = try await index.claim(
            runID: runID,
            ownerID: runIndexUUID(22),
            mode: .newRun
        )
        XCTAssertEqual(second.generation, 2)
        let persistedSecond = try await index.persistedFence(for: runID)
        XCTAssertEqual(persistedSecond, second)
        let reopened = try DurableAgentEngineRunIndex(fileURL: fixture.ledgerURL)
        try await reopened.validate(second)
    }

    func testTerminalSettlementIsExactIdempotentAndPermanentlyFenced() async throws {
        let fixture = try RunIndexDiskFixture()
        defer { fixture.remove() }
        let runID: RunID = runIndexTagged(3)
        let index = try DurableAgentEngineRunIndex(fileURL: fixture.ledgerURL)
        let fence = try await index.claim(
            runID: runID,
            ownerID: runIndexUUID(31),
            mode: .newRun
        )
        let terminal = AgentEngineTerminalRecord(
            runID: runID,
            fence: fence,
            phase: .completed,
            terminalEventID: runIndexTagged(32)
        )

        try await index.settle(terminal)
        try await index.settle(terminal)
        let indexedTerminal = try await index.terminalRecord(for: runID)
        XCTAssertEqual(indexedTerminal, terminal)
        await assertRunIndexError(.staleOwner(fence)) {
            try await index.validate(fence)
        }

        let conflicting = AgentEngineTerminalRecord(
            runID: runID,
            fence: fence,
            phase: .failed,
            terminalEventID: runIndexTagged(33)
        )
        await assertRunIndexError(.runAlreadyTerminal(runID)) {
            try await index.settle(conflicting)
        }
        await assertRunIndexError(.runAlreadyTerminal(runID)) {
            _ = try await index.claim(
                runID: runID,
                ownerID: runIndexUUID(34),
                mode: .recovery
            )
        }

        let reopened = try DurableAgentEngineRunIndex(fileURL: fixture.ledgerURL)
        let reopenedTerminal = try await reopened.terminalRecord(for: runID)
        XCTAssertEqual(reopenedTerminal, terminal)
    }

    func testNonterminalSettlementIsRejectedWithoutChangingOwner() async throws {
        let fixture = try RunIndexDiskFixture()
        defer { fixture.remove() }
        let runID: RunID = runIndexTagged(4)
        let index = try DurableAgentEngineRunIndex(fileURL: fixture.ledgerURL)
        let fence = try await index.claim(
            runID: runID,
            ownerID: runIndexUUID(41),
            mode: .newRun
        )
        let invalid = AgentEngineTerminalRecord(
            runID: runID,
            fence: fence,
            phase: .running,
            terminalEventID: runIndexTagged(42)
        )

        await assertRunIndexError(.invalidTerminalPhase(.running)) {
            try await index.settle(invalid)
        }
        try await index.validate(fence)
        let terminal = try await index.terminalRecord(for: runID)
        XCTAssertNil(terminal)
    }

    func testSnapshotEnumeratesExactActiveAbandonedAndTerminalState() async throws {
        let fixture = try RunIndexDiskFixture()
        defer { fixture.remove() }
        let index = try DurableAgentEngineRunIndex(fileURL: fixture.ledgerURL)

        let active = try await index.claim(
            runID: runIndexTagged(101),
            ownerID: runIndexUUID(1_001),
            mode: .newRun
        )
        let abandoned = try await index.claim(
            runID: runIndexTagged(102),
            ownerID: runIndexUUID(1_002),
            mode: .newRun
        )
        try await index.abandonDurably(abandoned)
        let terminalFence = try await index.claim(
            runID: runIndexTagged(103),
            ownerID: runIndexUUID(1_003),
            mode: .newRun
        )
        let terminal = AgentEngineTerminalRecord(
            runID: terminalFence.runID,
            fence: terminalFence,
            phase: .completed,
            terminalEventID: runIndexTagged(1_004)
        )
        try await index.settle(terminal)

        let snapshot = try await index.snapshot()

        XCTAssertEqual(snapshot.ledgerGeneration, 5)
        XCTAssertEqual(snapshot.entries.map(\.runID), [
            active.runID,
            abandoned.runID,
            terminalFence.runID,
        ])
        XCTAssertEqual(snapshot.entries.map(\.fence), [
            active,
            abandoned,
            terminalFence,
        ])
        XCTAssertEqual(snapshot.entries.map(\.state), [
            .active,
            .abandoned,
            .terminal(terminal),
        ])
        XCTAssertEqual(snapshot.capacity.usedEntryCount, 3)
        XCTAssertEqual(snapshot.capacity.maximumEntryCount, 65_536)
        XCTAssertEqual(snapshot.capacity.remainingEntryCount, 65_533)
        XCTAssertFalse(snapshot.capacity.isExhausted)
    }

    func testPreRenameFaultReturnsNoFenceAndLeavesOldLedgerCanonical() async throws {
        let fixture = try RunIndexDiskFixture()
        defer { fixture.remove() }
        let faulting = try DurableAgentEngineRunIndex(
            fileURL: fixture.ledgerURL,
            faultInjector: { point in
                if case .afterFileSyncBeforeRename = point {
                    throw RunIndexInjectedFault()
                }
            }
        )
        let runID: RunID = runIndexTagged(5)

        do {
            _ = try await faulting.claim(
                runID: runID,
                ownerID: runIndexUUID(51),
                mode: .newRun
            )
            XCTFail("Faulting claim unexpectedly returned authority")
        } catch {
            XCTAssertTrue(error is RunIndexInjectedFault)
        }

        let reopened = try DurableAgentEngineRunIndex(fileURL: fixture.ledgerURL)
        let absentFence = try await reopened.persistedFence(for: runID)
        XCTAssertNil(absentFence)
        let fence = try await reopened.claim(
            runID: runID,
            ownerID: runIndexUUID(52),
            mode: .newRun
        )
        XCTAssertEqual(fence.generation, 1)
    }

    func testPostRenameFaultLeavesCommittedActiveOrphanObservable() async throws {
        let fixture = try RunIndexDiskFixture()
        defer { fixture.remove() }
        let faulting = try DurableAgentEngineRunIndex(
            fileURL: fixture.ledgerURL,
            faultInjector: { point in
                if case .afterRenameBeforeDirectorySync = point {
                    throw RunIndexInjectedFault()
                }
            }
        )
        let runID: RunID = runIndexTagged(105)
        let ownerID = runIndexUUID(1_051)

        do {
            _ = try await faulting.claim(
                runID: runID,
                ownerID: ownerID,
                mode: .newRun
            )
            XCTFail("Post-rename fault unexpectedly returned authority")
        } catch {
            XCTAssertTrue(error is RunIndexInjectedFault)
        }

        let reopened = try DurableAgentEngineRunIndex(fileURL: fixture.ledgerURL)
        let snapshot = try await reopened.snapshot()
        let orphan = try XCTUnwrap(snapshot.entries.first)
        XCTAssertEqual(snapshot.ledgerGeneration, 1)
        XCTAssertEqual(snapshot.entries.count, 1)
        XCTAssertEqual(orphan.runID, runID)
        XCTAssertEqual(orphan.fence.ownerID, ownerID)
        XCTAssertEqual(orphan.fence.generation, 1)
        XCTAssertEqual(orphan.state, .active)
    }

    func testPartialFirstOpenMarkerRecoversOnlyFromValidatedLedger() async throws {
        let fixture = try RunIndexDiskFixture()
        defer { fixture.remove() }
        let first = try DurableAgentEngineRunIndex(fileURL: fixture.ledgerURL)
        let fence = try await first.claim(
            runID: runIndexTagged(106),
            ownerID: runIndexUUID(1_061),
            mode: .newRun
        )
        let partialMarker = Data(
            "novaforge-agent-engine-run-index-v1|00000000-0000".utf8
        )
        try overwriteRunIndexFile(fixture.lockURL, with: partialMarker)

        let recovered = try DurableAgentEngineRunIndex(fileURL: fixture.ledgerURL)
        try await recovered.validate(fence)
        let snapshot = try await recovered.snapshot()
        let repairedMarker = try Data(contentsOf: fixture.lockURL)

        XCTAssertEqual(
            repairedMarker,
            runIndexLockMarker(storeID: snapshot.storeID)
        )
        XCTAssertNotEqual(repairedMarker, partialMarker)
    }

    func testPartialFirstOpenMarkerDoesNotBlessChecksumCorruption() async throws {
        let fixture = try RunIndexDiskFixture()
        defer { fixture.remove() }
        let first = try DurableAgentEngineRunIndex(fileURL: fixture.ledgerURL)
        _ = try await first.claim(
            runID: runIndexTagged(107),
            ownerID: runIndexUUID(1_071),
            mode: .newRun
        )
        let partialMarker = Data(
            "novaforge-agent-engine-run-index-v1|00000000-0000".utf8
        )
        try overwriteRunIndexFile(fixture.lockURL, with: partialMarker)
        let validLedger = try Data(contentsOf: fixture.ledgerURL)
        try overwriteRunIndexFile(
            fixture.ledgerURL,
            with: try corruptRunIndexEnvelopeChecksum(validLedger)
        )

        do {
            _ = try DurableAgentEngineRunIndex(fileURL: fixture.ledgerURL)
            XCTFail("Checksum-corrupt ledger unexpectedly repaired its marker")
        } catch let error as DurableAgentEngineRunIndexError {
            XCTAssertEqual(error, .corruptEnvelope)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.lockURL), partialMarker)
    }

    func testStaleCrashTemporaryCannotBrickLaterCommits() async throws {
        let fixture = try RunIndexDiskFixture()
        defer { fixture.remove() }
        let staleTemporary = fixture.directory.appendingPathComponent(
            ".run-index.ledger.abandoned-crash.tmp"
        )
        try Data("partial".utf8).write(to: staleTemporary)

        let index = try DurableAgentEngineRunIndex(fileURL: fixture.ledgerURL)
        let fence = try await index.claim(
            runID: runIndexTagged(55),
            ownerID: runIndexUUID(551),
            mode: .newRun
        )

        XCTAssertEqual(fence.generation, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staleTemporary.path))
        try await index.validate(fence)
    }

    func testCorruptionAndObservedGenerationRollbackFailClosed() async throws {
        let fixture = try RunIndexDiskFixture()
        defer { fixture.remove() }
        let runID: RunID = runIndexTagged(6)
        let index = try DurableAgentEngineRunIndex(fileURL: fixture.ledgerURL)
        let initialLedger = try Data(contentsOf: fixture.ledgerURL)
        let first = try await index.claim(
            runID: runID,
            ownerID: runIndexUUID(61),
            mode: .newRun
        )
        _ = try await index.claim(
            runID: runID,
            ownerID: runIndexUUID(62),
            mode: .recovery
        )

        try overwriteRunIndexFile(fixture.ledgerURL, with: initialLedger)
        await assertDurableRunIndexError(.generationRollback) {
            try await index.validate(first)
        }

        var corrupt = initialLedger
        corrupt[corrupt.startIndex] ^= 0xff
        try overwriteRunIndexFile(fixture.ledgerURL, with: corrupt)
        do {
            _ = try DurableAgentEngineRunIndex(fileURL: fixture.ledgerURL)
            XCTFail("Corrupt ledger unexpectedly reopened")
        } catch let error as DurableAgentEngineRunIndexError {
            XCTAssertEqual(error, .corruptEnvelope)
        }
    }

    func testSymlinkAndHardLinkLedgerAliasesAreRejected() async throws {
        let fixture = try RunIndexDiskFixture()
        defer { fixture.remove() }
        _ = try DurableAgentEngineRunIndex(fileURL: fixture.ledgerURL)
        let symbolic = fixture.directory.appendingPathComponent("symbolic.ledger")
        try FileManager.default.createSymbolicLink(
            at: symbolic,
            withDestinationURL: fixture.ledgerURL
        )
        do {
            _ = try DurableAgentEngineRunIndex(fileURL: symbolic)
            XCTFail("Symbolic-link ledger unexpectedly opened")
        } catch let error as DurableAgentEngineRunIndexError {
            XCTAssertEqual(error, .invalidFileIdentity)
        }

        try FileManager.default.removeItem(at: symbolic)
        let hard = fixture.directory.appendingPathComponent("hard.ledger")
        try FileManager.default.linkItem(at: fixture.ledgerURL, to: hard)
        do {
            _ = try DurableAgentEngineRunIndex(fileURL: hard)
            XCTFail("Hard-link ledger unexpectedly opened")
        } catch let error as DurableAgentEngineRunIndexError {
            XCTAssertEqual(error, .invalidFileIdentity)
        }
    }

    func testDirectoryPathSubstitutionIsRejectedByPinnedIdentity() async throws {
        let root = try RunIndexDiskFixture.makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let live = root.appendingPathComponent("live", isDirectory: true)
        try FileManager.default.createDirectory(
            at: live,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let ledger = live.appendingPathComponent("run-index.ledger")
        let index = try DurableAgentEngineRunIndex(fileURL: ledger)
        let runID: RunID = runIndexTagged(7)
        let fence = try await index.claim(
            runID: runID,
            ownerID: runIndexUUID(71),
            mode: .newRun
        )
        let moved = root.appendingPathComponent("moved", isDirectory: true)
        try FileManager.default.moveItem(at: live, to: moved)
        try FileManager.default.createDirectory(
            at: live,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        for name in ["run-index.ledger", ".run-index.ledger.lock"] {
            try FileManager.default.copyItem(
                at: moved.appendingPathComponent(name),
                to: live.appendingPathComponent(name)
            )
        }

        await assertDurableRunIndexError(.invalidFileIdentity) {
            try await index.validate(fence)
        }
    }

    func testProcessLockWaitIsBoundedAcrossLiveInstances() async throws {
        let fixture = try RunIndexDiskFixture()
        defer { fixture.remove() }
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let holding = try DurableAgentEngineRunIndex(
            fileURL: fixture.ledgerURL,
            lockTimeoutMilliseconds: 1_000,
            faultInjector: { point in
                if case .afterFileSyncBeforeRename = point {
                    entered.signal()
                    _ = release.wait(timeout: .now() + .seconds(2))
                }
            }
        )
        let contending = try DurableAgentEngineRunIndex(
            fileURL: fixture.ledgerURL,
            lockTimeoutMilliseconds: 10
        )
        let runID: RunID = runIndexTagged(8)
        let claim = Task {
            try await holding.claim(
                runID: runID,
                ownerID: runIndexUUID(81),
                mode: .newRun
            )
        }
        XCTAssertEqual(
            entered.wait(timeout: .now() + .seconds(1)),
            .success
        )
        await assertDurableRunIndexError(.lockUnavailable) {
            try await contending.persistedFence(for: runID)
        }
        release.signal()
        let fence = try await claim.value
        XCTAssertEqual(fence.generation, 1)
    }
}

private struct RunIndexDiskFixture {
    let directory: URL
    let ledgerURL: URL

    var lockURL: URL {
        directory.appendingPathComponent(".\(ledgerURL.lastPathComponent).lock")
    }

    init() throws {
        directory = try Self.makeDirectory()
        ledgerURL = directory.appendingPathComponent("run-index.ledger")
    }

    static func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "NovaForgeRunIndexTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return url
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class RunIndexDirectoryRaceFileManager: FileManager,
    @unchecked Sendable
{
    enum Winner {
        case directory
        case regularFile
    }

    private let supportURL: URL
    private let winner: Winner
    private var didInjectRace = false
    private var protectedPaths: Set<String> = []

    init(supportURL: URL, winner: Winner) {
        self.supportURL = supportURL
        self.winner = winner
        super.init()
    }

    override func urls(
        for directory: FileManager.SearchPathDirectory,
        in domainMask: FileManager.SearchPathDomainMask
    ) -> [URL] {
        [supportURL]
    }

    override func createDirectory(
        at url: URL,
        withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]? = nil
    ) throws {
        if !didInjectRace,
           url.standardizedFileURL.path
            == supportURL.appendingPathComponent(
                "AgentEngine",
                isDirectory: true
            ).standardizedFileURL.path
        {
            didInjectRace = true
            switch winner {
            case .directory:
                try super.createDirectory(
                    at: url,
                    withIntermediateDirectories: createIntermediates,
                    attributes: attributes
                )
            case .regularFile:
                guard FileManager.default.createFile(
                    atPath: url.path,
                    contents: Data(),
                    attributes: [.posixPermissions: 0o600]
                ) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            throw CocoaError(.fileWriteFileExists)
        }
        try super.createDirectory(
            at: url,
            withIntermediateDirectories: createIntermediates,
            attributes: attributes
        )
    }

    override func setAttributes(
        _ attributes: [FileAttributeKey: Any],
        ofItemAtPath path: String
    ) throws {
        try super.setAttributes(attributes, ofItemAtPath: path)
        let rawProtection = attributes[.protectionKey]
        let isComplete = (rawProtection as? FileProtectionType) == .complete
            || (rawProtection as? String)
                == FileProtectionType.complete.rawValue
        if isComplete {
            protectedPaths.insert(
                URL(fileURLWithPath: path).standardizedFileURL.path
            )
        }
    }

    override func attributesOfItem(
        atPath path: String
    ) throws -> [FileAttributeKey: Any] {
        var attributes = try super.attributesOfItem(atPath: path)
        if protectedPaths.contains(
            URL(fileURLWithPath: path).standardizedFileURL.path
        ) {
            attributes[.protectionKey] = FileProtectionType.complete
        }
        return attributes
    }
}

private struct RunIndexInjectedFault: Error {}

private enum RunIndexTestFixtureError: Error {
    case checksumFieldMissing
}

private func runIndexUUID(_ value: UInt64) -> UUID {
    UUID(
        uuidString: String(
            format: "00000000-0000-0000-0000-%012llX",
            value
        )
    )!
}

private func runIndexTagged<Tag: AgentIdentifierTag>(
    _ value: UInt64
) -> AgentIdentifier<Tag> {
    AgentIdentifier(rawValue: runIndexUUID(value))
}

private func overwriteRunIndexFile(_ url: URL, with data: Data) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.truncate(atOffset: 0)
    try handle.write(contentsOf: data)
    try handle.synchronize()
}

private func runIndexLockMarker(storeID: UUID) -> Data {
    Data(
        "novaforge-agent-engine-run-index-v1|\(storeID.uuidString.lowercased())\n"
            .utf8
    )
}

private func corruptRunIndexEnvelopeChecksum(_ data: Data) throws -> Data {
    guard var value = String(data: data, encoding: .utf8),
          let field = value.range(of: "\"envelopeSHA256\":\"")
    else { throw RunIndexTestFixtureError.checksumFieldMissing }
    let digestStart = field.upperBound
    guard digestStart < value.endIndex else {
        throw RunIndexTestFixtureError.checksumFieldMissing
    }
    let replacement = value[digestStart] == "0" ? "1" : "0"
    value.replaceSubrange(digestStart ... digestStart, with: replacement)
    return Data(value.utf8)
}

private func assertRunIndexError<T: Sendable>(
    _ expected: AgentEngineRunIndexError,
    operation: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await operation()
        XCTFail("Expected run-index error", file: file, line: line)
    } catch let error as AgentEngineRunIndexError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("Unexpected error: \(error)", file: file, line: line)
    }
}

private func assertDurableRunIndexError<T: Sendable>(
    _ expected: DurableAgentEngineRunIndexError,
    operation: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await operation()
        XCTFail("Expected durable run-index error", file: file, line: line)
    } catch let error as DurableAgentEngineRunIndexError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("Unexpected error: \(error)", file: file, line: line)
    }
}
