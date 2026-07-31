import AgentDomain
import AgentTools
import XCTest

final class ToolRegistryContractTests: XCTestCase {
    private let executorOperations: Set<String> = [
        "append_file",
        "copy_path",
        "delete_path",
        "diff_files",
        "extract_outline",
        "file_info",
        "list_directory",
        "list_tree",
        "make_directory",
        "move_path",
        "read_file",
        "read_file_range",
        "replace_text",
        "run_command",
        "search_text",
        "tail_file",
        "validate_html_file",
        "validate_json",
        "workspace_summary",
        "write_file",
    ]

    func testCanonicalRegistryCoversEveryLegacyExecutorOperationExactlyOnce() throws {
        let registry = try SandboxToolCatalog.canonicalRegistry()
        let registryNames = Set(registry.descriptors.map(\.name))
        XCTAssertEqual(registryNames, executorOperations)
        XCTAssertEqual(registry.descriptors.count, executorOperations.count)

        let legacyNames = try Set(registry.descriptors.map { descriptor in
            try XCTUnwrap(descriptor.legacyAdapter).executorName
        })
        XCTAssertEqual(legacyNames, executorOperations)

        for descriptor in registry.descriptors {
            let legacy = try XCTUnwrap(descriptor.legacyAdapter)
            XCTAssertEqual(legacy.executorName, descriptor.name)
            XCTAssertEqual(legacy.supportedMajorVersion, descriptor.version.major)
            guard case let .object(_, properties, _, additionalProperties) = descriptor.argumentSchema else {
                return XCTFail("\(descriptor.name) must expose an object argument schema")
            }
            XCTAssertFalse(additionalProperties)
            XCTAssertEqual(Set(legacy.fieldMappings.map(\.argumentName)), Set(properties.keys))
            XCTAssertFalse(descriptor.ui.title.isEmpty)
            XCTAssertFalse(descriptor.description.isEmpty)
        }
    }

    func testMutationClassificationMatchesEveryLegacyMutatingOperation() throws {
        let legacyMutations: Set<String> = [
            "append_file", "copy_path", "delete_path", "make_directory",
            "move_path", "replace_text", "run_command", "write_file",
        ]
        let registry = try SandboxToolCatalog.canonicalRegistry()
        let registryMutations = Set(
            registry.descriptors
                .filter { $0.effectClass != .readOnlyLocal }
                .map(\.name)
        )
        XCTAssertEqual(registryMutations, legacyMutations)
    }

    func testProviderDefinitionsAreDeterministicAndGeneratedFromDescriptorsOnly() throws {
        let registry = try SandboxToolCatalog.canonicalRegistry()
        let first = try registry.providerDefinitionsData()
        let second = try registry.providerDefinitionsData()
        XCTAssertEqual(first, second)

        let definitions = try JSONDecoder().decode([ProviderToolDefinition].self, from: first)
        XCTAssertEqual(definitions.map(\.function.name), registry.descriptors.map(\.name))
        XCTAssertEqual(definitions.map(\.function.name), definitions.map(\.function.name).sorted())
        XCTAssertTrue(definitions.allSatisfy { $0.type == "function" && $0.function.strict })

        for (descriptor, definition) in zip(registry.descriptors, definitions) {
            XCTAssertEqual(definition.function.parameters, descriptor.argumentSchema.strictProviderValue)
        }
        let uiDefinitions = registry.uiDefinitions()
        XCTAssertEqual(uiDefinitions.map(\.identity.name), registry.descriptors.map(\.name))
        XCTAssertEqual(uiDefinitions.map(\.metadata), registry.descriptors.map(\.ui))

        let listTree = try XCTUnwrap(definitions.first { $0.function.name == "list_tree" })
        let properties = try providerProperties(from: listTree.function.parameters)
        XCTAssertEqual(providerTypes(from: try XCTUnwrap(properties["max_depth"])), ["integer", "null"])
        XCTAssertEqual(
            providerRequired(from: listTree.function.parameters),
            ["max_depth", "max_items"]
        )

        let replace = try XCTUnwrap(definitions.first { $0.function.name == "replace_text" })
        let replaceProperties = try providerProperties(from: replace.function.parameters)
        XCTAssertEqual(providerTypes(from: try XCTUnwrap(replaceProperties["replace_all"])), ["boolean", "null"])
    }

