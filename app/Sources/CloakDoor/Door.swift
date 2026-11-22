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

        public init(
            reword: @escaping @Sendable ([String]) async throws(RewriteStop) -> [String], queue: PayQueue,
            exchange: @escaping Exchange, wallet: @escaping @Sendable () async throws -> String?, key: @escaping Remote.Key,
            sealing: @escaping @Sendable () async throws -> SymmetricKey?
        ) {
            self.reword = reword
            self.queue = queue
            self.exchange = exchange
            self.wallet = wallet
            self.key = key
            self.sealing = sealing
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
    /// The requests the Agents window lists, newest first, and the only
    /// ones that keep their messages' texts.
    public static let latest = 20
    /// The port taken at the last open, until the door closes.
    private var opened: UInt16?

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
    /// The one port, on 127.0.0.1 only, asked at each open: in the app, the
    /// Settings window's.
    @ObservationIgnored private let chosen: () -> UInt16
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var serving: [UUID: Task<Void, Never>] = [:]
    /// By app, and by the agent's conversation.
    @ObservationIgnored private var memories: [UUID: Memory] = [:]
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

    /// Listens on 127.0.0.1 and the one port, and nowhere else; refused
    /// (`Refusal`) when the port is taken or the apps can't be read.
    public func open() async {
        guard listener == nil else { return }
        await load()
        guard case .read = access else {
            state = .refused(.appsUnread)
            return
        }
        let port = chosen()
        opened = port
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        parameters.allowLocalEndpointReuse = false
        parameters.acceptLocalOnly = true
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            logger.error("door cannot listen: \(String(describing: error), privacy: .public)")
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
            state = .refused(error == .posix(.EADDRINUSE) ? .portTaken(port) : .address)
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
        for conversation in boxes.keys { memories[conversation] = nil }
        boxes = [:]
        let serving = Array(self.serving.values)
        for task in serving { task.cancel() }
        for task in serving { await task.value }
    }

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
        do {
            let (request, after) = try await HTTPRequest.head(connection)
            let (app, payment) = try admit(request, from: side)
            let body = try await request.body(after: after, from: connection)
            limit.cancel()
            await routing(request, body: body, for: app, paying: payment, from: side, on: connection, since: started)
        } catch let failure as Failure {
            limit.cancel()
            await answer(failure.response, on: connection, since: started)
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
    /// Sending it pays for it.
    private struct Ready: Sendable {
        /// How it is paid: through the payer, in its turn, or from the Tempo
        /// wallet, whose deposit is kept here.
        enum Way: Sendable {
            case payer
            case wallet(DepositStore)
        }

        let listed: AgentRequest.ID
        let body: Data
        let identity: String
        let streaming: Bool
        let way: Way
    }

    /// Routes one request read whole while watching its connection, and
    /// lists a chat request's end. An app that leaves before its request is
    /// sent ends it there: nothing more is reworded, sent or paid. One sent
    /// has been handed on to be paid for (`send`), and goes on to its
    /// answer, which an app that has left never reads.
    private func routing(
        _ request: HTTPRequest, body: [UInt8], for app: UUID, paying payment: Payment, from side: Side, on connection: some Link,
        since started: ContinuousClock.Instant
    ) async {
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
            group.addTask { await self.route(request, body: body, for: app, paying: payment, from: side) }
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
                    await finish(failure.response, at: &stage)
                case .ready(let ready):
                    guard stage == .preparing else {
                        note(ready.listed) { $0.end(.left(paid: false)) }
                        continue
                    }
                    stage = .sending
                    group.addTask { await self.send(ready) }
                case .sent(let listed, .success(let response)):
                    note(listed) { $0.end(stage == .unread ? .left(paid: true) : .answered) }
                    await finish(response, at: &stage)
                case .sent(let listed, .failure(let failure)):
                    note(listed) { $0.end(.stopped(failure.message)) }
                    await finish(failure.response, at: &stage)
                }
            }
        }
    }

    /// Refuses a request from a web page, then one without a pass of this
    /// side's, as the daemon does (`ServeHTTP`, internal/server/server.go:70-97):
    /// from the Mac, an app's pass, and the app's request is counted; from the
    /// guest, a box pass. Returns the app, or the agent's conversation, and
    /// how its requests are paid: an app's through zkAPI, a conversation's
    /// as its box says.
    private func admit(_ request: HTTPRequest, from side: Side) throws(Failure) -> (UUID, Payment) {
        guard request.headers["origin"] == nil, request.headers["sec-fetch-site"] != "cross-site" else { throw .origin }
        guard let header = request.headers["authorization"], header.hasPrefix("Bearer ") else { throw .pass }
        let presented = Pass.fingerprint(header.dropFirst("Bearer ".count))
        if case .guest = side {
            var found: (UUID, Payment)?
            for (conversation, box) in boxes where Pass.same(box.fingerprint, presented) {
                found = (conversation, box.payment)
            }
            guard let found else { throw .pass }
            return found
        }
        var found: Int?
        for (index, app) in apps.enumerated() where Pass.same(app.fingerprint, presented) {
            found = index
        }
        guard let found, case .read(let key?) = access else { throw .pass }
        var apps = self.apps
        apps[found].requests += 1
        apps[found].lastUsed = .now
        _ = keep(apps, key: key)
        return (apps[found].id, .zkapi)
    }

    /// Routes one request up to the point where sending it would pay for
    /// it. A chat request is listed in `requests` from here; `routing` lists
    /// its end.
    private func route(_ request: HTTPRequest, body: [UInt8], for app: UUID, paying payment: Payment, from side: Side) async -> Routed {
        do throws(Failure) {
            switch (request.method, request.target) {
            case ("GET", "/v1/models"):
                let list = try await models(paying: payment)
                guard (try? GoJSON.read([UInt8](list)))?.members != nil else { throw Self.unreadable }
                return .answer(HTTPResponse(status: 200, body: list))
            case ("POST", "/v1/chat/completions"):
                let listed = AgentRequest(sender: side == .mac ? .app(app) : .agent)
                requests.insert(listed, at: 0)
                if requests.count > 200 { requests.removeLast() }
                // The one this pushed out of the newest drops its texts.
                if requests.count > Self.latest { requests[Self.latest].messages = [] }
                do throws(Failure) {
                    return .ready(try await prepare(request, body: body, for: app, paying: payment, listed: listed.id))
                } catch {
                    return .stopped(listed.id, error)
                }
            case (_, "/v1/models"), (_, "/v1/chat/completions"):
                throw Failure(405, "method_not_allowed", "Method not allowed.")
            default:
                throw Failure(404, "not_found", "Cloak answers /v1/chat/completions and /v1/models only.")
            }
        } catch {
            return .answer(error.response)
        }
    }

    private static let unreadable = Failure(502, "invalid_upstream_response", "The provider's answer did not read.")

    /// The provider's list of models, as it gives it: the zkAPI service's
    /// through the payer, or the Tempo wallet's provider's through the
    /// sender.
    private func models(paying payment: Payment) async throws(Failure) -> Data {
        switch payment {
        case .zkapi:
            do {
                return try await parts.queue.call("GET", "/v1/models")
            } catch {
                throw Failure(error)
            }
        case .tempo:
            do {
                return try await Remote.models(exchange: parts.exchange)
            } catch {
                throw Failure(error)
            }
        }
    }

    /// Checks the request, then the model against the provider's list, then
    /// rewords each user message on this Mac, then, for the Tempo wallet,
    /// checks there is one; returns the request ready to send (`send`).
    /// Nothing leaves this Mac before every user message is reworded, and
    /// nothing here pays.
    private func prepare(
        _ request: HTTPRequest, body: [UInt8], for app: UUID, paying payment: Payment, listed: AgentRequest.ID
    ) async throws(Failure) -> Ready {
        try Asked.check(type: request.headers["content-type"])
        let asked = try await Asked.read(body)
        note(listed) { $0.model = asked.model }
        guard let ids = Self.ids(try await models(paying: payment)) else { throw Self.unreadable }
        guard ids.contains(asked.model) else {
            throw Failure(404, "model_not_found", "The provider has no model \(asked.model).")
        }
        var memory = memories[app] ?? Memory()
        let identity = memory.identity(for: asked.messages)
        memories[app] = memory
        let (messages, transcript) = try await memory.rewrite(asked, reword: parts.reword)
        memories[app]?.transcript = transcript
        note(listed) { entry in
            entry.reworded = asked.messages.count { $0.draft != nil }
            entry.stage = .sending
        }
        let pairs = await Self.pairs(asked, sent: messages)
        if let index = requests.firstIndex(where: { $0.id == listed }), index < Self.latest {
            requests[index].messages = pairs
        }
        let way: Ready.Way
        switch payment {
        case .zkapi:
            way = .payer
        case .tempo:
            let key = try await sealing()
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
            way = .wallet(DepositStore(folder: walletFolder, key: key))
        }
        guard !Task.isCancelled else { throw .stopped }
        return Ready(listed: listed, body: asked.body(messages), identity: identity, streaming: asked.streaming, way: way)
    }

    /// Sends a ready request, which pays for it: through the payer, in its
    /// turn, or from the Tempo wallet. Once handed on it is not cut short
    /// for an app that leaves (`routing`): the payer gives no sign of when
    /// it asks for the request's key, and one cut after that may be charged;
    /// the Tempo wallet's exchange, once begun, runs to its end.
    private func send(_ ready: Ready) async -> Routed {
        do throws(Failure) {
            guard !Task.isCancelled else { throw .stopped }
            let completion: Data
            switch ready.way {
            case .payer:
                do {
                    completion = try await parts.queue.complete(ready.body, identity: ready.identity, rank: .door)
                } catch {
                    logger.error("door payment stopped: \(error.code.rawValue, privacy: .public) \(error.detail, privacy: .private)")
                    throw Failure(error)
                }
            case .wallet(let deposits):
                do {
                    completion = try await Remote.complete(
                        ready.body, identity: ready.identity, key: parts.key, deposits: deposits, exchange: parts.exchange)
                } catch {
                    logger.error("door send stopped: \(error.code.rawValue, privacy: .public) \(error.detail, privacy: .private)")
                    throw Failure(error)
                }
            }
            return .sent(ready.listed, .success(try Asked.answer(completion, streaming: ready.streaming)))
        } catch {
            return .sent(ready.listed, .failure(error))
        }
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
        case .unread, .failed:
            throw .stopped
        }
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
