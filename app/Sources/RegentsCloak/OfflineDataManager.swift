import AppKit
import CloakChat
import Foundation
import Observation

/// Manages progressive, resumable direct HTTPS downloads for `OfflineDataset`
/// collections and persists each dataset's downloaded slider level so users can
/// start at Minimum and smoothly scale up later without re-downloading files.
@MainActor
@Observable
final class OfflineDataManager {
    static let shared = OfflineDataManager()

    struct ProgressState: Equatable {
        var currentFileName: String
        var completedBytes: Int64
        var totalBytes: Int64
        var completedFiles: Int
        var totalFiles: Int

        var fraction: Double {
            guard totalBytes > 0 else { return 0 }
            return min(max(Double(completedBytes) / Double(totalBytes), 0), 1)
        }
    }

    let rootFolder: URL
    @ObservationIgnored private let defaults: UserDefaults

    /// User's current slider position (`1...maxLevel`) for each dataset.
    var selectedLevel: [OfflineDatasetID: Int] = [:]
    /// Highest tier level (`0...maxLevel`) currently downloaded on disk.
    private(set) var downloadedLevel: [OfflineDatasetID: Int] = [:]
    /// Actual filenames present in each dataset's folder on disk.
    private(set) var installedFiles: [OfflineDatasetID: Set<String>] = [:]
    /// Active download progress per dataset.
    private(set) var activeDownloads: [OfflineDatasetID: ProgressState] = [:]
    /// Latest download error message per dataset.
    private(set) var errors: [OfflineDatasetID: String] = [:]

    @ObservationIgnored private var tasks: [OfflineDatasetID: Task<Void, Never>] = [:]

    init(
        rootFolder: URL = OfflineDataManager.defaultRootFolder,
        defaults: UserDefaults = .standard
    ) {
        self.rootFolder = rootFolder
        self.defaults = defaults
        refreshFromDisk()
    }

