import Foundation

/// Pure Darkbloom wire contracts, hardware/capability guards, redaction, and
/// exact integer micro-USD money formatting. Zero AppKit/SwiftUI/process I/O
/// dependencies so every money and capability invariant is directly testable
/// in `CloakTests`.

/// Why something of Darkbloom's stopped: a few words for the window, and,
/// for its note, Darkbloom's own reason when it gave one.
public struct DarkbloomFailure: Error, Equatable, Sendable {
    public var words: String
    public var detail: String?

    public init(_ words: String, detail: String? = nil) {
        self.words = words
        self.detail = detail
    }
}

/// How a call to Darkbloom's control service went wrong.
public enum DarkbloomError: Error, Equatable, Sendable {
    /// It didn't answer, or the line to it broke.
    case unreachable
    /// It answered with something Cloak can't read.
    case unreadable
    /// It refused, in its own words.
    case refused(String)

    public var reason: String {
        switch self {
        case .unreachable: "Darkbloom's control service isn't answering."
        case .unreadable: "Darkbloom answered in a way Cloak doesn't know."
        case .refused(let words): words
        }
    }
}

/// One of the control service's actions Cloak asks for
/// (docs/reference/desktop-control.md:199–216), each with a new request ID.
public enum DarkbloomAction: Equatable, Sendable {
    case download(model: String)
    case remove(model: String)
    case cancel(operation: String)
    case stop
    case link
    case accountSignIn

    public var body: Data {
        var fields = ["id": UUID().uuidString.lowercased()]
        switch self {
        case .download(let model):
            fields["action"] = "download"
            fields["model"] = model
        case .remove(let model):
            fields["action"] = "remove"
            fields["model"] = model
        case .cancel(let operation):
            fields["action"] = "cancel"
            fields["operation"] = operation
        case .stop:
            fields["action"] = "stop"
        case .link:
            fields["action"] = "link"
        case .accountSignIn:
            fields["action"] = "account-signin"
        }
        return try! JSONEncoder().encode(fields)
    }
}

/// The reason a run of Darkbloom's gave for stopping: its last `✗` or
/// `Error:` line (how its installer and command line say what failed),
/// else its last line, cut short, with anything that looks like a token,
/// a key or a link's query taken out (as installProgress.ts's
/// `sanitizeInstallLine` does).
public struct DarkbloomReasons: Equatable, Sendable {
    private var failure: String?
    private var last: String?

    public init() {}

    public var reason: String? { failure ?? last }

    public mutating func hear(_ line: String) {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        if text.hasPrefix("✗") || text.hasPrefix("Error:") {
            failure = Self.clean(text)
        } else {
            last = Self.clean(text)
        }
    }

