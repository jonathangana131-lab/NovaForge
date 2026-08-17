//
//  LlamaSampler.swift
//  LlamaSwift
//
//  Created by Piotr Gorzelany on 26/09/2024.
//


import Foundation
import llama

/// A wrapper for the `llama.cpp` sampling chain (`llama_sampler_chain`).
///
/// This class configures and manages a series of samplers to control the token generation process.
public final class LlamaSampler {
    private let samplerPointer: UnsafeMutablePointer<llama_sampler>

    public init(config: LlamaSamplingConfig, model: LlamaModel) throws {
        let sparams = llama_sampler_chain_default_params()
        guard let samplerPointer = llama_sampler_chain_init(sparams) else {
            throw LlamaError.couldNotInitializeContext
        }

        if let grammarConfig = config.grammarConfig {
            guard let grammarSampler = llama_sampler_init_grammar(
                model.vocabPointer,
                grammarConfig.grammar,
                grammarConfig.grammarRoot
            ) else {
                llama_sampler_free(samplerPointer)
                throw LlamaError.invalidGrammar
            }
            llama_sampler_chain_add(samplerPointer, grammarSampler)
        }

        if let topK = config.topK {
            let topKSampler = llama_sampler_init_top_k(topK)
            llama_sampler_chain_add(samplerPointer, topKSampler)
        }

        let topPSampler = llama_sampler_init_top_p(config.topP, config.minKeep)
        llama_sampler_chain_add(samplerPointer, topPSampler)

        if let penaltyConfig = config.repetitionPenaltyConfig, penaltyConfig.lastN > 0 {
            let penaltiesSampler = llama_sampler_init_penalties(
                model.vocabularySize(),
                penaltyConfig.lastN,
                penaltyConfig.repeatPenalty,
                penaltyConfig.freqPenalty,
                penaltyConfig.presentPenalty
            )
            llama_sampler_chain_add(samplerPointer, penaltiesSampler)
        }

        let tempSampler = llama_sampler_init_temp(config.temperature)
        llama_sampler_chain_add(samplerPointer, tempSampler)

        let distSampler = llama_sampler_init_dist(config.seed)
        llama_sampler_chain_add(samplerPointer, distSampler)
        self.samplerPointer = samplerPointer
    }

    deinit {
        llama_sampler_free(samplerPointer)
    }

    public func sample(context: LlamaContext) -> llama_token {
        llama_sampler_sample(samplerPointer, context.contextPointer, -1)
    }

    public func accept(token: llama_token) {
        llama_sampler_accept(samplerPointer, token)
    }

    public func name() -> String {
        guard let c = llama_sampler_name(samplerPointer) else { return "" }
        return String(cString: c)
    }

    public func reset() { llama_sampler_reset(samplerPointer) }

    public func clone() -> LlamaSampler? {
        guard let cloned = llama_sampler_clone(samplerPointer) else { return nil }
        return LlamaSampler(adopting: cloned)
    }

    private init(adopting pointer: UnsafeMutablePointer<llama_sampler>) {
        self.samplerPointer = pointer
    }

    public func perfDataDescription() -> String {
        llama_perf_sampler_print(samplerPointer)
        return ""
    }

    public func count() -> Int { Int(llama_sampler_chain_n(samplerPointer)) }

    public func name(at index: Int32) -> String {
        guard let s = llama_sampler_chain_get(samplerPointer, index) else { return "" }
        guard let c = llama_sampler_name(s) else { return "" }
        return String(cString: c)
    }

    public func remove(at index: Int32) {
        _ = llama_sampler_chain_remove(samplerPointer, index)
    }
}
