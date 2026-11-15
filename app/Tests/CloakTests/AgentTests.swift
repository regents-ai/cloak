@testable import CloakChat
@testable import CloakDoor
import CloakHost
import CloakSupervisor
import Foundation
import Testing

/// What the agent's lines say for a task's card, against Pi's lines in the
/// shapes its JSON mode writes (docs/json.md and docs/message-types.md in
/// Pi's package, and the door's own refusals as Pi words them).
@Suite
struct PiEventTests {
    @Test func aTasksLinesGiveItsStepsInOrderThenItsAnswer() {
        let events = PiLines.task.compactMap { PiEvent(line: Data($0.utf8)) }
        #expect(events == PiLines.steps.map(PiEvent.step) + [.answer("There are 3 files.")])
    }

    /// The door's own sentence for each refusal, as Pi writes the status
    /// and the door's error; none when the door gave none.
    @Test func aRefusedRequestGivesTheDoorsSentence() throws {
        for failure in [CloakDoor.Failure.stopped, CloakDoor.Failure(RewriteStop.timedOut), CloakDoor.Failure.tooLong(12_000), CloakDoor.Failure(402, "insufficient_funds", "No funds.")] {
            let events = try PiLines.refused(failure).compactMap { PiEvent(line: Data($0.utf8)) }
            #expect(events == [.failure(failure.message)], "\(failure.code)")
        }
        for error in ["Connection error.", "Request was aborted.", "402 No funds.", #"500: not json"#] {
            #expect(PiEvent(line: PiLines.failed(error)) == .failure(nil), "\(error)")
        }
    }

    @Test func everyOtherLineSaysNothing() {
        let lines = [
            "", "not a line of Pi's", "[1, 2]", #"{"type":"compaction_start","reason":"threshold"}"#,
            #"{"type":"auto_retry_start","attempt":1,"maxAttempts":3,"delayMs":2000,"errorMessage":"529 overloaded"}"#,
            #"{"type":"tool_execution_start","toolCallId":"call_x","args":{}}"#,
            #"{"type":"message_end","message":{"role":"user","content":"Count the files.","timestamp":1794650400000}}"#,
            #"{"type":"message_end","message":\#(PiLines.assistant(PiLines.bashCalls, stop: "toolUse"))}"#,
            #"{"type":"message_end","message":\#(PiLines.assistant("[]", stop: "deferred"))}"#,
        ]
        for line in lines {
            #expect(PiEvent(line: Data(line.utf8)) == nil, "\(line)")
        }
    }
}

