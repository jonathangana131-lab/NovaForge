import AgentDomain
import AgentEngine
import AgentTools
import Foundation
import XCTest
@testable import NovaForge

@MainActor
final class AgentSandboxReadOnlyToolExecutorTests: XCTestCase {
    func testCanonicalReadReturnsOnlyObservedClassifiedOutput() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        try Data("observed value".utf8).write(
            to: fixture.root.appendingPathComponent("note.txt")
        )
        let request = try makeRequest(
            workspace: fixture.workspace,
            projectID: fixture.projectID,
            arguments: .object(["path": .string("note.txt")])
        )

        let output = try await fixture.executor.executeReadOnly(request)

        XCTAssertEqual(output.output, .string("observed value"))
        XCTAssertTrue(output.artifacts.isEmpty)
        XCTAssertTrue(output.evidence.isEmpty)
        XCTAssertTrue(output.warnings.isEmpty)
    }

    func testForeignWorkspaceAndProjectIdentitiesFailClosed() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        try Data("bound".utf8).write(
            to: fixture.root.appendingPathComponent("note.txt")
        )
        let foreignWorkspace = try makeRequest(
            workspace: fixture.workspace,
            projectID: fixture.projectID,
            arguments: .object(["path": .string("note.txt")]),
            contextWorkspaceID: WorkspaceID(rawValue: uuid(901))
        )
        let foreignProject = try makeRequest(
            workspace: fixture.workspace,
            projectID: fixture.projectID,
            arguments: .object(["path": .string("note.txt")]),
            contextProjectID: ProjectID(rawValue: uuid(902))
        )

        await assertFailure(
            .workspaceMismatch,
            executor: fixture.executor,
            request: foreignWorkspace
        )
        await assertFailure(
            .projectMismatch,
            executor: fixture.executor,
            request: foreignProject
        )
    }

    func testUnknownToolDescriptorAndDigestSpoofsFailClosed() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        try Data("bound".utf8).write(
            to: fixture.root.appendingPathComponent("note.txt")
        )
        let arguments: JSONValue = .object([
            "path": .string("note.txt"),
        ])
        let unknown = try makeRequest(
            workspace: fixture.workspace,
            projectID: fixture.projectID,
            arguments: arguments,
            invocationIdentity: ToolIdentity(
                name: "unknown_read",
                version: "1.0.0"
            )
        )
        let registry = try SandboxToolCatalog.canonicalRegistry()
        let wrongDescriptor = try makeRequest(
            workspace: fixture.workspace,
            projectID: fixture.projectID,
            arguments: arguments,
            requestDescriptor: registry.descriptor(named: "file_info")
        )
        let wrongDigest = try makeRequest(
            workspace: fixture.workspace,
            projectID: fixture.projectID,
            arguments: arguments,
            canonicalDigest: "sha256:not-the-canonical-argument-digest"
        )

        await assertFailure(
            .unknownTool,
            executor: fixture.executor,
            request: unknown
        )
        await assertFailure(
            .descriptorMismatch,
            executor: fixture.executor,
            request: wrongDescriptor
        )
        await assertFailure(
            .invocationMismatch,
            executor: fixture.executor,
            request: wrongDigest
        )
    }

    func testEffectLocalityAndMutatingDescriptorCannotReachBackend() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        try Data("bound".utf8).write(
            to: fixture.root.appendingPathComponent("note.txt")
        )
        let readArguments: JSONValue = .object([
            "path": .string("note.txt"),
        ])
        let effectMismatch = try makeRequest(
            workspace: fixture.workspace,
            projectID: fixture.projectID,
            arguments: readArguments,
            effectClass: .scopedReversibleWrite
        )
        let localityMismatch = try makeRequest(
            workspace: fixture.workspace,
            projectID: fixture.projectID,
            arguments: readArguments,
            locality: .worker
        )
        let writeArguments: JSONValue = .object([
            "path": .string("must-not-exist.txt"),
            "contents": .string("blocked"),
        ])
        let mutatingDescriptor = try makeRequest(
            workspace: fixture.workspace,
            projectID: fixture.projectID,
            toolName: "write_file",
            arguments: writeArguments,
            effectClass: .scopedReversibleWrite
        )

        await assertFailure(
            .effectMismatch,
            executor: fixture.executor,
            request: effectMismatch
        )
        await assertFailure(
            .localityMismatch,
            executor: fixture.executor,
            request: localityMismatch
        )
        await assertFailure(
            .invalidReadOnlyContract,
            executor: fixture.executor,
            request: mutatingDescriptor
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.root.appendingPathComponent(
                "must-not-exist.txt"
            ).path
        ))
    }

    func testMalformedAndMismatchedDecodedArgumentsFailClosed() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        try Data("bound".utf8).write(
            to: fixture.root.appendingPathComponent("note.txt")
        )
        let registry = try SandboxToolCatalog.canonicalRegistry()
        let validDecoded = try registry.decode(
            name: "read_file",
            version: "1.0.0",
            arguments: .object(["path": .string("note.txt")])
        )
        let malformed = try makeRequest(
            workspace: fixture.workspace,
            projectID: fixture.projectID,
            arguments: .object(["path": .number(.integer(7))]),
            canonicalDigest: "invalid",
            decodedArguments: validDecoded
        )
        let otherDecoded = try registry.decode(
            name: "read_file",
            version: "1.0.0",
            arguments: .object(["path": .string("other.txt")])
        )
        let mismatched = try makeRequest(
            workspace: fixture.workspace,
            projectID: fixture.projectID,
            arguments: .object(["path": .string("note.txt")]),
            decodedArguments: otherDecoded
        )

        await assertFailure(
            .invalidArguments,
            executor: fixture.executor,
            request: malformed
        )
        await assertFailure(
            .invalidArguments,
            executor: fixture.executor,
            request: mismatched
        )
    }

    func testPathEscapeAndSymlinkAreRejectedBeforeOutput() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "NovaForgeM8Outside-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("outside secret".utf8).write(
            to: outside.appendingPathComponent("secret.txt")
        )
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appendingPathComponent("escape"),
            withDestinationURL: outside
        )
        let traversal = try makeRequest(
            workspace: fixture.workspace,
            projectID: fixture.projectID,
            arguments: .object(["path": .string("../secret.txt")])
        )
        let symlink = try makeRequest(
            workspace: fixture.workspace,
            projectID: fixture.projectID,
            arguments: .object([
                "path": .string("escape/secret.txt"),
            ])
        )

        await assertFailure(
            .unsafeTarget,
            executor: fixture.executor,
            request: traversal
        )
        await assertFailure(
            .unsafeTarget,
            executor: fixture.executor,
            request: symlink
        )
    }

    func testOutputByteAndItemLimitsFailClosed() async throws {
        let byteFixture = try makeFixture(
            limits: .init(maximumBytes: 8, maximumItems: 100)
        )
        defer { byteFixture.remove() }
        try Data("0123456789".utf8).write(
            to: byteFixture.root.appendingPathComponent("bytes.txt")
        )
        let byteRequest = try makeRequest(
            workspace: byteFixture.workspace,
            projectID: byteFixture.projectID,
            arguments: .object(["path": .string("bytes.txt")])
        )

        let itemFixture = try makeFixture(
            limits: .init(maximumBytes: 1_024, maximumItems: 2)
        )
        defer { itemFixture.remove() }
        try Data("one\ntwo\nthree".utf8).write(
            to: itemFixture.root.appendingPathComponent("items.txt")
        )
        let itemRequest = try makeRequest(
            workspace: itemFixture.workspace,
            projectID: itemFixture.projectID,
            arguments: .object(["path": .string("items.txt")])
        )

        await assertFailure(
            .outputByteLimitExceeded,
            executor: byteFixture.executor,
            request: byteRequest
        )
        await assertFailure(
            .outputItemLimitExceeded,
            executor: itemFixture.executor,
            request: itemRequest
        )
    }

    func testInvalidLimitExpansionIsRejected() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = SandboxWorkspace(rootURL: root)

        XCTAssertThrowsError(try AgentSandboxReadOnlyToolExecutor(
            workspace: workspace,
            projectID: ProjectID(rawValue: uuid(920)),
            outputLimits: .init(
                maximumBytes: 512 * 1_024 + 1,
                maximumItems: 2_048
            )
        )) { error in
            XCTAssertEqual(
                error as? AgentSandboxReadOnlyToolExecutorError,
                .invalidLimits
            )
        }
    }

    func testProductionBackendImplementsExactlyTwelveCanonicalReads() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let docs = fixture.root.appendingPathComponent(
            "docs",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: docs,
            withIntermediateDirectories: true
        )
        try Data("alpha\nbeta\ngamma\n".utf8).write(
            to: docs.appendingPathComponent("note.txt")
        )
        try Data("alpha\nchanged\ngamma\n".utf8).write(
            to: docs.appendingPathComponent("other.txt")
        )
        try Data("{\"ready\":true}".utf8).write(
            to: fixture.root.appendingPathComponent("data.json")
        )
        try Data("""
        <!doctype html><html><head><meta name="viewport"></head>
        <body><main>Ready</main></body></html>
        """.utf8).write(
            to: fixture.root.appendingPathComponent("index.html")
        )
        try Data("struct Demo {\n  func run() {}\n}\n".utf8).write(
            to: fixture.root.appendingPathComponent("Demo.swift")
        )

        let cases: [(String, JSONValue, String)] = [
            ("list_directory", .object(["path": .string("docs")]), "file: docs/note.txt"),
            ("list_tree", .object([:]), "▸ docs"),
            ("workspace_summary", .object([:]), "Workspace:"),
            ("file_info", .object(["path": .string("docs/note.txt")]), "Kind: file"),
            ("read_file", .object(["path": .string("docs/note.txt")]), "alpha"),
            ("read_file_range", .object([
                "path": .string("docs/note.txt"),
                "start_line": .number(.integer(2)),
                "line_count": .number(.integer(1)),
            ]), "2|beta"),
            ("tail_file", .object([
                "path": .string("docs/note.txt"),
                "line_count": .number(.integer(2)),
            ]), "3|gamma"),
            ("search_text", .object([
                "query": .string("beta"),
                "path": .string("docs"),
            ]), "docs/note.txt:2: beta"),
            ("diff_files", .object([
                "left": .string("docs/note.txt"),
                "right": .string("docs/other.txt"),
            ]), "+2|changed"),
            ("validate_json", .object(["path": .string("data.json")]), "ok"),
            ("validate_html_file", .object([
                "path": .string("index.html"),
                "profile": .string("page"),
            ]), "ready for preview"),
            ("extract_outline", .object(["path": .string("Demo.swift")]), "1|struct Demo"),
        ]
        XCTAssertEqual(POSIXWorkspaceReadBackend.supportedToolNames.count, 12)

        for (toolName, arguments, expected) in cases {
            let request = try makeRequest(
                workspace: fixture.workspace,
                projectID: fixture.projectID,
                toolName: toolName,
                arguments: arguments
            )
            let result = try await fixture.executor.executeReadOnly(request)
            guard case let .string(output) = result.output else {
                XCTFail("\(toolName) did not return classified text")
                continue
            }
            XCTAssertTrue(
                output.contains(expected),
                "\(toolName) output omitted expected marker: \(expected)"
            )
        }
    }

    func testPinnedRootCannotBeRedirectedAfterConstruction() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "NovaForgeM8PinnedRoot-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("workspace", isDirectory: true)
        let parked = base.appendingPathComponent("parked", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: true
        )
        try Data("inside-authorized".utf8).write(
            to: root.appendingPathComponent("note.txt")
        )
        try Data("outside-secret".utf8).write(
            to: outside.appendingPathComponent("note.txt")
        )
        let workspace = SandboxWorkspace(rootURL: root)
        let projectID = ProjectID(rawValue: uuid(925))
        let executor = try AgentSandboxReadOnlyToolExecutor(
            workspace: workspace,
            projectID: projectID
        )
        let request = try makeRequest(
            workspace: workspace,
            projectID: projectID,
            arguments: .object(["path": .string("note.txt")])
        )

        try FileManager.default.moveItem(at: root, to: parked)
        try FileManager.default.createSymbolicLink(
            at: root,
            withDestinationURL: outside
        )
        let output = try await executor.executeReadOnly(request)

        XCTAssertEqual(output.output, .string("inside-authorized"))
        XCTAssertNotEqual(output.output, .string("outside-secret"))
    }

    func testCancellationAfterBackendEntrySuppressesOutput() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("cancelled value".utf8).write(
            to: root.appendingPathComponent("note.txt")
        )
        let gate = ReadExecutionGate()
        let workspace = SandboxWorkspace(rootURL: root)
        let projectID = ProjectID(rawValue: uuid(930))
        let executor = try AgentSandboxReadOnlyToolExecutor(
            workspace: workspace,
            projectID: projectID,
            outputLimits: .production,
            readInterposition: POSIXWorkspaceReadInterposition(
                beforeOpenComponent: { path in
                    if path == "note.txt" { gate.enter() }
                },
                afterOpenComponent: { _ in }
            )
        )
        let request = try makeRequest(
            workspace: workspace,
            projectID: projectID,
            arguments: .object(["path": .string("note.txt")])
        )
        let task = Task.detached {
            try await executor.executeReadOnly(request)
        }

        XCTAssertEqual(gate.waitUntilEntered(), .success)
        task.cancel()
        gate.release()
        do {
            _ = try await task.value
            XCTFail("Cancelled read unexpectedly returned output")
        } catch let error as AgentSandboxReadOnlyToolExecutorError {
            XCTAssertEqual(error, .cancelled)
        } catch {
            XCTFail("Unexpected cancellation error: \(type(of: error))")
        }
    }

    func testComponentReplacementAfterOpenWithholdsOutsideBytes() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "NovaForgeM8ReadRace-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent(
            "workspace",
            isDirectory: true
        )
        let parent = root.appendingPathComponent(
            "parent",
            isDirectory: true
        )
        let parked = base.appendingPathComponent(
            "parked",
            isDirectory: true
        )
        let outside = base.appendingPathComponent(
            "outside",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: true
        )
        try Data("inside".utf8).write(
            to: parent.appendingPathComponent("note.txt")
        )
        try Data("outside-secret-must-not-return".utf8).write(
            to: outside.appendingPathComponent("note.txt")
        )
        let probe = SwapRestoreProbe(
            parent: parent,
            parked: parked,
            outside: outside
        )
        let workspace = SandboxWorkspace(rootURL: root)
        let projectID = ProjectID(rawValue: uuid(940))
        let executor = try AgentSandboxReadOnlyToolExecutor(
            workspace: workspace,
            projectID: projectID,
            outputLimits: .production,
            readInterposition: POSIXWorkspaceReadInterposition(
                beforeOpenComponent: { _ in },
                afterOpenComponent: { path in
                    if path == "parent" { try probe.swapToOutside() }
                }
            )
        )
        let request = try makeRequest(
            workspace: workspace,
            projectID: projectID,
            arguments: .object([
                "path": .string("parent/note.txt"),
            ])
        )

        await assertFailure(
            .workspaceChanged,
            executor: executor,
            request: request
        )
        try probe.restoreInside()
        XCTAssertTrue(probe.didSwapAndRestore)
        XCTAssertEqual(
            try String(
                contentsOf: parent.appendingPathComponent("note.txt"),
                encoding: .utf8
            ),
            "inside"
        )
    }
}

