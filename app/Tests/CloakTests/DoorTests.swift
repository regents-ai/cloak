import CloakChat
import CloakHost
@testable import CloakDoor
@testable import CloakSupervisor
import CryptoKit
import Foundation
import Synchronization
import Testing

/// The door end to end on 127.0.0.1, with real requests from URLSession,
/// against stand-ins for the worker's rewording and for the guest's sender
/// (`SendTests.StandIn`): passes, web pages, every user message reworded
/// before anything is sent, earlier turns replayed only as reworded, each
/// stop, and closing with a request under way. Test-only keys and folders;
/// never the keychain, never the network beyond loopback.
@MainActor
@Suite(.serialized)
struct DoorTests {
    @Test func onlyAPassOfAnAppHereGetsIn() async throws {
        let stand = try await Stand()
        defer { stand.remove() }
        let pass = try #require(await stand.door.add("Agent"))
        let other = try #require(await stand.door.add("Other"))

        #expect(try await stand.ask(pass: nil).status == 401)
        #expect(try await stand.ask(pass: "cloak-" + String(repeating: "0", count: 64)).status == 401)
        #expect(try await stand.ask(pass: pass, headers: ["Authorization": "Basic " + pass]).status == 401)
        // A web page is refused, pass or not.
        let page = try await stand.ask(pass: pass, headers: ["Origin": "http://127.0.0.1:\(stand.door.port)"])
        #expect(page.status == 403)
        #expect(page.code == "browser_origin_denied")
        #expect(try await stand.ask(pass: pass, headers: ["Sec-Fetch-Site": "cross-site"]).status == 403)
        #expect(page.headers["Access-Control-Allow-Origin"] == nil)
        #expect(stand.reworder.asked.isEmpty && stand.sender.read.isEmpty)
        #expect(stand.door.apps.map(\.requests) == [0, 0])

        #expect(try await stand.ask(pass: pass).status == 200)
        let removed = try #require(stand.door.apps.first { $0.name == "Other" })
        #expect(try await stand.ask(pass: other).status == 200)
        stand.door.remove(removed.id)
        #expect(try await stand.ask(pass: other).status == 401)
        #expect(stand.door.apps.map(\.name) == ["Agent"])
        #expect(stand.door.apps[0].requests == 1)
        #expect(stand.door.apps[0].lastUsed != nil)

        // Sealed: neither the pass, its fingerprint nor the name is in the file.
        let sealed = try Data(contentsOf: stand.folder.appending(path: "agents"))
        for clear in [pass, Pass.fingerprint(pass).map { String(format: "%02x", $0) }.joined(), "Agent"] {
            #expect(sealed.range(of: Data(clear.utf8)) == nil)
        }
        #expect(sealed.range(of: Pass.fingerprint(pass)) == nil)
        #expect(try FileManager.default.attributesOfItem(atPath: stand.folder.appending(path: "agents").path)[.posixPermissions] as? Int == 0o600)
        // Read again, the apps are as they were.
        let port = stand.door.port
        let again = Door(file: stand.folder.appending(path: "agents"), wallet: stand.folder, parts: stand.parts, port: { port })
        await again.load()
        #expect(again.apps == stand.door.apps)
    }

