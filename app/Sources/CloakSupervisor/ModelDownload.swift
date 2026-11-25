import CryptoKit
import Foundation
import Network
import Observation
import os
import Synchronization

/// One model's download, in the app (release plan item 7 in docs/release.md;
/// the transfer's shape is borrowed from the Llama app, decision 14 in
/// docs/plan.md): one for each model that answers Local Llama chats, the one
/// that rewords among them (decision 21), each on its own. It fetches exactly
/// the files the manifest pins for its model, at their pinned sizes and
/// sha256, each from the one URL the manifest names for it, into the model's
/// folder, and nothing else. Nothing downloads until the person asks
/// (`start`), and the download never starts Cloak. Any model but the one that
/// rewords can be removed (`remove`).
///
/// Each file streams into `<file>.part` beside its place with a running
/// sha256, and only a file whose size and sha256 match its pin is renamed
/// into place. A file that does not match has its partial deleted and stops
/// the download; it is never tried again by itself, and never accepted. A
/// partial left by a quit, a crash or a dropped connection is hashed again
/// and continued with an HTTP Range request, and started over only when the
/// server sends the whole file. The worker still checks every file's sha256
/// itself as it loads them.
///
/// This is the one owner of the download's state (docs/state-machines.md,
/// section 9a):
///
///     launch, refresh --> Installed when every file is in place, else Stopped
///     Stopped --start--> Downloading                  (not while `blocked`)
///     Downloading --every file in place--> Installed
///     Downloading --a file does not match its pin--> Stopped (mismatch)
///     Downloading, Retrying --network lost--> Waiting for network
///     Waiting for network --network back--> Downloading
///     Downloading --other failure, tries left--> Retrying --wait over--> Downloading
///     Downloading --other failure, no tries left--> Stopped (failed)
///     Downloading, Retrying, Waiting for network --pause--> Stopped (paused)
///     Stopped, Downloading, Retrying, Waiting for network --cancel--> Stopped, partials removed
///     any state --remove--> Stopped, the model's folder removed   (not the model that rewords)
///
/// The network is lost when the system says no path is up, or when a try
/// fails as a lost connection does while no path is up; neither counts as a
/// failed try. Tries count failures in a row with no new bytes between them.
@MainActor
@Observable
public final class ModelDownload {
    public enum State: Sendable, Equatable {
        /// Every file is in place, as the start check counts it.
        case installed
        /// Some file is not in place and nothing is under way: before the
        /// first press, after a launch, or after the stop it names.
        case stopped(Stop?)
        /// Fetching the files that are not in place, one at a time.
        case downloading
        /// No network; the download continues by itself when it returns.
        case waitingForNetwork
        /// That many tries have failed in a row; the next starts by itself
        /// after its wait.
        case retrying(failures: Int)
    }

    public enum Stop: Sendable, Equatable {
        /// The person paused it.
        case paused
        /// The file at this path did not match its pin, and its partial was
        /// deleted.
        case mismatch(String)
        /// The tries ran out; the last one failed this way.
        case failed(Problem)
    }

    /// How one try failed.
    public enum Problem: Sendable, Equatable {
        /// The connection failed as a lost network does, or ended early.
        case network
        /// The host answered with this HTTP status.
        case status(Int)
        /// The partial file could not be written.
        case write
        /// Anything else, as the system describes it.
        case other(String)
    }

    /// Why a download now is certain to fail.
    public enum Block: Sendable, Equatable {
        /// This Mac fails the model's Mac check (`Manifest.answerCheck`), so
        /// it could not run the model.
        case mac
        /// The models folder's volume has `free` bytes; the download needs
        /// `needed`.
        case disk(needed: Int, free: Int)
    }

    public private(set) var state: State {
        didSet {
            logger.info("\(String(describing: oldValue), privacy: .public) --> \(String(describing: self.state), privacy: .public)")
            followNetwork()
        }
    }

    /// The files in place, by path.
    private var inPlace: Set<String> = []
    /// The bytes each partial file holds, by path, for the files not in place.
    private var partial: [String: Int] = [:]
    /// The free bytes on the models folder's volume, when they can be read.
    private var free: Int?

