import Foundation

/// Loopback-only (`127.0.0.1` / `localhost`) discovery and ranking of existing local
/// OpenAI-compatible AI servers running on this Mac (LM Studio / `llmster`, `mlx-serve`,
/// Ollama, Darkbloom `--local`) so users can reuse already-downloaded weights without
/// duplicating 10–20 GB downloads.
public struct DiscoveredLocalModel: Identifiable, Equatable, Hashable, Sendable, Codable {
    public enum ServerKind: String, CaseIterable, Codable, Sendable {
        case splash = "Splash"
        case tensorFold = "TensorFold"
        case mlxServe = "mlx-serve"
        case lmStudio = "LM Studio"
        case ollama = "Ollama"
        case darkbloomLocal = "Darkbloom Local"

        public var defaultPort: UInt16? {
            switch self {
            case .splash: 8000
            case .tensorFold: 8080
            case .mlxServe: 11234
            case .lmStudio: 1234
            case .ollama: 11434
            case .darkbloomLocal: nil
            }
        }
    }

    public let server: ServerKind
    /// Base URL without trailing slash (e.g. `http://127.0.0.1:1234`). Always loopback-only.
    public let baseURL: URL
    public let modelID: String
    public let createdAt: Date?
    public let qualityScore: Int
    public let recencyScore: Int

    public var id: String { "\(server.rawValue)::\(baseURL.absoluteString)::\(modelID)" }

    /// Clean human-readable display name derived from the model ID.
    public var displayName: String {
        let leaf = modelID.split(separator: "/").last.map(String.init) ?? modelID
        return leaf
            .replacingOccurrences(of: ".gguf", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "_", with: " ")
    }

    public init(
        server: ServerKind,
        baseURL: URL,
        modelID: String,
        createdAt: Date? = nil
    ) {
        self.server = server
        self.baseURL = baseURL
        self.modelID = modelID
        self.createdAt = createdAt
        let rank = LocalModelRanking.score(identifier: modelID, createdAt: createdAt)
        self.qualityScore = rank.quality
        self.recencyScore = rank.recency
    }
}

/// Deterministic recency + quality ranking for both Cloak's built-in pinned local models
/// and models discovered from external loopback servers.
public enum LocalModelRanking {
    public struct Score: Equatable, Sendable {
        public let recency: Int
        public let quality: Int

        public var combined: Int { recency * 10 + quality }
    }

