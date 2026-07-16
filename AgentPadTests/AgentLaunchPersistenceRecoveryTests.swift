import CryptoKit
import Foundation
import SwiftData
import XCTest
@testable import NovaForge

@MainActor
final class AgentLaunchPersistenceRecoveryTests: XCTestCase {
    func testUnknownModelVersionPreservesPrimaryAndProbesBeforeEveryResume() throws {
        let defaults = try makeDefaults("unknown-version")
        defer { clear(defaults) }
        let paths = testPaths("unknown-version")
        let originals = sourceFiles(paths)
        let fileSystem = InMemoryLaunchFileSystem(files: originals)
        let repository = FakeLaunchContainerRepository(fileSystem: fileSystem)
        var openAttempts: [URL] = []
        var knownLegacyOpenCount = 0
        let dependencies = LaunchPersistenceContainerSelectionDependencies(
            fileOperations: fileSystem.operations,
            now: { fixedRecoveryDate },
            makeRecoveryID: { fixedRecoveryID },
            openContainer: { url -> FakeLaunchContainer in
                openAttempts.append(url)
                if url == paths.primaryStoreURL {
                    throw makeUnknownModelVersionCodeOnlyError()
                }
                return repository.open(url)
            },
            isUnknownModelVersion: LaunchPersistenceErrorClassifier
                .isUnknownStagedMigrationVersion,
            classifyKnownLegacyStore: { _ in nil },
            openKnownLegacyContainer: { url in
                knownLegacyOpenCount += 1
                return repository.open(url)
            }
        )

        let first = try LaunchPersistenceContainerSelector.select(
            paths: paths,
            migrationStore: defaults,
            dependencies: dependencies
        )
        first.container.values["draft"] = "survives-relaunch"
        let second = try LaunchPersistenceContainerSelector.select(
            paths: paths,
            migrationStore: defaults,
            dependencies: dependencies
        )

        XCTAssertEqual(first.mode, .unknownVersionCompatibility)
        XCTAssertEqual(second.mode, .resumedCompatibility)
        XCTAssertEqual(second.container.values["draft"], "survives-relaunch")
        XCTAssertEqual(openAttempts, [
            paths.primaryStoreURL,
            paths.compatibilityStoreURL,
            paths.primaryStoreURL,
            paths.compatibilityStoreURL,
        ])
        XCTAssertEqual(fileSystem.sourceFiles(for: paths), originals)
        XCTAssertTrue(fileSystem.copyCalls.isEmpty)
        XCTAssertTrue(fileSystem.removedSourceURLs.isEmpty)
        XCTAssertEqual(knownLegacyOpenCount, 0)
    }

    func testExactKnownLegacyStoreSnapshotsBeforeOpeningInferredMigration() throws {
        let defaults = try makeDefaults("known-legacy-success")
        defer { clear(defaults) }
        let paths = testPaths("known-legacy-success")
        let originals = sourceFiles(paths)
        let fileSystem = InMemoryLaunchFileSystem(files: originals)
        let repository = FakeLaunchContainerRepository(fileSystem: fileSystem)
        var stagedOpenCount = 0
        var knownLegacyOpenCount = 0
        var snapshotWasDurableBeforeLegacyOpen = false
        var sourceWasUnchangedBeforeLegacyOpen = false

        let selection = try LaunchPersistenceContainerSelector.select(
            paths: paths,
            migrationStore: defaults,
            dependencies: .init(
                fileOperations: fileSystem.operations,
                now: { fixedRecoveryDate },
                makeRecoveryID: { fixedRecoveryID },
                openContainer: { url in
                    if url == paths.primaryStoreURL {
                        stagedOpenCount += 1
                        throw makeUnknownModelVersionCodeOnlyError()
                    }
                    return repository.open(url)
                },
                isUnknownModelVersion: LaunchPersistenceErrorClassifier
                    .isUnknownStagedMigrationVersion,
                classifyKnownLegacyStore: { url in
                    url == paths.primaryStoreURL
                        ? .preExplicitSchemaV1
                        : nil
                },
                openKnownLegacyContainer: { url in
                    knownLegacyOpenCount += 1
                    snapshotWasDurableBeforeLegacyOpen =
                        fileSystem.fileExists(recoveryVerifiedCommitURL(
                            paths,
                            recoveryID: fixedRecoveryID
                        ))
                    sourceWasUnchangedBeforeLegacyOpen =
                        fileSystem.sourceFiles(for: paths) == originals
                    fileSystem.files[url] = Data("migrated-v4".utf8)
                    return repository.open(url)
                }
            )
        )

        XCTAssertEqual(selection.mode, .migratedKnownLegacyPrimary)
        XCTAssertEqual(selection.storeURL, paths.primaryStoreURL)
        XCTAssertFalse(selection.isCompatibilityFallback)
        XCTAssertEqual(stagedOpenCount, 1)
        XCTAssertEqual(knownLegacyOpenCount, 1)
        XCTAssertTrue(snapshotWasDurableBeforeLegacyOpen)
        XCTAssertTrue(sourceWasUnchangedBeforeLegacyOpen)
        XCTAssertFalse(defaults.bool(
            forKey: ProjectBootstrap.compatibilityFallbackActiveKey
        ))
        XCTAssertFalse(fileSystem.fileExists(paths.compatibilityStoreURL))
        for (suffix, originalData) in sourceDataBySuffix {
            XCTAssertEqual(
                fileSystem.files[recoveryStoreURL(
                    paths,
                    recoveryID: fixedRecoveryID,
                    suffix: suffix
                )],
                originalData
            )
        }
    }

    func testExactKnownLegacySignatureAuthorizesBridgeWhenErrorIsOpaque() throws {
        let defaults = try makeDefaults("known-legacy-opaque-error")
        defer { clear(defaults) }
        let paths = testPaths("known-legacy-opaque-error")
        let originals = sourceFiles(paths)
        let fileSystem = InMemoryLaunchFileSystem(files: originals)
        let repository = FakeLaunchContainerRepository(fileSystem: fileSystem)
        var bridgeOpenCount = 0

        let selection = try LaunchPersistenceContainerSelector.select(
            paths: paths,
            migrationStore: defaults,
            dependencies: .init(
                fileOperations: fileSystem.operations,
                now: { fixedRecoveryDate },
                makeRecoveryID: { fixedRecoveryID },
                openContainer: { url in
                    if url == paths.primaryStoreURL {
                        // SwiftData's public wrapper does not expose Core
                        // Data's logged 134504 as an NSError in this case.
                        throw InjectedLaunchFailure.primaryOpen
                    }
                    return repository.open(url)
                },
                isUnknownModelVersion: { _ in false },
                classifyKnownLegacyStore: { url in
                    url == paths.primaryStoreURL
                        ? .preExplicitSchemaV1
                        : nil
                },
                openKnownLegacyContainer: { url in
                    bridgeOpenCount += 1
                    return repository.open(url)
                }
            )
        )

        XCTAssertEqual(selection.mode, .migratedKnownLegacyPrimary)
        XCTAssertEqual(bridgeOpenCount, 1)
        XCTAssertEqual(fileSystem.sourceFiles(for: paths), originals)
        XCTAssertTrue(fileSystem.fileExists(recoveryVerifiedCommitURL(
            paths,
            recoveryID: fixedRecoveryID
        )))
    }

    func testKnownLegacySnapshotFailureNeverOpensInferredMigration() throws {
        let defaults = try makeDefaults("known-legacy-snapshot-failure")
        defer { clear(defaults) }
        let paths = testPaths("known-legacy-snapshot-failure")
        let originals = sourceFiles(paths)
        let fileSystem = InMemoryLaunchFileSystem(
            files: originals,
            failures: [.copyAfterCreating(call: 1)]
        )
        let repository = FakeLaunchContainerRepository(fileSystem: fileSystem)
        var knownLegacyOpenCount = 0

        let selection = try LaunchPersistenceContainerSelector.select(
            paths: paths,
            migrationStore: defaults,
            dependencies: .init(
                fileOperations: fileSystem.operations,
                now: { fixedRecoveryDate },
                makeRecoveryID: { fixedRecoveryID },
                openContainer: { url in
                    if url == paths.primaryStoreURL {
                        throw makeUnknownModelVersionCodeOnlyError()
                    }
                    return repository.open(url)
                },
                isUnknownModelVersion: LaunchPersistenceErrorClassifier
                    .isUnknownStagedMigrationVersion,
                classifyKnownLegacyStore: { _ in .preExplicitSchemaV1 },
                openKnownLegacyContainer: { url in
                    knownLegacyOpenCount += 1
                    return repository.open(url)
                }
            )
        )

        XCTAssertEqual(selection.mode, .recoverySnapshotFailureCompatibility)
        XCTAssertTrue(selection.isCompatibilityFallback)
        XCTAssertEqual(knownLegacyOpenCount, 0)
        XCTAssertEqual(fileSystem.sourceFiles(for: paths), originals)
        XCTAssertFalse(fileSystem.fileExists(recoveryVerifiedCommitURL(
            paths,
            recoveryID: fixedRecoveryID
        )))
        XCTAssertTrue(fileSystem.fileExists(paths.compatibilityActiveGuardURL))
    }

    func testKnownLegacyOpenFailureRetainsVerifiedSnapshotAndFailsClosed() throws {
        let defaults = try makeDefaults("known-legacy-open-failure")
        defer { clear(defaults) }
        let paths = testPaths("known-legacy-open-failure")
        let originals = sourceFiles(paths)
        let fileSystem = InMemoryLaunchFileSystem(files: originals)
        let repository = FakeLaunchContainerRepository(fileSystem: fileSystem)
        var knownLegacyOpenCount = 0

        let selection = try LaunchPersistenceContainerSelector.select(
            paths: paths,
            migrationStore: defaults,
            dependencies: .init(
                fileOperations: fileSystem.operations,
                now: { fixedRecoveryDate },
                makeRecoveryID: { fixedRecoveryID },
                openContainer: { url in
                    if url == paths.primaryStoreURL {
                        throw makeUnknownModelVersionCodeOnlyError()
                    }
                    return repository.open(url)
                },
                isUnknownModelVersion: LaunchPersistenceErrorClassifier
                    .isUnknownStagedMigrationVersion,
                classifyKnownLegacyStore: { _ in .preExplicitSchemaV1 },
                openKnownLegacyContainer: { _ -> FakeLaunchContainer in
                    knownLegacyOpenCount += 1
                    throw InjectedLaunchFailure.primaryOpen
                }
            )
        )

        XCTAssertEqual(selection.mode, .unknownVersionCompatibility)
        XCTAssertEqual(knownLegacyOpenCount, 1)
        XCTAssertEqual(fileSystem.sourceFiles(for: paths), originals)
        XCTAssertTrue(fileSystem.fileExists(recoveryVerifiedCommitURL(
            paths,
            recoveryID: fixedRecoveryID
        )))
        XCTAssertTrue(fileSystem.fileExists(paths.compatibilityActiveGuardURL))
    }

