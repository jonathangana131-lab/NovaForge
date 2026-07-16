import AgentDomain
import AgentProviders
import AgentTools
import Foundation

/// App-private HTTP boundary for the developer hosted canaries.
///
/// The package owns route authority and request encoding. This transport owns
/// the credential and the one permitted origin. It deliberately has no base URL
/// setting. Each instance is permanently bound to text-only, read-only canary,
/// or production canonical-tool authority; text-only still rejects every
/// tool-bearing envelope, while tool modes compare the entire definition list
/// to the frozen app registry. Its transport contract is intentionally
/// stricter than the generic package gateway: scopes use
/// `${requestID}:provider-attempt:<canonical UInt>`, Responses continuation is
/// disabled, and hosted models must be the selected alias or its date-versioned
/// snapshot.
final class AgentHostedProviderTransport: ProviderTransport, @unchecked Sendable {
    struct Limits: Equatable, Sendable {
        let maximumRequestBodyBytes: Int
        let maximumRequestJSONDepth: Int
        let maximumRequestJSONNodes: Int
        let maximumHTTPErrorBodyBytes: Int
        let maximumSSELineBytes: Int
        let maximumSSEEventBytes: Int
        let maximumFrameCount: Int
        let maximumStreamBytes: Int
        let maximumBufferedWireFrames: Int

        static let production = Limits(
            maximumRequestBodyBytes: 2 * 1_024 * 1_024,
            maximumRequestJSONDepth: 64,
            maximumRequestJSONNodes: 100_000,
            maximumHTTPErrorBodyBytes: 64 * 1_024,
            maximumSSELineBytes: 512 * 1_024,
            maximumSSEEventBytes: 1 * 1_024 * 1_024,
            maximumFrameCount: 50_000,
            maximumStreamBytes: 16 * 1_024 * 1_024,
            maximumBufferedWireFrames: 256
        )

        init(
            maximumRequestBodyBytes: Int,
            maximumRequestJSONDepth: Int,
            maximumRequestJSONNodes: Int,
            maximumHTTPErrorBodyBytes: Int,
            maximumSSELineBytes: Int,
            maximumSSEEventBytes: Int,
            maximumFrameCount: Int,
            maximumStreamBytes: Int,
            maximumBufferedWireFrames: Int
        ) {
            precondition(maximumRequestBodyBytes > 0)
            precondition(maximumRequestJSONDepth > 0)
            precondition(maximumRequestJSONNodes > 0)
            precondition(maximumHTTPErrorBodyBytes > 0)
            precondition(maximumSSELineBytes > 0)
            precondition(maximumSSEEventBytes > 0)
            precondition(maximumFrameCount > 0)
            precondition(maximumStreamBytes > 0)
            precondition(maximumBufferedWireFrames > 0)
            self.maximumRequestBodyBytes = maximumRequestBodyBytes
            self.maximumRequestJSONDepth = maximumRequestJSONDepth
            self.maximumRequestJSONNodes = maximumRequestJSONNodes
            self.maximumHTTPErrorBodyBytes = maximumHTTPErrorBodyBytes
            self.maximumSSELineBytes = maximumSSELineBytes
            self.maximumSSEEventBytes = maximumSSEEventBytes
            self.maximumFrameCount = maximumFrameCount
            self.maximumStreamBytes = maximumStreamBytes
            self.maximumBufferedWireFrames = maximumBufferedWireFrames
        }
    }

    private let credential: String
    private enum Authority: Sendable {
        case textOnly(HostedTextOnlyProviderCapability)
        case readOnlyTools(HostedReadOnlyToolsProviderCapability)
        case singleCallTools(HostedSingleCallToolsProviderCapability)
    }

    private let authority: Authority
    private let session: URLSession
    private let limits: Limits
    private let producerDidTerminate: (@Sendable () -> Void)?
    private let httpErrorBodyDidConsume: (@Sendable (Int) -> Void)?
    private let attempts = HostedProviderAttemptRegistry()

    init(
        credential: String,
        capability: HostedTextOnlyProviderCapability,
        session: URLSession? = nil,
        limits: Limits = .production,
        producerDidTerminate: (@Sendable () -> Void)? = nil,
        httpErrorBodyDidConsume: (@Sendable (Int) -> Void)? = nil
    ) {
        self.credential = credential
        authority = .textOnly(capability)
        self.session = session ?? Self.makeSession()
        self.limits = limits
        self.producerDidTerminate = producerDidTerminate
        self.httpErrorBodyDidConsume = httpErrorBodyDidConsume
    }

    /// A distinct initializer prevents text-only authority from being widened
    /// by a Boolean or caller-created route description.
    init(
        credential: String,
        readOnlyToolsCapability: HostedReadOnlyToolsProviderCapability,
        session: URLSession? = nil,
        limits: Limits = .production,
        producerDidTerminate: (@Sendable () -> Void)? = nil,
        httpErrorBodyDidConsume: (@Sendable (Int) -> Void)? = nil
    ) {
        self.credential = credential
        authority = .readOnlyTools(readOnlyToolsCapability)
        self.session = session ?? Self.makeSession()
        self.limits = limits
        self.producerDidTerminate = producerDidTerminate
        self.httpErrorBodyDidConsume = httpErrorBodyDidConsume
    }

    /// Production hosted authority for the exact 20-tool canonical registry.
    /// The package capability authorizes only the provider wire shape; this
    /// transport freezes every definition and `AgentEngine` still sends every
    /// mutation through its policy executor.
    init(
        credential: String,
        singleCallToolsCapability: HostedSingleCallToolsProviderCapability,
        session: URLSession? = nil,
        limits: Limits = .production,
        producerDidTerminate: (@Sendable () -> Void)? = nil,
        httpErrorBodyDidConsume: (@Sendable (Int) -> Void)? = nil
    ) {
        self.credential = credential
        authority = .singleCallTools(singleCallToolsCapability)
        self.session = session ?? Self.makeSession()
        self.limits = limits
        self.producerDidTerminate = producerDidTerminate
        self.httpErrorBodyDidConsume = httpErrorBodyDidConsume
    }

    func stream(
        request: ProviderEncodedRequest,
        descriptor: ProviderAdapterDescriptor,
        scope: ProviderAttemptScope
    ) async throws -> AsyncThrowingStream<ProviderWireFrame, any Error> {
        try Task.checkCancellation()
        try Self.validateCredential(credential, descriptor: descriptor)
        try Self.validateDescriptor(descriptor, against: authority)
        try Self.validateScope(scope)
        try Self.validateRequestStructure(request.body, limits: limits)
        try Self.validateEnvelope(
            request,
            descriptor: descriptor,
            credential: credential,
            authority: authority
        )

        let body: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            body = try encoder.encode(request.body)
        } catch {
            throw AgentHostedProviderTransportError.invalidRequestEnvelope
        }
        guard body.count <= limits.maximumRequestBodyBytes else {
            throw AgentHostedProviderTransportError.requestBodyTooLarge
        }
        guard credential.isEmpty ||
                body.range(of: Data(credential.utf8)) == nil else {
            throw AgentHostedProviderTransportError.credentialPresentInRequestBody
        }

        let urlRequest = try Self.makeURLRequest(
            path: request.relativePath,
            body: body,
            credential: credential,
            authority: authority
        )
        try await attempts.reserve(scope)
        // A cancelled caller must not start HTTP after waiting for the
        // process-local reservation actor. The durable barrier has already
        // consumed this scope, so retaining the reservation is intentional.
        try Task.checkCancellation()
        let session = session
        let limits = limits
        let providerID = descriptor.route.providerID
        let adapterID = descriptor.route.adapterID
        let dialect = descriptor.dialect
        let expectedModelID = descriptor.route.modelID
        let responseCredential = credential
        let producerDidTerminate = producerDidTerminate
        let httpErrorBodyDidConsume = httpErrorBodyDidConsume

