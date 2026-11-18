@testable import CloakSupervisor
import CryptoKit
import Foundation
import Network
import Synchronization
import Testing

/// The model's download against a small HTTP server on 127.0.0.1 that the
/// test starts, into a temporary folder: never the real host, never a large
/// file. The network's state and the free space are the test's.
@MainActor
struct ModelDownloadTests {
    @Test func aCleanDownloadPutsEveryFileInPlaceAndLeavesNoPartial() async throws {
        let stand = try await ModelStand()
        defer { stand.remove() }
        let download = stand.download()
        #expect(download.state == .stopped(nil))
        #expect(download.done == 0 && download.total == stand.model.count + stand.config.count)
        #expect(download.hosts == ["127.0.0.1"])

        download.start()
        try await eventually { download.state == .installed }
        #expect(try Data(contentsOf: stand.folder.appending(path: "model.gguf")) == stand.model)
        #expect(try Data(contentsOf: stand.folder.appending(path: "config.json")) == stand.config)
        #expect(stand.partials.isEmpty)
        #expect(Checks.modelCheck(stand.manifest.model, in: stand.folder).1 == nil)
        #expect(stand.host.requests == [.init(path: "/config.json", range: nil), .init(path: "/model.gguf", range: nil)])
        #expect(download.done == download.total)
        // A launch with every file in place finds it installed.
        #expect(stand.download().state == .installed)
    }

