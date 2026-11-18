import CloakHost
@testable import CloakSupervisor
import Foundation
import Synchronization
import Testing

/// The worker resting while Cloak runs, through a real relay given
/// `Relay.Resting`, as the supervisor makes it, and tests/fake_worker.py,
/// with rest times of a second or less. The tests keep off the main actor,
/// which other suites keep busy, so that their requests come when they say.
@Suite(.serialized)
struct RestTests {
    /// The time counts from the last answer, so a request made before the
    /// time is up starts it again.
    @Test func theWorkerRestsOnceNothingHasBeenAskedForTheRestTimeSinceTheLastAnswer() async throws {
        try await RestingWorker.with(restAfter: .seconds(1)) { worker in
            let clock = ContinuousClock()
            try await Task.sleep(for: .milliseconds(300))
            #expect(try await worker.rewrite("case:ok first") == "CASE:OK FIRST")
            let answered = clock.now
            try await worker.wait { worker.has("ended") }
            #expect(clock.now - answered >= .seconds(1))
            try await worker.wait { !worker.told.value.isEmpty }
            #expect(worker.kinds == [.rested])
            #expect(worker.starts.count == 1)
            #expect(!worker.starts.contains(where: isRunning))
        }
    }

    @Test func aRequestAfterARestIsAnsweredByANewWorkerWhichRestsInItsTurn() async throws {
        try await RestingWorker.with(restAfter: .milliseconds(300)) { worker in
            try await worker.wait { worker.kinds == [.rested] }
            #expect(try await worker.rewrite("case:ok again") == "CASE:OK AGAIN")
            #expect(worker.kinds == [.rested, .woke])
            #expect(worker.starts.count == 2)
            #expect(isRunning(worker.starts[1]))
            try await worker.wait { worker.kinds == [.rested, .woke, .rested] }
            #expect(!worker.starts.contains(where: isRunning))
            #expect(worker.requests == 1)
        }
    }

    /// The worker that rested takes a second to exit once its input closes,
    /// and a request arrives in that second: the new worker starts only once
    /// it has exited.
    @Test func twoWorkersNeverHoldTheModelAtOnce() async throws {
        try await RestingWorker.with(restAfter: .milliseconds(300)) { worker in
            try await worker.wait { worker.has("ended") }
            #expect(isRunning(worker.starts[0]))
            #expect(try await worker.rewrite("case:ok again") == "CASE:OK AGAIN")
            #expect(worker.kinds == [.rested, .woke])
            #expect(worker.starts.count == 2)
            #expect(!worker.has("overlaps"))
        }
    }

    /// A crash while idle stays a failure: the owner hears of the exit, and
    /// the worker never rests or wakes after it.
    @Test func aWorkerThatEndsByItselfWhileIdleIsAnExitAndNeverARest() async throws {
        try await RestingWorker.with(restAfter: .seconds(1)) { worker in
            kill(worker.starts[0], SIGKILL)
            try await worker.wait { !worker.told.value.isEmpty }
            #expect(worker.kinds == [.exited(Termination(status: SIGKILL, signalled: true))])
            try await Task.sleep(for: .milliseconds(1500))
            #expect(worker.kinds == [.exited(Termination(status: SIGKILL, signalled: true))])
            #expect(worker.starts.count == 1)
        }
    }

    /// The model's files changed while the worker rested: the request that
    /// woke it gets no answer, the owner hears why, and nothing starts again.
    @Test func aWorkerThatCannotWakeFailsItsRequestAndIsNeverTriedAgain() async throws {
        try await RestingWorker.with(restAfter: .milliseconds(300), wake: .modelChanged) { worker in
            try await worker.wait { worker.kinds == [.rested] }
            await #expect(throws: RewriteStop.stopped) { try await worker.rewrite("case:ok again") }
            #expect(worker.kinds == [.rested, .cannotWake(Termination(status: 3, signalled: false))])
            await #expect(throws: RewriteStop.stopped) { try await worker.rewrite("case:ok later") }
            #expect(worker.starts.count == 2)
            #expect(worker.requests == 0)
        }
    }

    @Test func aRequestCancelledWhileANewWorkerLoadsIsNeverSent() async throws {
        try await RestingWorker.with(restAfter: .milliseconds(300), wake: .slow) { worker in
            try await worker.wait { worker.kinds == [.rested] }
            let call = Task { try await worker.rewrite("case:ok cancelled") }
            try await worker.wait { worker.starts.count == 2 }
            call.cancel()
            await #expect(throws: RewriteStop.cancelled) { try await call.value }
            #expect(try await worker.rewrite("case:ok next") == "CASE:OK NEXT")
            #expect(worker.requests == 1)
            #expect(worker.kinds == [.rested, .woke])
        }
    }

    /// A pause, stop or quit while the worker rests ends it at once and
    /// starts nothing, then or later.
    @Test func finishingWhileRestingStartsNothing() async throws {
        try await RestingWorker.with(restAfter: .milliseconds(300)) { worker in
            try await worker.wait { worker.kinds == [.rested] }
            let clock = ContinuousClock()
            let asked = clock.now
            await worker.relay.finish()
            #expect(clock.now - asked < .milliseconds(500))
            await #expect(throws: RewriteStop.stopped) { try await worker.rewrite("case:ok late") }
            #expect(worker.starts.count == 1)
            #expect(worker.kinds == [.rested])
        }
    }

