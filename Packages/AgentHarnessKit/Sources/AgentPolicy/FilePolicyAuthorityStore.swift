import AgentDomain
import Darwin
import Dispatch
import Foundation

public enum FilePolicyAuthorityStoreError: Error, Equatable, Sendable {
    case unsupportedVersion(UInt16)
    case corruptEnvelope
    case invalidFileURL
    case invalidFileIdentity
    case invalidLockTimeout
    case lockUnavailable
    case persistenceFailed
    case generationRollback
}

enum FilePolicyAuthorityStoreFaultPoint: Sendable {
    case afterFileSyncBeforeRename
    case afterRenameBeforeDirectorySync
}

typealias FilePolicyAuthorityStoreFaultInjector =
    @Sendable (FilePolicyAuthorityStoreFaultPoint) throws -> Void

/// Crash-recoverable policy authority ledger.
///
/// The ledger is accessed through a pinned directory descriptor, a pinned
/// same-user 0600 lock file, and `openat`/`renameat` operations. Its canonical
/// envelope checksum detects field/record deletion and its generation detects
/// rollback observed by a live store instance. The checksum is not a MAC: a
/// same-user attacker can recompute and replay an older snapshot across a fresh
/// process. That stronger boundary requires an external secure monotonic anchor.
public actor FilePolicyAuthorityStore:
    DurablePolicyGrantRedemptionStore,
    DurableApprovalStore,
    DurableToolEffectClaimStore
{
    private static let formatVersion: UInt16 = 3
    private static let maximumLockTimeoutMilliseconds: UInt64 = 60_000

    private let location: PolicyAuthorityFileIO.Location
    private let lockTimeoutMilliseconds: UInt64
    private let faultInjector: FilePolicyAuthorityStoreFaultInjector?
    private var lastObservedGeneration: UInt64
    private var lastObservedEnvelopeSHA256: SHA256Digest

    public init(
        fileURL: URL,
        lockTimeoutMilliseconds: UInt64 = 250
    ) throws {
        guard (1 ... Self.maximumLockTimeoutMilliseconds).contains(
            lockTimeoutMilliseconds
        ) else { throw FilePolicyAuthorityStoreError.invalidLockTimeout }
        let initial = try DiskEnvelope.make(
            formatVersion: Self.formatVersion,
            generation: 0,
            state: .empty
        )
        let prepared = try PolicyAuthorityFileIO.prepare(
            fileURL: fileURL,
            timeoutMilliseconds: lockTimeoutMilliseconds,
            initialEnvelope: initial
        )
        let envelope = try Self.decodeValidated(prepared.data)
        location = prepared.location
        self.lockTimeoutMilliseconds = lockTimeoutMilliseconds
        faultInjector = nil
        lastObservedGeneration = envelope.generation
        lastObservedEnvelopeSHA256 = envelope.envelopeSHA256
    }

    init(
        fileURL: URL,
        lockTimeoutMilliseconds: UInt64 = 250,
        faultInjector: @escaping FilePolicyAuthorityStoreFaultInjector
    ) throws {
        guard (1 ... Self.maximumLockTimeoutMilliseconds).contains(
            lockTimeoutMilliseconds
        ) else { throw FilePolicyAuthorityStoreError.invalidLockTimeout }
        let initial = try DiskEnvelope.make(
            formatVersion: Self.formatVersion,
            generation: 0,
            state: .empty
        )
        let prepared = try PolicyAuthorityFileIO.prepare(
            fileURL: fileURL,
            timeoutMilliseconds: lockTimeoutMilliseconds,
            initialEnvelope: initial
        )
        let envelope = try Self.decodeValidated(prepared.data)
        location = prepared.location
        self.lockTimeoutMilliseconds = lockTimeoutMilliseconds
        self.faultInjector = faultInjector
        lastObservedGeneration = envelope.generation
        lastObservedEnvelopeSHA256 = envelope.envelopeSHA256
    }

    public func commitIfAbsent(
        _ record: PolicyGrantRedemptionRecord
    ) throws -> PolicyGrantCommitDisposition {
        guard record.isCanonical() else {
            throw PolicyGrantStoreError.corruptEvidence
        }
        return try transaction { state in
            var records = try Self.grantMap(state.grants)
            let key = GrantKey(grantID: record.grantID, nonce: record.nonce)
            if let existing = records[key] {
                return .alreadyPresent(existing)
            }
            records[key] = record
            state.grants = Self.grantSnapshot(records)
            return .committed
        }
    }

    public func redemption(
        grantID: String,
        nonce: String
    ) throws -> PolicyGrantRedemptionRecord? {
        try read { state in
            try Self.grantMap(state.grants)[
                GrantKey(grantID: grantID, nonce: nonce)
            ]
        }
    }

    public func registerIfAbsent(
        _ request: DurableApprovalRequest
    ) throws -> ApprovalRegistrationDisposition {
        guard request.registrationIdentity.isCanonical(),
              request.binding.isCanonical(),
              request.registrationIdentity.runID == request.binding.runID,
              request.registrationIdentity.callID == request.binding.callID,
              request.registrationIdentity.idempotencyKey
                == request.binding.idempotencyKey
        else { throw DurableApprovalStoreError.corruptEvidence }
        return try transaction { state in
            var maps = try Self.approvalMaps(state.approvals)
            if let existing = maps.states[request.requestID] {
                guard existing.request == request else {
                    throw DurableApprovalStoreError.requestConflict(
                        request.requestID
                    )
                }
                return .alreadyRegistered(existing.request)
            }
            if let existingID = maps.registrations[
                request.registrationIdentity.keySHA256
            ], let existing = maps.states[existingID] {
                return .alreadyRegistered(existing.request)
            }
            if maps.nonces[request.binding.nonce] != nil {
                throw DurableApprovalStoreError.nonceConflict(
                    request.binding.nonce
                )
            }
            maps.states[request.requestID] = DurableApprovalState(
                request: request,
                resolution: nil,
                consumption: nil
            )
            state.approvals = Self.approvalSnapshot(maps.states)
            return .registered
        }
    }

    public func resolveIfPending(
        _ resolution: DurableApprovalResolution
    ) throws -> ApprovalResolutionDisposition {
        try transaction { state in
            var states = try Self.approvalMaps(state.approvals).states
            guard let existingState = states[resolution.requestID] else {
                throw DurableApprovalStoreError.requestNotFound(
                    resolution.requestID
                )
            }
            guard resolution.isCanonical(),
                  resolution.bindingSHA256
                    == existingState.request.binding.bindingSHA256,
                  resolution.resolvedAt
                    >= existingState.request.binding.issuedAt,
                  resolution.resolvedAt
                    < existingState.request.binding.expiresAt
            else { throw DurableApprovalStoreError.corruptEvidence }
            if let existing = existingState.resolution {
                guard existing == resolution else {
                    throw DurableApprovalStoreError.resolutionConflict(
                        resolution.requestID
                    )
                }
                return .alreadyResolved(existing)
            }
            states[resolution.requestID] = DurableApprovalState(
                request: existingState.request,
                resolution: resolution,
                consumption: nil
            )
            state.approvals = Self.approvalSnapshot(states)
            return .resolved
        }
    }

    public func consumeIfUnconsumed(
        _ consumption: DurableApprovalConsumptionRecord
    ) throws -> ApprovalConsumptionDisposition {
        try transaction { state in
            var states = try Self.approvalMaps(state.approvals).states
            guard let existingState = states[consumption.requestID],
                  let resolution = existingState.resolution
            else {
                throw DurableApprovalStoreError.requestNotFound(
                    consumption.requestID
                )
            }
            guard resolution.decision == .approved,
                  consumption.isCanonical(),
                  consumption.bindingSHA256
                    == existingState.request.binding.bindingSHA256,
                  consumption.resolutionSHA256
                    == resolution.resolutionSHA256,
                  consumption.targetAttestationSHA256
                    == existingState.request.binding.targetAttestationSHA256,
                  consumption.nonce == existingState.request.binding.nonce,
                  consumption.idempotencyKey
                    == existingState.request.binding.idempotencyKey,
                  consumption.authorizedAt >= resolution.resolvedAt,
                  consumption.authorizedAt
                    >= existingState.request.binding.issuedAt,
                  consumption.authorizedAt
                    < existingState.request.binding.expiresAt,
                  consumption.expiresAt
                    == existingState.request.binding.expiresAt
            else { throw DurableApprovalStoreError.corruptEvidence }
            if let existing = existingState.consumption {
                return .alreadyConsumed(existing)
            }
            states[consumption.requestID] = DurableApprovalState(
                request: existingState.request,
                resolution: resolution,
                consumption: consumption
            )
            state.approvals = Self.approvalSnapshot(states)
            return .consumed
        }
    }

    public func state(
        requestID: ApprovalRequestID
    ) throws -> DurableApprovalState? {
        try read { state in
            try Self.approvalMaps(state.approvals).states[requestID]
        }
    }

    public func state(
        registrationKeySHA256: SHA256Digest
    ) throws -> DurableApprovalState? {
        try read { state in
            let maps = try Self.approvalMaps(state.approvals)
            guard let requestID = maps.registrations[
                registrationKeySHA256
            ] else { return nil }
            return maps.states[requestID]
        }
    }

    public func commitIfAbsent(
        _ record: ToolEffectClaimRecord
    ) throws -> ToolEffectClaimDisposition {
        guard record.isCanonical() else {
            throw ToolEffectClaimError.corruptEvidence
        }
        return try transaction { state in
            var records = try Self.effectClaimMap(state.effectClaims)
            if let existing = records[record.effectKeySHA256] {
                return .alreadyPresent(existing)
            }
            records[record.effectKeySHA256] = record
            state.effectClaims = Self.effectClaimSnapshot(records)
            return .committed
        }
    }

    public func claim(
        effectKeySHA256: SHA256Digest
    ) throws -> ToolEffectClaimRecord? {
        try read { state in
            try Self.effectClaimMap(state.effectClaims)[effectKeySHA256]
        }
    }

    public func approvalSnapshot() throws -> DurableApprovalLedgerSnapshot {
        try read(\.approvals)
    }

    public func grantSnapshot() throws -> PolicyGrantLedgerSnapshot {
        try read(\.grants)
    }

    public func effectClaimSnapshot() throws -> ToolEffectClaimSnapshot {
        try read(\.effectClaims)
    }

    private func transaction<Result: Sendable>(
        _ mutation: (inout DiskState) throws -> Result
    ) throws -> Result {
        let location = location
        let minimumGeneration = lastObservedGeneration
        let observedDigest = lastObservedEnvelopeSHA256
        let outcome = try PolicyAuthorityFileIO.withExclusiveLock(
            at: location,
            timeoutMilliseconds: lockTimeoutMilliseconds
        ) { directoryDescriptor in
            let current = try Self.load(
                directoryDescriptor: directoryDescriptor,
                location: location
            )
            try Self.validateObservedRevision(
                current,
                minimumGeneration: minimumGeneration,
                observedDigest: observedDigest
            )
            var nextState = current.state
            let result = try mutation(&nextState)
            nextState = try Self.canonicalState(nextState)
            guard nextState != current.state else {
                return PolicyAuthorityTransactionOutcome(
                    result: result,
                    generation: current.generation,
                    envelopeSHA256: current.envelopeSHA256
                )
            }
            guard current.generation < UInt64.max else {
                throw FilePolicyAuthorityStoreError.corruptEnvelope
            }
            let next = try DiskEnvelope.make(
                formatVersion: Self.formatVersion,
                generation: current.generation + 1,
                state: nextState
            )
            try PolicyAuthorityFileIO.persist(
                next,
                directoryDescriptor: directoryDescriptor,
                location: location,
                faultInjector: faultInjector
            )
            return PolicyAuthorityTransactionOutcome(
                result: result,
                generation: next.generation,
                envelopeSHA256: next.envelopeSHA256
            )
        }
        lastObservedGeneration = max(
            lastObservedGeneration,
            outcome.generation
        )
        lastObservedEnvelopeSHA256 = outcome.envelopeSHA256
        return outcome.result
    }

    private func read<Result: Sendable>(
        _ body: (DiskState) throws -> Result
    ) throws -> Result {
        let location = location
        let minimumGeneration = lastObservedGeneration
        let observedDigest = lastObservedEnvelopeSHA256
        let outcome = try PolicyAuthorityFileIO.withExclusiveLock(
            at: location,
            timeoutMilliseconds: lockTimeoutMilliseconds
        ) { directoryDescriptor in
            let envelope = try Self.load(
                directoryDescriptor: directoryDescriptor,
                location: location
            )
            try Self.validateObservedRevision(
                envelope,
                minimumGeneration: minimumGeneration,
                observedDigest: observedDigest
            )
            return PolicyAuthorityTransactionOutcome(
                result: try body(envelope.state),
                generation: envelope.generation,
                envelopeSHA256: envelope.envelopeSHA256
            )
        }
        lastObservedGeneration = max(
            lastObservedGeneration,
            outcome.generation
        )
        lastObservedEnvelopeSHA256 = outcome.envelopeSHA256
        return outcome.result
    }

    private static func validateObservedRevision(
        _ envelope: DiskEnvelope,
        minimumGeneration: UInt64,
        observedDigest: SHA256Digest
    ) throws {
        guard envelope.generation >= minimumGeneration else {
            throw FilePolicyAuthorityStoreError.generationRollback
        }
        if envelope.generation == minimumGeneration,
           envelope.envelopeSHA256 != observedDigest {
            throw FilePolicyAuthorityStoreError.generationRollback
        }
    }

    private static func load(
        directoryDescriptor: Int32,
        location: PolicyAuthorityFileIO.Location
    ) throws -> DiskEnvelope {
        try decodeValidated(PolicyAuthorityFileIO.readLedger(
            directoryDescriptor: directoryDescriptor,
            location: location
        ))
    }

    private static func decodeValidated(_ data: Data) throws -> DiskEnvelope {
        struct VersionProbe: Decodable { let formatVersion: UInt16 }
        let encodedVersion: UInt16
        do {
            encodedVersion = try JSONDecoder()
                .decode(VersionProbe.self, from: data)
                .formatVersion
        } catch {
            throw FilePolicyAuthorityStoreError.corruptEnvelope
        }
        guard encodedVersion == formatVersion else {
            throw FilePolicyAuthorityStoreError.unsupportedVersion(
                encodedVersion
            )
        }
        let envelope: DiskEnvelope
        do {
            envelope = try JSONDecoder().decode(DiskEnvelope.self, from: data)
        } catch let error as FilePolicyAuthorityStoreError {
            throw error
        } catch {
            throw FilePolicyAuthorityStoreError.corruptEnvelope
        }
        _ = try canonicalState(envelope.state)
        return envelope
    }

    private static func canonicalState(_ state: DiskState) throws -> DiskState {
        let approvals = approvalSnapshot(try approvalMaps(state.approvals).states)
        let grants = grantSnapshot(try grantMap(state.grants))
        let effectClaims = effectClaimSnapshot(
            try effectClaimMap(state.effectClaims)
        )
        let canonical = DiskState(
            approvals: approvals,
            grants: grants,
            effectClaims: effectClaims
        )
        guard canonical == state else {
            throw FilePolicyAuthorityStoreError.corruptEnvelope
        }
        return canonical
    }

    private static func approvalMaps(
        _ snapshot: DurableApprovalLedgerSnapshot
    ) throws -> (
        states: [ApprovalRequestID: DurableApprovalState],
        nonces: [ApprovalNonce: ApprovalRequestID],
        registrations: [SHA256Digest: ApprovalRequestID]
    ) {
        var states: [ApprovalRequestID: DurableApprovalState] = [:]
        var nonces: [ApprovalNonce: ApprovalRequestID] = [:]
        var registrations: [SHA256Digest: ApprovalRequestID] = [:]
        for state in snapshot.states {
            try InMemoryDurableApprovalStore.validate(state)
            guard states[state.request.requestID] == nil,
                  nonces[state.request.binding.nonce] == nil,
                  registrations[
                    state.request.registrationIdentity.keySHA256
                  ] == nil
            else { throw DurableApprovalStoreError.corruptEvidence }
            states[state.request.requestID] = state
            nonces[state.request.binding.nonce] = state.request.requestID
            registrations[state.request.registrationIdentity.keySHA256] =
                state.request.requestID
        }
        return (states, nonces, registrations)
    }

    private static func grantMap(
        _ snapshot: PolicyGrantLedgerSnapshot
    ) throws -> [GrantKey: PolicyGrantRedemptionRecord] {
        var records: [GrantKey: PolicyGrantRedemptionRecord] = [:]
        for record in snapshot.redemptions {
            let key = GrantKey(grantID: record.grantID, nonce: record.nonce)
            guard record.isCanonical(), records[key] == nil else {
                throw PolicyGrantStoreError.duplicateRedemption(
                    grantID: record.grantID,
                    nonce: record.nonce
                )
            }
            records[key] = record
        }
        return records
    }

    private static func effectClaimMap(
        _ snapshot: ToolEffectClaimSnapshot
    ) throws -> [SHA256Digest: ToolEffectClaimRecord] {
        var records: [SHA256Digest: ToolEffectClaimRecord] = [:]
        for record in snapshot.claims {
            guard record.isCanonical(),
                  records[record.effectKeySHA256] == nil
            else { throw ToolEffectClaimError.corruptEvidence }
            records[record.effectKeySHA256] = record
        }
        return records
    }

    private static func approvalSnapshot(
        _ states: [ApprovalRequestID: DurableApprovalState]
    ) -> DurableApprovalLedgerSnapshot {
        DurableApprovalLedgerSnapshot(states: states.values.sorted {
            $0.request.requestID.description
                < $1.request.requestID.description
        })
    }

    private static func grantSnapshot(
        _ records: [GrantKey: PolicyGrantRedemptionRecord]
    ) -> PolicyGrantLedgerSnapshot {
        PolicyGrantLedgerSnapshot(redemptions: records.values.sorted {
            ($0.grantID, $0.nonce) < ($1.grantID, $1.nonce)
        })
    }

    private static func effectClaimSnapshot(
        _ records: [SHA256Digest: ToolEffectClaimRecord]
    ) -> ToolEffectClaimSnapshot {
        ToolEffectClaimSnapshot(claims: records.values.sorted {
            $0.effectKeySHA256.rawValue < $1.effectKeySHA256.rawValue
        })
    }
}

