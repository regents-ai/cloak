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
/// own, and each request goes on as Chat's do: every user message reworded
/// on this Mac (`Memory`), then sent through the guest's sender, Tor and
/// the one wallet (decision 10 in docs/plan.md). Open only while Cloak is
/// Running. No message's text is kept, shown or logged: an app's requests
/// are counted, and its last one timed.
@MainActor
@Observable
public final class Door {
    public enum State: Equatable, Sendable {
        case closed
        case open
        /// It could not open, in plain words.
        case refused(String)
    }

    /// What the door works with: in the app, the supervisor's and the
    /// keychain's.
    public struct Parts: Sendable {
        let reword: @Sendable ([String]) async throws(RewriteStop) -> [String]
        let exchange: Exchange
        /// The wallet's address; nil when there is none.
        let wallet: @Sendable () async throws -> String?
        let key: Remote.Key
        /// The conversations' key, found, or made when there is none.
        let sealing: @Sendable () async throws -> SymmetricKey?

        public init(
            reword: @escaping @Sendable ([String]) async throws(RewriteStop) -> [String], exchange: @escaping Exchange,
            wallet: @escaping @Sendable () async throws -> String?, key: @escaping Remote.Key,
            sealing: @escaping @Sendable () async throws -> SymmetricKey?
        ) {
            self.reword = reword
            self.exchange = exchange
            self.wallet = wallet
            self.key = key
            self.sealing = sealing
        }
    }

    /// The one port, on 127.0.0.1 only.
    public static let port: UInt16 = 8742

    public private(set) var state = State.closed
    /// In the order they were added.
    public private(set) var apps: [AgentApp] = []
    /// The apps could not be read, or a change to them not kept.
    public private(set) var problem: String?
    public let port: UInt16

    private enum Access {
        case unread
        /// The key is there once there is a file of apps.
        case read(SymmetricKey?)
        case failed
    }

    @ObservationIgnored private var access = Access.unread
    @ObservationIgnored private let file: URL
    @ObservationIgnored private let walletFolder: URL
    @ObservationIgnored private let parts: Parts
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var serving: [UUID: Task<Void, Never>] = [:]
    /// By app.
    @ObservationIgnored private var memories: [UUID: Memory] = [:]
    @ObservationIgnored private let logger = Logger(subsystem: "sh.regents.cloak.app", category: "door")

    public init(file: URL, wallet: URL, parts: Parts, port: UInt16 = Door.port) {
        self.file = file
        self.walletFolder = wallet
        self.parts = parts
        self.port = port
    }

    /// What an app is pointed at.
    public var address: String { "http://127.0.0.1:\(port)/v1" }

    /// Reads the apps; with no file of them, there are none and no key is
    /// needed yet.
    public func load() async {
        switch access {
        case .unread, .failed: break
        case .read: return
        }
        do {
            guard FileManager.default.fileExists(atPath: file.path) else {
                access = .read(nil)
                return
            }
            guard let key = try await parts.sealing() else { throw CocoaError(.fileReadNoPermission) }
            apps = try AgentStore(file: file, key: key).load()
            access = .read(key)
            problem = nil
        } catch {
            logger.error("cannot read the apps: \(String(describing: error), privacy: .public)")
            access = .failed
            problem = "Cloak couldn't read your apps."
        }
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
        case .unread, .failed:
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
    }

    private func keep(_ apps: [AgentApp], key: SymmetricKey) -> Bool {
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

    // MARK: Opening and closing

    /// Listens on 127.0.0.1 and the one port, and nowhere else; refused in
    /// plain words when the port is taken or the apps can't be read.
    public func open() async {
        guard listener == nil else { return }
        await load()
        guard case .read = access else {
            state = .refused("Cloak couldn't read your apps, so they can't connect.")
            return
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        parameters.allowLocalEndpointReuse = false
        parameters.acceptLocalOnly = true
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            logger.error("door cannot listen: \(String(describing: error), privacy: .public)")
            state = .refused("Apps can't connect: the address can't be opened.")
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
                self.accept(connection)
            }
        }
        self.listener = listener
        listener.start(queue: .main)
    }

    private func changed(_ change: NWListener.State) {
        switch change {
        case .ready:
            logger.info("door open on 127.0.0.1:\(self.port, privacy: .public)")
            state = .open
        case .failed(let error), .waiting(let error):
            logger.error("door refused: \(String(describing: error), privacy: .public)")
            listener?.cancel()
            listener = nil
            state = .refused(
                error == .posix(.EADDRINUSE)
                    ? "Another app is using 127.0.0.1:\(port), so apps can't connect. Quit it, then pause and start Cloak."
                    : "Apps can't connect: the address can't be opened.")
        default:
            break
        }
    }

    /// Stops listening and ends every request under way, each with a plain
    /// error to its app; returns once each has been answered.
    public func close() async {
        listener?.cancel()
        listener = nil
        if state == .open { logger.info("door closed") }
        state = .closed
        let serving = Array(self.serving.values)
        for task in serving { task.cancel() }
        for task in serving { await task.value }
    }