    func testTypedDecoderPreservesBooleanIntegerNumberNullArraysAndNestedObjects() throws {
        let registry = try ToolRegistry(tools: [.init(NestedContractTool.self)])
        let decoded = try registry.decode(
            name: "nested_contract",
            arguments: .object([
                "enabled": .bool(true),
                "count": .number(.integer(3)),
                "ratio": .number(.floatingPoint(0.75)),
                "note": .null,
                "entries": .array([
                    .object(["id": .string("first"), "secret": .string("token-a")]),
                    .object(["id": .string("second"), "secret": .string("token-b")]),
                ]),
                "options": .object([
                    "retries": .number(.integer(2)),
                    "labels": .array([.string("swift"), .string("sandbox")]),
                ]),
            ])
        )
        let arguments: NestedContractArguments = try decoded.value()
        XCTAssertTrue(arguments.enabled)
        XCTAssertEqual(arguments.count, 3)
        XCTAssertEqual(arguments.ratio, 0.75)
        XCTAssertNil(arguments.note)
        XCTAssertEqual(arguments.entries.map(\.id), ["first", "second"])
        XCTAssertEqual(arguments.options.retries, 2)
        XCTAssertEqual(arguments.options.labels, ["swift", "sandbox"])
        XCTAssertEqual(try registry.descriptor(named: "nested_alias").name, "nested_contract")
    }

    func testRegistryDecodesCurrentBooleanNumberAndNullContractsWithoutStringCoercion() throws {
        let registry = try SandboxToolCatalog.canonicalRegistry()

        let replaceBox = try registry.decode(
            name: "replace_text",
            version: "1.0.0",
            arguments: .object([
                "path": .string("Sources/App.swift"),
                "old": .string("false"),
                "new": .string("true"),
                "replace_all": .bool(true),
            ])
        )
        let replace: ReplaceTextArguments = try replaceBox.value()
        XCTAssertEqual(replace.replaceAll, true)

        let treeBox = try registry.decode(
            name: "list_tree",
            arguments: .object([
                "max_depth": .number(.integer(7)),
                "max_items": .number(.integer(400)),
            ])
        )
        let tree: ListTreeArguments = try treeBox.value()
        XCTAssertEqual(tree.maxDepth, 7)
        XCTAssertEqual(tree.maxItems, 400)

        let htmlBox = try registry.decode(
            name: "validate_html_file",
            arguments: .object(["path": .string("index.html"), "profile": .null])
        )
        let html: ValidateHTMLArguments = try htmlBox.value()
        XCTAssertNil(html.profile)
    }

    func testRequiredBoundsEnumTypeAndUnknownFieldValidationFailClosed() throws {
        let registry = try SandboxToolCatalog.canonicalRegistry()

        assertValidationCode(.missingRequiredField) {
            _ = try registry.decode(name: "read_file", arguments: .object([:]))
        }
        assertValidationCode(.tooShort) {
            _ = try registry.decode(name: "read_file", arguments: .object(["path": .string("")]))
        }
        assertValidationCode(.aboveMaximum) {
            _ = try registry.decode(
                name: "list_tree",
                arguments: .object(["max_depth": .number(.integer(11))])
            )
        }
        assertValidationCode(.typeMismatch) {
            _ = try registry.decode(
                name: "replace_text",
                arguments: .object([
                    "path": .string("a"),
                    "old": .string("x"),
                    "new": .string("y"),
                    "replace_all": .number(.integer(1)),
                ])
            )
        }
        assertValidationCode(.disallowedValue) {
            _ = try registry.decode(
                name: "validate_html_file",
                arguments: .object(["path": .string("a.html"), "profile": .string("unsafe")])
            )
        }
        assertValidationCode(.unknownField) {
            _ = try registry.decode(
                name: "workspace_summary",
                arguments: .object(["unreviewed": .bool(true)])
            )
        }
    }

    func testRedactionHandlesTopLevelFieldsNestedObjectsArraysAndOutputs() throws {
        let registry = try SandboxToolCatalog.canonicalRegistry()
        let write = try registry.descriptor(named: "write_file")
        let original: JSONValue = .object([
            "path": .string("Private/secret.txt"),
            "contents": .string("api-key-value"),
        ])
        XCTAssertEqual(
            write.redaction.redact(arguments: original),
            .object([
                "path": .string("<redacted>"),
                "contents": .string("<redacted>"),
            ])
        )
        XCTAssertEqual(
            write.redaction.redact(output: .string("Wrote Private/secret.txt")),
            .string("<redacted-tool-output>")
        )

        let nested = NestedContractTool.descriptor.redaction.redact(arguments: .object([
            "entries": .array([
                .object(["id": .string("a"), "secret": .string("one")]),
                .object(["id": .string("b"), "secret": .string("two")]),
            ]),
        ]))
        XCTAssertEqual(nested, .object([
            "entries": .array([
                .object(["id": .string("a"), "secret": .string("<redacted>")]),
                .object(["id": .string("b"), "secret": .string("<redacted>")]),
            ]),
        ]))
    }