    func testKnownLegacyMigratorBridgesToExactV1BeforeStagedOpen() throws {
        let storeURL = URL(fileURLWithPath: "/known-legacy/NovaForge.store")
        var events: [String] = []

        let result: String = try LaunchPersistenceKnownLegacyMigrator.open(
            storeAt: storeURL,
            dependencies: .init(
                openInferredV1Bridge: { url in
                    XCTAssertEqual(url, storeURL)
                    events.append("inferred-v1")
                },
                isExactExplicitV1Store: { url in
                    XCTAssertEqual(url, storeURL)
                    events.append("verify-v1")
                    return true
                },
                openCurrentStagedContainer: { url in
                    XCTAssertEqual(url, storeURL)
                    events.append("staged-v4")
                    return "current-container"
                }
            )
        )

        XCTAssertEqual(result, "current-container")
        XCTAssertEqual(events, ["inferred-v1", "verify-v1", "staged-v4"])
    }

    func testKnownLegacyMigratorFailsClosedOnUnexpectedBridgeSignature() {
        let storeURL = URL(fileURLWithPath: "/known-legacy/NovaForge.store")
        var stagedOpenCount = 0

        XCTAssertThrowsError(try LaunchPersistenceKnownLegacyMigrator.open(
            storeAt: storeURL,
            dependencies: .init(
                openInferredV1Bridge: { _ in },
                isExactExplicitV1Store: { _ in false },
                openCurrentStagedContainer: { _ -> String in
                    stagedOpenCount += 1
                    return "must-not-open"
                }
            )
        ))
        XCTAssertEqual(stagedOpenCount, 0)
    }

    func testActiveCompatibilityBranchRemainsAuthoritativeAfterKnownLegacyMigration() throws {
        let defaults = try makeDefaults("known-legacy-active-fallback")
        defer { clear(defaults) }
        defaults.set(
            true,
            forKey: ProjectBootstrap.compatibilityFallbackActiveKey
        )
        let paths = testPaths("known-legacy-active-fallback")
        var files = sourceFiles(paths)
        files[paths.compatibilityStoreURL] = Data("newer-fallback".utf8)
        files[paths.compatibilityActiveGuardURL] = Data("active".utf8)
        let fileSystem = InMemoryLaunchFileSystem(files: files)
        let repository = FakeLaunchContainerRepository(fileSystem: fileSystem)
        repository.open(paths.compatibilityStoreURL).values["newer-run"] =
            "must remain authoritative"
        var knownLegacyOpenCount = 0

        let selection = try LaunchPersistenceContainerSelector.select(
            paths: paths,
            migrationStore: defaults,
            dependencies: .init(
                fileOperations: fileSystem.operations,
                now: { fixedRecoveryDate },
                makeRecoveryID: { fixedRecoveryID },
                openContainer: { url in
                    if url == paths.primaryStoreURL {
                        throw makeUnknownModelVersionCodeOnlyError()
                    }
                    return repository.open(url)
                },
                isUnknownModelVersion: LaunchPersistenceErrorClassifier
                    .isUnknownStagedMigrationVersion,
                classifyKnownLegacyStore: { _ in .preExplicitSchemaV1 },
                openKnownLegacyContainer: { url in
                    knownLegacyOpenCount += 1
                    fileSystem.files[url] = Data("migrated-v4".utf8)
                    return FakeLaunchContainer(url: url)
                }
            )
        )

        XCTAssertEqual(selection.mode, .resumedCompatibility)
        XCTAssertEqual(selection.storeURL, paths.compatibilityStoreURL)
        XCTAssertTrue(selection.isCompatibilityFallback)
        XCTAssertEqual(knownLegacyOpenCount, 1)
        XCTAssertEqual(
            selection.container.values["newer-run"],
            "must remain authoritative"
        )
        XCTAssertTrue(fileSystem.fileExists(recoveryVerifiedCommitURL(
            paths,
            recoveryID: fixedRecoveryID
        )))
        XCTAssertTrue(defaults.bool(
            forKey: ProjectBootstrap.compatibilityFallbackActiveKey
        ))
    }

    func testDiskBackedFallbackSurvivesFreshModelContainerReopen() throws {
        let root = try makeTemporaryDirectory("disk-fallback")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = LaunchPersistenceStorePaths(supportURL: root)
        let defaults = try makeDefaults("disk-fallback")
        defer { clear(defaults) }
        let suiteName = try XCTUnwrap(defaults.string(forKey: testSuiteNameKey))
        let schema = Schema([AgentSettings.self])

        try writeDiskBackedFallback(
            paths: paths,
            defaults: defaults,
            schema: schema
        )
        defaults.removeObject(
            forKey: ProjectBootstrap.compatibilityFallbackActiveKey
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: paths.compatibilityActiveGuardURL.path
        ))

        // This is a new defaults handle and a newly-created disk ModelContainer;
        // no cached fake or in-memory container crosses the helper boundary.
        let freshDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        var openAttempts: [URL] = []
        let selection = try LaunchPersistenceContainerSelector.select(
            paths: paths,
            migrationStore: freshDefaults,
            dependencies: LaunchPersistenceContainerSelectionDependencies(
                fileOperations: .live,
                now: { fixedRecoveryDate },
                makeRecoveryID: { secondRecoveryID },
                openContainer: { url -> ModelContainer in
                    openAttempts.append(url)
                    if url == paths.primaryStoreURL {
                        throw makeUnknownModelVersionCodeOnlyError()
                    }
                    return try ModelContainer(
                        for: schema,
                        configurations: [ModelConfiguration(url: url)]
                    )
                },
                isUnknownModelVersion: LaunchPersistenceErrorClassifier
                    .isUnknownStagedMigrationVersion
            )
        )

