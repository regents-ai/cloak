@testable import CloakDoor
import Foundation
import Testing

/// The door as the agent in the guest meets it: connections from the guest's
/// door port, each a socket the door takes, read and answered as any app's
/// are. Box passes work there only, and app passes only on 127.0.0.1; each
/// conversation has its own pass and memory until the door closes; and the
/// door's answers are those the task path's stand-in door replays
/// (tests/door_answers.json). Test-only keys and folders, as in DoorTests.
@MainActor
@Suite(.serialized)
struct DoorGuestTests {
    static let unknown = "cloak-" + String(repeating: "0", count: 64)

    @Test func aBoxPassGetsInFromTheGuestOnly() async throws {
        let stand = try await Stand()
        defer { stand.remove() }
        let conversation = UUID()
        let box = try #require(stand.door.pass(for: conversation))
        #expect(stand.door.pass(for: conversation) == box)
        let other = try #require(stand.door.pass(for: UUID()))
        #expect(other != box)

        // With no app added there is no file of apps, and the agent's request goes on.
        let answer = try #require(await stand.askFromTheGuest(pass: box))
        #expect(answer.status == 200)
        #expect(answer.body == Data(SendTests.said("Sage.").utf8))
        #expect(stand.reworder.asked == [["hello there"]])
        #expect(!FileManager.default.fileExists(atPath: stand.folder.appending(path: "agents").path))

        let app = try #require(await stand.door.add("Agent"))
        #expect(stand.door.apps.map(\.name) == ["Agent"])
        for refused in [nil, Self.unknown, app] {
            #expect(try await stand.askFromTheGuest(pass: refused)?.status == 401, "\(String(describing: refused?.prefix(8)))")
        }
        #expect(try await stand.askFromTheGuest(pass: box, headers: [("Origin", "http://127.0.0.1:8742")])?.status == 403)
        #expect(try await stand.ask(pass: box).status == 401)
        #expect(try await stand.ask(pass: app).status == 200)
        #expect(try await stand.askFromTheGuest(pass: other)?.status == 200)
        // The agent's requests are not an app's.
        #expect(stand.door.apps[0].requests == 1)
        #expect(stand.sent.count == 3)
    }

