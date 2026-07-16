import Darwin
import Foundation
import XCTest
@testable import NovaForge

final class AgentRecoveryLeadershipLeaseTests: XCTestCase {
    func testSameProcessDuplicateIsRejectedAndLifetimeReleaseAllowsReacquire() async throws {
        let fixture = try RecoveryLeadershipFixture()
        defer { fixture.remove() }
        let acquirer = try AgentRecoveryLeadershipFileLeaseAcquirer(
            fileURL: fixture.lockURL,
            lockTimeoutMilliseconds: 100
        )
        var first: (any AgentRecoveryLeadershipLease)? = try await acquirer
            .acquireProcessLifetimeLease()
        XCTAssertNotNil(first)

        await assertRecoveryLeadershipError(.duplicateAcquisition) {
            try await acquirer.acquireProcessLifetimeLease()
        }

        first = nil
        let second = try await acquirer.acquireProcessLifetimeLease()
        withExtendedLifetime(second) {}
    }

    func testSymlinkHardlinkAndWorldReadableFilesAreRejected() async throws {
        let symlinkFixture = try RecoveryLeadershipFixture()
        defer { symlinkFixture.remove() }
        let symlinkTarget = symlinkFixture.directory.appendingPathComponent(
            "symlink-target.lock"
        )
        try makeRecoveryLeadershipFile(at: symlinkTarget, mode: 0o600)
        try FileManager.default.createSymbolicLink(
            at: symlinkFixture.lockURL,
            withDestinationURL: symlinkTarget
        )
        let symlinkAcquirer = try AgentRecoveryLeadershipFileLeaseAcquirer(
            fileURL: symlinkFixture.lockURL
        )
        await assertRecoveryLeadershipError(.symbolicLinkRejected) {
            try await symlinkAcquirer.acquireProcessLifetimeLease()
        }

        let hardlinkFixture = try RecoveryLeadershipFixture()
        defer { hardlinkFixture.remove() }
        let hardlinkTarget = hardlinkFixture.directory.appendingPathComponent(
            "hardlink-target.lock"
        )
        try makeRecoveryLeadershipFile(at: hardlinkTarget, mode: 0o600)
        try FileManager.default.linkItem(
            at: hardlinkTarget,
            to: hardlinkFixture.lockURL
        )
        let hardlinkAcquirer = try AgentRecoveryLeadershipFileLeaseAcquirer(
            fileURL: hardlinkFixture.lockURL
        )
        await assertRecoveryLeadershipError(.hardLinkRejected) {
            try await hardlinkAcquirer.acquireProcessLifetimeLease()
        }

        let modeFixture = try RecoveryLeadershipFixture()
        defer { modeFixture.remove() }
        try makeRecoveryLeadershipFile(at: modeFixture.lockURL, mode: 0o644)
        let modeAcquirer = try AgentRecoveryLeadershipFileLeaseAcquirer(
            fileURL: modeFixture.lockURL
        )
        await assertRecoveryLeadershipError(.insecurePermissions) {
            try await modeAcquirer.acquireProcessLifetimeLease()
        }
    }

    func testSymlinkDirectoryIsRejected() async throws {
        let root = try RecoveryLeadershipFixture.makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(
            at: real,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let alias = root.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: alias,
            withDestinationURL: real
        )
        let acquirer = try AgentRecoveryLeadershipFileLeaseAcquirer(
            fileURL: alias.appendingPathComponent("leadership.lock")
        )

        await assertRecoveryLeadershipError(.symbolicLinkRejected) {
            try await acquirer.acquireProcessLifetimeLease()
        }
    }

    func testGroupOrOtherAccessibleDirectoryIsRejected() async throws {
        let fixture = try RecoveryLeadershipFixture()
        defer { fixture.remove() }
        guard Darwin.chmod(fixture.directory.path, 0o755) == 0 else {
            throw RecoveryLeadershipTestError.fileCreationFailed
        }
        let acquirer = try AgentRecoveryLeadershipFileLeaseAcquirer(
            fileURL: fixture.lockURL
        )

        await assertRecoveryLeadershipError(.invalidDirectory) {
            try await acquirer.acquireProcessLifetimeLease()
        }
    }