    public let model: Manifest.Model
    /// Whether this is the model that rewords, which is never removed.
    public let rewords: Bool
    /// Whether this Mac can run the model (`Manifest.answerCheck`).
    public let fits: Bool
    public let total: Int
    /// The hosts the files come from, as the manifest names them.
    public let hosts: [String]

    /// Kept free on the volume beyond the files' bytes, for macOS and
    /// everything else on it.
    static let diskSpare = 1 << 30

    @ObservationIgnored private let files: [Manifest.Model.File]
    @ObservationIgnored private let folder: URL
    /// The wait before each try after a failed one; a failure with none
    /// left stops the download.
    private static let waits: [Duration] = [.seconds(2), .seconds(4), .seconds(8)]
    @ObservationIgnored private let session: URLSession
    /// The last run, pause or cancel; each waits for the one before it, so
    /// only one ever touches the files.
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var watch: Task<Void, Never>?
    @ObservationIgnored private var online = true
    @ObservationIgnored private let logger = Logger(subsystem: "sh.regents.cloak.app", category: "download")

    public init(model: Manifest.Model, manifest: Manifest, layout: Layout) {
        self.model = model
        rewords = model.name == manifest.model
        fits = model.memory == 0 ? true : manifest.answerCheck(model, hardware: .current).1 == nil
        files = model.files
        folder = layout.model(model)
        total = model.size
        hosts = files.compactMap { $0.url.host() }.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        session = Self.session()
        state = .stopped(nil)
        read()
        if inPlace.count == files.count { state = .installed }
    }

    /// Creates a resumable, SHA-256-verified download for an optional LoRA adapter.
    public convenience init(adapter: Manifest.Model.Adapter, manifest: Manifest, layout: Layout) {
        self.init(model: adapter.asDownloadModel(), manifest: manifest, layout: layout)
    }

    /// The bytes on this Mac toward the model: the files in place and what
    /// the partials hold.
    public var done: Int {
        files.reduce(0) { $0 + (inPlace.contains($1.path) ? $1.size : min(partial[$1.path] ?? 0, $1.size)) }
    }

    /// Partial files are on disk, for Cancel to remove.
    public var hasPartials: Bool {
        partial.values.contains { $0 > 0 }
    }

    public var isUnderWay: Bool {
        switch state {
        case .downloading, .waitingForNetwork, .retrying: true
        case .installed, .stopped: false
        }
    }

    public var blocked: Block? {
        guard fits else { return .mac }
        let remaining = files.reduce(0) { $0 + (inPlace.contains($1.path) ? 0 : $1.size - min(partial[$1.path] ?? 0, $1.size)) }
        if let free, free < remaining + Self.diskSpare { return .disk(needed: remaining + Self.diskSpare, free: free) }
        return nil
    }

    /// Reads the files, the partials and the free space again, while
    /// nothing is under way.
    public func refresh() {
        guard !isUnderWay else { return }
        read()
        if inPlace.count == files.count {
            state = .installed
        } else if state == .installed {
            state = .stopped(nil)
        }
    }

    /// Download, or Continue: starts fetching what is not in place, unless
    /// it is certain to fail.
    public func start() {
        guard case .stopped = state else { return }
        refresh()
        guard case .stopped = state, blocked == nil else { return }
        begin()
    }

    public func pause() {
        guard isUnderWay else { return }
        work?.cancel()
        state = .stopped(.paused)
        after { download in
            download.read()
            if download.inPlace.count == download.files.count {
                download.state = .installed
            }
        }
    }

    /// Stops what is under way and removes the partial files.
    public func cancel() {
        guard state != .installed else { return }
        work?.cancel()
        state = .stopped(nil)
        after { download in
            for file in download.files where !download.inPlace.contains(file.path) {
                try? FileManager.default.removeItem(at: Self.partial(for: file, in: download.folder))
            }
            download.read()
        }
    }

    /// Stops what is under way and removes the model's folder: its files and
    /// partials. Never for the model that rewords, which every Start needs.
    public func remove() {
        precondition(!rewords, "the model that rewords is never removed")
        work?.cancel()
        state = .stopped(nil)
        after { download in
            try? FileManager.default.removeItem(at: download.folder)
            download.read()
        }
    }

