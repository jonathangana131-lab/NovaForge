import XCTest
@testable import NovaForge

final class AgentApprovalSigningKeyStoreTests: XCTestCase {
    func testReadExistingUsesCanonicalAccountAndAcceptsBoundedMaterial() throws {
        for byteCount in [32, 48, 64] {
            let bytes = Data(repeating: UInt8(byteCount), count: byteCount)
            let keychain = SigningKeyKeychainFixture(
                lookups: [
                    .item(
                        data: bytes,
                        accessibility: .whenUnlockedThisDeviceOnly
                    ),
                ]
            )
            let random = SigningKeyRandomFixture(data: Data(repeating: 9, count: 32))
            let store = AgentApprovalSigningKeyStore(
                keychain: keychain,
                randomGenerator: random
            )

            let key = try store.readExistingKey()

            XCTAssertEqual(key.byteCount, byteCount)
            XCTAssertEqual(key.withKeyData { $0 }, bytes)
            XCTAssertEqual(
                keychain.lookupRequests,
                [
                    .init(
                        service: "com.joey.NovaForge",
                        account: "agent-policy.approval-ui-hmac.v1"
                    ),
                ]
            )
            XCTAssertTrue(keychain.insertRequests.isEmpty)
            XCTAssertTrue(random.requestedCounts.isEmpty)
        }
    }

    func testReadExistingRejectsMissingWithoutGeneratingFallback() {
        let keychain = SigningKeyKeychainFixture(lookups: [.notFound])
        let random = SigningKeyRandomFixture(data: Data(repeating: 1, count: 32))
        let store = AgentApprovalSigningKeyStore(
            keychain: keychain,
            randomGenerator: random
        )

        assertKeyError(.missing) { _ = try store.readExistingKey() }
        XCTAssertTrue(random.requestedCounts.isEmpty)
        XCTAssertTrue(keychain.insertRequests.isEmpty)
    }

    func testReadOrCreateGeneratesExactly32BytesWithDeviceOnlyProtection() throws {
        let generated = Data((0 ..< 32).map(UInt8.init))
        let keychain = SigningKeyKeychainFixture(
            lookups: [
                .notFound,
                .item(
                    data: generated,
                    accessibility: .whenUnlockedThisDeviceOnly
                ),
            ],
            insertResult: .inserted
        )
        let random = SigningKeyRandomFixture(data: generated)
        let store = AgentApprovalSigningKeyStore(
            keychain: keychain,
            randomGenerator: random
        )

        let key = try store.readOrCreateKey()

        XCTAssertEqual(key.withKeyData { $0 }, generated)
        XCTAssertEqual(random.requestedCounts, [32])
        XCTAssertEqual(keychain.insertRequests.count, 1)
        XCTAssertEqual(keychain.insertRequests.first?.data, generated)
        XCTAssertEqual(
            keychain.insertRequests.first?.service,
            "com.joey.NovaForge"
        )
        XCTAssertEqual(
            keychain.insertRequests.first?.account,
            "agent-policy.approval-ui-hmac.v1"
        )
        XCTAssertEqual(
            keychain.insertRequests.first?.accessibility,
            .whenUnlockedThisDeviceOnly
        )
        XCTAssertEqual(keychain.lookupRequests.count, 2)
    }

    func testReadOrCreateIsIdempotentWhenValidItemExists() throws {
        let existing = Data(repeating: 0xA5, count: 32)
        let keychain = SigningKeyKeychainFixture(
            lookups: [
                .item(
                    data: existing,
                    accessibility: .whenUnlockedThisDeviceOnly
                ),
            ]
        )
        let random = SigningKeyRandomFixture(data: Data(repeating: 2, count: 32))
        let store = AgentApprovalSigningKeyStore(
            keychain: keychain,
            randomGenerator: random
        )

        let key = try store.readOrCreateKey()

        XCTAssertEqual(key.withKeyData { $0 }, existing)
        XCTAssertTrue(random.requestedCounts.isEmpty)
        XCTAssertTrue(keychain.insertRequests.isEmpty)
    }

    func testDuplicateInsertRaceReturnsOnlyValidatedWinningItem() throws {
        let losingCandidate = Data(repeating: 0x11, count: 32)
        let winningItem = Data(repeating: 0x22, count: 32)
        let keychain = SigningKeyKeychainFixture(
            lookups: [
                .notFound,
                .item(
                    data: winningItem,
                    accessibility: .whenUnlockedThisDeviceOnly
                ),
            ],
            insertResult: .duplicate
        )
        let store = AgentApprovalSigningKeyStore(
            keychain: keychain,
            randomGenerator: SigningKeyRandomFixture(data: losingCandidate)
        )

        let key = try store.readOrCreateKey()

        XCTAssertEqual(key.withKeyData { $0 }, winningItem)
        XCTAssertNotEqual(key.withKeyData { $0 }, losingCandidate)
        XCTAssertEqual(keychain.lookupRequests.count, 2)
        XCTAssertEqual(keychain.insertRequests.count, 1)
    }