    static var defaultRootFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appending(path: "Regents Cloak/OfflineData", directoryHint: .isDirectory)
    }

    func folder(for id: OfflineDatasetID) -> URL {
        rootFolder.appending(path: id.rawValue, directoryHint: .isDirectory)
    }

    func setSelectedLevel(_ level: Int, for dataset: OfflineDataset) {
        let clamped = min(max(level, dataset.minLevel), dataset.maxLevel)
        selectedLevel[dataset.id] = clamped
        defaults.set(clamped, forKey: selectedKey(for: dataset.id))
    }

    func refreshFromDisk() {
        let fm = FileManager.default
        for dataset in OfflineDataset.all {
            let dir = folder(for: dataset.id)
            let entries = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            let installed = Set(entries.filter { !$0.hasSuffix(".part") && !$0.hasPrefix(".") })
            installedFiles[dataset.id] = installed

            let completeLevel = dataset.highestCompleteLevel(installed: installed)
            downloadedLevel[dataset.id] = completeLevel
            defaults.set(completeLevel, forKey: downloadedKey(for: dataset.id))

            let savedSelected = defaults.integer(forKey: selectedKey(for: dataset.id))
            if savedSelected >= dataset.minLevel && savedSelected <= dataset.maxLevel {
                selectedLevel[dataset.id] = savedSelected
            } else {
                selectedLevel[dataset.id] = max(completeLevel, dataset.minLevel)
            }
        }
    }

    func missingFiles(for dataset: OfflineDataset, upTo level: Int) -> [OfflineDatasetFile] {
        dataset.missingFiles(upTo: level, installed: installedFiles[dataset.id] ?? [])
    }

    func missingBytes(for dataset: OfflineDataset, upTo level: Int) -> Int64 {
        dataset.missingBytes(upTo: level, installed: installedFiles[dataset.id] ?? [])
    }

    /// Downloads all missing files up to `level` for `dataset`, preserving any
    /// files already downloaded at earlier slider levels.
    func download(_ dataset: OfflineDataset, upTo level: Int) {
        guard tasks[dataset.id] == nil else { return }
        let targetLevel = min(max(level, dataset.minLevel), dataset.maxLevel)
        setSelectedLevel(targetLevel, for: dataset)
        errors[dataset.id] = nil

        let missing = missingFiles(for: dataset, upTo: targetLevel)
        guard !missing.isEmpty else {
            refreshFromDisk()
            return
        }

        let totalBytes = missing.reduce(Int64(0)) { $0 + $1.expectedBytes }
        activeDownloads[dataset.id] = ProgressState(
            currentFileName: missing[0].filename,
            completedBytes: 0,
            totalBytes: totalBytes,
            completedFiles: 0,
            totalFiles: missing.count)

        let dir = folder(for: dataset.id)
        let id = dataset.id
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            defer {
                self.tasks[id] = nil
                self.activeDownloads[id] = nil
                self.refreshFromDisk()
            }
            do {
                try Self.ensurePrivateFolder(dir)
                var finishedPriorBytes: Int64 = 0
                for (index, file) in missing.enumerated() {
                    try Task.checkCancellation()
                    self.activeDownloads[id] = ProgressState(
                        currentFileName: file.filename,
                        completedBytes: finishedPriorBytes,
                        totalBytes: totalBytes,
                        completedFiles: index,
                        totalFiles: missing.count)

                    let destination = dir.appending(path: file.filename)
                    let partURL = dir.appending(path: file.filename + ".part")
                    let baseBytes = finishedPriorBytes
                    try await Self.downloadFile(
                        from: file.url,
                        partURL: partURL,
                        destination: destination
                    ) { [weak self] received in
                        Task { @MainActor [weak self] in
                            guard let self, var state = self.activeDownloads[id] else { return }
                            state.completedBytes = min(baseBytes + received, totalBytes)
                            self.activeDownloads[id] = state
                        }
                    }
                    if file.extractTarGz {
                        try Self.extractTarGz(archive: destination, into: dir)
                        try? FileManager.default.removeItem(at: destination)
                    }
                    finishedPriorBytes += file.expectedBytes
                    self.refreshFromDisk()
                }
                self.defaults.set(targetLevel, forKey: self.downloadedKey(for: id))
                self.defaults.set(targetLevel, forKey: self.selectedKey(for: id))
            } catch is CancellationError {
                // Clean user cancel — leave already-finished files intact.
            } catch {
                self.errors[id] = error.localizedDescription
            }
        }
    }

    func cancel(_ id: OfflineDatasetID) {
        tasks[id]?.cancel()
        tasks[id] = nil
        activeDownloads[id] = nil
        // Clean up any partial `.part` files on cancel.
        let dir = folder(for: id)
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
            for entry in entries where entry.hasSuffix(".part") {
                try? FileManager.default.removeItem(at: dir.appending(path: entry))
            }
        }
        refreshFromDisk()
    }

    func remove(_ dataset: OfflineDataset) {
        cancel(dataset.id)
        let dir = folder(for: dataset.id)
        try? FileManager.default.removeItem(at: dir)
        errors[dataset.id] = nil
        defaults.set(0, forKey: downloadedKey(for: dataset.id))
        defaults.set(dataset.minLevel, forKey: selectedKey(for: dataset.id))
        refreshFromDisk()
    }

    func revealFolder(for id: OfflineDatasetID) {
        let dir = folder(for: id)
        try? Self.ensurePrivateFolder(dir)
        NSWorkspace.shared.open(dir)
    }

    private func selectedKey(for id: OfflineDatasetID) -> String {
        "offlineDatasetSelectedLevel.\(id.rawValue)"
    }

    private func downloadedKey(for id: OfflineDatasetID) -> String {
        "offlineDatasetDownloadedLevel.\(id.rawValue)"
    }

    nonisolated private static func ensurePrivateFolder(_ dir: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var excluded = dir
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)
    }

    nonisolated private static func extractTarGz(archive: URL, into directory: URL) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/tar")
        process.arguments = ["-xzf", archive.path, "-C", directory.path]
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(
                domain: "sh.regents.cloak.offline",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "Couldn't unpack \(archive.lastPathComponent): \(errText.trimmingCharacters(in: .whitespacesAndNewlines))"])
        }
    }

    nonisolated private static func downloadFile(
        from url: URL,
        partURL: URL,
        destination: URL,
        onBytes: @escaping @Sendable (Int64) -> Void
    ) async throws {
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Cloak/0.2", forHTTPHeaderField: "User-Agent")

        let delegate = StreamingDownloadDelegate(destination: destination, partURL: partURL, onBytes: onBytes)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.setContinuation(continuation)
                let task = session.downloadTask(with: request)
                delegate.setTask(task)
                task.resume()
            }
        } onCancel: {
            delegate.cancel()
        }
    }
}

private final class StreamingDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let partURL: URL
    private let onBytes: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?
    private var task: URLSessionDownloadTask?
    private var lastReported: Int64 = 0

    init(destination: URL, partURL: URL, onBytes: @escaping @Sendable (Int64) -> Void) {
        self.destination = destination
        self.partURL = partURL
        self.onBytes = onBytes
    }

    func setContinuation(_ c: CheckedContinuation<Void, any Error>) {
        lock.withLock { continuation = c }
    }

    func setTask(_ t: URLSessionDownloadTask) {
        lock.withLock { task = t }
    }

    func cancel() {
        let active = lock.withLock { task }
        active?.cancel()
    }

    private func finish(_ result: Result<Void, any Error>) {
        let cont = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
            defer { continuation = nil }
            return continuation
        }
        cont?.resume(with: result)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let shouldReport = lock.withLock { () -> Bool in
            if totalBytesWritten - lastReported >= 128 * 1024 || totalBytesWritten == totalBytesExpectedToWrite {
                lastReported = totalBytesWritten
                return true
            }
            return false
        }
        if shouldReport {
            onBytes(totalBytesWritten)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            finish(.failure(NSError(
                domain: "sh.regents.cloak.offline",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Download failed (HTTP \(http.statusCode))."])))
            return
        }
        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: partURL.path) { try? fm.removeItem(at: partURL) }
            try fm.moveItem(at: location, to: partURL)
            if fm.fileExists(atPath: destination.path) { try? fm.removeItem(at: destination) }
            try fm.moveItem(at: partURL, to: destination)
            finish(.success(()))
        } catch {
            try? FileManager.default.removeItem(at: partURL)
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let error else { return }
        if (error as NSError).code == NSURLErrorCancelled {
            finish(.failure(CancellationError()))
        } else {
            finish(.failure(error))
        }
    }
}
