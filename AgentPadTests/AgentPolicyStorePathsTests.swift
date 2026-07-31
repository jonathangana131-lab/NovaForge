import XCTest
@testable import NovaForge

final class AgentPolicyStorePathsTests: XCTestCase {
    func testPrepareBuildsDeterministicProtectedVersionedLayout() throws {
        let support = URL(
            fileURLWithPath: "/sandbox/Application Support",
            isDirectory: true
        )
        let fileSystem = PolicyStoreFileSystemFixture(support: support)

        let paths = try AgentPolicyStorePaths.prepare(fileSystem: fileSystem)

        XCTAssertEqual(paths.applicationSupportDirectory, support)
        XCTAssertEqual(
            paths.policyDirectory.path,
            "/sandbox/Application Support/AgentPolicy"
        )
        XCTAssertEqual(
            paths.versionDirectory.path,
            "/sandbox/Application Support/AgentPolicy/v1"
        )
        XCTAssertEqual(
            paths.checkpointDirectory.path,
            "/sandbox/Application Support/AgentPolicy/v1/checkpoints"
        )
        XCTAssertEqual(
            paths.policyAuthorityLedgerURL.path,
            "/sandbox/Application Support/AgentPolicy/v1/policy-authority.ledger"
        )
        XCTAssertEqual(
            paths.mutationEffectLifecycleLedgerURL.path,
            "/sandbox/Application Support/AgentPolicy/v1/mutation-effect-lifecycle.ledger"
        )
        XCTAssertEqual(
            fileSystem.createdDirectories.map(\.path),
            [
                paths.policyDirectory.path,
                paths.versionDirectory.path,
                paths.checkpointDirectory.path,
            ]
        )
        XCTAssertEqual(
            fileSystem.creationProtections,
            [.complete, .complete, .complete]
        )
        for directory in [
            paths.policyDirectory,
            paths.versionDirectory,
            paths.checkpointDirectory,
        ] {
            XCTAssertEqual(fileSystem.protections[directory.path], .complete)
            XCTAssertEqual(fileSystem.backupExclusions[directory.path], true)
        }
    }

    func testPrepareIsIdempotentAndNeverCreatesLedgerFiles() throws {
        let support = URL(fileURLWithPath: "/app/support", isDirectory: true)
        let fileSystem = PolicyStoreFileSystemFixture(support: support)

        let first = try AgentPolicyStorePaths.prepare(fileSystem: fileSystem)
        fileSystem.createdDirectories.removeAll()
        let second = try AgentPolicyStorePaths.prepare(fileSystem: fileSystem)

        XCTAssertEqual(first, second)
        XCTAssertTrue(fileSystem.createdDirectories.isEmpty)
        XCTAssertEqual(
            fileSystem.kinds[first.policyAuthorityLedgerURL.path],
            nil
        )
        XCTAssertEqual(
            fileSystem.kinds[first.mutationEffectLifecycleLedgerURL.path],
            nil
        )
    }

    func testInvalidOrMissingApplicationSupportFailsClosed() {
        let invalidURLs = [
            URL(string: "https://example.invalid/support")!,
            URL(fileURLWithPath: "/", isDirectory: true),
        ]

        for url in invalidURLs {
            let fileSystem = PolicyStoreFileSystemFixture(support: url)
            assertPathError(.invalidApplicationSupportDirectory) {
                _ = try AgentPolicyStorePaths.prepare(fileSystem: fileSystem)
            }
        }

        let missing = PolicyStoreFileSystemFixture(
            support: URL(fileURLWithPath: "/missing/support", isDirectory: true),
            supportKind: .missing
        )
        assertPathError(.invalidApplicationSupportDirectory) {
            _ = try AgentPolicyStorePaths.prepare(fileSystem: missing)
        }
    }

    func testSymlinksAtEveryOwnedBoundaryAreRejected() throws {
        let support = URL(fileURLWithPath: "/app/support", isDirectory: true)
        let canonicalPolicy = support.appendingPathComponent("AgentPolicy")
        let canonicalVersion = canonicalPolicy.appendingPathComponent("v1")
        let checkpoints = canonicalVersion.appendingPathComponent("checkpoints")
        let authority = canonicalVersion.appendingPathComponent(
            "policy-authority.ledger"
        )
        let mutation = canonicalVersion.appendingPathComponent(
            "mutation-effect-lifecycle.ledger"
        )

        for attackedPath in [
            support.path,
            canonicalPolicy.path,
            canonicalVersion.path,
            checkpoints.path,
            authority.path,
            mutation.path,
        ] {
            let fileSystem = PolicyStoreFileSystemFixture(support: support)
            fileSystem.kinds[canonicalPolicy.path] = .directory
            fileSystem.kinds[canonicalVersion.path] = .directory
            fileSystem.kinds[checkpoints.path] = .directory
            fileSystem.kinds[attackedPath] = .symbolicLink

            assertPathError(.symbolicLinkRejected) {
                _ = try AgentPolicyStorePaths.prepare(fileSystem: fileSystem)
            }
        }
    }