    func testLegacyAdapterUsesCanonicalTypedScalarEncodingAndOmitsNull() throws {
        let registry = try SandboxToolCatalog.canonicalRegistry()
        let replace = try registry.legacyRequest(
            name: "replace_text",
            version: "1.0.0",
            arguments: .object([
                "path": .string("a.swift"),
                "old": .string("x"),
                "new": .string("y"),
                "replace_all": .bool(true),
            ])
        )
        XCTAssertEqual(replace.name, "replace_text")
        XCTAssertEqual(replace.arguments["replace_all"], "true")
        XCTAssertNotEqual(replace.arguments["replace_all"], "1")

        let tree = try registry.legacyRequest(
            name: "list_tree",
            arguments: .object([
                "max_depth": .number(.integer(4)),
                "max_items": .number(.integer(250)),
            ])
        )
        XCTAssertEqual(tree.arguments["max_depth"], "4")
        XCTAssertEqual(tree.arguments["max_items"], "250")

        let html = try registry.legacyRequest(
            name: "validate_html_file",
            arguments: .object(["path": .string("index.html"), "profile": .null])
        )
        XCTAssertNil(html.arguments["profile"])
    }

    func testCanonicalArgumentDigestUsesSortedJSONAndKnownSHA256() throws {
        let registry = try SandboxToolCatalog.canonicalRegistry()
        let summary = try registry.descriptor(named: "workspace_summary")
        XCTAssertEqual(
            try summary.canonicalArgumentDigest(for: .object([:])),
            "sha256:44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a"
        )

        let write = try registry.descriptor(named: "write_file")
        let first = try write.canonicalArgumentDigest(for: .object([
            "contents": .string("hello"),
            "path": .string("A.txt"),
        ]))
        let second = try write.canonicalArgumentDigest(for: .object([
            "path": .string("A.txt"),
            "contents": .string("hello"),
        ]))
        XCTAssertEqual(first, second)

        let paddingVectors: [(contentsCount: Int, digest: String)] = [
            (29, "84e422db920aa5a0ee9d4217bed040551079b7e43c08e65fd181fe9c80ad284c"),
            (30, "01ee029f4a91154680b53386a18c52c5bcc0f6ff4042752f76797dbe321cc001"),
            (37, "4d9be39cb00d9dd1b00b9ea8d7c2ae1874ef36cd60b5544ffc1fb074e9ead6dd"),
            (38, "9f4b1a1def058edcb33db734fb1bc20d7270b3d8faa6b1bb9881a98ef23965bb"),
            (39, "cd7c2c38c83158211e51b973b7695b7b739212b827708f6f83dca6a25c12cdb9"),
            (94, "e56a6acdeebc7b80e6700e93bcff69a1eb45154add73521b4ac2d0ec13e885d7"),
        ]
        for vector in paddingVectors {
            let arguments: JSONValue = .object([
                "contents": .string(String(repeating: "a", count: vector.contentsCount)),
                "path": .string("A"),
            ])
            XCTAssertEqual(
                try write.canonicalArgumentDigest(for: arguments),
                "sha256:" + vector.digest
            )
        }
    }