        XCTAssertEqual(selection.mode, .resumedCompatibility)
        XCTAssertEqual(openAttempts, [
            paths.primaryStoreURL,
            paths.compatibilityStoreURL,
        ])
        let settings = try XCTUnwrap(
            selection.container.mainContext
                .fetch(FetchDescriptor<AgentSettings>())
                .first
        )
        XCTAssertEqual(settings.activeWorkspaceName, "Durable fallback")
        XCTAssertEqual(settings.modelID, "durable-model")
    }

    func testCapturedPreExplicitStoreMigratesAndReopensThroughCurrentV4Plan() throws {
        let fixtureDirectory = preExplicitFixtureDirectoryURL()
        let fixtureStoreURL = fixtureDirectory.appendingPathComponent(
            "NovaForgePreExplicit.store"
        )
        let metadataURL = fixtureDirectory.appendingPathComponent(
            "NovaForgePreExplicit.store.metadata.json"
        )
        let ledgerURL = fixtureDirectory.appendingPathComponent("SHA256SUMS")
        let metadataData = try Data(contentsOf: metadataURL)
        let metadata = try JSONDecoder().decode(
            PreExplicitFixtureMetadata.self,
            from: metadataData
        )
        let ledger = try readSHA256Ledger(at: ledgerURL)
        let fixtureData = try Data(contentsOf: fixtureStoreURL)

        XCTAssertEqual(metadata.formatVersion, 1)
        XCTAssertEqual(metadata.fixture, fixtureStoreURL.lastPathComponent)
        XCTAssertEqual(Set(ledger.keys), [
            fixtureStoreURL.lastPathComponent,
            metadataURL.lastPathComponent,
        ])
        XCTAssertEqual(
            ledger[fixtureStoreURL.lastPathComponent],
            fingerprint(fixtureData).sha256
        )
        XCTAssertEqual(
            ledger[metadataURL.lastPathComponent],
            fingerprint(metadataData).sha256
        )
        XCTAssertEqual(metadata.store.byteCount, fixtureData.count)
        XCTAssertEqual(metadata.store.sha256, fingerprint(fixtureData).sha256)
        XCTAssertEqual(metadata.store.sqliteQuickCheck, "ok")
        XCTAssertEqual(metadata.store.schema, "pre-explicit default SwiftData schema")
        XCTAssertEqual(metadata.store.modelVersionIdentifiers, ["1.0.0"])
        XCTAssertEqual(
            metadata.store.modelVersionChecksum,
            "aQOGil0EMr8AGv/erCZU9WHPLjisZqFlY+zxDBGc0Ag="
        )
        XCTAssertEqual(
            metadata.store.modelVersionHashesDigest,
            "masscU9dDKfkvThS8HL2SNsPQ8xkq3WNzYSvll3+5yodpVgBRY3wEcdeOCSL/1yTS43oIYe8fgLzUspAbHtuGg=="
        )
        XCTAssertEqual(Set(metadata.store.entityNames), Set(knownLegacyEntityNames))
        XCTAssertEqual(
            metadata.store.semanticDigest.canonicalization,
            "NovaForgePreExplicitSemanticRowsV1"
        )
        XCTAssertEqual(metadata.store.semanticDigest.algorithm, "sha256")

        let root = try makeTemporaryDirectory("pre-explicit-v1")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = LaunchPersistenceStorePaths(supportURL: root)
        try FileManager.default.copyItem(
            at: fixtureStoreURL,
            to: paths.primaryStoreURL
        )
        XCTAssertEqual(
            LaunchPersistenceKnownLegacyStoreClassifier.classify(
                storeAt: paths.primaryStoreURL
            ),
            .preExplicitSchemaV1
        )

        let defaults = try makeDefaults("pre-explicit-v1")
        defer { clear(defaults) }
        let migrated = try migratePreExplicitFixture(
            paths: paths,
            defaults: defaults
        )

        XCTAssertEqual(migrated.knownLegacyOpenCount, 1)
        XCTAssertEqual(migrated.mode, .migratedKnownLegacyPrimary)
        XCTAssertEqual(migrated.storeURL, paths.primaryStoreURL)
        XCTAssertFalse(migrated.isCompatibilityFallback)
        assertPreExplicitFixtureSnapshot(
            migrated.snapshot,
            matches: metadata
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: paths.compatibilityStoreURL.path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: paths.compatibilityActiveGuardURL.path
        ))
        XCTAssertFalse(defaults.bool(
            forKey: ProjectBootstrap.compatibilityFallbackActiveKey
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: recoveryVerifiedCommitURL(
                paths,
                recoveryID: fixedRecoveryID
            ).path
        ))

        let capturedPreimage = try Data(contentsOf: recoveryStoreURL(
            paths,
            recoveryID: fixedRecoveryID,
            suffix: ""
        ))
        XCTAssertEqual(fingerprint(capturedPreimage).sha256, metadata.store.sha256)
        XCTAssertEqual(capturedPreimage.count, metadata.store.byteCount)
        XCTAssertNil(
            LaunchPersistenceKnownLegacyStoreClassifier.classify(
                storeAt: paths.primaryStoreURL
            )
        )

        let firstReopen = try readCurrentV4Snapshot(at: paths.primaryStoreURL)
        let secondReopen = try readCurrentV4Snapshot(at: paths.primaryStoreURL)
        assertPreExplicitFixtureSnapshot(firstReopen, matches: metadata)
        assertPreExplicitFixtureSnapshot(secondReopen, matches: metadata)
        XCTAssertEqual(firstReopen, migrated.snapshot)
        XCTAssertEqual(secondReopen, migrated.snapshot)
    }

    func testVerifiedSnapshotIsDurableAndLeavesSourceByteForByteUnchanged() throws {
        let paths = testPaths("verified-snapshot")
        let originals = sourceFiles(paths)
        let fileSystem = InMemoryLaunchFileSystem(files: originals)

        let result = LaunchPersistenceStoreQuarantine.perform(
            paths: paths,
            reason: InjectedLaunchFailure.primaryOpen,
            now: fixedRecoveryDate,
            recoveryID: fixedRecoveryID,
            files: fileSystem.operations
        )

        XCTAssertTrue(result)
        XCTAssertEqual(fileSystem.sourceFiles(for: paths), originals)
        XCTAssertTrue(fileSystem.removedSourceURLs.isEmpty)
        for (suffix, data) in sourceDataBySuffix {
            XCTAssertEqual(
                fileSystem.files[recoveryStoreURL(
                    paths,
                    recoveryID: fixedRecoveryID,
                    suffix: suffix
                )],
                data
            )
        }

        let manifestData = try XCTUnwrap(fileSystem.files[
            recoveryManifestURL(paths, recoveryID: fixedRecoveryID)
        ])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let manifest = try decoder.decode(
            LaunchPersistenceRecoveryManifest.self,
            from: manifestData
        )
        XCTAssertEqual(manifest.formatVersion, 2)
        XCTAssertEqual(manifest.recoveryID, fixedRecoveryID)
        XCTAssertEqual(manifest.sourceDisposition, "retained")
        XCTAssertEqual(
            manifest.files.map(\.fileName),
            ["NovaForge.store", "NovaForge.store-wal", "NovaForge.store-shm"]
        )
        let commit = try XCTUnwrap(fileSystem.files[
            recoveryVerifiedCommitURL(paths, recoveryID: fixedRecoveryID)
        ])
        XCTAssertTrue(String(decoding: commit, as: UTF8.self).contains(
            "source=retained"
        ))
        XCTAssertTrue(fileSystem.events.contains(
            "file-sync:\(LaunchPersistenceStoreQuarantine.manifestFileName)"
        ))
        XCTAssertTrue(fileSystem.events.contains(
            "file-sync:\(LaunchPersistenceStoreQuarantine.verifiedCommitFileName)"
        ))
        XCTAssertTrue(fileSystem.events.contains(
            "dir-sync:\(fixedRecoveryID.uuidString.lowercased())"
        ))
    }

    func testLiveSnapshotPersistsCopiesAndCommitWithoutDeletingSource() throws {
        let root = try makeTemporaryDirectory("live-snapshot")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = LaunchPersistenceStorePaths(supportURL: root)
        try writeSourceFiles(paths)
        let originals = try readSourceFiles(paths)

        let result = LaunchPersistenceStoreQuarantine.perform(
            paths: paths,
            reason: InjectedLaunchFailure.primaryOpen,
            now: fixedRecoveryDate,
            recoveryID: fixedRecoveryID,
            files: .live
        )

        XCTAssertTrue(result)
        XCTAssertEqual(try readSourceFiles(paths), originals)
        for (suffix, data) in sourceDataBySuffix {
            XCTAssertEqual(
                try Data(contentsOf: recoveryStoreURL(
                    paths,
                    recoveryID: fixedRecoveryID,
                    suffix: suffix
                )),
                data
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: recoveryManifestURL(
                paths,
                recoveryID: fixedRecoveryID
            ).path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: recoveryVerifiedCommitURL(
                paths,
                recoveryID: fixedRecoveryID
            ).path
        ))
    }

    func testNonUnknownFailureReturnsAlreadyOpenFallbackAndNextLaunchContinuesIt() throws {
        let defaults = try makeDefaults("snapshot-continuity")
        defer { clear(defaults) }
        let paths = testPaths("snapshot-continuity")
        let originals = sourceFiles(paths)
        let fileSystem = InMemoryLaunchFileSystem(files: originals)
        let repository = FakeLaunchContainerRepository(fileSystem: fileSystem)
        var primaryFailures = 0
        let dependencies = LaunchPersistenceContainerSelectionDependencies(
            fileOperations: fileSystem.operations,
            now: { fixedRecoveryDate },
            makeRecoveryID: {
                primaryFailures == 1 ? fixedRecoveryID : secondRecoveryID
            },
            openContainer: { url -> FakeLaunchContainer in
                if url == paths.primaryStoreURL {
                    primaryFailures += 1
                    throw InjectedLaunchFailure.primaryOpen
                }
                return repository.open(url)
            },
            isUnknownModelVersion: { _ in false }
        )

        let first = try LaunchPersistenceContainerSelector.select(
            paths: paths,
            migrationStore: defaults,
            dependencies: dependencies
        )
        first.container.values["receipt"] = "durable-branch"
        let second = try LaunchPersistenceContainerSelector.select(
            paths: paths,
            migrationStore: defaults,
            dependencies: dependencies
        )

        XCTAssertEqual(first.mode, .recoverySnapshotCompatibility)
        XCTAssertEqual(second.mode, .resumedCompatibility)
        XCTAssertEqual(second.container.values["receipt"], "durable-branch")
        XCTAssertEqual(primaryFailures, 2)
        XCTAssertEqual(fileSystem.sourceFiles(for: paths), originals)
        XCTAssertTrue(fileSystem.fileExists(recoveryVerifiedCommitURL(
            paths,
            recoveryID: fixedRecoveryID
        )))
        XCTAssertFalse(fileSystem.fileExists(
            paths.recoveryAttemptDirectoryURL(recoveryID: secondRecoveryID)
        ))
    }

    func testHealthyPrimaryProbeCannotStrandFallbackBeforeTransientFailure() throws {
        let defaults = try makeDefaults("active-fallback-probe")
        defer { clear(defaults) }
        defaults.set(true, forKey: ProjectBootstrap.compatibilityFallbackActiveKey)
        defaults.set(true, forKey: ProjectBootstrap.legacyOwnershipMigrationKey)
        let paths = testPaths("active-fallback-probe")
        let fallbackData = Data("fallback-data".utf8)
        let fileSystem = InMemoryLaunchFileSystem(
            files: [
                paths.primaryStoreURL: Data("primary".utf8),
                paths.compatibilityStoreURL: fallbackData,
                paths.compatibilityActiveGuardURL: Data("active".utf8),
            ],
            failures: [.remove(url: paths.compatibilityActiveGuardURL)]
        )
        let repository = FakeLaunchContainerRepository(fileSystem: fileSystem)
        repository.open(paths.compatibilityStoreURL).values["newer-run"] =
            "must remain active"

        let first = try LaunchPersistenceContainerSelector.select(
            paths: paths,
            migrationStore: defaults,
            dependencies: .init(
                fileOperations: fileSystem.operations,
                now: { fixedRecoveryDate },
                makeRecoveryID: { fixedRecoveryID },
                openContainer: repository.open,
                isUnknownModelVersion: { _ in false }
            )
        )
        let second = try LaunchPersistenceContainerSelector.select(
            paths: paths,
            migrationStore: defaults,
            dependencies: .init(
                fileOperations: fileSystem.operations,
                now: { fixedRecoveryDate },
                makeRecoveryID: { secondRecoveryID },
                openContainer: { url in
                    if url == paths.primaryStoreURL {
                        throw InjectedLaunchFailure.primaryOpen
                    }
                    return repository.open(url)
                },
                isUnknownModelVersion: { _ in false }
            )
        )

        XCTAssertEqual(first.mode, .resumedCompatibility)
        XCTAssertEqual(second.mode, .resumedCompatibility)
        XCTAssertEqual(
            first.container.values["newer-run"],
            "must remain active"
        )
        XCTAssertEqual(
            second.container.values["newer-run"],
            "must remain active"
        )
        XCTAssertTrue(defaults.bool(
            forKey: ProjectBootstrap.compatibilityFallbackActiveKey
        ))
        XCTAssertTrue(defaults.bool(
            forKey: ProjectBootstrap.legacyOwnershipMigrationKey
        ))
        XCTAssertEqual(fileSystem.files[paths.compatibilityStoreURL], fallbackData)
        XCTAssertNotNil(fileSystem.files[paths.compatibilityActiveGuardURL])
        XCTAssertTrue(fileSystem.copyCalls.isEmpty)
        XCTAssertTrue(fileSystem.removedURLs.isEmpty)
    }

    func testStaleGuardWithoutFallbackMustBeDurablyRemovedBeforePrimarySwitch() throws {
        let defaults = try makeDefaults("guard-clear-success")
        defer { clear(defaults) }
        defaults.set(true, forKey: ProjectBootstrap.compatibilityFallbackActiveKey)
        defaults.set(true, forKey: ProjectBootstrap.legacyOwnershipMigrationKey)
        let paths = testPaths("guard-clear-success")
        let fileSystem = InMemoryLaunchFileSystem(files: [
            paths.primaryStoreURL: Data("primary".utf8),
            paths.compatibilityActiveGuardURL: Data("active".utf8),
        ])
        let repository = FakeLaunchContainerRepository(fileSystem: fileSystem)

        let selection = try LaunchPersistenceContainerSelector.select(
            paths: paths,
            migrationStore: defaults,
            dependencies: .init(
                fileOperations: fileSystem.operations,
                now: { fixedRecoveryDate },
                makeRecoveryID: { fixedRecoveryID },
                openContainer: repository.open,
                isUnknownModelVersion: { _ in false }
            )
        )

        XCTAssertEqual(selection.mode, .primary)
        XCTAssertFalse(defaults.bool(
            forKey: ProjectBootstrap.compatibilityFallbackActiveKey
        ))
        XCTAssertTrue(defaults.bool(
            forKey: ProjectBootstrap.legacyOwnershipMigrationKey
        ))
        XCTAssertNil(fileSystem.files[paths.compatibilityActiveGuardURL])
        XCTAssertNil(fileSystem.files[paths.compatibilityStoreURL])
        XCTAssertTrue(fileSystem.events.contains("dir-sync:CompatibilityRecovery"))
    }

    func testGuardRemovalFailureThenTransientPrimaryFailureRemainsFailClosed() throws {
        let defaults = try makeDefaults("guard-clear-failure")
        defer { clear(defaults) }
        defaults.set(true, forKey: ProjectBootstrap.compatibilityFallbackActiveKey)
        defaults.set(true, forKey: ProjectBootstrap.legacyOwnershipMigrationKey)
        let paths = testPaths("guard-clear-failure")
        let primaryData = Data("primary".utf8)
        let guardData = Data("active".utf8)
        let fileSystem = InMemoryLaunchFileSystem(
            files: [
                paths.primaryStoreURL: primaryData,
                paths.compatibilityActiveGuardURL: guardData,
            ],
            failures: [.remove(url: paths.compatibilityActiveGuardURL)]
        )
        let repository = FakeLaunchContainerRepository(fileSystem: fileSystem)

        XCTAssertThrowsError(try LaunchPersistenceContainerSelector.select(
            paths: paths,
            migrationStore: defaults,
            dependencies: .init(
                fileOperations: fileSystem.operations,
                now: { fixedRecoveryDate },
                makeRecoveryID: { fixedRecoveryID },
                openContainer: repository.open,
                isUnknownModelVersion: { _ in false }
            )
        ))
        XCTAssertThrowsError(try LaunchPersistenceContainerSelector.select(
            paths: paths,
            migrationStore: defaults,
            dependencies: .init(
                fileOperations: fileSystem.operations,
                now: { fixedRecoveryDate },
                makeRecoveryID: { secondRecoveryID },
                openContainer: { url -> FakeLaunchContainer in
                    if url == paths.primaryStoreURL {
                        throw InjectedLaunchFailure.primaryOpen
                    }
                    return repository.open(url)
                },
                isUnknownModelVersion: { _ in false }
            )
        ))

        XCTAssertEqual(fileSystem.files[paths.primaryStoreURL], primaryData)
        XCTAssertEqual(fileSystem.files[paths.compatibilityActiveGuardURL], guardData)
        XCTAssertNil(fileSystem.files[paths.compatibilityStoreURL])
        XCTAssertTrue(fileSystem.copyCalls.isEmpty)
        XCTAssertTrue(defaults.bool(
            forKey: ProjectBootstrap.compatibilityFallbackActiveKey
        ))
        XCTAssertTrue(defaults.bool(
            forKey: ProjectBootstrap.legacyOwnershipMigrationKey
        ))
    }

    func testActiveMarkerAndMissingFallbackFailsClosedWithoutCreatingBlankStore() throws {
        let defaults = try makeDefaults("missing-fallback")
        defer { clear(defaults) }
        defaults.set(true, forKey: ProjectBootstrap.compatibilityFallbackActiveKey)
        let paths = testPaths("missing-fallback")
        let originals = sourceFiles(paths)
        let fileSystem = InMemoryLaunchFileSystem(files: originals)
        var attempts: [URL] = []

        XCTAssertThrowsError(try LaunchPersistenceContainerSelector.select(
            paths: paths,
            migrationStore: defaults,
            dependencies: LaunchPersistenceContainerSelectionDependencies(
                fileOperations: fileSystem.operations,
                now: { fixedRecoveryDate },
                makeRecoveryID: { fixedRecoveryID },
                openContainer: { url -> FakeLaunchContainer in
                    attempts.append(url)
                    throw InjectedLaunchFailure.primaryOpen
                },
                isUnknownModelVersion: { _ in false }
            )
        ))

        XCTAssertEqual(attempts, [paths.primaryStoreURL])
        XCTAssertNil(fileSystem.files[paths.compatibilityStoreURL])
        XCTAssertEqual(fileSystem.sourceFiles(for: paths), originals)
        XCTAssertTrue(fileSystem.copyCalls.isEmpty)
        XCTAssertTrue(defaults.bool(
            forKey: ProjectBootstrap.compatibilityFallbackActiveKey
        ))
    }

    func testCorruptGuardSafelyResumesExistingFallback() throws {
        let defaults = try makeDefaults("corrupt-guard")
        defer { clear(defaults) }
        let paths = testPaths("corrupt-guard")
        let corruptGuard = Data([0x00, 0xff, 0x7f])
        let fileSystem = InMemoryLaunchFileSystem(files: [
            paths.primaryStoreURL: Data("primary".utf8),
            paths.compatibilityStoreURL: Data("fallback".utf8),
            paths.compatibilityActiveGuardURL: corruptGuard,
        ])
        let repository = FakeLaunchContainerRepository(fileSystem: fileSystem)

        let selection = try LaunchPersistenceContainerSelector.select(
            paths: paths,
            migrationStore: defaults,
            dependencies: .init(
                fileOperations: fileSystem.operations,
                now: { fixedRecoveryDate },
                makeRecoveryID: { fixedRecoveryID },
                openContainer: { url in
                    if url == paths.primaryStoreURL {
                        throw InjectedLaunchFailure.primaryOpen
                    }
                    return repository.open(url)
                },
                isUnknownModelVersion: { _ in false }
            )
        )

        XCTAssertEqual(selection.mode, .resumedCompatibility)
        XCTAssertEqual(fileSystem.files[paths.compatibilityActiveGuardURL], corruptGuard)
        XCTAssertTrue(defaults.bool(
            forKey: ProjectBootstrap.compatibilityFallbackActiveKey
        ))
        XCTAssertTrue(fileSystem.copyCalls.isEmpty)
    }

    func testExclusiveAttemptCollisionNeverOverwritesEarlierRecovery() {
        let paths = testPaths("exclusive-collision")
        let originals = sourceFiles(paths)
        let attempt = paths.recoveryAttemptDirectoryURL(recoveryID: fixedRecoveryID)
        let sentinel = attempt.appendingPathComponent("sentinel")
        let sentinelData = Data("earlier recovery".utf8)
        let fileSystem = InMemoryLaunchFileSystem(
            files: originals.merging([sentinel: sentinelData]) { current, _ in current },
            directories: [paths.recoveryDirectoryURL, attempt]
        )

        let result = LaunchPersistenceStoreQuarantine.perform(
            paths: paths,
            reason: InjectedLaunchFailure.primaryOpen,
            now: fixedRecoveryDate,
            recoveryID: fixedRecoveryID,
            files: fileSystem.operations
        )

        XCTAssertFalse(result)
        XCTAssertEqual(fileSystem.files[sentinel], sentinelData)
        XCTAssertEqual(fileSystem.sourceFiles(for: paths), originals)
        XCTAssertTrue(fileSystem.copyCalls.isEmpty)
        XCTAssertTrue(fileSystem.removedURLs.isEmpty)
    }

    func testLiveExclusiveAttemptCollisionNeverOverwritesEarlierRecovery() throws {
        let root = try makeTemporaryDirectory("live-exclusive-collision")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = LaunchPersistenceStorePaths(supportURL: root)
        try writeSourceFiles(paths)
        let originals = try readSourceFiles(paths)
        let attempt = paths.recoveryAttemptDirectoryURL(recoveryID: fixedRecoveryID)
        try FileManager.default.createDirectory(
            at: attempt,
            withIntermediateDirectories: true
        )
        let sentinel = attempt.appendingPathComponent("sentinel")
        let sentinelData = Data("earlier recovery".utf8)
        try sentinelData.write(to: sentinel, options: .withoutOverwriting)

        let result = LaunchPersistenceStoreQuarantine.perform(
            paths: paths,
            reason: InjectedLaunchFailure.primaryOpen,
            now: fixedRecoveryDate,
            recoveryID: fixedRecoveryID,
            files: .live
        )

        XCTAssertFalse(result)
        XCTAssertEqual(try readSourceFiles(paths), originals)
        XCTAssertEqual(try Data(contentsOf: sentinel), sentinelData)
    }

    func testCopyFileSyncDirectorySyncAndManifestFailuresNeverPublishCommit() {
        let failureCases: [(String, InMemoryLaunchFileSystem.Failure)] = [
            ("copy", .copyAfterCreating(call: 2)),
            ("file-sync", .fileSync(lastPathComponent: "NovaForge.store-wal")),
            (
                "directory-sync",
                .directorySync(lastPathComponent: fixedRecoveryID.uuidString.lowercased())
            ),
            (
                "manifest-write",
                .write(lastPathComponent: LaunchPersistenceStoreQuarantine.manifestFileName)
            ),
            (
                "manifest-sync",
                .fileSync(lastPathComponent: LaunchPersistenceStoreQuarantine.manifestFileName)
            ),
        ]

        for (label, failure) in failureCases {
            let paths = testPaths("failure-\(label)")
            let originals = sourceFiles(paths)
            let fileSystem = InMemoryLaunchFileSystem(
                files: originals,
                failures: [failure]
            )

            let result = LaunchPersistenceStoreQuarantine.perform(
                paths: paths,
                reason: InjectedLaunchFailure.primaryOpen,
                now: fixedRecoveryDate,
                recoveryID: fixedRecoveryID,
                files: fileSystem.operations
            )

            XCTAssertFalse(result, label)
            XCTAssertEqual(fileSystem.sourceFiles(for: paths), originals, label)
            XCTAssertNil(fileSystem.files[recoveryVerifiedCommitURL(
                paths,
                recoveryID: fixedRecoveryID
            )], label)
            XCTAssertTrue(fileSystem.removedSourceURLs.isEmpty, label)
        }
    }

    func testSourceMutationBeforeCommitRejectsSnapshotAndRetainsBothVersions() {
        let paths = testPaths("source-mutation")
        let originals = sourceFiles(paths)
        let changedMain = Data("main changed by another writer".utf8)
        let fileSystem = InMemoryLaunchFileSystem(
            files: originals,
            mutation: .init(
                url: paths.primaryStoreURL,
                fingerprintCall: 3,
                replacement: changedMain
            )
        )

        let result = LaunchPersistenceStoreQuarantine.perform(
            paths: paths,
            reason: InjectedLaunchFailure.primaryOpen,
            now: fixedRecoveryDate,
            recoveryID: fixedRecoveryID,
            files: fileSystem.operations
        )

        XCTAssertFalse(result)
        XCTAssertEqual(fileSystem.files[paths.primaryStoreURL], changedMain)
        XCTAssertEqual(fileSystem.files[recoveryStoreURL(
            paths,
            recoveryID: fixedRecoveryID,
            suffix: ""
        )], originals[paths.primaryStoreURL])
        XCTAssertNil(fileSystem.files[recoveryVerifiedCommitURL(
            paths,
            recoveryID: fixedRecoveryID
        )])
        XCTAssertTrue(fileSystem.removedSourceURLs.isEmpty)
    }

    func testSuccessfulNewSnapshotRetainsPriorRecovery() {
        let paths = testPaths("prior-retained")
        let originals = sourceFiles(paths)
        let priorAttempt = paths.recoveryAttemptDirectoryURL(
            recoveryID: priorRecoveryID
        )
        let priorCommit = priorAttempt.appendingPathComponent(
            LaunchPersistenceStoreQuarantine.verifiedCommitFileName
        )
        let priorData = Data("prior verified recovery".utf8)
        let fileSystem = InMemoryLaunchFileSystem(
            files: originals.merging([priorCommit: priorData]) { current, _ in current },
            directories: [paths.recoveryDirectoryURL, priorAttempt]
        )

        let result = LaunchPersistenceStoreQuarantine.perform(
            paths: paths,
            reason: InjectedLaunchFailure.primaryOpen,
            now: fixedRecoveryDate,
            recoveryID: fixedRecoveryID,
            files: fileSystem.operations
        )

        XCTAssertTrue(result)
        XCTAssertEqual(fileSystem.files[priorCommit], priorData)
        XCTAssertNotNil(fileSystem.files[recoveryVerifiedCommitURL(
            paths,
            recoveryID: fixedRecoveryID
        )])
        XCTAssertFalse(fileSystem.removedURLs.contains(priorAttempt))
        XCTAssertEqual(fileSystem.sourceFiles(for: paths), originals)
    }

    func testGuardFileSyncFailureDoesNotConsumeLegacyMarkerOrTouchPrimary() throws {
        let defaults = try makeDefaults("guard-sync-failure")
        defer { clear(defaults) }
        defaults.set(true, forKey: ProjectBootstrap.legacyOwnershipMigrationKey)
        let paths = testPaths("guard-sync-failure")
        let originals = sourceFiles(paths)
        let fileSystem = InMemoryLaunchFileSystem(
            files: originals,
            failures: [
                .fileSync(
                    lastPathComponent: paths.compatibilityActiveGuardURL
                        .lastPathComponent
                ),
            ]
        )
        let repository = FakeLaunchContainerRepository(fileSystem: fileSystem)

        XCTAssertThrowsError(try LaunchPersistenceContainerSelector.select(
            paths: paths,
            migrationStore: defaults,
            dependencies: .init(
                fileOperations: fileSystem.operations,
                now: { fixedRecoveryDate },
                makeRecoveryID: { fixedRecoveryID },
                openContainer: { url in
                    if url == paths.primaryStoreURL {
                        throw InjectedLaunchFailure.primaryOpen
                    }
                    return repository.open(url)
                },
                isUnknownModelVersion: { _ in false }
            )
        ))

        XCTAssertEqual(fileSystem.sourceFiles(for: paths), originals)
        XCTAssertTrue(fileSystem.copyCalls.isEmpty)
        XCTAssertFalse(defaults.bool(
            forKey: ProjectBootstrap.compatibilityFallbackActiveKey
        ))
        XCTAssertTrue(defaults.bool(
            forKey: ProjectBootstrap.legacyOwnershipMigrationKey
        ))
    }

    func testKnownLegacyClassifierAcceptsOnlyExactPreExplicitSignature() {
        XCTAssertEqual(
            LaunchPersistenceKnownLegacyStoreClassifier.classify(
                metadata: knownLegacyStoreMetadata()
            ),
            .preExplicitSchemaV1
        )
    }

    func testKnownLegacyClassifierRejectsExplicitV1ChecksumCollision() {
        var metadata = knownLegacyStoreMetadata()
        metadata["NSStoreModelVersionChecksumKey"] =
            "df3CbAxOVVJKxOmHskef4t1iO5rKU8+N9ZQ7ID9xMLY="

        XCTAssertNil(
            LaunchPersistenceKnownLegacyStoreClassifier.classify(
                metadata: metadata
            )
        )
    }

    func testKnownLegacyClassifierRejectsChangedEntitySet() {
        var metadata = knownLegacyStoreMetadata()
        var hashes = Dictionary(
            uniqueKeysWithValues: knownLegacyEntityNames.map { name in
                (name, Data("\(name)-hash".utf8) as Any)
            }
        )
        hashes["AgentRunRecord"] = Data("future-hash".utf8)
        metadata["NSStoreModelVersionHashes"] = hashes

        XCTAssertNil(
            LaunchPersistenceKnownLegacyStoreClassifier.classify(
                metadata: metadata
            )
        )
    }

    func testKnownLegacyClassifierRejectsChangedHashesDigest() {
        var metadata = knownLegacyStoreMetadata()
        metadata["NSStoreModelVersionHashesDigest"] = "changed-digest"

        XCTAssertNil(
            LaunchPersistenceKnownLegacyStoreClassifier.classify(
                metadata: metadata
            )
        )
    }

    func testKnownLegacyClassifierRejectsVersionIdentifierMismatch() {
        var metadata = knownLegacyStoreMetadata()
        metadata["NSStoreModelVersionIdentifiers"] = ["2.0.0"]

        XCTAssertNil(
            LaunchPersistenceKnownLegacyStoreClassifier.classify(
                metadata: metadata
            )
        )
    }

    func testKnownLegacyClassifierRejectsUnknownFutureChecksumAndVersion() {
        var metadata = knownLegacyStoreMetadata()
        metadata["NSStoreModelVersionChecksumKey"] = "future-checksum"
        metadata["NSStoreModelVersionHashesDigest"] = "future-digest"
        metadata["NSStoreModelVersionIdentifiers"] = ["99.0.0"]

        XCTAssertNil(
            LaunchPersistenceKnownLegacyStoreClassifier.classify(
                metadata: metadata
            )
        )
    }

    func testExplicitV1BridgeClassifierAcceptsOnlyReleasedV1Signature() {
        XCTAssertTrue(
            LaunchPersistenceExplicitV1StoreClassifier.matches(
                metadata: explicitV1StoreMetadata()
            )
        )

        var legacyCollision = explicitV1StoreMetadata()
        legacyCollision["NSStoreModelVersionChecksumKey"] =
            "aQOGil0EMr8AGv/erCZU9WHPLjisZqFlY+zxDBGc0Ag="
        XCTAssertFalse(
            LaunchPersistenceExplicitV1StoreClassifier.matches(
                metadata: legacyCollision
            )
        )

        var changedEntities = explicitV1StoreMetadata()
        changedEntities["NSStoreModelVersionHashes"] = [
            "Project": Data("changed".utf8),
        ]
        XCTAssertFalse(
            LaunchPersistenceExplicitV1StoreClassifier.matches(
                metadata: changedEntities
            )
        )
    }

    func testUnknownVersionClassifierRequiresExactCodeOrBothTextSemantics() {
        XCTAssertTrue(
            LaunchPersistenceErrorClassifier.isUnknownStagedMigrationVersion(
                makeUnknownModelVersionCodeOnlyError()
            )
        )
        XCTAssertTrue(
            LaunchPersistenceErrorClassifier.isUnknownStagedMigrationVersion(
                NSError(
                    domain: "NovaForge.TextOnly",
                    code: 17,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Cannot use staged migration with an unknown model version",
                    ]
                )
            )
        )

        let wrapped = NSError(
            domain: "NovaForge.Wrapper",
            code: 1,
            userInfo: [
                NSUnderlyingErrorKey: NSError(
                    domain: "NovaForge.Nested",
                    code: 2,
                    userInfo: [
                        NSLocalizedFailureReasonErrorKey:
                            "Unknown model version while staging migration",
                    ]
                ),
            ]
        )
        XCTAssertTrue(
            LaunchPersistenceErrorClassifier
                .isUnknownStagedMigrationVersion(wrapped)
        )

        for unrelated in [
            NSError(
                domain: "NovaForge.UnknownOnly",
                code: 3,
                userInfo: [
                    NSLocalizedDescriptionKey: "Unknown model version",
                ]
            ),
            NSError(
                domain: "NovaForge.StagedOnly",
                code: 4,
                userInfo: [
                    NSLocalizedDescriptionKey: "Staged migration failed",
                ]
            ),
            NSError(
                domain: NSCocoaErrorDomain,
                code: 134_503,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Unrelated persistent store failure",
                ]
            ),
        ] {
            XCTAssertFalse(
                LaunchPersistenceErrorClassifier
                    .isUnknownStagedMigrationVersion(unrelated)
            )
        }
    }

    #if DEBUG || targetEnvironment(simulator)
    func testDebugResetMovesAuthorityAndSwiftDataTogetherWhilePreservingUserState() throws {
        let root = try makeTemporaryDirectory("debug-reset-authority")
        defer { try? FileManager.default.removeItem(at: root) }
        let supportURL = root.appendingPathComponent(
            "ApplicationSupport",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: supportURL,
            withIntermediateDirectories: true
        )
        let paths = LaunchPersistenceStorePaths(supportURL: supportURL)

        let engineVersionURL = supportURL
            .appendingPathComponent("AgentEngine", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
        try FileManager.default.createDirectory(
            at: engineVersionURL,
            withIntermediateDirectories: true
        )
        try Data("lease".utf8).write(
            to: engineVersionURL.appendingPathComponent(
                ProductionAgentRecoveryLeadershipLeaseAcquirer.lockFileName
            )
        )
        try Data("index".utf8).write(
            to: engineVersionURL.appendingPathComponent(
                "run-ownership-index.ledger"
            )
        )

        let policyVersionURL = supportURL
            .appendingPathComponent("AgentPolicy", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
        try FileManager.default.createDirectory(
            at: policyVersionURL.appendingPathComponent(
                "checkpoints",
                isDirectory: true
            ),
            withIntermediateDirectories: true
        )
        try Data("policy".utf8).write(
            to: policyVersionURL.appendingPathComponent(
                "policy-authority.ledger"
            )
        )

        for url in sourceURLs(paths) {
            try Data("swiftdata".utf8).write(to: url)
        }
        let compatibilityDirectoryURL = paths.compatibilityStoreURL
            .deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: compatibilityDirectoryURL,
            withIntermediateDirectories: true
        )
        let compatibilityURLs = ["", "-wal", "-shm"].map {
            URL(fileURLWithPath: paths.compatibilityStoreURL.path + $0)
        }
        for url in compatibilityURLs {
            try Data("compatibility".utf8).write(to: url)
        }
        try Data("active".utf8).write(
            to: paths.compatibilityActiveGuardURL
        )

        let recoveryMarkerURL = paths.recoveryDirectoryURL
            .appendingPathComponent("keep-recovery")
        try FileManager.default.createDirectory(
            at: paths.recoveryDirectoryURL,
            withIntermediateDirectories: true
        )
        try Data("recovery".utf8).write(to: recoveryMarkerURL)
        let supportSiblingURL = supportURL.appendingPathComponent(
            "unrelated-state"
        )
        try Data("keep".utf8).write(to: supportSiblingURL)
        let workspaceURL = root
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("Workspaces", isDirectory: true)
            .appendingPathComponent("project.txt")
        try FileManager.default.createDirectory(
            at: workspaceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("workspace".utf8).write(to: workspaceURL)

        let defaults = try makeDefaults("debug-reset-authority")
        defer { clear(defaults) }
        defaults.set(
            true,
            forKey: ProjectBootstrap.compatibilityFallbackActiveKey
        )
        defaults.set("keep", forKey: "execution-node-sentinel")

        try LaunchDebugPersistenceReset.reset(
            at: supportURL,
            migrationStore: defaults
        )
        // A second reset proves the missing-target path remains idempotent.
        try LaunchDebugPersistenceReset.reset(
            at: supportURL,
            migrationStore: defaults
        )

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: supportURL.appendingPathComponent("AgentEngine").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: supportURL.appendingPathComponent("AgentPolicy").path
        ))
        for url in sourceURLs(paths) {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: paths.compatibilityActiveGuardURL.path
        ))
        for url in compatibilityURLs {
            XCTAssertEqual(try Data(contentsOf: url), Data("compatibility".utf8))
        }
        XCTAssertEqual(
            try Data(contentsOf: recoveryMarkerURL),
            Data("recovery".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: supportSiblingURL),
            Data("keep".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: workspaceURL),
            Data("workspace".utf8)
        )
        XCTAssertFalse(defaults.bool(
            forKey: ProjectBootstrap.compatibilityFallbackActiveKey
        ))
        XCTAssertEqual(
            defaults.string(forKey: "execution-node-sentinel"),
            "keep"
        )
    }

    func testDebugResetRejectsAuthoritySymlinkBeforeAnyMutation() throws {
        let root = try makeTemporaryDirectory("debug-reset-symlink")
        defer { try? FileManager.default.removeItem(at: root) }
        let supportURL = root.appendingPathComponent(
            "ApplicationSupport",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: supportURL,
            withIntermediateDirectories: true
        )
        let paths = LaunchPersistenceStorePaths(supportURL: supportURL)
        try Data("swiftdata".utf8).write(to: paths.primaryStoreURL)
        let outsideAuthorityURL = root.appendingPathComponent(
            "outside-engine",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outsideAuthorityURL,
            withIntermediateDirectories: true
        )
        let outsideMarkerURL = outsideAuthorityURL.appendingPathComponent(
            "must-survive"
        )
        try Data("outside".utf8).write(to: outsideMarkerURL)
        try FileManager.default.createSymbolicLink(
            at: supportURL.appendingPathComponent("AgentEngine"),
            withDestinationURL: outsideAuthorityURL
        )
        let defaults = try makeDefaults("debug-reset-symlink")
        defer { clear(defaults) }
        defaults.set(
            true,
            forKey: ProjectBootstrap.compatibilityFallbackActiveKey
        )

        XCTAssertThrowsError(
            try LaunchDebugPersistenceReset.reset(
                at: supportURL,
                migrationStore: defaults
            )
        ) { error in
            XCTAssertEqual(
                error as? LaunchDebugPersistenceResetError,
                .symbolicLinkRejected
            )
        }
        XCTAssertEqual(
            try Data(contentsOf: paths.primaryStoreURL),
            Data("swiftdata".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: outsideMarkerURL),
            Data("outside".utf8)
        )
        XCTAssertTrue(defaults.bool(
            forKey: ProjectBootstrap.compatibilityFallbackActiveKey
        ))
    }

    func testDebugResetAuthorityFailureNeverAttemptsSwiftDataRemoval() throws {
        let root = try makeTemporaryDirectory("debug-reset-failure-order")
        defer { try? FileManager.default.removeItem(at: root) }
        let supportURL = root.appendingPathComponent(
            "ApplicationSupport",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: supportURL.appendingPathComponent(
                "AgentEngine",
                isDirectory: true
            ),
            withIntermediateDirectories: true
        )
        let policyURL = supportURL.appendingPathComponent(
            "AgentPolicy",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: policyURL,
            withIntermediateDirectories: true
        )
        let paths = LaunchPersistenceStorePaths(supportURL: supportURL)
        for url in sourceURLs(paths) {
            try Data("swiftdata".utf8).write(to: url)
        }
        let defaults = try makeDefaults("debug-reset-failure-order")
        defer { clear(defaults) }
        defaults.set(
            true,
            forKey: ProjectBootstrap.compatibilityFallbackActiveKey
        )
        let live = LaunchDebugPersistenceReset.Dependencies.live(
            fileManager: .default
        )
        var removalAttempts: [URL] = []
        let dependencies = LaunchDebugPersistenceReset.Dependencies(
            removeItem: { url in
                removalAttempts.append(url)
                if url == policyURL { throw InjectedLaunchFailure.remove }
                try live.removeItem(url)
            },
            synchronizeDirectory: live.synchronizeDirectory
        )

        XCTAssertThrowsError(
            try LaunchDebugPersistenceReset.reset(
                at: supportURL,
                migrationStore: defaults,
                dependencies: dependencies
            )
        ) { error in
            XCTAssertEqual(
                error as? LaunchDebugPersistenceResetError,
                .fileSystemFailure
            )
        }
        XCTAssertEqual(
            removalAttempts.map(\.lastPathComponent),
            ["AgentEngine", "AgentPolicy"]
        )
        for url in sourceURLs(paths) {
            XCTAssertEqual(
                try Data(contentsOf: url),
                Data("swiftdata".utf8)
            )
        }
        XCTAssertTrue(defaults.bool(
            forKey: ProjectBootstrap.compatibilityFallbackActiveKey
        ))
    }

    func testDebugResetRejectsMissingOrUnexpectedSupportRoot() throws {
        XCTAssertThrowsError(try LaunchDebugPersistenceReset.reset(at: nil)) {
            XCTAssertEqual(
                $0 as? LaunchDebugPersistenceResetError,
                .supportDirectoryUnavailable
            )
        }

        let root = try makeTemporaryDirectory("debug-reset-invalid-root")
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("not-a-directory")
        try Data("file".utf8).write(to: fileURL)
        XCTAssertThrowsError(
            try LaunchDebugPersistenceReset.reset(at: fileURL)
        ) {
            XCTAssertEqual(
                $0 as? LaunchDebugPersistenceResetError,
                .invalidSupportDirectory
            )
        }
    }
    #endif
}