    @Test func aChatIsRewordedOnThisMacThenSent() async throws {
        let stand = try await Stand()
        defer { stand.remove() }
        let pass = try #require(await stand.door.add("Agent"))
        let body = #"""
            {"model":"cheap","user":"someone","temperature":0.5,"stream_options":{"include_usage":true},
             "tools":[{"type":"function","function":{"name":"look","parameters":{"type":"object"}}}],
             "messages":[{"role":"system","content":"You are terse."},
                         {"role":"user","content":[{"type":"text","text":"um hi, what colour is calm?"},
                                                   {"type":"image_url","image_url":{"url":"data:image/png;base64,AAAA"}},
                                                   {"type":"text","text":"  "},{"type":"text","text":"and green?"}]}]}
            """#
        let answer = try await stand.ask(pass: pass, body: body)
        #expect(answer.status == 200)
        #expect(answer.body == Data(SendTests.said("Sage.").utf8))
        #expect(stand.reworder.asked == [["um hi, what colour is calm?", "and green?"]])

        let sent = try #require(stand.sent.first)
        #expect(!sent.contains("um hi") && !sent.contains("and green"))
        let object = try #require(JSONSerialization.jsonObject(with: Data(sent.utf8)) as? [String: Any])
        #expect(Set(object.keys) == ["model", "temperature", "tools", "messages", "stream"])
        #expect(object["stream"] as? Bool == false)
        let messages = try #require(object["messages"] as? [[String: Any]])
        #expect(messages[0] as? [String: String] == ["role": "system", "content": "You are terse."])
        let parts = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(parts[0]["text"] as? String == "UM HI, WHAT COLOUR IS CALM?")
        #expect((parts[1]["image_url"] as? [String: String])?["url"] == "data:image/png;base64,AAAA")
        #expect(parts[2]["text"] as? String == "  ")
        #expect(parts[3]["text"] as? String == "AND GREEN?")
        #expect(stand.door.apps[0].requests == 1)
    }

    /// The daemon's transcript, per app: earlier user turns are replayed as
    /// reworded, never sent as written; a history that is not the last one
    /// continued is reworded again, with a new Tor identity.
    @Test func earlierTurnsNeverLeaveAsWritten() async throws {
        let stand = try await Stand()
        defer { stand.remove() }
        let pass = try #require(await stand.door.add("Agent"))
        let other = try #require(await stand.door.add("Other"))
        let system = #"{"role":"system","content":"Be brief."}"#
        let first = #"{"role":"user","content":"first question"}"#
        let edited = #"{"role":"user","content":"first question, edited"}"#
        let answered = #"{"role":"assistant","content":"Sage."}"#
        let second = #"{"role":"user","content":"second question"}"#
        let calls = #"{"role":"assistant","content":null,"tool_calls":[{"id":"1","type":"function","function":{"name":"look","arguments":"{}"}}]}"#
        let result = #"{"role":"tool","tool_call_id":"1","content":"Sunny."}"#
        func chat(_ messages: String...) -> String { #"{"model":"cheap","messages":["# + messages.joined(separator: ",") + "]}" }

        let steps: [(pass: String, body: String, asked: [[String]], sameIdentity: Bool)] = [
            (pass, chat(system, first), [["first question"]], false),
            (pass, chat(system, first, answered, second), [["second question"]], true),
            (pass, chat(system, first, answered, second, calls, result), [], true),
            (pass, chat(system, edited, answered, second), [["first question, edited"], ["second question"]], false),
            (other, chat(system, first, answered, second), [["first question"], ["second question"]], false),
        ]
        var identities = [String]()
        for (index, step) in steps.enumerated() {
            let before = stand.reworder.asked.count
            #expect(try await stand.ask(pass: step.pass, body: step.body).status == 200)
            #expect(Array(stand.reworder.asked[before...]) == step.asked, "step \(index)")
            let sent = try #require(stand.sent.last)
            for original in ["first question", "second question"] {
                #expect(!sent.contains(original), "step \(index)")
            }
            let identity = try #require(stand.sender.read.last?["identity"] as? String)
            if step.sameIdentity { #expect(identity == identities.last) } else { #expect(!identities.contains(identity)) }
            identities.append(identity)
        }
        let replayed = try #require(JSONSerialization.jsonObject(with: Data(stand.sent[2].utf8)) as? [String: Any])
        let messages = try #require(replayed["messages"] as? [[String: Any]])
        #expect(messages.map { $0["content"] as? String } == ["Be brief.", "FIRST QUESTION", "Sage.", "SECOND QUESTION", nil, "Sunny."])
    }

    /// The door's transcript against the pinned daemon's own
    /// (tests/daemon_transcript/main.go): the same requests take the same
    /// rewrites, in the same order, and give the same messages to send.
    @Test func theTranscriptIsTheDaemons() async throws {
        func chat(_ messages: String...) -> String { #"{"model":"cheap","messages":["# + messages.joined(separator: ",") + "]}" }
        let system = #"{"role":"system","content":"Be brief."}"#
        let hi = #"{"role":"user","content":"Say hi to the team."}"#
        let hiAgain = #"{ "content" : "Say hi to the team." , "role":"user","name":null,"content":"Say hi to the team." }"#
        let answered = #"{"role":"assistant","content":"Hi team."}"#
        let french = #"{"role":"user","content":"Now in French, é included."}"#
        let calls = #"{"role":"assistant","content":null,"tool_calls":[{"id":"1","type":"function","function":{"name":"look","arguments":"{\"q\":1}"}}]}"#
        let result = #"{"role":"tool","tool_call_id":"1","content":"Sunny, 21C."}"#
        let parts = #"{"role":"user","content":[{"type":"text","text":"Look at this."},{"type":"image_url","image_url":{"url":"data:image/png;base64,AAAA"}},{"type":"text","text":"  "},{"type":"input_audio","input_audio":{"data":"AAAA","format":"wav"}},{"type":"text","text":"And this."}]}"#
        let imageOnly = #"{"role":"user","content":[{"type":"image_url","image_url":{"url":"data:image/png;base64,AAAA"}}]}"#
        let empty = #"{"role":"user","content":null}"#
        let blank = #"{"role":"user","content":" \n\t"}"#
        let developer = #"{"role":"developer","content":"Use tools."}"#
        let conversations: [[String]] = [
            [chat(system, hi), chat(system, hi, answered, french), chat(system, hi, answered, french, calls, result),
             chat(system, hiAgain, answered, french, calls, result, #"{"role":"user","content":"Thanks."}"#)],
            [chat(hi), chat(french, answered, hi), chat(french, answered, hi, answered, french)],
            [chat(parts), chat(parts, answered, empty), chat(blank), chat(imageOnly, answered, developer, hi)],
            [chat(#"{"role":"user","content":[{"type":"video","video":"x"}]}"#), chat(#"{"role":"user"}"#),
             chat(#"{"role":"user","content":5}"#), chat(hi), chat(hi, answered, hi)],
        ]
        let input = conversations.map { "[" + $0.joined(separator: ",") + "]" }.joined(separator: "\n") + "\n"
        let output = try Repository.tool("daemon_transcript", input: Data(input.utf8))
        let lines = output.split(separator: UInt8(ascii: "\n")).map { [UInt8]($0) }
        #expect(lines.count == conversations.count)
        var compared = 0
        for (conversation, line) in zip(conversations, lines) {
            guard case .array(let theirs) = try GoJSON.read(line).value else {
                Issue.record("the daemon's answer did not read")
                continue
            }
            var memory = Memory()
            for (body, their) in zip(conversation, theirs) {
                let fields = try #require(their.members)
                let reworder = Reworder()
                var ours: [[UInt8]]?
                do {
                    let asked = try await Asked.read(Array(body.utf8))
                    let (messages, transcript) = try await memory.rewrite(asked) { texts throws(RewriteStop) in try await reworder.reword(texts) }
                    memory.transcript = transcript
                    ours = messages
                } catch {
                    ours = nil
                }
                let ok = Asked.text(try #require(fields["ok"]), in: line) == "true"
                #expect((ours != nil) == ok, "\(body)")
                let asked = try #require(fields["asked"]).array { call throws(GoJSON.Mismatch) in
                    try call.array { text throws(GoJSON.Mismatch) in try text.string() ?? "" }
                }
                #expect(reworder.asked == asked, "\(body)")
                if let ours, case .array(let messages)? = fields["messages"]?.value {
                    #expect(ours.map { try! GoJSON.read($0).canonical(in: $0) } == messages.map { $0.canonical(in: line) }, "\(body)")
                    compared += 1
                }
            }
        }
        #expect(compared == 13)
    }

    @Test(arguments: StopCase.all)
    func eachStopIsPlainAndSendsNothingItShouldNot(_ stop: StopCase) async throws {
        let stand = try await Stand(reword: stop.reword, wallet: stop.wallet, sender: stop.sender)
        defer { stand.remove() }
        let pass = try #require(await stand.door.add("Agent"))
        let answer = try await stand.ask(stop.method, stop.path, pass: pass, body: stop.body, headers: stop.headers)
        #expect(answer.status == stop.status, "\(stop.name)")
        #expect(answer.code == stop.code, "\(stop.name)")
        #expect(stand.reworder.asked.count == stop.reworded, "\(stop.name)")
        #expect(stand.sent.count == stop.sent, "\(stop.name)")
    }

    @Test func modelsAreTheProvidersListAsItGivesIt() async throws {
        let stand = try await Stand()
        defer { stand.remove() }
        let pass = try #require(await stand.door.add("Agent"))
        let answer = try await stand.ask("GET", "/v1/models", pass: pass)
        #expect(answer.status == 200)
        #expect(answer.body == Data(Stand.models.utf8))
    }

    /// The send path does not stream: one chunk, then [DONE].
    @Test func aStreamIsOneChunk() async throws {
        let stand = try await Stand()
        defer { stand.remove() }
        let pass = try #require(await stand.door.add("Agent"))
        let answer = try await stand.ask(pass: pass, body: #"{"model":"cheap","stream":true,"messages":[{"role":"user","content":"hi"}]}"#)
        #expect(answer.status == 200)
        #expect(answer.headers["Content-Type"] == "text/event-stream")
        let text = String(decoding: answer.body, as: UTF8.self)
        #expect(text.hasPrefix("data: {") && text.hasSuffix("}\n\ndata: [DONE]\n\n"))
        let chunk = try #require(JSONSerialization.jsonObject(with: Data(text.dropFirst(6).prefix { $0 != "\n" }.utf8)) as? [String: Any])
        #expect(chunk["object"] as? String == "chat.completion.chunk")
        let choice = try #require((chunk["choices"] as? [[String: Any]])?.first)
        #expect((choice["delta"] as? [String: String])?["content"] == "Sage.")
        let body = try #require(stand.sent.first)
        let sent = try #require(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        #expect(sent["stream"] as? Bool == false)
        #expect(sent["stream_options"] == nil)
    }

    /// Pause, Stop and Quit close the door: a request waiting on its
    /// rewording gets a plain error, nothing is sent, and nothing more
    /// connects.
    @Test func closingAnswersARequestUnderWay() async throws {
        let stand = try await Stand(reword: .hold)
        defer { stand.remove() }
        let pass = try #require(await stand.door.add("Agent"))
        let waiting = Task { try await stand.ask(pass: pass) }
        for _ in 0..<100 where stand.reworder.asked.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(stand.reworder.asked.count == 1)
        await stand.door.close()
        let answer = try await waiting.value
        #expect(answer.status == 503)
        #expect(answer.code == "cloak_stopped")
        #expect(stand.sent.isEmpty)
        #expect(stand.door.state == .closed)
        await #expect(throws: (any Error).self) { try await stand.ask(pass: pass) }
    }

    /// A port another app holds, on 127.0.0.1 or on every address, keeps the
    /// door closed, in plain words.
    @Test(arguments: [INADDR_LOOPBACK, INADDR_ANY])
    func aTakenPortIsRefused(_ address: in_addr_t) async throws {
        let port = try Stand.freePort()
        let holder = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(holder) }
        var bound = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET),
                                sin_port: port.bigEndian, sin_addr: in_addr(s_addr: address.bigEndian), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        let held = withUnsafePointer(to: &bound) { address in
            address.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(holder, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        #expect(held == 0 && listen(holder, 1) == 0)
        let stand = try await Stand(port: port, waitOpen: false)
        defer { stand.remove() }
        for _ in 0..<100 where stand.door.state == .closed {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard case .refused = stand.door.state else {
            Issue.record("the door is \(stand.door.state)")
            return
        }
    }
}

/// A rewording stand-in: each text in upper case, or held until cancelled,
/// or stopped.
final class Reworder: Sendable {
    enum Mode: Sendable {
        case upper
        case hold
        case stop(RewriteStop)
    }

    let mode: Mode
    private let calls = Mutex<[[String]]>([])

    init(_ mode: Mode = .upper) {
        self.mode = mode
    }

    var asked: [[String]] { calls.withLock { $0 } }

    func reword(_ texts: [String]) async throws(RewriteStop) -> [String] {
        calls.withLock { $0.append(texts) }
        switch mode {
        case .upper:
            return texts.map { $0.uppercased() }
        case .hold:
            try? await Task.sleep(for: .seconds(60))
            throw .cancelled
        case .stop(let stop):
            throw stop
        }
    }
}

/// A door on a free port of 127.0.0.1, with its stand-ins and a folder of
/// its own.
@MainActor
struct Stand {
    let folder = URL(filePath: "/tmp").appending(path: "cloak-door-\(UUID().uuidString.prefix(8))")
    let key = SymmetricKey(size: .bits256)
    let reworder: Reworder
    let sender: SendTests.StandIn
    let parts: Door.Parts
    let door: Door

    nonisolated static let models = #"{"object":"list","data":[{"id":"cheap","object":"model"},{"id":"other","object":"model"}]}"#

    /// The sender's answers: the models listed, and a completion for a send.
    nonisolated static func answer(_ request: [String: Any]) -> Data? {
        switch request["op"] as? String {
        case "models": try! JSONSerialization.data(withJSONObject: ["ok": ["models": models]])
        case "send": SendTests.completed(SendTests.said("Sage."))
        default: nil
        }
    }

    init(
        reword: Reworder.Mode = .upper, wallet: String? = "0xabc",
        sender: @escaping @Sendable ([String: Any]) -> Data? = Stand.answer, port: UInt16? = nil, waitOpen: Bool = true
    ) async throws {
        let reworder = Reworder(reword)
        let key = self.key
        self.reworder = reworder
        self.sender = SendTests.StandIn(answer: sender)
        parts = Door.Parts(
            reword: { texts throws(RewriteStop) in try await reworder.reword(texts) }, exchange: self.sender.exchange,
            wallet: { wallet }, key: { Data(repeating: 0x11, count: 32) }, sealing: { key })
        let port = try port ?? Self.freePort()
        door = Door(file: folder.appending(path: "agents"), wallet: folder.appending(path: "wallet"), parts: parts, port: { port })
        await door.open()
        guard waitOpen else { return }
        for _ in 0..<100 where door.state != .open {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(door.state == .open)
    }

    /// The bodies sent to the provider.
    var sent: [String] {
        sender.read.filter { $0["op"] as? String == "send" }.compactMap { $0["body"] as? String }
    }

    func remove() {
        let door = door
        Task { await door.close() }
        try? FileManager.default.removeItem(at: folder)
    }

    struct Answer {
        let status: Int
        let headers: [String: String]
        let body: Data

        /// The OpenAI error's code.
        var code: String? {
            ((try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["error"] as? [String: Any])?["code"] as? String
        }
    }

    func ask(
        _ method: String = "POST", _ path: String = "/v1/chat/completions", pass: String?,
        body: String? = #"{"model":"cheap","messages":[{"role":"user","content":"hello there"}]}"#, headers: [String: String] = [:]
    ) async throws -> Answer {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(door.port)\(path)")!)
        request.httpMethod = method
        if method == "POST" {
            request.httpBody = body.map { Data($0.utf8) }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let pass { request.setValue("Bearer " + pass, forHTTPHeaderField: "Authorization") }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        return Answer(
            status: http.statusCode,
            headers: Dictionary(uniqueKeysWithValues: http.allHeaderFields.map { ("\($0.key)", "\($0.value)") }), body: data)
    }

    /// A port of 127.0.0.1 free a moment ago.
    static func freePort() throws -> UInt16 {
        let probe = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(probe) }
        var address = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET), sin_port: 0,
                                  sin_addr: in_addr(s_addr: INADDR_LOOPBACK.bigEndian), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let found = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(probe, $0, length) == 0 && getsockname(probe, $0, &length) == 0 }
        }
        guard found else { throw POSIXError(.EADDRNOTAVAIL) }
        return UInt16(bigEndian: address.sin_port)
    }
}

/// One way a chat request stops, with what may have happened by then.
struct StopCase: Sendable, CustomTestStringConvertible {
    let name: String
    var method = "POST"
    var path = "/v1/chat/completions"
    var body = #"{"model":"cheap","messages":[{"role":"user","content":"hello there"}]}"#
    var headers: [String: String] = [:]
    var reword = Reworder.Mode.upper
    var wallet: String? = "0xabc"
    var sender: @Sendable ([String: Any]) -> Data? = Stand.answer
    let status: Int
    let code: String
    /// Rewordings asked for, and bodies sent to the provider.
    var reworded = 0
    var sent = 0

    var testDescription: String { name }

    static func chat(_ message: String, _ more: String = "") -> String {
        #"{"model":"cheap","messages":["# + message + "]" + more + "}"
    }

    /// The sender stops `op` with `code`, and answers every other.
    static func stops(_ op: String, _ code: String) -> @Sendable ([String: Any]) -> Data? {
        { request in
            request["op"] as? String == op ? Data(#"{"stop":{"code":"\#(code)","detail":"made up"}}"#.utf8) : Stand.answer(request)
        }
    }

    static let all: [StopCase] = [
        StopCase(name: "rewording refused", reword: .stop(.refused), status: 502, code: "rewrite_failed", reworded: 1),
        StopCase(name: "rewording past its deadline", reword: .stop(.timedOut), status: 504, code: "rewrite_timed_out", reworded: 1),
        StopCase(name: "the worker stopped", reword: .stop(.stopped), status: 503, code: "cloak_stopped", reworded: 1),
        StopCase(
            name: "over the cap", body: chat(#"{"role":"user","content":"\#(String(repeating: "é", count: 10_001))"}"#),
            status: 413, code: "input_too_long"),
        StopCase(name: "a model not in the list", body: #"{"model":"nope","messages":[{"role":"user","content":"hi"}]}"#, status: 404, code: "model_not_found"),
        StopCase(name: "no wallet", wallet: nil, status: 402, code: "no_wallet", reworded: 1),
        StopCase(name: "no funds", sender: stops("send", "no_funds"), status: 402, code: "insufficient_funds", reworded: 1, sent: 1),
        StopCase(name: "Tor down", sender: stops("send", "tor_down"), status: 503, code: "tor_down", reworded: 1, sent: 1),
        StopCase(
            name: "the sender goes away", sender: { request in request["op"] as? String == "send" ? nil : Stand.answer(request) },
            status: 503, code: "cloak_stopped", reworded: 1, sent: 1),
        StopCase(name: "no list of models", sender: stops("models", "tor_down"), status: 503, code: "tor_down"),
        StopCase(name: "several answers", body: chat(#"{"role":"user","content":"hi"}"#, #","n":2"#), status: 400, code: "invalid_request_error"),
        StopCase(name: "stored", body: chat(#"{"role":"user","content":"hi"}"#, #","store":true"#), status: 400, code: "invalid_request_error"),
        StopCase(
            name: "an image by link",
            body: chat(#"{"role":"user","content":[{"type":"text","text":"hi"},{"type":"image_url","image_url":{"url":"https://example.com/a.png"}}]}"#),
            status: 400, code: "invalid_request_error"),
        StopCase(
            name: "a stored file", body: chat(#"{"role":"user","content":[{"type":"file","file":{"file_id":"file-1"}}]}"#),
            status: 400, code: "invalid_request_error"),
        StopCase(name: "a role the provider lacks", body: chat(#"{"role":"User","content":"hi"}"#), status: 400, code: "invalid_request_error"),
        StopCase(name: "a part that can't be reworded", body: chat(#"{"role":"user","content":[{"type":"input_text","text":"hi"}]}"#), status: 400, code: "invalid_request_error"),
        StopCase(name: "not JSON", body: "hello", status: 400, code: "invalid_request_error"),
        StopCase(name: "not said to be JSON", headers: ["Content-Type": "text/plain"], status: 415, code: "unsupported_media_type"),
        StopCase(name: "another method", method: "GET", status: 405, code: "method_not_allowed"),
        StopCase(name: "another path", path: "/v1/embeddings", status: 404, code: "not_found"),
    ]
}
