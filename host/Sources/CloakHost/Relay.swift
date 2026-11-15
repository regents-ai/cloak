import Foundation
import Synchronization

/// The host end of the guest channel (spec section 7). Each guest connection
/// carries one request: the 32-byte channel token, then an `R` frame. The
/// answer goes back as an `A` frame and the connection closes. Connections,
/// and the app's own requests (`answer(to:)`), are served one at a time, in
/// order. A guest that closes its end once it has sent its request cancels the
/// rewrite, including while the request is still being handed to the worker.
/// An app's request may give way (decision 13 in docs/plan.md): the next
/// request to arrive, the app's or a connection's, cancels it as its task's
/// cancel would, so it holds that one up no longer than the worker takes to
/// stop.
///
/// A lost worker fails the request it had, or the one that found it gone:
/// that connection closes without an answer, and its request is never sent
/// again. Nothing more is served until the lost worker has exited (killed if
/// it has not within `Child.exitLimit`) and `afterLoss` has decided what
/// follows it: the worker it returns serves the next connection; with none,
/// every later request fails. Two workers never hold the model at once.
public final class Relay: Sendable {
    /// What follows a lost worker, once it has exited: a new worker, or none.
    public typealias AfterLoss = @Sendable () async -> WorkerChannel?

    static let port: UInt32 = 8012
    static let maxRequest = 1 << 20
    /// How long a connection may take to deliver its request.
    static let requestTimeout = timeval(tv_sec: 10, tv_usec: 0)

    /// The worker requests go to:
    ///
    ///     serving --loss--> replacing --afterLoss--> serving, or none
    ///     any but replacing --finish--> finished
    ///
    /// `finish` waits out a replacement first, so it ends the worker that
    /// replacement started.
    private enum Slot {
        case serving(WorkerChannel)
        case replacing(Task<Void, Never>)
        case none
        case finished
    }

    /// The per-boot channel token the guest must present.
    let token = randomBytes(32)
    private let afterLoss: AfterLoss
    private let slot: Mutex<Slot>
    /// The last request that gives way, until a later request cancels it.
    private let yielding = Mutex<Call?>(nil)
    private let queue = DispatchQueue(label: "sh.regents.cloak.relay")
    private let watch = DispatchQueue(label: "sh.regents.cloak.relay.watch")

    public init(worker: WorkerChannel, afterLoss: @escaping AfterLoss) {
        self.slot = Mutex(.serving(worker))
        self.afterLoss = afterLoss
    }

    /// Takes ownership of the socket.
    func accept(_ socket: Int32) {
        giveWay(to: nil)
        queue.async { [self] in
            let lost = serve(socket)
            close(socket)
            if let lost { replaceAfter(lost) }
        }
    }