private final class FakeLaunchContainer {
    let url: URL
    var values: [String: String]

    init(url: URL, values: [String: String] = [:]) {
        self.url = url
        self.values = values
    }
}

private final class FakeLaunchContainerRepository {
    private let fileSystem: InMemoryLaunchFileSystem
    private var containers: [URL: FakeLaunchContainer] = [:]
    private(set) var openedURLs: [URL] = []

    init(fileSystem: InMemoryLaunchFileSystem) {
        self.fileSystem = fileSystem
    }

    func open(_ url: URL) -> FakeLaunchContainer {
        openedURLs.append(url)
        if let existing = containers[url] { return existing }
        fileSystem.files[url] = fileSystem.files[url] ?? Data("store".utf8)
        let container = FakeLaunchContainer(url: url)
        containers[url] = container
        return container
    }
}

private final class InMemoryLaunchFileSystem {
    enum Failure: Equatable {
        case copyAfterCreating(call: Int)
        case fileSync(lastPathComponent: String)
        case directorySync(lastPathComponent: String)
        case write(lastPathComponent: String)
        case remove(url: URL)
    }

    struct Mutation {
        let url: URL
        let fingerprintCall: Int
        let replacement: Data
    }

    struct CopyCall: Equatable {
        let source: URL
        let destination: URL
    }

