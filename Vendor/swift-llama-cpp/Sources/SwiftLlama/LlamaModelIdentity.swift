import Foundation
import llama

/// Content-free identity metadata read from a loaded GGUF.
///
/// This deliberately exposes only model-card/architecture facts. It never
/// contains prompts, token ids, generated text, file paths, or user content.
public struct LlamaModelIdentitySnapshot: Equatable, Sendable {
    public let name: String?
    public let basename: String?
    public let architecture: String?
    public let sizeLabel: String?
    public let description: String
    public let parameterCount: UInt64
    public let modelBytes: UInt64
    public let vocabularySize: Int32
    public let layerCount: Int32

    public init(
        name: String?,
        basename: String?,
        architecture: String?,
        sizeLabel: String?,
        description: String,
        parameterCount: UInt64,
        modelBytes: UInt64,
        vocabularySize: Int32,
        layerCount: Int32
    ) {
        self.name = name
        self.basename = basename
        self.architecture = architecture
        self.sizeLabel = sizeLabel
        self.description = description
        self.parameterCount = parameterCount
        self.modelBytes = modelBytes
        self.vocabularySize = vocabularySize
        self.layerCount = layerCount
    }
}

extension LlamaModel {
    /// Reads one scalar GGUF metadata value through llama.cpp's stable public
    /// API. The buffer grows to the exact size reported by llama.cpp so future
    /// model names/architecture strings are not silently truncated.
    public func metadataString(forKey key: String) -> String? {
        func read(into buffer: inout [CChar]) -> Int32 {
            key.withCString { cKey in
                buffer.withUnsafeMutableBufferPointer { storage in
                    guard let baseAddress = storage.baseAddress else { return -1 }
                    return llama_model_meta_val_str(
                        modelPointer,
                        cKey,
                        baseAddress,
                        storage.count
                    )
                }
            }
        }

        var buffer = [CChar](repeating: 0, count: 256)
        var count = read(into: &buffer)
        guard count >= 0 else { return nil }
        if Int(count) >= buffer.count {
            buffer = [CChar](repeating: 0, count: Int(count) + 1)
            count = read(into: &buffer)
            guard count >= 0 else { return nil }
        }
        let value = Self.identityString(from: buffer)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    public func identitySnapshot() -> LlamaModelIdentitySnapshot {
        LlamaModelIdentitySnapshot(
            name: metadataString(forKey: "general.name"),
            basename: metadataString(forKey: "general.basename"),
            architecture: metadataString(forKey: "general.architecture"),
            sizeLabel: metadataString(forKey: "general.size_label"),
            description: description(),
            parameterCount: numberOfParameters(),
            modelBytes: modelSizeBytes(),
            vocabularySize: vocabularySize(),
            layerCount: nLayer()
        )
    }

    private static func identityString(from buffer: [CChar]) -> String {
        let units = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: units, as: UTF8.self)
    }
}
