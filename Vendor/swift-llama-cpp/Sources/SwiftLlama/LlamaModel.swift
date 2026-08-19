//
//  LlamaModel.swift
//  PrivateAI
//
//  Created by Piotr Gorzelany on 12/02/2024.
//

import Foundation
import llama

enum LlamaModelError: Error {
    case initializationError
}

public final class LlamaModel {

    // MARK: - Properties

    let modelPointer: OpaquePointer
    let vocabPointer: OpaquePointer

    // MARK: - Lifecycle

    public init?(path: String, parameters: llama_model_params = llama_model_default_params()) {
        guard let modelPointer = llama_model_load_from_file(path, parameters), let vocabPointer = llama_model_get_vocab(modelPointer) else {
            return nil
        }
        self.modelPointer = modelPointer
        self.vocabPointer = vocabPointer
    }

    /// Initializes a model from multiple GGUF split files.
    /// The `paths` must be ordered correctly.
    public init?(paths: [String], parameters: llama_model_params = llama_model_default_params()) {
        var cStrings: [UnsafeMutablePointer<CChar>?] = paths.map { strdup($0) }
        defer { cStrings.forEach { if let p = $0 { free(UnsafeMutablePointer(mutating: p)) } } }
        let count = cStrings.count
        let result = cStrings.withUnsafeMutableBufferPointer { buf in
            buf.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: count) { reboundPtr in
                llama_model_load_from_splits(reboundPtr, size_t(count), parameters)
            }
        }
        guard let modelPointer = result, let vocabPointer = llama_model_get_vocab(modelPointer) else {
            return nil
        }
        self.modelPointer = modelPointer
        self.vocabPointer = vocabPointer
    }

    deinit {
        llama_model_free(modelPointer)
    }

    // MARK: - Methods

    // Helper to convert a null-terminated CChar buffer into Swift String without deprecation warnings
    private static func stringFromNullTerminated(_ buffer: [CChar]) -> String {
        let units: [UInt8] = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: units, as: UTF8.self)
    }

    /// Text context size used during training.
    public func trainedContextSize() -> Int32 {
        llama_model_n_ctx_train(modelPointer)
    }

    /// A string describing the model type.
    public func description() -> String {
        let bufferSize = 1024
        var buffer = [CChar](repeating: 0, count: bufferSize)
        let descriptionBufferSize = llama_model_desc(modelPointer, &buffer, bufferSize)
        guard descriptionBufferSize > 0 else {
            fatalError("Something went wrong")
        }
        return Self.stringFromNullTerminated(buffer)
    }

    /// Render token text for a token id.
    public func string(from token: llama_token) -> String {
        guard let results = llama_vocab_get_text(vocabPointer, token) else {
            return ""
        }
        return String(cString: results, encoding: .utf8) ?? ""
    }

    /// Decode llama.cpp's negative required-size convention without risking
    /// `Int32.min` negation overflow or retrying a non-growing allocation.
    private static func nextRequiredBufferSize(for result: Int32, currentSize: Int32) -> Int32? {
        guard result < 0, currentSize > 0 else { return nil }
        let requiredSize = -Int64(result)
        guard requiredSize > Int64(currentSize), requiredSize <= Int64(Int32.max) else { return nil }
        return Int32(requiredSize)
    }

    /// Return the next token-piece buffer size requested by llama.cpp.
    /// A negative `llama_token_to_piece` result encodes the required byte count.
    static func nextTokenPieceBufferSize(for result: Int32, currentSize: Int32) -> Int32? {
        nextRequiredBufferSize(for: result, currentSize: currentSize)
    }

    /// Return the next token buffer size requested by llama.cpp tokenization.
    static func nextTokenizationBufferSize(for result: Int32, currentSize: Int32) -> Int32? {
        nextRequiredBufferSize(for: result, currentSize: currentSize)
    }

    /// Return the next detokenization buffer size requested by llama.cpp.
    static func nextDetokenizationBufferSize(for result: Int32, currentSize: Int32) -> Int32? {
        nextRequiredBufferSize(for: result, currentSize: currentSize)
    }

    /// Chat-template rendering reports the exact required byte count as a
    /// non-negative value. Retry only when that count is strictly larger than
    /// the buffer just supplied so malformed/non-growing results fail closed.
    static func nextChatTemplateBufferSize(for result: Int32, currentSize: Int32) -> Int32? {
        guard currentSize >= 0, result > currentSize else { return nil }
        return result
    }

    /// Build a bounded first detokenization buffer without overflowing Swift's
    /// integer conversions for pathological token counts.
    static func initialDetokenizationBufferSize(tokenCount: Int) -> Int32? {
        guard tokenCount > 0, tokenCount <= Int(Int32.max) else { return nil }
        let heuristicSize = Int64(tokenCount) * 4 + 16
        guard heuristicSize > 0, heuristicSize <= Int64(Int32.max) else { return nil }
        return Int32(heuristicSize)
    }

    /// Convert a token id to its piece (optionally rendering special tokens).
    public func piece(from token: llama_token, renderSpecial: Bool = false, lstrip: Int32 = 0) -> String {
        var bufferSize: Int32 = 64

        while true {
            var buffer = [CChar](repeating: 0, count: Int(bufferSize))
            let charCount = llama_token_to_piece(vocabPointer, token, &buffer, bufferSize, lstrip, renderSpecial)

            if let requiredSize = Self.nextTokenPieceBufferSize(for: charCount, currentSize: bufferSize) {
                bufferSize = requiredSize
                continue
            }

            guard charCount >= 0, charCount <= bufferSize else { return "" }
            let chars = Array(buffer.prefix(Int(charCount))) + [0]
            return String(cString: chars, encoding: .utf8) ?? ""
        }
    }

    /// Beginning-of-sentence token id.
    public func bosToken() -> llama_token {
        llama_vocab_bos(vocabPointer)
    }

    /// Whether a BOS token should be added automatically.
    public func shouldAddBos() -> Bool {
        let addBos = llama_vocab_get_add_bos(vocabPointer)
        if addBos {
            return llama_vocab_type(vocabPointer) == LLAMA_VOCAB_TYPE_SPM
        }
        return addBos
    }

    /// End-of-sentence token id.
    public func eosToken() -> llama_token {
        llama_vocab_eos(vocabPointer)
    }

    /// Whether the token is an end-of-generation token (e.g. EOS/EOT).
    public func isEogToken(_ token: llama_token) -> Bool {
        llama_vocab_is_eog(vocabPointer, token)
    }

    /// Convert the provided text into tokens.
    /// - Parameters:
    ///   - addBos: Allow to add BOS/EOS if model is configured so.
    ///   - special: Allow tokenizing special/control tokens.
    public func tokenize(text: String, addBos: Bool, special: Bool) -> [llama_token] {
        guard !text.isEmpty else { return [] }

        let utf8Count = text.utf8.count
        guard utf8Count <= Int(Int32.max) else { return [] }

        let initialCapacity = Int64(utf8Count) + (addBos ? 1 : 0) + 1
        guard initialCapacity > 0, initialCapacity <= Int64(Int32.max) else { return [] }
        var bufferSize = Int32(initialCapacity)

        while true {
            var tokensBuffer = [llama_token](repeating: llama_token(), count: Int(bufferSize))
            let tokenCount = llama_tokenize(
                vocabPointer,
                text,
                Int32(utf8Count),
                &tokensBuffer,
                bufferSize,
                addBos,
                special
            )

            if let requiredSize = Self.nextTokenizationBufferSize(for: tokenCount, currentSize: bufferSize) {
                bufferSize = requiredSize
                continue
            }

            guard tokenCount >= 0, tokenCount <= bufferSize else { return [] }
            return Array(tokensBuffer.prefix(Int(tokenCount)))
        }
    }

    /// Convert tokens back to text (inverse of tokenize()).
    public func detokenize(tokens: [llama_token], removeSpecial: Bool = true, unparseSpecial: Bool = false) -> String {
        guard let initialSize = Self.initialDetokenizationBufferSize(tokenCount: tokens.count) else { return "" }
        var bufferSize = initialSize

        while true {
            var buffer = [CChar](repeating: 0, count: Int(bufferSize))
            let written = tokens.withUnsafeBufferPointer { ptr in
                llama_detokenize(
                    vocabPointer,
                    ptr.baseAddress,
                    Int32(tokens.count),
                    &buffer,
                    bufferSize,
                    removeSpecial,
                    unparseSpecial
                )
            }

            if let requiredSize = Self.nextDetokenizationBufferSize(for: written, currentSize: bufferSize) {
                bufferSize = requiredSize
                continue
            }

            guard written >= 0, written <= bufferSize else { return "" }
            let chars = Array(buffer.prefix(Int(written))) + [0]
            return String(cString: chars, encoding: .utf8) ?? ""
        }
    }

    /// Number of tokens in the vocabulary.
    public func vocabularySize() -> Int32 {
        llama_vocab_n_tokens(vocabPointer)
    }

    /// Apply chat template using the default model template.
    public func applyChatTemplate(to messages: [LlamaChatMessage], addAssistant: Bool? = nil) -> String {
        let template = llama_model_chat_template(modelPointer, nil)
        return renderChatTemplate(
            template: template,
            messages: messages,
            addAssistant: addAssistant ?? (messages.last?.role != .assistant)
        )
    }

    /// Apply chat template by template name found in the model.
    public func applyChatTemplate(name: String, to messages: [LlamaChatMessage], addAssistant: Bool? = nil) -> String {
        let template = name.withCString { namePointer in
            llama_model_chat_template(modelPointer, namePointer)
        }
        return renderChatTemplate(
            template: template,
            messages: messages,
            addAssistant: addAssistant ?? (messages.last?.role != .assistant)
        )
    }

    /// llama.cpp supports a zero-capacity probe for chat templates. Use that
    /// exact required size rather than estimating Swift Character counts and
    /// converting potentially overflowing Int values into Int32 capacities.
    private func renderChatTemplate(
        template: UnsafePointer<CChar>?,
        messages: [LlamaChatMessage],
        addAssistant: Bool
    ) -> String {
        var cMessages = messages.map { message -> llama_chat_message in
            llama_chat_message(role: strdup(message.role.rawValue), content: strdup(message.content))
        }
        defer {
            for message in cMessages {
                free(UnsafeMutablePointer(mutating: message.role))
                free(UnsafeMutablePointer(mutating: message.content))
            }
        }

        func apply(to buffer: UnsafeMutablePointer<CChar>?, capacity: Int32) -> Int32 {
            cMessages.withUnsafeBufferPointer { messageBuffer in
                llama_chat_apply_template(
                    template,
                    messageBuffer.baseAddress,
                    messageBuffer.count,
                    addAssistant,
                    buffer,
                    capacity
                )
            }
        }

        var bufferSize = apply(to: nil, capacity: 0)
        guard bufferSize >= 0 else { return "" }
        guard bufferSize > 0 else { return "" }

        while true {
            var buffer = [CChar](repeating: 0, count: Int(bufferSize))
            let written = buffer.withUnsafeMutableBufferPointer { bufferPointer in
                apply(to: bufferPointer.baseAddress, capacity: bufferSize)
            }

            if let requiredSize = Self.nextChatTemplateBufferSize(for: written, currentSize: bufferSize) {
                bufferSize = requiredSize
                continue
            }

            guard written >= 0, written <= bufferSize else { return "" }
            let chars = Array(buffer.prefix(Int(written))) + [0]
            return String(cString: chars, encoding: .utf8) ?? ""
        }
    }

    /// Total number of parameters in the model.
    public func numberOfParameters() -> UInt64 {
        return llama_model_n_params(modelPointer)
    }

    // MARK: - Model & Vocab Introspection

    public func ropeType() -> llama_rope_type { llama_model_rope_type(modelPointer) }
    public func nEmbed() -> Int32 { llama_model_n_embd(modelPointer) }
    public func nLayer() -> Int32 { llama_model_n_layer(modelPointer) }
    public func nHead() -> Int32 { llama_model_n_head(modelPointer) }
    public func nHeadKV() -> Int32 { llama_model_n_head_kv(modelPointer) }
    public func nSWA() -> Int32 { llama_model_n_swa(modelPointer) }
    public func ropeFreqScaleTrain() -> Float { llama_model_rope_freq_scale_train(modelPointer) }
    public func nClassifierOutputs() -> UInt32 { llama_model_n_cls_out(modelPointer) }
    public func classifierLabel(at index: UInt32) -> String? {
        guard let cstr = llama_model_cls_label(modelPointer, index) else { return nil }
        return String(cString: cstr)
    }
    public func modelSizeBytes() -> UInt64 { llama_model_size(modelPointer) }

    // MARK: - Adapter Factories

    public func loadLoraAdapter(path: String) -> LlamaLoraAdapter? {
        LlamaLoraAdapter(model: self, path: path)
    }
}
