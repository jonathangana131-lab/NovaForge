import AgentDomain
@testable import AgentPolicy
import Foundation
import XCTest

final class WorkspaceMutationProcessArbiterTests: XCTestCase {
    func testTrueChildProcessExcludesSameWorkspaceButNotAnotherWorkspace()
        async throws
    {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let arbiter = try WorkspaceMutationProcessArbiter(
            directoryURL: directory.appendingPathComponent("locks"),
            timeoutMilliseconds: 75
        )
        let firstWorkspace = WorkspaceID()
        let secondWorkspace = WorkspaceID()

        let seedLease = try await arbiter.acquire(
            workspaceID: firstWorkspace
        )
        seedLease.release()
        let child = try launchChildHoldingLock(
            arbiter.lockURL(workspaceID: firstWorkspace)
        )
        defer { stop(child.process) }
        let signal = child.output.fileHandleForReading.availableData
        XCTAssertEqual(String(data: signal, encoding: .utf8), "locked\n")

        let started = Date()
        do {
            _ = try await arbiter.acquire(workspaceID: firstWorkspace)
            XCTFail("a separate process must own the workspace lane")
        } catch {
            XCTAssertEqual(
                error as? WorkspaceMutationProcessArbiterError,
                .lockUnavailable
            )
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)

        let independentLease = try await arbiter.acquire(
            workspaceID: secondWorkspace
        )
        independentLease.release()
    }

    func testLockIdentityReplacementIsRejectedAfterPinning() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let arbiter = try WorkspaceMutationProcessArbiter(
            directoryURL: directory.appendingPathComponent("locks"),
            timeoutMilliseconds: 75
        )
        let workspace = WorkspaceID()
        let firstLease = try await arbiter.acquire(workspaceID: workspace)
        firstLease.release()

        let lockURL = arbiter.lockURL(workspaceID: workspace)
        let displacedURL = lockURL.appendingPathExtension("displaced")
        try FileManager.default.moveItem(at: lockURL, to: displacedURL)
        XCTAssertTrue(FileManager.default.createFile(
            atPath: lockURL.path,
            contents: Data(),
            attributes: [.posixPermissions: 0o600]
        ))

        do {
            _ = try await arbiter.acquire(workspaceID: workspace)
            XCTFail("lock path substitution must fail closed")
        } catch {
            XCTAssertEqual(
                error as? WorkspaceMutationProcessArbiterError,
                .invalidLockIdentity
            )
        }
    }

    private func launchChildHoldingLock(
        _ lockURL: URL
    ) throws -> (process: Process, output: Pipe) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            "-c",
            "import fcntl,sys,time; f=open(sys.argv[1],'r+'); fcntl.lockf(f,fcntl.LOCK_EX); print('locked',flush=True); time.sleep(30)",
            lockURL.path,
        ]
        process.standardOutput = output
        try process.run()
        return (process, output)
    }

    private func stop(_ process: Process) {
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "novaforge-workspace-arbiter-tests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return url
    }
}
