import CloakChat
import CloakControl
import CloakSupervisor
import CryptoKit
import Foundation
import Network
import Observation
import os

/// One app given a pass to the door. The pass itself is shown once, when the
/// app is added, and never kept: only its SHA-256.
public struct AgentApp: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let name: String
    public let added: Date
    let fingerprint: Data
    public internal(set) var requests = 0
    public internal(set) var lastUsed: Date?
}

/// One chat request at the door, for the Agents window: who sent it, the
/// model, how many user messages went reworded, where it is now and how
/// long it took, and, while it is among the newest `Door.latest`, each user
/// message as the app wrote it and as Cloak sent it. In memory only.
public struct AgentRequest: Identifiable, Sendable {
    public enum Sender: Equatable, Sendable {
        /// An app on this Mac, by its id.
        case app(UUID)
        /// The owner's agent in the guest.
        case agent
    }

    public enum Stage: Equatable, Sendable {
        case rewording
        case sending
        case answered
        /// In the plain words the request was answered with.
        case stopped(String)
        /// The app went before its answer: before the request was sent,
        /// and nothing was paid; or after, when it was paid for and its
        /// answer went unread.
        case left(paid: Bool)
    }

    /// One user message's text as the app wrote it, and the text Cloak sent
    /// in its place; a message of several text parts, each part on lines of
    /// its own.
    public struct Message: Sendable {
        public let written: String
        public let sent: String
    }

    public let id = UUID()
    public let sender: Sender
    public let started = Date.now
    private let clock = ContinuousClock.now
    /// Once the request has been read.
    public internal(set) var model: String?
    /// The user messages that went reworded, once every one has.
    public internal(set) var reworded: Int?
    /// Sensitive entities masked with reversible aliases before leaving this Mac.
    public internal(set) var shielded: Int?
    /// Detected credential kinds when the secret tripwire blocked this request before sending.
    public internal(set) var blockedSecret: String?
    public internal(set) var stage = Stage.rewording
    /// Once it is answered or stopped.
    public internal(set) var took: Duration?
    /// Each user message with text, in the order the app sent them, once
    /// every one is reworded and while the request is among the newest
    /// `Door.latest`; otherwise none.
    public internal(set) var messages: [Message] = []

    mutating func end(_ stage: Stage) {
        self.stage = stage
        took = clock.duration(to: .now)
    }
}

/// The apps, sealed in one owner-only file with ChaChaPoly under the
/// conversations' key, as `DepositStore` keeps the deposit.
struct AgentStore {
    let file: URL
    let key: SymmetricKey
    private static let tag = Data("agents".utf8)

    func load() throws -> [AgentApp] {
        let box = try ChaChaPoly.SealedBox(combined: Data(contentsOf: file))
        return try JSONDecoder().decode([AgentApp].self, from: ChaChaPoly.open(box, using: key, authenticating: Self.tag))
    }

    func save(_ apps: [AgentApp]) throws {
        try Places.makeOwnerOnly(file.deletingLastPathComponent())
        try ConversationStore.replace(file, with: try ChaChaPoly.seal(JSONEncoder().encode(apps), using: key, authenticating: Self.tag).combined)
    }
}

enum Pass {
    /// 32 random bytes, as "cloak-" and hex.
    static func make() -> String {
        "cloak-" + SymmetricKey(size: .bits256).withUnsafeBytes { bytes in bytes.map { String(format: "%02x", $0) }.joined() }
    }

    static func fingerprint(_ pass: some StringProtocol) -> Data {
        Data(SHA256.hash(data: Data(pass.utf8)))
    }