    /// Computes a deterministic `(recency, quality)` score from a model identifier/label
    /// and optional release/created timestamp.
    public static func score(
        identifier: String,
        label: String = "",
        memoryBytes: UInt64 = 0,
        isMLX: Bool = false,
        createdAt: Date? = nil
    ) -> Score {
        let text = "\(identifier) \(label)".lowercased()

        // 1. Recency tier (0...100) from known release generation + optional `createdAt`.
        var recency = 40
        if text.contains("inkling-2") || text.contains("inkling 2") || text.contains("inkling-mini") {
            recency = 98
        } else if text.contains("qwen3.8") || text.contains("qwen 3.8") || text.contains("qwen4") {
            recency = 96
        } else if text.contains("qwen3.6") || text.contains("qwen 3.6") {
            recency = 95
        } else if text.contains("deepseek-v4") || text.contains("deepseek v4") {
            recency = 94
        } else if text.contains("bonsai-2") || text.contains("bonsai 2") {
            recency = 92
        } else if text.contains("gemma-4") || text.contains("gemma 4") {
            recency = 90
        } else if text.contains("qwen3.5") || text.contains("qwen 3.5") {
            recency = 86
        } else if text.contains("nemotron-3") || text.contains("nemotron 3") {
            recency = 84
        } else if text.contains("qwen3") || text.contains("qwen 3") || text.contains("llama-4") {
            recency = 76
        } else if text.contains("deepseek-r1") || text.contains("deepseek-v3") || text.contains("llama-3.3") {
            recency = 64
        }
        if let createdAt {
            let year = Calendar(identifier: .gregorian).component(.year, from: createdAt)
            let month = Calendar(identifier: .gregorian).component(.month, from: createdAt)
            if year >= 2026 {
                recency = max(recency, min(99, 75 + month * 2))
            } else if year == 2025 {
                recency = max(recency, 60 + month)
            }
        }

        // 2. Quality / capability tier (0...100) from parameter class, quant fidelity, and engine.
        var quality = 50
        if text.contains("35b") || text.contains("32b") || text.contains("70b") || text.contains("72b") || text.contains("120b") {
            quality = 94
        } else if text.contains("27b") || text.contains("26b") || text.contains("inkling-2") || text.contains("inkling 2") || text.contains("inkling-mini") {
            quality = 90
        } else if text.contains("14b") || text.contains("12b") {
            quality = 78
        } else if text.contains("9b") || text.contains("8b") || text.contains("7b") {
            quality = 72
        } else if text.contains("4b") {
            quality = 58
        } else if text.contains("2b") || text.contains("1.7b") || text.contains("1.5b") || text.contains("1b") {
            quality = 42
        }
        if text.contains("jangh2") || text.contains("oq4") || text.contains("nvfp4") || text.contains("full quality") {
            quality = min(100, quality + 6)
        } else if text.contains("iq4") || text.contains("q4_k_m") || text.contains("mxfp8") {
            quality = min(100, quality + 3)
        }
        if isMLX {
            quality = min(100, quality + 4)
        }
        if memoryBytes >= (14 << 30) {
            quality = min(100, quality + 2)
        }

        return Score(recency: recency, quality: quality)
    }

    /// Sorts discovered external local models by combined recency + quality descending.
    public static func sorted(_ models: [DiscoveredLocalModel]) -> [DiscoveredLocalModel] {
        models.sorted { lhs, rhs in
            let lCombined = lhs.recencyScore * 10 + lhs.qualityScore
            let rCombined = rhs.recencyScore * 10 + rhs.qualityScore
            if lCombined != rCombined { return lCombined > rCombined }
            if lhs.qualityScore != rhs.qualityScore { return lhs.qualityScore > rhs.qualityScore }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }
}

/// Loopback-only local server scanner and OpenAI completions proxy.
public enum LocalServerDiscovery {
    public enum DiscoveryError: LocalizedError, Sendable {
        case nonLoopbackRejected
        case unreachable(String)
        case invalidResponse(Int)

        public var errorDescription: String? {
            switch self {
            case .nonLoopbackRejected:
                "Refused non-loopback local server address. External local servers must listen on 127.0.0.1 only."
            case .unreachable(let detail):
                "Local server unreachable: \(detail)"
            case .invalidResponse(let status):
                "Local server returned HTTP \(status)."
            }
        }
    }

    /// Returns `true` only when `url` is plain HTTP targeting loopback (`127.0.0.1`, `localhost`, or `::1`).
    public static func isLoopback(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" else { return false }
        guard let host = url.host()?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1" || host == "[::1]"
    }

    /// Probes standard localhost OpenAI-compatible AI servers concurrently and returns all
    /// discovered models sorted by recency + quality. Never contacts the internet.
    public static func discover(
        darkbloomLocalFile: URL? = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".darkbloom/local.json"),
        timeout: TimeInterval = 1.2
    ) async -> [DiscoveredLocalModel] {
        var targets: [(DiscoveredLocalModel.ServerKind, URL)] = [
            (.splash, URL(string: "http://127.0.0.1:8000")!),
            (.tensorFold, URL(string: "http://127.0.0.1:8080")!),
            (.mlxServe, URL(string: "http://127.0.0.1:11234")!),
            (.lmStudio, URL(string: "http://127.0.0.1:1234")!),
            (.ollama, URL(string: "http://127.0.0.1:11434")!),
        ]
        if let darkbloomURL = readDarkbloomLocalBaseURL(from: darkbloomLocalFile), isLoopback(darkbloomURL) {
            targets.append((.darkbloomLocal, darkbloomURL))
        }

        let session = loopbackSession(timeout: timeout)
        defer { session.invalidateAndCancel() }

        let all = await withTaskGroup(of: [DiscoveredLocalModel].self) { group in
            for (kind, baseURL) in targets {
                group.addTask {
                    await probe(kind: kind, baseURL: baseURL, session: session)
                }
            }
            var collected: [DiscoveredLocalModel] = []
            for await batch in group {
                collected.append(contentsOf: batch)
            }
            return collected
        }
        return LocalModelRanking.sorted(all)
    }

