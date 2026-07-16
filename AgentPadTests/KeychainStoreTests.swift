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
                String(repeating: "s", count: 4_097),
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
