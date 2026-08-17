#!/usr/bin/env python3
from pathlib import Path

llama_path = Path('Vendor/swift-llama-cpp/Sources/SwiftLlama/Llama.swift')
service_path = Path('Vendor/swift-llama-cpp/Sources/SwiftLlama/LlamaService.swift')
llama = llama_path.read_text()
service = service_path.read_text()

llama_marker = '''    func saveStateData() -> Data { context.saveState() }
    func loadStateData(_ data: Data) -> Bool { context.loadState(data) }
'''
llama_replacement = '''    func saveStateData() -> Data { context.saveState() }
    func loadStateData(_ data: Data) -> Bool { context.loadState(data) }
    func persistentStateSizeBytes() -> Int { context.stateSize() }

    /// Restore a llama.cpp session only when its saved token stream is a proven
    /// prefix of the exact prompt about to run. A mismatched or stale session is
    /// immediately cleared, so persistence can only improve TTFT—not alter the
    /// model's logical context.
    func restoreSessionIfPrefix(
        from url: URL,
        messages: [LlamaChatMessage],
        addAssistant: Bool? = nil
    ) throws -> Bool {
        let formattedPrompt = model.applyChatTemplate(to: messages, addAssistant: addAssistant)
        let tokenList = model.tokenize(text: formattedPrompt, addBos: model.shouldAddBos(), special: true)
        guard tokenList.count < maxTokenCount - 4 else {
            throw LlamaError.contextSizeLimitExeeded
        }

        clear()
        guard let loaded = context.loadSession(
            from: url.path(percentEncoded: false),
            capacity: Int(maxTokenCount)
        ), loaded.count > 0,
           loaded.count == loaded.tokens.count,
           tokenList.starts(with: loaded.tokens)
        else {
            clear()
            return false
        }

        processedTokens = loaded.tokens
        currentTokenPosition = Int32(loaded.count)
        batch = .init(initialSize: Int32(config.batchSize))

        let suffix = Array(tokenList.dropFirst(loaded.count))
        if !suffix.isEmpty {
            try processPrompt(tokens: suffix, startIndex: loaded.count)
        }
        return true
    }

    func saveSession(to url: URL) -> Bool {
        guard !processedTokens.isEmpty else { return false }
        return context.saveSession(
            to: url.path(percentEncoded: false),
            tokens: processedTokens
        )
    }
'''
if llama.count(llama_marker) != 1:
    raise SystemExit(f'Llama state marker count={llama.count(llama_marker)}')
llama = llama.replace(llama_marker, llama_replacement)

property_marker = '''    private let runtimeDecision: LlamaRuntimeTuner.Decision
    private let tokenBufferSize = 1
'''
property_replacement = '''    private let runtimeDecision: LlamaRuntimeTuner.Decision
    private let tokenBufferSize = 1
    private var didAttemptPersistentRestore = false

    /// State persistence is deliberately bounded. llama.cpp writes directly to
    /// disk (no giant Swift Data copy); anything larger than this is cheaper and
    /// safer to re-prefill on a 4 GB phone than to churn through NAND every turn.
    private let maximumPersistentSessionBytes = 512 * 1024 * 1024
'''
if service.count(property_marker) != 1:
    raise SystemExit('LlamaService property marker mismatch')
service = service.replace(property_marker, property_replacement)

prefill_marker = '''        let llama = try initializeLlamaIfNecessary()
        await stopCompletion()
        let prefillStartedAt = Self.monotonicSeconds()
        try await llama.initializeCompletion(messages: messages)
'''
prefill_replacement = '''        let llama = try initializeLlamaIfNecessary()
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
'''
if service.count(prefill_marker) != 1:
    raise SystemExit('LlamaService prefill marker mismatch')
service = service.replace(prefill_marker, prefill_replacement)

finish_marker = '''                    recordPerformance(
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
'''
finish_replacement = '''                    recordPerformance(
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
'''
if service.count(finish_marker) != 1:
    raise SystemExit('LlamaService finish marker mismatch')
service = service.replace(finish_marker, finish_replacement)

insert_marker = '''    private func initializeLlamaIfNecessary() throws -> Llama {
'''
helpers = r'''    private struct PersistentSessionMetadata: Codable, Equatable {
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

'''
if service.count(insert_marker) != 1:
    raise SystemExit('LlamaService helper marker mismatch')
service = service.replace(insert_marker, helpers + insert_marker)

llama_path.write_text(llama)
service_path.write_text(service)
print('patched persistent prefix sessions')
