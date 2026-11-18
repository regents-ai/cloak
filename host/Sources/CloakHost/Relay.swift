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
///
/// A relay given `Resting` (the app's; `cloak-host`'s never rests) lets its
/// worker rest: once no request has been at the worker or waiting for it for
/// the time `Resting.after` gives, counted from the last answer, the worker
/// is ended as `finish` ends it, and the model is out of memory. The next
/// request, in its turn, waits while a new worker, started as the first was,
/// loads once the one that rested has exited, and is then served. One that
/// cannot start fails that request and every later one, and is not tried
/// again. There a lost worker is followed by none, and the owner hears of
/// each rest and wake, and of every exit the relay did not cause (`Change`).
public final class Relay: Sendable {
    /// What follows a lost worker, once it has exited: a new worker, or none.
    public typealias AfterLoss = @Sendable () async -> WorkerChannel?

    /// How a relay's worker rests, and whom it tells.
    public struct Resting: Sendable {
        /// How long the worker may go with no request before it rests; nil,
        /// never. Asked each time the time starts again, so a change applies
        /// from then.
        let after: @Sendable () -> Duration?
        /// Starts a worker exactly as the first was started.
        let start: @Sendable () async throws -> WorkerChannel
        /// Hears each change, in order.
        let changed: @Sendable (Change) -> Void

        public init(
            after: @escaping @Sendable () -> Duration?, start: @escaping @Sendable () async throws -> WorkerChannel,
            changed: @escaping @Sendable (Change) -> Void
        ) {
            self.after = after
            self.start = start
            self.changed = changed
        }
    }

    /// What became of a resting relay's worker.
    public enum Change: Sendable {
        /// The worker rested and has exited: the model is out of memory until
        /// the next request.
        case rested
        /// A worker started for a request is ready, and serves from now on.
        case woke(WorkerChannel)
        /// A worker started for a request could not start, with what `start`
        /// threw; that request and every later one fail.
        case cannotWake(any Error)
        /// A worker the relay did not end has exited: it crashed, or was
        /// stopped once lost.
        case exited(Termination)
    }

    static let port: UInt32 = 8012
    static let maxRequest = 1 << 20
    /// How long a connection may take to deliver its request.
    static let requestTimeout = timeval(tv_sec: 10, tv_usec: 0)

    /// The worker requests go to:
    ///
    ///     serving --no request for the rest time--> resting --a request's turn--> waking
    ///     waking --ready--> serving, or --cannot start--> none
    ///     serving --loss--> replacing --afterLoss--> serving, or none
    ///     any but replacing or waking --finish--> finished
    ///
    /// Only a relay given `Resting` rests and wakes. The queue waits while a
    /// worker wakes, and its worker starts only once the one that rested has
    /// exited. `finish` waits out a replacement and stops a wake at once,
    /// then ends the worker either left.
    private enum Slot {
        case serving(WorkerChannel)
        /// The worker rested; the task ends once it has exited and the owner
        /// has been told.
        case resting(Task<Void, Never>)
        /// A worker is starting for the request whose turn it is.
        case waking(Task<Void, Never>)
        case replacing(Task<Void, Never>)
        case none
        case finished
    }

    /// The slot, and what resting keeps beside it.
    private struct State {
        var slot: Slot
        /// Requests that have arrived and are not yet answered or dropped:
        /// at the worker, or waiting for their turn.
        var requests = 0
        /// Rests the serving worker once its time has passed. It exists only
        /// while `requests` is zero: armed when the last is answered, and
        /// cancelled, under the lock, by the next to arrive.
        var idle: Task<Void, Never>?
        /// The worker whose exit the owner hears of. The relay lets go of it,
        /// under the lock, before it ends that worker itself; its watch lets
        /// go of it once it has exited by itself. Whichever is first decides.
        var watched: WorkerChannel?
    }

    /// The per-boot channel token the guest must present.
    let token = randomBytes(32)
    private let afterLoss: AfterLoss
    private let resting: Resting?
    private let state: Mutex<State>
    /// The last request that gives way, until a later request cancels it.
    private let yielding = Mutex<Call?>(nil)
    private let queue = DispatchQueue(label: "sh.regents.cloak.relay")
    private let watch = DispatchQueue(label: "sh.regents.cloak.relay.watch")

    /// A relay whose worker never rests; what follows a lost one is what
    /// `afterLoss` decides.
    public init(worker: WorkerChannel, afterLoss: @escaping AfterLoss) {
        state = Mutex(State(slot: .serving(worker)))
        self.afterLoss = afterLoss
        resting = nil
    }

    /// A relay whose worker rests as `resting` says, its time starting now.
    /// A lost worker is followed by none.
    public init(worker: WorkerChannel, resting: Resting) {
        state = Mutex(State(slot: .serving(worker), watched: worker))
        afterLoss = { nil }
        self.resting = resting
        watchExit(of: worker, resting)
        state.withLock { arm(&$0) }
    }

