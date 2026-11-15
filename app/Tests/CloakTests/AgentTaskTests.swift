import CloakHost
@testable import CloakSupervisor
import Foundation
import Synchronization
import Testing

/// The owner's agent tasks on the Mac, against a stand-in for the guest's
/// runner on the other end of a socket pair: the task's request, its events
/// in order to its exit, each refusal, the guest going away mid-task,
/// ending the events, a stop with tasks under way, and a task asked for
/// while Cloak is not Running.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct AgentTaskTests {
    static let request = Runner.Request(
        task: "Count the files.\nThen say how many.", session: "c-1", model: "cheap", pass: "cloak-" + String(repeating: "ab", count: 32))

    static func exit(_ status: Int32, signalled: Bool = false) -> Data {
        RunnerStandIn.frame("X", Data(#"{"status":\#(status),"signalled":\#(signalled)}"#.utf8))
    }

    /// The events until the stream ends, and the error it ended with.
    static func collect(_ stream: AsyncThrowingStream<Runner.Event, any Error>) async -> (events: [Runner.Event], stop: (any Error)?) {
        var events = [Runner.Event]()
        do {
            for try await event in stream { events.append(event) }
        } catch {
            return (events, error)
        }
        return (events, nil)
    }

    @Test func theEventsComeInOrderThenTheExit() async throws {
        let lines: [(Character, Data)] = [
            ("O", Data(#"{"type":"session","id":"c-1"}"#.utf8)), ("E", Data("a warning".utf8)), ("O", Data()),
            ("O", Data([0xFF, 0xFE, 0x20])), ("O", Data(#"{"type":"agent_end"}"#.utf8)),
        ]
        let standIn = try RunnerStandIn(lines.map { RunnerStandIn.frame($0, $1) } + [Self.exit(0)], then: .close)
        let (events, stop) = await Self.collect(Runner.run(standIn.socket, Self.request))
        #expect(stop == nil)
        #expect(events == lines.map { $0 == "O" ? .output($1) : .error($1) } + [.exited(Termination(status: 0, signalled: false))])

        let read = try #require(standIn.request)
        #expect(read.task == Self.request.task && read.session == "c-1" && read.model == "cheap" && read.pass == Self.request.pass)

        for (status, signalled) in [(Int32(3), false), (9, true)] {
            let standIn = try RunnerStandIn([Self.exit(status, signalled: signalled)], then: .close)
            let (events, stop) = await Self.collect(Runner.run(standIn.socket, Self.request))
            #expect(stop == nil)
            #expect(events == [.exited(Termination(status: status, signalled: signalled))])
        }
    }

    @Test func aRefusedTaskEndsWithWhy() async throws {
        for (word, why) in [("busy", Runner.Stop.busy), ("invalid", .invalid), ("other", .ended)] {
            let standIn = try RunnerStandIn([RunnerStandIn.frame("N", Data(word.utf8))], then: .close)
            let (events, stop) = await Self.collect(Runner.run(standIn.socket, Self.request))
            #expect(events.isEmpty, "\(word)")
            #expect(stop as? Runner.Stop == why, "\(word)")
        }
    }

    /// Before the exit: the connection closing, a frame of no kind the runner
    /// sends, an exit that does not read, a frame cut short, and one over the
    /// largest taken.
    @Test func aConnectionThatEndsBeforeTheExitEndsTheTask() async throws {
        let output = RunnerStandIn.frame("O", Data("{}".utf8))
        let scripts: [(String, [Data])] = [
            ("the guest goes away", [output]),
            ("another kind", [output, RunnerStandIn.frame("Z", Data())]),
            ("an exit that does not read", [output, RunnerStandIn.frame("X", Data("0".utf8))]),
            ("a frame cut short", [output, Data([UInt8(ascii: "O"), 0, 0, 0, 10]) + Data("{}".utf8)]),
            ("a frame over 16 MiB", [output, Data([UInt8(ascii: "O"), 0x01, 0, 0, 0x01])]),
        ]
        for (name, script) in scripts {
            let standIn = try RunnerStandIn(script, then: .close)
            let (events, stop) = await Self.collect(Runner.run(standIn.socket, Self.request))
            #expect(events == [.output(Data("{}".utf8))], "\(name)")
            #expect(stop as? Runner.Stop == .ended, "\(name)")
        }
    }

    @Test func endingTheEventsClosesTheConnection() async throws {
        let standIn = try RunnerStandIn([RunnerStandIn.frame("O", Data("{}".utf8))], then: .hold)
        for try await event in Runner.run(standIn.socket, Self.request) {
            #expect(event == .output(Data("{}".utf8)))
            break
        }
        let ended = ContinuousClock.now
        await standIn.closed()
        #expect(ended.duration(to: .now) < .seconds(2))

        // The same through the supervisor's tasks.
        let tasks = AgentTasks()
        let again = try RunnerStandIn([RunnerStandIn.frame("O", Data("{}".utf8))], then: .hold)
        for try await event in tasks.run(Self.request, connect: { again.socket }) {
            #expect(event == .output(Data("{}".utf8)))
            break
        }
        let stopped = ContinuousClock.now
        await again.closed()
        #expect(stopped.duration(to: .now) < .seconds(2))
    }

    @Test func aStopEndsEveryTaskUnderWayAsStopped() async throws {
        let tasks = AgentTasks()
        let first = try RunnerStandIn([], then: .hold), second = try RunnerStandIn([], then: .hold)
        let consumers = [first, second].map { standIn in
            let events = tasks.run(Self.request) { standIn.socket }
            return Task { await Self.collect(events) }
        }
        // Each is under way once the runner has its request.
        for _ in 0..<250 where first.request == nil || second.request == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(first.request != nil && second.request != nil)
        let stopped = ContinuousClock.now
        tasks.stop()
        for consumer in consumers {
            let (events, stop) = await consumer.value
            #expect(events.isEmpty)
            #expect(stop as? Runner.Stop == .stopped)
        }
        await first.closed()
        await second.closed()
        #expect(stopped.duration(to: .now) < .seconds(2))
    }

    @Test func theGuestGoingAwayEndsTheSupervisorsTask() async throws {
        let tasks = AgentTasks()
        let standIn = try RunnerStandIn([RunnerStandIn.frame("O", Data("{}".utf8))], then: .close)
        let (events, stop) = await Self.collect(tasks.run(Self.request) { standIn.socket })
        #expect(events == [.output(Data("{}".utf8))])
        #expect(stop as? Runner.Stop == .ended)

        // No connection to the runner: the reason it could not be made.
        let (none, why) = await Self.collect(tasks.run(Self.request) { throw POSIXError(.ECONNREFUSED) })
        #expect(none.isEmpty)
        #expect((why as? POSIXError)?.code == .ECONNREFUSED)
    }

    @Test func aTaskAskedForWhileNotRunningRunsNothing() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let supervisor = try fixture.supervisor()
        #expect(supervisor.phase == .paused)
        let (events, stop) = await Self.collect(supervisor.run(Self.request))
        #expect(events.isEmpty)
        #expect(stop as? Runner.Stop == .notRunning)
    }
}

/// A stand-in for the guest's runner on the far end of a socket pair: it
/// reads the task's frame, writes `script`, then either closes its end or,
/// with `hold`, waits for the host to end the connection first.
final class RunnerStandIn: Sendable {
    enum End: Sendable {
        case close
        case hold
    }

    /// The host's end, for `Runner.run`.
    let socket: Int32
    private let read = Mutex<Runner.Request?>(nil)
    private let ended: AsyncStream<Void>

    init(_ script: [Data], then end: End) throws {
        var pair: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw POSIXError(.EIO) }
        socket = pair[0]
        let far = pair[1]
        var on: Int32 = 1
        setsockopt(far, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let (ended, done) = AsyncStream.makeStream(of: Void.self)
        self.ended = ended
        Thread { [self] in
            defer {
                close(far)
                done.finish()
            }
            guard let (kind, payload) = Self.frame(far), kind == UInt8(ascii: "T"),
                let request = try? JSONDecoder().decode(Runner.Request.self, from: payload)
            else { return }
            read.withLock { $0 = request }
            for data in script {
                guard Self.write(far, data) else { return }
            }
            if case .hold = end {
                var byte: UInt8 = 0
                while Darwin.read(far, &byte, 1) > 0 {}
            }
        }.start()
    }

    /// The task's request, once read.
    var request: Runner.Request? { read.withLock { $0 } }

    /// Returns once the stand-in's end is closed: for `hold`, after the host
    /// ended the connection.
    func closed() async {
        for await _ in ended {}
    }

    static func frame(_ kind: Character, _ payload: Data) -> Data {
        Data([kind.asciiValue!]) + withUnsafeBytes(of: UInt32(payload.count).bigEndian) { Data($0) } + payload
    }

    private static func write(_ socket: Int32, _ data: Data) -> Bool {
        var done = 0
        while done < data.count {
            let n = data.withUnsafeBytes { Darwin.write(socket, $0.baseAddress! + done, data.count - done) }
            guard n > 0 else { return false }
            done += n
        }
        return true
    }

    private static func frame(_ socket: Int32) -> (UInt8, Data)? {
        guard let head = exactly(socket, 5) else { return nil }
        let length = head.dropFirst().reduce(0) { $0 << 8 | Int($1) }
        guard let payload = exactly(socket, length) else { return nil }
        return (head[0], payload)
    }

    private static func exactly(_ socket: Int32, _ count: Int) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while data.count < count {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(socket, $0.baseAddress!, min($0.count, count - data.count)) }
            guard n > 0 else { return nil }
            data += buffer.prefix(n)
        }
        return data
    }
}