private struct DiskState: Codable, Equatable, Sendable {
    var approvals: DurableApprovalLedgerSnapshot
    var grants: PolicyGrantLedgerSnapshot
    var effectClaims: ToolEffectClaimSnapshot

    static let empty = Self(
        approvals: .init(states: []),
        grants: .init(redemptions: []),
        effectClaims: .init(claims: [])
    )
}

private struct DiskEnvelope: Codable, Sendable {
    let formatVersion: UInt16
    let generation: UInt64
    let state: DiskState
    let envelopeSHA256: SHA256Digest

    private struct DigestMaterial: Codable {
        let formatVersion: UInt16
        let generation: UInt64
        let state: DiskState
    }

    static func make(
        formatVersion: UInt16,
        generation: UInt64,
        state: DiskState
    ) throws -> Self {
        let material = DigestMaterial(
            formatVersion: formatVersion,
            generation: generation,
            state: state
        )
        return Self(
            formatVersion: formatVersion,
            generation: generation,
            state: state,
            envelopeSHA256: try PolicyCanonicalDigest.sha256(
                domain: .policyAuthorityLedgerEnvelope,
                material
            )
        )
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rebuilt = try Self.make(
            formatVersion: container.decode(
                UInt16.self,
                forKey: .formatVersion
            ),
            generation: container.decode(UInt64.self, forKey: .generation),
            state: container.decode(DiskState.self, forKey: .state)
        )
        guard rebuilt.envelopeSHA256 == (try container.decode(
            SHA256Digest.self,
            forKey: .envelopeSHA256
        )) else { throw FilePolicyAuthorityStoreError.corruptEnvelope }
        self = rebuilt
    }

