import Foundation
import Security

enum AgentApprovalSigningKeyStoreError: Error, Equatable, Sendable {
    case missing
    case corrupt
    case undersized
    case oversized
    case unexpectedAccessibility
    case randomGenerationFailed
    case keychainFailure
}

extension AgentApprovalSigningKeyStoreError: CustomStringConvertible {
    var description: String {
        switch self {
        case .missing:
            return "Approval signing key is unavailable."
        case .corrupt:
            return "Approval signing key storage is invalid."
        case .undersized:
            return "Approval signing key does not meet the minimum size."
        case .oversized:
            return "Approval signing key exceeds the supported size."
        case .unexpectedAccessibility:
            return "Approval signing key protection is invalid."
        case .randomGenerationFailed:
            return "Approval signing key generation failed."
        case .keychainFailure:
            return "Approval signing key storage is unavailable."
        }
    }
}

/// Redacts key material from normal and debug interpolation. The bytes are
/// exposed only to a lexical closure so callers can immediately construct the
/// trusted AgentPolicy authority without retaining another named copy.
struct AgentApprovalSigningKey: Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible
{
    private let bytes: Data

    fileprivate init(bytes: Data) {
        self.bytes = bytes
    }

    var byteCount: Int { bytes.count }

    func withKeyData<Result>(
        _ operation: (Data) throws -> Result
    ) rethrows -> Result {
        try operation(bytes)
    }

    var description: String { "<AgentApprovalSigningKey: redacted>" }
    var debugDescription: String { description }
}

enum AgentApprovalSigningKeyAccessibility: Equatable, Sendable {
    case whenUnlockedThisDeviceOnly
    case unexpected
}

enum AgentApprovalSigningKeychainLookup: Equatable, Sendable {
    case notFound
    case item(
        data: Data,
        accessibility: AgentApprovalSigningKeyAccessibility
    )
    case malformed
}

extension AgentApprovalSigningKeychainLookup:
    CustomStringConvertible,
    CustomDebugStringConvertible
{
    var description: String {
        switch self {
        case .notFound:
            return "<AgentApprovalSigningKeychainLookup: not found>"
        case .item:
            return "<AgentApprovalSigningKeychainLookup: redacted item>"
        case .malformed:
            return "<AgentApprovalSigningKeychainLookup: malformed>"
        }
    }

    var debugDescription: String { description }
}

enum AgentApprovalSigningKeychainInsertResult: Equatable, Sendable {
    case inserted
    case duplicate
}

protocol AgentApprovalSigningKeychainClient: Sendable {
    func lookup(service: String, account: String) throws
        -> AgentApprovalSigningKeychainLookup
    func insert(
        _ data: Data,
        service: String,
        account: String,
        accessibility: AgentApprovalSigningKeyAccessibility
    ) throws -> AgentApprovalSigningKeychainInsertResult
}

protocol AgentApprovalSigningKeyRandomGenerating: Sendable {
    func randomBytes(count: Int) throws -> Data
}

struct AgentApprovalSigningKeyStore: Sendable {
    static let service = "com.joey.NovaForge"
    static let account = "agent-policy.approval-ui-hmac.v1"
    static let generatedKeyByteCount = 32
    static let minimumKeyByteCount = 32
    static let maximumKeyByteCount = 64

    private let keychain: any AgentApprovalSigningKeychainClient
    private let randomGenerator: any AgentApprovalSigningKeyRandomGenerating

    init(
        keychain: any AgentApprovalSigningKeychainClient =
            AgentApprovalSigningKeyStore.productionKeyStorageClient(),
        randomGenerator: any AgentApprovalSigningKeyRandomGenerating =
            AgentApprovalSigningSystemRandomGenerator()
    ) {
        self.keychain = keychain
        self.randomGenerator = randomGenerator
    }

