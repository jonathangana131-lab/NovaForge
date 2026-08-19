import Foundation
import llama

/// Source-compatibility wrappers that remain supported by the pinned llama.cpp b10456 C API.
///
/// Keep these in a small extension so migration-specific model/tokenization changes in `LlamaModel.swift`
/// can evolve without silently deleting public wrapper capabilities that b10456 still exports.
public extension LlamaModel {
    func hasEncoder() -> Bool { llama_model_has_encoder(modelPointer) }
    func hasDecoder() -> Bool { llama_model_has_decoder(modelPointer) }
    func decoderStartToken() -> llama_token { llama_model_decoder_start_token(modelPointer) }
    func isRecurrent() -> Bool { llama_model_is_recurrent(modelPointer) }
    func isDiffusion() -> Bool { llama_model_is_diffusion(modelPointer) }

    func vocabType() -> llama_vocab_type { llama_vocab_type(vocabPointer) }
    func vocabScore(for token: llama_token) -> Float { llama_vocab_get_score(vocabPointer, token) }
    func vocabAttr(for token: llama_token) -> llama_token_attr { llama_vocab_get_attr(vocabPointer, token) }
    func isControl(token: llama_token) -> Bool { llama_vocab_is_control(vocabPointer, token) }
    func sepToken() -> llama_token { llama_vocab_sep(vocabPointer) }
    func nlToken() -> llama_token { llama_vocab_nl(vocabPointer) }
    func padToken() -> llama_token { llama_vocab_pad(vocabPointer) }
    func maskToken() -> llama_token { llama_vocab_mask(vocabPointer) }
    func addEos() -> Bool { llama_vocab_get_add_eos(vocabPointer) }
    func addSep() -> Bool { llama_vocab_get_add_sep(vocabPointer) }
    func fimPre() -> llama_token { llama_vocab_fim_pre(vocabPointer) }
    func fimSuf() -> llama_token { llama_vocab_fim_suf(vocabPointer) }
    func fimMid() -> llama_token { llama_vocab_fim_mid(vocabPointer) }
    func fimPad() -> llama_token { llama_vocab_fim_pad(vocabPointer) }
    func fimRep() -> llama_token { llama_vocab_fim_rep(vocabPointer) }
    func fimSep() -> llama_token { llama_vocab_fim_sep(vocabPointer) }

    func metaValue(forKey key: String) -> String? {
        readCompatibilityString { buffer, capacity in
            llama_model_meta_val_str(modelPointer, key, buffer, capacity)
        }
    }

    func metaCount() -> Int32 { llama_model_meta_count(modelPointer) }

    func metaKey(at index: Int32) -> String? {
        readCompatibilityString { buffer, capacity in
            llama_model_meta_key_by_index(modelPointer, index, buffer, capacity)
        }
    }

    func metaValue(at index: Int32) -> String? {
        readCompatibilityString { buffer, capacity in
            llama_model_meta_val_str_by_index(modelPointer, index, buffer, capacity)
        }
    }

    func save(to path: String) {
        llama_model_save_to_file(modelPointer, path)
    }

    func builtinChatTemplates(maxCount: Int = 64) -> [String] {
        guard maxCount > 0 else { return [] }
        var templates = Array<UnsafePointer<CChar>?>(repeating: nil, count: maxCount)
        let count = templates.withUnsafeMutableBufferPointer { buffer in
            llama_chat_builtin_templates(buffer.baseAddress, size_t(maxCount))
        }
        guard count > 0 else { return [] }

        return templates.prefix(min(Int(count), maxCount)).compactMap { pointer in
            pointer.map { String(cString: $0) }
        }
    }

    @discardableResult
    static func quantizeModel(
        inputPath: String,
        outputPath: String,
        params: inout llama_model_quantize_params
    ) -> UInt32 {
        llama_model_quantize(inputPath, outputPath, &params)
    }

    static func defaultQuantizeParams() -> llama_model_quantize_params {
        llama_model_quantize_default_params()
    }

    static func splitPath(pathPrefix: String, splitNo: Int32, splitCount: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 1_024)
        let length = pathPrefix.withCString { pathPointer in
            llama_split_path(
                &buffer,
                buffer.count,
                pathPointer,
                splitNo,
                splitCount
            )
        }
        guard length > 0, Int(length) < buffer.count else { return "" }
        return String(cString: buffer)
    }

    static func splitPrefix(splitPath: String, splitNo: Int32, splitCount: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 1_024)
        let length = splitPath.withCString { pathPointer in
            llama_split_prefix(
                &buffer,
                buffer.count,
                pathPointer,
                splitNo,
                splitCount
            )
        }
        guard length > 0, Int(length) < buffer.count else { return nil }
        return String(cString: buffer)
    }

    private func readCompatibilityString(
        _ read: (UnsafeMutablePointer<CChar>, Int) -> Int32
    ) -> String? {
        var capacity = 512

        while capacity <= 64 * 1_024 {
            var buffer = [CChar](repeating: 0, count: capacity)
            let result = buffer.withUnsafeMutableBufferPointer { bufferPointer in
                guard let baseAddress = bufferPointer.baseAddress else { return Int32(-1) }
                return read(baseAddress, capacity)
            }
            guard result >= 0 else { return nil }

            if Int(result) >= capacity {
                let required = Int(result) + 1
                guard required > capacity, required <= 64 * 1_024 else { return nil }
                capacity = required
                continue
            }

            return String(cString: buffer)
        }

        return nil
    }
}
