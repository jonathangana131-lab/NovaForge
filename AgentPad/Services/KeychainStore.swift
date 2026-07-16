import Foundation
import Security

enum KeychainError: Error {
    case invalidAccount
    case invalidValue
    case unexpectedStatus(OSStatus)
}

struct KeychainStore {
    private let service = "com.joey.NovaForge"
    private let maximumAccountBytes = 256
    private let maximumSecretBytes = 4_096

    func read(_ account: String) throws -> String? {
        try validateAccount(account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let data = item as? Data,
              (1 ... maximumSecretBytes).contains(data.count),
              let value = String(data: data, encoding: .utf8)
        else { throw KeychainError.invalidValue }
        return value
    }

    func save(_ value: String, account: String) throws {
        try validateAccount(account)
        let data = Data(value.utf8)
        guard (1 ... maximumSecretBytes).contains(data.count) else {
            throw KeychainError.invalidValue
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func delete(_ account: String) throws {
        try validateAccount(account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func validateAccount(_ account: String) throws {
        guard !account.isEmpty,
              account.utf8.count <= maximumAccountBytes,
              account == account.trimmingCharacters(in: .whitespacesAndNewlines),
              account.unicodeScalars.allSatisfy({ scalar in
                  !CharacterSet.whitespacesAndNewlines.contains(scalar) &&
                      !CharacterSet.controlCharacters.contains(scalar) &&
                      scalar.properties.generalCategory != .format
              })
        else { throw KeychainError.invalidAccount }
    }
}