    func testNestedLegacyValuesUseDeterministicCanonicalJSON() throws {
        let registry = try ToolRegistry(tools: [.init(NestedContractTool.self)])
        let value: JSONValue = .object([
            "enabled": .bool(false),
            "count": .number(.integer(1)),
            "ratio": .null,
            "note": .null,
            "entries": .array([.object(["secret": .string("s"), "id": .string("a")])]),
            "options": .object([
                "labels": .array([.string("z"), .string("a")]),
                "retries": .number(.integer(1)),
            ]),
        ])
        let first = try registry.legacyRequest(name: "nested_contract", arguments: value)
        let second = try registry.legacyRequest(name: "nested_contract", arguments: value)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.arguments["entries"], #"[{"id":"a","secret":"s"}]"#)
        XCTAssertEqual(first.arguments["options"], #"{"labels":["z","a"],"retries":1}"#)
        XCTAssertNil(first.arguments["note"])
        XCTAssertNil(first.arguments["ratio"])
    }

    func testAvailabilityFiltersProviderDefinitionsByWorkspaceLocalityAndCapabilities() throws {
        let registry = try SandboxToolCatalog.canonicalRegistry()
        let allCapabilities = Set(ToolCapability.allCases)
        let available = ToolAvailabilityContext(
            locality: .onDevice,
            capabilities: allCapabilities,
            hasWorkspace: true
        )
        XCTAssertEqual(registry.providerDefinitions(availableIn: available).count, executorOperations.count)

        let withoutHTML = ToolAvailabilityContext(
            locality: .onDevice,
            capabilities: allCapabilities.subtracting([.htmlValidation]),
            hasWorkspace: true
        )
        XCTAssertFalse(registry.providerDefinitions(availableIn: withoutHTML).contains {
            $0.function.name == "validate_html_file"
        })

        let worker = ToolAvailabilityContext(
            locality: .worker,
            capabilities: allCapabilities,
            hasWorkspace: true
        )
        XCTAssertTrue(registry.providerDefinitions(availableIn: worker).isEmpty)

        let noWorkspace = ToolAvailabilityContext(
            locality: .onDevice,
            capabilities: allCapabilities,
            hasWorkspace: false
        )
        XCTAssertTrue(registry.providerDefinitions(availableIn: noWorkspace).isEmpty)
    }

    func testTargetsComeFromDescriptorAndDynamicCommandRequiresDedicatedParser() throws {
        let registry = try SandboxToolCatalog.canonicalRegistry()
        let move = try registry.descriptor(named: "move_path")
        XCTAssertEqual(
            try move.extractTargets(from: .object([
                "from": .string("Old/File.swift"),
                "to": .string("New/File.swift"),
            ])),
            [
                .init(value: "Old/File.swift", access: .source),
                .init(value: "New/File.swift", access: .destination),
            ]
        )

        let command = try registry.descriptor(named: "run_command")
        XCTAssertThrowsError(try command.extractTargets(from: .object(["command": .string("pwd")]))) { error in
            XCTAssertEqual(error as? ToolTargetExtractionError, .requiresLegacyCommandParser)
        }
    }

    func testDuplicateAliasAndVersionRisksAreRejected() throws {
        XCTAssertThrowsError(
            try ToolRegistry(tools: SandboxToolCatalog.all + [.init(ReadFileTool.self)])
        ) { error in
            XCTAssertEqual(error as? ToolRegistryError, .duplicateCanonicalName("read_file"))
        }

        XCTAssertThrowsError(
            try ToolRegistry(tools: [.init(ReadFileTool.self), .init(AliasCollisionTool.self)])
        ) { error in
            XCTAssertEqual(error as? ToolRegistryError, .aliasCollision("read_file"))
        }

        XCTAssertThrowsError(try ToolRegistry(tools: [.init(BadLegacyVersionTool.self)])) { error in
            XCTAssertEqual(
                error as? ToolRegistryError,
                .legacyMajorVersionMismatch(tool: "bad_legacy_version", descriptorMajor: 2, adapterMajor: 1)
            )
        }

        XCTAssertThrowsError(try ToolRegistry(tools: [.init(BadRedactionTool.self)])) { error in
            XCTAssertEqual(
                error as? ToolRegistryError,
                .invalidRedactionPath(tool: "bad_redaction", path: ["typo"])
            )
        }

        XCTAssertThrowsError(try ToolRegistry(tools: [.init(BadNegativeRedactionTool.self)])) { error in
            XCTAssertEqual(
                error as? ToolRegistryError,
                .invalidRedactionPath(
                    tool: "bad_negative_redaction",
                    path: ["entries", "-1", "secret"]
                )
            )
        }

        XCTAssertThrowsError(try ToolRegistry(tools: [.init(LooseStrictSchemaTool.self)])) { error in
            XCTAssertEqual(error as? ToolRegistryError, .invalidBounds(tool: "loose_strict_schema"))
        }

        XCTAssertThrowsError(try ToolRegistry(tools: [.init(OverlongNameTool.self)])) { error in
            XCTAssertEqual(
                error as? ToolRegistryError,
                .invalidName(String(repeating: "a", count: 65))
            )
        }

        XCTAssertThrowsError(try ToolRegistry(tools: [.init(OverlappingUnionTool.self)])) { error in
            XCTAssertEqual(error as? ToolRegistryError, .invalidBounds(tool: "overlapping_union"))
        }

        let registry = try SandboxToolCatalog.canonicalRegistry()
        XCTAssertThrowsError(try registry.resolve("read_file", version: "2.0.0")) { error in
            XCTAssertEqual(
                error as? ToolRegistryError,
                .unsupportedVersion(tool: "read_file", requested: "2.0.0", available: "1.0.0")
            )
        }
    }

    private func assertValidationCode(
        _ code: ToolValidationCode,
        file: StaticString = #filePath,
        line: UInt = #line,
        operation: () throws -> Void
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            guard let validation = error as? ToolArgumentValidationError else {
                return XCTFail("Expected ToolArgumentValidationError, got \(error)", file: file, line: line)
            }
            XCTAssertTrue(
                validation.issues.contains { $0.code == code },
                "Expected \(code), got \(validation.issues)",
                file: file,
                line: line
            )
        }
    }