        return AsyncThrowingStream(
            bufferingPolicy: .bufferingOldest(limits.maximumBufferedWireFrames)
        ) { continuation in
            let producer = Task { @Sendable in
                defer { producerDidTerminate?() }
                do {
                    try Task.checkCancellation()
                    let (bytes, response) = try await session.bytes(
                        for: urlRequest,
                        delegate: HostedProviderNoRedirectDelegate.shared
                    )
                    guard let http = response as? HTTPURLResponse else {
                        throw AgentHostedProviderTransportError.invalidHTTPResponse
                    }
                    guard http.url == urlRequest.url else {
                        throw AgentHostedProviderTransportError.redirectedResponse
                    }
                    guard !(300 ..< 400).contains(http.statusCode) else {
                        throw AgentHostedProviderTransportError.redirectedResponse
                    }

                    guard (200 ..< 300).contains(http.statusCode) else {
                        var consumed = 0
                        for try await _ in bytes {
                            try Task.checkCancellation()
                            consumed += 1
                            if consumed >= limits.maximumHTTPErrorBodyBytes { break }
                        }
                        httpErrorBodyDidConsume?(consumed)
                        throw HostedProviderTrustedFailure(
                            failure: ProviderFailureMapper.httpFailure(
                                statusCode: http.statusCode,
                                providerID: providerID,
                                adapterID: adapterID
                            )
                        )
                    }

                    guard Self.isEventStreamContentType(
                        http.value(forHTTPHeaderField: "Content-Type")
                    ) else {
                        throw AgentHostedProviderTransportError.invalidContentType
                    }

                    var parser = HostedProviderSSEParser(limits: limits)
                    var identityValidator = HostedProviderWireIdentityValidator(
                        dialect: dialect,
                        expectedModelID: expectedModelID
                    )
                    var credentialGuard = HostedProviderCredentialEchoGuard(
                        credential: responseCredential,
                        maximumDepth: limits.maximumRequestJSONDepth,
                        maximumNodesPerFrame: limits.maximumRequestJSONNodes,
                        maximumTrackedTextChannels: limits.maximumFrameCount
                    )
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        let frames = try parser.consume(byte)
                        for frame in frames {
                            try credentialGuard.validate(frame, dialect: dialect)
                            try Self.validateSentinel(frame, dialect: dialect)
                            try identityValidator.validate(frame)
                            try Self.yield(frame, to: continuation)
                        }
                    }

                    for frame in try parser.finish() {
                        try credentialGuard.validate(frame, dialect: dialect)
                        try Self.validateSentinel(frame, dialect: dialect)
                        try identityValidator.validate(frame)
                        try Self.yield(frame, to: continuation)
                    }
                    if dialect == .openAIChatCompletions, !parser.didReceiveDone {
                        throw AgentHostedProviderTransportError.chatStreamEndedWithoutDone
                    }
                    // Both dialects drain through transport EOF. Trusted Chat
                    // additionally requires `[DONE]`; Responses completion is
                    // owned by ProviderStreamSession and needs no sentinel.
                    continuation.finish()
                } catch {
                    let sanitized = Self.sanitized(
                        error,
                        providerID: providerID,
                        adapterID: adapterID
                    )
                    continuation.finish(throwing: sanitized)
                    return
                }
            }
            continuation.onTermination = { @Sendable _ in
                producer.cancel()
            }
        }
    }

    private static func yield(
        _ frame: sending ProviderWireFrame,
        to continuation: AsyncThrowingStream<ProviderWireFrame, any Error>.Continuation
    ) throws {
        switch continuation.yield(frame) {
        case .enqueued:
            return
        case .dropped:
            throw AgentHostedProviderTransportError.consumerBackpressureExceeded
        case .terminated:
            throw CancellationError()
        @unknown default:
            throw AgentHostedProviderTransportError.consumerBackpressureExceeded
        }
    }

    private static func validateSentinel(
        _ frame: ProviderWireFrame,
        dialect: ProviderAdapterDialect
    ) throws {
        if dialect == .openAIResponses, frame == .done {
            throw AgentHostedProviderTransportError.malformedSSE
        }
    }

    private static func isEventStreamContentType(_ rawValue: String?) -> Bool {
        guard let rawValue else { return false }
        guard let firstComponent = rawValue.split(
            separator: ";",
            maxSplits: 1,
            omittingEmptySubsequences: false
        ).first else { return false }
        let mediaType = String(firstComponent)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return mediaType == "text/event-stream"
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 180
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
    }

    private static func validateCredential(
        _ credential: String,
        descriptor: ProviderAdapterDescriptor
    ) throws {
        if credential.isEmpty,
           descriptor.route.provenance == .builtInOpenCodeZenChatCompletions,
           !AIProvider.openCodeZen.requiresCredential(
            for: descriptor.route.modelID.rawValue
           ) {
            return
        }
        guard (1 ... 4_096).contains(credential.utf8.count),
              credential.unicodeScalars.allSatisfy({ (0x21 ... 0x7e).contains($0.value) })
        else {
            throw AgentHostedProviderTransportError.invalidCredential
        }
    }

    private static func validateDescriptor(
        _ descriptor: ProviderAdapterDescriptor,
        against authority: Authority
    ) throws {
        switch authority {
        case let .textOnly(capability):
            try validateTextOnlyDescriptor(
                descriptor,
                against: capability.snapshot
            )
        case let .readOnlyTools(capability):
            try validateReadOnlyToolsDescriptor(
                descriptor,
                against: capability.snapshot
            )
        case let .singleCallTools(capability):
            try validateSingleCallToolsDescriptor(
                descriptor,
                against: capability.snapshot
            )
        }
    }

    private static func validateTextOnlyDescriptor(
        _ descriptor: ProviderAdapterDescriptor,
        against snapshot: HostedTextOnlyRouteSnapshot
    ) throws {
        let route = descriptor.route
        guard snapshot.toolDispatchDisabled,
              snapshot.providerID.rawValue == "openai",
              isSafeIdentity(snapshot.modelID.rawValue, maximumUTF8Count: 256),
              isSafeIdentity(snapshot.adapterID.rawValue, maximumUTF8Count: 128),
              snapshot.deployment == .hostedService,
              route.providerID == snapshot.providerID,
              route.modelID == snapshot.modelID,
              route.adapterID == snapshot.adapterID,
              route.capabilities == snapshot.capabilities,
              route.deployment == snapshot.deployment,
              route.provenance == snapshot.provenance,
              descriptor.dialect == snapshot.dialect,
              descriptor.requestPath == snapshot.requestPath
        else {
            throw AgentHostedProviderTransportError.untrustedDescriptor
        }

        let isTrustedChat = descriptor.dialect == .openAIChatCompletions &&
            descriptor.requestPath == "/v1/chat/completions" &&
            route.adapterID.rawValue == "openai-chat-completions" &&
            route.provenance == .builtInOpenAIChatCompletions
        let isTrustedResponses = descriptor.dialect == .openAIResponses &&
            descriptor.requestPath == "/v1/responses" &&
            route.adapterID.rawValue == "openai-responses" &&
            route.provenance == .builtInOpenAIResponses
        guard isTrustedChat || isTrustedResponses else {
            throw AgentHostedProviderTransportError.untrustedDescriptor
        }
    }

    private static func validateReadOnlyToolsDescriptor(
        _ descriptor: ProviderAdapterDescriptor,
        against snapshot: HostedReadOnlyToolsRouteSnapshot
    ) throws {
        let route = descriptor.route
        guard isSafeIdentity(snapshot.providerID.rawValue, maximumUTF8Count: 128),
              isSafeIdentity(snapshot.modelID.rawValue, maximumUTF8Count: 256),
              isSafeIdentity(snapshot.adapterID.rawValue, maximumUTF8Count: 128),
              snapshot.deployment == .hostedService,
              snapshot.maximumToolDefinitions == 12,
              snapshot.maximumToolCallsPerTurn == 1,
              !snapshot.parallelToolDispatchEnabled,
              route.providerID == snapshot.providerID,
              route.modelID == snapshot.modelID,
              route.adapterID == snapshot.adapterID,
              route.capabilities == snapshot.capabilities,
              route.deployment == snapshot.deployment,
              route.provenance == snapshot.provenance,
              descriptor.dialect == snapshot.dialect,
              descriptor.requestPath == snapshot.requestPath,
              route.capabilities.features.contains(.tools),
              route.capabilities.features.contains(.typedToolArguments),
              route.capabilities.features.contains(.strictToolSchema),
              !route.capabilities.features.contains(.parallelToolCalls)
        else {
            throw AgentHostedProviderTransportError.untrustedDescriptor
        }

        let isTrustedChat = descriptor.dialect == .openAIChatCompletions &&
            descriptor.requestPath == "/v1/chat/completions" &&
            route.adapterID.rawValue == "openai-chat-completions" &&
            route.provenance == .builtInOpenAIChatCompletions
        // The live M5 read-tools lane intentionally exposes Chat Completions
        // only. Responses remains package-tested but has no app transport
        // authority until its continuation/recovery contract is integrated.
        guard isTrustedChat else {
            throw AgentHostedProviderTransportError.untrustedDescriptor
        }
    }

    private static func validateSingleCallToolsDescriptor(
        _ descriptor: ProviderAdapterDescriptor,
        against snapshot: HostedSingleCallToolsRouteSnapshot
    ) throws {
        let route = descriptor.route
        guard isSafeIdentity(snapshot.providerID.rawValue, maximumUTF8Count: 128),
              isSafeIdentity(snapshot.modelID.rawValue, maximumUTF8Count: 256),
              isSafeIdentity(snapshot.adapterID.rawValue, maximumUTF8Count: 128),
              snapshot.deployment == .hostedService,
              snapshot.maximumToolDefinitions == 20,
              snapshot.maximumToolCallsPerTurn == 1,
              !snapshot.parallelToolDispatchEnabled,
              route.providerID == snapshot.providerID,
              route.modelID == snapshot.modelID,
              route.adapterID == snapshot.adapterID,
              route.capabilities == snapshot.capabilities,
              route.deployment == snapshot.deployment,
              route.provenance == snapshot.provenance,
              descriptor.dialect == snapshot.dialect,
              descriptor.requestPath == snapshot.requestPath,
              route.capabilities.features.contains(.tools),
              route.capabilities.features.contains(.typedToolArguments),
              route.capabilities.features.contains(.strictToolSchema),
              !route.capabilities.features.contains(.parallelToolCalls)
        else {
            throw AgentHostedProviderTransportError.untrustedDescriptor
        }

        // Responses continuation/recovery is intentionally still closed. The
        // production composition may use only the package-owned Chat route.
        let isOpenAI = route.providerID.rawValue == "openai" &&
            descriptor.dialect == .openAIChatCompletions &&
            descriptor.requestPath == "/v1/chat/completions" &&
            route.adapterID.rawValue == "openai-chat-completions" &&
            route.provenance == .builtInOpenAIChatCompletions
        let isOpenCodeZen = route.providerID.rawValue == "opencode-zen" &&
            descriptor.dialect == .openAIChatCompletions &&
            descriptor.requestPath == "/zen/v1/chat/completions" &&
            route.adapterID.rawValue == "opencode-zen-chat-completions" &&
            route.provenance == .builtInOpenCodeZenChatCompletions
        let isOpenAICodex = route.providerID.rawValue == "openai-codex" &&
            descriptor.dialect == .openAIResponses &&
            descriptor.requestPath == "/codex/responses" &&
            route.adapterID.rawValue == "openai-codex-responses" &&
            route.provenance == .builtInOpenAICodexResponses
        guard isOpenAI || isOpenCodeZen || isOpenAICodex else {
            throw AgentHostedProviderTransportError.untrustedDescriptor
        }
    }

    private static func validateScope(_ scope: ProviderAttemptScope) throws {
        let requestID = scope.requestID
        let attemptID = scope.attemptID.rawValue
        guard isSafeIdentity(requestID, maximumUTF8Count: 512),
              isSafeIdentity(attemptID, maximumUTF8Count: 512)
        else {
            throw AgentHostedProviderTransportError.invalidAttemptScope
        }

        let prefix = requestID + ":provider-attempt:"
        guard attemptID.hasPrefix(prefix) else {
            throw AgentHostedProviderTransportError.invalidAttemptScope
        }
        let suffix = String(attemptID.dropFirst(prefix.count))
        guard let number = UInt64(suffix), number > 0, String(number) == suffix else {
            throw AgentHostedProviderTransportError.invalidAttemptScope
        }
    }

    private static func isSafeIdentity(_ value: String, maximumUTF8Count: Int) -> Bool {
        guard !value.isEmpty, value.utf8.count <= maximumUTF8Count,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar) &&
                !CharacterSet.controlCharacters.contains(scalar) &&
                scalar.properties.generalCategory != .format
        }
    }

    /// Bounds hostile caller-created JSON before any recursive credential or
    /// tool-material scan. The encoded byte limit remains authoritative after
    /// serialization; this iterative meter protects depth, nodes, and the
    /// amount of string/key material visited while reaching that check.
    private static func validateRequestStructure(
        _ root: JSONValue,
        limits: Limits
    ) throws {
        struct PendingValue {
            let value: JSONValue
            let depth: Int
        }

        var pending = [PendingValue(value: root, depth: 1)]
        var visitedNodes = 0
        var measuredStringBytes = 0

        while let current = pending.popLast() {
            visitedNodes += 1
            guard visitedNodes <= limits.maximumRequestJSONNodes,
                  current.depth <= limits.maximumRequestJSONDepth
            else {
                throw AgentHostedProviderTransportError.requestStructureTooComplex
            }

            switch current.value {
            case let .string(value):
                try addRequestBytes(
                    value.utf8.count,
                    to: &measuredStringBytes,
                    limit: limits.maximumRequestBodyBytes
                )
            case let .array(values):
                guard values.count <= limits.maximumRequestJSONNodes - visitedNodes - pending.count,
                      values.isEmpty || current.depth < limits.maximumRequestJSONDepth
                else {
                    throw AgentHostedProviderTransportError.requestStructureTooComplex
                }
                pending.reserveCapacity(pending.count + values.count)
                for value in values {
                    pending.append(.init(value: value, depth: current.depth + 1))
                }
            case let .object(object):
                guard object.count <= limits.maximumRequestJSONNodes - visitedNodes - pending.count,
                      object.isEmpty || current.depth < limits.maximumRequestJSONDepth
                else {
                    throw AgentHostedProviderTransportError.requestStructureTooComplex
                }
                pending.reserveCapacity(pending.count + object.count)
                for (key, value) in object {
                    try addRequestBytes(
                        key.utf8.count,
                        to: &measuredStringBytes,
                        limit: limits.maximumRequestBodyBytes
                    )
                    pending.append(.init(value: value, depth: current.depth + 1))
                }
            case .null, .bool, .number:
                break
            }
        }
    }

    private static func addRequestBytes(
        _ count: Int,
        to total: inout Int,
        limit: Int
    ) throws {
        let addition = total.addingReportingOverflow(count)
        guard !addition.overflow, addition.partialValue <= limit else {
            throw AgentHostedProviderTransportError.requestBodyTooLarge
        }
        total = addition.partialValue
    }

    private static func validateEnvelope(
        _ request: ProviderEncodedRequest,
        descriptor: ProviderAdapterDescriptor,
        credential: String,
        authority: Authority
    ) throws {
        guard request.method == .post,
              request.relativePath == descriptor.requestPath,
              case let .object(body) = request.body,
              body["model"] == .string(descriptor.route.modelID.rawValue),
              body["stream"] == .bool(true)
        else {
            throw AgentHostedProviderTransportError.invalidRequestEnvelope
        }

        switch authority {
        case .textOnly:
            switch descriptor.dialect {
            case .openAIChatCompletions:
                try validateChatTextOnlyEnvelope(body, descriptor: descriptor)
            case .openAIResponses:
                try validateResponsesTextOnlyEnvelope(body, descriptor: descriptor)
            case .openAICompatibleChat:
                throw AgentHostedProviderTransportError.untrustedDescriptor
            }
            guard !containsToolDispatchMaterial(request.body) else {
                throw AgentHostedProviderTransportError.toolDispatchNotAllowed
            }
        case .readOnlyTools:
            guard descriptor.dialect == .openAIChatCompletions else {
                throw AgentHostedProviderTransportError.untrustedDescriptor
            }
            try validateChatReadOnlyToolsEnvelope(
                body,
                descriptor: descriptor
            )
        case .singleCallTools:
            switch descriptor.dialect {
            case .openAIChatCompletions:
                try validateChatSingleCallToolsEnvelope(
                    body,
                    descriptor: descriptor
                )
            case .openAIResponses:
                try validateResponsesSingleCallToolsEnvelope(
                    body,
                    descriptor: descriptor
                )
            case .openAICompatibleChat:
                throw AgentHostedProviderTransportError.untrustedDescriptor
            }
        }
        guard credential.isEmpty ||
                !containsCredential(credential, in: request.body) else {
            throw AgentHostedProviderTransportError.credentialPresentInRequestBody
        }
    }

    private static let canonicalReadOnlyToolNames: Set<String> = [
        "list_directory",
        "list_tree",
        "workspace_summary",
        "file_info",
        "read_file",
        "read_file_range",
        "tail_file",
        "search_text",
        "diff_files",
        "validate_json",
        "validate_html_file",
        "extract_outline",
    ]

    private static let canonicalReadOnlyToolDefinitions: [JSONValue] =
        SandboxToolCatalog.all.map(\.descriptor).filter {
            $0.effectClass == .readOnlyLocal
        }.map { descriptor in
            let definition = AgentTools.ProviderToolDefinition(
                descriptor: descriptor
            )
            return .object([
                "type": .string(definition.type),
                "function": .object([
                    "name": .string(definition.function.name),
                    "description": .string(
                        definition.function.description
                    ),
                    "parameters": definition.function.parameters,
                    "strict": .bool(definition.function.strict),
                ]),
            ])
        }

    private static let canonicalSingleCallToolNames: Set<String> = Set(
        SandboxToolCatalog.all.map(\.descriptor.name)
    )

    private static let canonicalSingleCallToolDefinitions: [JSONValue] =
        SandboxToolCatalog.all.map(\.descriptor).map { descriptor in
            let definition = AgentTools.ProviderToolDefinition(
                descriptor: descriptor
            )
            return .object([
                "type": .string(definition.type),
                "function": .object([
                    "name": .string(definition.function.name),
                    "description": .string(
                        definition.function.description
                    ),
                    "parameters": definition.function.parameters,
                    "strict": .bool(definition.function.strict),
                ]),
            ])
        }

    private static let canonicalResponsesSingleCallToolDefinitions: [JSONValue] =
        SandboxToolCatalog.all.map(\.descriptor).map { descriptor in
            let definition = AgentTools.ProviderToolDefinition(
                descriptor: descriptor
            )
            return .object([
                "type": .string(definition.type),
                "name": .string(definition.function.name),
                "description": .string(definition.function.description),
                "parameters": definition.function.parameters,
                "strict": .bool(definition.function.strict),
            ])
        }

    private static func validateChatReadOnlyToolsEnvelope(
        _ body: [String: JSONValue],
        descriptor: ProviderAdapterDescriptor
    ) throws {
        try validateChatToolsEnvelope(
            body,
            descriptor: descriptor,
            canonicalToolNames: canonicalReadOnlyToolNames,
            canonicalToolDefinitions: canonicalReadOnlyToolDefinitions
        )
    }

    private static func validateChatSingleCallToolsEnvelope(
        _ body: [String: JSONValue],
        descriptor: ProviderAdapterDescriptor
    ) throws {
        try validateChatToolsEnvelope(
            body,
            descriptor: descriptor,
            canonicalToolNames: canonicalSingleCallToolNames,
            canonicalToolDefinitions: canonicalSingleCallToolDefinitions
        )
    }

    private static func validateChatToolsEnvelope(
        _ body: [String: JSONValue],
        descriptor: ProviderAdapterDescriptor,
        canonicalToolNames: Set<String>,
        canonicalToolDefinitions: [JSONValue]
    ) throws {
        let maximumOutputKey = descriptor.route.provenance ==
            .builtInOpenCodeZenChatCompletions
            ? "max_tokens"
            : "max_completion_tokens"
        let allowedKeys: Set<String> = [
            maximumOutputKey, "messages", "metadata", "model",
            "parallel_tool_calls", "prompt_cache_key", "stream",
            "stream_options", "temperature", "tool_choice", "tools",
        ]
        guard body.keys.allSatisfy(allowedKeys.contains),
              body["stream_options"] == .object(["include_usage": .bool(true)]),
              body["parallel_tool_calls"] == .bool(false),
              body["tool_choice"] == .string("auto"),
              case .object? = body["metadata"],
              case let .array(messages)? = body["messages"],
              !messages.isEmpty,
              case let .array(tools)? = body["tools"],
              tools.count == canonicalToolNames.count,
              tools.count == Int(descriptor.route.capabilities.maximumToolDefinitions),
              tools == canonicalToolDefinitions
        else {
            throw AgentHostedProviderTransportError.invalidRequestEnvelope
        }
        try validateGenerationOptions(
            body,
            maximumOutputKey: maximumOutputKey,
            maximumOutputTokens: descriptor.route.capabilities.maximumOutputTokens
        )

        var pendingProviderCallID: String?
        var completedProviderCallIDs: Set<String> = []
        for value in messages {
            guard case let .object(message) = value,
                  case let .string(role)? = message["role"] else {
                throw AgentHostedProviderTransportError.invalidRequestEnvelope
            }
            switch role {
            case "assistant" where message["tool_calls"] != nil:
                guard pendingProviderCallID == nil,
                      Set(message.keys) == Set(["content", "role", "tool_calls"]),
                      message["content"] == .null,
                      case let .array(calls)? = message["tool_calls"],
                      calls.count == 1,
                      case let .object(call) = calls[0],
                      Set(call.keys) == Set(["function", "id", "type"]),
                      call["type"] == .string("function"),
                      case let .string(callID)? = call["id"],
                      isSafeIdentity(callID, maximumUTF8Count: 512),
                      !completedProviderCallIDs.contains(callID),
                      case let .object(function)? = call["function"],
                      Set(function.keys) == Set(["arguments", "name"]),
                      case let .string(name)? = function["name"],
                      canonicalToolNames.contains(name),
                      case let .string(arguments)? = function["arguments"],
                      isCanonicalJSONObject(arguments)
                else {
                    throw AgentHostedProviderTransportError.invalidRequestEnvelope
                }
                pendingProviderCallID = callID
            case "tool":
                guard let expectedCallID = pendingProviderCallID,
                      Set(message.keys) == Set(["content", "role", "tool_call_id"]),
                      message["tool_call_id"] == .string(expectedCallID),
                      case .string? = message["content"] else {
                    throw AgentHostedProviderTransportError.invalidRequestEnvelope
                }
                completedProviderCallIDs.insert(expectedCallID)
                pendingProviderCallID = nil
            case "assistant", "developer", "system", "user":
                guard pendingProviderCallID == nil,
                      Set(message.keys) == Set(["content", "role"]),
                      let content = message["content"] else {
                    throw AgentHostedProviderTransportError.invalidRequestEnvelope
                }
                try validateChatTextContent(content)
            default:
                throw AgentHostedProviderTransportError.invalidRequestEnvelope
            }
        }
        guard pendingProviderCallID == nil else {
            throw AgentHostedProviderTransportError.invalidRequestEnvelope
        }
    }

    private static func validateResponsesSingleCallToolsEnvelope(
        _ body: [String: JSONValue],
        descriptor: ProviderAdapterDescriptor
    ) throws {
        let isChatGPTCodex = descriptor.route.provenance ==
            .builtInOpenAICodexResponses
        let allowedKeys: Set<String> = [
            "input", "instructions", "max_output_tokens", "metadata", "model",
            "parallel_tool_calls", "previous_response_id", "prompt_cache_key",
            "reasoning", "store", "stream", "temperature", "tool_choice",
            "tools",
        ]
        let metadataIsValid = isChatGPTCodex
            ? body["metadata"] == nil
            : body["metadata"].map {
                if case .object = $0 { true } else { false }
            } == true
        let storeIsValid = isChatGPTCodex
            ? body["store"] == .bool(false)
            : body["store"] == nil || body["store"] == .bool(false)
        let outputLimitIsValid = !isChatGPTCodex ||
            body["max_output_tokens"] == nil
        let instructionsAreValid = isChatGPTCodex
            ? validCodexInstructions(body["instructions"])
            : body["instructions"] == nil
        guard body.keys.allSatisfy(allowedKeys.contains),
              body["parallel_tool_calls"] == .bool(false),
              body["tool_choice"] == .string("auto"),
              storeIsValid,
              metadataIsValid,
              outputLimitIsValid,
              instructionsAreValid,
              case let .array(input)? = body["input"],
              !input.isEmpty,
              case let .array(tools)? = body["tools"],
              tools == canonicalResponsesSingleCallToolDefinitions,
              tools.count == Int(
                  descriptor.route.capabilities.maximumToolDefinitions
              )
        else {
            throw AgentHostedProviderTransportError.invalidRequestEnvelope
        }
        try validateGenerationOptions(
            body,
            maximumOutputKey: "max_output_tokens",
            maximumOutputTokens:
                descriptor.route.capabilities.maximumOutputTokens
        )

        var pendingCallID: String?
        var completedCallIDs: Set<String> = []
        for value in input {
            guard case let .object(item) = value,
                  case let .string(type)? = item["type"]
            else {
                throw AgentHostedProviderTransportError.invalidRequestEnvelope
            }
            switch type {
            case "message":
                let allowedRoles = isChatGPTCodex
                    ? ["assistant", "user"]
                    : ["assistant", "developer", "system", "user"]
                guard pendingCallID == nil,
                      Set(item.keys) == Set(["content", "role", "type"]),
                      case let .string(role)? = item["role"],
                      allowedRoles.contains(role),
                      case let .array(content)? = item["content"],
                      !content.isEmpty
                else {
                    throw AgentHostedProviderTransportError
                        .invalidRequestEnvelope
                }
                for partValue in content {
                    guard case let .object(part) = partValue,
                          Set(part.keys) == Set(["text", "type"]),
                          case let .string(partType)? = part["type"],
                          case .string? = part["text"],
                          partType == (role == "assistant"
                              ? "output_text" : "input_text")
                    else {
                        throw AgentHostedProviderTransportError
                            .invalidRequestEnvelope
                    }
                }
            case "function_call":
                guard pendingCallID == nil,
                      Set(item.keys) == Set([
                          "arguments", "call_id", "name", "type",
                      ]),
                      case let .string(callID)? = item["call_id"],
                      isSafeIdentity(callID, maximumUTF8Count: 512),
                      !completedCallIDs.contains(callID),
                      case let .string(name)? = item["name"],
                      canonicalSingleCallToolNames.contains(name),
                      case let .string(arguments)? = item["arguments"],
                      isCanonicalJSONObject(arguments)
                else {
                    throw AgentHostedProviderTransportError
                        .invalidRequestEnvelope
                }
                pendingCallID = callID
            case "function_call_output":
                guard let expectedCallID = pendingCallID,
                      Set(item.keys) == Set(["call_id", "output", "type"]),
                      item["call_id"] == .string(expectedCallID),
                      item["output"] != nil
                else {
                    throw AgentHostedProviderTransportError
                        .invalidRequestEnvelope
                }
                completedCallIDs.insert(expectedCallID)
                pendingCallID = nil
            default:
                throw AgentHostedProviderTransportError.invalidRequestEnvelope
            }
        }
        guard pendingCallID == nil else {
            throw AgentHostedProviderTransportError.invalidRequestEnvelope
        }
    }

    private static func isCanonicalJSONObject(_ value: String) -> Bool {
        guard let data = value.data(using: .utf8),
              let object = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object = object else { return false }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let canonical = try? encoder.encode(object),
              let canonicalString = String(data: canonical, encoding: .utf8)
        else { return false }
        return canonicalString == value
    }

    private static func validateChatTextOnlyEnvelope(
        _ body: [String: JSONValue],
        descriptor: ProviderAdapterDescriptor
    ) throws {
        let allowedKeys: Set<String> = [
            "max_completion_tokens", "messages", "metadata", "model",
            "prompt_cache_key", "stream", "stream_options", "temperature",
        ]
        guard let metadata = body["metadata"],
              let messagesValue = body["messages"]
        else {
            throw AgentHostedProviderTransportError.invalidRequestEnvelope
        }
        guard body.keys.allSatisfy(allowedKeys.contains),
              body["stream_options"] == .object(["include_usage": .bool(true)]),
              case .object = metadata,
              case let .array(messages) = messagesValue,
              !messages.isEmpty
        else {
            throw AgentHostedProviderTransportError.invalidRequestEnvelope
        }
        try validateGenerationOptions(
            body,
            maximumOutputKey: "max_completion_tokens",
            maximumOutputTokens: descriptor.route.capabilities.maximumOutputTokens
        )

        let allowedRoles: Set<String> = ["assistant", "developer", "system", "user"]
        for value in messages {
            guard case let .object(message) = value,
                  let roleValue = message["role"],
                  let content = message["content"]
            else {
                throw AgentHostedProviderTransportError.invalidRequestEnvelope
            }
            guard Set(message.keys) == Set(["content", "role"]),
                  case let .string(role) = roleValue,
                  allowedRoles.contains(role)
            else {
                throw AgentHostedProviderTransportError.invalidRequestEnvelope
            }
            try validateChatTextContent(content)
        }
    }

    private static func validateChatTextContent(_ content: JSONValue) throws {
        switch content {
        case .string:
            return
        case let .array(parts):
            guard !parts.isEmpty else {
                throw AgentHostedProviderTransportError.invalidRequestEnvelope
            }
            for value in parts {
                guard case let .object(part) = value,
                      let textValue = part["text"]
                else {
                    throw AgentHostedProviderTransportError.invalidRequestEnvelope
                }
                guard Set(part.keys) == Set(["text", "type"]),
                      part["type"] == .string("text"),
                      case .string = textValue
                else {
                    throw AgentHostedProviderTransportError.invalidRequestEnvelope
                }
            }
        case .null, .bool, .number, .object:
            throw AgentHostedProviderTransportError.invalidRequestEnvelope
        }
    }

    private static func validateResponsesTextOnlyEnvelope(
        _ body: [String: JSONValue],
        descriptor: ProviderAdapterDescriptor
    ) throws {
        let isChatGPTCodex = descriptor.route.provenance ==
            .builtInOpenAICodexResponses
        let allowedKeys: Set<String> = [
            "input", "instructions", "max_output_tokens", "metadata", "model",
            "prompt_cache_key", "reasoning", "store", "stream", "temperature",
        ]
        let metadataIsValid = isChatGPTCodex
            ? body["metadata"] == nil
            : body["metadata"].map {
                if case .object = $0 { true } else { false }
            } == true
        let storeIsValid = isChatGPTCodex
            ? body["store"] == .bool(false)
            : body["store"] == nil
        let outputLimitIsValid = !isChatGPTCodex ||
            body["max_output_tokens"] == nil
        let instructionsAreValid = isChatGPTCodex
            ? validCodexInstructions(body["instructions"])
            : body["instructions"] == nil
        guard body["previous_response_id"] == nil,
              body.keys.allSatisfy(allowedKeys.contains),
              metadataIsValid,
              storeIsValid,
              outputLimitIsValid,
              instructionsAreValid,
              case let .array(items)? = body["input"],
              !items.isEmpty
        else {
            throw AgentHostedProviderTransportError.invalidRequestEnvelope
        }
        try validateGenerationOptions(
            body,
            maximumOutputKey: "max_output_tokens",
            maximumOutputTokens: descriptor.route.capabilities.maximumOutputTokens
        )

        let allowedRoles: Set<String> = isChatGPTCodex
            ? ["assistant", "user"]
            : ["assistant", "developer", "system", "user"]
        for value in items {
            guard case let .object(item) = value,
                  let roleValue = item["role"],
                  let contentValue = item["content"]
            else {
                throw AgentHostedProviderTransportError.invalidRequestEnvelope
            }
            guard Set(item.keys) == Set(["content", "role", "type"]),
                  item["type"] == .string("message"),
                  case let .string(role) = roleValue,
                  allowedRoles.contains(role),
                  case let .array(parts) = contentValue,
                  !parts.isEmpty
            else {
                throw AgentHostedProviderTransportError.invalidRequestEnvelope
            }
            let expectedPartType = role == "assistant" ? "output_text" : "input_text"
            for value in parts {
                guard case let .object(part) = value,
                      let textValue = part["text"]
                else {
                    throw AgentHostedProviderTransportError.invalidRequestEnvelope
                }
                guard Set(part.keys) == Set(["text", "type"]),
                      part["type"] == .string(expectedPartType),
                      case .string = textValue
                else {
                    throw AgentHostedProviderTransportError.invalidRequestEnvelope
                }
            }
        }
    }

    private static func validateGenerationOptions(
        _ body: [String: JSONValue],
        maximumOutputKey: String,
        maximumOutputTokens: UInt64
    ) throws {
        if let maximum = body[maximumOutputKey] {
            guard case let .number(.unsignedInteger(value)) = maximum,
                  value > 0, value <= maximumOutputTokens
            else {
                throw AgentHostedProviderTransportError.invalidRequestEnvelope
            }
        }
        if let temperature = body["temperature"] {
            guard case let .number(.floatingPoint(value)) = temperature,
                  value.isFinite, (0 ... 2).contains(value)
            else {
                throw AgentHostedProviderTransportError.invalidRequestEnvelope
            }
        }
        if let reasoning = body["reasoning"] {
            guard case let .object(options) = reasoning,
                  !options.isEmpty,
                  options.keys.allSatisfy({ ["effort", "summary"].contains($0) })
            else {
                throw AgentHostedProviderTransportError.invalidRequestEnvelope
            }
            if let summary = options["summary"],
               summary != .string("auto") {
                throw AgentHostedProviderTransportError.invalidRequestEnvelope
            }
            if let effort = options["effort"] {
                guard case let .string(value) = effort,
                      ProviderReasoningEffort(rawValue: value) != nil
                else {
                    throw AgentHostedProviderTransportError.invalidRequestEnvelope
                }
            }
        }
        if let cacheKey = body["prompt_cache_key"],
           case let .string(value) = cacheKey,
           !value.isEmpty {
            // The value is credential-scanned below with the entire envelope.
        } else if body["prompt_cache_key"] != nil {
            throw AgentHostedProviderTransportError.invalidRequestEnvelope
        }
    }

    private static func validCodexInstructions(_ value: JSONValue?) -> Bool {
        guard let value else { return true }
        guard case let .string(instructions) = value else { return false }
        return !instructions.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty && instructions.utf8.count <= 1_000_000
    }

    private static func containsToolDispatchMaterial(_ value: JSONValue) -> Bool {
        switch value {
        case let .array(values):
            return values.contains(where: containsToolDispatchMaterial)
        case let .object(object):
            let forbiddenKeys: Set<String> = [
                "call_id", "parallel_tool_calls", "tool_call_id", "tool_calls",
                "tool_choice", "tools",
            ]
            if object.keys.contains(where: forbiddenKeys.contains) { return true }
            if object["role"] == .string("tool") { return true }
            if let typeValue = object["type"],
               case let .string(type) = typeValue,
               type == "function" || type.hasPrefix("function_call") {
                return true
            }
            return object.values.contains(where: containsToolDispatchMaterial)
        case .null, .bool, .number, .string:
            return false
        }
    }

    private static func containsCredential(_ credential: String, in value: JSONValue) -> Bool {
        switch value {
        case let .string(string):
            return string.contains(credential)
        case let .array(values):
            return values.contains { containsCredential(credential, in: $0) }
        case let .object(object):
            return object.contains { key, value in
                key.contains(credential) || containsCredential(credential, in: value)
            }
        case .null, .bool, .number:
            return false
        }
    }

    private static func makeURLRequest(
        path: String,
        body: Data,
        credential: String,
        authority: Authority
    ) throws -> URLRequest {
        let provenance: ProviderRouteProvenance = switch authority {
        case let .textOnly(capability): capability.snapshot.provenance
        case let .readOnlyTools(capability): capability.snapshot.provenance
        case let .singleCallTools(capability): capability.snapshot.provenance
        }
        let absolute: String = switch (provenance, path) {
        case (.builtInOpenAIChatCompletions, "/v1/chat/completions"):
            "https://api.openai.com/v1/chat/completions"
        case (.builtInOpenAIResponses, "/v1/responses"):
            "https://api.openai.com/v1/responses"
        case (
            .builtInOpenCodeZenChatCompletions,
            "/zen/v1/chat/completions"
        ):
            "https://opencode.ai/zen/v1/chat/completions"
        case (.builtInOpenAICodexResponses, "/codex/responses"):
            "https://chatgpt.com/backend-api/codex/responses"
        default:
            throw AgentHostedProviderTransportError.untrustedDescriptor
        }
        guard let url = URL(string: absolute),
              url.scheme == "https",
              ["api.openai.com", "chatgpt.com", "opencode.ai"]
                .contains(url.host ?? ""),
              url.user == nil, url.password == nil, url.query == nil,
              url.fragment == nil
        else {
            throw AgentHostedProviderTransportError.untrustedDescriptor
        }

        var result = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 90
        )
        result.httpMethod = "POST"
        result.httpShouldHandleCookies = false
        if !credential.isEmpty {
            result.setValue(
                "Bearer \(credential)",
                forHTTPHeaderField: "Authorization"
            )
        }
        result.setValue("application/json", forHTTPHeaderField: "Content-Type")
        result.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if provenance == .builtInOpenAICodexResponses {
            result.setValue("novaforge_ios", forHTTPHeaderField: "originator")
            result.setValue("NovaForge/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
            if let accountID = chatGPTAccountID(fromJWT: credential) {
                result.setValue(
                    accountID,
                    forHTTPHeaderField: "ChatGPT-Account-ID"
                )
            }
        }
        result.httpBody = body
        return result
    }

    private static func chatGPTAccountID(fromJWT token: String) -> String? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64), data.count <= 64 * 1_024,
              let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let auth = object["https://api.openai.com/auth"]
                as? [String: Any],
              let accountID = auth["chatgpt_account_id"] as? String,
              isSafeIdentity(accountID, maximumUTF8Count: 512)
        else { return nil }
        return accountID
    }

    private static func sanitized(
        _ error: any Error,
        providerID: ProviderID,
        adapterID: ProviderAdapterID
    ) -> any Error {
        if let error = error as? AgentHostedProviderTransportError { return error }
        if let trusted = error as? HostedProviderTrustedFailure,
           trusted.failure.providerID == providerID,
           trusted.failure.adapterID == adapterID {
            return trusted.failure
        }
        if error is CancellationError || Task.isCancelled ||
            (error as? URLError)?.code == .cancelled
        {
            return ProviderFailureMapper.cancellation(
                providerID: providerID,
                adapterID: adapterID
            )
        }
        return ProviderFailureMapper.transportFailure(
            providerID: providerID,
            adapterID: adapterID,
            timedOut: (error as? URLError)?.code == .timedOut
        )
    }
}