    /// Clears a corrupted or modified model folder (including the rewording
    /// model) and starts a clean re-download, so `.modelChanged` always has an
    /// in-app recovery path.
    public func repair() {
        work?.cancel()
        state = .stopped(nil)
        after { download in
            try? FileManager.default.removeItem(at: download.folder)
            download.read()
            if download.blocked == nil {
                download.state = .downloading
                await download.download()
            }
        }
    }

    private func begin() {
        state = .downloading
        after { await $0.download() }
    }

    /// Runs `step` once the work before it has ended, unless this step was
    /// itself superseded before its turn came.
    private func after(_ step: @escaping @MainActor (ModelDownload) async -> Void) {
        let previous = work
        work = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            await step(self)
        }
    }

    private func read() {
        inPlace = Set(files.filter { Checks.isInPlace($0, in: folder) }.map(\.path))
        partial = [:]
        for file in files where !inPlace.contains(file.path) {
            partial[file.path] = Self.size(of: Self.partial(for: file, in: folder))
        }
        free = Self.freeSpace(at: folder)
    }

    /// One run: each file not in place, in the manifest's order, until all
    /// are, a file does not match, the tries run out or the network goes.
    private func download() async {
        var failures = 0
        while let file = files.first(where: { !Checks.isInPlace($0, in: folder) }) {
            let before = Self.size(of: Self.partial(for: file, in: folder))
            do {
                try await fetch(file)
                failures = 0
            } catch let fault as Fault {
                guard !Task.isCancelled else { return }
                read()
                switch fault {
                case .mismatch:
                    logger.error("\(file.path, privacy: .public) does not match its pin; its partial is deleted")
                    state = .stopped(.mismatch(file.path))
                    return
                case .problem(let problem):
                    logger.error("\(file.path, privacy: .public): \(String(describing: problem), privacy: .public)")
                    if problem == .network, !online {
                        state = .waitingForNetwork
                        return
                    }
                    // Disk-full / write errors and client HTTP errors (e.g. 404, 416)
                    // won't succeed on immediate blind retry and would re-hash GBs.
                    let retryable: Bool = switch problem {
                    case .write: false
                    case .status(let code): code == 429 || code >= 500
                    case .network, .other: true
                    }
                    if Self.size(of: Self.partial(for: file, in: folder)) > before { failures = 0 }
                    guard retryable, failures < Self.waits.count else {
                        state = .stopped(.failed(problem))
                        return
                    }
                    state = .retrying(failures: failures + 1)
                    do {
                        try await Task.sleep(for: Self.waits[failures])
                    } catch {
                        return
                    }
                    failures += 1
                    state = .downloading
                }
            } catch {
                // Cancelled: whatever cancelled it has set the state.
                return
            }
        }
        guard !Task.isCancelled else { return }
        read()
        state = .installed
    }

    /// Fetches one file, following its partial's bytes as they grow.
    private func fetch(_ file: Manifest.Model.File) async throws {
        let (updates, update) = AsyncStream.makeStream(of: Int.self, bufferingPolicy: .bufferingNewest(1))
        let follow = Task {
            for await bytes in updates { partial[file.path] = bytes }
        }
        do {
            try await Self.fetch(file, into: folder, session: session) { update.yield($0) }
        } catch {
            update.finish()
            await follow.value
            throw error
        }
        update.finish()
        await follow.value
    }

    /// Watches the network while the download is under way, and only then.
    private func followNetwork() {
        guard isUnderWay else {
            watch?.cancel()
            watch = nil
            online = true
            return
        }
        guard watch == nil else { return }
        watch = Task {
            for await online in Self.paths() {
                networkChanged(online)
            }
        }
    }

    private func networkChanged(_ online: Bool) {
        self.online = online
        switch (state, online) {
        case (.downloading, false), (.retrying, false):
            work?.cancel()
            state = .waitingForNetwork
        case (.waitingForNetwork, true):
            begin()
        default:
            break
        }
    }
}

extension ModelDownload {
    /// Why one file's fetch ended without it in place.
    enum Fault: Error, Equatable {
        /// Its bytes do not match its pin; its partial is deleted.
        case mismatch
        case problem(Problem)
    }