    static func productionKeyStorageClient()
        -> any AgentApprovalSigningKeychainClient
    {
        #if targetEnvironment(simulator)
        // CODE_SIGNING_ALLOWED=NO is the supported simulator build lane. Such
        // binaries have no SecTask entitlement record, so Security rejects
        // both Data Protection and legacy Keychain writes. Keep a
        // simulator-only, this-install authority in the already protected
        // AgentPolicy directory; physical devices always take the Keychain
        // branch below.
        return AgentApprovalSigningSimulatorFileClient()
        #else
        return AgentApprovalSigningSystemKeychainClient()
        #endif
    }

    /// Reads a previously provisioned key. Absence and malformed material are
    /// terminal errors; this path never manufactures replacement authority.
    func readExistingKey() throws -> AgentApprovalSigningKey {
        switch try lookup() {
        case .notFound:
            throw AgentApprovalSigningKeyStoreError.missing
        case .malformed:
            throw AgentApprovalSigningKeyStoreError.corrupt
        case let .item(data, accessibility):
            return try validate(data, accessibility: accessibility)
        }
    }

    /// Returns the existing valid key or creates one exactly once when the
    /// Keychain proves the account is absent. Corrupt existing entries are
    /// never overwritten. A duplicate insert race is resolved only by reading
    /// and validating the winning item.
    func readOrCreateKey() throws -> AgentApprovalSigningKey {
        switch try lookup() {
        case let .item(data, accessibility):
            return try validate(data, accessibility: accessibility)
        case .malformed:
            throw AgentApprovalSigningKeyStoreError.corrupt
        case .notFound:
            break
        }

        let candidate: Data
        do {
            candidate = try randomGenerator.randomBytes(
                count: Self.generatedKeyByteCount
            )
        } catch {
            throw AgentApprovalSigningKeyStoreError.randomGenerationFailed
        }
        guard candidate.count == Self.generatedKeyByteCount else {
            throw AgentApprovalSigningKeyStoreError.randomGenerationFailed
        }

        let insertResult: AgentApprovalSigningKeychainInsertResult
        do {
            insertResult = try keychain.insert(
                candidate,
                service: Self.service,
                account: Self.account,
                accessibility: .whenUnlockedThisDeviceOnly
            )
        } catch {
            throw AgentApprovalSigningKeyStoreError.keychainFailure
        }

        switch insertResult {
        case .inserted:
            // Verify what the Keychain persisted instead of trusting an
            // adapter's success result or retaining only the in-memory value.
            return try readExistingKey()
        case .duplicate:
            // Do not return our losing candidate and do not retry insertion.
            // Only the item committed by the concurrent winner has authority.
            return try readExistingKey()
        }
    }

    private func lookup() throws -> AgentApprovalSigningKeychainLookup {
        do {
            return try keychain.lookup(
                service: Self.service,
                account: Self.account
            )
        } catch {
            // Backend errors are deliberately collapsed so an implementation
            // can never smuggle key material through an associated error.
            throw AgentApprovalSigningKeyStoreError.keychainFailure
        }
    }

    private func validate(
        _ data: Data,
        accessibility: AgentApprovalSigningKeyAccessibility
    ) throws -> AgentApprovalSigningKey {
        guard accessibility == .whenUnlockedThisDeviceOnly else {
            throw AgentApprovalSigningKeyStoreError.unexpectedAccessibility
        }
        guard data.count >= Self.minimumKeyByteCount else {
            throw AgentApprovalSigningKeyStoreError.undersized
        }
        guard data.count <= Self.maximumKeyByteCount else {
            throw AgentApprovalSigningKeyStoreError.oversized
        }
        return AgentApprovalSigningKey(bytes: data)
    }
}

