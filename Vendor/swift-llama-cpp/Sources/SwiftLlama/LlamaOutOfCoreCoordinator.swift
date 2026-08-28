import Darwin
import Foundation
import llama

public struct LlamaOutOfCoreSnapshot: Codable, Equatable, Sendable {
    public let modelBytes: UInt64
    public let stageCount: Int
    public let residentBudgetBytes: UInt64
    public let largestStageBytes: UInt64
    public let advisedReadBytes: UInt64
    public let advisedEvictionBytes: UInt64
    public let decodeCount: UInt64
    public let lastCompletedLayer: Int?
    public let planner: String
}

/// Experimental dense-model page scheduler. The model stays file-backed in
/// llama.cpp; this coordinator parses exact GGUF tensor ranges, selects one
/// callback boundary per transformer block, reads ahead the next block, and
/// releases completed block pages. It never claims a fixed RSS: the physical
/// receipt must prove the process footprint on the target device.
final class LlamaOutOfCoreCoordinator: @unchecked Sendable {
    private struct ByteRange: Sendable {
        let offset: Int
        let length: Int
    }

    private struct Stage: Sendable {
        let layer: Int
        let ranges: [ByteRange]
        let bytes: UInt64
    }

    private let fileDescriptor: Int32
    private let mapping: UnsafeMutableRawPointer
    private let modelBytes: Int
    private let residentBudgetBytes: UInt64
    private let stages: [Int: Stage]
    private let orderedLayers: [Int]
    private let pageSize: Int
    private let ioQueue = DispatchQueue(
        label: "com.joey.NovaForge.out-of-core-read-ahead",
        qos: .userInitiated
    )
    private let lock = NSLock()
    private var observedDuringPlanning: Set<Int> = []
    private var advisedReadBytes: UInt64 = 0
    private var advisedEvictionBytes: UInt64 = 0
    private var decodeCount: UInt64 = 0
    private var lastCompletedLayer: Int?
    private var lastEvidenceWrite = Date.distantPast

    static func make(
        modelPath: String,
        residentBudgetBytes: UInt64
    ) -> LlamaOutOfCoreCoordinator? {
        guard residentBudgetBytes > 0 else { return nil }
        return LlamaOutOfCoreCoordinator(
            modelPath: modelPath,
            residentBudgetBytes: residentBudgetBytes
        )
    }

    private init?(
        modelPath: String,
        residentBudgetBytes: UInt64
    ) {
        var parameters = gguf_init_params(no_alloc: true, ctx: nil)
        guard let gguf = modelPath.withCString({
            gguf_init_from_file($0, parameters)
        }) else { return nil }
        defer { gguf_free(gguf) }

        let dataOffset = gguf_get_data_offset(gguf)
        let tensorCount = gguf_get_n_tensors(gguf)
        var layerRanges: [Int: [ByteRange]] = [:]
        if tensorCount > 0 {
            for tensorIndex in 0..<tensorCount {
                guard let cName = gguf_get_tensor_name(gguf, tensorIndex) else {
                    continue
                }
                let name = String(cString: cName)
                guard let layer = Self.layerNumber(in: name) else { continue }
                let rawOffset = dataOffset + gguf_get_tensor_offset(gguf, tensorIndex)
                let rawLength = gguf_get_tensor_size(gguf, tensorIndex)
                guard rawLength > 0,
                      rawOffset <= Int.max,
                      rawLength <= Int.max else { continue }
                layerRanges[layer, default: []].append(
                    ByteRange(offset: Int(rawOffset), length: Int(rawLength))
                )
            }
        }

        var builtStages: [Int: Stage] = [:]
        for (layer, ranges) in layerRanges {
            let merged = Self.merge(ranges: ranges)
            let bytes = merged.reduce(UInt64(0)) {
                $0 + UInt64($1.length)
            }
            builtStages[layer] = Stage(
                layer: layer,
                ranges: merged,
                bytes: bytes
            )
        }
        guard !builtStages.isEmpty else { return nil }

        let descriptor = open(modelPath, O_RDONLY)
        guard descriptor >= 0 else { return nil }
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: modelPath
        ),
              let sizeNumber = attributes[.size] as? NSNumber,
              sizeNumber.uint64Value <= UInt64(Int.max) else {
            close(descriptor)
            return nil
        }
        let byteCount = Int(sizeNumber.uint64Value)
        let mapped = mmap(nil, byteCount, PROT_READ, MAP_PRIVATE, descriptor, 0)
        guard mapped != MAP_FAILED, let mapped else {
            close(descriptor)
            return nil
        }