    var files: [URL: Data]
    private(set) var directories: Set<URL>
    private(set) var copyCalls: [CopyCall] = []
    private(set) var removedSourceURLs: [URL] = []
    private(set) var removedURLs: [URL] = []
    private(set) var events: [String] = []
    private var fingerprintCalls: [URL: Int] = [:]
    private let failures: [Failure]
    private let mutation: Mutation?

    init(
        files: [URL: Data],
        directories: Set<URL> = [],
        failures: [Failure] = [],
        mutation: Mutation? = nil
    ) {
        self.files = files
        self.directories = directories
        self.failures = failures
        self.mutation = mutation
    }

    var operations: LaunchPersistenceFileOperations {
        LaunchPersistenceFileOperations(
            fileExists: { [self] in fileExists($0) },
            createDirectory: { [self] url in
                directories.insert(url)
                events.append("mkdir:\(url.lastPathComponent)")
            },
            createDirectoryExclusively: { [self] url in
                guard !fileExists(url) else {
                    throw InjectedLaunchFailure.destinationExists
                }
                directories.insert(url)
                events.append("mkdir-exclusive:\(url.lastPathComponent)")
            },
            copyItem: { [self] source, destination in
                copyCalls.append(.init(source: source, destination: destination))
                events.append("copy:\(destination.lastPathComponent)")
                guard !fileExists(destination) else {
                    throw InjectedLaunchFailure.destinationExists
                }
                guard let data = files[source] else {
                    throw InjectedLaunchFailure.fileMissing
                }
                files[destination] = data
                if failures.contains(.copyAfterCreating(call: copyCalls.count)) {
                    throw InjectedLaunchFailure.copy
                }
            },
            fingerprint: { [self] url in
                fingerprintCalls[url, default: 0] += 1
                if let mutation,
                   mutation.url == url,
                   mutation.fingerprintCall == fingerprintCalls[url] {
                    files[url] = mutation.replacement
                }
                guard let data = files[url] else {
                    throw InjectedLaunchFailure.fileMissing
                }
                return fingerprint(data)
            },
            removeItem: { [self] url in
                if failures.contains(.remove(url: url)) {
                    throw InjectedLaunchFailure.remove
                }
                events.append("remove:\(url.lastPathComponent)")
                removedURLs.append(url)
                if isSourceStoreURL(url) {
                    removedSourceURLs.append(url)
                }
                if directories.contains(url) {
                    let prefix = url.path.hasSuffix("/")
                        ? url.path
                        : url.path + "/"
                    files = files.filter { !$0.key.path.hasPrefix(prefix) }
                    directories = Set(directories.filter {
                        $0 != url && !$0.path.hasPrefix(prefix)
                    })
                } else {
                    files.removeValue(forKey: url)
                }
            },
            writeDataDurably: { [self] data, url in
                if failures.contains(.write(
                    lastPathComponent: url.lastPathComponent
                )) {
                    throw InjectedLaunchFailure.write
                }
                guard !fileExists(url) else {
                    throw InjectedLaunchFailure.destinationExists
                }
                files[url] = data
                events.append("write:\(url.lastPathComponent)")
            },
            readData: { [self] url in
                guard let data = files[url] else {
                    throw InjectedLaunchFailure.fileMissing
                }
                return data
            },
            synchronizeFile: { [self] url in
                events.append("file-sync:\(url.lastPathComponent)")
                if failures.contains(.fileSync(
                    lastPathComponent: url.lastPathComponent
                )) {
                    throw InjectedLaunchFailure.fileSync
                }
            },
            synchronizeDirectory: { [self] url in
                events.append("dir-sync:\(url.lastPathComponent)")
                if failures.contains(.directorySync(
                    lastPathComponent: url.lastPathComponent
                )) {
                    throw InjectedLaunchFailure.directorySync
                }
            }
        )
    }