    nonisolated static func partial(for file: Manifest.Model.File, in folder: URL) -> URL {
        folder.appending(path: file.path + ".part")
    }

    nonisolated static func size(of url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    /// The free bytes, for important use, on the volume `folder` is on, or
    /// would be on once made.
    nonisolated static func freeSpace(at folder: URL) -> Int? {
        var url = folder
        while !FileManager.default.fileExists(atPath: url.path), url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
        }
        return (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage.map(Int.init)
    }

    /// Whether the system has a path to the network, each time it changes.
    nonisolated static func paths() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { continuation.yield($0.status == .satisfied) }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: DispatchQueue(label: "sh.regents.cloak.app.network"))
        }
    }

    /// No cache, no cookies kept, a client name that says neither the app
    /// nor its version, and each file's callbacks one at a time.
    nonisolated static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpAdditionalHeaders = ["User-Agent": "curl/8.7.1"]
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return URLSession(configuration: configuration, delegate: nil, delegateQueue: queue)
    }

    /// Fetches `file` into its place in `folder`, through its partial file.
    /// `progress` hears the partial's bytes as the host's arrive. Ends with
    /// the file in place, or throws `Fault`, or `CancellationError` when
    /// cancelled.
    @concurrent
    static func fetch(
        _ file: Manifest.Model.File, into folder: URL, session: URLSession, progress: @escaping @Sendable (Int) -> Void
    ) async throws {
        let destination = folder.appending(path: file.path)
        let partial = partial(for: file, in: folder)
        let handle: FileHandle
        do {
            try FileManager.default.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: partial.path) {
                try Data().write(to: partial)
            }
            handle = try FileHandle(forUpdating: partial)
        } catch {
            throw Fault.problem(.write)
        }

        // What a partial already holds is hashed again, never trusted; its
        // bytes are already counted as done. Each block is read inside a
        // pool of its own, so it is gone before the next (see the worker's
        // `ModelPin.digest`).
        var hasher = SHA256()
        var have = 0
        do {
            while try autoreleasepool(invoking: {
                try Task.checkCancellation()
                guard let block = try handle.read(upToCount: 8 << 20), !block.isEmpty else { return false }
                hasher.update(data: block)
                have += block.count
                return true
            }) {}
        } catch {
            try? handle.close()
            throw error is CancellationError ? error : Fault.problem(.write)
        }
        guard have < file.size else {
            try settle(file, handle: handle, hasher: hasher, size: have, partial: partial, destination: destination)
            return
        }
        do {
            try Task.checkCancellation()
        } catch {
            try? handle.close()
            throw error
        }

        var request = URLRequest(url: file.url)
        if have > 0 { request.setValue("bytes=\(have)-", forHTTPHeaderField: "Range") }
        let transfer = Transfer(
            file: file, partial: partial, destination: destination, handle: handle, hasher: hasher, written: have,
            progress: progress)
        let task = session.dataTask(with: request)
        task.delegate = transfer
        try await withTaskCancellationHandler {
            task.resume()
            try await transfer.outcome.wait()
        } onCancel: {
            task.cancel()
        }
    }

    /// The partial holds the pinned size or more: renamed into place when its
    /// size and sha256 match the pin, else deleted as a mismatch. Closes
    /// `handle` either way.
    nonisolated static func settle(
        _ file: Manifest.Model.File, handle: FileHandle, hasher: SHA256, size: Int, partial: URL, destination: URL
    ) throws(Fault) {
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard size == file.size, digest == file.sha256 else {
            try? handle.close()
            try? FileManager.default.removeItem(at: partial)
            throw .mismatch
        }
        do {
            try handle.synchronize()
            try handle.close()
        } catch {
            throw .problem(.write)
        }
        // rename(2) puts it in place at once, over anything there.
        guard rename(partial.path, destination.path) == 0 else { throw .problem(.write) }
    }
}