    /// Answers one request from the app itself, in turn with the guest's
    /// connections, so it never overlaps one. Nil when there is no worker or
    /// it was lost on this request, as for a guest connection. Cancelling the
    /// task cancels the request: before its turn it never reaches the worker;
    /// at the worker, the worker is told to stop it, and the answer it then
    /// gives is returned. A request before it that gives way is cancelled the
    /// same way; with `yielding`, this one gives way to the next.
    public func answer(to request: Data, yielding: Bool = false) async -> Data? {
        let call = Call()
        giveWay(to: yielding ? call : nil)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async { [self] in
                    let (answer, lost) = serve(request, call)
                    continuation.resume(returning: answer)
                    if let lost { replaceAfter(lost) }
                }
            }
        } onCancel: {
            call.cancel()
        }
    }

    /// One request from the app, as its task's cancel sees it:
    ///
    ///     waiting --its turn--> atWorker --answer--> finished
    ///     waiting or atWorker --cancel--> cancelled
    ///
    /// A cancel at the worker reaches it under the lock, so never after the
    /// answer has let the next request in.
    private final class Call: Sendable {
        private enum State {
            case waiting
            case atWorker(WorkerChannel)
            case cancelled
            case finished
        }

        private let state = Mutex(State.waiting)

        /// Hands the request to the worker: nil when it was cancelled first,
        /// false when the worker is lost.
        func send(_ request: Data, to worker: WorkerChannel) -> Bool? {
            state.withLock { state in
                guard case .waiting = state else { return nil }
                guard worker.send(request) else { return false }
                state = .atWorker(worker)
                return true
            }
        }

        func cancel() {
            state.withLock { state in
                switch state {
                case .waiting:
                    state = .cancelled
                case .atWorker(let worker):
                    worker.cancel()
                    state = .cancelled
                case .cancelled, .finished:
                    break
                }
            }
        }

        func finish() {
            state.withLock { $0 = .finished }
        }
    }

    /// A request has arrived: the one that gives way, if any, is cancelled,
    /// and `next` gives way from now on when it does.
    private func giveWay(to next: Call?) {
        yielding.withLock { yielding in
            yielding?.cancel()
            yielding = next
        }
    }

    /// Nothing more is served until the replacement has settled. The task is
    /// made under the lock, so its own use of the slot comes after this one.
    /// Runs on the queue.
    private func replaceAfter(_ lost: WorkerChannel) {
        queue.suspend()
        slot.withLock { $0 = .replacing(Task { await replace(lost) }) }
    }

    /// Ends the worker, after any replacement in progress has settled.
    public func finish() async {
        while true {
            let next: Slot = slot.withLock { slot in
                let current = slot
                if case .replacing = current { return current }
                slot = .finished
                return current
            }
            switch next {
            case .replacing(let replacement):
                await replacement.value
            case .serving(let worker):
                await worker.finish()
                return
            case .none, .finished:
                return
            }
        }
    }

    /// Serves one connection. The worker, when it was lost during it.
    private func serve(_ socket: Int32) -> WorkerChannel? {
        var timeout = Self.requestTimeout
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        guard let presented = Self.read(socket, 32), Self.same(presented, token) else {
            log("refused a connection without the channel token")
            return nil
        }
        guard let header = Self.read(socket, 5), header[0] == 0x52 else { return nil }
        let length = header.dropFirst().reduce(0) { $0 << 8 | Int($1) }
        guard length <= Self.maxRequest, let request = Self.read(socket, length) else { return nil }
        guard case .serving(let worker) = slot.withLock({ $0 }) else {
            log("no worker; closing the guest connection without an answer")
            return nil
        }
        guard worker.send(request), let answer = cancellingOnClose(socket, worker) else {
            log("worker lost; closing the guest connection without an answer")
            return worker
        }
        Self.write(socket, WorkerChannel.frame(0x41, answer))
        return nil
    }

    /// Serves one request from the app: its answer, and the worker when it
    /// was lost on it.
    private func serve(_ request: Data, _ call: Call) -> (Data?, WorkerChannel?) {
        defer { call.finish() }
        guard case .serving(let worker) = slot.withLock({ $0 }) else {
            log("no worker; the app's request has no answer")
            return (nil, nil)
        }
        guard let sent = call.send(request, to: worker) else { return (nil, nil) }
        guard sent, let answer = worker.answer() else {
            log("worker lost; the app's request has no answer")
            return (nil, worker)
        }
        return (answer, nil)
    }

    /// Waits for the lost worker to exit, puts what `afterLoss` decides in its
    /// place, and serves again.
    private func replace(_ lost: WorkerChannel) async {
        await lost.end()
        let next = await afterLoss()
        slot.withLock { $0 = next.map(Slot.serving) ?? .none }
        queue.resume()
    }

    /// The worker's answer, while the guest closing its end cancels the
    /// worker's request. The watch starts once the worker has the request:
    /// nothing more is expected from the guest, so the socket turning readable
    /// means it closed its end (or broke the protocol), and a guest that
    /// closed earlier is seen at once. The socket stays open until the watch
    /// has let go of it.
    private func cancellingOnClose(_ socket: Int32, _ worker: WorkerChannel) -> Data? {
        let closed = DispatchSource.makeReadSource(fileDescriptor: socket, queue: watch)
        let released = DispatchSemaphore(value: 0)
        closed.setEventHandler { [unowned closed] in
            worker.cancel()
            closed.cancel()
        }
        closed.setCancelHandler { released.signal() }
        closed.resume()
        defer {
            closed.cancel()
            released.wait()
        }
        return worker.answer()
    }

    static func read(_ socket: Int32, _ count: Int) -> Data? {
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

    /// False when the socket failed before all of the data was written.
    @discardableResult
    static func write(_ socket: Int32, _ data: Data) -> Bool {
        var done = 0
        while done < data.count {
            let n = data.withUnsafeBytes { Darwin.write(socket, $0.baseAddress! + done, data.count - done) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { return false }
            done += n
        }
        return true
    }

    private static func same(_ a: Data, _ b: Data) -> Bool {
        a.count == b.count && zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// One line on standard error, as `cloak-host: <message>`.
public func log(_ message: String) {
    FileHandle.standardError.write(Data("cloak-host: \(message)\n".utf8))
}

func randomBytes(_ count: Int) -> Data {
    var generator = SystemRandomNumberGenerator()
    return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
}