    func fileExists(_ url: URL) -> Bool {
        files[url] != nil || directories.contains(url)
    }

    func sourceFiles(for paths: LaunchPersistenceStorePaths) -> [URL: Data] {
        Dictionary(uniqueKeysWithValues: sourceURLs(paths).compactMap { url in
            files[url].map { (url, $0) }
        })
    }

    private func isSourceStoreURL(_ url: URL) -> Bool {
        !url.path.contains("/RecoveredStores/") &&
            url.lastPathComponent.hasPrefix("NovaForge.store")
    }
}

private enum InjectedLaunchFailure: Error {
    case primaryOpen
    case fileMissing
    case destinationExists
    case copy
    case write
    case fileSync
    case directorySync
    case remove
}

private let testSuiteNameKey = "test-suite-name"
private let fixedRecoveryDate = Date(timeIntervalSince1970: 1_725_000_000.125)
private let fixedRecoveryID = UUID(
    uuidString: "11111111-2222-4333-8444-555555555555"
)!
private let secondRecoveryID = UUID(
    uuidString: "22222222-3333-4444-8555-666666666666"
)!
private let priorRecoveryID = UUID(
    uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
)!
private let sourceDataBySuffix: [String: Data] = [
    "": Data("main".utf8),
    "-wal": Data("wal".utf8),
    "-shm": Data("shm".utf8),
]