    func testDuplicateRaceWithDisappearingWinnerFailsWithoutRetry() {
        let keychain = SigningKeyKeychainFixture(
            lookups: [.notFound, .notFound],
            insertResult: .duplicate
        )
        let random = SigningKeyRandomFixture(data: Data(repeating: 3, count: 32))
        let store = AgentApprovalSigningKeyStore(
            keychain: keychain,
            randomGenerator: random
        )

        assertKeyError(.missing) { _ = try store.readOrCreateKey() }
        XCTAssertEqual(random.requestedCounts, [32])
        XCTAssertEqual(keychain.insertRequests.count, 1)
        XCTAssertEqual(keychain.lookupRequests.count, 2)
    }

    func testSuccessfulInsertStillRequiresValidPersistedPostcondition() {
        let keychain = SigningKeyKeychainFixture(
            lookups: [.notFound, .notFound],
            insertResult: .inserted
        )
        let store = AgentApprovalSigningKeyStore(
            keychain: keychain,
            randomGenerator: SigningKeyRandomFixture(
                data: Data(repeating: 0x33, count: 32)
            )
        )

        assertKeyError(.missing) { _ = try store.readOrCreateKey() }
        XCTAssertEqual(keychain.insertRequests.count, 1)
        XCTAssertEqual(keychain.lookupRequests.count, 2)
    }

    func testCorruptUndersizedOversizedAndWrongProtectionNeverSelfHeal() {
        let cases: [(AgentApprovalSigningKeychainLookup, AgentApprovalSigningKeyStoreError)] = [
            (.malformed, .corrupt),
            (
                .item(
                    data: Data(repeating: 1, count: 31),
                    accessibility: .whenUnlockedThisDeviceOnly
                ),
                .undersized
            ),
            (
                .item(
                    data: Data(repeating: 1, count: 65),
                    accessibility: .whenUnlockedThisDeviceOnly
                ),
                .oversized
            ),
            (
                .item(
                    data: Data(repeating: 1, count: 32),
                    accessibility: .unexpected
                ),
                .unexpectedAccessibility
            ),
        ]

        for (lookup, expectedError) in cases {
            let keychain = SigningKeyKeychainFixture(lookups: [lookup])
            let random = SigningKeyRandomFixture(
                data: Data(repeating: 4, count: 32)
            )
            let store = AgentApprovalSigningKeyStore(
                keychain: keychain,
                randomGenerator: random
            )

            assertKeyError(expectedError) { _ = try store.readOrCreateKey() }
            XCTAssertTrue(random.requestedCounts.isEmpty)
            XCTAssertTrue(keychain.insertRequests.isEmpty)
        }
    }

    func testRandomFailureAndWrongLengthNeverReachKeychainInsert() {
        let failingKeychain = SigningKeyKeychainFixture(lookups: [.notFound])
        let failingRandom = SigningKeyRandomFixture(
            data: Data(),
            shouldFail: true
        )
        let failingStore = AgentApprovalSigningKeyStore(
            keychain: failingKeychain,
            randomGenerator: failingRandom
        )
        assertKeyError(.randomGenerationFailed) {
            _ = try failingStore.readOrCreateKey()
        }
        XCTAssertTrue(failingKeychain.insertRequests.isEmpty)

        let shortKeychain = SigningKeyKeychainFixture(lookups: [.notFound])
        let shortStore = AgentApprovalSigningKeyStore(
            keychain: shortKeychain,
            randomGenerator: SigningKeyRandomFixture(
                data: Data(repeating: 5, count: 31)
            )
        )
        assertKeyError(.randomGenerationFailed) {
            _ = try shortStore.readOrCreateKey()
        }
        XCTAssertTrue(shortKeychain.insertRequests.isEmpty)
    }

    func testBackendFailuresAreCollapsedAndNeverLeakBackendText() {
        let secretMarker = "DO-NOT-LEAK-001122334455"
        let lookupFailure = SigningKeyKeychainFixture(
            lookups: [],
            lookupErrorText: secretMarker
        )
        let store = AgentApprovalSigningKeyStore(
            keychain: lookupFailure,
            randomGenerator: SigningKeyRandomFixture(
                data: Data(repeating: 6, count: 32)
            )
        )

        do {
            _ = try store.readExistingKey()
            XCTFail("Expected failure")
        } catch {
            XCTAssertEqual(
                error as? AgentApprovalSigningKeyStoreError,
                .keychainFailure
            )
            XCTAssertFalse(String(describing: error).contains(secretMarker))
        }

        let insertFailure = SigningKeyKeychainFixture(
            lookups: [.notFound],
            insertErrorText: secretMarker
        )
        let insertStore = AgentApprovalSigningKeyStore(
            keychain: insertFailure,
            randomGenerator: SigningKeyRandomFixture(
                data: Data(repeating: 7, count: 32)
            )
        )
        assertKeyError(.keychainFailure) {
            _ = try insertStore.readOrCreateKey()
        }
        XCTAssertEqual(insertFailure.insertRequests.count, 1)
    }