    private func providerProperties(from value: JSONValue) throws -> [String: JSONValue] {
        guard case let .object(root) = value,
              case let .object(properties)? = root["properties"] else {
            throw TestFailure.invalidProviderSchema
        }
        return properties
    }

    private func providerTypes(from value: JSONValue) -> [String] {
        guard case let .object(object) = value else { return [] }
        if case let .string(type)? = object["type"] { return [type] }
        guard case let .array(schemas)? = object["anyOf"] else { return [] }
        return schemas.compactMap { schema in
            guard case let .object(object) = schema,
                  case let .string(type)? = object["type"] else { return nil }
            return type
        }
    }

    private func providerRequired(from value: JSONValue) -> [String] {
        guard case let .object(object) = value,
              case let .array(values)? = object["required"] else { return [] }
        return values.compactMap {
            guard case let .string(value) = $0 else { return nil }
            return value
        }
    }

    private enum TestFailure: Error {
        case invalidProviderSchema
    }
}

private struct NestedContractArguments: AgentToolArguments {
    struct Entry: Codable, Equatable, Sendable {
        let id: String
        let secret: String
    }

    struct Options: Codable, Equatable, Sendable {
        let retries: Int
        let labels: [String]
    }

    let enabled: Bool
    let count: Int
    let ratio: Double?
    let note: String?
    let entries: [Entry]
    let options: Options

    static let jsonSchema: JSONSchema = .object(
        properties: [
            "enabled": .boolean(),
            "count": .integer(minimum: 0, maximum: 10),
            "ratio": .nullable(.number(minimum: 0, maximum: 1)),
            "note": .nullable(.string(maxLength: 100)),
            "entries": .array(
                items: .object(
                    properties: [
                        "id": .string(minLength: 1, maxLength: 50),
                        "secret": .string(minLength: 1, maxLength: 200),
                    ],
                    required: ["id", "secret"],
                    additionalProperties: false
                ),
                minItems: 1,
                maxItems: 5
            ),
            "options": .object(
                properties: [
                    "retries": .integer(minimum: 0, maximum: 3),
                    "labels": .array(items: .string(maxLength: 40), maxItems: 5),
                ],
                required: ["retries", "labels"],
                additionalProperties: false
            ),
        ],
        required: ["enabled", "count", "entries", "options"],
        additionalProperties: false
    )
}

private enum NestedContractTool: AgentTool {
    typealias Arguments = NestedContractArguments
    static let metadata = contractMetadata(
        name: "nested_contract",
        version: .init(major: 1, minor: 0, patch: 0),
        redaction: .init(
            argumentRules: [.init(path: ["entries", "*", "secret"])],
            output: .none
        ),
        legacyMajorVersion: 1,
        aliases: ["nested_alias"]
    )
}

private enum AliasCollisionTool: AgentTool {
    typealias Arguments = PathArguments
    static var metadata: ToolDescriptorMetadata {
        let base = contractMetadata(
            name: "alias_collision",
            version: .init(major: 1, minor: 0, patch: 0),
            redaction: .init(argumentRules: [], output: .none),
            legacyMajorVersion: nil
        )
        return ToolDescriptorMetadata(
            name: base.name,
            version: base.version,
            aliases: ["read_file"],
            toolset: base.toolset,
            description: base.description,
            availability: base.availability,
            effectClass: base.effectClass,
            approvalClass: base.approvalClass,
            targetStrategy: base.targetStrategy,
            parallelSafety: base.parallelSafety,
            concurrencyKey: base.concurrencyKey,
            limits: base.limits,
            redaction: base.redaction,
            legacyAdapter: base.legacyAdapter,
            receipt: base.receipt,
            evidence: base.evidence,
            ui: base.ui
        )
    }
}