    /// A pause, stop or quit while a new worker loads stops the load at once,
    /// as during the first load: the request waiting for it gets no answer,
    /// and the owner hears of no failure.
    @Test func finishingWhileANewWorkerLoadsStopsItAtOnce() async throws {
        try await RestingWorker.with(restAfter: .milliseconds(300), wake: .neverReady) { worker in
            try await worker.wait { worker.kinds == [.rested] }
            let call = Task { try await worker.rewrite("case:ok again") }
            try await worker.wait { worker.starts.count == 2 }
            let clock = ContinuousClock()
            let asked = clock.now
            await worker.relay.finish()
            #expect(clock.now - asked < .seconds(3))
            #expect(!worker.starts.contains(where: isRunning))
            await #expect(throws: RewriteStop.stopped) { try await call.value }
            #expect(worker.kinds == [.rested])
            #expect(worker.requests == 0)
        }
    }

    /// Never keeps the worker; a time chosen later applies from the next
    /// answer, with nothing restarted.
    @Test func aTimeChosenLaterAppliesFromTheNextAnswer() async throws {
        try await RestingWorker.with(restAfter: nil) { worker in
            try await Task.sleep(for: .seconds(1))
            worker.restAfter.set(.milliseconds(300))
            try await Task.sleep(for: .seconds(1))
            #expect(worker.told.value.isEmpty)
            #expect(try await worker.rewrite("case:ok now") == "CASE:OK NOW")
            try await worker.wait { worker.kinds == [.rested] }
            #expect(worker.starts.count == 1)
        }
    }
}

/// tests/fake_worker.py behind a relay that rests. Every worker starts
/// through one launcher, as the supervisor starts each with the same program
/// and arguments: it notes its process in `starts`, and in `overlaps` any
/// earlier one still running; a start after the first does what `Wake` says
/// first. Once the fake worker has exited, on the end of its input, the
/// launcher notes it in `ended` and takes a second more to exit.
final class RestingWorker: Sendable {
    /// What a start after the first does before the fake worker runs.
    enum Wake: String {
        case same = ":"
        /// Exits as the worker does when the model's files differ from their
        /// pins.
        case modelChanged = "exit 3"
        /// Never signals ready, as a worker still loading, until stopped.
        case neverReady = "exec sleep 600"
        /// Takes two seconds to signal ready.
        case slow = "sleep 2"
    }

    /// What the relay told, as tests compare it.
    enum Told: Equatable {
        case rested
        case woke
        /// How the worker that could not start ended.
        case cannotWake(Termination?)
        case exited(Termination)
    }

    let log: URL
    let relay: Relay
    /// How long the worker may go with nothing asked; nil, never.
    let restAfter: Locked<Duration?>
    /// Each change the relay told, in order.
    let told: Locked<[Relay.Change]>

    private init(restAfter: Duration?, wake: Wake) async throws {
        log = URL(filePath: "/tmp").appending(path: "cloak-rest-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: log, withIntermediateDirectories: true)
        let python = String(decoding: try DaemonReply.run(["uv", "python", "find"], in: log), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let launcher = log.appending(path: "worker")
        try Data("""
            #!/bin/sh
            log="\(log.path)"
            for pid in $(cat "$log/starts" 2>/dev/null); do
                if kill -0 "$pid" 2>/dev/null; then echo "$pid" >> "$log/overlaps"; fi
            done
            if [ -s "$log/starts" ]; then
                echo $$ >> "$log/starts"
                \(wake.rawValue)
            else
                echo $$ >> "$log/starts"
            fi
            export FAKE_WORKER_LOG="$log" FAKE_WORKER_READ_DELAY=0
            "\(python)" -I "\(DaemonReply.root.appending(path: "tests/fake_worker.py").path)"
            echo $$ >> "$log/ended"
            sleep 1
            """.utf8).write(to: launcher)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        let rest = Locked(restAfter), told = Locked<[Relay.Change]>([])
        self.restAfter = rest
        self.told = told
        let start: @Sendable () async throws -> WorkerChannel = {
            try await WorkerChannel.start(executable: launcher, arguments: [])
        }
        relay = Relay(
            worker: try await start(),
            resting: .init(after: { rest.value }, start: start, changed: { change in told.update { $0.append(change) } }))
    }

    func rewrite(_ text: String) async throws(RewriteStop) -> String {
        try await Rewrite.run([text], model: "worker", relay: relay, deadline: .seconds(30))[0]
    }

    var kinds: [Told] {
        told.value.map { change in
            switch change {
            case .rested: .rested
            case .woke: .woke
            case .cannotWake(let error): .cannotWake((error as? WorkerChannel.NotReady)?.ended)
            case .exited(let end): .exited(end)
            }
        }
    }

    /// The process of each worker started, in order.
    var starts: [pid_t] {
        guard let text = try? String(contentsOf: log.appending(path: "starts"), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { pid_t($0) }
    }

    /// Requests that reached a worker.
    var requests: Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: log.path)) ?? []).filter { $0.hasSuffix(".json") }.count
    }

    func has(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: log.appending(path: name).path)
    }

    /// Waits, up to 10 seconds, for something the relay or a worker does by
    /// itself.
    func wait(until condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(10)
        while !condition() {
            guard clock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Runs `body` with a resting worker, then ends the relay and removes
    /// its files.
    static func with(restAfter: Duration?, wake: Wake = .same, _ body: (RestingWorker) async throws -> Void) async throws {
        let worker = try await RestingWorker(restAfter: restAfter, wake: wake)
        do {
            try await body(worker)
        } catch {
            await worker.finish()
            throw error
        }
        await worker.finish()
    }

    private func finish() async {
        await relay.finish()
        try? FileManager.default.removeItem(at: log)
    }
}

/// A value shared between a test and the callbacks it gives.
final class Locked<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>

    init(_ value: Value) {
        mutex = Mutex(value)
    }

    var value: Value { mutex.withLock { $0 } }

    func set(_ value: Value) {
        mutex.withLock { $0 = value }
    }

    func update(_ change: (inout Value) -> Void) {
        mutex.withLock { change(&$0) }
    }
}
