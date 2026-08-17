//
//  LlamaService.swift
//  PrivateAI
//
//  Created by Piotr Gorzelany on 24/01/2024.
//

import Foundation

public final actor LlamaService {

    // MARK: Properties
    private var llama: Llama?
    private var currentTask: Task<(), Error>?
    private var lastPerformanceSnapshot: LlamaPerformanceSnapshot?
    private let modelUrl: URL
    private let requestedConfig: LlamaConfig
    private let runtimeDecision: LlamaRuntimeTuner.Decision
    private let tokenBufferSize = 1
    private var didAttemptPersistentRestore = false

    /// State persistence is deliberately bounded. llama.cpp writes directly to
    /// disk (no giant Swift Data copy); anything larger than this is cheaper and
    /// safer to re-prefill on a 4 GB phone than to churn through NAND every turn.
    private let maximumPersistentSessionBytes = 512 * 1024 * 1024

    // MARK: Lifecycle

    public init(modelUrl: URL, config: LlamaConfig) {
        self.modelUrl = modelUrl
        self.requestedConfig = config
        self.runtimeDecision = LlamaRuntimeTuner.decide(
            modelURL: modelUrl,
            requested: config
        )
    }

    /// The exact pre-context runtime decision is exposed for diagnostics and
    /// benchmark receipts. It never contains user prompt/model content.
    public func runtimeProfile() -> LlamaRuntimeTuner.Decision {
        runtimeDecision
    }

    /// Content-free measurements from the most recently completed local stream.
    /// This is intentionally opt-in diagnostics state; it never captures text,
    /// token ids, prompts, generated output, or model paths.
    public func performanceSnapshot() -> LlamaPerformanceSnapshot? {
        lastPerformanceSnapshot
    }

    // MARK: Methods

    public func processMessages(_ messages: [LlamaChatMessage]) async throws {
        let llama = try initializeLlamaIfNecessary()
        await stopCompletion()
        try await llama.initializeCompletion(messages: messages, addAssistant: false)
    }

    /// Generate a typed response constrained by a JSON grammar inferred from `T` and decode it.
    public func respond<T: Codable>(to messages: [LlamaChatMessage], generating type: T.Type) async throws -> T {
        func extractLikelyJSON(from text: String) -> String? {
            guard let startIndex = text.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return nil }
            let candidate = text[startIndex...]
            var depth: Int = 0
            var closingIndex: String.Index?
            for (i, ch) in candidate.enumerated() {
                let idx = candidate.index(candidate.startIndex, offsetBy: i)
                if ch == "{" || ch == "[" { depth += 1 }
                else if ch == "}" || ch == "]" {
                    depth -= 1
                    if depth == 0 { closingIndex = idx; break }
                }
            }
            if let closingIndex { return String(candidate[...closingIndex]) }
            return nil
        }

        var accumulated = ""
        let decoder = JSONDecoder()
        var decodedValue: T?
        let stream = try await streamCompletion(of: messages, generating: type)
        do {
            for try await token in stream {
                accumulated += token
                if let jsonText = extractLikelyJSON(from: accumulated),
                   let data = jsonText.data(using: .utf8),
                   let value = try? decoder.decode(T.self, from: data) {
                    decodedValue = value
                    break
                }
            }
        } catch {
            // Fall through to final decode attempt below.
        }
        if let value = decodedValue {
            await stopCompletion()
            return value
        }
        let finalText = extractLikelyJSON(from: accumulated) ?? accumulated
        guard let finalData = finalText.data(using: .utf8) else {
            throw LlamaError.decodingError
        }
        return try decoder.decode(T.self, from: finalData)
    }

    public func respond(to messages: [LlamaChatMessage], samplingConfig: LlamaSamplingConfig) async throws -> String {
        let stream = try await streamCompletion(of: messages, samplingConfig: samplingConfig)
        var output = ""
        for try await token in stream { output += token }
        return output
    }

    public func streamCompletion<T: Codable>(of messages: [LlamaChatMessage], generating: T.Type) async throws -> AsyncThrowingStream<String, Error> {
        let grammarConfig = try LlamaTypedJSONGrammarBuilder.makeGrammarConfig(for: generating)
        let sampling = LlamaSamplingConfig(
            temperature: 0.1,
            seed: 42,
            grammarConfig: grammarConfig
        )
        return try await streamCompletion(of: messages, samplingConfig: sampling)
    }

    public func streamCompletion(of messages: [LlamaChatMessage], samplingConfig: LlamaSamplingConfig) async throws -> AsyncThrowingStream<String, Error> {
        guard !messages.isEmpty else { throw LlamaError.emptyMessageArray }
        let requestStartedAt = Self.monotonicSeconds()
        let llama = try initializeLlamaIfNecessary()
        await stopCompletion()
        let prefillStartedAt = Self.monotonicSeconds()
        if !didAttemptPersistentRestore {
            didAttemptPersistentRestore = true
            _ = try? await restorePersistentSessionIfPossible(
                into: llama,
                messages: messages
            )
        }
        try await llama.initializeCompletion(messages: messages)
        try await llama.updateSamplingConfig(samplingConfig)
        let prefillFinishedAt = Self.monotonicSeconds()
        let prefillSeconds = max(0, prefillFinishedAt - prefillStartedAt)
        let effectiveConfig = runtimeDecision.config
        let runtimeReason = runtimeDecision.reason

        return AsyncThrowingStream { continuation in
            currentTask = Task {
                let generationStartedAt = Self.monotonicSeconds()
                var firstTokenAt: Double?
                var generatedTokenCount = 0
                var completion: LlamaPerformanceSnapshot.Completion = .completed

                do {
                    var tokenBuffer: [String] = []
                    generationLoop: while await (llama.currentTokenPosition < llama.maxTokenCount) {
                        guard !Task.isCancelled else {
                            completion = .cancelled
                            if !tokenBuffer.isEmpty {
                                continuation.yield(tokenBuffer.joined())
                                tokenBuffer = []
                            }
                            break
                        }
                        let result = try await llama.generateNextToken()
                        switch result {
                        case .token(let token):
                            generatedTokenCount += 1
                            if firstTokenAt == nil {
                                firstTokenAt = Self.monotonicSeconds()
                            }
                            tokenBuffer.append(token)
                            if tokenBuffer.count == tokenBufferSize {
                                continuation.yield(tokenBuffer.joined())
                                tokenBuffer = []
                            }
                            if generatedTokenCount.isMultiple(of: effectiveConfig.yieldEveryTokenCount) {
                                await Task.yield()
                            }
                        case .endOfString:
                            if !tokenBuffer.isEmpty { continuation.yield(tokenBuffer.joined()) }
                            break generationLoop
                        }
                    }

                    let generationFinishedAt = Self.monotonicSeconds()
                    recordPerformance(
                        runtimeReason: runtimeReason,
                        requestStartedAt: requestStartedAt,
                        prefillSeconds: prefillSeconds,
                        generationStartedAt: generationStartedAt,
                        firstTokenAt: firstTokenAt,
                        generationFinishedAt: generationFinishedAt,
                        generatedTokenCount: generatedTokenCount,
                        completion: completion
                    )
                    if completion == .completed, generatedTokenCount > 0 {
                        await persistSessionIfUseful(from: llama)
                    }
                    continuation.finish()
                } catch {
                    completion = Task.isCancelled ? .cancelled : .failed
                    let generationFinishedAt = Self.monotonicSeconds()
                    recordPerformance(
                        runtimeReason: runtimeReason,
                        requestStartedAt: requestStartedAt,
                        prefillSeconds: prefillSeconds,
                        generationStartedAt: generationStartedAt,
                        firstTokenAt: firstTokenAt,
                        generationFinishedAt: generationFinishedAt,
                        generatedTokenCount: generatedTokenCount,
                        completion: completion
                    )
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public func stopCompletion() async {
        await currentTask?.cancelAndWait()
    }

    private func recordPerformance(
        runtimeReason: String,
        requestStartedAt: Double,
        prefillSeconds: Double,
        generationStartedAt: Double,
        firstTokenAt: Double?,
        generationFinishedAt: Double,
        generatedTokenCount: Int,
        completion: LlamaPerformanceSnapshot.Completion
    ) {
        let decodeSeconds = max(0, generationFinishedAt - generationStartedAt)
        let tokensPerSecond = decodeSeconds > 0
            ? Double(generatedTokenCount) / decodeSeconds
            : 0
        lastPerformanceSnapshot = LlamaPerformanceSnapshot(
            runtimeReason: runtimeReason,
            prefillSeconds: prefillSeconds,
            timeToFirstTokenSeconds: firstTokenAt.map {
                max(0, $0 - requestStartedAt)
            },
            decodeSeconds: decodeSeconds,
            generatedTokenCount: generatedTokenCount,
            decodeTokensPerSecond: tokensPerSecond,
            completion: completion
        )
    }

    /// Foundation's reference-date clock is monotonic enough for short local
    /// inference intervals and keeps the telemetry implementation portable
    /// across every platform supported by this package.
    private nonisolated static func monotonicSeconds() -> Double {
        ProcessInfo.processInfo.systemUptime
    }

    private struct PersistentSessionMetadata: Codable, Equatable {
        static let formatVersion = 1
        let formatVersion: Int
        let modelFilename: String
        let logicalModelBytes: Int64
        let modificationTimestamp: TimeInterval
        let contextTokens: UInt32
        let batchTokens: UInt32
        let microBatchTokens: UInt32
        let keyCacheType: String
        let valueCacheType: String
        let loadMode: String
    }

    private struct PersistentSessionPaths {
        let directory: URL
        let session: URL
        let temporarySession: URL
        let metadata: URL
    }

    private func restorePersistentSessionIfPossible(
        into llama: Llama,
        messages: [LlamaChatMessage]
    ) async throws -> Bool {
        let expected = try persistentSessionMetadata()
        let paths = try persistentSessionPaths(for: expected)
        guard FileManager.default.fileExists(atPath: paths.session.path),
              FileManager.default.fileExists(atPath: paths.metadata.path),
              let data = try? Data(contentsOf: paths.metadata),
              let persisted = try? JSONDecoder().decode(PersistentSessionMetadata.self, from: data),
              persisted == expected
        else {
            invalidatePersistentSession(paths)
            return false
        }

        let restored = try await llama.restoreSessionIfPrefix(
            from: paths.session,
            messages: messages
        )
        if !restored {
            invalidatePersistentSession(paths)
        }
        return restored
    }

    private func persistSessionIfUseful(from llama: Llama) async {
        do {
            let stateBytes = await llama.persistentStateSizeBytes()
            guard stateBytes > 0, stateBytes <= maximumPersistentSessionBytes else { return }
            let metadata = try persistentSessionMetadata()
            let paths = try persistentSessionPaths(for: metadata)
            try FileManager.default.createDirectory(
                at: paths.directory,
                withIntermediateDirectories: true
            )
            try? FileManager.default.removeItem(at: paths.temporarySession)
            guard await llama.saveSession(to: paths.temporarySession) else {
                try? FileManager.default.removeItem(at: paths.temporarySession)
                return
            }

            // Move the expensive binary state into place before atomically
            // publishing metadata. A crash can therefore create at worst an
            // untrusted orphan, which the next launch rejects and removes.
            try? FileManager.default.removeItem(at: paths.session)
            try FileManager.default.moveItem(
                at: paths.temporarySession,
                to: paths.session
            )
            let metadataData = try JSONEncoder().encode(metadata)
            try metadataData.write(to: paths.metadata, options: [.atomic])
        } catch {
            // Prefix persistence is a pure accelerator. Any I/O/filesystem issue
            // degrades to the existing in-memory prefix reuse path.
        }
    }

    private func persistentSessionMetadata() throws -> PersistentSessionMetadata {
        let values = try modelUrl.resourceValues(forKeys: [
            .fileSizeKey,
            .contentModificationDateKey,
        ])
        let logicalBytes = Int64(values.fileSize ?? 0)
        guard logicalBytes > 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        return PersistentSessionMetadata(
            formatVersion: PersistentSessionMetadata.formatVersion,
            modelFilename: modelUrl.lastPathComponent,
            logicalModelBytes: logicalBytes,
            modificationTimestamp: values.contentModificationDate?.timeIntervalSince1970 ?? 0,
            contextTokens: runtimeDecision.config.maxTokenCount,
            batchTokens: runtimeDecision.config.batchSize,
            microBatchTokens: runtimeDecision.config.microBatchSize,
            keyCacheType: runtimeDecision.config.keyCacheType.rawValue,
            valueCacheType: runtimeDecision.config.valueCacheType.rawValue,
            loadMode: runtimeDecision.config.loadMode.rawValue
        )
    }

    private func persistentSessionPaths(
        for metadata: PersistentSessionMetadata
    ) throws -> PersistentSessionPaths {
        let base = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let fingerprintInput = [
            metadata.modelFilename,
            String(metadata.logicalModelBytes),
            String(metadata.modificationTimestamp),
            String(metadata.contextTokens),
            String(metadata.batchTokens),
            String(metadata.microBatchTokens),
            metadata.keyCacheType,
            metadata.valueCacheType,
            metadata.loadMode,
        ].joined(separator: "|")
        let fingerprint = Self.fnv1a64(fingerprintInput.utf8)
        let key = String(fingerprint, radix: 16, uppercase: false)
        let directory = base
            .appendingPathComponent("NovaForgeLLM", isDirectory: true)
            .appendingPathComponent("PrefixSessions", isDirectory: true)
            .appendingPathComponent(key, isDirectory: true)
        return PersistentSessionPaths(
            directory: directory,
            session: directory.appendingPathComponent("last.session"),
            temporarySession: directory.appendingPathComponent("last.session.tmp"),
            metadata: directory.appendingPathComponent("metadata.json")
        )
    }

    private func invalidatePersistentSession(_ paths: PersistentSessionPaths) {
        try? FileManager.default.removeItem(at: paths.session)
        try? FileManager.default.removeItem(at: paths.temporarySession)
        try? FileManager.default.removeItem(at: paths.metadata)
    }

    nonisolated static func fnv1a64<S: Sequence>(_ bytes: S) -> UInt64
    where S.Element == UInt8 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in bytes {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }

    private func initializeLlamaIfNecessary() throws -> Llama {
        guard let llama else {
            print("SwiftLlama runtime profile: \(runtimeDecision.reason)")
            llama = try Llama(
                modelPath: modelUrl.path(percentEncoded: false),
                config: runtimeDecision.config
            )
            return llama!
        }
        return llama
    }
}