#if targetEnvironment(simulator)
struct AgentApprovalSigningSimulatorFileClient:
    AgentApprovalSigningKeychainClient
{
    private let fileURL: URL

    init(
        fileURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        if let fileURL {
            self.fileURL = fileURL.standardizedFileURL
        } else {
            let support = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? fileManager.temporaryDirectory
            self.fileURL = support
                .appendingPathComponent("AgentPolicy", isDirectory: true)
                .appendingPathComponent("v1", isDirectory: true)
                .appendingPathComponent(
                    "simulator-approval-signing-key",
                    isDirectory: false
                )
                .standardizedFileURL
        }
    }

    func lookup(
        service: String,
        account: String
    ) throws -> AgentApprovalSigningKeychainLookup {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return .notFound
        }
        let values = try fileURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true
        else {
            return .malformed
        }
        return .item(
            data: try Data(contentsOf: fileURL, options: [.mappedIfSafe]),
            accessibility: .whenUnlockedThisDeviceOnly
        )
    }

    func insert(
        _ data: Data,
        service: String,
        account: String,
        accessibility: AgentApprovalSigningKeyAccessibility
    ) throws -> AgentApprovalSigningKeychainInsertResult {
        let fileManager = FileManager.default
        guard accessibility == .whenUnlockedThisDeviceOnly else {
            throw AgentApprovalSigningKeyStoreError.keychainFailure
        }
        do {
            try data.write(to: fileURL, options: [.withoutOverwriting])
            try fileManager.setAttributes(
                [
                    .posixPermissions: 0o600,
                    .protectionKey: FileProtectionType.complete,
                ],
                ofItemAtPath: fileURL.path
            )
            return .inserted
        } catch let error as CocoaError
            where error.code == .fileWriteFileExists
        {
            return .duplicate
        } catch {
            throw AgentApprovalSigningKeyStoreError.keychainFailure
        }
    }
}
#endif

struct AgentApprovalSigningSystemRandomGenerator:
    AgentApprovalSigningKeyRandomGenerating
{
    func randomBytes(count: Int) throws -> Data {
        guard count > 0 else {
            throw AgentApprovalSigningKeyStoreError.randomGenerationFailed
        }
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { buffer in
            guard let address = buffer.baseAddress else {
                return errSecParam
            }
            return SecRandomCopyBytes(kSecRandomDefault, count, address)
        }
        guard status == errSecSuccess else {
            throw AgentApprovalSigningKeyStoreError.randomGenerationFailed
        }
        return data
    }
}

struct AgentApprovalSigningSystemKeychainClient:
    AgentApprovalSigningKeychainClient
{
    func lookup(
        service: String,
        account: String
    ) throws -> AgentApprovalSigningKeychainLookup {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        #if !targetEnvironment(simulator)
        // The physical-device authority is pinned to the Data Protection
        // Keychain. Unsigned CoreSimulator test bundles have no SecTask
        // entitlement record, so asking for that backend is rejected before
        // the normal simulator Keychain can enforce this-device-only access.
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .notFound }
        guard status == errSecSuccess else {
            throw AgentApprovalSigningKeyStoreError.keychainFailure
        }
        guard let attributes = result as? [String: Any],
              let data = attributes[kSecValueData as String] as? Data,
              let accessible = attributes[kSecAttrAccessible as String]
                as? String
        else {
            return .malformed
        }
        let protection: AgentApprovalSigningKeyAccessibility =
            accessible == (kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
                ? .whenUnlockedThisDeviceOnly
                : .unexpected
        return .item(data: data, accessibility: protection)
    }

    func insert(
        _ data: Data,
        service: String,
        account: String,
        accessibility: AgentApprovalSigningKeyAccessibility
    ) throws -> AgentApprovalSigningKeychainInsertResult {
        guard accessibility == .whenUnlockedThisDeviceOnly else {
            throw AgentApprovalSigningKeyStoreError.keychainFailure
        }
        var item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecAttrAccessible as String:
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: data,
        ]
        #if !targetEnvironment(simulator)
        item[kSecUseDataProtectionKeychain as String] = true
        #endif
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecSuccess { return .inserted }
        if status == errSecDuplicateItem { return .duplicate }
        throw AgentApprovalSigningKeyStoreError.keychainFailure
    }
}
