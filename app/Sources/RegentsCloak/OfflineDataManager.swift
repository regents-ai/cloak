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
    @ObservationIgnored private var activeTokens: [OfflineDatasetID: UUID] = [:]

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
        let runToken = UUID()
        activeTokens[id] = runToken
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            defer {
                // Only clear state if this download was not superseded by a
                // newer cancel + re-download for the same dataset.
                if self.activeTokens[id] == runToken {
                    self.tasks[id] = nil
                    self.activeDownloads[id] = nil
                    self.activeTokens[id] = nil
                    self.refreshFromDisk()
                }
            }
            do {
                try Self.ensurePrivateFolder(dir)
                var finishedPriorBytes: Int64 = 0
                for (index, file) in missing.enumerated() {
                    try Task.checkCancellation()
                    guard self.activeTokens[id] == runToken else { return }
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
                            guard let self, self.activeTokens[id] == runToken, var state = self.activeDownloads[id] else { return }
                            state.completedBytes = min(baseBytes + received, totalBytes)
                            self.activeDownloads[id] = state
                        }
                    }
                    try Task.checkCancellation()
                    if file.extractTarGz {
                        try await Task.detached(priority: .userInitiated) {
                            try Self.extractTarGz(archive: destination, into: dir)
                        }.value
                        try? FileManager.default.removeItem(at: destination)
                    }
                    finishedPriorBytes += file.expectedBytes
                    self.refreshFromDisk()
                }
                guard self.activeTokens[id] == runToken else { return }
                self.defaults.set(targetLevel, forKey: self.downloadedKey(for: id))
                self.defaults.set(targetLevel, forKey: self.selectedKey(for: id))
            } catch is CancellationError {
                // Clean user cancel — leave already-finished files intact.
            } catch {
                if self.activeTokens[id] == runToken {
                    self.errors[id] = error.localizedDescription
                }
            }
        }
    }

    func cancel(_ id: OfflineDatasetID) {
        activeTokens[id] = nil
        tasks[id]?.cancel()
        tasks[id] = nil
        activeDownloads[id] = nil
        // Keep any `.part` file intact so clicking Download again resumes via HTTP Range.
        // (`remove(_:)` deletes the entire dataset folder including partial files.)
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
        // Inspect archive entries first to reject path traversal (`..`) or absolute paths.
        let list = Process()
        list.executableURL = URL(filePath: "/usr/bin/tar")
        list.arguments = ["-tzf", archive.path]
        let listOut = Pipe()
        list.standardOutput = listOut
        try list.run()
        let listed = String(data: listOut.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        list.waitUntilExit()
        guard list.terminationStatus == 0 else {
            throw NSError(
                domain: "sh.regents.cloak.offline",
                code: Int(list.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "Couldn't inspect \(archive.lastPathComponent)."])
        }
        for entry in listed.split(whereSeparator: \.isNewline) {
            let path = String(entry)
            if path.hasPrefix("/") || path.split(separator: "/").contains("..") {
                throw NSError(
                    domain: "sh.regents.cloak.offline",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Refused unsafe archive path in \(archive.lastPathComponent)."])
            }
        }

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
        let existingBytes = Int64((try? FileManager.default.attributesOfItem(atPath: partURL.path)[.size] as? NSNumber)?.int64Value ?? 0)
        let validatorURL = partURL.appendingPathExtension("etag")
        let savedValidator = (try? String(contentsOf: validatorURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        var request = URLRequest(url: url)
        request.setValue("curl/8.7.1", forHTTPHeaderField: "User-Agent")
        if existingBytes > 0, let savedValidator, !savedValidator.isEmpty {
            request.setValue("bytes=\(existingBytes)-", forHTTPHeaderField: "Range")
            request.setValue(savedValidator, forHTTPHeaderField: "If-Range")
        }

        let delegate = ResumableDownloadDelegate(
            destination: destination,
            partURL: partURL,
            validatorURL: validatorURL,
            existingBytes: (savedValidator?.isEmpty == false) ? existingBytes : 0,
            onBytes: onBytes
        )
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.setContinuation(continuation)
                let task = session.dataTask(with: request)
                delegate.setTask(task)
                task.resume()
            }
        } onCancel: {
            delegate.cancel()
        }
    }
}

/// Streams HTTP downloads directly into `partURL` with `Range` resume support so
/// multi-gigabyte offline packs continue where they left off after a drop or restart.
private final class ResumableDownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let destination: URL
    private let partURL: URL
    private let validatorURL: URL
    private let existingBytes: Int64
    private let onBytes: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?
    private var task: URLSessionDataTask?
    private var handle: FileHandle?
    private var written: Int64 = 0
    private var lastReported: Int64 = 0
    private var cancelled = false
    private var failed = false

    init(
        destination: URL,
        partURL: URL,
        validatorURL: URL,
        existingBytes: Int64,
        onBytes: @escaping @Sendable (Int64) -> Void
    ) {
        self.destination = destination
        self.partURL = partURL
        self.validatorURL = validatorURL
        self.existingBytes = existingBytes
        self.onBytes = onBytes
    }

    func setContinuation(_ c: CheckedContinuation<Void, any Error>) {
        let alreadyCancelled = lock.withLock { () -> Bool in
            if cancelled { return true }
            continuation = c
            return false
        }
        if alreadyCancelled {
            c.resume(throwing: CancellationError())
        }
    }

    func setTask(_ t: URLSessionDataTask) {
        let shouldCancel = lock.withLock { () -> Bool in
            task = t
            return cancelled
        }
        if shouldCancel {
            t.cancel()
        }
    }

    func cancel() {
        let active = lock.withLock { () -> URLSessionDataTask? in
            cancelled = true
            try? handle?.close()
            handle = nil
            return task
        }
        active?.cancel()
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<Void, any Error>) {
        let cont = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
            try? handle?.close()
            handle = nil
            defer { continuation = nil }
            return continuation
        }
        cont?.resume(with: result)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(.failure(NSError(domain: "sh.regents.cloak.offline", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response."])))
            return
        }
        // HTTP 416 with an existing .part means the file is already complete or stale.
        if http.statusCode == 416 && existingBytes > 0 {
            try? FileManager.default.removeItem(at: partURL)
            try? FileManager.default.removeItem(at: validatorURL)
            completionHandler(.cancel)
            finish(.failure(NSError(
                domain: "sh.regents.cloak.offline",
                code: 416,
                userInfo: [NSLocalizedDescriptionKey: "Partial file out of range — click Download again to retry cleanly."])))
            return
        }
        guard http.statusCode == 200 || http.statusCode == 206 else {
            completionHandler(.cancel)
            finish(.failure(NSError(
                domain: "sh.regents.cloak.offline",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Download failed (HTTP \(http.statusCode))."])))
            return
        }
        do {
            let fm = FileManager.default
            var resuming = false
            if http.statusCode == 206 && existingBytes > 0 && fm.fileExists(atPath: partURL.path) {
                let contentRange = (http.value(forHTTPHeaderField: "Content-Range") ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                guard contentRange.hasPrefix("bytes \(existingBytes)-") else {
                    try? fm.removeItem(at: partURL)
                    try? fm.removeItem(at: validatorURL)
                    completionHandler(.cancel)
                    finish(.failure(NSError(
                        domain: "sh.regents.cloak.offline",
                        code: 206,
                        userInfo: [NSLocalizedDescriptionKey: "Server returned an unexpected byte range — click Download again to restart cleanly."])))
                    return
                }
                resuming = true
            }
            if !resuming {
                if fm.fileExists(atPath: partURL.path) { try fm.removeItem(at: partURL) }
                fm.createFile(atPath: partURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
                // Record ETag / Last-Modified validator for safe If-Range resume.
                if let validator = http.value(forHTTPHeaderField: "ETag") ?? http.value(forHTTPHeaderField: "Last-Modified"),
                    !validator.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    try? validator.write(to: validatorURL, atomically: true, encoding: .utf8)
                } else {
                    try? fm.removeItem(at: validatorURL)
                }
            }
            let fileHandle = try FileHandle(forWritingTo: partURL)
            if resuming {
                try fileHandle.seekToEnd()
            }
            lock.withLock {
                handle = fileHandle
                written = resuming ? existingBytes : 0
                lastReported = written
            }
            if resuming { onBytes(existingBytes) }
            completionHandler(.allow)
        } catch {
            completionHandler(.cancel)
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let report: Int64? = lock.withLock {
            guard !cancelled, !failed, let handle else { return nil }
            do {
                try handle.write(contentsOf: data)
                written += Int64(data.count)
                if written - lastReported >= 128 * 1024 {
                    lastReported = written
                    return written
                }
                return nil
            } catch {
                failed = true
                task?.cancel()
                return nil
            }
        }
        if let report {
            onBytes(report)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            // Keep `.part` intact on network drops so the next attempt resumes via HTTP Range.
            if (error as NSError).code == NSURLErrorCancelled {
                finish(.failure(CancellationError()))
            } else {
                finish(.failure(error))
            }
            return
        }
        let total = lock.withLock { () -> Int64 in
            try? handle?.close()
            handle = nil
            return written
        }
        onBytes(total)
        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: destination.path) { try? fm.removeItem(at: destination) }
            try fm.moveItem(at: partURL, to: destination)
            try? fm.removeItem(at: validatorURL)
            finish(.success(()))
        } catch {
            finish(.failure(error))
        }
    }
}