    /// Equal, in a time that does not depend on where they differ.
    static func same(_ a: Data, _ b: Data) -> Bool {
        a.count == b.count && zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// The door: the owner's other apps on this Mac send chat requests in
/// OpenAI's shape to one address, 127.0.0.1 only, each with a pass of its
/// own, and each request goes on as a V chat's does: every user message
/// reworded on this Mac (`Memory`), then paid through zkAPI by the guest's
/// payer, behind any of Chat's own (`PayQueue`, rank `door`; decision 24 in
/// docs/plan.md). The owner's agent in the guest sends its requests the same
/// way, from the guest's door port, each conversation with a box pass of its
/// own (`pass(for:paying:)`, decision 12), and each paid as its chat is: a
/// V chat's through the payer, a Token Inference chat's through the guest's
/// sender, Tor and the one Tempo wallet (decisions 10, 25 and 26).
/// Open only while Cloak is Running. No message's text is logged or written
/// to disk: an app's requests are counted, and its last one timed, and the
/// latest chat requests are listed with their counts and times, the newest
/// `latest` of them with each user message as written and as sent, in
/// memory only until Cloak quits.
@MainActor
@Observable
public final class Door {
    public enum State: Equatable, Sendable {
        case closed
        case open
        /// It could not open.
        case refused(Refusal)
    }

    /// Why the door could not open.
    public enum Refusal: Equatable, Sendable {
        /// The apps' file could not be read, so no pass could be checked.
        case appsUnread
        /// Another app holds this port.
        case portTaken(UInt16)
        /// The address could not be opened, for any other reason.
        case address
    }

    /// Where Mac apps connected through `CloakDoor` route their requests.
    public enum MacRoute: Equatable, Sendable {
        case zkapi
        case tempo
        /// 100% on-device local inference ($0/token, no Tor/VM required) via Cloak's
        /// built-in worker or a detected loopback local server (Splash / TensorFold / LM Studio / mlx-serve / Ollama).
        case local
        /// Hardware-attested NEAR AI Gateway (Intel TDX + NVIDIA GPU E2EE v2 via `cloak-near`).
        case near
        /// Venice AI (Base USDC x402 wallet or Venice API key, Tor or direct HTTPS).
        case venice
    }

    /// What the door works with: in the app, the supervisor's and the
    /// keychain's.
    public struct Parts: Sendable {
        let reword: @Sendable ([String]) async throws(RewriteStop) -> [String]
        /// The one way to the guest's payer, shared with Chat.
        let queue: PayQueue
        let exchange: Exchange
        /// The wallet's address; nil when there is none.
        let wallet: @Sendable () async throws -> String?
        let key: Remote.Key
        /// The conversations' key, found, or made when there is none.
        let sealing: @Sendable () async throws -> SymmetricKey?
        /// How Mac apps connected through the door route (`local`, `near`, `venice`, `tempo`, or `zkapi`).
        let macRoute: @Sendable () -> MacRoute
        /// Optional fail-closed Security Profile check; returns a plain-English refusal if `route` is disallowed.
        let routeAllowed: @Sendable (MacRoute) -> String?
        /// OpenAI `/v1/models` JSON returned when `macRoute() == .local`.
        let localModels: @Sendable () async throws -> Data
        /// Executes an OpenAI `/v1/chat/completions` JSON request locally on this Mac when `macRoute() == .local`.
        let localComplete: @Sendable (Data) async throws -> Data
        /// OpenAI `/v1/models` JSON returned when `macRoute() == .near`.
        let nearModels: @Sendable () async throws -> Data
        /// Executes an OpenAI `/v1/chat/completions` JSON request through NEAR TEE when `macRoute() == .near`.
        let nearComplete: @Sendable (Data) async throws -> Data
        /// OpenAI `/v1/models` JSON returned when `macRoute() == .venice`.
        let veniceModels: @Sendable () async throws -> Data
        /// Executes an OpenAI `/v1/chat/completions` JSON request through Venice when `macRoute() == .venice`.
        let veniceComplete: @Sendable (Data, String) async throws -> Data
        /// Preferred Venice model ID when mapping an unknown Claude/OpenAI alias on `.venice`.
        let preferredVeniceModel: @Sendable () -> String?
        /// Preferred default model ID for a payment rail when an Anthropic
        /// client sends a Claude alias the provider does not list verbatim.
        let preferredModel: @Sendable (Payment) -> String?
        /// Optional user-configured model ID that overrides the requested model
        /// for Mac apps when listed by the provider.
        let forcedModel: @Sendable () -> String?
        /// Deterministic local spending ledger enforcing budgets outside the LLM.
        let spendLedger: SpendLedger
        /// Current spending policy snapshot read before each Mac app payment.
        let spendPolicy: @Sendable () -> SpendPolicy
        /// Conservative per-request max spend estimate (micro-USD) reserved before send.
        let requestMaxMicroUSD: @Sendable (Payment) -> UInt64
        /// Pre-send Privacy Shield policy (secret tripwire + reversible alias masking).
        let privacyPolicy: @Sendable () -> PrivacyShieldPolicy

        public init(
            reword: @escaping @Sendable ([String]) async throws(RewriteStop) -> [String], queue: PayQueue,
            exchange: @escaping Exchange, wallet: @escaping @Sendable () async throws -> String?, key: @escaping Remote.Key,
            sealing: @escaping @Sendable () async throws -> SymmetricKey?,
            macPayment: @escaping @Sendable () -> Payment = { .zkapi },
            macRoute: (@Sendable () -> MacRoute)? = nil,
            routeAllowed: @escaping @Sendable (MacRoute) -> String? = { _ in nil },
            localModels: @escaping @Sendable () async throws -> Data = {
                Data(#"{"object":"list","data":[{"id":"cloak-local"}]}"#.utf8)
            },
            localComplete: (@Sendable (Data) async throws -> Data)? = nil,
            nearModels: @escaping @Sendable () async throws -> Data = {
                Data(#"{"object":"list","data":[{"id":"Qwen/Qwen3.8-27B","object":"model","owned_by":"near-ai"}]}"#.utf8)
            },
            nearComplete: (@Sendable (Data) async throws -> Data)? = nil,
            veniceModels: (@Sendable () async throws -> Data)? = nil,
            veniceComplete: (@Sendable (Data, String) async throws -> Data)? = nil,
            preferredVeniceModel: @escaping @Sendable () -> String? = { nil },
            preferredModel: @escaping @Sendable (Payment) -> String? = { _ in nil },
            forcedModel: @escaping @Sendable () -> String? = { nil },
            spendLedger: SpendLedger = SpendLedger(),
            spendPolicy: @escaping @Sendable () -> SpendPolicy = { .disabled },
            requestMaxMicroUSD: @escaping @Sendable (Payment) -> UInt64 = { _ in 50_000 },
            privacyPolicy: @escaping @Sendable () -> PrivacyShieldPolicy = { .disabled }
        ) {
            self.reword = reword
            self.queue = queue
            self.exchange = exchange
            self.wallet = wallet
            self.key = key
            self.sealing = sealing
            self.macRoute = macRoute ?? {
                switch macPayment() {
                case .zkapi: .zkapi
                case .tempo: .tempo
                }
            }
            self.routeAllowed = routeAllowed
            self.localModels = localModels
            self.localComplete = localComplete ?? { _ in
                throw Failure(503, "local_unavailable", "Local inference is not configured for Connected Apps.")
            }
            self.nearModels = nearModels
            self.nearComplete = nearComplete ?? { _ in
                throw Failure(503, "near_unavailable", "NEAR AI Gateway is not configured for Connected Apps.")
            }
            self.veniceModels = veniceModels ?? {
                throw Failure(503, "venice_unavailable", "Venice AI is not configured for Connected Apps.")
            }
            self.veniceComplete = veniceComplete ?? { _, _ in
                throw Failure(503, "venice_unavailable", "Venice AI is not configured for Connected Apps.")
            }
            self.preferredVeniceModel = preferredVeniceModel
            self.preferredModel = preferredModel
            self.forcedModel = forcedModel
            self.spendLedger = spendLedger
            self.spendPolicy = spendPolicy
            self.requestMaxMicroUSD = requestMaxMicroUSD
            self.privacyPolicy = privacyPolicy
        }
    }

    public private(set) var state = State.closed
    /// In the order they were added.
    public private(set) var apps: [AgentApp] = []
    /// The apps could not be read, or a change to them not kept.
    public private(set) var problem: String?
    /// The latest chat requests, newest first, at most 200. In memory only,
    /// never on disk or in the log, and kept until Cloak quits. Only the
    /// newest `latest` keep their messages' texts.
    public private(set) var requests: [AgentRequest] = []
    /// Live local spending totals and recent privacy-safe receipts.
    public private(set) var spendSnapshot: SpendSnapshot = .empty
    /// The requests the Agents window lists, newest first, and the only
    /// ones that keep their messages' texts.
    public static let latest = 20
    /// The port taken at the last open or move, until the door closes.
    private var opened: UInt16?

    private enum Access {
        case unread
        /// A single coalesced load in flight so concurrent `load()` callers
        /// share one Keychain/disk read instead of racing.
        case loading(Task<Void, Never>)
        /// The key is there once there is a file of apps.
        case read(SymmetricKey?)
        case failed
    }

    @ObservationIgnored private var access = Access.unread
    @ObservationIgnored private let file: URL
    @ObservationIgnored private let walletFolder: URL
    @ObservationIgnored private let parts: Parts
    /// The one port, on 127.0.0.1 only, asked at each open: in the app, the
    /// Settings window's.
    @ObservationIgnored private let chosen: () -> UInt16
    @ObservationIgnored private var listener: NWListener?
    /// Callers awaiting `open()`'s transition out of `.closed` to `.open` or `.refused`.
    @ObservationIgnored private var openWaiters: [CheckedContinuation<Void, Never>] = []
    /// Result of a live loopback `/v1/models` connection check from Connected Apps.
    public struct ConnectionCheck: Equatable, Sendable {
        public let ok: Bool
        public let summary: String
        public let modelCount: Int

        public init(ok: Bool, summary: String, modelCount: Int = 0) {
            self.ok = ok
            self.summary = summary
            self.modelCount = modelCount
        }
    }

    private var serving: [UUID: Task<Void, Never>] = [:]
    /// By app, and by the agent's conversation.
    @ObservationIgnored private var memories: [UUID: Memory] = [:]
    /// Reversible alias maps per app, in memory only (cleared on `remove` and `close`).
    @ObservationIgnored private var redactionMaps: [UUID: RedactionMap] = [:]
    /// Ephemeral one-shot probe pass fingerprint used only during `verifyConnection()`.
    @ObservationIgnored private var probeFingerprint: Data?
    private static let probeAppID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    /// Serializes memory read-rewrite-commit per app so concurrent requests
    /// from the same app never desynchronize digests from transcripts.
    @ObservationIgnored private var memoryTurns: [UUID: Task<Void, Never>] = [:]
    /// Coalesced background flush of request counts so `admit` never blocks
    /// the main actor with `fsync` on every HTTP call.
    @ObservationIgnored private var appFlush: Task<Void, Never>?
    /// Short-lived cache for `/v1/models` per route so Connected Apps and
    /// Pi Agent turns don't pay an extra Tor round-trip on every single request.
    @ObservationIgnored private var modelsCache: [MacRoute: (data: Data, at: Date)] = [:]
    private static let modelsCacheTTL: TimeInterval = 60
    /// The box passes, by the agent's conversation, and how each
    /// conversation pays, until the door closes.
    @ObservationIgnored private var boxes: [UUID: (pass: String, fingerprint: Data, payment: Payment)] = [:]
    @ObservationIgnored private let logger = Logger(subsystem: "sh.regents.cloak.app", category: "door")

    /// Where a request comes from: an app on this Mac, on 127.0.0.1, or the
    /// agent in the guest, from its door port. Each side's passes work on
    /// that side only.
    private enum Side {
        case mac
        case guest
    }

    public init(file: URL, wallet: URL, parts: Parts, port: @escaping () -> UInt16) {
        self.file = file
        self.walletFolder = wallet
        self.parts = parts
        self.chosen = port
    }

    /// The port the door listens on from its open until it closes, and
    /// otherwise the one it opens on next.
    public var port: UInt16 { opened ?? chosen() }

    /// What an OpenAI-compatible app is pointed at.
    public var address: String { "http://127.0.0.1:\(port)/v1" }

    /// What Anthropic SDK / Claude Code (`ANTHROPIC_BASE_URL`) is pointed at.
    public var baseURL: String { "http://127.0.0.1:\(port)" }

    /// Refreshes the published spend snapshot from `parts.spendLedger`.
    public func refreshSpendSnapshot() async {
        spendSnapshot = await parts.spendLedger.snapshot()
    }

    /// Clears settled/released spend receipts from history (in-flight reservations stay).
    public func clearSpendReceipts() async {
        await parts.spendLedger.clearHistory()
        spendSnapshot = await parts.spendLedger.snapshot()
    }

    /// Reads the apps; with no file of them, there are none and no key is
    /// needed yet. Concurrent callers coalesce onto the single in-flight read.
    public func load() async {
        switch access {
        case .read:
            return
        case .loading(let task):
            await task.value
            return
        case .unread, .failed:
            break
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard FileManager.default.fileExists(atPath: self.file.path) else {
                    self.access = .read(nil)
                    return
                }
                guard let key = try await self.parts.sealing() else { throw CocoaError(.fileReadNoPermission) }
                self.apps = try AgentStore(file: self.file, key: key).load()
                self.access = .read(key)
                self.problem = nil
            } catch {
                self.logger.error("cannot read the apps: \(String(describing: error), privacy: .public)")
                self.access = .failed
                self.problem = "Cloak couldn't read your apps."
            }
        }
        access = .loading(task)
        await task.value
    }

    /// Adds an app. Returns its pass, to be shown once; nil when it could
    /// not be kept.
    public func add(_ name: String) async -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        await load()
        let key: SymmetricKey
        switch access {
        case .read(let found?):
            key = found
        case .read(nil):
            do {
                guard let made = try await parts.sealing() else { throw CocoaError(.fileReadNoPermission) }
                key = made
                access = .read(made)
            } catch {
                logger.error("cannot get the key for the apps: \(String(describing: error), privacy: .public)")
                problem = "Cloak couldn't keep the app."
                return nil
            }
        case .unread, .loading, .failed:
            return nil
        }
        let pass = Pass.make()
        guard keep(apps + [AgentApp(id: UUID(), name: name, added: .now, fingerprint: Pass.fingerprint(pass))], key: key) else {
            return nil
        }
        return pass
    }

    /// Removes an app: its pass stops working for every request after this.
    public func remove(_ id: UUID) {
        guard case .read(let key?) = access, keep(apps.filter { $0.id != id }, key: key) else { return }
        memories[id] = nil
        redactionMaps[id] = nil
    }

    private func keep(_ apps: [AgentApp], key: SymmetricKey) -> Bool {
        appFlush?.cancel()
        appFlush = nil
        do {
            try AgentStore(file: file, key: key).save(apps)
            self.apps = apps
            problem = nil
            return true
        } catch {
            logger.error("cannot keep the apps: \(String(describing: error), privacy: .public)")
            problem = "Cloak couldn't keep the change to your apps."
            return false
        }
    }

    private func scheduleKeep(key: SymmetricKey) {
        appFlush?.cancel()
        let snapshot = apps
        let store = AgentStore(file: file, key: key)
        appFlush = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            do {
                try await Self.saveApps(snapshot, to: store)
            } catch {
                logger.error("cannot keep the apps: \(String(describing: error), privacy: .public)")
            }
        }
    }

    @concurrent
    private static func saveApps(_ apps: [AgentApp], to store: AgentStore) async throws {
        try store.save(apps)
    }

    // MARK: Opening and closing

    /// Listens on 127.0.0.1 and the one port, and nowhere else; refused
    /// (`Refusal`) when the port is taken or the apps can't be read. Open on
    /// another port than the one chosen now, it moves to that one: only the
    /// listener changes, so requests under way keep their connections and
    /// the box passes stay.
    public func open() async {
        if listener != nil && opened == chosen() {
            if state == .closed {
                await withCheckedContinuation { openWaiters.append($0) }
            }
            return
        }
        listener?.cancel()
        listener = nil
        resumeOpenWaiters()
        await load()
        guard case .read = access else {
            state = .refused(.appsUnread)
            return
        }
        let port = chosen()
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            opened = nil
            state = .refused(.address)
            return
        }
        opened = port
        state = .closed
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: endpointPort)
        parameters.allowLocalEndpointReuse = false
        parameters.acceptLocalOnly = true
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            logger.error("door cannot listen: \(String(describing: error), privacy: .public)")
            opened = nil
            state = .refused(.address)
            return
        }
        listener.stateUpdateHandler = { [weak self, weak listener] change in
            MainActor.assumeIsolated {
                guard let self, let listener, self.listener === listener else { return }
                self.changed(change)
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated {
                guard let self else { return connection.cancel() }
                connection.start(queue: .main)
                self.accept(connection, from: .mac)
            }
        }
        self.listener = listener
        listener.start(queue: .main)
        if self.listener === listener && state == .closed {
            await withCheckedContinuation { openWaiters.append($0) }
        }
    }

    private func resumeOpenWaiters() {
        let waiters = openWaiters
        openWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    private func changed(_ change: NWListener.State) {
        switch change {
        case .ready:
            if opened == 0, let bound = listener?.port?.rawValue {
                opened = bound
            }
            logger.info("door open on 127.0.0.1:\(self.port, privacy: .public)")
            state = .open
            resumeOpenWaiters()
        case .failed(let error), .waiting(let error):
            let attempted = port
            logger.error("door refused: \(String(describing: error), privacy: .public)")
            listener?.cancel()
            listener = nil
            opened = nil
            state = .refused(error == .posix(.EADDRINUSE) ? .portTaken(attempted) : .address)
            resumeOpenWaiters()
        case .cancelled:
            resumeOpenWaiters()
        default:
            break
        }
    }

    /// Stops listening, drops the box passes and what was remembered of their
    /// conversations, and ends every request under way, each with a plain
    /// error to its app; returns once each has been answered.
    public func close() async {
        listener?.cancel()
        listener = nil
        if state == .open { logger.info("door closed") }
        state = .closed
        opened = nil
        resumeOpenWaiters()
        for conversation in boxes.keys {
            memories[conversation] = nil
            memoryTurns[conversation] = nil
        }
        redactionMaps = [:]
        probeFingerprint = nil
        boxes = [:]
        let serving = Array(self.serving.values)
        for task in serving { task.cancel() }
        for task in serving { await task.value }
        if let pending = appFlush {
            pending.cancel()
            appFlush = nil
            if case .read(let key?) = access {
                try? await Self.saveApps(apps, to: AgentStore(file: file, key: key))
            }
        }
    }

    /// Runs `Memory.rewrite` for `app` one request at a time and commits the
    /// updated digests, Tor identity and transcript only once rewriting
    /// succeeds, so concurrent or failed requests never corrupt `memories`.
    private func rewriteInOrder(for app: UUID, asked: Asked) async throws(Failure) -> (identity: String, messages: [[UInt8]]) {
        let previous = memoryTurns[app]
        let (done, release) = AsyncStream<Void>.makeStream()
        let marker = Task {
            for await _ in done {}
        }
        memoryTurns[app] = marker
        defer {
            release.finish()
            if memoryTurns[app] == marker { memoryTurns[app] = nil }
        }
        if let previous {
            await previous.value
        }
        guard !Task.isCancelled else { throw Failure(503, "cloak_stopped", "Cloak was paused or stopped.") }
        var memory = memories[app] ?? Memory()
        let identity = memory.identity(for: asked.messages)
        let (messages, transcript) = try await memory.rewrite(asked, reword: parts.reword)
        memory.transcript = transcript
        if apps.contains(where: { $0.id == app }) || boxes[app] != nil {
            memories[app] = memory
        }
        return (identity, messages)
    }

    /// A request is at the door: from its connection's start until it has
    /// been answered or has ended.
    public var underWay: Bool { !serving.isEmpty }

    // MARK: The agent in the guest

    /// The box pass of one of the owner's agent conversations, made the
    /// first time it is asked for: the agent sends that conversation's
    /// requests with it, from the guest, and the door takes it there only.
    /// It is kept in memory only, never with the apps, and dropped when the
    /// door closes; nil while the door is not open. The conversation's
    /// requests are paid as `payment` says, which its first task fixed.
    public func pass(for conversation: UUID, paying payment: Payment) -> String? {
        guard state == .open else { return nil }
        if let box = boxes[conversation] { return box.pass }
        let pass = Pass.make()
        boxes[conversation] = (pass, Pass.fingerprint(pass), payment)
        return pass
    }

    /// The last user message of one of the owner's agent conversations as
    /// the door last reworded it: its text, or its texts on lines of their
    /// own. Nil before the door has reworded one, and once the door closes.
    public func reworded(for conversation: UUID) -> String? {
        guard boxes[conversation] != nil, let user = memories[conversation]?.transcript.last(where: { $0.user != nil })?.user
        else { return nil }
        return Self.text(ofUser: user)
    }

    /// A user message's text as it is written in these bytes: its content,
    /// or its non-blank text parts on lines of their own. Nil when it has
    /// none.
    private nonisolated static func text(ofUser message: [UInt8]) -> String? {
        guard let content = (try? GoJSON.read(message))?.members?["content"] else { return nil }
        switch content.value {
        case .string(let text):
            return text
        case .array(let parts):
            let texts = parts.compactMap { part -> String? in
                guard let part = part.members, (try? part["type"]?.string()) == "text", case .string(let text)? = part["text"]?.value,
                    !Asked.isBlank(text)
                else { return nil }
                return text
            }
            return texts.isEmpty ? nil : texts.joined(separator: "\n")
        default:
            return nil
        }
    }

    /// Serves one connection from the guest's door port, the socket it
    /// takes, as any app's, while the door is open; closes it otherwise, or
    /// when the guest has closed it already.
    public func accept(guest socket: Int32) {
        guard state == .open else {
            Darwin.close(socket)
            return
        }
        if let link = GuestLink.take(socket) { accept(link, from: .guest) }
    }

    // MARK: Requests

    private func accept(_ connection: some Link, from side: Side) {
        let id = UUID()
        serving[id] = Task {
            await serve(connection, from: side)
            serving[id] = nil
        }
    }

    /// One request, then the connection closes. Its head and body must
    /// arrive within `HTTPRequest.readLimit`; a pass is checked before the
    /// body is read; then it is routed while its connection is watched
    /// (`routing`).
    private func serve(_ connection: some Link, from side: Side) async {
        let started = ContinuousClock.now
        let limit = Task {
            try? await Task.sleep(for: HTTPRequest.readLimit)
            if !Task.isCancelled { connection.cancel() }
        }
        var isAnthropic = false
        do {
            let (request, after) = try await HTTPRequest.head(connection)
            isAnthropic = request.path.hasPrefix("/v1/messages")
            let (app, route) = try admit(request, from: side)
            let body = try await request.body(after: after, from: connection)
            limit.cancel()
            await routing(request, body: body, for: app, route: route, from: side, on: connection, since: started)
        } catch let failure as Failure {
            limit.cancel()
            await answer(failure.response(anthropic: isAnthropic), on: connection, since: started)
        } catch {
            // It ended, ran out of time or was cancelled before a whole request.
            limit.cancel()
            connection.cancel()
        }
    }

    /// Writes `response`, then closes the connection.
    private func answer(_ response: HTTPResponse, on connection: some Link, since started: ContinuousClock.Instant) async {
        await connection.write(response.bytes, final: true)
        connection.cancel()
        logger.info("door answered \(response.status, privacy: .public) after \(started.duration(to: .now), privacy: .public)")
    }

    /// Where a request is from its body's reading to its connection's end.
    private enum Routing {
        /// Being read, checked, reworded and made ready to send (`route`):
        /// an app that leaves ends it here, and nothing is paid.
        case preparing
        /// Its app left while it was being made ready; its work is ending.
        case dropped
        /// Sent (`send`), which pays for it: it goes on to its answer though
        /// its app leaves, since one cut now may be charged.
        case sending
        /// Sent, and its app has left: its answer will go unread.
        case unread
        /// Answered, and its connection closed.
        case answered
    }

    /// What one piece of a request's work came to.
    private enum Routed: Sendable {
        /// The answer to write: the list of models, or a refusal.
        case answer(HTTPResponse)
        /// A listed chat request that stopped before it was sent.
        case stopped(AgentRequest.ID, Failure)
        /// A listed chat request ready to send.
        case ready(Ready)
        /// A listed chat request sent: the provider's answer, or why it
        /// stopped.
        case sent(AgentRequest.ID, Result<HTTPResponse, Failure>)
        /// The connection ended: its app left, or the door closed it.
        case ended
    }

    /// A chat request with every user message reworded, ready to send.
    /// Provider pricing and protocol-cap metadata parsed from `/v1/models`.
    private struct ModelPricing: Sendable, Equatable {
        /// zkAPI protocol-enforced per-request ticket ceiling (`oaRequestLimitMicroUsd`).
        let protocolCapMicroUSD: UInt64?
        /// US dollars per 1,000,000 input tokens (equivalent to micro-USD per input token).
        let inputPerMillionUSD: Double?
        /// US dollars per 1,000,000 output tokens (equivalent to micro-USD per output token).
        let outputPerMillionUSD: Double?
    }

    /// Sending it pays for it.
    private struct Ready: Sendable {
        /// How it is paid: through the payer, in its turn, or from the Tempo
        /// wallet, whose deposit is kept here.
        enum Way: Sendable {
            case payer
            case wallet(DepositStore)
            case local
            case near
            case venice
        }

        let app: UUID
        let listed: AgentRequest.ID
        let body: Data
        let identity: String
        let streaming: Bool
        /// Non-nil when the request arrived on `/v1/messages`; holds the model
        /// name the Anthropic client asked for so responses echo it back.
        let anthropicModel: String?
        /// Atomic SpendLedger reservation ID held until settlement or release.
        let reservationID: UUID?
        let estimatedMaxMicroUSD: UInt64
        let pricing: ModelPricing?
        let restoreAliases: Bool
        let way: Way
    }

    /// Verifies live loopback connectivity, Bearer auth, and provider model listing
    /// over `http://127.0.0.1:<port>/v1/models` using a one-shot in-memory probe token
    /// that can only access `GET /v1/models` and is cleared immediately afterward.
    public func verifyConnection() async -> ConnectionCheck {
        guard state == .open else {
            return ConnectionCheck(ok: false, summary: "Door is closed. Start Cloak to open 127.0.0.1:\(port).")
        }
        let pass = Pass.make()
        let currentPort = port
        probeFingerprint = Pass.fingerprint(pass)
        defer { probeFingerprint = nil }

        guard let url = URL(string: "http://127.0.0.1:\(currentPort)/v1/models") else {
            return ConnectionCheck(ok: false, summary: "Invalid local door address.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(pass)", forHTTPHeaderField: "Authorization")

        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.httpCookieStorage = nil
        config.urlCache = nil
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return ConnectionCheck(ok: false, summary: "Door returned a non-HTTP response.")
            }
            if http.statusCode == 200, let ids = Self.orderedIDs(data) {
                let noun = ids.count == 1 ? "model" : "models"
                return ConnectionCheck(
                    ok: true,
                    summary: "Connected on 127.0.0.1:\(currentPort) · \(ids.count) \(noun) ready",
                    modelCount: ids.count)
            }
            if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let err = root["error"] as? [String: Any],
                let message = err["message"] as? String, !message.isEmpty
            {
                return ConnectionCheck(ok: false, summary: message)
            }
            return ConnectionCheck(ok: false, summary: "Door answered HTTP \(http.statusCode).")
        } catch {
            return ConnectionCheck(ok: false, summary: error.localizedDescription)
        }
    }

    /// Routes one request read whole while watching its connection, and
    /// lists a chat request's end. An app that leaves before its request is
    /// sent ends it there: nothing more is reworded, sent or paid. One sent
    /// has been handed on to be paid for (`send`), and goes on to its
    /// answer, which an app that has left never reads.
    private func routing(
        _ request: HTTPRequest, body: [UInt8], for app: UUID, route: MacRoute, from side: Side, on connection: some Link,
        since started: ContinuousClock.Instant
    ) async {
        let isAnthropic = request.path.hasPrefix("/v1/messages")

        /// Writes `response` while the app is there to read it.
        func finish(_ response: HTTPResponse, at stage: inout Routing) async {
            guard stage == .preparing || stage == .sending else { return }
            await answer(response, on: connection, since: started)
            stage = .answered
        }

        await withTaskGroup(of: Routed.self) { group in
            group.addTask {
                await connection.ended()
                return .ended
            }
            group.addTask { await self.route(request, body: body, for: app, route: route, from: side) }
            var stage = Routing.preparing
            while let routed = await group.next() {
                switch routed {
                case .ended:
                    switch stage {
                    case .preparing:
                        stage = .dropped
                        group.cancelAll()
                    case .sending:
                        stage = .unread
                    case .dropped, .unread, .answered:
                        continue
                    }
                    connection.cancel()
                    logger.info("door request's app left after \(started.duration(to: .now), privacy: .public)")
                case .answer(let response):
                    await finish(response, at: &stage)
                case .stopped(let listed, let failure):
                    note(listed) { $0.end(stage == .dropped ? .left(paid: false) : .stopped(failure.message)) }
                    await finish(failure.response(anthropic: isAnthropic), at: &stage)
                case .ready(let ready):
                    guard stage == .preparing else {
                        if let reservationID = ready.reservationID {
                            await parts.spendLedger.release(reservationID: reservationID, failed: false)
                            spendSnapshot = await parts.spendLedger.snapshot()
                        }
                        note(ready.listed) { $0.end(.left(paid: false)) }
                        continue
                    }
                    stage = .sending
                    note(ready.listed) { $0.stage = .sending }
                    group.addTask { await self.send(ready) }
                case .sent(let listed, .success(let response)):
                    note(listed) { $0.end(stage == .unread ? .left(paid: true) : .answered) }
                    await finish(response, at: &stage)
                case .sent(let listed, .failure(let failure)):
                    if ["tor_down", "tor_exit_blocked", "failed", "timed_out"].contains(failure.code) {
                        memories[app]?.rotateIdentity()
                    }
                    note(listed) { $0.end(.stopped(failure.message)) }
                    await finish(failure.response(anthropic: isAnthropic), at: &stage)
                }
            }
        }
    }

    /// Refuses a request from a web page, then one without a pass of this
    /// side's, as the daemon does (`ServeHTTP`, internal/server/server.go:70-97):
    /// from the Mac, an app's pass (`Authorization: Bearer` or `x-api-key`),
    /// and the app's request is counted; from the guest, a box pass. Returns
    /// the app, or the agent's conversation, and how its requests are paid:
    /// an app's as configured (`parts.macPayment`), a conversation's as its box says.
    private func admit(_ request: HTTPRequest, from side: Side) throws(Failure) -> (UUID, MacRoute) {
        guard request.headers["origin"] == nil, request.headers["sec-fetch-site"] != "cross-site" else { throw .origin }
        let rawPass: Substring
        if let header = request.headers["authorization"], header.hasPrefix("Bearer ") {
            rawPass = header.dropFirst("Bearer ".count)
        } else if let apiKey = request.headers["x-api-key"], !apiKey.isEmpty {
            rawPass = Substring(apiKey)
        } else {
            throw .pass
        }
        let presented = Pass.fingerprint(rawPass)
        if case .guest = side {
            var found: (UUID, MacRoute)?
            for (conversation, box) in boxes where Pass.same(box.fingerprint, presented) {
                found = (conversation, box.payment == .zkapi ? .zkapi : .tempo)
            }
            guard let found else { throw .pass }
            return found
        }
        if let probe = probeFingerprint, Pass.same(probe, presented) {
            guard request.method == "GET", request.path == "/v1/models" else { throw .pass }
            return (Self.probeAppID, parts.macRoute())
        }
        var found: Int?
        for (index, app) in apps.enumerated() where Pass.same(app.fingerprint, presented) {
            found = index
        }
        guard let found, case .read(let key?) = access else { throw .pass }
        apps[found].requests += 1
        apps[found].lastUsed = .now
        scheduleKeep(key: key)
        return (apps[found].id, parts.macRoute())
    }

    /// Routes one request up to the point where sending it would pay for
    /// it. A chat request is listed in `requests` from here; `routing` lists
    /// its end.
    private func route(_ request: HTTPRequest, body: [UInt8], for app: UUID, route: MacRoute, from side: Side) async -> Routed {
        let path = request.path
        let isAnthropic = path.hasPrefix("/v1/messages")
        do throws(Failure) {
            if side == .mac, let refusal = parts.routeAllowed(route) {
                throw Failure(403, "security_profile_blocked", refusal)
            }
            switch (request.method, path) {
            case ("GET", "/v1/models"):
                let list = try await models(route: route)
                guard (try? GoJSON.read([UInt8](list)))?.members != nil else { throw Self.unreadable }
                return .answer(HTTPResponse(status: 200, body: list))
            case ("POST", "/v1/messages/count_tokens"):
                try Asked.check(type: request.headers["content-type"])
                return .answer(try Anthropic.countTokens(body))
            case ("POST", "/v1/chat/completions"), ("POST", "/v1/messages"):
                let listed = AgentRequest(sender: side == .mac ? .app(app) : .agent)
                requests.insert(listed, at: 0)
                if requests.count > 200 { requests.removeLast() }
                // The one this pushed out of the newest drops its texts.
                if requests.count > Self.latest { requests[Self.latest].messages = [] }
                do throws(Failure) {
                    return .ready(try await prepare(
                        request, body: body, for: app, route: route, from: side,
                        anthropic: path == "/v1/messages", listed: listed.id))
                } catch {
                    return .stopped(listed.id, error)
                }
            case (_, "/v1/models"), (_, "/v1/chat/completions"), (_, "/v1/messages"), (_, "/v1/messages/count_tokens"):
                throw Failure(405, "method_not_allowed", "Method not allowed.")
            default:
                throw Failure(404, "not_found", "Cloak answers /v1/chat/completions, /v1/messages, and /v1/models only.")
            }
        } catch {
            return .answer(error.response(anthropic: isAnthropic))
        }
    }

    private static let unreadable = Failure(502, "invalid_upstream_response", "The provider's answer did not read.")

    /// The provider's list of models, as it gives it: the zkAPI service's
    /// through the payer, the Tempo wallet's provider's through the sender,
    /// or the local model list when routing on-device.
    private func models(route: MacRoute) async throws(Failure) -> Data {
        if route != .local, let cached = modelsCache[route], Date.now.timeIntervalSince(cached.at) < Self.modelsCacheTTL {
            return cached.data
        }
        let fresh: Data
        switch route {
        case .zkapi:
            do {
                fresh = try await parts.queue.call("GET", "/v1/models")
            } catch {
                throw Failure(error)
            }
        case .tempo:
            do {
                fresh = try await Remote.models(exchange: parts.exchange)
            } catch {
                throw Failure(error)
            }
        case .local:
            do {
                fresh = try await parts.localModels()
            } catch let failure as Failure {
                throw failure
            } catch {
                throw Failure(503, "local_unavailable", error.localizedDescription)
            }
        case .near:
            do {
                fresh = try await parts.nearModels()
            } catch let failure as Failure {
                throw failure
            } catch {
                throw Failure(503, "near_unavailable", error.localizedDescription)
            }
        case .venice:
            do {
                fresh = try await parts.veniceModels()
            } catch let failure as Failure {
                throw failure
            } catch {
                throw Failure(503, "venice_unavailable", error.localizedDescription)
            }
        }
        if route != .local {
            modelsCache[route] = (fresh, .now)
        }
        return fresh
    }

    /// Checks the request, then the model against the provider's list, then
    /// rewords each user message on this Mac (for remote rails), then checks
    /// wallet/budget; returns the request ready to send (`send`).
    private func prepare(
        _ request: HTTPRequest, body: [UInt8], for app: UUID, route: MacRoute, from side: Side,
        anthropic: Bool, listed: AgentRequest.ID
    ) async throws(Failure) -> Ready {
        try Asked.check(type: request.headers["content-type"])
        let openAIBytes: [UInt8]
        let requestedModel: String
        if anthropic {
            let translated = try Anthropic.translateRequest(body)
            openAIBytes = translated.openAIBytes
            requestedModel = translated.requestedModel
        } else {
            openAIBytes = body
            requestedModel = ""
        }
        let asked = try await Asked.read(openAIBytes)
        let clientModel = anthropic ? requestedModel : asked.model
        note(listed) { $0.model = clientModel }
        let policy = side == .mac ? parts.privacyPolicy() : .disabled
        if policy.blockSecrets {
            let findings = PrivacyShield.scanRequestJSONForSecrets(Data(openAIBytes))
            if !findings.isEmpty {
                let summary = findings.map(\.kind).joined(separator: ", ")
                note(listed) { $0.blockedSecret = summary }
                throw Failure(
                    400,
                    "secret_blocked",
                    "Blocked before sending: detected \(summary) in outbound request. Remove the secret and retry.")
            }
        }
        let modelList = try await models(route: route)
        guard let ordered = Self.orderedIDs(modelList) else { throw Self.unreadable }
        let ids = Set(ordered)
        let effectiveModel: String
        if route == .local {
            if let forced = parts.forcedModel()?.trimmingCharacters(in: .whitespacesAndNewlines),
                !forced.isEmpty, ids.contains(forced)
            {
                effectiveModel = forced
            } else if ids.contains(asked.model) {
                effectiveModel = asked.model
            } else if let first = ordered.first {
                effectiveModel = first
            } else {
                throw Failure(503, "local_unavailable", "No local model is ready on this Mac. Download one in Settings → Local Models.")
            }
        } else if route == .near {
            if let forced = parts.forcedModel()?.trimmingCharacters(in: .whitespacesAndNewlines),
                !forced.isEmpty, ids.contains(forced)
            {
                effectiveModel = forced
            } else if ids.contains(asked.model) {
                effectiveModel = asked.model
            } else if let first = ordered.first {
                effectiveModel = first
            } else {
                throw Failure(503, "near_unavailable", "NEAR AI Gateway lists no models right now.")
            }
        } else if route == .venice {
            if let forced = parts.forcedModel()?.trimmingCharacters(in: .whitespacesAndNewlines),
                !forced.isEmpty, ids.contains(forced)
            {
                effectiveModel = forced
            } else if ids.contains(asked.model) {
                effectiveModel = asked.model
            } else if let preferred = parts.preferredVeniceModel(), ids.contains(preferred) {
                effectiveModel = preferred
            } else if let first = ordered.first {
                effectiveModel = first
            } else {
                throw Failure(503, "venice_unavailable", "Venice lists no private models right now.")
            }
        } else if side == .mac, let forced = parts.forcedModel()?.trimmingCharacters(in: .whitespacesAndNewlines),
            !forced.isEmpty, ids.contains(forced)
        {
            effectiveModel = forced
        } else if ids.contains(asked.model) {
            effectiveModel = asked.model
        } else if anthropic {
            let payment: Payment = (route == .tempo) ? .tempo : .zkapi
            if let preferred = parts.preferredModel(payment), ids.contains(preferred) {
                effectiveModel = preferred
            } else if let first = ordered.first {
                effectiveModel = first
            } else {
                throw Failure(404, "model_not_found", "The provider lists no models right now.")
            }
        } else {
            throw Failure(404, "model_not_found", "The provider has no model \(asked.model).")
        }
        if effectiveModel != clientModel {
            note(listed) { $0.model = "\(clientModel) → \(effectiveModel)" }
        }
        let identity: String
        let messages: [[UInt8]]
        if route == .local || route == .near {
            // Local stays 100% on-device; NEAR sends E2EE v2 to a verified TEE enclave.
            // Both still pass through Privacy Shield below.
            identity = route == .local ? "local" : "near"
            messages = asked.messages.map { Array(asked.bytes[$0.value.span]) }
            note(listed) { entry in
                entry.reworded = 0
            }
        } else {
            (identity, messages) = try await rewriteInOrder(for: app, asked: asked)
            note(listed) { entry in
                entry.reworded = asked.messages.count { $0.draft != nil }
            }
        }
        let pairs = await Self.pairs(asked, sent: messages)
        if let index = requests.firstIndex(where: { $0.id == listed }), index < Self.latest {
            requests[index].messages = pairs
        }
        let way: Ready.Way
        switch route {
        case .local:
            way = .local
        case .near:
            way = .near
        case .venice:
            way = .venice
        case .zkapi:
            way = .payer
        case .tempo:
            let key = try await sealing()
            do {
                guard try await parts.wallet() != nil else {
                    throw Failure(402, "no_wallet", "Cloak has no wallet yet. Create one in Chat, under Funds.")
                }
            } catch let failure as Failure {
                throw failure
            } catch {
                logger.error("cannot read the wallet: \(String(describing: error), privacy: .public)")
                throw Failure(502, "failed", "Cloak couldn't read the wallet.")
            }
            way = .wallet(DepositStore(folder: walletFolder, key: key))
        }
        let modelOverride = effectiveModel == asked.model ? nil : effectiveModel
        var outboundBody = asked.body(messages, modelOverride: modelOverride)
        var restoreAliases = false
        if policy.isActive {
            var map = redactionMaps[app] ?? RedactionMap()
            let (protected, maskedCount): (Data, Int)
            do throws(Failure) {
                (protected, maskedCount) = try PrivacyShield.protectRequestJSON(outboundBody, map: &map, policy: policy)
            } catch {
                if error.code == "secret_blocked" {
                    note(listed) { $0.blockedSecret = error.message }
                }
                throw error
            }
            outboundBody = protected
            if policy.maskEntities {
                if !map.isEmpty {
                    redactionMaps[app] = map
                    restoreAliases = true
                }
                if maskedCount > 0 {
                    note(listed) { entry in
                        entry.shielded = maskedCount
                        entry.messages = entry.messages.map { pair in
                            var previewMap = map
                            let (maskedSent, _) = previewMap.mask(pair.sent, privateTerms: policy.privateTerms)
                            return AgentRequest.Message(written: pair.written, sent: maskedSent)
                        }
                    }
                }
            }
        }
        guard !Task.isCancelled else { throw .stopped }
        let modelPricing = Self.modelPricing(in: modelList, for: effectiveModel)
        let estimatedMax: UInt64
        var reservationID: UUID?
        if side == .mac, route == .zkapi || route == .tempo || route == .venice {
            let payment: Payment = (route == .zkapi) ? .zkapi : .tempo
            let spendPolicy = parts.spendPolicy()
            let currentSnapshot = await parts.spendLedger.snapshot()
            let committedToday = currentSnapshot.spentTodayMicroUSD.saturatingAdd(currentSnapshot.reservedMicroUSD)
            let remainingDaily = spendPolicy.dailyLimitMicroUSD > committedToday
                ? (spendPolicy.dailyLimitMicroUSD - committedToday)
                : 0
            let effectiveCap = min(spendPolicy.perCallLimitMicroUSD, remainingDaily)
            let budgetPlan = Self.planSpendAndCapOutput(
                body: outboundBody,
                pricing: modelPricing,
                fallbackMinMicroUSD: parts.requestMaxMicroUSD(payment),
                policyEnabled: spendPolicy.enabled,
                effectiveCapMicroUSD: effectiveCap
            )
            outboundBody = budgetPlan.body
            estimatedMax = budgetPlan.estimatedMaxMicroUSD
            let networkID: PaymentNetwork.ID = switch route {
            case .zkapi: .ethereum
            case .venice: .base
            case .tempo, .local, .near: .tempo
            }
            let spec = PaymentNetwork.network(for: networkID)
            let providerName: String = switch route {
            case .zkapi: "zkapi"
            case .venice: "venice"
            case .tempo, .local, .near: "boundless"
            }
            let appName = apps.first(where: { $0.id == app })?.name ?? "Connected App"
            let quote = SpendQuote(
                idempotencyKey: listed.uuidString,
                service: "Connected App · \(appName)",
                provider: providerName,
                network: networkID,
                expectedChainID: spec.chainID,
                asset: route == .zkapi ? "ETH" : spec.stableAsset,
                maxMicroUSD: estimatedMax,
                leavesThisMac: policy.maskEntities ? "Rewritten & alias-shielded prompt" : "Rewritten prompt only"
            )
            let decision = await parts.spendLedger.authorize(quote, policy: spendPolicy)
            spendSnapshot = await parts.spendLedger.snapshot()
            switch decision {
            case .approved(let id):
                reservationID = id
            case .idempotentReplay:
                throw Failure(409, "duplicate_request", "This payment authorization was already settled.")
            case .rejected(let rejection):
                throw Failure(402, "budget_limit_exceeded", rejection.message)
            }
        } else {
            estimatedMax = 0
        }
        return Ready(
            app: app, listed: listed, body: outboundBody, identity: identity,
            streaming: asked.streaming, anthropicModel: anthropic ? clientModel : nil,
            reservationID: reservationID, estimatedMaxMicroUSD: estimatedMax,
            pricing: modelPricing, restoreAliases: restoreAliases, way: way)
    }

    /// Sends a ready request, which pays for it: through the payer, in its
    /// turn, or from the Tempo wallet. Once handed on it is not cut short
    /// for an app that leaves (`routing`): the payer gives no sign of when
    /// it asks for the request's key, and one cut after that may be charged;
    /// the Tempo wallet's exchange, once begun, runs to its end.
    private func send(_ ready: Ready) async -> Routed {
        var providerResponded = false
        var dispatchedPaidRequest = false
        do throws(Failure) {
            guard !Task.isCancelled else { throw .stopped }
            let completion: Data
            switch ready.way {
            case .payer:
                dispatchedPaidRequest = true
                do {
                    completion = try await parts.queue.complete(ready.body, identity: ready.identity, rank: .door)
                } catch {
                    logger.error("door payment stopped: \(error.code.rawValue, privacy: .public) \(error.detail, privacy: .private)")
                    throw Failure(error)
                }
            case .wallet(let deposits):
                dispatchedPaidRequest = true
                do {
                    completion = try await Remote.complete(
                        ready.body, identity: ready.identity, key: parts.key, deposits: deposits, exchange: parts.exchange)
                } catch {
                    logger.error("door send stopped: \(error.code.rawValue, privacy: .public) \(error.detail, privacy: .private)")
                    throw Failure(error)
                }
            case .local:
                do {
                    completion = try await parts.localComplete(ready.body)
                } catch let failure as Failure {
                    throw failure
                } catch {
                    logger.error("door local completion failed: \(String(describing: error), privacy: .public)")
                    throw Failure(503, "local_failed", error.localizedDescription)
                }
            case .near:
                do {
                    completion = try await parts.nearComplete(ready.body)
                } catch let failure as Failure {
                    throw failure
                } catch {
                    logger.error("door NEAR completion failed: \(String(describing: error), privacy: .public)")
                    throw Failure(502, "near_failed", error.localizedDescription)
                }
            case .venice:
                dispatchedPaidRequest = true
                do {
                    completion = try await parts.veniceComplete(ready.body, ready.identity)
                } catch let failure as Failure {
                    throw failure
                } catch {
                    logger.error("door Venice completion failed: \(String(describing: error), privacy: .public)")
                    throw Failure(502, "venice_failed", error.localizedDescription)
                }
            }
            // The provider has returned a paid response: from this point on, a local
            // response-parsing error MUST NOT release the reservation.
            providerResponded = true
            var completionData = completion
            if ready.restoreAliases, let map = redactionMaps[ready.app], !map.isEmpty {
                let (restored, _) = PrivacyShield.restoreCompletionJSON(completionData, map: map)
                completionData = restored
            }
            let response: HTTPResponse
            if let anthropicModel = ready.anthropicModel {
                response = try Anthropic.answer(completionData, requestedModel: anthropicModel, streaming: ready.streaming)
            } else {
                response = try Asked.answer(completionData, streaming: ready.streaming)
            }
            if let reservationID = ready.reservationID {
                let charge = Self.actualMicroUSD(
                    from: completion,
                    pricing: ready.pricing,
                    fallback: ready.estimatedMaxMicroUSD)
                await parts.spendLedger.settle(reservationID: reservationID, actualMicroUSD: charge)
                spendSnapshot = await parts.spendLedger.snapshot()
            }
            return .sent(ready.listed, .success(response))
        } catch {
            if let reservationID = ready.reservationID {
                if providerResponded {
                    // Payment succeeded on the provider side, but translating/parsing the
                    // reply failed locally: settle actual usage if parseable, otherwise
                    // mark ambiguous so the daily budget is never falsely refunded.
                    await parts.spendLedger.markAmbiguous(reservationID: reservationID)
                } else if dispatchedPaidRequest, !Self.isDefinitePreChargeFailure(error) {
                    await parts.spendLedger.markAmbiguous(reservationID: reservationID)
                } else {
                    await parts.spendLedger.release(reservationID: reservationID, failed: true)
                }
                spendSnapshot = await parts.spendLedger.snapshot()
            }
            return .sent(ready.listed, .failure(error))
        }
    }

    private nonisolated static let fallbackInputPerMillionUSD: Double = 5.0
    private nonisolated static let fallbackOutputPerMillionUSD: Double = 15.0
    private nonisolated static let defaultUnboundedOutputTokens: Int = 4_096
    private nonisolated static let minAllowedOutputTokens: Int = 64

    /// Errors known to fail BEFORE any upstream provider charge occurs.
    private nonisolated static func isDefinitePreChargeFailure(_ error: Failure) -> Bool {
        if [400, 401, 402, 403, 404, 429].contains(error.status) { return true }
        return ["no_funds", "no_wallet", "model_not_found", "model_unavailable", "stopped"].contains(error.code)
    }

    /// Computes a worst-case micro-USD reservation from request size, output token cap,
    /// and model pricing / zkAPI protocol caps. When `policyEnabled` is true and the client
    /// omitted `max_tokens`/`max_completion_tokens`, injects an output token cap bounded to
    /// the remaining budget so the provider cannot run away past the user's limit.
    private nonisolated static func planSpendAndCapOutput(
        body: Data,
        pricing: ModelPricing?,
        fallbackMinMicroUSD: UInt64,
        policyEnabled: Bool,
        effectiveCapMicroUSD: UInt64
    ) -> (body: Data, estimatedMaxMicroUSD: UInt64) {
        let inputRate = pricing?.inputPerMillionUSD ?? Self.fallbackInputPerMillionUSD
        let outputRate = pricing?.outputPerMillionUSD ?? Self.fallbackOutputPerMillionUSD
        let inputTokens = max(1, (body.count + 2) / 3)
        let inputCostMicroUSD = UInt64(ceil(Double(inputTokens) * inputRate))
        let protoCap = pricing?.protocolCapMicroUSD ?? 0

        guard var root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            let defaultOutCost = UInt64(ceil(Double(Self.defaultUnboundedOutputTokens) * outputRate))
            let total = inputCostMicroUSD.saturatingAdd(defaultOutCost)
            return (body, max(fallbackMinMicroUSD, protoCap, total))
        }

        let explicitMaxTokens = (root["max_completion_tokens"] as? Int) ?? (root["max_tokens"] as? Int)
        if let maxOut = explicitMaxTokens, maxOut > 0 {
            let outputCostMicroUSD = UInt64(ceil(Double(maxOut) * outputRate))
            let tokenTotal = inputCostMicroUSD.saturatingAdd(outputCostMicroUSD)
            return (body, max(fallbackMinMicroUSD, protoCap, tokenTotal))
        }

        // Client omitted an output token limit. When Spend Guardrails are active,
        // bound `max_tokens` to what fits inside `effectiveCapMicroUSD` so an
        // unbounded completion cannot silently blow past the configured cap.
        if policyEnabled {
            if inputCostMicroUSD < effectiveCapMicroUSD {
                let remainingForOutput = effectiveCapMicroUSD - inputCostMicroUSD
                let safeOutputRate = max(0.01, outputRate)
                let affordableTokens = Int(floor(Double(remainingForOutput) / safeOutputRate))
                if affordableTokens >= Self.minAllowedOutputTokens {
                    let cappedTokens = min(affordableTokens, 16_384)
                    root["max_tokens"] = cappedTokens
                    let cappedBody = (try? JSONSerialization.data(withJSONObject: root, options: [.withoutEscapingSlashes])) ?? body
                    let outputCostMicroUSD = UInt64(ceil(Double(cappedTokens) * outputRate))
                    let boundedTotal = inputCostMicroUSD.saturatingAdd(outputCostMicroUSD)
                    return (cappedBody, max(fallbackMinMicroUSD, protoCap, boundedTotal))
                }
            }
            // Input + minimum reply already exceeds the remaining budget cap.
            let minReplyCost = UInt64(ceil(Double(Self.minAllowedOutputTokens) * outputRate))
            let minNeeded = inputCostMicroUSD.saturatingAdd(minReplyCost)
            return (body, max(fallbackMinMicroUSD, protoCap, minNeeded, effectiveCapMicroUSD.saturatingAdd(1)))
        }

        let defaultOutCost = UInt64(ceil(Double(Self.defaultUnboundedOutputTokens) * outputRate))
        let total = inputCostMicroUSD.saturatingAdd(defaultOutCost)
        return (body, max(fallbackMinMicroUSD, protoCap, total))
    }

    /// Computes actual spend from provider token counts and real model pricing WITHOUT
    /// artificially clipping larger responses down to the initial reservation estimate.
    private nonisolated static func actualMicroUSD(from completion: Data, pricing: ModelPricing?, fallback: UInt64) -> UInt64 {
        guard let object = try? JSONSerialization.jsonObject(with: completion) as? [String: Any],
            let usage = object["usage"] as? [String: Any]
        else { return fallback }
        let input = (usage["prompt_tokens"] as? Int) ?? (usage["input_tokens"] as? Int) ?? 0
        let output = (usage["completion_tokens"] as? Int) ?? (usage["output_tokens"] as? Int) ?? 0
        guard input > 0 || output > 0 else { return fallback }
        let inputRate = pricing?.inputPerMillionUSD ?? Self.fallbackInputPerMillionUSD
        let outputRate = pricing?.outputPerMillionUSD ?? Self.fallbackOutputPerMillionUSD
        let micro = UInt64(ceil((Double(input) * inputRate) + (Double(output) * outputRate)))
        return max(1, micro)
    }

    /// Extracts protocol cap (`oaRequestLimitMicroUsd`) and per-million token pricing
    /// for `modelID` from a provider's `/v1/models` JSON response.
    private nonisolated static func modelPricing(in list: Data, for modelID: String) -> ModelPricing? {
        guard let root = try? JSONSerialization.jsonObject(with: list) as? [String: Any],
            let models = root["data"] as? [[String: Any]],
            let match = models.first(where: { ($0["id"] as? String) == modelID })
        else { return nil }

        let protocolCap: UInt64? = {
            if let v = match["oaRequestLimitMicroUsd"] as? UInt64 { return v }
            if let v = match["oaRequestLimitMicroUsd"] as? Int, v > 0 { return UInt64(v) }
            if let s = match["oaRequestLimitMicroUsd"] as? String, let v = UInt64(s) { return v }
            return nil
        }()

        var inputPerMillion: Double?
        var outputPerMillion: Double?
        if let pricing = match["pricing"] as? [String: Any] {
            // Boundless / Venice format: USD per 1,000,000 tokens (`input`, `output`).
            if let inp = Self.doubleValue(pricing["input"]), inp >= 0 { inputPerMillion = inp }
            if let out = Self.doubleValue(pricing["output"]), out >= 0 { outputPerMillion = out }
            // OpenRouter / zkAPI format: USD per single token (`prompt`, `completion`).
            if inputPerMillion == nil, let prompt = Self.doubleValue(pricing["prompt"]), prompt >= 0 {
                inputPerMillion = prompt * 1_000_000.0
            }
            if outputPerMillion == nil, let comp = Self.doubleValue(pricing["completion"]), comp >= 0 {
                outputPerMillion = comp * 1_000_000.0
            }
        }
        guard protocolCap != nil || inputPerMillion != nil || outputPerMillion != nil else { return nil }
        return ModelPricing(
            protocolCapMicroUSD: protocolCap,
            inputPerMillionUSD: inputPerMillion,
            outputPerMillionUSD: outputPerMillion)
    }

    private nonisolated static func doubleValue(_ raw: Any?) -> Double? {
        if let d = raw as? Double { return d }
        if let i = raw as? Int { return Double(i) }
        if let s = raw as? String { return Double(s) }
        return nil
    }

    /// Each user message with text, as the app wrote it (its draft's texts)
    /// and as it goes (`sent`, the messages `Memory.rewrite` returns, in the
    /// same order), read off the main thread.
    @concurrent
    private static func pairs(_ asked: Asked, sent: [[UInt8]]) async -> [AgentRequest.Message] {
        zip(asked.messages, sent).compactMap { message, sent in
            guard let draft = message.draft, let text = text(ofUser: sent) else { return nil }
            return AgentRequest.Message(written: draft.texts.joined(separator: "\n"), sent: text)
        }
    }

    /// Changes a listed request, while it is still in the list.
    private func note(_ id: AgentRequest.ID, _ change: (inout AgentRequest) -> Void) {
        guard let index = requests.firstIndex(where: { $0.id == id }) else { return }
        change(&requests[index])
    }

    /// The conversations' key, which seals the deposit as it seals the apps:
    /// as read with the apps, or, when there are none (as for the agent's
    /// requests before any app is added), found or made now.
    private func sealing() async throws(Failure) -> SymmetricKey {
        if case .loading(let task) = access {
            await task.value
        }
        switch access {
        case .read(let key?):
            return key
        case .read(nil):
            do {
                guard let key = try await parts.sealing() else { throw CocoaError(.fileReadNoPermission) }
                access = .read(key)
                return key
            } catch {
                logger.error("cannot get the key for the deposit: \(String(describing: error), privacy: .public)")
                throw Failure(502, "failed", "Cloak couldn't read its key.")
            }
        case .unread, .loading, .failed:
            throw .stopped
        }
    }

    /// The model names in the provider's list (`data[].id`), preserving provider order.
    private static func orderedIDs(_ list: Data) -> [String]? {
        let bytes = [UInt8](list)
        guard let data = try? GoJSON.read(bytes).members?["data"], case .array(let models) = data.value else { return nil }
        return models.compactMap { model in
            guard case .string(let id)? = model.members?["id"]?.value else { return nil }
            return id
        }
    }
}

private extension UInt64 {
    func saturatingAdd(_ other: UInt64) -> UInt64 {
        let (sum, overflow) = addingReportingOverflow(other)
        return overflow ? .max : sum
    }
}