private let knownLegacyEntityNames = [
    "AgentSettings",
    "ChatMessage",
    "Conversation",
    "Project",
    "ProjectArtifact",
    "ProjectEvent",
    "ProjectFileChange",
    "ProjectOSRun",
    "ProjectOSStep",
    "TerminalCommandRecord",
    "ToolRun",
]

private let explicitV1EntityNames = knownLegacyEntityNames + [
    "AgentRunRecord",
    "ToolOperationRecord",
]

private struct PreExplicitFixtureMetadata: Decodable {
    struct Store: Decodable {
        struct SemanticDigest: Decodable {
            let canonicalization: String
            let algorithm: String
            let lineCount: Int
            let byteCount: Int
            let sha256: String
            let expectedAgentSettingsTemperature: Double
        }

        let schema: String
        let modelVersionIdentifiers: [String]
        let modelVersionChecksum: String
        let modelVersionHashesDigest: String
        let entityNames: [String]
        let sqliteQuickCheck: String
        let byteCount: Int
        let sha256: String
        let rowCounts: [String: Int]
        let semanticDigest: SemanticDigest
    }

    let formatVersion: Int
    let fixture: String
    let store: Store
}

private struct PreExplicitFixtureStoreSnapshot: Equatable {
    let rowCounts: [String: Int]
    let semanticLineCount: Int
    let semanticByteCount: Int
    let semanticSHA256: String
    let agentSettingsTemperature: Double?
    let currentSchemaCompanionRowCounts: [String: Int]
}

private struct PreExplicitFixtureMigrationResult {
    let mode: LaunchPersistenceContainerSelectionMode
    let storeURL: URL
    let isCompatibilityFallback: Bool
    let knownLegacyOpenCount: Int
    let snapshot: PreExplicitFixtureStoreSnapshot
}

private enum PreExplicitFixtureError: Error {
    case malformedSHA256Ledger
}

private func preExplicitFixtureDirectoryURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)
        .appendingPathComponent("NovaForgePreExplicitV1", isDirectory: true)
}

private func readSHA256Ledger(at url: URL) throws -> [String: String] {
    let contents = try String(contentsOf: url, encoding: .utf8)
    return try Dictionary(uniqueKeysWithValues: contents
        .split(whereSeparator: \.isNewline)
        .map { line in
            let fields = line.split(
                whereSeparator: \.isWhitespace
            )
            guard fields.count == 2 else {
                throw PreExplicitFixtureError.malformedSHA256Ledger
            }
            return (String(fields[1]), String(fields[0]))
        })
}

@MainActor
private func migratePreExplicitFixture(
    paths: LaunchPersistenceStorePaths,
    defaults: UserDefaults
) throws -> PreExplicitFixtureMigrationResult {
    let schema = Schema(versionedSchema: NovaForgeSchemaV4.self)
    var knownLegacyOpenCount = 0
    let selection = try LaunchPersistenceContainerSelector.select(
        paths: paths,
        migrationStore: defaults,
        dependencies: LaunchPersistenceContainerSelectionDependencies(
            fileOperations: .live,
            now: { fixedRecoveryDate },
            makeRecoveryID: { fixedRecoveryID },
            openContainer: { storeURL in
                try ModelContainer(
                    for: schema,
                    migrationPlan: NovaForgeSchemaMigrationPlan.self,
                    configurations: [ModelConfiguration(url: storeURL)]
                )
            },
            isUnknownModelVersion: LaunchPersistenceErrorClassifier
                .isUnknownStagedMigrationVersion,
            classifyKnownLegacyStore: { storeURL in
                LaunchPersistenceKnownLegacyStoreClassifier.classify(
                    storeAt: storeURL
                )
            },
            openKnownLegacyContainer: { storeURL in
                knownLegacyOpenCount += 1
                return try LaunchPersistenceKnownLegacyMigrator.openCurrentContainer(
                    storeAt: storeURL,
                    targetSchema: schema
                )
            }
        )
    )

    return try PreExplicitFixtureMigrationResult(
        mode: selection.mode,
        storeURL: selection.storeURL,
        isCompatibilityFallback: selection.isCompatibilityFallback,
        knownLegacyOpenCount: knownLegacyOpenCount,
        snapshot: preExplicitFixtureSnapshot(
            from: selection.container.mainContext
        )
    )
}

@MainActor
private func readCurrentV4Snapshot(
    at storeURL: URL
) throws -> PreExplicitFixtureStoreSnapshot {
    let schema = Schema(versionedSchema: NovaForgeSchemaV4.self)
    let container = try ModelContainer(
        for: schema,
        migrationPlan: NovaForgeSchemaMigrationPlan.self,
        configurations: [ModelConfiguration(url: storeURL)]
    )
    return try preExplicitFixtureSnapshot(from: container.mainContext)
}

@MainActor
private func preExplicitFixtureSnapshot(
    from context: ModelContext
) throws -> PreExplicitFixtureStoreSnapshot {
    let projects = try context.fetch(FetchDescriptor<Project>())
        .sorted { canonicalUUID($0.id) < canonicalUUID($1.id) }
    let events = try context.fetch(FetchDescriptor<ProjectEvent>())
        .sorted { canonicalUUID($0.id) < canonicalUUID($1.id) }
    let artifacts = try context.fetch(FetchDescriptor<ProjectArtifact>())
    let fileChanges = try context.fetch(FetchDescriptor<ProjectFileChange>())
    let projectOSRuns = try context.fetch(FetchDescriptor<ProjectOSRun>())
    let projectOSSteps = try context.fetch(FetchDescriptor<ProjectOSStep>())
    let terminalCommands = try context.fetch(
        FetchDescriptor<TerminalCommandRecord>()
    )
    let conversations = try context.fetch(FetchDescriptor<Conversation>())
        .sorted { canonicalUUID($0.id) < canonicalUUID($1.id) }
    let messages = try context.fetch(FetchDescriptor<ChatMessage>())
        .sorted { canonicalUUID($0.id) < canonicalUUID($1.id) }
    let toolRuns = try context.fetch(FetchDescriptor<ToolRun>())
        .sorted { canonicalUUID($0.id) < canonicalUUID($1.id) }
    let settings = try context.fetch(FetchDescriptor<AgentSettings>())
        .sorted { canonicalUUID($0.id) < canonicalUUID($1.id) }

    let rowCounts = [
        "ZAGENTSETTINGS": settings.count,
        "ZCHATMESSAGE": messages.count,
        "ZCONVERSATION": conversations.count,
        "ZPROJECT": projects.count,
        "ZPROJECTARTIFACT": artifacts.count,
        "ZPROJECTEVENT": events.count,
        "ZPROJECTFILECHANGE": fileChanges.count,
        "ZPROJECTOSRUN": projectOSRuns.count,
        "ZPROJECTOSSTEP": projectOSSteps.count,
        "ZTERMINALCOMMANDRECORD": terminalCommands.count,
        "ZTOOLRUN": toolRuns.count,
    ]

    var lines: [String] = []
    lines.reserveCapacity(rowCounts.values.reduce(0, +))
    lines.append(contentsOf: projects.map(canonicalProjectLine))
    lines.append(contentsOf: events.map(canonicalProjectEventLine))
    lines.append(contentsOf: conversations.map(canonicalConversationLine))
    lines.append(contentsOf: messages.map(canonicalMessageLine))
    lines.append(contentsOf: toolRuns.map(canonicalToolRunLine))
    lines.append(contentsOf: settings.map(canonicalSettingsLine))
    let semanticData = Data(
        (lines.joined(separator: "\n") + "\n").utf8
    )

    let companionCounts = [
        "AgentRunRecord": try context.fetch(
            FetchDescriptor<AgentRunRecord>()
        ).count,
        "ToolOperationRecord": try context.fetch(
            FetchDescriptor<ToolOperationRecord>()
        ).count,
        "AgentEventRecord": try context.fetch(
            FetchDescriptor<AgentEventRecord>()
        ).count,
        "PersistedAgentRunMetadataRecord": try context.fetch(
            FetchDescriptor<PersistedAgentRunMetadataRecord>()
        ).count,
        "ApprovalRequestRecord": try context.fetch(
            FetchDescriptor<ApprovalRequestRecord>()
        ).count,
        "ToolEffectEvidenceRecord": try context.fetch(
            FetchDescriptor<ToolEffectEvidenceRecord>()
        ).count,
        "ProjectionCursorRecord": try context.fetch(
            FetchDescriptor<ProjectionCursorRecord>()
        ).count,
        "ProjectionSnapshotRecord": try context.fetch(
            FetchDescriptor<ProjectionSnapshotRecord>()
        ).count,
        "ExecutionNodeRecord": try context.fetch(
            FetchDescriptor<ExecutionNodeRecord>()
        ).count,
        "AgentArtifactProjectionRecord": try context.fetch(
            FetchDescriptor<AgentArtifactProjectionRecord>()
        ).count,
        "ProjectMaterializedEvidenceRevisionRecord": try context.fetch(
            FetchDescriptor<ProjectMaterializedEvidenceRevisionRecord>()
        ).count,
        "AgentMaterializationDispositionRecord": try context.fetch(
            FetchDescriptor<AgentMaterializationDispositionRecord>()
        ).count,
        "PersistedAgentRunExecutionCompositionRecord": try context.fetch(
            FetchDescriptor<PersistedAgentRunExecutionCompositionRecord>()
        ).count,
    ]

    return PreExplicitFixtureStoreSnapshot(
        rowCounts: rowCounts,
        semanticLineCount: lines.count,
        semanticByteCount: semanticData.count,
        semanticSHA256: fingerprint(semanticData).sha256,
        agentSettingsTemperature: settings.first?.temperature,
        currentSchemaCompanionRowCounts: companionCounts
    )
}