private extension AgentSandboxReadOnlyToolExecutorTests {
    struct Fixture {
        let root: URL
        let workspace: SandboxWorkspace
        let projectID: ProjectID
        let executor: AgentSandboxReadOnlyToolExecutor

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    func makeFixture(
        limits: AgentSandboxReadOnlyToolExecutor.OutputLimits = .production
    ) throws -> Fixture {
        let root = try makeRoot()
        let workspace = SandboxWorkspace(rootURL: root)
        let projectID = ProjectID(rawValue: uuid(800))
        return Fixture(
            root: root,
            workspace: workspace,
            projectID: projectID,
            executor: try AgentSandboxReadOnlyToolExecutor(
                workspace: workspace,
                projectID: projectID,
                outputLimits: limits
            )
        )
    }

    func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "NovaForgeM8ReadExecutor-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return root
    }

    func makeRequest(
        workspace: SandboxWorkspace,
        projectID: ProjectID?,
        toolName: String = "read_file",
        arguments: JSONValue,
        requestDescriptor: ToolDescriptor? = nil,
        invocationIdentity: ToolIdentity? = nil,
        effectClass: ToolEffectClass? = nil,
        locality: ToolExecutionLocality = .onDevice,
        canonicalDigest: String? = nil,
        decodedArguments: DecodedToolArguments? = nil,
        contextWorkspaceID: WorkspaceID? = nil,
        contextProjectID: ProjectID? = nil
    ) throws -> AgentReadOnlyToolRequest {
        let registry = try SandboxToolCatalog.canonicalRegistry()
        let descriptor = try registry.descriptor(named: toolName)
        let decoded = try decodedArguments ?? registry.decode(
            name: descriptor.name,
            version: descriptor.version.description,
            arguments: arguments
        )
        let identity = try WorkspaceResourceIdentity(workspace: workspace)
        let runID = RunID(rawValue: uuid(1))
        let context = AgentRunContext(
            schemaVersion: .current,
            lineage: .root(runID),
            conversationID: ConversationID(rawValue: uuid(2)),
            projectID: contextProjectID ?? projectID,
            workspaceID: contextWorkspaceID ?? WorkspaceID(
                rawValue: identity.persistentID
            ),
            executionNodeID: ExecutionNodeID(rawValue: uuid(3)),
            engineVersion: .agentHarnessV2,
            acceptedAt: AgentInstant(rawValue: 1_900_000_000_000),
            features: AgentFeatureSet([]),
            cancellation: CancellationLineage(
                scopeID: CancellationScopeID(rawValue: uuid(4))
            ),
            initialBudget: AgentBudget(limits: .standard)
        )
        let digest = try canonicalDigest ?? descriptor
            .canonicalArgumentDigest(for: arguments)
        let invocation = ToolInvocation(
            callID: ToolCallID(rawValue: uuid(5)),
            providerCallID: "provider-call-5",
            modelAttemptID: AttemptID(rawValue: uuid(6)),
            tool: invocationIdentity ?? descriptor.identity,
            arguments: arguments,
            canonicalArgumentDigest: digest,
            idempotencyKey: "m8-read-only:5",
            effectClass: effectClass ?? descriptor.effectClass,
            locality: locality
        )
        return AgentReadOnlyToolRequest(
            context: context,
            invocation: invocation,
            descriptor: requestDescriptor ?? descriptor,
            decodedArguments: decoded
        )
    }