    // MARK: Requests

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        serving[id] = Task {
            await serve(connection)
            serving[id] = nil
        }
    }

    /// One request, then the connection closes. Its head and body must
    /// arrive within `HTTPRequest.readLimit`; a pass is checked before the
    /// body is read.
    private func serve(_ connection: NWConnection) async {
        let started = ContinuousClock.now
        connection.start(queue: .main)
        let limit = Task {
            try? await Task.sleep(for: HTTPRequest.readLimit)
            if !Task.isCancelled { connection.cancel() }
        }
        let response: HTTPResponse
        do {
            let (request, after) = try await HTTPRequest.head(connection)
            let app = try admit(request)
            let body = try await request.body(after: after, from: connection)
            limit.cancel()
            response = await route(request, body: body, for: app)
        } catch let failure as Failure {
            limit.cancel()
            response = failure.response
        } catch {
            // It ended, ran out of time or was cancelled before a whole request.
            limit.cancel()
            connection.cancel()
            return
        }
        await connection.write(response.bytes, final: true)
        connection.cancel()
        logger.info("door answered \(response.status, privacy: .public) after \(started.duration(to: .now), privacy: .public)")
    }

    /// Refuses a request from a web page, then one without a pass of an app
    /// here, as the daemon does (`ServeHTTP`, internal/server/server.go:70-97);
    /// counts the app's request. Returns the app.
    private func admit(_ request: HTTPRequest) throws(Failure) -> UUID {
        guard request.headers["origin"] == nil, request.headers["sec-fetch-site"] != "cross-site" else { throw .origin }
        guard let header = request.headers["authorization"], header.hasPrefix("Bearer ") else { throw .pass }
        let presented = Pass.fingerprint(header.dropFirst("Bearer ".count))
        var found: Int?
        for (index, app) in apps.enumerated() where Pass.same(app.fingerprint, presented) {
            found = index
        }
        guard let found, case .read(let key?) = access else { throw .pass }
        var apps = self.apps
        apps[found].requests += 1
        apps[found].lastUsed = .now
        _ = keep(apps, key: key)
        return apps[found].id
    }

    private func route(_ request: HTTPRequest, body: [UInt8], for app: UUID) async -> HTTPResponse {
        do throws(Failure) {
            switch (request.method, request.target) {
            case ("GET", "/v1/models"):
                let list = try await models()
                guard (try? GoJSON.read([UInt8](list)))?.members != nil else { throw Self.unreadable }
                return HTTPResponse(status: 200, body: list)
            case ("POST", "/v1/chat/completions"):
                return try await complete(request, body: body, for: app)
            case (_, "/v1/models"), (_, "/v1/chat/completions"):
                throw Failure(405, "method_not_allowed", "Method not allowed.")
            default:
                throw Failure(404, "not_found", "Cloak answers /v1/chat/completions and /v1/models only.")
            }
        } catch {
            return error.response
        }
    }

    private static let unreadable = Failure(502, "invalid_upstream_response", "The provider's answer did not read.")

    /// The provider's list of models, as it gives it.
    private func models() async throws(Failure) -> Data {
        do {
            return try await Remote.models(exchange: parts.exchange)
        } catch {
            throw Failure(error)
        }
    }

    /// Checks the request, then the model against the provider's list, then
    /// rewords each user message on this Mac, then sends it from the wallet.
    /// Nothing leaves this Mac before every user message is reworded.
    private func complete(_ request: HTTPRequest, body: [UInt8], for app: UUID) async throws(Failure) -> HTTPResponse {
        try Asked.check(type: request.headers["content-type"])
        let asked = try await Asked.read(body)
        guard let ids = Self.ids(try await models()) else { throw Self.unreadable }
        guard ids.contains(asked.model) else {
            throw Failure(404, "model_not_found", "The provider has no model \(asked.model). /v1/models lists those it has.")
        }
        var memory = memories[app] ?? Memory()
        let identity = memory.identity(for: asked.messages)
        memories[app] = memory
        let (messages, transcript) = try await memory.rewrite(asked, reword: parts.reword)
        memories[app]?.transcript = transcript
        guard case .read(let key?) = access else { throw .stopped }
        do {
            guard try await parts.wallet() != nil else {
                throw Failure(402, "no_wallet", "Cloak has no wallet yet. Create one in Chat, under Wallet.")
            }
        } catch let failure as Failure {
            throw failure
        } catch {
            logger.error("cannot read the wallet: \(String(describing: error), privacy: .public)")
            throw Failure(502, "failed", "Cloak couldn't read the wallet.")
        }
        guard !Task.isCancelled else { throw .stopped }
        let completion: Data
        do {
            completion = try await Remote.complete(
                asked.body(messages), identity: identity, key: parts.key, deposits: DepositStore(folder: walletFolder, key: key),
                exchange: parts.exchange)
        } catch {
            logger.error("door send stopped: \(error.code.rawValue, privacy: .public) \(error.detail, privacy: .public)")
            throw Failure(error)
        }
        return try Asked.answer(completion, streaming: asked.streaming)
    }

    /// The model names in the provider's list (`data[].id`).
    private static func ids(_ list: Data) -> Set<String>? {
        let bytes = [UInt8](list)
        guard let data = try? GoJSON.read(bytes).members?["data"], case .array(let models) = data.value else { return nil }
        return Set(models.compactMap { model in
            guard case .string(let id)? = model.members?["id"]?.value else { return nil }
            return id
        })
    }
}