enum AgentHostedProviderTransportError: Error, Equatable, LocalizedError, Sendable {
    case invalidCredential
    case untrustedDescriptor
    case invalidAttemptScope
    case duplicateAttemptScope
    case invalidRequestEnvelope
    case toolDispatchNotAllowed
    case credentialPresentInRequestBody
    case requestBodyTooLarge
    case requestStructureTooComplex
    case invalidHTTPResponse
    case redirectedResponse
    case invalidContentType
    case streamTooLarge
    case lineTooLarge
    case eventTooLarge
    case frameLimitExceeded
    case malformedSSE
    case malformedJSONFrame
    case invalidWireIdentity
    case credentialPresentInProviderResponse
    case responseStructureTooComplex
    case chatStreamEndedWithoutDone
    case consumerBackpressureExceeded

    var errorDescription: String? {
        switch self {
        case .invalidCredential:
            "The hosted provider credential is invalid."
        case .untrustedDescriptor:
            "The hosted provider route is not trusted."
        case .invalidAttemptScope, .duplicateAttemptScope:
            "The hosted provider attempt identity is invalid."
        case .invalidRequestEnvelope, .toolDispatchNotAllowed,
             .credentialPresentInRequestBody, .requestBodyTooLarge,
             .requestStructureTooComplex:
            "The hosted provider request was rejected."
        case .invalidHTTPResponse, .redirectedResponse, .invalidContentType:
            "The hosted provider returned an invalid response."
        case .streamTooLarge, .lineTooLarge, .eventTooLarge,
             .frameLimitExceeded, .malformedSSE, .malformedJSONFrame,
             .invalidWireIdentity, .credentialPresentInProviderResponse,
             .responseStructureTooComplex, .chatStreamEndedWithoutDone,
             .consumerBackpressureExceeded:
            "The hosted provider returned an invalid streaming event."
        }
    }
}