/// One file's request. URLSession calls it on its session's delegate queue,
/// one call at a time, and only there is its file and hash touched; once it
/// has ended, it touches the file no more.
private final class Transfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let outcome = Outcome()
    private let file: Manifest.Model.File
    private let partial: URL
    private let destination: URL
    private let progress: @Sendable (Int) -> Void
    /// Open until the transfer ends.
    private var handle: FileHandle?
    private var hasher: SHA256
    private var written: Int
    private var reported: Int

    /// The URL errors a lost or unsteady network gives.
    private static let network: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost, .cannotFindHost,
        .dnsLookupFailed, .dataNotAllowed,
    ]

    init(
        file: Manifest.Model.File, partial: URL, destination: URL, handle: FileHandle, hasher: SHA256, written: Int,
        progress: @escaping @Sendable (Int) -> Void
    ) {
        self.file = file
        self.partial = partial
        self.destination = destination
        self.handle = handle
        self.hasher = hasher
        self.written = written
        reported = written
        self.progress = progress
    }

    /// 206 from where the partial ends continues it; 200 is the whole file,
    /// from the start, when the server will not resume. Anything else ends
    /// the try.
    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let handle else { return completionHandler(.cancel) }
        let response = response as? HTTPURLResponse
        switch response?.statusCode {
        case 206:
            let range = response?.value(forHTTPHeaderField: "Content-Range") ?? ""
            guard range.hasPrefix("bytes \(written)-") else {
                end(ModelDownload.Fault.problem(.other("the host sent another part of the file than the one asked for")))
                return completionHandler(.cancel)
            }
        case 200:
            do {
                try handle.truncate(atOffset: 0)
            } catch {
                end(ModelDownload.Fault.problem(.write))
                return completionHandler(.cancel)
            }
            hasher = SHA256()
            written = 0
            reported = 0
            progress(0)
        default:
            end(ModelDownload.Fault.problem(.status(response?.statusCode ?? 0)))
            return completionHandler(.cancel)
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let handle else { return }
        guard written + data.count <= file.size else {
            // More bytes than the pin: not the pinned file.
            dataTask.cancel()
            mismatch()
            return
        }
        do {
            try handle.write(contentsOf: data)
        } catch {
            dataTask.cancel()
            end(ModelDownload.Fault.problem(.write))
            return
        }
        hasher.update(data: data)
        written += data.count
        if written - reported >= 8 << 20 {
            reported = written
            progress(written)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let handle else { return }
        if let error {
            let code = (error as? URLError)?.code
            if code == .cancelled {
                end(CancellationError())
            } else {
                end(ModelDownload.Fault.problem(code.map(Self.network.contains) == true ? .network : .other(error.localizedDescription)))
            }
            return
        }
        progress(written)
        // A response that ends early is a connection that ended early.
        guard written == file.size else { return end(ModelDownload.Fault.problem(.network)) }
        self.handle = nil
        do throws(ModelDownload.Fault) {
            try ModelDownload.settle(file, handle: handle, hasher: hasher, size: written, partial: partial, destination: destination)
            outcome.end(.success(()))
        } catch {
            outcome.end(.failure(error))
        }
    }

    private func mismatch() {
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: partial)
        progress(0)
        outcome.end(.failure(ModelDownload.Fault.mismatch))
    }

    private func end(_ error: any Error) {
        try? handle?.close()
        handle = nil
        progress(written)
        outcome.end(.failure(error))
    }
}

/// How one transfer ends: given once, by the delegate, and waited for once,
/// in either order.
private final class Outcome: Sendable {
    private enum Slot {
        case open
        case waiting(CheckedContinuation<Void, any Error>)
        case ended(Result<Void, any Error>)
    }

    private let slot = Mutex(Slot.open)

    func wait() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let ended: Result<Void, any Error>? = slot.withLock {
                if case .ended(let result) = $0 { return result }
                $0 = .waiting(continuation)
                return nil
            }
            if let ended { continuation.resume(with: ended) }
        }
    }

    /// The first ending given is the one; any after it is dropped.
    func end(_ result: Result<Void, any Error>) {
        let waiting: CheckedContinuation<Void, any Error>? = slot.withLock {
            switch $0 {
            case .open:
                $0 = .ended(result)
                return nil
            case .waiting(let continuation):
                $0 = .ended(result)
                return continuation
            case .ended:
                return nil
            }
        }
        waiting?.resume(with: result)
    }
}