    public static func clean(_ line: String) -> String {
        let text = line
            .replacing(/^(✗|Error:)\s*/, with: "")
            .replacing(/(https?:\/\/[^\s?#]+)[?#]\S*/) { $0.output.1 }
            .replacing(/(?i)\b(token|key|secret|password|authorization)\s*[:=]\s*(bearer\s+)?\S+/) { "\($0.output.1) …" }
            .replacing(/(?i)\bbearer\s+\S+/, with: "Bearer …")
            .replacing(/[A-Za-z0-9+\/=_-]{32,}/, with: "…")
        return String(text.prefix(200))
    }
}

/// What Darkbloom's control service reports, as much of it as Cloak shows
/// (desktop-app/src/shared/contracts.ts, `Snapshot`).
public struct DarkbloomSnapshot: Decodable, Equatable, Sendable {
    public var `protocol`: Int
    public var version: String
    public var linked: Bool
    public var accountRevision: String?
    public var resourceRevision: String?
    /// "stopped", "starting", "running", "draining" or "stale".
    public var state: String
    /// What Darkbloom's network says of this Mac while it serves the network:
    /// "untrusted" until it has verified this Mac, "offline" while not
    /// connected; nil otherwise.
    public var providerStatus: String?
    public var models: [Model]
    public var operations: [Operation]
    public var memory: Memory
    public var endpoint: Endpoint?
    public var link: Link?
    public var account: Account?
    public var machine: Machine?
    public var settings: Settings?
    public var catalogError: String?
    /// Live provider activity reported by Darkbloom v0.10.17+ (`/control/v1/state`).
    public var activity: Activity?
    /// Optional live provider metrics reported by newer Darkbloom builds
    /// (Decision N5.2 — darkbloom-monitor metrics).
    public var metrics: Metrics?
    public var stats: Metrics?

    public init(
        protocol: Int = 1,
        version: String = "0.10.19",
        linked: Bool = false,
        accountRevision: String? = nil,
        resourceRevision: String? = nil,
        state: String = "stopped",
        providerStatus: String? = nil,
        models: [Model] = [],
        operations: [Operation] = [],
        memory: Memory = Memory(totalGb: 48, pinBudgetGb: 32),
        endpoint: Endpoint? = nil,
        link: Link? = nil,
        account: Account? = nil,
        machine: Machine? = nil,
        settings: Settings? = nil,
        catalogError: String? = nil,
        activity: Activity? = nil,
        metrics: Metrics? = nil,
        stats: Metrics? = nil
    ) {
        self.protocol = `protocol`
        self.version = version
        self.linked = linked
        self.accountRevision = accountRevision
        self.resourceRevision = resourceRevision
        self.state = state
        self.providerStatus = providerStatus
        self.models = models
        self.operations = operations
        self.memory = memory
        self.endpoint = endpoint
        self.link = link
        self.account = account
        self.machine = machine
        self.settings = settings
        self.catalogError = catalogError
        self.activity = activity
        self.metrics = metrics
        self.stats = stats
    }

    public var liveMetrics: Metrics? { metrics ?? stats }
    public var providerName: String? {
        [machine?.name, settings?.name]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    public struct Activity: Decodable, Equatable, Sendable {
        public var startedAt: Double?
        public var requests: Int?
        public var countedRequests: Int?
        public var tokens: Int?
        public var processedTokens: Int?
        public var processedInputTokens: Int?
        public var processedOutputTokens: Int?
        /// Settled earnings for the current provider session in micro-USD (`$1 = 1_000_000`).
        public var earningsMicroUsd: UInt64?

        public var resolvedRequests: Int? { requests ?? countedRequests }
        public var resolvedTokens: Int? { processedOutputTokens ?? processedTokens ?? tokens }

        public init(
            startedAt: Double? = nil,
            requests: Int? = nil,
            countedRequests: Int? = nil,
            tokens: Int? = nil,
            processedTokens: Int? = nil,
            processedInputTokens: Int? = nil,
            processedOutputTokens: Int? = nil,
            earningsMicroUsd: UInt64? = nil
        ) {
            self.startedAt = startedAt
            self.requests = requests
            self.countedRequests = countedRequests
            self.tokens = tokens
            self.processedTokens = processedTokens
            self.processedInputTokens = processedInputTokens
            self.processedOutputTokens = processedOutputTokens
            self.earningsMicroUsd = earningsMicroUsd
        }

        private enum CodingKeys: String, CodingKey {
            case startedAt, requests, countedRequests, tokens, processedTokens, processedInputTokens, processedOutputTokens, earningsMicroUsd
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            startedAt = try? c.decode(Double.self, forKey: .startedAt)
            requests = Self.decodeInt(c, forKey: .requests)
            countedRequests = Self.decodeInt(c, forKey: .countedRequests)
            tokens = Self.decodeInt(c, forKey: .tokens)
            processedTokens = Self.decodeInt(c, forKey: .processedTokens)
            processedInputTokens = Self.decodeInt(c, forKey: .processedInputTokens)
            processedOutputTokens = Self.decodeInt(c, forKey: .processedOutputTokens)
            earningsMicroUsd = Self.decodeUInt64(c, forKey: .earningsMicroUsd)
        }

        private static func decodeInt(_ c: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> Int? {
            if let v = try? c.decode(Int.self, forKey: key) { return v }
            if let s = try? c.decode(String.self, forKey: key), let v = Int(s) { return v }
            return nil
        }

        private static func decodeUInt64(_ c: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> UInt64? {
            if let v = try? c.decode(UInt64.self, forKey: key) { return v }
            if let s = try? c.decode(String.self, forKey: key), let v = UInt64(s) { return v }
            return nil
        }
    }

    public struct Account: Decodable, Equatable, Sendable {
        public var signedIn: Bool?
        public var email: String?
        public var username: String?
        public var displayName: String?
        public var name: String?
        public var handle: String?
        public var legacyData: Bool?

        public init(
            signedIn: Bool? = nil, email: String? = nil, username: String? = nil,
            displayName: String? = nil, name: String? = nil, handle: String? = nil, legacyData: Bool? = nil
        ) {
            self.signedIn = signedIn
            self.email = email
            self.username = username
            self.displayName = displayName
            self.name = name
            self.handle = handle
            self.legacyData = legacyData
        }

        public var identity: String? {
            [email, username, handle, displayName, name]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
        }
    }

    public struct Machine: Decodable, Equatable, Sendable {
        public var name: String?
        public init(name: String? = nil) { self.name = name }
    }

    public struct Settings: Decodable, Equatable, Sendable {
        public var name: String?
        public init(name: String? = nil) { self.name = name }
    }

    public struct Metrics: Decodable, Equatable, Sendable {
        public var tokensPerSecond: Double?
        public var tps: Double?
        public var requestsServed: Int?
        public var totalRequests: Int?
        public var activeRequests: Int?
        public var inFlight: Int?
        public var uptimeSeconds: Double?

        public init(
            tokensPerSecond: Double? = nil, tps: Double? = nil, requestsServed: Int? = nil,
            totalRequests: Int? = nil, activeRequests: Int? = nil, inFlight: Int? = nil, uptimeSeconds: Double? = nil
        ) {
            self.tokensPerSecond = tokensPerSecond
            self.tps = tps
            self.requestsServed = requestsServed
            self.totalRequests = totalRequests
            self.activeRequests = activeRequests
            self.inFlight = inFlight
            self.uptimeSeconds = uptimeSeconds
        }

        public var resolvedTPS: Double? { tokensPerSecond ?? tps }
        public var resolvedRequests: Int? { requestsServed ?? totalRequests }
        public var resolvedActive: Int? { activeRequests ?? inFlight }
    }

    public struct Model: Decodable, Equatable, Sendable, Identifiable {
        public var id: String
        public var displayName: String
        /// The download's size, in Darkbloom's GB.
        public var sizeGb: Double?
        /// What it takes in memory once loaded, known once downloaded.
        public var memoryGb: Double?
        public var quantization: String?
        public var description: String?
        public var contextLength: Int?
        public var downloaded: Bool
        /// Whether Darkbloom is set to serve it.
        public var serving: Bool
        public var loaded: Bool
        /// Whether Darkbloom can serve it on this Mac.
        public var eligible: Bool
        /// Whether Darkbloom's list has it.
        public var network: Bool
        /// "routable" once the network sends it requests.
        public var registration: String?

        public init(
            id: String,
            displayName: String,
            sizeGb: Double? = nil,
            memoryGb: Double? = nil,
            quantization: String? = nil,
            description: String? = nil,
            contextLength: Int? = nil,
            downloaded: Bool = false,
            serving: Bool = false,
            loaded: Bool = false,
            eligible: Bool = true,
            network: Bool = true,
            registration: String? = nil
        ) {
            self.id = id
            self.displayName = displayName
            self.sizeGb = sizeGb
            self.memoryGb = memoryGb
            self.quantization = quantization
            self.description = description
            self.contextLength = contextLength
            self.downloaded = downloaded
            self.serving = serving
            self.loaded = loaded
            self.eligible = eligible
            self.network = network
            self.registration = registration
        }
    }

    public struct Operation: Decodable, Equatable, Sendable {
        public var id: String
        public var action: String
        /// "running", "succeeded", "failed", "cancelled" or "interrupted".
        public var state: String
        public var message: String
        public var cancellable: Bool
        public var model: String?
        /// From 0 to 1, for a download that reports it.
        public var progress: Double?

        public init(
            id: String, action: String, state: String, message: String = "",
            cancellable: Bool = false, model: String? = nil, progress: Double? = nil
        ) {
            self.id = id
            self.action = action
            self.state = state
            self.message = message
            self.cancellable = cancellable
            self.model = model
            self.progress = progress
        }
    }

    public struct Memory: Decodable, Equatable, Sendable {
        public var totalGb: Double
        /// What Darkbloom lets models take on this Mac, in its GB.
        public var pinBudgetGb: Double?

        public init(totalGb: Double, pinBudgetGb: Double? = nil) {
            self.totalGb = totalGb
            self.pinBudgetGb = pinBudgetGb
        }
    }

    public struct Endpoint: Decodable, Equatable, Sendable {
        public var baseUrl: String
        public var authenticated: Bool

        public init(baseUrl: String, authenticated: Bool) {
            self.baseUrl = baseUrl
            self.authenticated = authenticated
        }
    }

    /// Darkbloom's link page and the code to give it.
    public struct Link: Decodable, Equatable, Sendable {
        public var url: String
        public var code: String

        public init(url: String, code: String) {
            self.url = url
            self.code = code
        }
    }
}

/// Account payout balance and settled earnings returned by Darkbloom's
/// `GET /control/v1/cloud` endpoint (`desktop-app/src/shared/contracts.ts`,
/// `CloudData`). All monetary counters cross the boundary as decimal-string
/// micro-USD (`$1.00 = 1_000_000`) to preserve exact integer accounting.
public struct DarkbloomCloudEarnings: Decodable, Equatable, Sendable {
    public var linked: Bool
    public var balanceMicroUsd: UInt64?
    public var lifetimeMicroUsd: UInt64?
    public var weekMicroUsd: UInt64?
    public var localDayMicroUsd: UInt64?
    public var localLifetimeMicroUsd: UInt64?
    public var localEarningsMicroUsd: UInt64?
    public var settledRecords: Int?
    public var earningsComplete: Bool?
    public var error: String?

    private enum CodingKeys: String, CodingKey {
        case linked, balanceMicroUsd, lifetimeMicroUsd, weekMicroUsd, localDayMicroUsd,
            localLifetimeMicroUsd, localEarningsMicroUsd, settledRecords, earningsComplete, error
    }

    public init(
        linked: Bool,
        balanceMicroUsd: UInt64? = nil,
        lifetimeMicroUsd: UInt64? = nil,
        weekMicroUsd: UInt64? = nil,
        localDayMicroUsd: UInt64? = nil,
        localLifetimeMicroUsd: UInt64? = nil,
        localEarningsMicroUsd: UInt64? = nil,
        settledRecords: Int? = nil,
        earningsComplete: Bool? = nil,
        error: String? = nil
    ) {
        self.linked = linked
        self.balanceMicroUsd = balanceMicroUsd
        self.lifetimeMicroUsd = lifetimeMicroUsd
        self.weekMicroUsd = weekMicroUsd
        self.localDayMicroUsd = localDayMicroUsd
        self.localLifetimeMicroUsd = localLifetimeMicroUsd
        self.localEarningsMicroUsd = localEarningsMicroUsd
        self.settledRecords = settledRecords
        self.earningsComplete = earningsComplete
        self.error = error
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        linked = (try? c.decode(Bool.self, forKey: .linked)) ?? false
        balanceMicroUsd = Self.decodeUInt64(c, forKey: .balanceMicroUsd)
        lifetimeMicroUsd = Self.decodeUInt64(c, forKey: .lifetimeMicroUsd)
        weekMicroUsd = Self.decodeUInt64(c, forKey: .weekMicroUsd)
        localDayMicroUsd = Self.decodeUInt64(c, forKey: .localDayMicroUsd)
        localLifetimeMicroUsd = Self.decodeUInt64(c, forKey: .localLifetimeMicroUsd)
        localEarningsMicroUsd = Self.decodeUInt64(c, forKey: .localEarningsMicroUsd)
        settledRecords = Self.decodeInt(c, forKey: .settledRecords)
        earningsComplete = try? c.decode(Bool.self, forKey: .earningsComplete)
        error = try? c.decode(String.self, forKey: .error)
    }

    private static func decodeUInt64(_ c: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> UInt64? {
        if let v = try? c.decode(UInt64.self, forKey: key) { return v }
        if let s = try? c.decode(String.self, forKey: key), let v = UInt64(s) { return v }
        return nil
    }

    private static func decodeInt(_ c: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> Int? {
        if let v = try? c.decode(Int.self, forKey: key) { return v }
        if let s = try? c.decode(String.self, forKey: key), let v = Int(s) { return v }
        return nil
    }

    /// Formats integer micro-USD (`$1.00 = 1_000_000`) cleanly without float drift:
    /// shows 2 decimals for `$0.10+` and `$0.00`, and up to 4 decimals for small
    /// positive balances like `$0.0129`.
    public static func formatMicroUSD(_ micro: UInt64) -> String {
        let dollars = micro / 1_000_000
        let remainder = micro % 1_000_000
        if micro == 0 { return "$0.00" }
        if dollars > 0 || remainder >= 100_000 {
            let cents = (remainder + 5_000) / 10_000
            let carry = cents / 100
            let remCents = cents % 100
            return String(format: "$%llu.%02llu", dollars + carry, remCents)
        }
        let tenThousandths = (remainder + 50) / 100
        if tenThousandths == 0 { return "<$0.0001" }
        var frac = String(format: "%04llu", tenThousandths)
        while frac.count > 2, frac.hasSuffix("0") {
            frac.removeLast()
        }
        return "$0.\(frac)"
    }
}

/// How Darkbloom on this Mac is set to serve, read from its own files each
/// time: the job it gave launchd (`~/Library/LaunchAgents/io.darkbloom.provider.plist`),
/// the address its local server listens on (`host` in `~/.darkbloom/local.json`),
/// and where the person's requests go when this Mac is busy (`[local] route`
/// in `~/.config/darkbloom/provider.toml`). Cloak changes none of them; its
/// Start asks Darkbloom to.
public struct DarkbloomSetup: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        /// `--local`: this Mac alone (Darkbloom's Only me).
        case onlyMe
        /// `--local-endpoint` / `--me-first`: the network and this Mac (Both).
        case both
        /// The network alone.
        case network
    }

    public struct Job: Equatable, Sendable {
        public var mode: Mode
        /// Its `--bind`, when it has a local address.
        public var bind: String?
        /// Model IDs passed via `--model` in the launchd job (used to identify
        /// the configured model in `--local` on-demand mode where `/control/v1/state`
        /// reports `serving: false, loaded: false` while idle).
        public var models: [String]
        /// Whether launchd has it now: Darkbloom's Stop takes it out.
        public var loaded: Bool
        /// Whether its process runs now.
        public var running: Bool
        /// Whether launchd starts it at login while it has it.
        public var runsAtLoad: Bool

        public init(
            mode: Mode, bind: String? = nil, models: [String] = [],
            loaded: Bool = false, running: Bool = false, runsAtLoad: Bool = false
        ) {
            self.mode = mode
            self.bind = bind
            self.models = models
            self.loaded = loaded
            self.running = running
            self.runsAtLoad = runsAtLoad
        }
    }

    public var job: Job?
    /// The address the running local server listens on, when one runs.
    public var listens: String?
    /// The saved route, nil when none is saved, the file can't be read, or
    /// the job reads another file.
    public var route: String?

    public init(job: Job? = nil, listens: String? = nil, route: String? = nil) {
        self.job = job
        self.listens = listens
        self.route = route
    }

    /// `route` in `[local]`, as Darkbloom writes it there.
    public static func route(in toml: String) -> String? {
        var local = false
        for line in toml.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("[") {
                local = text == "[local]"
                continue
            }
            let parts = text.split(separator: "=", maxSplits: 1)
            guard local, parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "route" else { continue }
            let value = parts[1].split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            return value.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return nil
    }

    /// Whether `address` is this Mac's loopback, which only this Mac reaches.
    public static func loopback(_ address: String) -> Bool {
        address == "127.0.0.1" || address == "::1"
    }
}

/// Live per-million-token pricing from Darkbloom's public catalog endpoint
/// (`https://api.darkbloom.dev/v1/pricing`). Darkbloom takes a 0% platform cut
/// from providers, so token rates directly reflect relative per-token earning
/// potential when ranking fitting models on this Mac.
public struct DarkbloomPricing: Decodable, Equatable, Sendable {
    public static let endpoint = URL(string: "https://api.darkbloom.dev/v1/pricing")!

    public struct Price: Decodable, Equatable, Sendable {
        public var model: String
        /// Micro-USD per 1M input tokens (e.g. 35000 = $0.035 / 1M).
        public var inputPrice: Int
        /// Micro-USD per 1M output tokens (e.g. 1500000 = $1.50 / 1M).
        public var outputPrice: Int
        public var cacheReadPrice: Int?
        public var inputUsd: String?
        public var outputUsd: String?
        public var cacheReadUsd: String?

        public init(
            model: String, inputPrice: Int, outputPrice: Int,
            cacheReadPrice: Int? = nil, inputUsd: String? = nil, outputUsd: String? = nil, cacheReadUsd: String? = nil
        ) {
            self.model = model
            self.inputPrice = inputPrice
            self.outputPrice = outputPrice
            self.cacheReadPrice = cacheReadPrice
            self.inputUsd = inputUsd
            self.outputUsd = outputUsd
            self.cacheReadUsd = cacheReadUsd
        }

        public var inputPerMillion: Double { Double(inputPrice) / 1_000_000.0 }
        public var outputPerMillion: Double { Double(outputPrice) / 1_000_000.0 }

        /// Weighted earning score per 1M tokens (75% output, 25% input) since
        /// generation tokens dominate GPU time and provider revenue.
        public var earningScore: Double {
            inputPerMillion * 0.25 + outputPerMillion * 0.75
        }

        /// Compact "$0.035 | $1.50 / 1M" display matching Cloak's pricing format.
        public var compactRate: String {
            let input = Self.format(inputPerMillion)
            let output = Self.format(outputPerMillion)
            return "\(input) | \(output) / 1M"
        }

        private static func format(_ dollars: Double) -> String {
            let maxDigits = dollars < 0.10 ? 3 : 2
            return dollars.formatted(.currency(code: "USD").precision(.fractionLength(2...maxDigits)))
        }
    }

    public var prices: [Price]
    public var fallbackInputPrice: Int?
    public var fallbackOutputPrice: Int?

    public init(prices: [Price], fallbackInputPrice: Int? = nil, fallbackOutputPrice: Int? = nil) {
        self.prices = prices
        self.fallbackInputPrice = fallbackInputPrice
        self.fallbackOutputPrice = fallbackOutputPrice
    }

    public func price(for modelID: String) -> Price? {
        if let exact = prices.first(where: { $0.model == modelID }) { return exact }
        return prices.first { $0.model.caseInsensitiveCompare(modelID) == .orderedSame }
    }

    public var fallbackEarningScore: Double {
        let input = Double(fallbackInputPrice ?? 50_000) / 1_000_000.0
        let output = Double(fallbackOutputPrice ?? 200_000) / 1_000_000.0
        return input * 0.25 + output * 0.75
    }
}

/// Pure JSON decoder configured for Darkbloom's snake_case wire format.
public extension JSONDecoder {
    static var darkbloom: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}
