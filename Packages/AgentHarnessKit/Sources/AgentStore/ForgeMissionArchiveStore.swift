import AgentDomain
import ForgeMission
import Foundation

/// Result of an atomic mission snapshot compare-and-set operation.
public enum ForgeMissionArchiveCommitDisposition: String, Codable, Equatable, Sendable {
    case committed
    case idempotentReplay
}

/// Durable receipt returned only after the snapshot store accepts the exact archive bytes.
public struct ForgeMissionArchiveCommit: Codable, Equatable, Sendable {
    public let missionID: MissionID
    public let projectID: ProjectID
    public let revision: UInt64
    public let authorityEpoch: UInt64
    public let disposition: ForgeMissionArchiveCommitDisposition

    public init(
        missionID: MissionID,
        projectID: ProjectID,
        revision: UInt64,
        authorityEpoch: UInt64,
        disposition: ForgeMissionArchiveCommitDisposition
    ) {
        self.missionID = missionID
        self.projectID = projectID
        self.revision = revision
        self.authorityEpoch = authorityEpoch
        self.disposition = disposition
    }
}

public enum ForgeMissionArchiveStoreError: Error, Equatable, Sendable {
    case invalidArchive
    case identityMismatch(
        missionID: MissionID,
        expectedProjectID: ProjectID,
        actualProjectID: ProjectID
    )
    case staleWrite(expectedPreviousRevision: UInt64?, actualRevision: UInt64?)
    case revisionRegression(current: UInt64, proposed: UInt64)
    case authorityEpochRegression(current: UInt64, proposed: UInt64)
    case conflictingRevision(UInt64)
}

/// Canonical archive encoding boundary. Decode always re-enters ForgeMissionArchive's
/// fail-closed schema/invariant validation instead of trusting persisted bytes.
public struct ForgeMissionArchiveCodec: Sendable {
    public init() {}

    public func encode(_ archive: ForgeMissionArchive) throws -> Data {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(archive)
        } catch {
            throw ForgeMissionArchiveStoreError.invalidArchive
        }
    }

    public func decode(_ data: Data) throws -> ForgeMissionArchive {
        do {
            return try JSONDecoder().decode(ForgeMissionArchive.self, from: data)
        } catch {
            throw ForgeMissionArchiveStoreError.invalidArchive
        }
    }
}

/// Mission persistence authority is deliberately separate from AgentEventJournal.
/// Implementations must atomically compare the previously accepted mission revision
/// and persist the complete validated archive before returning `.committed`.
public protocol ForgeMissionArchivePersisting: Sendable {
    func load(
        missionID: MissionID,
        projectID: ProjectID
    ) async throws -> ForgeMissionArchive?

    func save(
        _ archive: ForgeMissionArchive,
        expectedPreviousRevision: UInt64?
    ) async throws -> ForgeMissionArchiveCommit
}

/// Deterministic reference adapter used to prove compare-and-set and retry semantics.
/// Production adapters can map the same contract to SwiftData/files/database storage.
public actor InMemoryForgeMissionArchiveStore: ForgeMissionArchivePersisting {
    private struct StoredRecord: Sendable {
        let projectID: ProjectID
        let revision: UInt64
        let authorityEpoch: UInt64
        let canonicalData: Data
    }

    private var records: [MissionID: StoredRecord] = [:]
    private let codec: ForgeMissionArchiveCodec

    public init(codec: ForgeMissionArchiveCodec = ForgeMissionArchiveCodec()) {
        self.codec = codec
    }

    public func load(
        missionID: MissionID,
        projectID: ProjectID
    ) async throws -> ForgeMissionArchive? {
        guard let record = records[missionID] else { return nil }
        guard record.projectID == projectID else {
            throw ForgeMissionArchiveStoreError.identityMismatch(
                missionID: missionID,
                expectedProjectID: record.projectID,
                actualProjectID: projectID
            )
        }

        let archive = try codec.decode(record.canonicalData)
        guard archive.state.missionID == missionID,
              archive.state.projectID == projectID,
              archive.state.revision == record.revision,
              archive.state.authorityEpoch == record.authorityEpoch else {
            throw ForgeMissionArchiveStoreError.invalidArchive
        }
        return archive
    }

    public func save(
        _ archive: ForgeMissionArchive,
        expectedPreviousRevision: UInt64?
    ) async throws -> ForgeMissionArchiveCommit {
        // Canonical encode + validated decode means every accepted snapshot crosses
        // the same schema/invariant boundary that a relaunch will use.
        let canonicalData = try codec.encode(archive)
        let validated = try codec.decode(canonicalData)
        let state = validated.state
        let missionID = state.missionID
        let projectID = state.projectID

        if let current = records[missionID] {
            guard current.projectID == projectID else {
                throw ForgeMissionArchiveStoreError.identityMismatch(
                    missionID: missionID,
                    expectedProjectID: current.projectID,
                    actualProjectID: projectID
                )
            }

            // Check exact bytes before CAS so a response-loss retry of a successful
            // commit is idempotent even when it repeats the old expected revision.
            if current.canonicalData == canonicalData {
                return commit(for: state, disposition: .idempotentReplay)
            }

            if state.revision == current.revision {
                throw ForgeMissionArchiveStoreError.conflictingRevision(state.revision)
            }
            guard state.revision > current.revision else {
                throw ForgeMissionArchiveStoreError.revisionRegression(
                    current: current.revision,
                    proposed: state.revision
                )
            }
            guard state.authorityEpoch >= current.authorityEpoch else {
                throw ForgeMissionArchiveStoreError.authorityEpochRegression(
                    current: current.authorityEpoch,
                    proposed: state.authorityEpoch
                )
            }
            guard expectedPreviousRevision == current.revision else {
                throw ForgeMissionArchiveStoreError.staleWrite(
                    expectedPreviousRevision: expectedPreviousRevision,
                    actualRevision: current.revision
                )
            }
        } else {
            guard expectedPreviousRevision == nil else {
                throw ForgeMissionArchiveStoreError.staleWrite(
                    expectedPreviousRevision: expectedPreviousRevision,
                    actualRevision: nil
                )
            }
        }

        records[missionID] = StoredRecord(
            projectID: projectID,
            revision: state.revision,
            authorityEpoch: state.authorityEpoch,
            canonicalData: canonicalData
        )
        return commit(for: state, disposition: .committed)
    }

    private func commit(
        for state: ForgeMissionState,
        disposition: ForgeMissionArchiveCommitDisposition
    ) -> ForgeMissionArchiveCommit {
        ForgeMissionArchiveCommit(
            missionID: state.missionID,
            projectID: state.projectID,
            revision: state.revision,
            authorityEpoch: state.authorityEpoch,
            disposition: disposition
        )
    }
}