    private init(
        formatVersion: UInt16,
        generation: UInt64,
        state: DiskState,
        envelopeSHA256: SHA256Digest
    ) {
        self.formatVersion = formatVersion
        self.generation = generation
        self.state = state
        self.envelopeSHA256 = envelopeSHA256
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case generation
        case state
        case envelopeSHA256
    }
}

private struct PolicyAuthorityTransactionOutcome<Result: Sendable>: Sendable {
    let result: Result
    let generation: UInt64
    let envelopeSHA256: SHA256Digest
}

private struct GrantKey: Hashable {
    let grantID: String
    let nonce: String
}

private enum PolicyAuthorityFileIO {
    private static let maximumFileBytes = 32 * 1_024 * 1_024
    private static let processSemaphore = DispatchSemaphore(value: 1)
    private static let lockMarker = Data(
        "NovaForgePolicyAuthorityLock-v3\n".utf8
    )

    struct FileIdentity: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64

        init(_ status: stat) {
            device = UInt64(bitPattern: Int64(status.st_dev))
            inode = UInt64(status.st_ino)
        }
    }

    struct Location: Sendable {
        let directoryURL: URL
        let fileName: String
        let lockName: String
        let directoryIdentity: FileIdentity
        let lockIdentity: FileIdentity
    }

    struct Preparation: Sendable {
        let location: Location
        let data: Data
    }

    static func prepare(
        fileURL: URL,
        timeoutMilliseconds: UInt64,
        initialEnvelope: DiskEnvelope
    ) throws -> Preparation {
        guard fileURL.isFileURL,
              !fileURL.lastPathComponent.isEmpty,
              fileURL.lastPathComponent != ".",
              fileURL.lastPathComponent != ".."
        else { throw FilePolicyAuthorityStoreError.invalidFileURL }
        let requestedDirectory = fileURL.standardizedFileURL
            .deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: requestedDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw FilePolicyAuthorityStoreError.persistenceFailed
        }
        let directoryURL = requestedDirectory
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let fileName = fileURL.lastPathComponent
        let lockName = fileName + ".lock"
        let deadline = deadline(after: timeoutMilliseconds)
        try acquireProcessLock(until: deadline)
        defer { processSemaphore.signal() }

        let directoryDescriptor = try openDirectory(at: directoryURL)
        defer { Darwin.close(directoryDescriptor) }
        let directoryStatus = try validatedDirectory(
            descriptor: directoryDescriptor
        )
        let lockDescriptor = try openLock(
            directoryDescriptor: directoryDescriptor,
            name: lockName
        )
        defer { Darwin.close(lockDescriptor) }
        try acquireFileLock(descriptor: lockDescriptor, until: deadline)
        defer { releaseFileLock(descriptor: lockDescriptor) }
        let lockStatus = try validatedRegularFile(
            descriptor: lockDescriptor,
            directoryDescriptor: directoryDescriptor,
            name: lockName
        )
        let marker = try readAll(
            descriptor: lockDescriptor,
            expectedSize: Int(lockStatus.st_size),
            maximumBytes: lockMarker.count
        )
        let location = Location(
            directoryURL: directoryURL,
            fileName: fileName,
            lockName: lockName,
            directoryIdentity: FileIdentity(directoryStatus),
            lockIdentity: FileIdentity(lockStatus)
        )
        let ledgerExists = entryExists(
            directoryDescriptor: directoryDescriptor,
            name: fileName
        )
        if marker.isEmpty {
            if ledgerExists {
                _ = try readLedger(
                    directoryDescriptor: directoryDescriptor,
                    location: location
                )
            } else {
                try persist(
                    initialEnvelope,
                    directoryDescriptor: directoryDescriptor,
                    location: location,
                    faultInjector: nil
                )
            }
            try replaceContents(descriptor: lockDescriptor, data: lockMarker)
            try synchronize(descriptor: directoryDescriptor)
        } else {
            guard marker == lockMarker, ledgerExists else {
                throw FilePolicyAuthorityStoreError.corruptEnvelope
            }
        }
        return Preparation(
            location: location,
            data: try readLedger(
                directoryDescriptor: directoryDescriptor,
                location: location
            )
        )
    }

    static func withExclusiveLock<Result: Sendable>(
        at location: Location,
        timeoutMilliseconds: UInt64,
        _ body: (Int32) throws -> Result
    ) throws -> Result {
        let deadline = deadline(after: timeoutMilliseconds)
        try acquireProcessLock(until: deadline)
        defer { processSemaphore.signal() }
        let directoryDescriptor = try openDirectory(at: location.directoryURL)
        defer { Darwin.close(directoryDescriptor) }
        let directoryStatus = try validatedDirectory(
            descriptor: directoryDescriptor
        )
        guard FileIdentity(directoryStatus) == location.directoryIdentity else {
            throw FilePolicyAuthorityStoreError.invalidFileIdentity
        }
        let lockDescriptor = try openLock(
            directoryDescriptor: directoryDescriptor,
            name: location.lockName
        )
        defer { Darwin.close(lockDescriptor) }
        let openedLockStatus = try validatedRegularFile(
            descriptor: lockDescriptor,
            directoryDescriptor: directoryDescriptor,
            name: location.lockName
        )
        guard FileIdentity(openedLockStatus) == location.lockIdentity else {
            throw FilePolicyAuthorityStoreError.invalidFileIdentity
        }
        try acquireFileLock(descriptor: lockDescriptor, until: deadline)
        defer { releaseFileLock(descriptor: lockDescriptor) }
        let lockedStatus = try validatedRegularFile(
            descriptor: lockDescriptor,
            directoryDescriptor: directoryDescriptor,
            name: location.lockName
        )
        guard FileIdentity(lockedStatus) == location.lockIdentity else {
            throw FilePolicyAuthorityStoreError.invalidFileIdentity
        }
        let marker = try readAll(
            descriptor: lockDescriptor,
            expectedSize: Int(lockedStatus.st_size),
            maximumBytes: lockMarker.count
        )
        guard marker == lockMarker else {
            throw FilePolicyAuthorityStoreError.corruptEnvelope
        }
        return try body(directoryDescriptor)
    }

    static func readLedger(
        directoryDescriptor: Int32,
        location: Location
    ) throws -> Data {
        let descriptor = openAt(
            directoryDescriptor: directoryDescriptor,
            name: location.fileName,
            flags: O_RDONLY | O_CLOEXEC | O_NOFOLLOW,
            mode: 0
        )
        guard descriptor >= 0 else {
            if errno == ELOOP {
                throw FilePolicyAuthorityStoreError.invalidFileIdentity
            }
            throw FilePolicyAuthorityStoreError.persistenceFailed
        }
        defer { Darwin.close(descriptor) }
        let status = try validatedRegularFile(
            descriptor: descriptor,
            directoryDescriptor: directoryDescriptor,
            name: location.fileName
        )
        guard status.st_size >= 0,
              status.st_size <= maximumFileBytes
        else { throw FilePolicyAuthorityStoreError.corruptEnvelope }
        return try readAll(
            descriptor: descriptor,
            expectedSize: Int(status.st_size),
            maximumBytes: maximumFileBytes
        )
    }

    static func persist(
        _ envelope: DiskEnvelope,
        directoryDescriptor: Int32,
        location: Location,
        faultInjector: FilePolicyAuthorityStoreFaultInjector?
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do {
            data = try encoder.encode(envelope)
        } catch {
            throw FilePolicyAuthorityStoreError.corruptEnvelope
        }
        guard data.count <= maximumFileBytes else {
            throw FilePolicyAuthorityStoreError.persistenceFailed
        }
        let temporaryName =
            ".\(location.fileName).\(UUID().uuidString).tmp"
        let descriptor = openAt(
            directoryDescriptor: directoryDescriptor,
            name: temporaryName,
            flags: O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW,
            mode: S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw FilePolicyAuthorityStoreError.persistenceFailed
        }
        var shouldUnlink = true
        defer {
            Darwin.close(descriptor)
            if shouldUnlink {
                _ = temporaryName.withCString {
                    Darwin.unlinkat(directoryDescriptor, $0, 0)
                }
            }
        }
        _ = try validatedRegularFile(
            descriptor: descriptor,
            directoryDescriptor: directoryDescriptor,
            name: temporaryName
        )
        try writeAll(descriptor: descriptor, data: data)
        try synchronize(descriptor: descriptor)
        try faultInjector?(.afterFileSyncBeforeRename)
        let renamed = temporaryName.withCString { temporary in
            location.fileName.withCString { destination in
                Darwin.renameat(
                    directoryDescriptor,
                    temporary,
                    directoryDescriptor,
                    destination
                )
            }
        }
        guard renamed == 0 else {
            throw FilePolicyAuthorityStoreError.persistenceFailed
        }
        shouldUnlink = false
        try faultInjector?(.afterRenameBeforeDirectorySync)
        try synchronize(descriptor: directoryDescriptor)
    }

    private static func deadline(after milliseconds: UInt64) -> DispatchTime {
        .now() + .milliseconds(Int(milliseconds))
    }

    private static func acquireProcessLock(until deadline: DispatchTime) throws {
        guard processSemaphore.wait(timeout: deadline) == .success else {
            throw FilePolicyAuthorityStoreError.lockUnavailable
        }
    }

    private static func acquireFileLock(
        descriptor: Int32,
        until deadline: DispatchTime
    ) throws {
        while true {
            var lock = Darwin.flock()
            lock.l_type = Int16(F_WRLCK)
            lock.l_whence = Int16(SEEK_SET)
            lock.l_start = 0
            lock.l_len = 0
            if Darwin.fcntl(descriptor, F_SETLK, &lock) == 0 { return }
            let code = errno
            guard code == EACCES || code == EAGAIN else {
                throw FilePolicyAuthorityStoreError.lockUnavailable
            }
            guard DispatchTime.now() < deadline else {
                throw FilePolicyAuthorityStoreError.lockUnavailable
            }
            Darwin.usleep(2_000)
        }
    }

    private static func releaseFileLock(descriptor: Int32) {
        var lock = Darwin.flock()
        lock.l_type = Int16(F_UNLCK)
        lock.l_whence = Int16(SEEK_SET)
        lock.l_start = 0
        lock.l_len = 0
        _ = Darwin.fcntl(descriptor, F_SETLK, &lock)
    }

    private static func openDirectory(at url: URL) throws -> Int32 {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw FilePolicyAuthorityStoreError.invalidFileIdentity
        }
        return descriptor
    }

    private static func openLock(
        directoryDescriptor: Int32,
        name: String
    ) throws -> Int32 {
        let descriptor = openAt(
            directoryDescriptor: directoryDescriptor,
            name: name,
            flags: O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            mode: S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw FilePolicyAuthorityStoreError.lockUnavailable
        }
        return descriptor
    }

    private static func openAt(
        directoryDescriptor: Int32,
        name: String,
        flags: Int32,
        mode: mode_t
    ) -> Int32 {
        name.withCString {
            Darwin.openat(directoryDescriptor, $0, flags, mode)
        }
    }

    private static func validatedDirectory(
        descriptor: Int32
    ) throws -> stat {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == Darwin.geteuid(),
              status.st_mode & 0o022 == 0
        else { throw FilePolicyAuthorityStoreError.invalidFileIdentity }
        return status
    }

    private static func validatedRegularFile(
        descriptor: Int32,
        directoryDescriptor: Int32,
        name: String
    ) throws -> stat {
        var descriptorStatus = stat()
        var pathStatus = stat()
        let pathResult = name.withCString {
            Darwin.fstatat(
                directoryDescriptor,
                $0,
                &pathStatus,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard Darwin.fstat(descriptor, &descriptorStatus) == 0,
              pathResult == 0,
              descriptorStatus.st_mode & S_IFMT == S_IFREG,
              pathStatus.st_mode & S_IFMT == S_IFREG,
              descriptorStatus.st_nlink == 1,
              pathStatus.st_nlink == 1,
              descriptorStatus.st_uid == Darwin.geteuid(),
              pathStatus.st_uid == Darwin.geteuid(),
              descriptorStatus.st_mode & 0o077 == 0,
              pathStatus.st_mode & 0o077 == 0,
              descriptorStatus.st_dev == pathStatus.st_dev,
              descriptorStatus.st_ino == pathStatus.st_ino
        else { throw FilePolicyAuthorityStoreError.invalidFileIdentity }
        return descriptorStatus
    }

    private static func entryExists(
        directoryDescriptor: Int32,
        name: String
    ) -> Bool {
        var status = stat()
        return name.withCString {
            Darwin.fstatat(
                directoryDescriptor,
                $0,
                &status,
                AT_SYMLINK_NOFOLLOW
            )
        } == 0
    }

    private static func readAll(
        descriptor: Int32,
        expectedSize: Int,
        maximumBytes: Int
    ) throws -> Data {
        guard expectedSize >= 0, expectedSize <= maximumBytes else {
            throw FilePolicyAuthorityStoreError.corruptEnvelope
        }
        guard Darwin.lseek(descriptor, 0, SEEK_SET) >= 0 else {
            throw FilePolicyAuthorityStoreError.persistenceFailed
        }
        var result = Data()
        result.reserveCapacity(expectedSize)
        var buffer = [UInt8](
            repeating: 0,
            count: min(64 * 1_024, max(1, maximumBytes))
        )
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw FilePolicyAuthorityStoreError.persistenceFailed
            }
            guard result.count + count <= maximumBytes else {
                throw FilePolicyAuthorityStoreError.corruptEnvelope
            }
            result.append(buffer, count: count)
        }
        guard result.count == expectedSize else {
            throw FilePolicyAuthorityStoreError.corruptEnvelope
        }
        return result
    }

    private static func writeAll(descriptor: Int32, data: Data) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
                if written < 0 {
                    if errno == EINTR { continue }
                    throw FilePolicyAuthorityStoreError.persistenceFailed
                }
                guard written > 0 else {
                    throw FilePolicyAuthorityStoreError.persistenceFailed
                }
                offset += written
            }
        }
    }

    private static func replaceContents(
        descriptor: Int32,
        data: Data
    ) throws {
        guard Darwin.ftruncate(descriptor, 0) == 0,
              Darwin.lseek(descriptor, 0, SEEK_SET) >= 0
        else { throw FilePolicyAuthorityStoreError.persistenceFailed }
        try writeAll(descriptor: descriptor, data: data)
        try synchronize(descriptor: descriptor)
    }

    private static func synchronize(descriptor: Int32) throws {
        while Darwin.fsync(descriptor) != 0 {
            if errno == EINTR { continue }
            throw FilePolicyAuthorityStoreError.persistenceFailed
        }
    }
}