/// The owner's agent tasks against a stand-in for the runner's events: a
/// task runs to its answer, Stop ends it, Cloak stopping ends it, one that
/// ends without an answer says why, Run is held back only where it is
/// certain to stop, and another conversation runs meanwhile.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AgentTests {
    static let pass = "cloak-" + String(repeating: "cd", count: 32)

    /// An agent with the stand-in, a door that is open unless `open` says
    /// not, and the door's reworded task as `reworded` gives it.
    static func agent(_ runner: StandInRunner, open: @escaping () -> Bool = { true }, reworded: @escaping () -> String? = { nil }) -> Agent {
        Agent(parts: Agent.Parts(run: { runner.run($0) }, pass: { _ in open() ? Self.pass : nil }, reworded: { _ in reworded() }))
    }

    static func until(_ done: () -> Bool) async throws {
        for _ in 0..<250 where !done() {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(done())
    }

    @Test func aTaskRunsToItsAnswer() async throws {
        let runner = StandInRunner()
        let said = "COUNT THE FILES HERE, THEN SAY HOW MANY."
        let agent = Self.agent(runner, reworded: { said })
        let conversation = UUID()
        var kept = [Turn]()
        agent.run("Count the files here, then say how many.", in: conversation, model: "cheap") { kept.append($0) }

        // Kept as it starts.
        let started = try #require(kept.first)
        #expect(kept.count == 1 && started.steps == [] && started.reworded == nil && started.answer == nil)
        #expect(agent.runs[conversation]?.turn == started)
        let request = try #require(runner.requests.first)
        #expect(request.task == started.original && request.session == conversation.uuidString)
        #expect(request.model == "cheap" && request.pass == Self.pass)

        // The task as reworded once its first model request has gone through.
        let first = try #require(PiLines.task.firstIndex { $0.contains("tool_execution_start") })
        runner.say(Array(PiLines.task[...first]), in: request.session)
        try await Self.until { agent.runs[conversation]?.turn.steps?.count == 1 }
        #expect(agent.runs[conversation]?.turn.reworded == said)
        #expect(agent.ran == [conversation])

        // Standard error is not the card's; the last steps and the answer are.
        runner.send(.error(Data("a warning".utf8)), in: request.session)
        runner.say(Array(PiLines.task[(first + 1)...]), in: request.session)
        runner.exit(request.session)
        try await Self.until { agent.runs[conversation] == nil }
        #expect(kept.count == 2)
        let ended = kept[1]
        #expect(ended.id == started.id && ended.original == started.original)
        #expect(ended.steps == PiLines.steps && ended.reworded == said && ended.answer == "There are 3 files.")
        #expect(agent.ends.isEmpty)
    }

    @Test func stopEndsTheTaskAndKeepsItsSteps() async throws {
        let runner = StandInRunner()
        let agent = Self.agent(runner)
        let conversation = UUID()
        var kept = [Turn]()
        agent.run("Count the files.", in: conversation, model: "cheap") { kept.append($0) }
        let first = try #require(PiLines.task.firstIndex { $0.contains("tool_execution_start") })
        runner.say(Array(PiLines.task[...first]), in: conversation.uuidString)
        try await Self.until { agent.runs[conversation]?.turn.steps?.count == 1 }

        agent.stop(conversation)
        agent.stop(conversation)
        try await Self.until { agent.runs[conversation] == nil }
        #expect(kept.count == 2 && kept[1].steps == [PiLines.steps[0]] && kept[1].answer == nil)
        #expect(agent.ends[kept[1].id] == .stopped)
        // Its events were ended from this side, which ends the task in the guest.
        #expect(runner.ended(conversation.uuidString))
    }

    /// Pause, Stop and Quit end every task under way as stopped, and a task
    /// asked for while Cloak is not Running runs nothing.
    @Test func cloakStoppingEndsTheTask() async throws {
        let runner = StandInRunner()
        let agent = Self.agent(runner)
        for stop in [Runner.Stop.stopped, .notRunning] {
            let conversation = UUID()
            var kept = [Turn]()
            agent.run("Count the files.", in: conversation, model: "cheap") { kept.append($0) }
            runner.say(Array(PiLines.task.prefix(3)), in: conversation.uuidString)
            runner.finish(conversation.uuidString, throwing: stop)
            try await Self.until { agent.runs[conversation] == nil }
            #expect(kept.count == 2 && kept[1].answer == nil, "\(stop)")
            #expect(agent.ends[kept[1].id] == .cloakStopped, "\(stop)")
        }
    }

    @Test func aTaskThatEndsWithoutAnAnswerSaysWhy() async throws {
        let runner = StandInRunner()
        let agent = Self.agent(runner)
        let refusal = CloakDoor.Failure(402, "insufficient_funds", "No funds.")
        let refused = try PiLines.refused(refusal)
        let retried = #"{"type":"auto_retry_start","attempt":1,"maxAttempts":3,"delayMs":2000,"errorMessage":"502 failed"}"#
        let first = try #require(PiLines.task.firstIndex { $0.contains("tool_execution_start") })
        let cases: [(name: String, lines: [String], end: Runner.Stop?, ended: Agent.End?)] = [
            ("the door refused its request", refused, nil, .failed(refusal.message)),
            ("refused, then retried and answered", refused + [retried] + PiLines.task, nil, nil),
            ("refused, then retried, then an exit", refused + [retried] + Array(PiLines.task[...first]), nil, .failed(nil)),
            ("the guest went away", Array(PiLines.task.prefix(3)), .ended, .failed(nil)),
            ("an exit without an answer", Array(PiLines.task.prefix(3)), nil, .failed(nil)),
        ]
        for (name, lines, end, ended) in cases {
            let conversation = UUID()
            var kept = [Turn]()
            agent.run("Count the files.", in: conversation, model: "cheap") { kept.append($0) }
            runner.say(lines, in: conversation.uuidString)
            if let end { runner.finish(conversation.uuidString, throwing: end) } else { runner.exit(conversation.uuidString) }
            try await Self.until { agent.runs[conversation] == nil }
            let turn = try #require(kept.last, "\(name)")
            #expect(agent.ends[turn.id] == ended, "\(name)")
            #expect((turn.answer != nil) == (ended == nil), "\(name)")
        }
    }

    @Test func runIsHeldBackOnlyWhereItIsCertainToStop() async throws {
        // Cloak not running, then no wallet, then no funds.
        let holds: [(running: Bool, hasWallet: Bool, lacksFunds: Bool, block: Block?)] = [
            (false, false, false, .notRunning), (false, true, true, .notRunning), (false, true, false, .notRunning),
            (true, false, false, .noWallet), (true, false, true, .noWallet),
            (true, true, true, .noFunds),
            (true, true, false, nil),
        ]
        for hold in holds {
            #expect(Block(running: hold.running, hasWallet: hold.hasWallet, lacksFunds: hold.lacksFunds) == hold.block, "\(hold)")
        }

        let runner = StandInRunner()
        var open = true
        let agent = Self.agent(runner, open: { open })
        let conversation = UUID()
        var kept = [Turn]()
        // A second task in a conversation with one under way, which the
        // guest would refuse: nothing is asked of it.
        agent.run("Count the files.", in: conversation, model: "cheap") { kept.append($0) }
        agent.run("Count them again.", in: conversation, model: "cheap") { kept.append($0) }
        #expect(runner.requests.count == 1 && kept.count == 1)

        // With the door not open, the agent has no way to the model: the
        // task ends at once and is kept.
        open = false
        let closed = UUID()
        var keptClosed = [Turn]()
        agent.run("Count the files.", in: closed, model: "cheap") { keptClosed.append($0) }
        #expect(runner.requests.count == 1 && agent.runs[closed] == nil)
        #expect(keptClosed.count == 1 && agent.ends[keptClosed[0].id] == .unreachable)

        // Once the task has ended, every press runs a new one, in the same
        // conversation, as its next task.
        open = true
        runner.exit(conversation.uuidString)
        try await Self.until { agent.runs[conversation] == nil }
        for index in 1...2 {
            agent.run("Count the files.", in: conversation, model: "cheap") { kept.append($0) }
            runner.exit(conversation.uuidString)
            try await Self.until { agent.runs[conversation] == nil }
            #expect(runner.requests.count == 1 + index)
        }
        #expect(runner.requests.allSatisfy { $0.session == conversation.uuidString })
        #expect(Set(kept.map(\.id)).count == 3)
    }

    @Test func anotherConversationRunsMeanwhile() async throws {
        let runner = StandInRunner()
        let agent = Self.agent(runner)
        let first = UUID(), second = UUID()
        var kept = [UUID: [Turn]]()
        agent.run("Count the files.", in: first, model: "cheap") { kept[first, default: []].append($0) }
        agent.run("Count the folders.", in: second, model: "cheap") { kept[second, default: []].append($0) }
        #expect(runner.requests.map(\.session) == [first.uuidString, second.uuidString])
        #expect(agent.runs[first] != nil && agent.runs[second] != nil)

        runner.say(Array(PiLines.task.prefix(1)), in: first.uuidString)
        runner.say(PiLines.task, in: second.uuidString)
        runner.exit(second.uuidString)
        try await Self.until { agent.runs[second] == nil }
        #expect(kept[second]?.last?.answer == "There are 3 files.")
        #expect(agent.runs[first] != nil && kept[first]?.count == 1)
        #expect(agent.ran == [first, second])

        // Cloak starting again is a new guest, without either one's work.
        agent.restarted()
        #expect(agent.ran.isEmpty)
        agent.stop(first)
        try await Self.until { agent.runs[first] == nil }
        #expect(kept[first]?.last.flatMap { agent.ends[$0.id] } == .stopped)
    }
}

