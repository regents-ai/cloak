import Foundation
import Synchronization

/// The host end of the guest's runner (guest/runner), which runs the owner's
/// agent tasks: Pi in the reference sandbox, its model requests going to the
/// door port. One task per connection, in the frames guest/runner/main.go
/// describes. Ending a task's events closes its connection, which ends the
/// task and every process it started.
public enum Runner {
    /// The guest's port the runner listens on; the host connects to it.
    public static let port: UInt32 = 8030
    /// The largest frame taken: a line of Pi's longer than this ends its task.
    static let maxFrame = 16 << 20

    static let task = UInt8(ascii: "T")
    static let output = UInt8(ascii: "O")
    static let error = UInt8(ascii: "E")
    static let exit = UInt8(ascii: "X")
    static let refused = UInt8(ascii: "N")

    /// One task. The runner refuses it (`Stop.invalid`) unless the session
    /// is one Pi takes (letters, digits, ".", "_" and "-", beginning and
    /// ending with a letter or digit, at most 128), the model's name is at
    /// most 256 bytes with no control characters, the pass is a box pass and
    /// the task is not blank.
    public struct Request: Sendable, Codable {
        /// What the owner asked; Pi reads it on its standard input.
        public let task: String
        /// The conversation: the first task in it starts Pi's session, and
        /// each later one continues it.
        public let session: String
        /// The model, as the door's /v1/models names it.
        public let model: String
        /// The conversation's box pass, from the door.
        public let pass: String

        public init(task: String, session: String, model: String, pass: String) {
            self.task = task
            self.session = session
            self.model = model
            self.pass = pass
        }
    }

    public enum Event: Sendable, Equatable {
        /// One line Pi wrote on its standard output, without its line end,
        /// as written: in Pi's JSON mode, one event.
        case output(Data)
        /// One line written on standard error in the sandbox, without its
        /// line end, as written.
        case error(Data)
        /// How the task ended: the last event.
        case exited(Termination)
    }

    /// Why a task's events ended without its exit.
    public enum Stop: Error, Sendable, Equatable {
        /// No guest was serving to run it.
        case notRunning
        /// Cloak paused, stopped or quit with the task under way.
        case stopped
        /// A task in the same conversation was under way; nothing ran.
        case busy
        /// The runner refused the request (see `Request`); nothing ran.
        case invalid
        /// The connection ended, or carried what does not read, before the
        /// task's exit: the guest went away, or the runner could not run it.
        case ended
    }

    private struct Exit: Decodable {
        let status: Int32
        let signalled: Bool
    }

    /// Runs `request` on `socket`, which it takes and closes: its events in
    /// order, ending with `exited`, or failing with a `Stop`. Ending the
    /// stream first shuts the socket, which the runner takes as the end of
    /// the task. The frames are read on a thread of the task's own, as a
    /// task may run for hours.
    public static func run(_ socket: Int32, _ request: Request) -> AsyncThrowingStream<Event, any Error> {
        let (events, continuation) = AsyncThrowingStream.makeStream(of: Event.self, throwing: (any Error).self)
        let connection = Connection(socket)
        continuation.onTermination = { _ in connection.shut() }
        Thread {
            defer { connection.close() }
            continuation.finish(throwing: serve(socket, request) { continuation.yield($0) })
        }.start()
        return events
    }

    /// Sends the request, then hands on each event until the exit, which is
    /// handed on and returns nil; returns the stop otherwise. A socket the
    /// runner has closed already takes no option, so a write to it would
    /// raise SIGPIPE: the task has ended.
    private static func serve(_ socket: Int32, _ request: Request, event: (Event) -> Void) -> Stop? {
        var on: Int32 = 1
        guard setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0,
            let payload = try? JSONEncoder().encode(request), Relay.write(socket, WorkerChannel.frame(task, payload))
        else {
            return .ended
        }
        while let (kind, payload) = frame(socket) {
            switch kind {
            case output:
                event(.output(payload))
            case error:
                event(.error(payload))
            case exit:
                guard let exit = try? JSONDecoder().decode(Exit.self, from: payload) else { return .ended }
                event(.exited(Termination(status: exit.status, signalled: exit.signalled)))
                return nil
            case refused:
                switch payload {
                case Data("busy".utf8): return .busy
                case Data("invalid".utf8): return .invalid
                default: return .ended
                }
            default:
                return .ended
            }
        }
        return .ended
    }

    private static func frame(_ socket: Int32) -> (UInt8, Data)? {
        guard let head = Relay.read(socket, 5) else { return nil }
        let length = head.dropFirst().reduce(0) { $0 << 8 | Int($1) }
        guard length <= maxFrame, let payload = length == 0 ? Data() : Relay.read(socket, length) else { return nil }
        return (head[head.startIndex], payload)
    }
}

/// A guest connection's socket, the runner's, the payer's or a Venice
/// stream's: shut only while
/// it is open, and closed once, under one lock, so that a shut never reaches
/// a socket number reused since.
final class Connection: Sendable {
    private let socket: Int32
    private let open = Mutex(true)

    init(_ socket: Int32) {
        self.socket = socket
    }

    func shut() {
        open.withLock { if $0 { shutdown(socket, SHUT_RDWR) } }
    }

    func close() {
        open.withLock {
            $0 = false
            Darwin.close(socket)
        }
    }
}
