import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

@MainActor @Observable
private final class ModelsScreenState {
    var installed: [ModelManager.InstalledModel] = []
    var candidates: [ModelManager.Candidate] = []
    var jobs: [String: BackgroundModelDownloads.Job] = [:]
    var discovering = false
    var importer = false
    var error: String?
}

struct ModelsView: View {
    @Bindable var model: AppModel
    @State private var state = ModelsScreenState()
    private let downloads = BackgroundModelDownloads.shared

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                        .font(.title2)
                        .frame(width: 44, height: 44)
                        .glassEffect(.regular, in: .rect(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Local Model Library").font(.headline)
                        Text("GGUF • llama.cpp b10456 • Metal + CPU • stored on-device")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            if !state.jobs.isEmpty {
                Section("Transfers") {
                    ForEach(state.jobs.values.sorted(by: { $0.updated > $1.updated })) { job in
                        transferRow(job)
                    }
                }
            }

            Section("Installed") {
                if state.installed.isEmpty {
                    Text("No GGUF models installed yet.").foregroundStyle(.secondary)
                }
                ForEach(state.installed) { item in
                    HStack(spacing: 12) {
                        Image(systemName: item.name == model.currentModelName ? "checkmark.circle.fill" : "shippingbox.fill")
                            .foregroundStyle(item.name == model.currentModelName ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(item.name == model.currentModelName ? "Loaded" : "Load") { model.loadModel(item) }
                            .buttonStyle(.bordered)
                            .disabled(model.isGenerating || item.name == model.currentModelName)
                        Menu {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                Task { try? await model.models.delete(item); await reload() }
                            }
                        } label: { Image(systemName: "ellipsis.circle") }
                    }
                }
            }

            Section {
                Button { Task { await discover() } } label: {
                    HStack {
                        Label("Find fastest Qwen3.8-27B GGUF", systemImage: "sparkle.magnifyingglass")
                        Spacer()
                        if state.discovering { ProgressView().controlSize(.small) }
                    }
                }
                .disabled(state.discovering)

                Button { state.importer = true } label: {
                    Label("Import GGUF from Files", systemImage: "square.and.arrow.down")
                }
            } header: {
                Text("Add a model")
            } footer: {
                Text("Discovery is live. TriInfer ranks ultra-low-bit single-file Qwen3.8-27B GGUFs instead of freezing the app to an old URL. Large downloads use an OS-managed background session and reconnect after relaunch.")
            }

            if !state.candidates.isEmpty {
                Section("Qwen3.8-27B candidates") {
                    ForEach(state.candidates.prefix(10)) { candidate in
                        candidateRow(candidate)
                    }
                }
            }
        }
        .navigationTitle("Models")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }
            }
        }
        .task {
            await reload()
            seedShowcase()
            await monitorTransfers()
        }
        .fileImporter(
            isPresented: $state.importer,
            allowedContentTypes: [UTType(filenameExtension: "gguf") ?? .data]
        ) { result in
            guard case .success(let url) = result else { return }
            Task {
                do {
                    _ = try await model.models.importGGUF(from: url)
                    await reload()
                } catch {
                    state.error = error.localizedDescription
                }
            }
        }
        .alert(
            "Model Library",
            isPresented: Binding(get: { state.error != nil }, set: { if !$0 { state.error = nil } })
        ) {
            Button("OK", role: .cancel) { state.error = nil }
        } message: {
            Text(state.error ?? "")
        }
    }

    @ViewBuilder
    private func transferRow(_ job: BackgroundModelDownloads.Job) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.filename).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(transferSubtitle(job)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(job.state.rawValue.capitalized)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(job.state == .failed ? .red : .secondary)
            }

            if job.state == .downloading || job.state == .queued || job.state == .paused {
                ProgressView(value: job.fraction)
                HStack {
                    Text(job.fraction > 0 ? "\(Int(job.fraction * 100))%" : "Preparing…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if job.state == .paused {
                        Button("Resume") { downloads.resume(job.id) }
                    } else {
                        Button("Pause") { downloads.pause(job.id) }
                    }
                    Button("Cancel", role: .destructive) { downloads.cancel(job.id) }
                }
                .font(.caption)
            } else if job.state == .failed {
                HStack {
                    Text(job.error ?? "Download interrupted.")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                    Spacer()
                    Button("Retry") { downloads.resume(job.id) }
                    Button("Remove", role: .destructive) { downloads.cancel(job.id) }
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func candidateRow(_ candidate: ModelManager.Candidate) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(candidate.displayName).font(.subheadline.weight(.semibold)).lineLimit(2)
                    Text("\(candidate.quant) • \(candidate.repository)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if let size = candidate.size {
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            if let job = state.jobs[candidate.id] {
                Label(job.state == .paused ? "Paused in Transfers" : "Managed in Transfers", systemImage: "arrow.down.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            } else {
                Button { Task { await start(candidate) } } label: {
                    Label("Download", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 4)
    }

    private func reload() async {
        state.installed = (try? await model.models.installedModels()) ?? []
        refreshJobs()
        await model.refreshModelState()
    }

    private func discover() async {
        state.discovering = true
        do { state.candidates = try await model.models.discoverQwen38_27B() }
        catch { state.error = error.localizedDescription }
        state.discovering = false
    }

    private func start(_ candidate: ModelManager.Candidate) async {
        do {
            _ = try await model.models.destination(for: candidate)
            downloads.start(candidate: candidate)
            refreshJobs()
        } catch {
            state.error = error.localizedDescription
        }
    }

    private func monitorTransfers() async {
        while !Task.isCancelled {
            refreshJobs()
            let completed = state.jobs.values.filter { $0.state == .completed }
            for job in completed {
                guard let staging = downloads.consumeCompleted(job.id) else { continue }
                let candidate = ModelManager.Candidate(
                    repository: job.repository,
                    filename: job.filename,
                    downloadURL: job.url,
                    size: job.expectedBytes,
                    quant: job.quant
                )
                do {
                    _ = try await model.models.finalizeDownload(tempURL: staging, candidate: candidate)
                    await reload()
                } catch {
                    state.error = "Downloaded \(job.filename), but installation failed: \(error.localizedDescription)"
                }
            }
            try? await Task.sleep(for: .milliseconds(450))
        }
    }

    private func refreshJobs() {
        state.jobs = Dictionary(uniqueKeysWithValues: downloads.allJobs().map { ($0.id, $0) })
    }

    private func transferSubtitle(_ job: BackgroundModelDownloads.Job) -> String {
        let received = ByteCountFormatter.string(fromByteCount: job.receivedBytes, countStyle: .file)
        if job.totalBytes > 0 {
            let total = ByteCountFormatter.string(fromByteCount: job.totalBytes, countStyle: .file)
            return "\(job.quant) • \(received) of \(total)"
        }
        return "\(job.quant) • \(received)"
    }

    private func seedShowcase() {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("--ui-showcase"), args.contains("models"), state.candidates.isEmpty else { return }
        state.candidates = [
            .init(
                repository: "unsloth/Qwen3.8-27B-GGUF",
                filename: "Qwen3.8-27B-IQ2_XXS.gguf",
                downloadURL: URL(string: "https://huggingface.co")!,
                size: 8_360_000_000,
                quant: "IQ2_XXS"
            ),
            .init(
                repository: "community/Qwen3.8-27B-GGUF",
                filename: "Qwen3.8-27B-IQ2_M.gguf",
                downloadURL: URL(string: "https://huggingface.co/models")!,
                size: 10_200_000_000,
                quant: "IQ2_M"
            )
        ]
    }
}
