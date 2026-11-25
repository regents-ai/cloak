import CloakControl
import Foundation
import Network
import Observation

/// One completed background cover-traffic fetch over Tor.
public struct CoverEntry: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let url: String
    /// HTTP status code when the server answered; nil on network/Tor error.
    public let status: Int?
    public let bytes: Int
    public let durationMs: Int
    public let error: String?

    public init(
        id: UUID = UUID(),
        timestamp: Date = .now,
        url: String,
        status: Int?,
        bytes: Int,
        durationMs: Int,
        error: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.url = url
        self.status = status
        self.bytes = bytes
        self.durationMs = durationMs
        self.error = error
    }

    public var formattedLine: String {
        let time = timestamp.formatted(.dateTime.hour().minute().second())
        let outcome: String
        if let status {
            let kb = bytes >= 1024 ? String(format: "%.1f KB", Double(bytes) / 1024) : "\(bytes) B"
            outcome = "\(status) · \(kb) · \(durationMs) ms"
        } else {
            outcome = "error (\(error ?? "unreachable")) · \(durationMs) ms"
        }
        return "\(time)  \(outcome)  \(url)"
    }
}

/// Append-only log of Cover Traffic requests persisted as owner-only JSONL
/// (`~/Library/Application Support/Regents Cloak/cover-log.jsonl`, excluded from
/// Time Machine backups), with Clear Last Hour and Clear All controls.
@MainActor
@Observable
public final class CoverLog {
    public static let maxEntries = 2_000

    public let file: URL
    public private(set) var entries: [CoverEntry] = []

    public init(file: URL = Places.support.appending(path: "cover-log.jsonl")) {
        self.file = file
        load()
    }

    public func countInLastHour(now: Date = .now) -> Int {
        let cutoff = now.addingTimeInterval(-3600)
        return entries.count(where: { $0.timestamp >= cutoff })
    }