/// Only failures created inside this transport may cross the boundary with
/// their category/status intact. A URL loader (including a hostile injected
/// loader) cannot manufacture this private wrapper, so arbitrary
/// `ProviderFailure` code/message fields are remapped to a fixed failure.
private struct HostedProviderTrustedFailure: Error, Sendable {
    let failure: ProviderFailure
}

/// Rejects a credential before a provider frame can reach ModelGateway.
///
/// A complete credential is searched in every decoded JSON key and string.
/// Text deltas additionally use a streaming KMP matcher per output channel so
/// JSON syntax and repeated response metadata between frames cannot hide a
/// credential split into arbitrarily small fragments. State is bounded by the
/// credential length, the existing JSON budgets, and the frame-count budget.
private struct HostedProviderCredentialEchoGuard: Sendable {
    private enum TextChannel: Hashable, Sendable {
        case chat(choiceIndex: Int?)
        case chatTool(choiceIndex: Int?, toolIndex: Int?)
        case responses(outputIndex: Int?, contentIndex: Int?)
        case responsesTool(outputIndex: Int?)
    }

    private struct PendingValue: Sendable {
        let value: JSONValue
        let depth: Int
    }

    private let credential: String
    private let pattern: [UInt8]
    private let failureTable: [Int]
    private let maximumDepth: Int
    private let maximumNodesPerFrame: Int
    private let maximumTrackedTextChannels: Int
    private var matchedPrefixLengths: [TextChannel: Int] = [:]