    func assertFailure(
        _ expected: AgentSandboxReadOnlyToolExecutorError,
        executor: AgentSandboxReadOnlyToolExecutor,
        request: AgentReadOnlyToolRequest,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await executor.executeReadOnly(request)
            XCTFail(
                "Read-only execution unexpectedly succeeded",
                file: file,
                line: line
            )
        } catch let error as AgentSandboxReadOnlyToolExecutorError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail(
                "Unexpected error type: \(type(of: error))",
                file: file,
                line: line
            )
        }
    }

    func uuid(_ value: UInt64) -> UUID {
        UUID(uuidString: String(
            format: "00000000-0000-8000-8000-%012llx",
            value
        ))!
    }
}

private final class ReadExecutionGate: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)

    func enter() {
        entered.signal()
        released.wait()
    }

    func waitUntilEntered() -> DispatchTimeoutResult {
        entered.wait(timeout: .now() + 3)
    }

    func release() {
        released.signal()
    }
}

private final class SwapRestoreProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let parent: URL
    private let parked: URL
    private let outside: URL
    private var swapped = false
    private var restored = false

    init(parent: URL, parked: URL, outside: URL) {
        self.parent = parent
        self.parked = parked
        self.outside = outside
    }

    var didSwapAndRestore: Bool {
        lock.lock()
        defer { lock.unlock() }
        return swapped && restored
    }

    func swapToOutside() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !swapped else { return }
        try FileManager.default.moveItem(at: parent, to: parked)
        try FileManager.default.createSymbolicLink(
            at: parent,
            withDestinationURL: outside
        )
        swapped = true
    }

    func restoreInside() throws {
        lock.lock()
        defer { lock.unlock() }
        guard swapped, !restored else { return }
        try FileManager.default.removeItem(at: parent)
        try FileManager.default.moveItem(at: parked, to: parent)
        restored = true
    }
}