    /// Appends one entry to memory and appends one JSON line to disk.
    public func append(_ entry: CoverEntry) {
        entries.append(entry)
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
            rewriteFile()
            return
        }
        appendLine(entry)
    }

    /// Removes all entries recorded within the past 60 minutes.
    public func clearLastHour(now: Date = .now) {
        let cutoff = now.addingTimeInterval(-3600)
        let before = entries.count
        entries.removeAll(where: { $0.timestamp >= cutoff })
        guard entries.count != before else { return }
        rewriteFile()
    }

    /// Removes every entry from memory and disk.
    public func clearAll() {
        entries.removeAll()
        try? FileManager.default.removeItem(at: file)
    }

    private func load() {
        guard let data = try? Data(contentsOf: file), !data.isEmpty else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var loaded: [CoverEntry] = []
        for line in data.split(separator: 0x0a) where !line.isEmpty {
            if let entry = try? decoder.decode(CoverEntry.self, from: Data(line)) {
                loaded.append(entry)
            }
        }
        if loaded.count > Self.maxEntries {
            loaded.removeFirst(loaded.count - Self.maxEntries)
        }
        entries = loaded
    }

    private func appendLine(_ entry: CoverEntry) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var line = try? encoder.encode(entry) else { return }
        line.append(0x0a)
        do {
            try Places.makeOwnerOnly(file.deletingLastPathComponent())
            let fm = FileManager.default
            if !fm.fileExists(atPath: file.path) {
                try line.write(to: file, options: .atomic)
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                var mutable = file
                try? mutable.setResourceValues(values)
            } else {
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            }
        } catch {}
    }

    private func rewriteFile() {
        if entries.isEmpty {
            try? FileManager.default.removeItem(at: file)
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = Data()
        for entry in entries {
            if let line = try? encoder.encode(entry) {
                data.append(line)
                data.append(0x0a)
            }
        }
        do {
            try Places.makeOwnerOnly(file.deletingLastPathComponent())
            try data.write(to: file, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutable = file
            try? mutable.setResourceValues(values)
        } catch {}
    }
}

/// Live host-side Tor cover-traffic worker.
///
/// Runs directly over Cloak's bundled `tor` Unix SOCKS5 socket with per-request
/// `IsolateSOCKSAuth` credentials so toggling Cover Traffic ON or OFF takes
/// effect immediately without restarting Tor, unloading the local rewriter, or
/// rebooting the Linux microVM.
@MainActor
public final class CoverTraffic {
    /// Curated pool of 58 public pages matching `reference/cover.json`.
    public static let defaultPool: [String] = [
        "https://en.wikipedia.org/wiki/Main_Page",
        "https://en.wikipedia.org/wiki/Portal:Current_events",
        "https://en.wikipedia.org/wiki/Special:RecentChanges",
        "https://en.wikipedia.org/wiki/Special:NewPages",
        "https://en.wikipedia.org/wiki/Deaths_in_2026",
        "https://en.wikipedia.org/wiki/2026",
        "https://de.wikipedia.org/wiki/Wikipedia:Hauptseite",
        "https://fr.wikipedia.org/wiki/Wikip%C3%A9dia:Accueil_principal",
        "https://es.wikipedia.org/wiki/Wikipedia:Portada",
        "https://en.wikinews.org/wiki/Main_Page",
        "https://news.ycombinator.com/",
        "https://news.ycombinator.com/newest",
        "https://news.ycombinator.com/front",
        "https://news.ycombinator.com/ask",
        "https://news.ycombinator.com/show",
        "https://news.ycombinator.com/best",
        "https://news.ycombinator.com/active",
        "https://news.ycombinator.com/newcomments",
        "https://github.com/trending",
        "https://github.com/trending/python",
        "https://github.com/trending/rust",
        "https://github.com/trending/javascript",
        "https://github.com/explore",
        "https://www.bbc.com/news",
        "https://www.bbc.com/news/world",
        "https://www.bbc.com/sport",
        "https://www.theguardian.com/international",
        "https://www.theguardian.com/world",
        "https://www.theguardian.com/science",
        "https://arxiv.org/list/cs.AI/recent",
        "https://arxiv.org/list/cs.LG/recent",
        "https://arxiv.org/list/cs.CR/new",
        "https://arxiv.org/list/math/new",
        "https://lobste.rs/",
        "https://lobste.rs/newest",
        "https://lobste.rs/recent",
        "https://www.npr.org/sections/news/",
        "https://text.npr.org/",
        "https://openlibrary.org/trending/daily",
        "https://lemmy.ml/",
        "https://tildes.net/",
        "https://slashdot.org/",
        "https://arstechnica.com/",
        "https://www.theverge.com/",
        "https://www.aljazeera.com/",
        "https://www.aljazeera.com/news/",
        "https://www.dw.com/en/top-stories/s-9097",
        "https://phys.org/",
        "https://pypi.org/",
        "https://lite.cnn.com/",
        "https://www.cbc.ca/lite/news",
        "https://mastodon.social/explore",
        "https://bsky.app/",
        "https://hckrnews.com/",
        "https://www.wired.com/",
        "https://www.vox.com/",
        "https://www.sciencedaily.com/news/top/",
        "https://www.quantamagazine.org/",
    ]

    public let log: CoverLog
    private var task: Task<Void, Never>?
    private var activeSocket: String?

    public init(log: CoverLog = CoverLog()) {
        self.log = log
    }

    public var isRunning: Bool {
        task != nil
    }

    @ObservationIgnored private var generation: UInt64 = 0

    /// Starts live cover fetches over `torSocket` (no-op if already running on
    /// the same socket).
    public func start(torSocket: String) {
        if task != nil, activeSocket == torSocket { return }
        stop()
        generation &+= 1
        let gen = generation
        activeSocket = torSocket
        let subset = Array(Self.defaultPool.shuffled().prefix(16))
        task = Task.detached(priority: .background) { [weak self] in
            // Initial short stagger (2–4s) so enabling Cover shows real activity quickly.
            try? await Task.sleep(for: .milliseconds(Int.random(in: 2_000...4_000)))
            while !Task.isCancelled {
                if let urlString = subset.randomElement(), let url = URL(string: urlString) {
                    let entry = await Self.fetch(url: url, torSocket: torSocket)
                    if !Task.isCancelled {
                        await MainActor.run {
                            guard let self, self.generation == gen, self.task != nil else { return }
                            self.log.append(entry)
                        }
                    }
                }
                // Average ~20s between fetches (~3/min, matching rate=0.05 in reference/cover.json)
                // with wide random jitter so timing never forms a regular clock.
                let delayMs = Int.random(in: 12_000...28_000)
                try? await Task.sleep(for: .milliseconds(delayMs))
            }
        }
    }

    /// Stops cover traffic immediately without disturbing Tor or the VM.
    public func stop() {
        generation &+= 1
        task?.cancel()
        task = nil
        activeSocket = nil
    }

    private nonisolated static func fetch(url: URL, torSocket: String) async -> CoverEntry {
        let started = ContinuousClock.now
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 35
        let proxy = ProxyConfiguration(socksv5Proxy: .unix(path: torSocket))
        proxy.applyCredential(username: "cover-\(UUID().uuidString.prefix(12))", password: "x")
        config.proxyConfigurations = [proxy]

        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            let elapsed = ContinuousClock.now - started
            let ms = Int(elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
            let code = (response as? HTTPURLResponse)?.statusCode
            return CoverEntry(url: url.absoluteString, status: code, bytes: data.count, durationMs: max(ms, 0))
        } catch {
            let elapsed = ContinuousClock.now - started
            let ms = Int(elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
            let desc = (error as? URLError)?.localizedDescription ?? error.localizedDescription
            return CoverEntry(url: url.absoluteString, status: nil, bytes: 0, durationMs: max(ms, 0), error: desc)
        }
    }
}