    func testUnexpectedFilesAndDirectoriesAtReservedLocationsAreRejected() {
        let support = URL(fileURLWithPath: "/app/support", isDirectory: true)
        let policy = support.appendingPathComponent("AgentPolicy")
        let version = policy.appendingPathComponent("v1")

        let fileAtDirectory = PolicyStoreFileSystemFixture(support: support)
        fileAtDirectory.kinds[policy.path] = .regularFile
        assertPathError(.invalidEntryType) {
            _ = try AgentPolicyStorePaths.prepare(fileSystem: fileAtDirectory)
        }

        let directoryAtLedger = PolicyStoreFileSystemFixture(support: support)
        directoryAtLedger.kinds[policy.path] = .directory
        directoryAtLedger.kinds[version.path] = .directory
        directoryAtLedger.kinds[
            version.appendingPathComponent("policy-authority.ledger").path
        ] = .directory
        assertPathError(.invalidEntryType) {
            _ = try AgentPolicyStorePaths.prepare(fileSystem: directoryAtLedger)
        }
    }

    func testCreationPathSwapIsDetectedBeforeMetadataMutation() {
        let support = URL(fileURLWithPath: "/app/support", isDirectory: true)
        let fileSystem = PolicyStoreFileSystemFixture(support: support)
        fileSystem.createdKind = .symbolicLink

        assertPathError(.symbolicLinkRejected) {
            _ = try AgentPolicyStorePaths.prepare(fileSystem: fileSystem)
        }
        XCTAssertTrue(fileSystem.protections.isEmpty)
        XCTAssertTrue(fileSystem.backupExclusions.isEmpty)
    }

    func testProtectionAndBackupPostconditionsAreMandatory() {
        let support = URL(fileURLWithPath: "/app/support", isDirectory: true)

        let unprotected = PolicyStoreFileSystemFixture(support: support)
        unprotected.persistProtection = false
        assertPathError(.protectionUnavailable) {
            _ = try AgentPolicyStorePaths.prepare(fileSystem: unprotected)
        }

        let backedUp = PolicyStoreFileSystemFixture(support: support)
        backedUp.persistBackupExclusion = false
        assertPathError(.backupExclusionUnavailable) {
            _ = try AgentPolicyStorePaths.prepare(fileSystem: backedUp)
        }
    }

    func testFileSystemFailuresDoNotReturnPartiallyTrustedPaths() {
        let support = URL(fileURLWithPath: "/app/support", isDirectory: true)
        let fileSystem = PolicyStoreFileSystemFixture(support: support)
        fileSystem.failCreate = true

        assertPathError(.fileSystemFailure) {
            _ = try AgentPolicyStorePaths.prepare(fileSystem: fileSystem)
        }
    }

    private func assertPathError(
        _ expected: AgentPolicyStorePathError,
        operation: () throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            try operation()
            XCTFail("Expected path preparation to fail", file: file, line: line)
        } catch let error as AgentPolicyStorePathError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected error type", file: file, line: line)
        }
    }
}

private final class PolicyStoreFileSystemFixture:
    AgentPolicyStoreFileSystem,
    @unchecked Sendable
{
    struct FixtureError: Error {}

    let support: URL
    var kinds: [String: AgentPolicyStoreFileItemKind]
    var protections: [String: AgentPolicyDirectoryProtection] = [:]
    var backupExclusions: [String: Bool] = [:]
    var createdDirectories: [URL] = []
    var creationProtections: [AgentPolicyDirectoryProtection] = []
    var createdKind: AgentPolicyStoreFileItemKind = .directory
    var persistProtection = true
    var persistBackupExclusion = true
    var failCreate = false

    init(
        support: URL,
        supportKind: AgentPolicyStoreFileItemKind = .directory
    ) {
        self.support = support
        kinds = [support.standardizedFileURL.path: supportKind]
    }

    func applicationSupportDirectory() throws -> URL { support }

    func itemKind(at url: URL) throws -> AgentPolicyStoreFileItemKind {
        kinds[url.standardizedFileURL.path] ?? .missing
    }

    func createDirectory(
        at url: URL,
        protection: AgentPolicyDirectoryProtection
    ) throws {
        if failCreate { throw FixtureError() }
        createdDirectories.append(url)
        creationProtections.append(protection)
        kinds[url.standardizedFileURL.path] = createdKind
    }

    func setProtection(
        _ protection: AgentPolicyDirectoryProtection,
        at url: URL
    ) throws {
        if persistProtection {
            protections[url.standardizedFileURL.path] = protection
        }
    }

    func protection(
        at url: URL
    ) throws -> AgentPolicyDirectoryProtection? {
        protections[url.standardizedFileURL.path]
    }

    func setExcludedFromBackup(_ excluded: Bool, at url: URL) throws {
        if persistBackupExclusion {
            backupExclusions[url.standardizedFileURL.path] = excluded
        }
    }

    func isExcludedFromBackup(at url: URL) throws -> Bool {
        backupExclusions[url.standardizedFileURL.path] == true
    }
}