    func testPathReplacementAfterLockIsRejectedAndDoesNotRetainRegistrySlot() async throws {
        let fixture = try RecoveryLeadershipFixture()
        defer { fixture.remove() }
        let moved = fixture.directory.appendingPathComponent("moved.lock")
        let replacing = try AgentRecoveryLeadershipFileLeaseAcquirer(
            fileURL: fixture.lockURL,
            faultInjector: { point, fileURL in
                guard case .afterLockBeforeRevalidation = point else { return }
                try FileManager.default.moveItem(at: fileURL, to: moved)
                try makeRecoveryLeadershipFile(at: fileURL, mode: 0o600)
            }
        )

        await assertRecoveryLeadershipError(.pathIdentityMismatch) {
            try await replacing.acquireProcessLifetimeLease()
        }

        let clean = try AgentRecoveryLeadershipFileLeaseAcquirer(
            fileURL: fixture.lockURL
        )
        let lease = try await clean.acquireProcessLifetimeLease()
        withExtendedLifetime(lease) {}
    }

    func testIdentityGuardQuarantinesAliasDescriptorUntilOriginalRelease() async throws {
        let fixture = try RecoveryLeadershipFixture()
        defer { fixture.remove() }
        let primary = try AgentRecoveryLeadershipFileLeaseAcquirer(
            fileURL: fixture.lockURL
        )
        var lease: (any AgentRecoveryLeadershipLease)? = try await primary
            .acquireProcessLifetimeLease()
        XCTAssertNotNil(lease)
        let aliasURL = fixture.directory.appendingPathComponent("renamed.lock")
        try FileManager.default.moveItem(at: fixture.lockURL, to: aliasURL)
        let alias = try AgentRecoveryLeadershipFileLeaseAcquirer(fileURL: aliasURL)

        await assertRecoveryLeadershipError(.duplicateAcquisition) {
            try await alias.acquireProcessLifetimeLease()
        }
        await assertRecoveryLeadershipError(.duplicateAcquisition) {
            try await alias.acquireProcessLifetimeLease()
        }

        lease = nil
        let reacquired = try await alias.acquireProcessLifetimeLease()
        withExtendedLifetime(reacquired) {}
    }

    func testAlreadyCancelledTaskFailsWithoutCreatingLockFile() async throws {
        let fixture = try RecoveryLeadershipFixture()
        defer { fixture.remove() }
        let acquirer = try AgentRecoveryLeadershipFileLeaseAcquirer(
            fileURL: fixture.lockURL,
            lockTimeoutMilliseconds: 1_000
        )
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await acquirer.acquireProcessLifetimeLease()
        }