private func assertPreExplicitFixtureSnapshot(
    _ snapshot: PreExplicitFixtureStoreSnapshot,
    matches metadata: PreExplicitFixtureMetadata,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(
        snapshot.rowCounts,
        metadata.store.rowCounts,
        file: file,
        line: line
    )
    XCTAssertEqual(
        snapshot.semanticLineCount,
        metadata.store.semanticDigest.lineCount,
        file: file,
        line: line
    )
    XCTAssertEqual(
        snapshot.semanticByteCount,
        metadata.store.semanticDigest.byteCount,
        file: file,
        line: line
    )
    XCTAssertEqual(
        snapshot.semanticSHA256,
        metadata.store.semanticDigest.sha256,
        file: file,
        line: line
    )
    if let temperature = snapshot.agentSettingsTemperature {
        XCTAssertEqual(
            temperature,
            metadata.store.semanticDigest.expectedAgentSettingsTemperature,
            accuracy: 0.000_000_000_001,
            file: file,
            line: line
        )
    } else {
        XCTFail(
            "Captured AgentSettings row disappeared during migration.",
            file: file,
            line: line
        )
    }
    XCTAssertTrue(
        snapshot.currentSchemaCompanionRowCounts.values.allSatisfy { $0 == 0 },
        "Additive V1-V4 companion tables must remain empty after migration.",
        file: file,
        line: line
    )
}

private func canonicalProjectLine(_ project: Project) -> String {
    [
        "project",
        canonicalUUID(project.id),
        canonicalHex(project.name),
        canonicalHex(project.mission),
        canonicalHex(project.statusRawValue),
        canonicalHex(project.workspaceName),
        canonicalHex(project.blocker),
        canonicalHex(project.nextStep),
        canonicalOptionalBool(project.autoContinueEnabledValue),
        canonicalOptionalBool(project.autoContinuePausedValue),
        project.autoContinueFailureStreakValue.map { String($0) } ?? "-",
        canonicalOptionalHex(project.autoContinueStateRawValue),
        canonicalOptionalHex(project.autoContinueSourceEventIDString),
        canonicalOptionalHex(project.autoContinueDecision),
    ].joined(separator: "|")
}

private func canonicalProjectEventLine(_ event: ProjectEvent) -> String {
    [
        "project-event",
        canonicalUUID(event.id),
        event.project.map { canonicalUUID($0.id) } ?? "-",
        canonicalHex(event.kindRawValue),
        canonicalHex(event.severityRawValue),
        canonicalHex(event.title),
        canonicalHex(event.detail),
        canonicalOptionalHex(event.sourceTypeRawValue),
        canonicalOptionalHex(event.sourceIDString),
        canonicalOptionalHex(event.metadataJSON),
    ].joined(separator: "|")
}

private func canonicalConversationLine(_ conversation: Conversation) -> String {
    [
        "conversation",
        canonicalUUID(conversation.id),
        conversation.project.map { canonicalUUID($0.id) } ?? "-",
        canonicalHex(conversation.title),
        String(conversation.messageCount),
        conversation.hasUserMessages ? "1" : "0",
        canonicalHex(conversation.lastMessagePreview),
    ].joined(separator: "|")
}

private func canonicalMessageLine(_ message: ChatMessage) -> String {
    [
        "message",
        canonicalUUID(message.id),
        message.conversation.map { canonicalUUID($0.id) } ?? "-",
        canonicalHex(message.roleRawValue),
        canonicalHex(message.content),
        canonicalOptionalHex(message.toolCallID),
        canonicalOptionalHex(message.toolCallsJSON),
    ].joined(separator: "|")
}

private func canonicalToolRunLine(_ toolRun: ToolRun) -> String {
    [
        "tool-run",
        canonicalUUID(toolRun.id),
        toolRun.project.map { canonicalUUID($0.id) } ?? "-",
        canonicalHex(toolRun.name),
        canonicalHex(toolRun.argumentsJSON),
        canonicalHex(toolRun.output),
        canonicalHex(toolRun.statusRawValue),
        toolRun.requiresApproval ? "1" : "0",
        toolRun.isMutating ? "1" : "0",
    ].joined(separator: "|")
}

private func canonicalSettingsLine(_ settings: AgentSettings) -> String {
    [
        "settings",
        canonicalUUID(settings.id),
        canonicalOptionalHex(settings.providerRawValue),
        canonicalHex(settings.modelID),
        canonicalOptionalHex(settings.customChatCompletionsURL),
        settings.autoApproveWrites ? "1" : "0",
        canonicalHex(settings.activeWorkspaceName),
        canonicalOptionalHex(settings.activeProjectIDString),
        canonicalOptionalHex(settings.customSystemPrompt),
    ].joined(separator: "|")
}

private func canonicalUUID(_ uuid: UUID) -> String {
    uuid.uuidString
        .replacingOccurrences(of: "-", with: "")
        .lowercased()
}

private func canonicalOptionalBool(_ value: Bool?) -> String {
    value.map { $0 ? "1" : "0" } ?? "-"
}

private func canonicalOptionalHex(_ value: String?) -> String {
    value.map(canonicalHex) ?? "-"
}

private func canonicalHex(_ value: String) -> String {
    let digits = Array("0123456789abcdef".utf8)
    var output: [UInt8] = []
    output.reserveCapacity(value.utf8.count * 2)
    for byte in value.utf8 {
        output.append(digits[Int(byte >> 4)])
        output.append(digits[Int(byte & 0x0f)])
    }
    return String(decoding: output, as: UTF8.self)
}

private func knownLegacyStoreMetadata() -> [String: Any] {
    [
        "NSStoreModelVersionChecksumKey":
            "aQOGil0EMr8AGv/erCZU9WHPLjisZqFlY+zxDBGc0Ag=",
        "NSStoreModelVersionHashesDigest":
            "masscU9dDKfkvThS8HL2SNsPQ8xkq3WNzYSvll3+5yodpVgBRY3wEcdeOCSL/1yTS43oIYe8fgLzUspAbHtuGg==",
        "NSStoreModelVersionIdentifiers": ["1.0.0"],
        "NSStoreModelVersionHashes": Dictionary(
            uniqueKeysWithValues: knownLegacyEntityNames.map { name in
                (name, Data("\(name)-hash".utf8) as Any)
            }
        ),
    ]
}

private func explicitV1StoreMetadata() -> [String: Any] {
    [
        "NSStoreModelVersionChecksumKey":
            "df3CbAxOVVJKxOmHskef4t1iO5rKU8+N9ZQ7ID9xMLY=",
        "NSStoreModelVersionHashesDigest":
            "OcI25dwnfUynOVuoNe7Nec0uP5Oq/MWjChDZ8Wko98px76e7Bt3AX4khfDW/UQeWzm+bC9dPmJ4sGmciUczMNA==",
        "NSStoreModelVersionIdentifiers": ["1.0.0"],
        "NSStoreModelVersionHashes": Dictionary(
            uniqueKeysWithValues: explicitV1EntityNames.map { name in
                (name, Data("\(name)-hash".utf8) as Any)
            }
        ),
    ]
}

@MainActor
private func writeDiskBackedFallback(
    paths: LaunchPersistenceStorePaths,
    defaults: UserDefaults,
    schema: Schema
) throws {
    let selection = try LaunchPersistenceContainerSelector.select(
        paths: paths,
        migrationStore: defaults,
        dependencies: LaunchPersistenceContainerSelectionDependencies(
            fileOperations: .live,
            now: { fixedRecoveryDate },
            makeRecoveryID: { fixedRecoveryID },
            openContainer: { url -> ModelContainer in
                if url == paths.primaryStoreURL {
                    throw makeUnknownModelVersionCodeOnlyError()
                }
                return try ModelContainer(
                    for: schema,
                    configurations: [ModelConfiguration(url: url)]
                )
            },
            isUnknownModelVersion: LaunchPersistenceErrorClassifier
                .isUnknownStagedMigrationVersion
        )
    )
    XCTAssertEqual(selection.mode, .unknownVersionCompatibility)
    selection.container.mainContext.insert(AgentSettings(
        modelID: "durable-model",
        activeWorkspaceName: "Durable fallback"
    ))
    try selection.container.mainContext.save()
}

private func testPaths(_ name: String) -> LaunchPersistenceStorePaths {
    LaunchPersistenceStorePaths(
        supportURL: URL(fileURLWithPath: "/launch-recovery-tests/\(name)")
    )
}

private func sourceURLs(_ paths: LaunchPersistenceStorePaths) -> [URL] {
    ["", "-wal", "-shm"].map {
        URL(fileURLWithPath: paths.primaryStoreURL.path + $0)
    }
}

private func sourceFiles(
    _ paths: LaunchPersistenceStorePaths
) -> [URL: Data] {
    Dictionary(uniqueKeysWithValues: sourceDataBySuffix.map { suffix, data in
        (URL(fileURLWithPath: paths.primaryStoreURL.path + suffix), data)
    })
}

private func recoveryStoreURL(
    _ paths: LaunchPersistenceStorePaths,
    recoveryID: UUID,
    suffix: String
) -> URL {
    paths.recoveryAttemptDirectoryURL(recoveryID: recoveryID)
        .appendingPathComponent(paths.primaryStoreURL.lastPathComponent + suffix)
}

private func recoveryManifestURL(
    _ paths: LaunchPersistenceStorePaths,
    recoveryID: UUID
) -> URL {
    paths.recoveryAttemptDirectoryURL(recoveryID: recoveryID)
        .appendingPathComponent(LaunchPersistenceStoreQuarantine.manifestFileName)
}

private func recoveryVerifiedCommitURL(
    _ paths: LaunchPersistenceStorePaths,
    recoveryID: UUID
) -> URL {
    paths.recoveryAttemptDirectoryURL(recoveryID: recoveryID)
        .appendingPathComponent(
            LaunchPersistenceStoreQuarantine.verifiedCommitFileName
        )
}

private func fingerprint(_ data: Data) -> LaunchPersistenceFileFingerprint {
    LaunchPersistenceFileFingerprint(
        byteCount: UInt64(data.count),
        sha256: SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    )
}

private func makeUnknownModelVersionCodeOnlyError() -> NSError {
    NSError(domain: NSCocoaErrorDomain, code: 134_504, userInfo: [:])
}

private func makeTemporaryDirectory(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "NovaForgeLaunchRecovery-\(name)-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: true
    )
    return url
}

private func writeSourceFiles(_ paths: LaunchPersistenceStorePaths) throws {
    for (url, data) in sourceFiles(paths) {
        try data.write(to: url, options: .withoutOverwriting)
    }
}

private func readSourceFiles(
    _ paths: LaunchPersistenceStorePaths
) throws -> [URL: Data] {
    try Dictionary(uniqueKeysWithValues: sourceURLs(paths).map { url in
        (url, try Data(contentsOf: url))
    })
}

private func makeDefaults(_ name: String) throws -> UserDefaults {
    let suite = "NovaForgeLaunchPersistenceRecovery-\(name)-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else {
        throw InjectedLaunchFailure.fileMissing
    }
    defaults.set(suite, forKey: testSuiteNameKey)
    return defaults
}

private func clear(_ defaults: UserDefaults) {
    guard let suite = defaults.string(forKey: testSuiteNameKey) else { return }
    defaults.removePersistentDomain(forName: suite)
}