    /// Takes ownership of the socket.
    func accept(_ socket: Int32) {
        arrived()
        giveWay(to: nil)
        queue.async { [self] in
            let lost = serve(socket)
            close(socket)
            if let lost { replaceAfter(lost) }
            answered()
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
        arrived()
        giveWay(to: yielding ? call : nil)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async { [self] in
                    let (answer, lost) = serve(request, call)
                    continuation.resume(returning: answer)
                    if let lost { replaceAfter(lost) }
                    answered()
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

    /// A request has arrived, so the worker does not rest while it waits or
    /// is served.
    private func arrived() {
        state.withLock { state in
            state.requests += 1
            state.idle?.cancel()
            state.idle = nil
        }
    }

    /// A request has been answered or dropped: with none left, the time to
    /// the rest starts again.
    private func answered() {
        state.withLock { state in
            state.requests -= 1
            arm(&state)
        }
    }

    /// Starts the time to the rest, when this relay rests, a worker serves,
    /// no request is left and a time is chosen.
    private func arm(_ state: inout State) {
        guard let resting, state.requests == 0, case .serving = state.slot, let after = resting.after() else { return }
        state.idle = Task {
            guard (try? await Task.sleep(for: after)) != nil else { return }
            rest(resting)
        }
    }

    /// Rests the serving worker: ends it as `finish` does, then tells the
    /// owner once it has exited. Nothing happens when a request arrived since
    /// the time started (it cancelled this task, under the lock) or the
    /// worker has already exited by itself (its watch has let go of it).
    /// Runs on the idle task.
    private func rest(_ resting: Resting) {
        state.withLock { state in
            guard !Task.isCancelled, state.requests == 0, case .serving(let worker) = state.slot, state.watched === worker
            else { return }
            state.idle = nil
            state.watched = nil
            state.slot = .resting(Task {
                await worker.finish()
                resting.changed(.rested)
            })
        }
    }

    /// The worker for the request whose turn it is, woken first when it
    /// rests; nil when there is none. The wake is made under the lock, so its
    /// own use of the slot comes after this one, and the queue waits for it,
    /// so the requests behind this one keep their order. Runs on the queue.
    private func worker() -> WorkerChannel? {
        let woken = DispatchSemaphore(value: 0)
        let waking = state.withLock { state in
            guard case .resting(let rest) = state.slot, let resting = self.resting else { return false }
            state.slot = .waking(Task {
                await wake(after: rest, resting)
                woken.signal()
            })
            return true
        }
        if waking { woken.wait() }
        guard case .serving(let worker) = state.withLock({ $0.slot }) else { return nil }
        return worker
    }

    /// Starts a new worker once the one that rested has exited, and puts it
    /// in the slot, or none when it cannot start, which the owner hears of.
    /// A wake that `finish` cancels stops the worker loading at once, and
    /// tells nothing.
    private func wake(after rest: Task<Void, Never>, _ resting: Resting) async {
        await rest.value
        var next: WorkerChannel?
        do {
            try Task.checkCancellation()
            next = try await resting.start()
        } catch is CancellationError {
            // `finish` stopped the load.
        } catch {
            resting.changed(.cannotWake(error))
        }
        state.withLock { state in
            state.slot = next.map(Slot.serving) ?? .none
            state.watched = next
        }
        guard let next else { return }
        resting.changed(.woke(next))
        watchExit(of: next, resting)
    }

    /// Tells the owner once `worker` has exited, unless the relay let go of
    /// it first to end it itself.
    private func watchExit(of worker: WorkerChannel, _ resting: Resting) {
        Task {
            let end = await worker.exited()
            let unended = state.withLock { state in
                guard state.watched === worker else { return false }
                state.watched = nil
                return true
            }
            if unended { resting.changed(.exited(end)) }
        }
    }

    /// Nothing more is served until the replacement has settled. The task is
    /// made under the lock, so its own use of the slot comes after this one.
    /// Runs on the queue.
    private func replaceAfter(_ lost: WorkerChannel) {
        queue.suspend()
        state.withLock { $0.slot = .replacing(Task { await replace(lost) }) }
    }

    /// Ends the worker: after any replacement in progress has settled, once
    /// a wake in progress has stopped, and once a worker that rested has
    /// exited. The owner hears of no exit it causes.
    public func finish() async {
        while true {
            let next: Slot = state.withLock { state in
                let current = state.slot
                switch current {
                case .replacing, .waking:
                    return current
                case .serving, .resting, .none, .finished:
                    state.slot = .finished
                    state.idle?.cancel()
                    state.idle = nil
                    state.watched = nil
                    return current
                }
            }
            switch next {
            case .replacing(let replacement):
                await replacement.value
            case .waking(let wake):
                wake.cancel()
                await wake.value
            case .serving(let worker):
                await worker.finish()
                return
            case .resting(let rest):
                await rest.value
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
        guard let worker = worker() else {
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
        guard let worker = worker() else {
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
        state.withLock { $0.slot = next.map(Slot.serving) ?? .none }
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