    init(
        credential: String,
        maximumDepth: Int,
        maximumNodesPerFrame: Int,
        maximumTrackedTextChannels: Int
    ) {
        self.credential = credential
        pattern = Array(credential.utf8)
        failureTable = Self.makeFailureTable(for: pattern)
        self.maximumDepth = maximumDepth
        self.maximumNodesPerFrame = maximumNodesPerFrame
        self.maximumTrackedTextChannels = maximumTrackedTextChannels
    }

    mutating func validate(
        _ frame: ProviderWireFrame,
        dialect: ProviderAdapterDialect
    ) throws {
        // Anonymous Zen Free routes intentionally have no credential to scan.
        // Besides avoiding pointless work, this keeps the streaming matcher
        // from indexing an empty pattern.
        guard !pattern.isEmpty else { return }
        switch frame {
        case let .json(value):
            try rejectCompleteCredential(in: value)
            for (channel, text) in textDeltas(in: value, dialect: dialect) {
                try consume(text, on: channel)
            }
        case let .cancelled(reason):
            if let reason, reason.contains(credential) {
                throw AgentHostedProviderTransportError.credentialPresentInProviderResponse
            }
        case .done:
            break
        }
    }

    private func rejectCompleteCredential(in root: JSONValue) throws {
        var pending = [PendingValue(value: root, depth: 1)]
        var visitedNodes = 0

        while let current = pending.popLast() {
            visitedNodes += 1
            guard visitedNodes <= maximumNodesPerFrame,
                  current.depth <= maximumDepth
            else {
                throw AgentHostedProviderTransportError.responseStructureTooComplex
            }

            switch current.value {
            case let .string(value):
                guard !value.contains(credential) else {
                    throw AgentHostedProviderTransportError.credentialPresentInProviderResponse
                }
            case let .array(values):
                guard values.isEmpty || current.depth < maximumDepth,
                      values.count <= maximumNodesPerFrame - visitedNodes - pending.count
                else {
                    throw AgentHostedProviderTransportError.responseStructureTooComplex
                }
                pending.reserveCapacity(pending.count + values.count)
                for value in values {
                    pending.append(.init(value: value, depth: current.depth + 1))
                }
            case let .object(object):
                guard object.isEmpty || current.depth < maximumDepth,
                      object.count <= maximumNodesPerFrame - visitedNodes - pending.count
                else {
                    throw AgentHostedProviderTransportError.responseStructureTooComplex
                }
                pending.reserveCapacity(pending.count + object.count)
                for (key, value) in object {
                    guard !key.contains(credential) else {
                        throw AgentHostedProviderTransportError.credentialPresentInProviderResponse
                    }
                    pending.append(.init(value: value, depth: current.depth + 1))
                }
            case .null, .bool, .number:
                break
            }
        }
    }

