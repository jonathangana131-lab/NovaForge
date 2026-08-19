//
//  LlamaService.swift
//  PrivateAI
//
//  Created by Piotr Gorzelany on 24/01/2024.
//

import Foundation

/// Internal generation surface used by `LlamaService`.
///
/// Keeping the service dependent on this narrow actor-safe contract makes request ownership
/// deterministic to test without loading a GGUF while the production implementation remains `Llama`.
protocol LlamaServiceEngine: Sendable {
    func initializeCompletion(messages: [LlamaChatMessage], addAssistant: Bool?) async throws
    func updateSamplingConfig(_ config: LlamaSamplingConfig) async throws
    func hasGenerationCapacity() async -> Bool
    func generateNextToken() async throws -> NextToken
}

extension Llama: LlamaServiceEngine {
    func hasGenerationCapacity() -> Bool {
        guard currentTokenPosition >= 0 else { return false }
        return UInt64(currentTokenPosition) < UInt64(maxTokenCount)
    }
}

public final actor LlamaService {

    private struct ActiveGeneration {
        let requestID: UUID
        let task: Task<Void, Error>
    }

    // MARK: Properties
    private var engine: (any LlamaServiceEngine)?
    private var activeGeneration: ActiveGeneration?
    private var latestRequestID: UUID?
    private var requestStartCount: UInt64 = 0
    private let modelUrl: URL?
    private let config: LlamaConfig
    private let tokenBufferSize = 1

    // MARK: Lifecycle

    public init(modelUrl: URL, config: LlamaConfig) {
        self.modelUrl = modelUrl
        self.config = config
    }

    /// Internal deterministic test seam. Product callers cannot substitute the local inference engine.
    init(engine: any LlamaServiceEngine, config: LlamaConfig) {
        self.engine = engine
        self.modelUrl = nil
        self.config = config
    }

    // MARK: Methods

    public func processMessages(_ messages: [LlamaChatMessage]) async throws {
        let requestID = beginRequest()
        let engine = try initializeEngineIfNecessary()
        try await cancelActiveGeneration(for: requestID)
        try await engine.initializeCompletion(messages: messages, addAssistant: false)
        try requireCurrentRequest(requestID)
    }

    /// Generate a typed response constrained by a JSON grammar inferred from `T` and decode it.
    /// - Parameters:
    ///   - messages: Chat messages forming the prompt.
    ///   - type: The `Codable` type to generate and decode.
    /// - Returns: A decoded instance of `T` produced by the model.
    public func respond<T: Codable>(to messages: [LlamaChatMessage], generating type: T.Type) async throws -> T {
        func extractLikelyJSON(from text: String) -> String? {
            // Find first opening brace or bracket
            guard let startIndex = text.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return nil }
            let candidate = text[startIndex...]
            // Simple balance-based termination (ignores strings/escapes, good enough for LLM output)
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
            if let closingIndex {
                return String(candidate[...closingIndex])
            }
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
            // Fall through to final decode attempt below
        }
        if let value = decodedValue {
            await stopCompletion()
            return value
        }
        // Final attempt with trimmed JSON if available, otherwise full text
        let finalText = extractLikelyJSON(from: accumulated) ?? accumulated
        guard let finalData = finalText.data(using: .utf8) else {
            throw LlamaError.decodingError
        }
        return try decoder.decode(T.self, from: finalData)
    }

    /// Generate a plain text response using the provided sampling configuration.
    /// - Parameters:
    ///   - messages: Chat messages forming the prompt.
    ///   - samplingConfig: Sampling parameters controlling generation.
    /// - Returns: The full generated text.
    public func respond(to messages: [LlamaChatMessage], samplingConfig: LlamaSamplingConfig) async throws -> String {
        let stream = try await streamCompletion(of: messages, samplingConfig: samplingConfig)
        var output = ""
        for try await token in stream {
            output += token
        }
        return output
    }

    public func streamCompletion<T: Codable>(of messages: [LlamaChatMessage], generating: T.Type) async throws -> AsyncThrowingStream<String, Error> {
        // Default: constrain the output to valid JSON matching the provided type
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

        let requestID = beginRequest()
        let engine = try initializeEngineIfNecessary()

        // Every replacement waits for the exact generation that was active when setup began.
        // Actor reentrancy while waiting is expected: a newer request may supersede this one.
        // The request-ID checks below make the older setup fail closed before its next mutation.
        try await cancelActiveGeneration(for: requestID)
        try await engine.initializeCompletion(messages: messages, addAssistant: nil)
        try requireCurrentRequest(requestID)
        try await engine.updateSamplingConfig(samplingConfig)
        try requireCurrentRequest(requestID)

        return AsyncThrowingStream { continuation in
            guard latestRequestID == requestID else {
                continuation.finish(throwing: CancellationError())
                return
            }

            // Keep the producer task owned by this exact request/stream. If the consumer
            // drops the stream, cancel this task rather than whatever generation is newer.
            let generationTask = Task<Void, Error> {
                do {
                    var tokenBuffer: [String] = []
                    var generatedTokenCount = 0
                    generationLoop: while await engine.hasGenerationCapacity() {
                        guard !Task.isCancelled else {
                            if !tokenBuffer.isEmpty {
                                continuation.yield(tokenBuffer.joined())
                                tokenBuffer = []
                            }
                            break
                        }
                        let result = try await engine.generateNextToken()
                        switch result {
                        case .token(let token):
                            generatedTokenCount += 1
                            tokenBuffer.append(token)
                            if tokenBuffer.count == tokenBufferSize {
                                continuation.yield(tokenBuffer.joined())
                                tokenBuffer = []
                            }
                            if generatedTokenCount.isMultiple(of: config.yieldEveryTokenCount) {
                                await Task.yield()
                            }
                        case .endOfString:
                            if !tokenBuffer.isEmpty {
                                continuation.yield(tokenBuffer.joined())
                            }
                            break generationLoop
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            activeGeneration = ActiveGeneration(requestID: requestID, task: generationTask)
            continuation.onTermination = { @Sendable _ in
                generationTask.cancel()
            }
        }
    }

    public func stopCompletion() async {
        // Stop is itself a request boundary: pending setup work becomes stale even when no
        // producer task exists yet. A request that starts after Stop remains independent.
        let stopRequestID = beginRequest()
        let capturedGeneration = activeGeneration
        capturedGeneration?.task.cancel()
        if let capturedGeneration {
            await capturedGeneration.task.cancelAndWait()
        }

        guard latestRequestID == stopRequestID else { return }
        if let capturedGeneration,
           activeGeneration?.requestID == capturedGeneration.requestID {
            activeGeneration = nil
        }
    }

    /// Deterministic package-test observation only; no product behavior depends on this counter.
    var requestStartCountForTesting: UInt64 { requestStartCount }

    private func beginRequest() -> UUID {
        requestStartCount &+= 1
        let requestID = UUID()
        latestRequestID = requestID
        return requestID
    }

    private func requireCurrentRequest(_ requestID: UUID) throws {
        guard latestRequestID == requestID else {
            throw CancellationError()
        }
    }

    private func cancelActiveGeneration(for requestID: UUID) async throws {
        let capturedGeneration = activeGeneration
        capturedGeneration?.task.cancel()
        if let capturedGeneration {
            await capturedGeneration.task.cancelAndWait()
        }

        // A newer request may have entered while this actor was suspended waiting for the
        // captured task. Check freshness *before* clearing shared ownership or mutating Llama.
        try requireCurrentRequest(requestID)
        if let capturedGeneration,
           activeGeneration?.requestID == capturedGeneration.requestID {
            activeGeneration = nil
        }
    }

    private func initializeEngineIfNecessary() throws -> any LlamaServiceEngine {
        if let engine {
            return engine
        }
        guard let modelUrl else {
            throw LlamaError.couldNotInitializeContext
        }
        let engine = try Llama(modelPath: modelUrl.path(percentEncoded: false), config: config)
        self.engine = engine
        return engine
    }
}
