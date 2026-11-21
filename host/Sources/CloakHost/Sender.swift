import Foundation

/// The host end of the guest's sender (guest/sender), Token Inference's one
/// way to a remote model: one request per connection, in the frames
/// guest/sender/src/lib.rs describes. The sender serves one connection at a
/// time and gives each its turn, and only then is the request built, from
/// what the host has kept by that time. Each change to the deposit the
/// sender reports is kept (`keep`) before the sender is told to go on. A
/// Venice request's answer streams (`stream`).
public enum Sender {
    /// The guest's port the sender listens on; the host connects to it.
    public static let port: UInt32 = 8020
    /// The largest frame taken, as the sender's own limit.
    static let maxFrame = 16 << 20

    static let turn = UInt8(ascii: "Y")
    static let request = UInt8(ascii: "R")
    static let keep = UInt8(ascii: "S")
    static let kept = UInt8(ascii: "K")
    static let answer = UInt8(ascii: "A")
    static let head = UInt8(ascii: "L")
    static let piece = UInt8(ascii: "P")

    public struct Failure: Error, CustomStringConvertible {
        public let description: String

        public init(description: String) {
            self.description = description
        }
    }

    /// One exchange on `socket`, which it takes and closes: waits for the
    /// turn, sends `request()`, keeps each deposit change, and returns the
    /// sender's answer. Runs on a thread of its own, as the sender may take
    /// minutes.
    public static func exchange(
        _ socket: Int32, request: @escaping @Sendable () throws -> Data, keep: @escaping @Sendable (Data) throws -> Void
    ) async throws -> Data {
        try await onThread {
            defer { close(socket) }
            var on: Int32 = 1
            // A sender that has hung up already refuses the setting, and a
            // write to it would then end the app with a signal.
            guard setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                throw Failure(description: "the sender closed before its turn")
            }
            guard let (kind, _) = frame(socket), kind == turn else { throw Failure(description: "the sender gave no turn") }
            guard Relay.write(socket, WorkerChannel.frame(Self.request, try request())) else {
                throw Failure(description: "the sender closed before the request")
            }
            while let (kind, payload) = frame(socket) {
                switch kind {
                case Self.keep:
                    try keep(payload)
                    guard Relay.write(socket, WorkerChannel.frame(kept, Data())) else {
                        throw Failure(description: "the sender closed after a deposit change")
                    }
                case answer:
                    return payload
                default:
                    throw Failure(description: "the sender sent an unknown frame")
                }
            }
            throw Failure(description: "the sender closed before answering")
        }
    }

    /// One part of a Venice answer, in the order the sender hands them on.
    public enum Piece: Sendable, Equatable {
        /// Venice's status and headers, names in lower case: first, once.
        case head(status: Int, headers: [String: String])
        /// The body's bytes as they arrived; zero or more.
        case body(Data)
        /// The sender's answer, `{"ok":{}}` or `{"stop":...}`: last. A stop
        /// before the head means Venice's answer never came.
        case end(Data)
    }

    /// One `venice` request on `socket`, which it takes and closes: waits for
    /// the turn, sends `request`, then hands on each piece of the answer as
    /// it comes. Ending the stream first, as a consumer that stops does,
    /// shuts the socket; the sender takes that as the end of the request and
    /// drops Venice's answer, which closes its Tor stream. The frames are
    /// read on a thread of the request's own.
    public static func stream(_ socket: Int32, request: Data) -> AsyncThrowingStream<Piece, any Error> {
        let (pieces, continuation) = AsyncThrowingStream.makeStream(of: Piece.self, throwing: (any Error).self)
        let connection = Connection(socket)
        continuation.onTermination = { _ in connection.shut() }
        Thread {
            defer { connection.close() }
            do {
                try serve(socket, request) { continuation.yield($0) }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }.start()
        return pieces
    }

    private struct Head: Decodable {
        let status: Int
        let headers: [String: String]
    }

    private static func serve(_ socket: Int32, _ request: Data, piece: (Piece) -> Void) throws(Failure) {
        var on: Int32 = 1
        guard setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw Failure(description: "the sender closed before its turn")
        }
        guard let (kind, _) = frame(socket), kind == turn else { throw Failure(description: "the sender gave no turn") }
        guard Relay.write(socket, WorkerChannel.frame(Self.request, request)) else {
            throw Failure(description: "the sender closed before the request")
        }
        var headed = false
        while let (kind, payload) = frame(socket) {
            switch kind {
            case head where !headed:
                guard let head = try? JSONDecoder().decode(Head.self, from: payload) else {
                    throw Failure(description: "the sender's head did not read")
                }
                headed = true
                piece(.head(status: head.status, headers: head.headers))
            case Self.piece where headed:
                piece(.body(payload))
            case answer:
                piece(.end(payload))
                return
            default:
                throw Failure(description: "the sender sent an unknown frame")
            }
        }
        throw Failure(description: "the sender closed before answering")
    }

    private static func frame(_ socket: Int32) -> (UInt8, Data)? {
        guard let head = Relay.read(socket, 5) else { return nil }
        let length = head.dropFirst().reduce(0) { $0 << 8 | Int($1) }
        guard length <= maxFrame, let payload = length == 0 ? Data() : Relay.read(socket, length) else { return nil }
        return (head[head.startIndex], payload)
    }
}
