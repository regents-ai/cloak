import Foundation

/// The host end of the guest's sender (guest/sender), Development mode's one
/// way to a remote model: one request per connection, in the frames
/// guest/sender/src/lib.rs describes. The sender serves one connection at a
/// time and gives each its turn, and only then is the request built, from
/// what the host has kept by that time. Each change to the deposit the
/// sender reports is kept (`keep`) before the sender is told to go on.
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
            setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
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

    private static func frame(_ socket: Int32) -> (UInt8, Data)? {
        guard let head = Relay.read(socket, 5) else { return nil }
        let length = head.dropFirst().reduce(0) { $0 << 8 | Int($1) }
        guard length <= maxFrame, let payload = length == 0 ? Data() : Relay.read(socket, length) else { return nil }
        return (head[head.startIndex], payload)
    }
}