    func testKeyAndErrorsHaveRedactedDescriptions() throws {
        let secret = Data((0 ..< 32).map(UInt8.init))
        let keychain = SigningKeyKeychainFixture(
            lookups: [
                .item(
                    data: secret,
                    accessibility: .whenUnlockedThisDeviceOnly
                ),
            ]
        )
        let key = try AgentApprovalSigningKeyStore(
            keychain: keychain,
            randomGenerator: SigningKeyRandomFixture(data: secret)
        ).readExistingKey()

        let rendered = String(describing: key)
        let debugRendered = String(reflecting: key)
        XCTAssertEqual(rendered, "<AgentApprovalSigningKey: redacted>")
        XCTAssertEqual(debugRendered, "<AgentApprovalSigningKey: redacted>")
        XCTAssertFalse(rendered.contains(secret.base64EncodedString()))
        XCTAssertFalse(debugRendered.contains(secret.base64EncodedString()))

        for error in [
            AgentApprovalSigningKeyStoreError.missing,
            .corrupt,
            .undersized,
            .oversized,
            .unexpectedAccessibility,
            .randomGenerationFailed,
            .keychainFailure,
        ] {
            XCTAssertFalse(String(describing: error).contains("001122"))
            XCTAssertFalse(String(describing: error).contains("base64"))
        }
    }

    #if targetEnvironment(simulator)
    func testUnsignedSimulatorFileClientPersistsWithoutOverwritingAuthority()
        throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("approval-key")
        let client = AgentApprovalSigningSimulatorFileClient(fileURL: url)
        let bytes = Data(repeating: 0xA7, count: 32)

        XCTAssertEqual(
            try client.lookup(service: "service", account: "account"),
            .notFound
        )
        XCTAssertEqual(
            try client.insert(
                bytes,
                service: "service",
                account: "account",
                accessibility: .whenUnlockedThisDeviceOnly
            ),
            .inserted
        )
        XCTAssertEqual(
            try client.insert(
                Data(repeating: 0xFF, count: 32),
                service: "service",
                account: "account",
                accessibility: .whenUnlockedThisDeviceOnly
            ),
            .duplicate
        )
        XCTAssertEqual(
            try client.lookup(service: "service", account: "account"),
            .item(
                data: bytes,
                accessibility: .whenUnlockedThisDeviceOnly
            )
        )
        let permissions = try FileManager.default.attributesOfItem(
            atPath: url.path
        )[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }
    #endif

    private func assertKeyError(
        _ expected: AgentApprovalSigningKeyStoreError,
        operation: () throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            try operation()
            XCTFail("Expected signing-key failure", file: file, line: line)
        } catch let error as AgentApprovalSigningKeyStoreError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected error type", file: file, line: line)
        }
    }
}

private final class SigningKeyKeychainFixture:
    AgentApprovalSigningKeychainClient,
    @unchecked Sendable
{
    struct Request: Equatable {
        let service: String
        let account: String
    }

    struct InsertRequest: Equatable {
        let data: Data
        let service: String
        let account: String
        let accessibility: AgentApprovalSigningKeyAccessibility
    }

    struct SecretBearingFailure: Error, CustomStringConvertible {
        let text: String
        var description: String { text }
    }

    var lookups: [AgentApprovalSigningKeychainLookup]
    let insertResult: AgentApprovalSigningKeychainInsertResult
    let lookupErrorText: String?
    let insertErrorText: String?
    var lookupRequests: [Request] = []
    var insertRequests: [InsertRequest] = []

    init(
        lookups: [AgentApprovalSigningKeychainLookup],
        insertResult: AgentApprovalSigningKeychainInsertResult = .inserted,
        lookupErrorText: String? = nil,
        insertErrorText: String? = nil
    ) {
        self.lookups = lookups
        self.insertResult = insertResult
        self.lookupErrorText = lookupErrorText
        self.insertErrorText = insertErrorText
    }

    func lookup(
        service: String,
        account: String
    ) throws -> AgentApprovalSigningKeychainLookup {
        lookupRequests.append(.init(service: service, account: account))
        if let lookupErrorText {
            throw SecretBearingFailure(text: lookupErrorText)
        }
        guard !lookups.isEmpty else { return .notFound }
        return lookups.removeFirst()
    }

    func insert(
        _ data: Data,
        service: String,
        account: String,
        accessibility: AgentApprovalSigningKeyAccessibility
    ) throws -> AgentApprovalSigningKeychainInsertResult {
        insertRequests.append(
            .init(
                data: data,
                service: service,
                account: account,
                accessibility: accessibility
            )
        )
        if let insertErrorText {
            throw SecretBearingFailure(text: insertErrorText)
        }
        return insertResult
    }
}

private final class SigningKeyRandomFixture:
    AgentApprovalSigningKeyRandomGenerating,
    @unchecked Sendable
{
    struct FixtureError: Error {}

    let data: Data
    let shouldFail: Bool
    var requestedCounts: [Int] = []

    init(data: Data, shouldFail: Bool = false) {
        self.data = data
        self.shouldFail = shouldFail
    }

    func randomBytes(count: Int) throws -> Data {
        requestedCounts.append(count)
        if shouldFail { throw FixtureError() }
        return data
    }
}
