import AgentDomain
import AgentPolicy
import AgentTools
import Darwin
import Foundation
import XCTest
@testable import NovaForge

final class POSIXWorkspaceEffectBackendTests: XCTestCase {
    func testMutationCoreImplementsCanonicalFilesystemSemantics() throws {
        let fixture = try Fixture()
        try fixture.write("old", to: "notes.txt")
        let executor = POSIXWorkspaceMutationExecutor()

        try execute(
            .writeFile(path: "notes.txt", contents: Data("first".utf8)),
            dispositions: [("notes.txt", .existingObject)],
            fixture: fixture,
            executor: executor
        )
        try execute(
            .appendFile(path: "notes.txt", contents: Data("+second".utf8)),
            dispositions: [("notes.txt", .existingObject)],
            fixture: fixture,
            executor: executor
        )
        try execute(
            .replaceText(
                path: "notes.txt",
                old: Data("second".utf8),
                new: Data("third".utf8),
                replaceAll: false
            ),
            dispositions: [("notes.txt", .existingObject)],
            fixture: fixture,
            executor: executor
        )
        XCTAssertEqual(try fixture.read("notes.txt"), "first+third")

        try execute(
            .createFile(path: "nested/empty.txt"),
            dispositions: [("nested/empty.txt", .creatableDestination)],
            fixture: fixture,
            executor: executor
        )
        XCTAssertEqual(try fixture.read("nested/empty.txt"), "")

        try execute(
            .makeDirectory(path: "assets/icons"),
            dispositions: [("assets/icons", .creatableDestination)],
            fixture: fixture,
            executor: executor
        )
        try execute(
            .copyPath(from: "notes.txt", to: "assets/copy.txt"),
            dispositions: [
                ("notes.txt", .existingObject),
                ("assets/copy.txt", .creatableDestination),
            ],
            fixture: fixture,
            executor: executor
        )
        try execute(
            .movePath(from: "assets/copy.txt", to: "moved.txt"),
            dispositions: [
                ("assets/copy.txt", .existingObject),
                ("moved.txt", .creatableDestination),
            ],
            fixture: fixture,
            executor: executor
        )
        XCTAssertEqual(try fixture.read("moved.txt"), "first+third")

        try execute(
            .deletePath(path: "assets"),
            dispositions: [("assets", .existingObject)],
            fixture: fixture,
            executor: executor
        )
        XCTAssertFalse(fixture.exists("assets"))

        try execute(
            .resetWorkspace,
            dispositions: [("", .existingObject)],
            fixture: fixture,
            executor: executor
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: fixture.root.path
            ),
            []
        )
    }

    func testParentTraversalAndSymlinkEscapeAreRejected() throws {
        let fixture = try Fixture()
        let outside = fixture.base.appendingPathComponent("outside.txt")
        try Data("secret".utf8).write(to: outside)

        XCTAssertThrowsError(try POSIXWorkspaceTargetCondition.capture(
            rootURL: fixture.root,
            path: "../outside.txt",
            disposition: .existingObject
        )) { error in
            XCTAssertEqual(
                error as? POSIXWorkspaceInfrastructureError,
                .invalidRelativePath
            )
        }

        let link = fixture.root.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: fixture.base
        )
        XCTAssertThrowsError(try POSIXWorkspaceTargetCondition.capture(
            rootURL: fixture.root,
            path: "escape/outside.txt",
            disposition: .existingObject
        )) { error in
            XCTAssertEqual(
                error as? POSIXWorkspaceInfrastructureError,
                .unsafeFilesystemObject
            )
        }
        XCTAssertEqual(String(data: try Data(contentsOf: outside), encoding: .utf8), "secret")
    }

    func testTargetSwapToOutsideSymlinkFailsBeforeWriting() throws {
        let fixture = try Fixture()
        try fixture.write("inside", to: "target.txt")
        let outside = fixture.base.appendingPathComponent("outside.txt")
        try Data("outside".utf8).write(to: outside)
        let condition = try POSIXWorkspaceTargetCondition.capture(
            rootURL: fixture.root,
            path: "target.txt",
            disposition: .existingObject
        )
        let executor = POSIXWorkspaceMutationExecutor(
            interposition: POSIXWorkspaceMutationInterposition {
                let target = fixture.root.appendingPathComponent("target.txt")
                let parked = fixture.root.appendingPathComponent("parked.txt")
                try FileManager.default.moveItem(at: target, to: parked)
                try FileManager.default.createSymbolicLink(
                    at: target,
                    withDestinationURL: outside
                )
            }
        )

        XCTAssertThrowsError(try executor.execute(
            .writeFile(path: "target.txt", contents: Data("attack".utf8)),
            rootURL: fixture.root,
            conditions: [condition]
        ))
        XCTAssertEqual(String(data: try Data(contentsOf: outside), encoding: .utf8), "outside")
    }

    func testRacedInDestinationIsNotOverwrittenAtFinalCommit() throws {
        let fixture = try Fixture()
        let condition = try POSIXWorkspaceTargetCondition.capture(
            rootURL: fixture.root,
            path: "destination.txt",
            disposition: .creatableDestination
        )
        let executor = POSIXWorkspaceMutationExecutor(
            interposition: POSIXWorkspaceMutationInterposition(
                afterInitialValidation: {},
                beforeFinalFilesystemCommit: {
                    try Data("raced".utf8).write(
                        to: fixture.root.appendingPathComponent(
                            "destination.txt"
                        )
                    )
                }
            )
        )

        XCTAssertThrowsError(try executor.execute(
            .writeFile(
                path: "destination.txt",
                contents: Data("authorized".utf8)
            ),
            rootURL: fixture.root,
            conditions: [condition]
        )) { error in
            XCTAssertEqual(
                error as? POSIXWorkspaceInfrastructureError,
                .targetChanged
            )
        }
        XCTAssertEqual(try fixture.read("destination.txt"), "raced")
    }

    func testHardLinkedRegularFileIsRejected() throws {
        let fixture = try Fixture()
        try fixture.write("value", to: "first.txt")
        let first = fixture.root.appendingPathComponent("first.txt").path
        let second = fixture.root.appendingPathComponent("second.txt").path
        XCTAssertEqual(link(first, second), 0)

        XCTAssertThrowsError(try POSIXWorkspaceTree.capture(
            root: POSIXWorkspaceFD.openRoot(at: fixture.root),
            limits: .production
        )) { error in
            XCTAssertEqual(
                error as? POSIXWorkspaceInfrastructureError,
                .unsafeFilesystemObject
            )
        }
    }

    func testMissingRootTwoSiblingSeedResolvesWithoutContainmentCollision() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "POSIXResolverTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: base) }
        let container = base.appendingPathComponent("Workspaces", isDirectory: true)
        try FileManager.default.createDirectory(
            at: container,
            withIntermediateDirectories: true
        )
        let workspaceID = WorkspaceID()
        let provider = BoundAgentWorkspaceRootProvider(
            workspaceID: workspaceID,
            location: try AgentWorkspaceRootLocation(
                containerURL: container,
                directoryName: "Fresh"
            )
        )
        let resolver = WorkspaceTargetResolverAuthority(
            trustedBackend: POSIXWorkspaceTargetResolutionBackend(
                roots: provider
            )
        )

        let request = try await RiskPolicyRequest.resolveProjectOS(
            runID: RunID(),
            projectID: ProjectID(),
            workspaceID: workspaceID,
            sessionID: nil,
            backend: .onDevice,
            callID: ToolCallID(),
            operationAttemptID: AttemptID(),
            idempotencyKey: "seed-\(UUID().uuidString)",
            operation: .seedWorkspace(SeedWorkspaceMutationArguments(entries: [
                SeedWorkspaceEntry(path: "README.md", contents: "one"),
                SeedWorkspaceEntry(path: "Sources/App.swift", contents: "two"),
            ])),
            using: resolver
        )

        XCTAssertEqual(
            Set(request.resolvedTargets.map(\.path)),
            Set(["README.md", "Sources/App.swift"])
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: container.appendingPathComponent("Fresh").path
            ),
            "resolution must remain side-effect free"
        )
    }

    func testMutatingCommandParserRejectsShellSyntaxAndFlags() {
        for command in [
            "rm -rf project",
            "touch a && touch b",
            "mkdir ../escape",
            "cp source destination; rm source",
            "pwd",
        ] {
            XCTAssertThrowsError(try POSIXMutationCommand.parse(command))
        }
    }

    func testMissingRootBootstrapRejectsSpoofedSeedDescriptor() {
        let spoof = ToolDescriptor(
            metadata: ToolDescriptorMetadata(
                name: "seed_workspace",
                version: ToolVersion(major: 1, minor: 0, patch: 0),
                toolset: "spoofed_policy_workspace",
                description: "Spoof",
                availability: ToolAvailabilityRequirement(
                    allowedLocalities: [.onDevice],
                    requiredCapabilities: [.workspaceWrite],
                    requiresWorkspace: true
                ),
                effectClass: .scopedReversibleWrite,
                approvalClass: .explicit,
                targetStrategy: .arrayArgumentPaths(
                    arrayPath: ["entries"],
                    elementRules: [
                        ToolTargetRule(argumentPath: ["path"], access: .write),
                    ]
                ),
                parallelSafety: .workspaceSerialized,
                concurrencyKey: "workspace",
                limits: ToolLimits(
                    timeoutMilliseconds: 30_000,
                    maximumArgumentBytes: 2_100_000,
                    maximumOutputBytes: 65_536
                ),
                redaction: ToolRedactionPolicy(
                    argumentRules: [],
                    output: .replace(.string("<redacted-mutation-output>"))
                ),
                legacyAdapter: nil,
                receipt: ToolReceiptMetadata(
                    actionVerb: "Changed",
                    successSummary: "Workspace changed"
                ),
                evidence: .changedPath,
                ui: ToolUIMetadata(
                    title: "Seed Workspace",
                    systemImageName: "folder.badge.gearshape",
                    category: .edit,
                    resultPresentation: .text
                )
            ),
            argumentSchema: SeedWorkspaceMutationArguments.jsonSchema
        )
        XCTAssertFalse(
            POSIXWorkspaceTargetResolutionBackend
                .isCanonicalSeedDescriptor(spoof)
        )
    }

    private func execute(
        _ mutation: POSIXWorkspaceMutation,
        dispositions: [(String, POSIXWorkspaceTargetDisposition)],
        fixture: Fixture,
        executor: POSIXWorkspaceMutationExecutor
    ) throws {
        let conditions = try dispositions.map {
            try POSIXWorkspaceTargetCondition.capture(
                rootURL: fixture.root,
                path: $0.0,
                disposition: $0.1
            )
        }
        _ = try executor.execute(
            mutation,
            rootURL: fixture.root,
            conditions: conditions
        )
    }
}

private extension POSIXWorkspaceEffectBackendTests {
    final class Fixture: @unchecked Sendable {
        let base: URL
        let root: URL

        init() throws {
            base = FileManager.default.temporaryDirectory.appendingPathComponent(
                "POSIXEffectTests-\(UUID().uuidString)",
                isDirectory: true
            )
            root = base.appendingPathComponent("Workspace", isDirectory: true)
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
        }

        deinit { try? FileManager.default.removeItem(at: base) }

        func write(_ value: String, to path: String) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(value.utf8).write(to: url)
        }

        func read(_ path: String) throws -> String {
            String(
                decoding: try Data(
                    contentsOf: root.appendingPathComponent(path)
                ),
                as: UTF8.self
            )
        }

        func exists(_ path: String) -> Bool {
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(path).path
            )
        }
    }
}
