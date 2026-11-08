import Foundation

/// The host end of the guest channel (spec section 7). Each guest connection
/// carries one request: the 32-byte channel token, then an `R` frame. The
/// answer goes back as an `A` frame and the connection closes. Connections are
/// served one at a time, in order. A guest that closes its end once it has
/// sent its request cancels the rewrite, including while the request is still
/// being handed to the worker.
final class Relay: Sendable {
    static let port: UInt32 = 8012
    static let maxRequest = 1 << 20
    /// How long a connection may take to deliver its request.
    static let requestTimeout = timeval(tv_sec: 10, tv_usec: 0)

    private let token: Data
    private let worker: WorkerChannel
    private let queue = DispatchQueue(label: "sh.regents.cloak.relay")
    private let watch = DispatchQueue(label: "sh.regents.cloak.relay.watch")

    init(token: Data, worker: WorkerChannel) {
        self.token = token
        self.worker = worker
    }

    /// Takes ownership of the socket.
    func accept(_ socket: Int32) {
        queue.async { [self] in
            serve(socket)
            close(socket)
        }
    }

    private func serve(_ socket: Int32) {
        var timeout = Self.requestTimeout
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        guard let presented = Self.read(socket, 32), Self.same(presented, token) else {
            log("refused a connection without the channel token")
            return
        }
        guard let header = Self.read(socket, 5), header[0] == 0x52 else { return }
        let length = header.dropFirst().reduce(0) { $0 << 8 | Int($1) }
        guard length <= Self.maxRequest, let request = Self.read(socket, length) else { return }
        guard worker.send(request), let answer = cancellingOnClose(socket, worker.answer) else {
            log("worker lost; closing the guest connection without an answer")
            return
        }
        Self.write(socket, WorkerChannel.frame(0x41, answer))
    }

    /// Runs `body` while the guest closing its end cancels the worker's
    /// request. It starts once the worker has the request: nothing more is
    /// expected from the guest, so the socket turning readable means it closed
    /// its end (or broke the protocol), and a guest that closed earlier is
    /// seen at once. The socket stays open until the watch has let go of it.
    private func cancellingOnClose<T>(_ socket: Int32, _ body: () -> T) -> T {
        let closed = DispatchSource.makeReadSource(fileDescriptor: socket, queue: watch)
        let released = DispatchSemaphore(value: 0)
        closed.setEventHandler { [worker, unowned closed] in
            worker.cancel()
            closed.cancel()
        }
        closed.setCancelHandler { released.signal() }
        closed.resume()
        defer {
            closed.cancel()
            released.wait()
        }
        return body()
    }

    private static func read(_ socket: Int32, _ count: Int) -> Data? {
        var data = Data(count: count)
        var done = 0
        while done < count {
            let n = data.withUnsafeMutableBytes { Darwin.read(socket, $0.baseAddress! + done, count - done) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { return nil }
            done += n
        }
        return data
    }

    private static func write(_ socket: Int32, _ data: Data) {
        var done = 0
        while done < data.count {
            let n = data.withUnsafeBytes { Darwin.write(socket, $0.baseAddress! + done, data.count - done) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { return }
            done += n
        }
    }

    private static func same(_ a: Data, _ b: Data) -> Bool {
        a.count == b.count && zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("cloak-host: \(message)\n".utf8))
}
