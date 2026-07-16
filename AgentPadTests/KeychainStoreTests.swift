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
            [URLQueryItem(name: "prompt", value: "login")]
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
