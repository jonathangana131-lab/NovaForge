import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

actor DownloadService {
    private var active: URLSessionDownloadTask?
    func progress() -> Double { active?.progress.fractionCompleted ?? 0 }
    func cancel() { active?.cancel(); active = nil }

    func download(_ url: URL) async throws -> URL {
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("TriInfer-\(UUID().uuidString).gguf.part")
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = URLSession.shared.downloadTask(with: url) { temp, response, error in
                    if let error { continuation.resume(throwing: error); return }
                    guard let temp, let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                        continuation.resume(throwing: URLError(.badServerResponse)); return
                    }
                    do {
                        try? FileManager.default.removeItem(at: staging)
                        try FileManager.default.moveItem(at: temp, to: staging)
                        continuation.resume(returning: staging)
                    } catch { continuation.resume(throwing: error) }
                }
                active = task; task.resume()
            }
        } onCancel: { Task { await self.cancel() } }
    }
}

@MainActor @Observable
private final class ModelsScreenState {
    var installed: [ModelManager.InstalledModel] = []
    var candidates: [ModelManager.Candidate] = []
    var discovering = false
    var downloadingID: String?
    var downloadProgress = 0.0
    var importer = false
    var error: String?
}

struct ModelsView: View {
    @Bindable var model: AppModel
    @State private var state = ModelsScreenState()
    private let downloads = DownloadService()

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "iphone.gen3.radiowaves.left.and.right").font(.title2).frame(width: 44, height: 44).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Local Model Library").font(.headline)
                        Text("GGUF • llama.cpp • Metal + CPU • stored on-device").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 4)
            }

            Section("Installed") {
                if state.installed.isEmpty {
                    Text("No GGUF models installed yet.").foregroundStyle(.secondary)
                }
                ForEach(state.installed) { item in
                    HStack(spacing: 12) {
                        Image(systemName: item.name == model.currentModelName ? "checkmark.circle.fill" : "shippingbox.fill").foregroundStyle(item.name == model.currentModelName ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 3) { Text(item.name).font(.subheadline.weight(.semibold)).lineLimit(1); Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button(item.name == model.currentModelName ? "Loaded" : "Load") { model.loadModel(item) }.buttonStyle(.bordered).disabled(model.isGenerating || item.name == model.currentModelName)
                        Menu { Button("Delete", systemImage: "trash", role: .destructive) { Task { try? await model.models.delete(item); await reload() } } } label: { Image(systemName: "ellipsis.circle") }
                    }
                }
            }

            Section {
                Button { Task { await discover() } } label: {
                    HStack { Label("Find fastest Qwen3.8-27B GGUF", systemImage: "sparkle.magnifyingglass"); Spacer(); if state.discovering { ProgressView().controlSize(.small) } }
                }.disabled(state.discovering)
                Button { state.importer = true } label: { Label("Import GGUF from Files", systemImage: "square.and.arrow.down") }
            } header: { Text("Add a model") } footer: { Text("Discovery is live: TriInfer ranks ultra-low-bit single-file GGUF candidates instead of hardcoding a model URL that can go stale.") }

            if !state.candidates.isEmpty {
                Section("Qwen3.8-27B candidates") {
                    ForEach(state.candidates.prefix(10)) { candidate in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 3) { Text(candidate.displayName).font(.subheadline.weight(.semibold)).lineLimit(2); Text("\(candidate.quant) • \(candidate.repository)").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                Spacer()
                                if let size = candidate.size { Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)).font(.caption.weight(.medium)).foregroundStyle(.secondary) }
                            }
                            if state.downloadingID == candidate.id {
                                ProgressView(value: state.downloadProgress).progressViewStyle(.linear)
                                HStack { Text(state.downloadProgress > 0 ? "\(Int(state.downloadProgress * 100))%" : "Starting…").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Cancel", role: .destructive) { Task { await downloads.cancel(); state.downloadingID = nil } } }
                            } else {
                                Button { Task { await download(candidate) } } label: { Label("Download", systemImage: "arrow.down.circle.fill") }.buttonStyle(.borderedProminent)
                            }
                        }.padding(.vertical, 4)
                    }
                }
            }
        }
        .navigationTitle("Models")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") } } }
        .task { await reload(); seedShowcase() }
        .fileImporter(isPresented: $state.importer, allowedContentTypes: [UTType(filenameExtension: "gguf") ?? .data]) { result in
            guard case .success(let url) = result else { return }
            Task {
                do { _ = try await model.models.importGGUF(from: url); await reload() }
                catch { state.error = error.localizedDescription }
            }
        }
        .alert("Model Library", isPresented: Binding(get: { state.error != nil }, set: { if !$0 { state.error = nil } })) { Button("OK", role: .cancel) { state.error = nil } } message: { Text(state.error ?? "") }
    }

    private func reload() async {
        state.installed = (try? await model.models.installedModels()) ?? []
        await model.refreshModelState()
    }

    private func discover() async {
        state.discovering = true
        do { state.candidates = try await model.models.discoverQwen38_27B() }
        catch { state.error = error.localizedDescription }
        state.discovering = false
    }

    private func download(_ candidate: ModelManager.Candidate) async {
        state.downloadingID = candidate.id; state.downloadProgress = 0
        do {
            _ = try await model.models.destination(for: candidate)
            let poll = Task {
                while !Task.isCancelled {
                    let p = await downloads.progress(); await MainActor.run { state.downloadProgress = p }
                    try? await Task.sleep(for: .milliseconds(220))
                }
            }
            let staging = try await downloads.download(candidate.downloadURL)
            poll.cancel()
            _ = try await model.models.finalizeDownload(tempURL: staging, candidate: candidate)
            await reload()
        } catch is CancellationError { }
        catch { state.error = error.localizedDescription }
        state.downloadingID = nil; state.downloadProgress = 0
    }

    private func seedShowcase() {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("--ui-showcase"), args.contains("models"), state.candidates.isEmpty else { return }
        state.candidates = [
            .init(repository: "unsloth/Qwen3.8-27B-GGUF", filename: "Qwen3.8-27B-IQ2_XXS.gguf", downloadURL: URL(string: "https://huggingface.co")!, size: 8_360_000_000, quant: "IQ2_XXS"),
            .init(repository: "community/Qwen3.8-27B-GGUF", filename: "Qwen3.8-27B-IQ2_M.gguf", downloadURL: URL(string: "https://huggingface.co/models")!, size: 10_200_000_000, quant: "IQ2_M")
        ]
    }
}
