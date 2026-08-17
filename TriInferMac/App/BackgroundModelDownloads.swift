import Foundation
import UIKit

/// Durable, OS-managed model downloads. Background URLSession keeps large GGUF transfers alive
/// through suspension and normal process termination; job metadata is persisted so the Models UI
/// can reconnect after relaunch instead of starting a multi-gigabyte file from zero.
final class BackgroundModelDownloads: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = BackgroundModelDownloads()
    static let sessionIdentifier = "ai.triinfer.code.model-downloads.v1"

    enum TransferError: LocalizedError {
        case giantTransferAlreadyActive(String)
        var errorDescription: String? {
            switch self {
            case .giantTransferAlreadyActive(let filename):
                "A large model transfer is already active (\(filename)). Finish, pause/cancel, or install it before starting another 27B download."
            }
        }
    }

    struct Job: Codable, Sendable, Hashable, Identifiable {
        enum State: String, Codable, Sendable { case queued, downloading, paused, completed, failed }
        var id: String
        var repository: String
        var filename: String
        var url: URL
        var quant: String
        var expectedBytes: Int64?
        var taskIdentifier: Int
        var state: State
        var fraction: Double
        var receivedBytes: Int64
        var totalBytes: Int64
        var stagingPath: String?
        var error: String?
        var updated: Date
    }

    private let lock = NSLock()
    private var jobs: [String: Job] = [:]
    private var taskToJob: [Int: String] = [:]
    private var completionHandler: (() -> Void)?
    private let jobsURL: URL
    private let stagingDirectory: URL

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.allowsCellularAccess = true
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForResource = 60 * 60 * 24 * 7
        configuration.httpMaximumConnectionsPerHost = 1
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    private override init() {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        let root = support.appendingPathComponent("ModelDownloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        stagingDirectory = root.appendingPathComponent("Staging", isDirectory: true)
        try? FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        jobsURL = root.appendingPathComponent("jobs.json")
        super.init()

        for directory in [root, stagingDirectory] {
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            var mutable = directory
            try? mutable.setResourceValues(values)
        }

        loadJobs()
        _ = session
        reconnectTasks()
    }

    func start(candidate: ModelManager.Candidate) throws {
        lock.lock()
        if let existing = jobs[candidate.id] {
            lock.unlock()
            if existing.state == .paused || existing.state == .failed { resume(candidate.id) }
            return
        }

        let giant = (candidate.size ?? 2_000_000_000) >= 2_000_000_000
        let conflicting = giant ? jobs.values.first(where: { job in
            job.id != candidate.id && job.state != .failed
                && ((job.expectedBytes ?? 2_000_000_000) >= 2_000_000_000)
        }) : nil
        lock.unlock()
        if let conflicting { throw TransferError.giantTransferAlreadyActive(conflicting.filename) }

        let task = session.downloadTask(with: candidate.downloadURL)
        task.taskDescription = candidate.id
        let job = Job(
            id: candidate.id,
            repository: candidate.repository,
            filename: candidate.filename,
            url: candidate.downloadURL,
            quant: candidate.quant,
            expectedBytes: candidate.size,
            taskIdentifier: task.taskIdentifier,
            state: .queued,
            fraction: 0,
            receivedBytes: 0,
            totalBytes: candidate.size ?? -1,
            stagingPath: nil,
            error: nil,
            updated: Date()
        )
        mutate { jobs in
            jobs[job.id] = job
            self.taskToJob[task.taskIdentifier] = job.id
        }
        task.resume()
    }

    func pause(_ id: String) {
        session.getAllTasks { [weak self] tasks in
            guard let self else { return }
            if let task = tasks.first(where: { $0.taskDescription == id }) {
                task.suspend()
                self.update(id) { $0.state = .paused; $0.updated = Date() }
            }
        }
    }

    func resume(_ id: String) {
        session.getAllTasks { [weak self] tasks in
            guard let self else { return }
            if let task = tasks.first(where: { $0.taskDescription == id }) {
                task.resume()
                self.update(id) { $0.state = .downloading; $0.error = nil; $0.updated = Date() }
                return
            }
            guard let job = self.snapshot(id) else { return }
            let task = self.session.downloadTask(with: job.url)
            task.taskDescription = id
            self.update(id) {
                $0.taskIdentifier = task.taskIdentifier
                $0.state = .queued
                $0.error = nil
                $0.updated = Date()
            }
            self.lock.lock(); self.taskToJob[task.taskIdentifier] = id; self.lock.unlock()
            task.resume()
        }
    }

    func cancel(_ id: String) {
        session.getAllTasks { [weak self] tasks in
            guard let self else { return }
            tasks.first(where: { $0.taskDescription == id })?.cancel()
            self.lock.lock()
            if let path = self.jobs[id]?.stagingPath { try? FileManager.default.removeItem(atPath: path) }
            self.jobs.removeValue(forKey: id)
            self.persistLocked()
            self.lock.unlock()
        }
    }

    func snapshot(_ id: String) -> Job? {
        lock.lock(); defer { lock.unlock() }
        return jobs[id]
    }

    func allJobs() -> [Job] {
        lock.lock(); defer { lock.unlock() }
        return jobs.values.sorted { $0.updated > $1.updated }
    }

    func consumeCompleted(_ id: String) -> URL? {
        lock.lock(); defer { lock.unlock() }
        guard let job = jobs[id], job.state == .completed, let path = job.stagingPath else { return nil }
        jobs.removeValue(forKey: id)
        persistLocked()
        return URL(fileURLWithPath: path)
    }

    func setBackgroundCompletionHandler(_ handler: @escaping () -> Void) {
        lock.lock(); completionHandler = handler; lock.unlock()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription ?? jobID(for: downloadTask.taskIdentifier) else { return }
        let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : (snapshot(id)?.expectedBytes ?? -1)
        let fraction = expected > 0 ? min(1, max(0, Double(totalBytesWritten) / Double(expected))) : 0
        update(id) {
            $0.state = .downloading
            $0.receivedBytes = totalBytesWritten
            $0.totalBytes = expected
            $0.fraction = fraction
            $0.updated = Date()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription ?? jobID(for: downloadTask.taskIdentifier) else { return }
        let filename = snapshot(id)?.filename ?? "model.gguf"
        let safeStem = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "/", with: "_")
            .prefix(96)
        let staging = stagingDirectory.appendingPathComponent("\(shortHash(id))-\(safeStem).gguf.part")
        do {
            try? FileManager.default.removeItem(at: staging)
            try FileManager.default.moveItem(at: location, to: staging)
            update(id) {
                $0.state = .completed
                $0.fraction = 1
                $0.stagingPath = staging.path
                $0.error = nil
                $0.updated = Date()
            }
        } catch {
            update(id) { $0.state = .failed; $0.error = error.localizedDescription; $0.updated = Date() }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = task.taskDescription ?? jobID(for: task.taskIdentifier) else { return }
        if let error = error as NSError?, error.code != NSURLErrorCancelled {
            update(id) { $0.state = .failed; $0.error = error.localizedDescription; $0.updated = Date() }
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock(); let handler = completionHandler; completionHandler = nil; lock.unlock()
        DispatchQueue.main.async { handler?() }
    }

    private func reconnectTasks() {
        session.getAllTasks { [weak self] tasks in
            guard let self else { return }
            self.lock.lock()
            for task in tasks {
                guard let id = task.taskDescription else { continue }
                self.taskToJob[task.taskIdentifier] = id
                if var job = self.jobs[id] {
                    job.taskIdentifier = task.taskIdentifier
                    if task.state == .suspended { job.state = .paused }
                    else if task.state == .running { job.state = .downloading }
                    self.jobs[id] = job
                }
            }
            self.persistLocked()
            self.lock.unlock()
        }
    }

    private func loadJobs() {
        guard let data = try? Data(contentsOf: jobsURL), let decoded = try? JSONDecoder().decode([String: Job].self, from: data) else { return }
        jobs = decoded
        taskToJob = Dictionary(uniqueKeysWithValues: decoded.values.map { ($0.taskIdentifier, $0.id) })
    }

    private func jobID(for task: Int) -> String? {
        lock.lock(); defer { lock.unlock() }
        return taskToJob[task]
    }

    private func update(_ id: String, _ body: (inout Job) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard var job = jobs[id] else { return }
        body(&job); jobs[id] = job; persistLocked()
    }

    private func mutate(_ body: (inout [String: Job]) -> Void) {
        lock.lock(); defer { lock.unlock() }
        body(&jobs); persistLocked()
    }

    private func persistLocked() {
        guard let data = try? JSONEncoder().encode(jobs) else { return }
        try? data.write(to: jobsURL, options: .atomic)
    }

    private func shortHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}

final class TriInferAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == BackgroundModelDownloads.sessionIdentifier else { completionHandler(); return }
        BackgroundModelDownloads.shared.setBackgroundCompletionHandler(completionHandler)
    }
}