private enum BadLegacyVersionTool: AgentTool {
    typealias Arguments = PathArguments
    static let metadata = contractMetadata(
        name: "bad_legacy_version",
        version: .init(major: 2, minor: 0, patch: 0),
        redaction: .init(argumentRules: [], output: .none),
        legacyMajorVersion: 1
    )
}

private enum BadRedactionTool: AgentTool {
    typealias Arguments = PathArguments
    static let metadata = contractMetadata(
        name: "bad_redaction",
        version: .init(major: 1, minor: 0, patch: 0),
        redaction: .init(
            argumentRules: [.init(path: ["typo"])],
            output: .none
        ),
        legacyMajorVersion: nil
    )
}

private enum BadNegativeRedactionTool: AgentTool {
    typealias Arguments = NestedContractArguments
    static let metadata = contractMetadata(
        name: "bad_negative_redaction",
        version: .init(major: 1, minor: 0, patch: 0),
        redaction: .init(
            argumentRules: [.init(path: ["entries", "-1", "secret"])],
            output: .none
        ),
        legacyMajorVersion: nil
    )
}

private struct LooseStrictSchemaArguments: AgentToolArguments {
    let path: String

    static let jsonSchema: JSONSchema = .object(
        properties: ["path": .string(minLength: 1)],
        required: ["path"],
        additionalProperties: true
    )
}

private enum LooseStrictSchemaTool: AgentTool {
    typealias Arguments = LooseStrictSchemaArguments
    static let metadata = contractMetadata(
        name: "loose_strict_schema",
        version: .init(major: 1, minor: 0, patch: 0),
        redaction: .init(argumentRules: [], output: .none),
        legacyMajorVersion: nil
    )
}

private enum OverlongNameTool: AgentTool {
    typealias Arguments = PathArguments
    static let metadata = contractMetadata(
        name: String(repeating: "a", count: 65),
        version: .init(major: 1, minor: 0, patch: 0),
        redaction: .init(argumentRules: [], output: .none),
        legacyMajorVersion: nil
    )
}

private struct OverlappingUnionArguments: AgentToolArguments {
    let value: JSONValue

    static let jsonSchema: JSONSchema = .object(
        properties: [
            "value": .oneOf(schemas: [.integer(), .number()]),
        ],
        required: ["value"],
        additionalProperties: false
    )
}

private enum OverlappingUnionTool: AgentTool {
    typealias Arguments = OverlappingUnionArguments
    static let metadata = contractMetadata(
        name: "overlapping_union",
        version: .init(major: 1, minor: 0, patch: 0),
        redaction: .init(argumentRules: [], output: .none),
        legacyMajorVersion: nil
    )
}

private func contractMetadata(
    name: String,
    version: ToolVersion,
    redaction: ToolRedactionPolicy,
    legacyMajorVersion: Int?,
    aliases: [String] = []
) -> ToolDescriptorMetadata {
    ToolDescriptorMetadata(
        name: name,
        version: version,
        aliases: aliases,
        toolset: "contract-test",
        description: "Contract test tool.",
        availability: .init(
            allowedLocalities: [.either],
            requiredCapabilities: [],
            requiresWorkspace: false
        ),
        effectClass: .readOnlyLocal,
        approvalClass: .none,
        targetStrategy: .workspaceRoot(access: .inspect),
        parallelSafety: .parallelRead,
        concurrencyKey: nil,
        limits: .init(
            timeoutMilliseconds: 1_000,
            maximumArgumentBytes: 100_000,
            maximumOutputBytes: 100_000
        ),
        redaction: redaction,
        legacyAdapter: legacyMajorVersion.map {
            .init(executorName: name, supportedMajorVersion: $0)
        },
        receipt: .init(actionVerb: "Tested", successSummary: "Contract tested"),
        evidence: .none,
        ui: .init(
            title: "Contract Test",
            systemImageName: "checkmark",
            category: .inspect,
            resultPresentation: .text
        )
    )
}
