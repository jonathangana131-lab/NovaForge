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