    private func textDeltas(
        in value: JSONValue,
        dialect: ProviderAdapterDialect
    ) -> [(TextChannel, String)] {
        guard case let .object(object) = value else { return [] }
        switch dialect {
        case .openAIChatCompletions:
            guard case let .array(choices)? = object["choices"] else { return [] }
            return choices.flatMap { choiceValue -> [(TextChannel, String)] in
                guard case let .object(choice) = choiceValue,
                      case let .object(delta)? = choice["delta"] else { return [] }
                let choiceIndex = Self.exactInt(choice["index"])
                var fragments: [(TextChannel, String)] = []
                if case let .string(text)? = delta["content"] {
                    fragments.append((.chat(choiceIndex: choiceIndex), text))
                }
                if case let .array(calls)? = delta["tool_calls"] {
                    for callValue in calls {
                        guard case let .object(call) = callValue,
                              case let .object(function)? = call["function"],
                              case let .string(arguments)? = function["arguments"]
                        else { continue }
                        fragments.append((
                            .chatTool(
                                choiceIndex: choiceIndex,
                                toolIndex: Self.exactInt(call["index"])
                            ),
                            arguments
                        ))
                    }
                }
                return fragments
            }
        case .openAIResponses:
            if object["type"] == .string("response.output_text.delta"),
               case let .string(text)? = object["delta"] {
                return [(
                    .responses(
                        outputIndex: Self.exactInt(object["output_index"]),
                        contentIndex: Self.exactInt(object["content_index"])
                    ),
                    text,
                )]
            }
            if object["type"] == .string("response.function_call_arguments.delta"),
               case let .string(fragment)? = object["delta"] {
                return [(
                    .responsesTool(
                        outputIndex: Self.exactInt(object["output_index"])
                    ),
                    fragment,
                )]
            }
            return []
        case .openAICompatibleChat:
            return []
        }
    }