    /// Each conversation's earlier turns are its own, as each app's are, and
    /// go with its pass when the door closes.
    @Test func eachConversationHasItsOwnPassAndMemoryUntilTheDoorCloses() async throws {
        let stand = try await Stand()
        defer { stand.remove() }
        func chat(_ messages: String...) -> String { #"{"model":"cheap","messages":["# + messages.joined(separator: ",") + "]}" }
        let system = #"{"role":"system","content":"Be brief."}"#
        let first = #"{"role":"user","content":"first question"}"#
        let answered = #"{"role":"assistant","content":"Sage."}"#
        let second = #"{"role":"user","content":"second question"}"#
        let a = UUID(), b = UUID()
        let passA = try #require(stand.door.pass(for: a)), passB = try #require(stand.door.pass(for: b))

        let steps: [(pass: String, body: String, asked: [[String]])] = [
            (passA, chat(system, first), [["first question"]]),
            (passA, chat(system, first, answered, second), [["second question"]]),
            (passB, chat(system, first, answered, second), [["first question"], ["second question"]]),
        ]
        for (index, step) in steps.enumerated() {
            let before = stand.reworder.asked.count
            #expect(try await stand.askFromTheGuest(pass: step.pass, body: step.body)?.status == 200, "step \(index)")
            #expect(Array(stand.reworder.asked[before...]) == step.asked, "step \(index)")
        }

        await stand.door.close()
        #expect(stand.door.pass(for: a) == nil)
        // A connection from the guest while the door is closed is closed, unanswered.
        #expect(try await stand.askFromTheGuest(pass: passA) == nil)

        await stand.door.open()
        for _ in 0..<100 where stand.door.state != .open {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try await stand.askFromTheGuest(pass: passA)?.status == 401)
        let again = try #require(stand.door.pass(for: a))
        #expect(again != passA)
        let before = stand.reworder.asked.count
        #expect(try await stand.askFromTheGuest(pass: again, body: chat(system, first, answered, second))?.status == 200)
        #expect(Array(stand.reworder.asked[before...]) == [["first question"], ["second question"]])
    }

    /// What the agent's card shows as the task reworded: nothing before a
    /// request has gone through; the task once one has, and still once its
    /// tool's result has; the next task once its request has, its texts on
    /// lines of their own; another conversation's nothing; and nothing once
    /// the door closes.
    @Test func eachConversationsTaskIsTheOneLastReworded() async throws {
        let stand = try await Stand()
        defer { stand.remove() }
        func chat(_ messages: String...) -> String { #"{"model":"cheap","messages":["# + messages.joined(separator: ",") + "]}" }
        let system = #"{"role":"system","content":"Be brief."}"#
        let first = #"{"role":"user","content":[{"type":"text","text":"Count the files."}]}"#
        let call = #"{"role":"assistant","content":null,"tool_calls":[{"id":"call_tool","type":"function","function":{"name":"bash","arguments":"{\"command\":\"ls\"}"}}]}"#
        let result = #"{"role":"tool","tool_call_id":"call_tool","content":"3"}"#
        let answered = #"{"role":"assistant","content":"There are 3."}"#
        let next = #"{"role":"user","content":[{"type":"text","text":"Now the folders."},{"type":"text","text":" "},{"type":"text","text":"Then stop."}]}"#
        let a = UUID(), b = UUID()
        let pass = try #require(stand.door.pass(for: a))
        _ = try #require(stand.door.pass(for: b))
        #expect(stand.door.reworded(for: a) == nil)

        let steps: [(body: String, reworded: String)] = [
            (chat(system, first), "COUNT THE FILES."),
            (chat(system, first, call, result), "COUNT THE FILES."),
            (chat(system, first, call, result, answered, next), "NOW THE FOLDERS.\nTHEN STOP."),
        ]
        for (index, step) in steps.enumerated() {
            #expect(try await stand.askFromTheGuest(pass: pass, body: step.body)?.status == 200, "step \(index)")
            #expect(stand.door.reworded(for: a) == step.reworded, "step \(index)")
            #expect(stand.door.reworded(for: b) == nil, "step \(index)")
        }

        await stand.door.close()
        #expect(stand.door.reworded(for: a) == nil)
    }

    @Test func aGuestConnectionThatEndsBeforeAWholeRequestIsNotAnswered() async throws {
        let stand = try await Stand()
        defer { stand.remove() }
        let box = try #require(stand.door.pass(for: UUID()))
        let head = "POST /v1/chat/completions HTTP/1.1\r\nAuthorization: Bearer \(box)\r\nContent-Type: application/json\r\n"
        for cut in [head, head + "Content-Length: 40\r\n\r\n{\"model\":"] {
            #expect(await stand.fromTheGuest(Data(cut.utf8), endingWrites: true).isEmpty)
        }

        // A whole request on a connection the guest closed before the door
        // took it: no one is there to answer, and nothing is sent.
        let body = #"{"model":"cheap","messages":[{"role":"user","content":"hello there"}]}"#
        let whole = Data((head + "Content-Length: \(body.utf8.count)\r\n\r\n" + body).utf8)
        var pair: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        #expect(whole.withUnsafeBytes { write(pair[0], $0.baseAddress!, whole.count) } == whole.count)
        close(pair[0])
        stand.door.accept(guest: pair[1])
        try await Task.sleep(for: .milliseconds(200))
        #expect(stand.reworder.asked.isEmpty && stand.sender.read.isEmpty)
    }

    /// The door's answer to each completion the task path's stand-in door
    /// replays is the one it replays, byte for byte but for the order of the
    /// keys in its one event.
    @Test func theDoorsAnswersAreTheOnesTheTaskPathReplays() async throws {
        let fixture = try Self.fixture()
        let model = try #require(fixture["model"] as? String)
        let answers = try #require(fixture["answers"] as? [String: [String: Any]])
        #expect(Set(answers.keys) == ["tool", "final", "hold"])
        for (name, answer) in answers {
            let completion = try JSONSerialization.data(withJSONObject: try #require(answer["completion"]))
            let models = #"{"object":"list","data":[{"id":"\#(model)","object":"model"}]}"#
            let stand = try await Stand(sender: { request in
                switch request["op"] as? String {
                case "models": try! JSONSerialization.data(withJSONObject: ["ok": ["models": models]])
                case "send": SendTests.completed(String(decoding: completion, as: UTF8.self))
                default: nil
                }
            })
            defer { stand.remove() }
            let box = try #require(stand.door.pass(for: UUID()))
            let body = #"{"model":"\#(model)","stream":true,"messages":[{"role":"user","content":"Run the checks."}]}"#
            let raw = try #require(await stand.askFromTheGuest(pass: box, body: body)).raw
            try Self.same(raw, Data(try #require(answer["response"] as? String).utf8), name)
        }
    }

    /// Pi's two requests in the task path, as it sent them, headers and all:
    /// the task, then its tool's result. The door takes each as it is, with
    /// nothing in Pi's settings changed: each user message is reworded, the
    /// tool's result is not, and what goes to the provider has the fields
    /// the door keeps.
    @Test func theDoorTakesPisRequestsAsPiSendsThem() async throws {
        let fixture = try Self.fixture()
        let model = try #require(fixture["model"] as? String)
        let requests = try #require(fixture["requests"] as? [String: Any])
        let headers = try #require(requests["headers"] as? [[String]]).map { ($0[0], $0[1]) }
        let completion = try JSONSerialization.data(withJSONObject: try #require((fixture["answers"] as? [String: [String: Any]])?["final"]?["completion"]))
        let models = #"{"object":"list","data":[{"id":"\#(model)","object":"model"}]}"#
        let stand = try await Stand(sender: { request in
            switch request["op"] as? String {
            case "models": try! JSONSerialization.data(withJSONObject: ["ok": ["models": models]])
            case "send": SendTests.completed(String(decoding: completion, as: UTF8.self))
            default: nil
            }
        })
        defer { stand.remove() }
        let box = try #require(stand.door.pass(for: UUID()))
        for name in ["first", "second"] {
            let body = try #require(requests[name] as? String)
            let answer = try #require(await stand.askFromTheGuest(pass: box, body: body, headers: headers))
            #expect(answer.status == 200, "\(name)")
            #expect(answer.raw.range(of: Data("Content-Type: text/event-stream\r\n".utf8)) != nil, "\(name)")
        }
        // The task's text was reworded once, for the first request; the second replays it as reworded.
        #expect(stand.reworder.asked == [["Run the checks, then say they ran."]])
        #expect(stand.sent.count == 2)
        for sent in stand.sent {
            let object = try #require(try JSONSerialization.jsonObject(with: Data(sent.utf8)) as? [String: Any])
            #expect(Set(object.keys) == ["model", "messages", "stream", "max_completion_tokens", "tools"])
            #expect(object["stream"] as? Bool == false)
            #expect(!sent.contains("Run the checks, then say they ran."))
        }
        let second = try #require(try JSONSerialization.jsonObject(with: Data(stand.sent[1].utf8)) as? [String: Any])
        let roles = try #require(second["messages"] as? [[String: Any]]).map { $0["role"] as? String }
        #expect(roles == ["system", "user", "assistant", "tool"])
    }

    static func fixture() throws -> [String: Any] {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: root.appending(path: "tests/door_answers.json"))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The same head, each with its own body's length, and the same one
    /// event then the end.
    static func same(_ raw: Data, _ replayed: Data, _ name: String) throws {
        func split(_ data: Data) throws -> (lines: [String], body: Data) {
            let end = try #require(data.firstRange(of: Data("\r\n\r\n".utf8)))
            return (String(decoding: data[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n"), data[end.upperBound...])
        }
        let (lines, body) = try split(raw), (replayedLines, replayedBody) = try split(replayed)
        #expect(lines.contains("Content-Length: \(body.count)"), "\(name)")
        #expect(replayedLines.contains("Content-Length: \(replayedBody.count)"), "\(name)")
        #expect(lines.filter { !$0.hasPrefix("Content-Length:") } == replayedLines.filter { !$0.hasPrefix("Content-Length:") }, "\(name)")
        let start = Data("data: ".utf8), end = Data("\n\ndata: [DONE]\n\n".utf8)
        var events = [NSDictionary]()
        for body in [body, replayedBody] {
            #expect(body.starts(with: start) && body.suffix(end.count) == end, "\(name)")
            events.append(try #require(try JSONSerialization.jsonObject(with: body.dropFirst(start.count).dropLast(end.count)) as? NSDictionary))
        }
        #expect(events[0] == events[1], "\(name)")
    }
}

extension Stand {
    struct GuestAnswer {
        let status: Int
        let raw: Data
        let body: Data
    }

    /// Asks as the agent in the guest does, on a connection from the guest's
    /// door port. Returns the answer, or nil when the door closed the
    /// connection without one.
    func askFromTheGuest(
        pass: String?, body: String = #"{"model":"cheap","messages":[{"role":"user","content":"hello there"}]}"#,
        headers: [(String, String)] = []
    ) async throws -> GuestAnswer? {
        var head = "POST /v1/chat/completions HTTP/1.1\r\nHost: 127.0.0.1:8742\r\n"
        if let pass { head += "Authorization: Bearer \(pass)\r\n" }
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "Content-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n"
        let raw = await fromTheGuest(Data((head + body).utf8))
        guard let end = raw.firstRange(of: Data("\r\n\r\n".utf8)) else { return nil }
        let line = String(decoding: raw[..<end.lowerBound], as: UTF8.self).prefix { $0 != "\r" }
        let status = try #require(Int(line.split(separator: " ")[1]))
        return GuestAnswer(status: status, raw: raw, body: raw[end.upperBound...])
    }

    /// Writes `request` on a new connection from the guest's door port, then
    /// reads until the door closes it; with `endingWrites`, ends the writing
    /// side after the request, as a guest that sends nothing more does.
    func fromTheGuest(_ request: Data, endingWrites: Bool = false) async -> Data {
        var pair: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { return Data() }
        let client = pair[0]
        // Before the door can close its end, after which the socket takes no option.
        var on: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        door.accept(guest: pair[1])
        return await withCheckedContinuation { continuation in
            Thread {
                defer { close(client) }
                var done = 0
                while done < request.count {
                    let n = request.withUnsafeBytes { write(client, $0.baseAddress! + done, request.count - done) }
                    guard n > 0 else { break }
                    done += n
                }
                if endingWrites { shutdown(client, SHUT_WR) }
                var answer = Data()
                var buffer = [UInt8](repeating: 0, count: 1 << 16)
                while true {
                    let n = read(client, &buffer, buffer.count)
                    guard n > 0 else { break }
                    answer += buffer.prefix(n)
                }
                continuation.resume(returning: answer)
            }.start()
        }
    }
}