    @Test func aFileThatDoesNotMatchItsPinIsDeletedAndNeverTriedAgain() async throws {
        let stand = try await ModelStand()
        defer { stand.remove() }
        var other = stand.model
        other[other.count / 2] ^= 0xff
        stand.serveModel { [other] request, _ in .whole(other, for: request) }
        let download = stand.download()
        download.start()
        try await eventually { download.state == .stopped(.mismatch("model.gguf")) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(download.state == .stopped(.mismatch("model.gguf")))
        #expect(stand.host.requests.filter { $0.path == "/model.gguf" }.count == 1)
        #expect(!FileManager.default.fileExists(atPath: stand.folder.appending(path: "model.gguf").path))
        #expect(stand.partials.isEmpty)
        #expect(Checks.modelCheck(stand.manifest.model, in: stand.folder).1?.reason == .modelMissing)
    }

    @Test func aPartialContinuesWithARangeRequestFromWhereItEnds() async throws {
        let stand = try await ModelStand()
        defer { stand.remove() }
        let kept = 1 << 20
        try stand.leavePartial(stand.model.prefix(kept))
        let download = stand.download()
        #expect(download.done == kept && download.hasPartials)
        download.start()
        try await eventually { download.state == .installed }
        #expect(try Data(contentsOf: stand.folder.appending(path: "model.gguf")) == stand.model)
        #expect(stand.host.requests.last == .init(path: "/model.gguf", range: "bytes=\(kept)-"))
        #expect(stand.partials.isEmpty)
    }

    @Test func aPartialWithOtherBytesIsHashedAgainAndRefused() async throws {
        let stand = try await ModelStand()
        defer { stand.remove() }
        try stand.leavePartial(Data(repeating: 7, count: 1 << 20))
        let download = stand.download()
        download.start()
        try await eventually { download.state == .stopped(.mismatch("model.gguf")) }
        #expect(stand.host.requests.last?.range == "bytes=\(1 << 20)-")
        #expect(stand.partials.isEmpty)
    }

    @Test func aServerThatWillNotResumeSendsTheWholeFileAndItStartsOver() async throws {
        let stand = try await ModelStand()
        defer { stand.remove() }
        stand.serveModel { request, model in .whole(model, for: request, ranges: false) }
        try stand.leavePartial(Data(repeating: 7, count: 1 << 20))
        let download = stand.download()
        download.start()
        try await eventually { download.state == .installed }
        #expect(stand.host.requests.last == .init(path: "/model.gguf", range: "bytes=\(1 << 20)-"))
        #expect(try Data(contentsOf: stand.folder.appending(path: "model.gguf")) == stand.model)
        #expect(stand.partials.isEmpty)
    }

    @Test func cancelStopsTheDownloadAndRemovesItsPartials() async throws {
        let stand = try await ModelStand()
        defer { stand.remove() }
        stand.serveModel { request, model in .whole(model, for: request).stalling(after: 64 << 10) }
        let download = stand.download()
        download.start()
        try await eventually { stand.partialSize >= 64 << 10 }
        #expect(download.state == .downloading)
        download.cancel()
        #expect(download.state == .stopped(nil))
        try await eventually { stand.partials.isEmpty && !download.hasPartials }
        #expect(!FileManager.default.fileExists(atPath: stand.folder.appending(path: "model.gguf").path))
        // A file already in place is not a partial, and stays.
        #expect(try Data(contentsOf: stand.folder.appending(path: "config.json")) == stand.config)
    }

    @Test func pauseKeepsThePartialAndContinueResumesIt() async throws {
        let stand = try await ModelStand()
        defer { stand.remove() }
        stand.serveModel { request, model in
            request.range == nil ? .whole(model, for: request).stalling(after: 64 << 10) : .whole(model, for: request)
        }
        let download = stand.download()
        download.start()
        try await eventually { stand.partialSize >= 64 << 10 }
        download.pause()
        #expect(download.state == .stopped(.paused))
        try await eventually { download.hasPartials && download.done >= stand.config.count + (64 << 10) }
        let kept = stand.partialSize
        download.start()
        try await eventually { download.state == .installed }
        #expect(stand.host.requests.last == .init(path: "/model.gguf", range: "bytes=\(kept)-"))
        #expect(try Data(contentsOf: stand.folder.appending(path: "model.gguf")) == stand.model)
    }

    @Test func aLostNetworkWaitsWithoutATryAndContinuesWhenItReturns() async throws {
        let stand = try await ModelStand()
        defer { stand.remove() }
        stand.serveModel { request, model in
            request.range == nil ? .whole(model, for: request).stalling(after: 64 << 10) : .whole(model, for: request)
        }
        let download = stand.download()
        download.start()
        try await eventually { stand.partialSize >= 64 << 10 }
        stand.network.set(false)
        try await eventually { download.state == .waitingForNetwork }
        try await Task.sleep(for: .milliseconds(300))
        #expect(download.state == .waitingForNetwork)
        #expect(stand.host.requests.count == 2)
        stand.network.set(true)
        try await eventually { download.state == .installed }
        #expect(stand.host.requests.count == 3)
        #expect(stand.host.requests.last?.range?.hasPrefix("bytes=") == true)
        #expect(try Data(contentsOf: stand.folder.appending(path: "model.gguf")) == stand.model)
    }

    @Test func aConnectionCutShortIsTriedAgainFromWhereItEnded() async throws {
        let stand = try await ModelStand()
        defer { stand.remove() }
        stand.serveModel { request, model in
            request.range == nil ? .whole(model, for: request).cut(after: 512 << 10) : .whole(model, for: request)
        }
        let download = stand.download()
        download.start()
        try await eventually { download.state == .installed }
        let tries = stand.host.requests.filter { $0.path == "/model.gguf" }
        #expect(tries.count == 2 && tries[0].range == nil && tries[1].range?.hasPrefix("bytes=") == true)
        #expect(try Data(contentsOf: stand.folder.appending(path: "model.gguf")) == stand.model)
    }

    @Test func failuresAreTriedAFewTimesThenStopUntilContinued() async throws {
        let stand = try await ModelStand()
        defer { stand.remove() }
        stand.serveModel { _, _ in .status(503) }
        let download = stand.download()
        download.start()
        try await eventually { download.state == .stopped(.failed(.status(503))) }
        #expect(stand.host.requests.filter { $0.path == "/model.gguf" }.count == 1 + ModelStand.waits.count)
        stand.serveModel { request, model in .whole(model, for: request) }
        download.start()
        try await eventually { download.state == .installed }
    }

    @Test(arguments: [false, true])
    func aDownloadCertainToFailIsBlockedAndNothingIsAsked(diskFull: Bool) async throws {
        let stand = try await ModelStand()
        defer { stand.remove() }
        let download = diskFull
            ? stand.download(free: 10)
            : stand.download(hardware: .init(appleSilicon: true, memory: 8 << 30, graphicsLimit: 5 << 30))
        let needed = stand.model.count + stand.config.count + ModelDownload.diskSpare
        #expect(download.blocked == (diskFull ? .disk(needed: needed, free: 10) : .mac))
        download.start()
        #expect(download.state == .stopped(nil))
        try await Task.sleep(for: .milliseconds(200))
        #expect(stand.host.requests.isEmpty)
    }
}

/// A model of two files, pinned in its own manifest, served by a local host,
/// into a temporary folder.
@MainActor
private struct ModelStand {
    static let waits: [Duration] = [.milliseconds(20), .milliseconds(40)]