    /// Sends an OpenAI `/v1/chat/completions` JSON payload strictly to a loopback local server.
    public static func complete(baseURL: URL, modelID: String, body: Data, timeout: TimeInterval = 180) async throws -> Data {
        guard isLoopback(baseURL) else { throw DiscoveryError.nonLoopbackRejected }
        let endpoint = baseURL.appending(path: "v1/chat/completions")
        var outbound = body
        if var root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            root["model"] = modelID
            root["stream"] = false
            if let encoded = try? JSONSerialization.data(withJSONObject: root, options: [.withoutEscapingSlashes]) {
                outbound = encoded
            }
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = outbound

        let session = loopbackSession(timeout: timeout)
        defer { session.invalidateAndCancel() }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw DiscoveryError.unreachable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw DiscoveryError.invalidResponse(0)
        }
        guard (200...299).contains(http.statusCode) else {
            throw DiscoveryError.invalidResponse(http.statusCode)
        }
        return data
    }

    /// Parses an OpenAI `/v1/models` JSON response into ranked `DiscoveredLocalModel` entries.
    public static func parseModels(data: Data, kind: DiscoveredLocalModel.ServerKind, baseURL: URL) -> [DiscoveredLocalModel] {
        guard isLoopback(baseURL),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let items = root["data"] as? [[String: Any]]
        else { return [] }

        var result: [DiscoveredLocalModel] = []
        for item in items {
            guard let id = item["id"] as? String, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            // Skip embedding-only models from chat model listings.
            let lower = id.lowercased()
            if lower.contains("embed") || lower.contains("rerank") { continue }
            let created: Date?
            if let ts = item["created"] as? Double, ts > 1_500_000_000 {
                created = Date(timeIntervalSince1970: ts)
            } else if let ts = item["created"] as? Int, ts > 1_500_000_000 {
                created = Date(timeIntervalSince1970: TimeInterval(ts))
            } else {
                created = nil
            }
            result.append(DiscoveredLocalModel(server: kind, baseURL: baseURL, modelID: id, createdAt: created))
        }
        return LocalModelRanking.sorted(result)
    }

    // MARK: - Internal helpers

    private static func probe(kind: DiscoveredLocalModel.ServerKind, baseURL: URL, session: URLSession) async -> [DiscoveredLocalModel] {
        guard isLoopback(baseURL) else { return [] }
        var req = URLRequest(url: baseURL.appending(path: "v1/models"))
        req.httpMethod = "GET"
        guard let (data, response) = try? await session.data(for: req),
            let http = response as? HTTPURLResponse,
            http.statusCode == 200
        else { return [] }
        return parseModels(data: data, kind: kind, baseURL: baseURL)
    }

    private static func readDarkbloomLocalBaseURL(from file: URL?) -> URL? {
        guard let file,
            let data = try? Data(contentsOf: file),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let host = root["host"] as? String
        else { return nil }
        let normalized = host.hasPrefix("http://") || host.hasPrefix("https://") ? host : "http://\(host)"
        guard var url = URL(string: normalized) else { return nil }
        if url.path == "/v1" {
            url.deleteLastPathComponent()
        }
        return url
    }

    private static func loopbackSession(timeout: TimeInterval) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        return URLSession(configuration: config)
    }
}
