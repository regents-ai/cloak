import Foundation
import Synchronization

/// The native worker as a child process, spoken to in frames over its
/// standard input and output (see rewriter-kit/Sources/RewriterKit/Frames.swift).
/// One request at a time. The first fault marks the worker lost and stops it,
/// and every later request on this channel fails; the relay then waits for
/// the worker to exit (`end`), killing it if it has not within
/// `Child.exitLimit`, before anything takes its place.
public final class WorkerChannel: Sendable {
    /// The largest answer accepted. The worker's 16,384-token limit keeps real
    /// answers far below it; a larger one means the worker is broken. Answers
    /// over the daemon's own reply limit still pass, so the daemon refuses them.
    static let maxAnswer = 16 << 20

    /// The one request at a time:
    ///
    ///     idle --send--> running --cancel--> cancelling
    ///      ^                |                    |
    ///      +----answer------+--------------------+
    ///
    /// A fault in any state makes the worker lost, and lost never ends. A
    /// cancel in any state but running does nothing: in idle it is one that
    /// crossed the answer.
    private enum State {
        case idle
        /// The worker has the request and owes its answer.
        case running
        /// The worker was told to stop the request and still owes its answer.
        case cancelling
        /// The worker failed or exited.
        case lost
    }

    private let child: Child
    private let input: FileHandle
    private let output: FileHandle
    private let state = Mutex(State.idle)

    /// Starts the worker; `start` waits for it to signal ready.
    private init(executable: URL, arguments: [String]) throws {
        let toWorker = Pipe(), fromWorker = Pipe()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = toWorker
        process.standardOutput = fromWorker
        child = try Child(process) { _ in }
        input = toWorker.fileHandleForWriting
        output = fromWorker.fileHandleForReading
    }

    /// Starts the worker and returns once it has signalled ready, waiting on a
    /// thread of its own while the worker loads. A start that is cancelled
    /// stops the worker at once, which ends the wait. Throws, once the worker
    /// has exited, when it was cancelled, or when the worker ended or sent
    /// anything else first.
    public static func start(executable: URL, arguments: [String]) async throws -> WorkerChannel {
        let channel = try WorkerChannel(executable: executable, arguments: arguments)
        let ready = try await withTaskCancellationHandler {
            try await onThread { () -> Bool in
                guard let (kind, payload) = channel.readFrame() else { return false }
                return kind == 0x59 && payload.isEmpty
            }
        } onCancel: {
            channel.child.process.terminate()
        }
        guard ready, !Task.isCancelled else {
            channel.child.process.terminate()
            await channel.child.stopped("the worker")
            try Task.checkCancellation()
            throw ChannelError(description: "it did not become ready")
        }
        return channel
    }

    /// The worker's process.
    public var processIdentifier: Int32 { child.process.processIdentifier }

    /// How the worker ended, once it has, for whatever reason.
    public func exited() async -> Termination {
        await child.exited()
    }

    /// Hands a request to the idle worker. False when the worker is lost.
    /// The request is written whole before a cancel can follow it.
    func send(_ request: Data) -> Bool {
        state.withLock { state in
            switch state {
            case .lost:
                return false
            case .running, .cancelling:
                preconditionFailure("a request while the worker has one")
            case .idle:
                do {
                    try input.write(contentsOf: Self.frame(0x52, request))
                } catch {
                    lose(&state)
                    return false
                }
                state = .running
                return true
            }
        }
    }

    /// Asks the worker to stop the request it has, once.
    func cancel() {
        state.withLock { state in
            guard case .running = state else { return }
            state = .cancelling
            // A worker that is gone fails this write; reading its answer
            // finds the loss.
            try? input.write(contentsOf: Self.frame(0x43, Data()))
        }
    }

    /// The answer to the request sent (status and body), or nil when the
    /// worker is lost. The read waits outside the lock, so a cancel can reach
    /// the worker meanwhile.
    func answer() -> Data? {
        let frame = readFrame()
        return state.withLock { state in
            switch state {
            case .idle, .lost:
                preconditionFailure("an answer awaited with no request at the worker")
            case .running, .cancelling:
                guard let (kind, payload) = frame, kind == 0x41, payload.count >= 2 else {
                    lose(&state)
                    return nil
                }
                state = .idle
                return payload
            }
        }
    }

    /// Ends the worker by closing its input, and returns once it has exited.
    /// A busy worker first stops its rewrite, which fails. One that has not
    /// exited within `Child.exitLimit` is killed.
    public func finish() async {
        try? input.close()
        await child.stopped("the worker")
    }

    /// Stops a lost worker and returns once it has exited, so its memory is
    /// free before anything takes its place. One that has not exited within
    /// `Child.exitLimit` is killed.
    func end() async {
        child.process.terminate()
        await child.stopped("the lost worker")
    }

    /// Marks the worker lost and asks it to stop; `end` waits for it. A
    /// cancel from now on finds it lost.
    private func lose(_ state: inout State) {
        state = .lost
        child.process.terminate()
    }

    private func readFrame() -> (UInt8, Data)? {
        guard let header = readExactly(5) else { return nil }
        let length = header.dropFirst().reduce(0) { $0 << 8 | Int($1) }
        guard length <= Self.maxAnswer, let payload = readExactly(length) else { return nil }
        return (header[header.startIndex], payload)
    }

    private func readExactly(_ count: Int) -> Data? {
        var data = Data()
        while data.count < count {
            guard let block = try? output.read(upToCount: count - data.count), !block.isEmpty else { return nil }
            data += block
        }
        return data
    }

    static func frame(_ kind: UInt8, _ payload: Data) -> Data {
        let n = UInt32(payload.count)
        return Data([kind, UInt8(n >> 24), UInt8(n >> 16 & 0xff), UInt8(n >> 8 & 0xff), UInt8(n & 0xff)]) + payload
    }
}

struct ChannelError: Error, CustomStringConvertible {
    let description: String
}
