#!/usr/bin/env python3
from pathlib import Path

# 1) Expose the already-loaded llama.cpp model identity through the internal
# actor without crossing a non-Sendable LlamaContext between actors.
llama_path = Path('Vendor/swift-llama-cpp/Sources/SwiftLlama/Llama.swift')
llama = llama_path.read_text()
identity_method = '''    func modelIdentitySnapshot() -> LlamaModelIdentitySnapshot {\n        model.identitySnapshot()\n    }\n\n'''
llama_marker = '''    /// Return the full processed token id sequence (prompt + generated).\n    func getProcessedTokenIds() -> [llama_token] { processedTokens }\n\n'''
if identity_method not in llama:
    if llama.count(llama_marker) != 1:
        raise SystemExit('Llama identity insertion marker is not unique')
    llama = llama.replace(llama_marker, llama_marker + identity_method, 1)
    llama_path.write_text(llama)

# 2) Expose a content-free public service receipt. This initializes the model at
# most once and reuses the same loaded target for the following agent request.
service_path = Path('Vendor/swift-llama-cpp/Sources/SwiftLlama/LlamaService.swift')
service = service_path.read_text()
service_method = '''    /// Returns content-free GGUF identity metadata for the exact model already\n    /// owned by this service. Calling this is also the fail-closed load gate used\n    /// by NovaForge before an exact-target model is admitted to an agent run.\n    public func modelIdentitySnapshot() async throws -> LlamaModelIdentitySnapshot {\n        let llama = try initializeLlamaIfNecessary()\n        return await llama.modelIdentitySnapshot()\n    }\n\n'''
service_marker = '''    // MARK: Methods\n\n'''
if service_method not in service:
    if service.count(service_marker) != 1:
        raise SystemExit('LlamaService identity insertion marker is not unique')
    service = service.replace(service_marker, service_method + service_marker, 1)
    service_path.write_text(service)

# 3) Define the exact-target identity policy in the existing app source so the
# Xcode target does not need a project-file mutation for one small policy type.
runtime_path = Path('AgentPad/Services/LocalModelRuntime.swift')
runtime = runtime_path.read_text()
policy = '''#if canImport(SwiftLlama)\nenum Qwen38ModelIdentityPolicy {\n    private static let minimum27BParameters: UInt64 = 24_000_000_000\n    private static let maximum27BParameters: UInt64 = 31_000_000_000\n\n    static func validationError(for identity: LlamaModelIdentitySnapshot) -> String? {\n        let labels = [\n            identity.name,\n            identity.basename,\n            identity.architecture,\n            identity.sizeLabel,\n            identity.description,\n        ].compactMap { $0 }.joined(separator: " | ").lowercased()\n\n        let compact = labels\n            .replacingOccurrences(of: "_", with: "")\n            .replacingOccurrences(of: "-", with: "")\n            .replacingOccurrences(of: " ", with: "")\n        let identifiesQwen38 = compact.contains("qwen3.8") || compact.contains("qwen38")\n        guard identifiesQwen38 else {\n            return "GGUF metadata does not identify Qwen 3.8."\n        }\n\n        guard (minimum27BParameters ... maximum27BParameters).contains(identity.parameterCount) else {\n            return "GGUF parameter count is not in the verified Qwen 3.8 27B class."\n        }\n        return nil\n    }\n}\n#endif\n\n'''
policy_marker = '''enum Qwen38ReleaseDiscoveryError: LocalizedError {\n'''
if policy not in runtime:
    if runtime.count(policy_marker) != 1:
        raise SystemExit('Qwen38 identity policy insertion marker is not unique')
    runtime = runtime.replace(policy_marker, policy + policy_marker, 1)

admission = '''        if variant.id.hasPrefix("qwen38:") {\n            let identity = try await service.modelIdentitySnapshot()\n            if let identityError = Qwen38ModelIdentityPolicy.validationError(for: identity) {\n                throw LocalModelRuntimeError.incompatibleDevice(\n                    "Exact Qwen 3.8 27B identity verification failed. \\(identityError)"\n                )\n            }\n        }\n'''
admission_marker = '''        loadedService = (variant.id, service)\n        return service\n'''
if admission not in runtime:
    if runtime.count(admission_marker) != 1:
        raise SystemExit('LocalModelClient service admission marker is not unique')
    runtime = runtime.replace(admission_marker, admission + admission_marker, 1)
runtime_path.write_text(runtime)

# 4) Add policy-only regressions to an already compiled XCTest file. These do
# not need a real model fixture and therefore stay fast/deterministic.
test_path = Path('AgentPadTests/AgentLocalModelProviderTransportTests.swift')
tests = test_path.read_text()
if '#if canImport(SwiftLlama)\nimport SwiftLlama\n#endif\n' not in tests:
    import_marker = 'import XCTest\n'
    if tests.count(import_marker) != 1:
        raise SystemExit('AgentPad test import marker is not unique')
    tests = tests.replace(import_marker, import_marker + '#if canImport(SwiftLlama)\nimport SwiftLlama\n#endif\n', 1)

test_block = '''\n#if canImport(SwiftLlama)\nextension AgentLocalModelProviderTransportTests {\n    func testQwen38IdentityPolicyAcceptsExact27BClass() {\n        let identity = LlamaModelIdentitySnapshot(\n            name: "Qwen 3.8 27B",\n            basename: "Qwen3.8-27B",\n            architecture: "qwen3.8",\n            sizeLabel: "27B",\n            description: "Qwen 3.8 27B Q1_0",\n            parameterCount: 27_400_000_000,\n            modelBytes: 3_900_000_000,\n            vocabularySize: 250_000,\n            layerCount: 64\n        )\n        XCTAssertNil(Qwen38ModelIdentityPolicy.validationError(for: identity))\n    }\n\n    func testQwen38IdentityPolicyRejectsRenamedQwen36() {\n        let identity = LlamaModelIdentitySnapshot(\n            name: "Qwen 3.6 27B",\n            basename: "Qwen3.6-27B",\n            architecture: "qwen3.6",\n            sizeLabel: "27B",\n            description: "Qwen 3.6 27B renamed file",\n            parameterCount: 27_000_000_000,\n            modelBytes: 3_900_000_000,\n            vocabularySize: 250_000,\n            layerCount: 64\n        )\n        XCTAssertNotNil(Qwen38ModelIdentityPolicy.validationError(for: identity))\n    }\n\n    func testQwen38IdentityPolicyRejectsWrongParameterClass() {\n        let identity = LlamaModelIdentitySnapshot(\n            name: "Qwen 3.8",\n            basename: "Qwen3.8-7B",\n            architecture: "qwen3.8",\n            sizeLabel: "7B",\n            description: "Qwen 3.8 7B",\n            parameterCount: 7_600_000_000,\n            modelBytes: 1_200_000_000,\n            vocabularySize: 250_000,\n            layerCount: 32\n        )\n        XCTAssertNotNil(Qwen38ModelIdentityPolicy.validationError(for: identity))\n    }\n}\n#endif\n'''
if test_block not in tests:
    tests = tests.rstrip() + '\n' + test_block
test_path.write_text(tests)

print('PASS: staged exact Qwen 3.8 27B loaded-GGUF identity gate')