    let root: URL
    let folder: URL
    let host: LocalHost
    let network = TestNetwork()
    let config = Data(#"{"name":"stand-in"}"#.utf8)
    /// 3 MiB, so it comes in many pieces.
    let model = Data((0..<(3 << 20)).map { UInt8(truncatingIfNeeded: ($0 &* 2_654_435_761) >> 13) })
    let manifest: Manifest

    init() async throws {
        root = URL(filePath: "/tmp").appending(path: "cloak-download-\(UUID().uuidString.prefix(8))")
        folder = root.appending(path: "models/stand-in")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let host = try LocalHost()
        try await host.start()
        self.host = host
        let config = config, model = model
        host.respond { request in .whole(request.path == "/model.gguf" ? model : config, for: request) }
        func file(_ path: String, _ data: Data) -> Manifest.Model.File {
            .init(path: path, size: data.count, sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                  url: URL(string: "http://127.0.0.1:\(host.port)/\(path)")!)
        }
        manifest = Manifest(
            release: "0.0.0-test", build: "test", modelMemory: 7 << 30, cloakMemory: 10 << 30,
            model: .init(name: "stand-in", label: "stand-in", files: [file("config.json", config), file("model.gguf", model)]),
            pins: [])
    }

    func download(
        hardware: Checks.Hardware = .init(appleSilicon: true, memory: 64 << 30, graphicsLimit: 48 << 30), free: Int = 1 << 40
    ) -> ModelDownload {
        ModelDownload(
            manifest: manifest, folder: folder, hardware: hardware, freeSpace: { _ in free },
            network: { [network] in network.paths() }, waits: Self.waits)
    }

    /// Answers each request for the model as `reply` says, given the
    /// model's bytes, and the others with their file.
    func serveModel(_ reply: @escaping @Sendable (LocalHost.Request, Data) -> LocalHost.Reply) {
        host.respond { [model, config] request in
            request.path == "/model.gguf" ? reply(request, model) : .whole(config, for: request)
        }
    }

    func leavePartial(_ bytes: Data) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try bytes.write(to: folder.appending(path: "model.gguf.part"))
    }

    var partials: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".part") }
    }

    var partialSize: Int {
        ModelDownload.size(of: folder.appending(path: "model.gguf.part"))
    }

    func remove() {
        host.stop()
        try? FileManager.default.removeItem(at: root)
    }
}

/// The network's state as the test sets it, to every download watching.
private final class TestNetwork: Sendable {
    private let state = Mutex((online: true, watching: [AsyncStream<Bool>.Continuation]()))

    func paths() -> AsyncStream<Bool> {
        let (stream, continuation) = AsyncStream.makeStream(of: Bool.self)
        let online = state.withLock {
            $0.watching.append(continuation)
            return $0.online
        }
        continuation.yield(online)
        return stream
    }

    func set(_ online: Bool) {
        let watching = state.withLock {
            $0.online = online
            return $0.watching
        }
        for continuation in watching { continuation.yield(online) }
    }
}

