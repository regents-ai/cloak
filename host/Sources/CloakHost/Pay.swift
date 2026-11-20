import Foundation

/// The host end of the guest's payer, cloak-pay (guest/pay), which the guest
/// runs only with its payment disk: one exchange per connection, in frames
/// of a kind byte, a four-byte big-endian length and the payload, the same
/// frames as the sender's. The host sends one frame: a chat request (`R`),
/// which waits for its turn in the payer, or a call to one of the payer's
/// money routes (`C`) or a read of the deposit (`V`), which do not. The
/// payer may answer a chat request with `H` frames first, and every
/// exchange ends with one `A`. docs/zkapi-mac-side.md, section 1, writes
/// down each payload; this end carries them as they are. Ending the events
/// first shuts the connection, which the payer takes as the request's
/// cancel: nothing is sent or spent for it unless its key was asked for.
public enum Pay {
    /// The guest's port the payer listens on; the host connects to it.
    public static let port: UInt32 = 8021
    /// The largest frame taken, as the payer's own limit.
    static let maxFrame = 16 << 20

    /// The one frame the host sends.
    public enum Ask: UInt8, Sendable {
        /// "R": a chat request, `{"identity", "body"}`; it takes a turn.
        case request = 0x52
        /// "C": a call to a money route, `{"method", "path", "body"}`.
        case call = 0x43
        /// "V": a read of the deposit, `{"chain"}`.
        case view = 0x56
    }

    static let held = UInt8(ascii: "H")
    static let answer = UInt8(ascii: "A")

    public enum Event: Sendable, Equatable {
        /// An `H` frame's payload, as sent: a chat request's hold began or
        /// ended.
        case held(Data)
        /// The `A` frame's payload, as sent: the last event.
        case answer(Data)
    }

    public struct Failure: Error, CustomStringConvertible {
        public let description: String

        public init(description: String) {
            self.description = description
        }
    }

    /// Sends `payload` as `ask` on `socket`, which it takes and closes, and
    /// gives the payer's frames in order, the answer last. The frames are
    /// read on a thread of the exchange's own, as a request may be held for
    /// minutes and answered minutes later.
    public static func exchange(_ socket: Int32, _ ask: Ask, _ payload: Data) -> AsyncThrowingStream<Event, any Error> {
        let (events, continuation) = AsyncThrowingStream.makeStream(of: Event.self, throwing: (any Error).self)
        let connection = Connection(socket)
        continuation.onTermination = { _ in connection.shut() }
        Thread {
            defer { connection.close() }
            continuation.finish(throwing: serve(socket, ask, payload) { continuation.yield($0) })
        }.start()
        return events
    }

    /// Sends the frame, then hands on each frame until the answer, which is
    /// handed on and returns nil; returns the failure otherwise. A socket the
    /// payer has closed already takes no option, so a write to it would
    /// raise SIGPIPE.
    private static func serve(_ socket: Int32, _ ask: Ask, _ payload: Data, event: (Event) -> Void) -> Failure? {
        var on: Int32 = 1
        guard setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            return Failure(description: "the payer closed before the request")
        }
        guard payload.count <= maxFrame else { return Failure(description: "the request is larger than a frame") }
        guard Relay.write(socket, WorkerChannel.frame(ask.rawValue, payload)) else {
            return Failure(description: "the payer closed before the request")
        }
        while let (kind, payload) = frame(socket) {
            switch kind {
            case held where ask == .request:
                event(.held(payload))
            case answer:
                event(.answer(payload))
                return nil
            default:
                return Failure(description: "the payer sent an unknown frame")
            }
        }
        return Failure(description: "the payer closed before answering")
    }

    private static func frame(_ socket: Int32) -> (UInt8, Data)? {
        guard let head = Relay.read(socket, 5) else { return nil }
        let length = head.dropFirst().reduce(0) { $0 << 8 | Int($1) }
        guard length <= maxFrame, let payload = length == 0 ? Data() : Relay.read(socket, length) else { return nil }
        return (head[head.startIndex], payload)
    }
}
