import Foundation
import llama

public struct LlamaBackendCapabilities: Equatable, Sendable {
    public let hasCPU: Bool
    public let hasMetal: Bool
    public let metalDeviceNames: [String]
    public let supportsGPUOffload: Bool
    public var supportsMetalPartial: Bool { hasMetal && supportsGPUOffload }
    public var supportsMetalFull: Bool { supportsMetalPartial }
}

public struct LlamaComputeSelection: Equatable, Sendable {
    public let requested: LlamaComputeMode
    public let effective: LlamaComputeMode
    public let gpuLayerCount: Int32
    public let reason: String
}

public struct LlamaRuntimeFeatureReport: Equatable, Sendable {
    public let kvCacheQuantizationAvailable: Bool
    public let flashAttentionAvailable: Bool
    public let speculativeDecodingEnabled: Bool
    public let speculativeDecodingReason: String
}

public enum LlamaBackend {
    private static let lifecycleLock = NSLock()
    nonisolated(unsafe) private static var lifecycleUsers = 0

    /// Initialize the llama + ggml backend. Call once at program start.
    public static func initialize() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        if lifecycleUsers == 0 { llama_backend_init() }
        lifecycleUsers += 1
    }
    /// Free the backend. Call once at program end.
    public static func shutdown() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard lifecycleUsers > 0 else { return }
        lifecycleUsers -= 1
        if lifecycleUsers == 0 { llama_backend_free() }
    }
    /// Whether mmap/mlock/gpu offload/rpc are supported by the compiled library.
    public static var supportsMmap: Bool { llama_supports_mmap() }
    public static var supportsMlock: Bool { llama_supports_mlock() }
    public static var supportsGpuOffload: Bool { llama_supports_gpu_offload() }
    public static var supportsRpc: Bool { llama_supports_rpc() }

    /// Enumerate the linked backend rather than treating every Apple target as
    /// Metal-capable. The hybrid simulator slice can be CPU-only.
    public static var capabilities: LlamaBackendCapabilities {
        var hasCPU = false
        var hasMetal = false
        var metalNames: [String] = []
        for index in 0 ..< ggml_backend_dev_count() {
            guard let device = ggml_backend_dev_get(index),
                  let name = ggml_backend_dev_name(device)
            else { continue }
            let deviceName = String(cString: name)
            if ggml_backend_dev_type(device) == GGML_BACKEND_DEVICE_TYPE_CPU {
                hasCPU = true
            }
            if deviceName.lowercased().contains("metal") {
                hasMetal = true
                metalNames.append(deviceName)
            }
        }
        return .init(
            hasCPU: hasCPU,
            hasMetal: hasMetal,
            metalDeviceNames: metalNames,
            supportsGPUOffload: supportsGpuOffload
        )
    }

    public static var runtimeFeatures: LlamaRuntimeFeatureReport {
        .init(
            kvCacheQuantizationAvailable: true,
            flashAttentionAvailable: supportsGpuOffload,
            speculativeDecodingEnabled: false,
            speculativeDecodingReason:
                "Disabled: the vendored public C API has no exact DSpark/speculative draft route"
        )
    }

    public static func select(
        _ requested: LlamaComputeMode,
        gpuLayerCount: Int32
    ) -> LlamaComputeSelection {
        let caps = capabilities
        switch requested {
        case .cpu:
            return .init(
                requested: requested,
                effective: .cpu,
                gpuLayerCount: 0,
                reason: "CPU explicitly selected"
            )
        case .metalPartial where caps.supportsMetalPartial:
            return .init(
                requested: requested,
                effective: .metalPartial,
                gpuLayerCount: max(0, gpuLayerCount),
                reason: "Metal detected; using requested partial offload"
            )
        case .metalFull where caps.supportsMetalFull:
            return .init(
                requested: requested,
                effective: .metalFull,
                gpuLayerCount: -1,
                reason: "Metal detected; requesting full offload"
            )
        default:
            return .init(
                requested: requested,
                effective: .cpu,
                gpuLayerCount: 0,
                reason: "Requested Metal mode is unavailable in the active backend"
            )
        }
    }

    static func acquire() -> LlamaBackendLease {
        LlamaBackendLease()
    }
    /// Maximum devices and parallel sequences
    public static var maxDevices: Int { Int(llama_max_devices()) }
    public static var maxParallelSequences: Int { Int(llama_max_parallel_sequences()) }

    /// Initialize NUMA with a given strategy.
    public static func numaInit(_ strategy: ggml_numa_strategy) { llama_numa_init(strategy) }

    /// Microsecond timer from llama.cpp
    public static func timeMicros() -> Int64 { llama_time_us() }

    /// Return system info string provided by llama.cpp
    public static func systemInfo() -> String {
        guard let c = llama_print_system_info() else { return "" }
        return String(cString: c)
    }

    /// Attach the library-managed auto threadpool to a context.
    public static func attachAutoThreadpool(to context: LlamaContext) {
        llama_attach_threadpool(context.contextPointer, nil, nil)
    }

    /// Detach any threadpools from the context.
    public static func detachThreadpool(from context: LlamaContext) {
        llama_detach_threadpool(context.contextPointer)
    }
}

final class LlamaBackendLease {
    init() { LlamaBackend.initialize() }
    deinit { LlamaBackend.shutdown() }
}