/// An HTTP server on 127.0.0.1, one request per connection, answering as
/// the test says and noting each request's path and Range.
private final class LocalHost: Sendable {
    struct Request: Equatable, Sendable {
        var path: String
        var range: String?

        var start: Int? {
            range.flatMap { Int($0.dropFirst("bytes=".count).prefix { $0 != "-" }) }
        }
    }

    struct Reply: Sendable {
        enum Ending: Sendable {
            case finish
            /// Sends this many bytes of the body, then holds the connection.
            case stall(Int)
            /// Sends this many bytes of the body, then closes the connection.
            case cut(Int)
        }

        var head: String
        var body: Data
        var ending = Ending.finish

        /// The file from where the request's Range starts, when `ranges`,
        /// else all of it.
        static func whole(_ data: Data, for request: Request, ranges: Bool = true) -> Reply {
            if ranges, let start = request.start {
                let rest = data.dropFirst(start)
                return Reply(
                    head: "206 Partial Content\r\nContent-Range: bytes \(start)-\(data.count - 1)/\(data.count)\r\nContent-Length: \(rest.count)",
                    body: Data(rest))
            }
            return Reply(head: "200 OK\r\nContent-Length: \(data.count)", body: data)
        }

        static func status(_ code: Int) -> Reply {
            Reply(head: "\(code) Error\r\nContent-Length: 4", body: Data("busy".utf8))
        }

        func stalling(after count: Int) -> Reply {
            var reply = self
            reply.ending = .stall(count)
            return reply
        }

        func cut(after count: Int) -> Reply {
            var reply = self
            reply.ending = .cut(count)
            return reply
        }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "cloak.test.host")
    private let state = Mutex((
        requests: [Request](), respond: { (_: Request) in Reply.status(500) } as @Sendable (Request) -> Reply,
        held: [NWConnection]()))

    var requests: [Request] { state.withLock { $0.requests } }
    /// The port it listens on, once `start` has returned.
    var port: UInt16 { listener.port!.rawValue }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
    }

    /// Listens, once the port is open.
    func start() async throws {
        let ready = AsyncStream<Bool>.makeStream()
        listener.stateUpdateHandler = { change in
            switch change {
            case .ready: ready.continuation.yield(true)
            case .failed, .cancelled: ready.continuation.yield(false)
            default: break
            }
        }
        listener.start(queue: queue)
        var iterator = ready.stream.makeAsyncIterator()
        guard await iterator.next() == true else { throw CancellationError() }
    }

    func respond(_ respond: @escaping @Sendable (Request) -> Reply) {
        state.withLock { $0.respond = respond }
    }

    func stop() {
        listener.cancel()
        for connection in state.withLock({ $0.held }) { connection.cancel() }
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, Data())
    }

    private func read(_ connection: NWConnection, _ buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            let buffer = buffer + (data ?? Data())
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                answer(connection, String(decoding: buffer[..<end.lowerBound], as: UTF8.self))
            } else if !done, error == nil {
                read(connection, buffer)
            } else {
                connection.cancel()
            }
        }
    }

    private func answer(_ connection: NWConnection, _ head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        let range = lines.dropFirst().first { $0.lowercased().hasPrefix("range:") }
            .map { $0.dropFirst("range:".count).trimmingCharacters(in: .whitespaces) }
        let request = Request(path: path, range: range)
        let respond = state.withLock {
            $0.requests.append(request)
            return $0.respond
        }
        let reply = respond(request)
        let sent: Data
        switch reply.ending {
        case .finish: sent = reply.body
        case .stall(let count), .cut(let count): sent = reply.body.prefix(count)
        }
        let bytes = Data("HTTP/1.1 \(reply.head)\r\nConnection: close\r\n\r\n".utf8) + sent
        connection.send(content: bytes, completion: .contentProcessed { [weak self] _ in
            switch reply.ending {
            case .finish:
                connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            case .stall:
                self?.state.withLock { $0.held.append(connection) }
            case .cut:
                connection.cancel()
            }
        })
    }
}