/// A stand-in for the runner's events: each task's stream, fed by the test.
@MainActor
final class StandInRunner {
    private(set) var requests: [Runner.Request] = []
    private var tasks: [String: AsyncThrowingStream<Runner.Event, any Error>.Continuation] = [:]

    func run(_ request: Runner.Request) -> AsyncThrowingStream<Runner.Event, any Error> {
        requests.append(request)
        let (events, continuation) = AsyncThrowingStream.makeStream(of: Runner.Event.self, throwing: (any Error).self)
        tasks[request.session] = continuation
        return events
    }

    func say(_ lines: [String], in session: String) {
        for line in lines {
            send(.output(Data(line.utf8)), in: session)
        }
    }

    func send(_ event: Runner.Event, in session: String) {
        tasks[session]?.yield(event)
    }

    /// Pi's exit: 0 even when a model request failed.
    func exit(_ session: String) {
        send(.exited(Termination(status: 0, signalled: false)), in: session)
        tasks[session]?.finish()
    }

    func finish(_ session: String, throwing stop: Runner.Stop) {
        tasks[session]?.finish(throwing: stop)
    }

    /// Whether the task's events were ended from the host's side.
    func ended(_ session: String) -> Bool {
        guard case .terminated? = tasks[session]?.yield(.error(Data())) else { return false }
        return true
    }
}