    private mutating func consume(_ text: String, on channel: TextChannel) throws {
        guard !text.isEmpty else { return }
        if matchedPrefixLengths[channel] == nil {
            guard matchedPrefixLengths.count < maximumTrackedTextChannels else {
                throw AgentHostedProviderTransportError.responseStructureTooComplex
            }
            matchedPrefixLengths[channel] = 0
        }

        var matched = matchedPrefixLengths[channel, default: 0]
        for byte in text.utf8 {
            while matched > 0, pattern[matched] != byte {
                matched = failureTable[matched - 1]
            }
            if pattern[matched] == byte {
                matched += 1
                guard matched < pattern.count else {
                    throw AgentHostedProviderTransportError.credentialPresentInProviderResponse
                }
            }
        }
        matchedPrefixLengths[channel] = matched
    }

    private static func makeFailureTable(for pattern: [UInt8]) -> [Int] {
        var result = [Int](repeating: 0, count: pattern.count)
        guard pattern.count > 1 else { return result }
        var matched = 0
        for index in 1 ..< pattern.count {
            while matched > 0, pattern[matched] != pattern[index] {
                matched = result[matched - 1]
            }
            if pattern[matched] == pattern[index] { matched += 1 }
            result[index] = matched
        }
        return result
    }

    private static func exactInt(_ value: JSONValue?) -> Int? {
        guard case let .number(number)? = value else { return nil }
        switch number {
        case let .integer(value):
            return Int(exactly: value)
        case let .unsignedInteger(value):
            return Int(exactly: value)
        case let .floatingPoint(value):
            guard value.isFinite, value.rounded(.towardZero) == value else { return nil }
            return Int(exactly: value)
        }
    }
}

private actor HostedProviderAttemptRegistry {
    private static let maximumRecentScopes = 4_096

    /// Process-local defense in depth only. ModelGateway's durable dispatch
    /// barrier is authoritative across FIFO eviction and process relaunch.
    private var recent: Set<ProviderAttemptScope> = []
    private var order: [ProviderAttemptScope] = []
    private var cursor = 0

    func reserve(_ scope: ProviderAttemptScope) throws {
        guard recent.insert(scope).inserted else {
            throw AgentHostedProviderTransportError.duplicateAttemptScope
        }
        if order.count < Self.maximumRecentScopes {
            order.append(scope)
            return
        }
        let evicted = order[cursor]
        recent.remove(evicted)
        order[cursor] = scope
        cursor = (cursor + 1) % Self.maximumRecentScopes
    }
}

private struct HostedProviderWireIdentityValidator: Sendable {
    private let dialect: ProviderAdapterDialect
    private let expectedModelID: ProviderModelID
    private var responseID: String?
    private var responseModel: String?

    init(dialect: ProviderAdapterDialect, expectedModelID: ProviderModelID) {
        self.dialect = dialect
        self.expectedModelID = expectedModelID
    }

    mutating func validate(_ frame: ProviderWireFrame) throws {
        guard case let .json(value) = frame else { return }
        guard case let .object(object) = value else {
            throw AgentHostedProviderTransportError.invalidWireIdentity
        }
        switch dialect {
        case .openAIChatCompletions:
            try validateChat(object)
        case .openAIResponses:
            try validateResponses(object)
        case .openAICompatibleChat:
            throw AgentHostedProviderTransportError.invalidWireIdentity
        }
    }

