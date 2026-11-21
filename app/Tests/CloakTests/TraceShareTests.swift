import CloakChat
import CryptoKit
import Foundation
import Testing

/// Trace sharing's checks (docs/state-machines.md, section 9f): nothing goes
/// to the witness or the commons without its press, the upload carries
/// exactly the envelope the review gave back, only a NEAR chat can be
/// readied, only the one message after readying goes readied, and every
/// other message goes as today's `ask`. The helpers are
/// stand-in scripts, pinned as the real one is, that keep each line they
/// read and answer as the real one does; the keychain is a stand-in too. A
/// test-only key and folder; never the keychain, never the network.
@MainActor
struct TraceShareTests {
    static let proof = #"{"passed_at":1795125440,"model_servers":1,"gpus":8,"model_key":"00","gateway_tls_key_sha256":"ff"}"#
    static let reply = #"{"choices":[{"index":0,"message":{"role":"assistant","content":"Madrid."},"finish_reason":"stop"}]}"#
    static let replied = #"{"answer":"replied","sent":true,"proof":\#(proof),"reply":\#(reply)}"#
    static let receipt =
        #"{"text":"m:aa:bb","signature":"00","signing_address":"42","signing_algo":"ed25519","signature_kind":"provider_tee"}"#
    static let exchanged =
        #"{"answer":"exchanged","sent":true,"proof":\#(proof),"reply":\#(reply),"request":"e30=","response":"e30=","receipt":\#(receipt)}"#
    static let uploaded = #"{"answer":"uploaded","sent":true,"commons":{"status":"submitted","explanation":[]}}"#
    /// The witness's envelope: keys out of order, odd spacing and a letter
    /// beyond ASCII, so any reading and writing again would change it.
    static let envelope = Data(#"{"z":"é",  "a":[1 ,2]}"#.utf8)
    static let reviewed =
        #"{"answer":"reviewed","sent":true,"envelope":"\#(envelope.base64EncodedString())","certificate":"c","signature":"s","evidence":"e","evidence_signature":"es","submission_id":"sub-1"}"#
    /// What sharing keeps, as the keychain would give it back: signed in.
    nonisolated static let record = Data(
        #"""
        {"deviceKey":"\#(Data(repeating: 7, count: 32).base64EncodedString())","account":{"tenantId":"t","deviceKeyId":"d","issuerUrl":"https://issuer.test","audience":"a","witness":{"url":"https://witness.test","signingAddress":"0x00","expectedMeasurements":["m"]}},"session":"s","provider":"github","scopes":[],"shared":[]}
        """#.utf8)

    let folder: URL
    let turn = UUID()
    let conversation: Conversation

    init() throws {
        folder = URL(filePath: "/tmp").appending(path: "cloak-traces-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        var conversation = Conversation(turns: [Turn(id: turn, original: "And of Spain?", reworded: nil)])
        conversation.near = true
        self.conversation = conversation
    }

    /// The challenge's answer to Ready, ending `after` seconds from now.
    static func admitted(after: TimeInterval) -> String {
        #"{"answer":"admitted","sent":true,"binding":"b1","expires_at":\#(Int(Date.now.timeIntervalSince1970 + after))}"#
    }

    /// A stand-in for cloak-near, pinned as the real one is, that keeps each
    /// line it reads under `name` and answers it with the next of `answers`,
    /// and ends at a line it has no answer for.
    func helper(_ name: String, answers: [String]) throws -> Near {
        let queue = folder.appending(path: "\(name).answers"), kept = folder.appending(path: "\(name).lines")
        try Data((answers.joined(separator: "\n") + "\n").utf8).write(to: queue)
        try Data().write(to: kept)
        let file = folder.appending(path: name)
        let script = """
            #!/bin/sh
            n=0
            while IFS= read -r line; do
              printf '%s\\n' "$line" >> '\(kept.path)'
              n=$((n+1))
              answer=$(sed -n "${n}p" '\(queue.path)')
              [ -n "$answer" ] || exit 0
              printf '%s\\n' "$answer"
            done
            """
        try Data(script.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        let sha256 = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
        return Near(helper: file, sha256: sha256)
    }

    /// The lines the stand-in `name` read, in order.
    func lines(_ name: String) throws -> [[String: Any]] {
        try String(decoding: Data(contentsOf: folder.appending(path: "\(name).lines")), as: UTF8.self)
            .split(separator: "\n")
            .map { try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
    }

    func requests(_ name: String) throws -> [String] {
        try lines(name).map { $0["request"] as? String ?? "" }
    }

    func share(_ sharing: Near) -> TraceShare {
        TraceShare(sharing: sharing, vault: TraceVault(load: { Self.record }, save: { _ in }, remove: {}), version: "0.0.0")
    }

    /// Sends the chat's message through `share`, on the chat's helper, with
    /// Share Traces on at the press, or not.
    func send(_ share: TraceShare, on chat: Near, shares: Bool = true) async throws -> String {
        try await share.send(turn, in: conversation, shares: shares, on: chat, route: .direct, proofAge: .everyMessage, key: { "sk-test" })
            .text
    }

    /// Presses Share on the review held, as the review sheet shows it.
    func shareShown(_ share: TraceShare) async throws {
        guard case .signedIn(.reviewed(let answered, let review)) = share.state else {
            Issue.record("not reviewed: \(share.state)")
            return
        }
        await share.share(review, of: answered, route: .direct)
    }

    /// Turning on, Ready, the readied message, Review and Share each write
    /// their own line, at their press, and no other: nothing reaches the
    /// witness before Review, nor the commons' ingest before Share. Review
    /// of an exchange NEAR gave no receipt for writes nothing, and Share of a
    /// review no longer held writes nothing.
    @Test func eachStepGoesOnlyAtItsPress() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let sharing = try helper(
            "sharing", answers: [Self.admitted(after: 900), Self.reviewed, Self.uploaded, Self.admitted(after: 900)])
        let noReceipt = Self.exchanged.replacing(#""receipt":\#(Self.receipt)"#, with: #""no_receipt":"none for this model""#)
        let chat = try helper("chat", answers: [Self.exchanged, noReceipt])
        defer { sharing.stop(); chat.stop() }
        let share = share(sharing)

        await share.turn(on: true)
        #expect(try requests("sharing").isEmpty)
        await share.ready(conversation, route: .direct)
        #expect(try requests("sharing") == ["ready"])
        #expect(try await send(share, on: chat) == "Madrid.")
        #expect(try requests("chat") == ["readied"])
        #expect(try requests("sharing") == ["ready"])
        await share.review(route: .direct)
        #expect(try requests("sharing") == ["ready", "review"])
        guard case .signedIn(.reviewed(let shown, let review)) = share.state else {
            Issue.record("not reviewed: \(share.state)")
            return
        }
        await share.share(review, of: shown, route: .direct)
        #expect(try requests("sharing") == ["ready", "review", "upload"])
        #expect(share.shared(in: conversation.id).map(\.submission) == ["sub-1"])

        await share.ready(conversation, route: .direct)
        _ = try await send(share, on: chat)
        #expect(share.answered?.exchange.hasReceipt == false)
        await share.review(route: .direct)
        await share.share(review, of: shown, route: .direct)
        #expect(try requests("sharing") == ["ready", "review", "upload", "ready"])
        #expect(share.stop?.step == .share && share.stop?.stop.sent == false)
    }

    /// The upload's body is the envelope Review showed, its bytes exactly.
    @Test func shareUploadsExactlyTheEnvelopeShown() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let sharing = try helper("sharing", answers: [Self.admitted(after: 900), Self.reviewed, Self.uploaded])
        let chat = try helper("chat", answers: [Self.exchanged])
        defer { sharing.stop(); chat.stop() }
        let share = share(sharing)
        await share.turn(on: true)
        await share.ready(conversation, route: .direct)
        _ = try await send(share, on: chat)
        await share.review(route: .direct)
        guard case .signedIn(.reviewed(_, let review)) = share.state else {
            Issue.record("not reviewed: \(share.state)")
            return
        }
        #expect(review.envelope == Self.envelope)

        try await shareShown(share)

        let upload = try #require(try lines("sharing").last)
        let envelope = try #require(upload["envelope"] as? [String: Any])
        #expect(Data(base64Encoded: try #require(envelope["body"] as? String)) == review.envelope)
    }

    /// A chat of V, Token Inference or Local Llama, and an agent's, can't be
    /// readied: Ready writes nothing for any of them.
    @Test func onlyANearChatCanBeReadied() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let sharing = try helper("sharing", answers: [])
        defer { sharing.stop() }
        let share = share(sharing)
        await share.turn(on: true)
        let v = Conversation(turns: [Turn(original: "Hi", reworded: "Hello")])
        var token = v
        token.token = true
        var llama = v
        llama.llama = true
        var agent = Conversation(turns: [Turn(original: "List the files", reworded: nil, steps: [Step(tool: "bash", detail: "ls")])])
        agent.near = true

        for conversation in [v, token, llama, agent] {
            await share.ready(conversation, route: .direct)
        }

        #expect(try requests("sharing").isEmpty)
        #expect(share.state == .signedIn(.idle))
    }

    /// A message goes as today's `ask` (the same line, field for field) with
    /// the switch off, in a chat not readied while another is, and once the
    /// readied chat's challenge has ended.
    @Test func everyOtherMessageGoesAsToday() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let today = try helper("today", answers: [Self.replied])
        let chat = try helper("chat", answers: [Self.replied, Self.replied, Self.replied])
        let sharing = try helper("sharing", answers: [Self.admitted(after: 900), Self.admitted(after: -1)])
        defer { today.stop(); chat.stop(); sharing.stop() }
        _ = try await today.ask(route: .direct, proofAge: .everyMessage, key: { "sk-test" }, turn: turn, in: conversation)
        let expected = try #require(try lines("today").first) as NSDictionary
        let share = share(sharing)

        _ = try await send(share, on: chat)
        await share.turn(on: true)
        var other = Conversation(turns: [Turn(original: "Hi", reworded: nil, answer: "Hello.")])
        other.near = true
        await share.ready(other, route: .direct)
        _ = try await send(share, on: chat)
        await share.ready(conversation, route: .direct)
        _ = try await send(share, on: chat)

        let sent = try lines("chat")
        #expect(sent.count == 3)
        for line in sent {
            #expect(line as NSDictionary == expected)
        }
    }

    /// Only the one message after readying goes readied. One that stopped
    /// before reaching NEAR leaves the chat readied, so the next goes
    /// readied in its place; once one has gone, the next in the same chat
    /// goes sealed, as today's `ask`. One that stopped after it may have
    /// reached NEAR clears the chat, so the next goes sealed too.
    @Test func theReadiedMessageGoesOnce() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let before = #"{"answer":"stopped","sent":false,"stop":"fetch","text":"no proof"}"#
        let after = #"{"answer":"stopped","sent":true,"stop":"send","text":"dropped"}"#
        let sharing = try helper("sharing", answers: [Self.admitted(after: 900), Self.admitted(after: 900)])
        let chat = try helper("chat", answers: [before, Self.exchanged, Self.replied, after, Self.replied])
        defer { sharing.stop(); chat.stop() }
        let share = share(sharing)
        await share.turn(on: true)
        await share.ready(conversation, route: .direct)

        await #expect(throws: NearStop.self) { try await send(share, on: chat) }
        guard case .signedIn(.readied(let readied)) = share.state else {
            Issue.record("not readied: \(share.state)")
            return
        }
        #expect(readied.chat == conversation.id)
        _ = try await send(share, on: chat)
        _ = try await send(share, on: chat)
        #expect(try requests("chat") == ["readied", "readied", "ask"])

        await share.ready(conversation, route: .direct)
        await #expect(throws: NearStop.self) { try await send(share, on: chat) }
        #expect(share.state == .signedIn(.idle))
        _ = try await send(share, on: chat)
        #expect(try requests("chat") == ["readied", "readied", "ask", "readied", "ask"])
    }

    /// With Share Traces off, the sharing helper is given nothing at all and
    /// every message goes sealed. Off at the press goes sealed even before
    /// sharing hears of it, and turning it off forgets the chat readied.
    @Test func switchOffKeepsSharingOut() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let sharing = try helper("sharing", answers: [Self.admitted(after: 900)])
        let chat = try helper("chat", answers: [Self.replied, Self.replied, Self.replied])
        defer { sharing.stop(); chat.stop() }
        let share = share(sharing)

        await share.ready(conversation, route: .direct)
        _ = try await send(share, on: chat, shares: false)
        #expect(try requests("sharing").isEmpty)

        await share.turn(on: true)
        await share.ready(conversation, route: .direct)
        _ = try await send(share, on: chat, shares: false)
        #expect(share.chat == conversation.id)
        await share.turn(on: false)
        #expect(share.chat == nil)
        _ = try await send(share, on: chat, shares: false)
        #expect(try requests("chat") == ["ask", "ask", "ask"])
        #expect(try requests("sharing") == ["ready"])
    }
}