/// Pi's lines for one task, in the shapes its JSON mode writes: a bash call,
/// then a read, an edit, a write and a tool with nothing to show, between
/// lines the card does not use, then the answer.
enum PiLines {
    static let usage = #"{"input":812,"output":24,"cacheRead":0,"cacheWrite":0,"totalTokens":836,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}}"#
    static let bashCall = #"{"type":"toolCall","id":"call_tool","name":"bash","arguments":{"command":"ls -1 | wc -l"}}"#
    static let bashCalls = "[" + bashCall + "]"
    static let session = #"{"type":"session","version":3,"id":"C0FFEE00-0000-4000-8000-000000000001","timestamp":"2026-11-14T10:00:00.000Z","cwd":"/home/agent/conversations/C0FFEE00-0000-4000-8000-000000000001/workspace"}"#
    static let user = #"{"role":"user","content":[{"type":"text","text":"Count the files here, then say how many."}],"timestamp":1794650400000}"#
    static let calls = #"[{"type":"toolCall","id":"call_read","name":"read","arguments":{"path":"notes.txt"}},{"type":"toolCall","id":"call_edit","name":"edit","arguments":{"path":"notes.txt","edits":[{"oldText":"two files","newText":"three files"}]}},{"type":"toolCall","id":"call_write","name":"write","arguments":{"path":"count.txt","content":"3\n"}},{"type":"toolCall","id":"call_grep","name":"grep","arguments":{"pattern":"files"}}]"#
    static let final = #"[{"type":"thinking","thinking":"Three, so say so."},{"type":"text","text":"There are 3 files."}]"#

    static func assistant(_ content: String, stop: String) -> String {
        #"{"role":"assistant","content":\#(content),"api":"openai-completions","provider":"cloak","model":"cheap","usage":\#(usage),"stopReason":"\#(stop)","timestamp":1794650400500}"#
    }

    static let steps = [
        Step(tool: "bash", detail: "ls -1 | wc -l"), Step(tool: "read", detail: "notes.txt"), Step(tool: "edit", detail: "notes.txt"),
        Step(tool: "write", detail: "count.txt"), Step(tool: "grep", detail: nil),
    ]

