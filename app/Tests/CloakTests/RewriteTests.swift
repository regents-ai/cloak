import CloakHost
@testable import CloakSupervisor
import CryptoKit
import Foundation
import Testing

/// The app's rewrite against the pinned daemon's own code: the daemon's
/// reply check (tests/daemon_reply/main.go), built inside the pinned daemon
/// module, captures the request the daemon sends for each text and judges
/// each reply, and the app must send the same bytes and reach the same
/// verdict, with the same texts.
@Suite
struct DaemonEqualityTests {
    @Test func theSystemMessageIsThePinnedOne() {
        let digest = SHA256.hash(data: Data(Rewrite.system.utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(digest == "c95de591e464e6215df0544b7ef03486326ba45f095ea055d2f86e6daf91724b")
    }

    @Test func theRequestIsTheDaemonsByteForByte() throws {
        let texts = [
            "Say hello to the team.",
            "Hola, ¿puedes revisar /Users/ana/Documents/informe-2026.pdf? Necesito 3 copias antes del viernes.",
            #"<script>alert('x') & "quotes" \ backslash / slash</script>"#,
            "line one\nline two\r\nline three\ttabbed",
            "bell \u{07} backspace \u{08} form feed \u{0C} unit \u{1F} delete \u{7F} nul \u{00} end",
            "separators \u{2028} and \u{2029} and \u{85} next line",
            "emoji 👩‍👩‍👧 and 𝔘𝔫𝔦𝔠𝔬𝔡𝔢 and e\u{301} combined",
            String(repeating: "é", count: 10_000),
        ]
        let verdicts = try DaemonReply.judge(texts.map { ([$0], Array(Reply.ok(["Fine."]).utf8)) })
        for (text, verdict) in zip(texts, verdicts) {
            #expect(verdict.request == Rewrite.request(model: "worker", text: text), "\(text.prefix(40))")
        }
    }

    /// Replies to one text, each judged by the daemon and by the app.
    @Test func everyReplyIsJudgedAsTheDaemonJudgesIt() throws {
        let content = #"{"texts":["Greet the team."]}"#
        let cases: [String] = [
            Reply.ok(["Greet the team."]),
            // Keys match as Go folds them, escaped or not.
            #"{"Choices":[{"FINISH_REASON":"stop","Message":{"Content":\#(Rewrite.quote(content))}}]}"#,
            #"{"choice\#u{17F}":[{"finish_reason":"stop","message":{"content":\#(Rewrite.quote(content))}}]}"#,
            #"{"choices":[{"finish_reason":"stop","message":{"content":\#(Rewrite.quote(content))}}]}"#,
            Reply.message(content: Rewrite.quote(#"{"TEXT\#u{17F}":["Greet the team."]}"#)),
            // tool_calls by its exact bytes.
            Reply.message(content: Rewrite.quote(content), more: #","tool_calls":null"#),
            Reply.message(content: Rewrite.quote(content), more: #","tool_calls" : []"#),
            Reply.message(content: Rewrite.quote(content), more: #","tool_calls":[ ]"#),
            Reply.message(content: Rewrite.quote(content), more: #","tool_calls":[{"id":"1"}]"#),
            Reply.message(content: Rewrite.quote(content), more: #","tool_calls":{}"#),
            Reply.message(content: Rewrite.quote(content), more: #","tool_calls":"""#),
            // A refusal only when it says something.
            Reply.message(content: Rewrite.quote(content), more: #","refusal":null"#),
            Reply.message(content: Rewrite.quote(content), more: #","refusal":"""#),
            Reply.message(content: Rewrite.quote(content), more: #","refusal":"no""#),
            // The content: one value, with only whitespace around it.
            Reply.message(content: Rewrite.quote(" \n\t" + content + "\r\n ")),
            Reply.message(content: Rewrite.quote(content + " {}")),
            Reply.message(content: Rewrite.quote(content + "x")),
            Reply.message(content: Rewrite.quote(#"{"texts":["Greet the team."],"note":"x"}"#)),
            Reply.message(content: "null"),
            Reply.message(content: "5"),
            Reply.message(content: Rewrite.quote("null")),
            Reply.message(content: Rewrite.quote(#"{"texts":null}"#)),
            Reply.message(content: Rewrite.quote(#"{"texts":[]}"#)),
            Reply.message(content: Rewrite.quote(#"{"texts":["a","b"]}"#)),
            Reply.message(content: Rewrite.quote(#"{"texts":"a"}"#)),
            Reply.message(content: Rewrite.quote(#"{"texts":[1]}"#)),
            Reply.message(content: Rewrite.quote(#"{"texts":[null]}"#)),
            Reply.message(content: Rewrite.quote("```json\n" + content + "\n```")),
            // The finish, the choices and their types.
            #"{"choices":[{"finish_reason":"length","message":{"content":\#(Rewrite.quote(content))}}]}"#,
            #"{"choices":[{"finish_reason":null,"message":{"content":\#(Rewrite.quote(content))}}]}"#,
            #"{"choices":[{"message":{"content":\#(Rewrite.quote(content))}}]}"#,
            #"{"choices":[{"finish_reason":"stop","message":null}]}"#,
            #"{"choices":[{"finish_reason":"stop","message":[]}]}"#,
            #"{"choices":[{"finish_reason":1,"message":{"content":\#(Rewrite.quote(content))}}]}"#,
            #"{"choices":[]}"#,
            #"{"choices":null}"#,
            #"{"choices":{}}"#,
            #"{"choices":[null]}"#,
            "null",
            "[]",
            #"{"choices":[{"finish_reason":"stop","message":{"content":\#(Rewrite.quote(content))}},{"finish_reason":"stop","message":{"content":\#(Rewrite.quote(content))}}]}"#,
            // Whatever else is there is ignored, if it is JSON.
            #" {"id":"x","usage":{"a":[1,-0,1.5e+3,true,false,null,{"b":"\/é"}]},"choices":[{"finish_reason":"stop","message":{"content":\#(Rewrite.quote(content))}}]} "#,
            #"{"usage":01,"choices":[{"finish_reason":"stop","message":{"content":\#(Rewrite.quote(content))}}]}"#,
            #"{"usage":1.,"choices":[{"finish_reason":"stop","message":{"content":\#(Rewrite.quote(content))}}]}"#,
            #"{"usage":tru,"choices":[{"finish_reason":"stop","message":{"content":\#(Rewrite.quote(content))}}]}"#,
            #"{"choices":[{"finish_reason":"stop","message":{"content":\#(Rewrite.quote(content))}}],}"#,
            "{\"usage\":\"raw \u{01} control\",\"choices\":[{\"finish_reason\":\"stop\",\"message\":{\"content\":\(Rewrite.quote(content))}}]}",
            // The texts themselves.
            Reply.ok([" \n\t"]),
            Reply.ok(["\u{A0}"]),
            Reply.ok(["\u{3000}\u{2028}"]),
            Reply.ok(["\u{200B}"]),
            Reply.ok(["one\ntwo\tthree"]),
            Reply.ok(["carriage\rreturn"]),
            Reply.ok(["start \u{01} end"]),
            Reply.ok(["delete \u{7F} end"]),
            Reply.ok(["back\u{08}space"]),
            Reply.ok(["a/b \"c\" \\d <e> & f 👩‍👩‍👧"]),
            Reply.ok([String(repeating: "a", count: 128 << 10)]),
            Reply.ok([String(repeating: "a", count: (128 << 10) + 1)]),
            Reply.ok([String(repeating: "é", count: 64 << 10)]),
            // Escapes Go turns into U+FFFD: a lone surrogate, and a high one
            // followed by something else; a pair is one character.
            Reply.message(content: #""{\"texts\":[\"lone \\ud800 surrogate\"]}""#),
            Reply.message(content: #""{\"texts\":[\"high \\ud800\\u0041 then A\"]}""#),
            Reply.message(content: #""{\"texts\":[\"low \\udc00 alone\"]}""#),
            Reply.message(content: #""{\"texts\":[\"pair \\ud83d\\ude00 smile\"]}""#),
            Reply.message(content: #""{\"texts\":[\"lone\"]}\ud800""#),
            // The reply's size: 1 MiB at most.
            Reply.padded(Reply.ok(["Greet the team."]), to: 1 << 20),
            Reply.padded(Reply.ok(["Greet the team."]), to: (1 << 20) + 1),
        ]
        let verdicts = try DaemonReply.judge(cases.map { (["Say hello to the team."], Array($0.utf8)) })
        var accepted = 0
        for (reply, verdict) in zip(cases, verdicts) {
            let app = Rewrite.texts(status: 200, body: Array(reply.utf8), count: 1)
            #expect(app == (verdict.accepted ? verdict.texts : nil), "\(reply.prefix(120))")
            if verdict.accepted { accepted += 1 }
        }
        // The battery has both verdicts in it.
        #expect(accepted > 10 && accepted < cases.count - 10)
    }

    /// Where the app is stricter than Go: replies the worker never makes,
    /// which the daemon would accept and the app refuses.
    @Test func theAppIsStricterOnlyWhereTheWorkerNeverGoes() throws {
        let content = Rewrite.quote(#"{"texts":["Greet the team."]}"#)
        let deep = String(repeating: "[", count: 200) + String(repeating: "]", count: 200)
        var invalid = Array(#"{"usage":"x","choices":[{"finish_reason":"stop","message":{"content":\#(content)}}]}"#.utf8)
        invalid[10] = 0xFF
        let cases: [[UInt8]] = [
            Array(#"{"choices":[],"choices":[{"finish_reason":"stop","message":{"content":\#(content)}}]}"#.utf8),
            Array(Reply.message(content: Rewrite.quote(#"{"texts":["a"],"texts":["Greet the team."]}"#)).utf8),
            Array(#"{"usage":\#(deep),"choices":[{"finish_reason":"stop","message":{"content":\#(content)}}]}"#.utf8),
            invalid,
        ]
        let verdicts = try DaemonReply.judge(cases.map { (["Say hello to the team."], $0) })
        for (reply, verdict) in zip(cases, verdicts) {
            #expect(verdict.accepted)
            #expect(Rewrite.texts(status: 200, body: reply, count: 1) == nil)
        }
    }
}

/// Reply bodies as a worker would send them.
enum Reply {
    static func message(content: String, more: String = "") -> String {
        #"{"object":"chat.completion","choices":[{"index":0,"finish_reason":"stop","message":{"role":"assistant","content":\#(content)\#(more)}}]}"#
    }

    static func ok(_ texts: [String]) -> String {
        message(content: Rewrite.quote(#"{"texts":["# + texts.map(Rewrite.quote).joined(separator: ",") + "]}"))
    }

    /// The reply, with spaces after it to make it `size` bytes.
    static func padded(_ reply: String, to size: Int) -> String {
        reply + String(repeating: " ", count: size - reply.utf8.count)
    }
}

/// tests/daemon_reply, built once, as tests/test_llama_worker.py builds it.
enum DaemonReply {
    struct Verdict: Decodable {
        let accepted: Bool
        let request: Data?
        let texts: [String]?
    }

    static let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    private static let tool = Result { try build() }

    private static func build() throws -> URL {
        let daemon = root.appending(path: "reference/src/zkapi/zkapi-clientd")
        let out = URL(filePath: NSTemporaryDirectory()).appending(path: "cloak-daemon-reply-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let overlay = ["Replace": [daemon.appending(path: "cmd/cloak-daemon-reply/main.go").path: root.appending(path: "tests/daemon_reply/main.go").path]]
        try JSONEncoder().encode(overlay).write(to: out.appending(path: "overlay.json"))
        let binary = out.appending(path: "cloak-daemon-reply")
        try run(
            ["go", "build", "-p", "2", "-trimpath", "-overlay", out.appending(path: "overlay.json").path, "-o", binary.path,
             "./cmd/cloak-daemon-reply"],
            in: daemon, environment: ["CGO_ENABLED": "0"])
        return binary
    }

    /// The daemon's verdict on each reply to a request for its texts.
    static func judge(_ cases: [([String], [UInt8])]) throws -> [Verdict] {
        struct Line: Encodable {
            let texts: [String]
            let reply: Data
        }
        var input = Data()
        for (texts, reply) in cases {
            input += try JSONEncoder().encode(Line(texts: texts, reply: Data(reply))) + Data("\n".utf8)
        }
        let output = try run([try tool.get().path], in: root, input: input)
        let verdicts = try output.split(separator: UInt8(ascii: "\n")).map { try JSONDecoder().decode(Verdict.self, from: Data($0)) }
        #expect(verdicts.count == cases.count)
        return verdicts
    }

    /// Runs a command to its end; its output, or a failure with what it said.
    @discardableResult
    static func run(_ command: [String], in folder: URL, environment: [String: String] = [:], input: Data = Data()) throws -> Data {
        let files = URL(filePath: NSTemporaryDirectory()).appending(path: "cloak-run-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: files) }
        let stdin = files.appending(path: "in"), stdout = files.appending(path: "out"), stderr = files.appending(path: "err")
        try input.write(to: stdin)
        FileManager.default.createFile(atPath: stdout.path, contents: nil)
        FileManager.default.createFile(atPath: stderr.path, contents: nil)
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = command
        process.currentDirectoryURL = folder
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        process.standardInput = try FileHandle(forReadingFrom: stdin)
        process.standardOutput = try FileHandle(forWritingTo: stdout)
        process.standardError = try FileHandle(forWritingTo: stderr)
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failed(command: command.joined(separator: " "), said: (try? String(contentsOf: stderr, encoding: .utf8)) ?? "")
        }
        return try Data(contentsOf: stdout)
    }

    struct Failed: Error {
        let command: String
        let said: String
    }
}