        self.fileDescriptor = descriptor
        self.mapping = mapped
        self.modelBytes = byteCount
        self.residentBudgetBytes = residentBudgetBytes
        self.stages = builtStages
        self.orderedLayers = builtStages.keys.sorted()
        self.pageSize = Int(getpagesize())
        _ = fcntl(descriptor, F_RDAHEAD, 1)
        _ = madvise(mapped, byteCount, MADV_SEQUENTIAL)
    }

    deinit {
        ioQueue.sync {}
        munmap(mapping, modelBytes)
        close(fileDescriptor)
    }

    func beforeDecode() {
        lock.lock()
        observedDuringPlanning.removeAll(keepingCapacity: true)
        decodeCount += 1
        lock.unlock()
        guard let first = orderedLayers.first else { return }
        scheduleReadAhead(layer: first)
        if orderedLayers.count > 1 {
            scheduleReadAhead(layer: orderedLayers[1])
        }
    }

    /// `ask == true` is graph planning; selecting one node per layer creates a
    /// post-compute callback where eviction/read-ahead can advance in order.
    func evaluate(tensorName: String, ask: Bool) -> Bool {
        guard let layer = Self.layerNumber(in: tensorName),
              stages[layer] != nil else { return ask ? false : true }
        if ask {
            lock.lock()
            let inserted = observedDuringPlanning.insert(layer).inserted
            lock.unlock()
            return inserted
        }

        lock.lock()
        lastCompletedLayer = layer
        lock.unlock()
        if let index = orderedLayers.firstIndex(of: layer) {
            if index > 0 { scheduleEviction(layer: orderedLayers[index - 1]) }
            if index + 1 < orderedLayers.count {
                scheduleReadAhead(layer: orderedLayers[index + 1])
            }
        }
        return true
    }

    func finishedDecode() {
        let now = Date()
        lock.lock()
        let shouldWrite = now.timeIntervalSince(lastEvidenceWrite) >= 1
        if shouldWrite { lastEvidenceWrite = now }
        let receipt = snapshotLocked()
        lock.unlock()
        if shouldWrite { Self.write(receipt) }
    }

    func snapshot() -> LlamaOutOfCoreSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshotLocked()
    }

    private func snapshotLocked() -> LlamaOutOfCoreSnapshot {
        LlamaOutOfCoreSnapshot(
            modelBytes: UInt64(modelBytes),
            stageCount: stages.count,
            residentBudgetBytes: residentBudgetBytes,
            largestStageBytes: stages.values.map(\.bytes).max() ?? 0,
            advisedReadBytes: advisedReadBytes,
            advisedEvictionBytes: advisedEvictionBytes,
            decodeCount: decodeCount,
            lastCompletedLayer: lastCompletedLayer,
            planner: "gguf-layer-ranges+mmap+MADV_WILLNEED/DONTNEED+serial-read-ahead"
        )
    }

    private func scheduleReadAhead(layer: Int) {
        guard let stage = stages[layer],
              stage.bytes <= residentBudgetBytes else { return }
        ioQueue.async { [weak self] in
            guard let self else { return }
            var advised: UInt64 = 0
            for range in stage.ranges {
                let aligned = self.aligned(range)
                if madvise(
                    self.mapping.advanced(by: aligned.offset),
                    aligned.length,
                    MADV_WILLNEED
                ) == 0 {
                    advised += UInt64(range.length)
                }
            }
            self.lock.lock()
            self.advisedReadBytes += advised
            self.lock.unlock()
        }
    }

    private func scheduleEviction(layer: Int) {
        guard let stage = stages[layer] else { return }
        ioQueue.async { [weak self] in
            guard let self else { return }
            var advised: UInt64 = 0
            for range in stage.ranges {
                let aligned = self.aligned(range)
                if madvise(
                    self.mapping.advanced(by: aligned.offset),
                    aligned.length,
                    MADV_DONTNEED
                ) == 0 {
                    advised += UInt64(range.length)
                }
            }
            self.lock.lock()
            self.advisedEvictionBytes += advised
            self.lock.unlock()
        }
    }

    private func aligned(_ range: ByteRange) -> ByteRange {
        let start = (range.offset / pageSize) * pageSize
        let rawEnd = range.offset + range.length
        let end = min(modelBytes, ((rawEnd + pageSize - 1) / pageSize) * pageSize)
        return ByteRange(offset: start, length: max(0, end - start))
    }

    private static func layerNumber(in name: String) -> Int? {
        let parts = name.split(separator: ".")
        if let block = parts.firstIndex(of: "blk"), block + 1 < parts.count {
            return Int(parts[block + 1])
        }
        for marker in ["l_out-", "layer-", "layer_"] {
            if let range = name.range(of: marker) {
                return Int(name[range.upperBound...].prefix { $0.isNumber })
            }
        }
        return nil
    }

    private static func merge(ranges: [ByteRange]) -> [ByteRange] {
        let sorted = ranges.sorted { $0.offset < $1.offset }
        var result: [ByteRange] = []
        for range in sorted {
            guard let last = result.last else {
                result.append(range)
                continue
            }
            let lastEnd = last.offset + last.length
            if range.offset <= lastEnd + 65_536 {
                result[result.count - 1] = ByteRange(
                    offset: last.offset,
                    length: max(lastEnd, range.offset + range.length) - last.offset
                )
            } else {
                result.append(range)
            }
        }
        return result
    }

    private static func write(_ snapshot: LlamaOutOfCoreSnapshot) {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return }
        let directory = base
            .appendingPathComponent("LocalAI", isDirectory: true)
            .appendingPathComponent("OutOfCore", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(snapshot).write(
                to: directory.appendingPathComponent("latest.json"),
                options: .atomic
            )
        } catch {
            // Evidence writing must not take down inference. The physical
            // protocol treats a missing receipt as a failed admission.
        }
    }
}

let llamaOutOfCoreEvalCallback: ggml_backend_sched_eval_callback = {
    tensor, ask, userData in
    guard let tensor, let userData,
          let cName = ggml_get_name(tensor) else { return ask ? false : true }
    let coordinator = Unmanaged<LlamaOutOfCoreCoordinator>
        .fromOpaque(userData)
        .takeUnretainedValue()
    return coordinator.evaluate(tensorName: String(cString: cName), ask: ask)
}