    static let task = [
        session, #"{"type":"agent_start"}"#, #"{"type":"turn_start"}"#,
        #"{"type":"message_start","message":\#(user)}"#, #"{"type":"message_end","message":\#(user)}"#,
        #"{"type":"message_start","message":\#(assistant("[]", stop: "pending"))}"#,
        #"{"type":"message_update","usage":\#(usage),"assistantMessageEvent":{"type":"toolcall_start","contentIndex":0,"id":"call_tool","toolName":"bash"}}"#,
        #"{"type":"message_update","usage":\#(usage),"assistantMessageEvent":{"type":"toolcall_end","contentIndex":0,"toolCall":\#(bashCall)}}"#,
        #"{"type":"message_end","message":\#(assistant(bashCalls, stop: "toolUse"))}"#,
        #"{"type":"tool_execution_start","toolCallId":"call_tool","toolName":"bash","args":{"command":"ls -1 | wc -l"}}"#,
        #"{"type":"tool_execution_update","toolCallId":"call_tool","toolName":"bash","args":{"command":"ls -1 | wc -l"},"partialResult":{"content":[{"type":"text","text":"3\n"}],"details":{}}}"#,
        #"{"type":"tool_execution_end","toolCallId":"call_tool","toolName":"bash","result":{"content":[{"type":"text","text":"3\n"}],"details":{}},"isError":false,"durationMs":14}"#,
        #"{"type":"message_end","message":{"role":"toolResult","toolCallId":"call_tool","toolName":"bash","content":[{"type":"text","text":"3\n"}],"isError":false,"timestamp":1794650401000}}"#,
        #"{"type":"turn_end","message":\#(assistant(bashCalls, stop: "toolUse")),"toolResults":[]}"#,
        #"{"type":"turn_start"}"#, #"{"type":"message_end","message":\#(assistant(calls, stop: "toolUse"))}"#,
        #"{"type":"tool_execution_start","toolCallId":"call_read","toolName":"read","args":{"path":"notes.txt"}}"#,
        #"{"type":"tool_execution_start","toolCallId":"call_edit","toolName":"edit","args":{"path":"notes.txt","edits":[{"oldText":"two files","newText":"three files"}]}}"#,
        #"{"type":"tool_execution_start","toolCallId":"call_write","toolName":"write","args":{"path":"count.txt","content":"3\n"}}"#,
        #"{"type":"tool_execution_start","toolCallId":"call_grep","toolName":"grep","args":{"pattern":"files"}}"#,
        #"{"type":"queue_update","steering":[],"followUp":[]}"#, #"{"type":"turn_start"}"#,
        #"{"type":"message_update","usage":\#(usage),"assistantMessageEvent":{"type":"text_delta","contentIndex":1,"delta":"There are 3 files."}}"#,
        #"{"type":"message_end","message":\#(assistant(final, stop: "stop"))}"#,
        #"{"type":"turn_end","message":\#(assistant(final, stop: "stop")),"toolResults":[]}"#,
        #"{"type":"agent_end","messages":[],"willRetry":false}"#, #"{"type":"agent_settled","aborted":false}"#,
    ]

    /// A task whose model request the door refused with `failure`.
    static func refused(_ failure: CloakDoor.Failure) throws -> [String] {
        [session, #"{"type":"agent_start"}"#, #"{"type":"turn_start"}"#, #"{"type":"message_end","message":\#(user)}"#]
            + [String(decoding: failed(try errorMessage(failure)), as: UTF8.self)]
            + [#"{"type":"agent_end","messages":[],"willRetry":false}"#, #"{"type":"agent_settled","aborted":false}"#]
    }

    /// The line of a failed request's message, with `error` as Pi words it.
    static func failed(_ error: String) -> Data {
        var message = try! JSONSerialization.jsonObject(with: Data(assistant("[]", stop: "error").utf8)) as! [String: Any]
        message["errorMessage"] = error
        return try! JSONSerialization.data(withJSONObject: ["type": "message_end", "message": message])
    }

    /// The door's refusal as Pi words it (`formatProviderError` in Pi's
    /// bundle): the status, then the OpenAI error the door answered with.
    static func errorMessage(_ failure: CloakDoor.Failure) throws -> String {
        let body = try #require(try JSONSerialization.jsonObject(with: failure.response.body) as? [String: Any])
        let error = try JSONSerialization.data(withJSONObject: try #require(body["error"]))
        return "\(failure.status): " + String(decoding: error, as: UTF8.self)
    }
}
