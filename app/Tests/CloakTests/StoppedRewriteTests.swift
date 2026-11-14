import CloakHost
@testable import CloakSupervisor
import Foundation
import Testing

/// Every way the app's rewrite stops without a reworded text, through a real
/// relay and worker channel to tests/fake_worker.py, which picks what it does
/// from the message's first word. None of them gives back the original.
@Suite(.serialized)
struct StoppedRewriteTests {
    @Test func aWorkersReplyIsTheRewordedText() async throws {
        try await FakeWorker.with { worker async throws in
            #expect(try await worker.rewrite("case:ok say hello") == "CASE:OK SAY HELLO")
        }
    }

    /// One message's texts go in one call, and the cap counts them together.
    @Test func severalTextsAreOneCallUnderOneCap() async throws {
        try await FakeWorker.with { worker async throws in
            #expect(try await worker.rewrite(["case:ok first", "second é"]) == ["CASE:OK FIRST", "SECOND É"])
            #expect(worker.requests == 1)
            let half = String(repeating: "é", count: 5_000)
            // 5,008 and 4,993 characters.
            await #expect(throws: RewriteStop.tooLong(characters: 10_001)) {
                try await worker.rewrite(["case:ok " + half, String(half.dropFirst(7))])
            }
            #expect(worker.requests == 1)
        }
    }

    @Test func overTenThousandCharactersIsRefusedBeforeAnythingIsSent() async throws {
        try await FakeWorker.with { worker async throws in
            // "é" is two bytes, so a limit that counted bytes would show.
            let longest = "case:ok " + String(repeating: "é", count: 10_000 - 8)
            #expect(try await worker.rewrite(longest) == longest.uppercased())
            await #expect(throws: RewriteStop.tooLong(characters: 10_001)) { try await worker.rewrite(longest + "é") }
            #expect(worker.requests == 1)
        }
    }

    @Test(arguments: ["fenced", "extra-field", "wrong-count", "length", "tool-call", "refusal", "status-500", "not-json", "oversized"])
    func aReplyTheDaemonRefusesIsRefused(_ fault: String) async throws {
        try await FakeWorker.with { worker async throws in
            await #expect(throws: RewriteStop.refused) { try await worker.rewrite("case:\(fault) say hello") }
        }
    }

    @Test func cancellingStopsTheWorker() async throws {
        try await FakeWorker.with { worker async throws in
            let call = Task { try await worker.rewrite("case:hold say hello") }
            try await worker.waitFor("1.json")
            call.cancel()
            await #expect(throws: RewriteStop.cancelled) { try await call.value }
            #expect(worker.has("1.cancel"))
        }
    }

    @Test func pastTheDeadlineTheWorkerIsStopped() async throws {
        try await FakeWorker.with { worker async throws in
            await #expect(throws: RewriteStop.timedOut) {
                try await worker.rewrite("case:hold say hello", deadline: .milliseconds(500))
            }
            #expect(worker.has("1.cancel"))
        }
    }

    @Test func aWorkerThatExitsStopsTheRewrite() async throws {
        try await FakeWorker.with { worker async throws in
            await #expect(throws: RewriteStop.stopped) { try await worker.rewrite("case:exit say hello") }
        }
    }

    /// One call at a time: a second waits its turn, and cancelling it there
    /// leaves the call at the worker alone and never reaches the worker.
    @Test func cancellingAWaitingCallLeavesTheOneAtTheWorkerAlone() async throws {
        try await FakeWorker.with { worker async throws in
            let held = Task { try await worker.rewrite("case:hold first") }
            try await worker.waitFor("1.json")
            let waiting = Task { try await worker.rewrite("case:ok second") }
            try await Task.sleep(for: .milliseconds(300))
            waiting.cancel()
            try await Task.sleep(for: .seconds(1))
            #expect(!worker.has("1.cancel"))
            held.cancel()
            await #expect(throws: RewriteStop.cancelled) { try await held.value }
            await #expect(throws: RewriteStop.cancelled) { try await waiting.value }
            #expect(worker.has("1.cancel"))
            #expect(worker.requests == 1)
        }
    }

    @MainActor
    @Test func onlyWhileRunning() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let supervisor = try fixture.supervisor()
        await #expect(throws: RewriteStop.stopped) { try await supervisor.rewrite(["Say hello."]) }
    }
}

/// tests/fake_worker.py behind a relay, as the supervisor runs the worker.
struct FakeWorker {
    let log: URL
    let relay: Relay

    private init() async throws {
        log = URL(filePath: "/tmp").appending(path: "cloak-fake-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: log, withIntermediateDirectories: true)
        let python = String(decoding: try DaemonReply.run(["uv", "python", "find"], in: log), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let launcher = log.appending(path: "fake-worker")
        try Data("""
            #!/bin/sh
            export FAKE_WORKER_LOG="\(log.path)" FAKE_WORKER_READ_DELAY=0
            exec "\(python)" -I "\(DaemonReply.root.appending(path: "tests/fake_worker.py").path)"
            """.utf8).write(to: launcher)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        relay = Relay(worker: try await WorkerChannel.start(executable: launcher, arguments: [])) { nil }
    }

    func rewrite(_ text: String, deadline: Duration = .seconds(30)) async throws(RewriteStop) -> String {
        try await rewrite([text], deadline: deadline)[0]
    }

    func rewrite(_ texts: [String], deadline: Duration = .seconds(30)) async throws(RewriteStop) -> [String] {
        try await Rewrite.run(texts, model: "worker", relay: relay, deadline: deadline)
    }

    /// Requests that reached the worker.
    var requests: Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: log.path)) ?? []).filter { $0.hasSuffix(".json") }.count
    }

    func has(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: log.appending(path: name).path)
    }

    func waitFor(_ name: String) async throws {
        for _ in 0..<100 where !has(name) {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(has(name))
    }

    /// Runs `body` with a fake worker, then stops it and removes its files.
    static func with(_ body: (FakeWorker) async throws -> Void) async throws {
        let worker = try await FakeWorker()
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