        do {
            _ = try await task.value
            XCTFail("Cancelled acquisition unexpectedly returned a lease")
        } catch let error as AgentRecoveryLeadershipLeaseError {
            XCTAssertEqual(error, .cancelled)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.lockURL.path)
        )
    }

    func testRepeatedAcquireReleaseDoesNotLeakFileDescriptors() async throws {
        let fixture = try RecoveryLeadershipFixture()
        defer { fixture.remove() }
        let acquirer = try AgentRecoveryLeadershipFileLeaseAcquirer(
            fileURL: fixture.lockURL
        )
        let baseline = try recoveryLeadershipOpenFileDescriptorCount()

        for _ in 0 ..< 64 {
            var lease: (any AgentRecoveryLeadershipLease)? = try await acquirer
                .acquireProcessLifetimeLease()
            XCTAssertNotNil(lease)
            lease = nil
        }

        let final = try recoveryLeadershipOpenFileDescriptorCount()
        XCTAssertLessThanOrEqual(final, baseline + 2)
    }

    #if os(macOS)
    func testCrossProcessContentionTimesOutBoundedlyThenReleaseAllowsAcquire() async throws {
        let fixture = try RecoveryLeadershipFixture()
        defer { fixture.remove() }
        let holder = try RecoveryLeadershipSubprocessLock(fileURL: fixture.lockURL)
        defer { holder.release() }
        let acquirer = try AgentRecoveryLeadershipFileLeaseAcquirer(
            fileURL: fixture.lockURL,
            lockTimeoutMilliseconds: 30
        )
        let clock = ContinuousClock()
        let start = clock.now

        await assertRecoveryLeadershipError(.lockTimedOut) {
            try await acquirer.acquireProcessLifetimeLease()
        }

        let elapsed = start.duration(to: clock.now)
        XCTAssertLessThan(elapsed, .seconds(1))
        holder.release()
        let lease = try await acquirer.acquireProcessLifetimeLease()
        withExtendedLifetime(lease) {}
    }

    func testCancellationInterruptsCrossProcessContention() async throws {
        let fixture = try RecoveryLeadershipFixture()
        defer { fixture.remove() }
        let holder = try RecoveryLeadershipSubprocessLock(fileURL: fixture.lockURL)
        defer { holder.release() }
        let acquirer = try AgentRecoveryLeadershipFileLeaseAcquirer(
            fileURL: fixture.lockURL,
            lockTimeoutMilliseconds: 5_000
        )
        let task = Task {
            try await acquirer.acquireProcessLifetimeLease()
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Cancelled contended acquisition returned a lease")
        } catch let error as AgentRecoveryLeadershipLeaseError {
            XCTAssertEqual(error, .cancelled)
        }
        holder.release()
        let lease = try await acquirer.acquireProcessLifetimeLease()
        withExtendedLifetime(lease) {}
    }
    #endif
}

private struct RecoveryLeadershipFixture {
    let directory: URL
    let lockURL: URL

    init() throws {
        directory = try Self.makeDirectory()
        lockURL = directory.appendingPathComponent("leadership.lock")
    }

    static func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "NovaForgeRecoveryLeadershipTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return url
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private enum RecoveryLeadershipTestError: Error {
    case fileCreationFailed
    case subprocessDidNotBecomeReady(String)
}

private func makeRecoveryLeadershipFile(
    at url: URL,
    mode: Int
) throws {
    guard FileManager.default.createFile(
        atPath: url.path,
        contents: Data(),
        attributes: [.posixPermissions: mode]
    ) else {
        throw RecoveryLeadershipTestError.fileCreationFailed
    }
    guard Darwin.chmod(url.path, mode_t(mode)) == 0 else {
        throw RecoveryLeadershipTestError.fileCreationFailed
    }
}

private func recoveryLeadershipOpenFileDescriptorCount() throws -> Int {
    try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
}

private func assertRecoveryLeadershipError<T: Sendable>(
    _ expected: AgentRecoveryLeadershipLeaseError,
    operation: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await operation()
        XCTFail("Expected leadership lease error", file: file, line: line)
    } catch let error as AgentRecoveryLeadershipLeaseError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("Unexpected error: \(error)", file: file, line: line)
    }
}

#if os(macOS)
private final class RecoveryLeadershipSubprocessLock {
    private let process: Process
    private let input: Pipe
    private var didRelease = false

    init(fileURL: URL) throws {
        process = Process()
        input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            "-c",
            """
            import fcntl, os, sys
            fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR | os.O_CLOEXEC | os.O_NOFOLLOW, 0o600)
            os.fchmod(fd, 0o600)
            fcntl.lockf(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            sys.stdout.write("ready\\n")
            sys.stdout.flush()
            sys.stdin.buffer.read(1)
            os.close(fd)
            """,
            fileURL.path,
        ]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let ready = output.fileHandleForReading.readData(ofLength: 6)
        guard String(data: ready, encoding: .utf8) == "ready\n" else {
            let remainder = output.fileHandleForReading.readDataToEndOfFile()
            process.terminate()
            process.waitUntilExit()
            throw RecoveryLeadershipTestError.subprocessDidNotBecomeReady(
                String(data: ready + remainder, encoding: .utf8) ?? "unknown"
            )
        }
    }

    func release() {
        guard !didRelease else { return }
        didRelease = true
        try? input.fileHandleForWriting.write(contentsOf: Data([0]))
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
    }

    deinit {
        release()
    }
}
#endif
