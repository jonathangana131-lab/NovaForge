import Foundation
import XCTest

final class KeychainStoreTests: XCTestCase {
    func testInvalidAccountsAreRejectedBeforeSecurityLookup() {
        let store = KeychainStore()
        let invalidAccounts = [
            "",
            " leading",
            "trailing ",
            "line\nfeed",
            "format\u{200D}scalar",
            String(repeating: "a", count: 257),
        ]

        for account in invalidAccounts {
            assertInvalidAccount { _ = try store.read(account) }
            assertInvalidAccount { try store.save("secret", account: account) }
            assertInvalidAccount { try store.delete(account) }
        }
    }

    func testEmptyAndOversizedSecretsAreRejectedBeforeSecurityWrite() {
        let store = KeychainStore()

        assertInvalidValue { try store.save("", account: "test_account") }
        assertInvalidValue {
            try store.save(
                String(repeating: "s", count: KeychainStore.maximumSecretBytes + 1),
                account: "test_account"
            )
        }
    }

    func testEveryProviderCredentialAccountIsCanonicalAndBounded() {
        for provider in AIProvider.allCases {
            let account = provider.apiKeyAccount
            XCTAssertFalse(account.isEmpty)
            XCTAssertLessThanOrEqual(account.utf8.count, 256)
            XCTAssertEqual(
                account,
                account.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            XCTAssertTrue(account.unicodeScalars.allSatisfy { scalar in
                !CharacterSet.whitespacesAndNewlines.contains(scalar) &&
                    !CharacterSet.controlCharacters.contains(scalar) &&
                    scalar.properties.generalCategory != .format
            })
        }
    }

    func testOnlyExplicitZenFreeRoutesCanRunWithoutCredentials() {
        XCTAssertFalse(
            AIProvider.openCodeZen.requiresCredential(
                for: "mimo-v2.5-free"
            )
        )
        XCTAssertFalse(
            AIProvider.openCodeZen.requiresCredential(
                for: " NORTH-MINI-CODE-FREE "
            )
        )
        XCTAssertTrue(
            AIProvider.openCodeZen.requiresCredential(for: "glm-5.1")
        )
        XCTAssertTrue(
            AIProvider.openAI.requiresCredential(for: "gpt-5.1")
        )
        XCTAssertFalse(
            AIProvider.local.requiresCredential(for: "qwen3-0.6b-q4")
        )
    }

    @MainActor
    func testCodexDeviceLoginForcesFreshCredentialEntry() throws {
        let components = try XCTUnwrap(
            URLComponents(
                url: OpenAICodexAuthManager.verificationURL,
                resolvingAgainstBaseURL: false
            )
        )

        XCTAssertEqual(components.host, "auth.openai.com")
        XCTAssertEqual(components.path, "/codex/device")
        XCTAssertEqual(
            components.queryItems,
            [
                URLQueryItem(name: "prompt", value: "login"),
                URLQueryItem(name: "max_age", value: "0"),
            ]
        )
    }

    func testDeviceCodeParserAcceptsCurrentAndLegacyUserCodeFields() throws {
        let current = try OpenAICodexOAuthWire.deviceCode(from: Data(
            #"{"user_code":"NOW-123","device_auth_id":"device-current","interval":7}"#.utf8
        ))
        let legacy = try OpenAICodexOAuthWire.deviceCode(from: Data(
            #"{"usercode":"OLD-456","device_auth_id":"device-legacy","interval":"9"}"#.utf8
        ))

        XCTAssertEqual(current.userCode, "NOW-123")
        XCTAssertEqual(current.interval, .seconds(7))
        XCTAssertEqual(legacy.userCode, "OLD-456")
        XCTAssertEqual(legacy.interval, .seconds(9))
    }

    func testOAuthTokenParserKeepsLargeValidChatGPTTokens() throws {
        let accessToken = "header." + String(repeating: "a", count: 12_000) + ".sig"
        let idToken = "header." + String(repeating: "i", count: 8_000) + ".sig"
        let payload = try JSONSerialization.data(withJSONObject: [
            "access_token": accessToken,
            "refresh_token": "refresh-token",
            "id_token": idToken,
        ])

        let tokens = try OpenAICodexOAuthWire.tokens(from: payload)

        XCTAssertEqual(tokens.accessToken, accessToken)
        XCTAssertEqual(tokens.refreshToken, "refresh-token")
        XCTAssertEqual(tokens.idToken, idToken)
    }

    func testOAuthTokenParserRejectsOversizedOrMultilineSecrets() throws {
        let oversized = try JSONSerialization.data(withJSONObject: [
            "access_token": String(
                repeating: "x",
                count: KeychainStore.maximumSecretBytes + 1
            ),
        ])
        let multiline = try JSONSerialization.data(withJSONObject: [
            "access_token": "token\nsmuggled-header",
        ])

        XCTAssertThrowsError(try OpenAICodexOAuthWire.tokens(from: oversized))
        XCTAssertThrowsError(try OpenAICodexOAuthWire.tokens(from: multiline))
    }

    private func assertInvalidAccount(
        _ operation: () throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            try operation()
            XCTFail("Expected invalid account rejection", file: file, line: line)
        } catch let error as KeychainError {
            guard case .invalidAccount = error else {
                return XCTFail("Unexpected KeychainError: \(error)", file: file, line: line)
            }
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    private func assertInvalidValue(
        _ operation: () throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            try operation()
            XCTFail("Expected invalid value rejection", file: file, line: line)
        } catch let error as KeychainError {
            guard case .invalidValue = error else {
                return XCTFail("Unexpected KeychainError: \(error)", file: file, line: line)
            }
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }
}

@MainActor
final class OpenAICodexAuthManagerTests: XCTestCase {
    func testCancelledRefreshCannotPersistAfterExplicitLoginTakesOwnership()
        async
    {
        let credentials = AuthCredentialMemory(values: [
            OpenAICodexAuthManager.accessTokenAccount:
                expiredJWT(expiration: 1),
            OpenAICodexAuthManager.refreshTokenAccount: "stored-refresh",
        ])
        let refreshGate = AuthRefreshGate()
        var refreshReturned = false
        let dependencies = OpenAICodexAuthDependencies(
            readCredential: { credentials.read($0) },
            saveCredential: { credentials.save($0, account: $1) },
            deleteCredential: { credentials.delete($0) },
            requestDeviceCode: {
                OpenAICodexDeviceCode(
                    userCode: "LOGIN-OWNS",
                    deviceAuthID: "login-owns-device",
                    interval: .seconds(3)
                )
            },
            waitForApproval: { _ in
                OpenAICodexApprovalExchange(
                    authorizationCode: "login-owns-code",
                    codeVerifier: "login-owns-verifier",
                    codeChallenge: "login-owns-challenge"
                )
            },
            exchange: { _ in
                .init(
                    accessToken: "device-login-access",
                    refreshToken: "device-login-refresh",
                    idToken: nil
                )
            },
            refresh: {
                let tokens = try await refreshGate.refresh($0)
                refreshReturned = true
                return tokens
            },
            copyUserCode: { _ in },
            clearModelCatalog: {},
            now: { Date(timeIntervalSince1970: 10_000) }
        )
        let manager = OpenAICodexAuthManager(dependencies: dependencies)
        let refreshStarted = await refreshGate.waitUntilStarted()
        XCTAssertTrue(refreshStarted)

        manager.startLogin()
        let loginCompleted = await authEventually { manager.isSignedIn }
        XCTAssertTrue(loginCompleted)
        XCTAssertEqual(
            credentials.values[OpenAICodexAuthManager.accessTokenAccount],
            "device-login-access"
        )

        await refreshGate.complete(.init(
            accessToken: "stale-refresh-access",
            refreshToken: "stale-refresh-token",
            idToken: nil
        ))
        let staleRefreshReturned = await authEventually { refreshReturned }
        XCTAssertTrue(staleRefreshReturned)

        XCTAssertTrue(manager.isSignedIn)
        XCTAssertEqual(
            credentials.values[OpenAICodexAuthManager.accessTokenAccount],
            "device-login-access"
        )
        XCTAssertFalse(
            credentials.saveEvents.contains {
                $0.value == "stale-refresh-access"
            }
        )
    }

    func testCancelledStaleLoginCannotPersistOrOverwriteNewerLogin() async {
        let credentials = AuthCredentialMemory()
        let exchangeGate = AuthExchangeGate()
        var deviceCodeCallCount = 0
        var copiedCodes: [String] = []
        var returnedAuthorizationCodes: Set<String> = []
        let dependencies = OpenAICodexAuthDependencies(
            readCredential: { credentials.read($0) },
            saveCredential: { credentials.save($0, account: $1) },
            deleteCredential: { credentials.delete($0) },
            requestDeviceCode: {
                deviceCodeCallCount += 1
                return OpenAICodexDeviceCode(
                    userCode: "CODE-\(deviceCodeCallCount)",
                    deviceAuthID: "device-\(deviceCodeCallCount)",
                    interval: .seconds(3)
                )
            },
            waitForApproval: { code in
                OpenAICodexApprovalExchange(
                    authorizationCode: code.userCode,
                    codeVerifier: "verifier",
                    codeChallenge: "challenge"
                )
            },
            exchange: { exchange in
                let tokens = try await exchangeGate.exchange(exchange)
                returnedAuthorizationCodes.insert(exchange.authorizationCode)
                return tokens
            },
            refresh: { _ in throw AuthFixtureError.unexpectedRefresh },
            copyUserCode: { copiedCodes.append($0) },
            clearModelCatalog: {},
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        let manager = OpenAICodexAuthManager(
            dependencies: dependencies,
            refreshStoredStatusOnInit: false
        )

        manager.startLogin()
        let firstExchangeStarted = await exchangeGate.waitForCallCount(1)
        XCTAssertTrue(firstExchangeStarted)
        manager.startLogin()
        let secondExchangeStarted = await exchangeGate.waitForCallCount(2)
        XCTAssertTrue(secondExchangeStarted)

        await exchangeGate.complete(
            authorizationCode: "CODE-1",
            tokens: .init(
                accessToken: "stale-access",
                refreshToken: "stale-refresh",
                idToken: nil
            )
        )
        let staleLoginReturned = await authEventually {
            returnedAuthorizationCodes.contains("CODE-1")
        }
        XCTAssertTrue(staleLoginReturned)

        XCTAssertTrue(credentials.saveEvents.isEmpty)
        XCTAssertEqual(copiedCodes, ["CODE-1", "CODE-2"])
        guard case .exchanging = manager.state else {
            return XCTFail("The stale operation overwrote the newer login state")
        }

        await exchangeGate.complete(
            authorizationCode: "CODE-2",
            tokens: .init(
                accessToken: "current-access",
                refreshToken: "current-refresh",
                idToken: nil
            )
        )
        let currentLoginCompleted = await authEventually { manager.isSignedIn }
        XCTAssertTrue(currentLoginCompleted)
        XCTAssertEqual(
            credentials.values[OpenAICodexAuthManager.accessTokenAccount],
            "current-access"
        )
        XCTAssertEqual(
            credentials.values[OpenAICodexAuthManager.refreshTokenAccount],
            "current-refresh"
        )
        XCTAssertFalse(
            credentials.saveEvents.contains { $0.value == "stale-access" }
        )
    }

    func testExplicitRetryFromFailedDoesNotSpawnStoredTokenRefresh() async {
        let credentials = AuthCredentialMemory()
        var deviceCodeCallCount = 0
        var refreshCallCount = 0
        let dependencies = OpenAICodexAuthDependencies(
            readCredential: { credentials.read($0) },
            saveCredential: { credentials.save($0, account: $1) },
            deleteCredential: { credentials.delete($0) },
            requestDeviceCode: {
                deviceCodeCallCount += 1
                throw AuthFixtureError.expectedDeviceCodeFailure
            },
            waitForApproval: { _ in
                throw AuthFixtureError.unexpectedApproval
            },
            exchange: { _ in throw AuthFixtureError.unexpectedExchange },
            refresh: { _ in
                refreshCallCount += 1
                return .init(
                    accessToken: "unexpected-refreshed-access",
                    refreshToken: "unexpected-refreshed-refresh",
                    idToken: nil
                )
            },
            copyUserCode: { _ in },
            clearModelCatalog: {},
            now: { Date(timeIntervalSince1970: 10_000) }
        )
        let manager = OpenAICodexAuthManager(
            dependencies: dependencies,
            refreshStoredStatusOnInit: false
        )

        manager.startLogin()
        let firstAttemptFailed = await authEventually {
            if case .failed = manager.state { return true }
            return false
        }
        XCTAssertTrue(firstAttemptFailed)
        credentials.values[OpenAICodexAuthManager.accessTokenAccount] =
            expiredJWT(expiration: 1)
        credentials.values[OpenAICodexAuthManager.refreshTokenAccount] =
            "stored-refresh"

        manager.startLogin()
        let retryStarted = await authEventually { deviceCodeCallCount == 2 }
        XCTAssertTrue(retryStarted)
        let retryFailed = await authEventually {
            if case .failed = manager.state { return true }
            return false
        }
        XCTAssertTrue(retryFailed)

        XCTAssertEqual(refreshCallCount, 0)
        XCTAssertEqual(
            credentials.values[OpenAICodexAuthManager.accessTokenAccount],
            expiredJWT(expiration: 1)
        )
        guard case .failed = manager.state else {
            return XCTFail("Explicit retry did not remain the sole operation")
        }
    }

    func testAuthenticationFailureInvalidatesAccessAndFreshLoginRecovers() async {
        let credentials = AuthCredentialMemory(values: [
            OpenAICodexAuthManager.accessTokenAccount: "rejected-access",
            OpenAICodexAuthManager.refreshTokenAccount: "retained-refresh",
        ])
        var refreshCallCount = 0
        let dependencies = OpenAICodexAuthDependencies(
            readCredential: { credentials.read($0) },
            saveCredential: { credentials.save($0, account: $1) },
            deleteCredential: { credentials.delete($0) },
            requestDeviceCode: {
                OpenAICodexDeviceCode(
                    userCode: "RECOVER-1",
                    deviceAuthID: "recover-device",
                    interval: .seconds(3)
                )
            },
            waitForApproval: { _ in
                OpenAICodexApprovalExchange(
                    authorizationCode: "recover-code",
                    codeVerifier: "recover-verifier",
                    codeChallenge: "recover-challenge"
                )
            },
            exchange: { _ in
                .init(
                    accessToken: "recovered-access",
                    refreshToken: "recovered-refresh",
                    idToken: nil
                )
            },
            refresh: { _ in
                refreshCallCount += 1
                throw AuthFixtureError.unexpectedRefresh
            },
            copyUserCode: { _ in },
            clearModelCatalog: {},
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        let manager = OpenAICodexAuthManager(dependencies: dependencies)
        XCTAssertTrue(manager.isSignedIn)

        manager.invalidateAfterAuthenticationFailure(
            rejectedAccessToken: "rejected-access"
        )

        XCTAssertNil(
            credentials.values[OpenAICodexAuthManager.accessTokenAccount]
        )
        XCTAssertEqual(
            credentials.values[OpenAICodexAuthManager.refreshTokenAccount],
            "retained-refresh"
        )
        guard case .failed = manager.state else {
            return XCTFail("A rejected access token still looked signed in")
        }
        let credentialPrepared = await manager.prepareCredentialForRun()
        XCTAssertFalse(credentialPrepared)
        XCTAssertEqual(refreshCallCount, 0)

        manager.startLogin()
        let recovered = await authEventually { manager.isSignedIn }
        XCTAssertTrue(recovered)
        XCTAssertEqual(
            credentials.values[OpenAICodexAuthManager.accessTokenAccount],
            "recovered-access"
        )

        manager.invalidateAfterAuthenticationFailure(
            rejectedAccessToken: "rejected-access"
        )
        XCTAssertTrue(manager.isSignedIn)
        XCTAssertEqual(
            credentials.values[OpenAICodexAuthManager.accessTokenAccount],
            "recovered-access",
            "A late 401 for an old request deleted the new login"
        )
    }
}

@MainActor
private final class AuthCredentialMemory {
    struct SaveEvent {
        let value: String
        let account: String
    }

    var values: [String: String]
    private(set) var saveEvents: [SaveEvent] = []

    init(values: [String: String] = [:]) {
        self.values = values
    }

    func read(_ account: String) -> String? {
        values[account]
    }

    func save(_ value: String, account: String) {
        saveEvents.append(.init(value: value, account: account))
        values[account] = value
    }

    func delete(_ account: String) {
        values[account] = nil
    }
}

private let authTestTimeout: Duration = .seconds(2)
private let authTestPollInterval: Duration = .milliseconds(1)

private actor AuthExchangeGate {
    private var continuations: [
        String: CheckedContinuation<OpenAICodexOAuthTokens, Error>
    ] = [:]
    private var callCount = 0

    func exchange(
        _ exchange: OpenAICodexApprovalExchange
    ) async throws -> OpenAICodexOAuthTokens {
        callCount += 1
        return try await withCheckedThrowingContinuation { continuation in
            continuations[exchange.authorizationCode] = continuation
        }
    }

    func waitForCallCount(_ expectedCount: Int) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: authTestTimeout)
        while clock.now < deadline {
            if callCount >= expectedCount { return true }
            try? await Task.sleep(for: authTestPollInterval)
        }
        return callCount >= expectedCount
    }

    func complete(
        authorizationCode: String,
        tokens: OpenAICodexOAuthTokens
    ) {
        continuations.removeValue(forKey: authorizationCode)?
            .resume(returning: tokens)
    }
}

private actor AuthRefreshGate {
    private var continuation: CheckedContinuation<
        OpenAICodexOAuthTokens,
        Error
    >?
    private var started = false

    func refresh(_ refreshToken: String) async throws
        -> OpenAICodexOAuthTokens
    {
        guard refreshToken == "stored-refresh" else {
            throw AuthFixtureError.unexpectedRefresh
        }
        started = true
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilStarted() async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: authTestTimeout)
        while clock.now < deadline {
            if started { return true }
            try? await Task.sleep(for: authTestPollInterval)
        }
        return started
    }

    func complete(_ tokens: OpenAICodexOAuthTokens) {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: tokens)
    }
}

private enum AuthFixtureError: Error, Sendable {
    case expectedDeviceCodeFailure
    case unexpectedApproval
    case unexpectedExchange
    case unexpectedRefresh
}

@MainActor
private func authEventually(_ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: authTestTimeout)
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: authTestPollInterval)
    }
    return condition()
}

private func expiredJWT(expiration: Int) -> String {
    let payload = Data(#"{"exp":\#(expiration)}"#.utf8)
        .base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "header.\(payload).signature"
}