    private mutating func validateChat(
        _ object: [String: JSONValue]
    ) throws {
        // ProviderStreamSession maps a top-level provider error without
        // treating it as response output, so no response identity is required.
        if object["error"] != nil { return }
        guard let idValue = object["id"],
              case let .string(id) = idValue,
              let modelValue = object["model"],
              case let .string(model) = modelValue
        else {
            throw AgentHostedProviderTransportError.invalidWireIdentity
        }
        try bind(id: id, model: model)
    }

    private mutating func validateResponses(
        _ object: [String: JSONValue]
    ) throws {
        guard let typeValue = object["type"],
              case let .string(type) = typeValue
        else {
            throw AgentHostedProviderTransportError.invalidWireIdentity
        }
        if type == "error" { return }

        let identityRequired = type == "response.created" ||
            type == "response.completed" || type == "response.incomplete"
        if let responseValue = object["response"] {
            guard case let .object(response) = responseValue,
                  let idValue = response["id"],
                  case let .string(id) = idValue,
                  let modelValue = response["model"],
                  case let .string(model) = modelValue
            else {
                throw AgentHostedProviderTransportError.invalidWireIdentity
            }
            try bind(id: id, model: model)
        } else if identityRequired {
            throw AgentHostedProviderTransportError.invalidWireIdentity
        }

        if let responseIDValue = object["response_id"] {
            guard case let .string(candidate) = responseIDValue,
                  Self.isSafeIdentity(candidate, maximumUTF8Count: 512),
                  responseID == nil || responseID == candidate
            else {
                throw AgentHostedProviderTransportError.invalidWireIdentity
            }
        }
    }

    private mutating func bind(id: String, model: String) throws {
        guard Self.isSafeIdentity(id, maximumUTF8Count: 512),
              Self.isSafeIdentity(model, maximumUTF8Count: 256),
              Self.isPermittedModel(model, expected: expectedModelID.rawValue)
        else {
            throw AgentHostedProviderTransportError.invalidWireIdentity
        }
        if let responseID, responseID != id {
            throw AgentHostedProviderTransportError.invalidWireIdentity
        }
        if let responseModel, responseModel != model {
            throw AgentHostedProviderTransportError.invalidWireIdentity
        }
        responseID = id
        responseModel = model
    }

    /// Hosted aliases may resolve only to their exact YYYY-MM-DD snapshot.
    /// Arbitrary prefix matches (for example `model-untrusted`) are rejected.
    private static func isPermittedModel(_ actual: String, expected: String) -> Bool {
        if actual == expected { return true }
        guard !hasDateVersionSuffix(expected) else { return false }
        let prefix = expected + "-"
        guard actual.hasPrefix(prefix) else { return false }
        let suffix = actual.dropFirst(prefix.count)
        return isGregorianDateSuffix(suffix.utf8)
    }

    private static func hasDateVersionSuffix(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count >= 11,
              bytes[bytes.count - 11] == 45
        else { return false }
        return isGregorianDateSuffix(bytes.suffix(10))
    }

    private static func isGregorianDateSuffix<S: Collection>(_ suffix: S) -> Bool
    where S.Element == UInt8 {
        let bytes = Array(suffix)
        guard bytes.count == 10,
              bytes[4] == 45, bytes[7] == 45,
              bytes.enumerated().allSatisfy({ offset, byte in
                  offset == 4 || offset == 7 || (48 ... 57).contains(byte)
              })
        else { return false }

        let year = Int(bytes[0] - 48) * 1_000 +
            Int(bytes[1] - 48) * 100 +
            Int(bytes[2] - 48) * 10 +
            Int(bytes[3] - 48)
        let month = Int(bytes[5] - 48) * 10 + Int(bytes[6] - 48)
        let day = Int(bytes[8] - 48) * 10 + Int(bytes[9] - 48)
        guard year > 0, (1 ... 12).contains(month) else { return false }
        let leapYear = year.isMultiple(of: 4) &&
            (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
        let maximumDay: Int
        switch month {
        case 2:
            maximumDay = leapYear ? 29 : 28
        case 4, 6, 9, 11:
            maximumDay = 30
        default:
            maximumDay = 31
        }
        return (1 ... maximumDay).contains(day)
    }

    private static func isSafeIdentity(
        _ value: String,
        maximumUTF8Count: Int
    ) -> Bool {
        guard !value.isEmpty, value.utf8.count <= maximumUTF8Count,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar) &&
                !CharacterSet.controlCharacters.contains(scalar) &&
                scalar.properties.generalCategory != .format
        }
    }
}

enum AgentHostedProviderRedirectPolicy {
    /// The credentialed hosted canary never follows a redirect. Keeping this
    /// decision as a pure seam lets hostile tests prove that even a callback
    /// carrying a credentialed proposed request returns no request to dispatch.
    static func requestToFollow(
        response: HTTPURLResponse,
        proposedRequest: URLRequest
    ) -> URLRequest? {
        _ = response
        _ = proposedRequest
        return nil
    }
}

/// Internal only so the unit gate can invoke the redirect callback locally
/// with a suspended task. The production session still shares this exact
/// delegate instance and never receives a request to follow.
final class HostedProviderNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = HostedProviderNoRedirectDelegate()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(AgentHostedProviderRedirectPolicy.requestToFollow(
            response: response,
            proposedRequest: request
        ))
    }
}

private struct HostedProviderSSEParser {
    private let limits: AgentHostedProviderTransport.Limits
    private var totalBytes = 0
    private var currentLine: [UInt8] = []
    private var dataLines: [String] = []
    private var eventBytes = 0
    private var frameCount = 0
    private var receivedDone = false

    var didReceiveDone: Bool { receivedDone }

    init(limits: AgentHostedProviderTransport.Limits) {
        self.limits = limits
        currentLine.reserveCapacity(min(limits.maximumSSELineBytes, 4_096))
    }

    mutating func consume(_ byte: UInt8) throws -> [ProviderWireFrame] {
        totalBytes += 1
        guard totalBytes <= limits.maximumStreamBytes else {
            throw AgentHostedProviderTransportError.streamTooLarge
        }

        if byte == 0x0a {
            if currentLine.last == 0x0d { currentLine.removeLast() }
            let frames = try consumeCompletedLine()
            currentLine.removeAll(keepingCapacity: true)
            return frames
        }

        currentLine.append(byte)
        guard currentLine.count <= limits.maximumSSELineBytes else {
            throw AgentHostedProviderTransportError.lineTooLarge
        }
        return []
    }

    mutating func finish() throws -> [ProviderWireFrame] {
        var frames: [ProviderWireFrame] = []
        if !currentLine.isEmpty {
            if currentLine.last == 0x0d { currentLine.removeLast() }
            frames.append(contentsOf: try consumeCompletedLine())
            currentLine.removeAll(keepingCapacity: false)
        }
        if !dataLines.isEmpty {
            frames.append(contentsOf: try dispatchEvent())
        }
        return frames
    }

    private mutating func consumeCompletedLine() throws -> [ProviderWireFrame] {
        guard let line = String(bytes: currentLine, encoding: .utf8) else {
            throw AgentHostedProviderTransportError.malformedSSE
        }
        if line.isEmpty { return try dispatchEvent() }
        if line.hasPrefix(":") { return [] }

        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.first == " " { value = value.dropFirst() }
        } else {
            field = Substring(line)
            value = ""
        }
        guard field == "data" else { return [] }

        let string = String(value)
        let separatorBytes = dataLines.isEmpty ? 0 : 1
        eventBytes += separatorBytes + string.utf8.count
        guard eventBytes <= limits.maximumSSEEventBytes else {
            throw AgentHostedProviderTransportError.eventTooLarge
        }
        dataLines.append(string)
        return []
    }

    private mutating func dispatchEvent() throws -> [ProviderWireFrame] {
        guard !dataLines.isEmpty else { return [] }
        let payload = dataLines.joined(separator: "\n")
        dataLines.removeAll(keepingCapacity: true)
        eventBytes = 0

        guard !receivedDone else {
            throw AgentHostedProviderTransportError.malformedSSE
        }
        frameCount += 1
        guard frameCount <= limits.maximumFrameCount else {
            throw AgentHostedProviderTransportError.frameLimitExceeded
        }
        if payload == "[DONE]" {
            receivedDone = true
            return [.done]
        }

        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: Data(payload.utf8))
        } catch {
            throw AgentHostedProviderTransportError.malformedJSONFrame
        }
        return [.json(value)]
    }
}
