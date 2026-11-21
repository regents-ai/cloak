@testable import CloakChat
import Foundation
import Synchronization
import Testing

/// Proof before sending and money, for Venice: a chat whose model is gone,
/// may be answered by another, or changed tier, or whose list does not
/// come, sends nothing; each turn goes as its owner chose, and a chat
/// request carries exactly the intended fields; a stop before Venice's head
/// is called unsent only when nothing went; the key never reaches a stop's
/// words or a log line; the wallet's sign-in and payment are Venice's
/// documented messages byte for byte, paying only Base USDC; and dollars
/// typed are read exactly, each press of Add signing exactly them once with
/// the one wallet's key, and nothing when Venice asks for more. Against
/// stand-ins for the transport and the guest; test-only keys and signers;
/// never the network.
struct VeniceTests {
    /// Keeps each request and answers it from `answer`.
    final class StandIn: Sendable {
        let requests = Mutex<[VeniceRequest]>([])
        let answer: @Sendable (VeniceRequest) -> (status: Int, headers: [String: String], body: String)

        init(answer: @escaping @Sendable (VeniceRequest) -> (status: Int, headers: [String: String], body: String)) {
            self.answer = answer
        }

        var transport: VeniceTransport {
            { request throws(VeniceUnreachable) in
                self.requests.withLock { $0.append(request) }
                let (status, headers, body) = self.answer(request)
                return VeniceResponse(
                    status: status, headers: headers,
                    body: AsyncThrowingStream { continuation in
                        continuation.yield(Data(body.utf8))
                        continuation.finish()
                    })
            }
        }

        var sent: [VeniceRequest] { requests.withLock { $0 } }
    }

    /// Venice's list, trimmed to five entries in its own shape.
    static let list = #"""
        {"data":[
        {"id":"llama-3.3-70b","type":"text","model_spec":{"name":"Llama 3.3 70B","privacy":"private","offline":false,"availableContextTokens":131072,"capabilities":{"supportsTeeAttestation":false,"supportsE2EE":false},"pricing":{"input":{"usd":0.7,"diem":0.7},"output":{"usd":2.8,"diem":2.8}}}},
        {"id":"e2ee-glm-5-3-flash","type":"text","model_spec":{"name":"GLM 5.3 Flash","privacy":"private","offline":false,"availableContextTokens":131072,"capabilities":{"supportsTeeAttestation":true,"supportsE2EE":true},"pricing":{"input":{"usd":0.16,"diem":0.16},"output":{"usd":0.54,"diem":0.54}}}},
        {"id":"gemini-4-carbon","type":"text","model_spec":{"name":"Gemini 4 Carbon","privacy":"anonymized","offline":false,"availableContextTokens":1000000,"capabilities":{"supportsTeeAttestation":false,"supportsE2EE":false},"pricing":{"input":{"usd":2.5,"diem":2.5},"output":{"usd":12.5,"diem":12.5}}}},
        {"id":"gemma-4-uncensored","type":"text","model_spec":{"name":"Gemma 4 Uncensored","privacy":"private","offline":false,"availableContextTokens":131072,"capabilities":{"supportsTeeAttestation":false,"supportsE2EE":false},"pricing":{"input":{"usd":0.1625,"diem":0.1625},"output":{"usd":0.5,"diem":0.5}},"deprecation":{"autoRemap":true,"date":"2026-12-01T00:00:00.000Z","removesAt":"2026-12-01T00:00:00.000Z","replacementModelId":"glm-5-3-flash-uncensored"}}},
        {"id":"resting","type":"text","model_spec":{"name":"Resting","privacy":"private","offline":true,"availableContextTokens":32768,"capabilities":{"supportsTeeAttestation":false,"supportsE2EE":false},"pricing":{"input":{"usd":0.1,"diem":0.1},"output":{"usd":0.2,"diem":0.2}}}}
        ],"object":"list","type":"text"}
        """#

    static func stream(model: String) -> String {
        [
            #"{"id":"c","model":"\#(model)","choices":[{"index":0,"delta":{"role":"assistant","content":"pong"},"finish_reason":"stop"}]}"#,
            #"{"id":"c","model":"\#(model)","choices":[],"usage":{"prompt_tokens":9,"completion_tokens":1,"total_tokens":10},"cost":{"usd":0.00001,"diem":0}}"#,
            "[DONE]",
        ].map { "data: \($0)\n\n" }.joined()
    }

    /// Answers the list, then each chat with a short stream from its model.
    static func venice(_ request: VeniceRequest) -> (status: Int, headers: [String: String], body: String) {
        if request.url.path == "/api/v1/models" { return (200, [:], list) }
        let model = (try? JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any])?["model"] as? String ?? ""
        return (200, [:], stream(model: model))
    }

    static func ask(_ venice: Venice, _ chat: VeniceChat, earlier: Bool = false) async throws(VeniceStop) -> VeniceAnswer {
        let turn = Turn(original: "now, as written", reworded: "now, reworded")
        let turns = earlier ? [Turn(original: "first, as written", reworded: "first, reworded", answer: "first answer"), turn] : [turn]
        return try await venice.ask(chat, turn: turn.id, in: Conversation(turns: turns), partial: { _ in })
    }

    static let refusals: [(VeniceChat, VeniceStop.Kind)] = [
        (VeniceChat(model: "retired-long-ago", tier: .private, pays: .key), .gone),
        (VeniceChat(model: "gemma-4-uncensored", tier: .private, pays: .key), .gone),
        (VeniceChat(model: "llama-3.3-70b", tier: .tee, pays: .key), .tierChanged),
        (VeniceChat(model: "e2ee-glm-5-3-flash", tier: .private, pays: .key), .tierChanged),
        (VeniceChat(model: "gemini-4-carbon", tier: .private, pays: .key), .tierChanged),
        (VeniceChat(model: "resting", tier: .private, pays: .key), .busy),
    ]

    @Test(arguments: refusals)
    func chatWhoseModelMovedSendsNothing(chat: VeniceChat, kind: VeniceStop.Kind) async throws {
        let standIn = StandIn(answer: Self.venice)

        let stop = await #expect(throws: VeniceStop.self) { try await Self.ask(Venice(auth: .key("sk-test"), transport: standIn.transport), chat) }

        #expect(stop?.kind == kind)
        #expect(stop?.sent == false)
        #expect(standIn.sent.map(\.description) == ["GET /api/v1/models"])
        #expect(standIn.sent.first?.headers == [:])
    }

    /// A list that does not read, or does not come, stops the message before
    /// it goes: nothing more is sent, and the stop says nothing was.
    @Test(arguments: [401, 429, 500, 503])
    func aListThatStopsSendsNothingMore(status: Int) async throws {
        let standIn = StandIn { _ in (status, [:], "{}") }

        let stop = await #expect(throws: VeniceStop.self) {
            try await Self.ask(Venice(auth: .key("sk-test"), transport: standIn.transport), VeniceChat(model: "llama-3.3-70b", tier: .private, pays: .key))
        }

        #expect(stop?.sent == false)
        #expect(standIn.sent.map(\.description) == ["GET /api/v1/models"])
    }

    @Test
    func aListThatDoesNotComeSendsNothingMore() async throws {
        let tries = Mutex(0)
        let transport: VeniceTransport = { _ throws(VeniceUnreachable) in
            tries.withLock { $0 += 1 }
            throw VeniceUnreachable(sent: true)
        }

        let stop = await #expect(throws: VeniceStop.self) {
            try await Self.ask(Venice(auth: .key("sk-test"), transport: transport), VeniceChat(model: "llama-3.3-70b", tier: .private, pays: .key))
        }

        #expect(stop?.kind == .unreachable)
        #expect(stop?.sent == false)
        #expect(tries.withLock { $0 } == 1)
    }

    /// A turn its owner chose to send as written goes as written in its
    /// place, and every reworded turn goes reworded alone: no original of a
    /// reworded turn is ever in the request.
    @Test
    func eachTurnGoesAsItsOwnerChose() async throws {
        let standIn = StandIn(answer: Self.venice)
        let earlier = Turn(original: "first, as written", reworded: "first, reworded", answer: "first answer")
        let now = Turn(original: "now, as written", reworded: nil)

        _ = try await Venice(auth: .key("sk-test"), transport: standIn.transport).ask(
            VeniceChat(model: "llama-3.3-70b", tier: .private, pays: .key), turn: now.id, in: Conversation(turns: [earlier, now]),
            partial: { _ in })

        let body = try #require(standIn.sent.last?.body)
        let sent = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(
            sent["messages"] as? [[String: String]] == [
                ["role": "user", "content": "first, reworded"], ["role": "assistant", "content": "first answer"],
                ["role": "user", "content": "now, as written"],
            ])
        #expect(!String(decoding: body, as: UTF8.self).contains("first, as written"))
    }

    /// What reaches the guest for a Venice request is that request, and a
    /// stop before Venice's head says nothing was sent only when Tor was
    /// down, so a message that may have reached Venice, and may be charged,
    /// is never called unsent.
    @Test(arguments: [("tor_down", false), ("failed", true), ("unreachable", true)])
    func aStopBeforeVenicesHeadSaysWhetherItWasSent(code: String, sent: Bool) async throws {
        let lines = Mutex<[Data]>([])
        let transport = Remote.veniceTransport(identity: "conversation") { line in
            lines.withLock { $0.append(line) }
            return AsyncThrowingStream { pieces in
                pieces.yield(.end(Data(#"{"stop":{"code":"\#(code)","detail":"test"}}"#.utf8)))
                pieces.finish()
            }
        }
        let headers = ["authorization": "Bearer sk-test", "content-type": "application/json"]
        let request = VeniceRequest(
            method: "POST", url: URL(string: "https://api.venice.ai/api/v1/chat/completions")!, headers: headers, body: Data(#"{"model":"m"}"#.utf8))

        let unreachable = await #expect(throws: VeniceUnreachable.self) { try await transport(request) }

        #expect(unreachable?.sent == sent)
        let line = try #require(lines.withLock { $0.count == 1 ? $0.first : nil })
        let fields = try #require(JSONSerialization.jsonObject(with: line) as? NSDictionary)
        #expect(
            fields
                == [
                    "op": "venice", "identity": "conversation", "method": "POST", "url": "https://api.venice.ai/api/v1/chat/completions",
                    "headers": headers, "body": #"{"model":"m"}"#,
                ] as NSDictionary)
    }

    @Test
    func chatCarriesExactlyItsFields() async throws {
        let standIn = StandIn(answer: Self.venice)

        let answer = try await Self.ask(Venice(auth: .key("sk-test"), transport: standIn.transport), VeniceChat(model: "llama-3.3-70b", tier: .private, pays: .key), earlier: true)

        #expect(answer.text == "pong")
        let chat = try #require(standIn.sent.last)
        #expect(chat.method == "POST")
        #expect(chat.url.absoluteString == "https://api.venice.ai/api/v1/chat/completions")
        #expect(chat.headers == ["authorization": "Bearer sk-test", "content-type": "application/json"])
        let body = try #require(chat.body)
        #expect(
            String(decoding: body, as: UTF8.self)
                == #"{"messages":[{"content":"first, reworded","role":"user"},{"content":"first answer","role":"assistant"},{"content":"now, reworded","role":"user"}],"model":"llama-3.3-70b","stream":true,"venice_parameters":{"enable_web_search":"off","include_venice_system_prompt":false,"strip_thinking_response":true}}"#
        )
    }

    @Test(arguments: [400, 401, 402, 403, 404, 413, 429, 500, 503])
    func keyNeverInAStop(status: Int) async throws {
        let key = "VENICE-INFERENCE-KEY-test-only"
        let quoting = #"{"error":{"message":"bad key \#(key)","code":"\#(key)"},"code":"\#(key)","details":"\#(key)"}"#
        let standIn = StandIn { request in
            request.url.path == "/api/v1/models" ? (200, [:], Self.list) : (status, ["x-echo": key], quoting)
        }
        let venice = Venice(auth: .key(key), transport: standIn.transport)

        let asked = await #expect(throws: VeniceStop.self) { try await Self.ask(venice, VeniceChat(model: "llama-3.3-70b", tier: .private, pays: .key)) }
        let checked = await #expect(throws: VeniceStop.self) { try await venice.account() }

        for stop in [asked, checked] {
            let stop = try #require(stop)
            for words in [stop.text, stop.kind.words, String(describing: stop), String(reflecting: stop)] {
                #expect(!words.contains(key))
            }
        }
        for request in standIn.sent {
            #expect(!String(describing: request).contains(key))
            #expect(!String(reflecting: request).contains(key))
        }
        #expect(!String(describing: venice.auth).contains(key))
        #expect(!String(reflecting: venice.auth).contains(key))
    }

    @Test
    func keyNeverInAStopMidway() async throws {
        let key = "VENICE-INFERENCE-KEY-test-only"
        let standIn = StandIn { request in
            request.url.path == "/api/v1/models"
                ? (200, [:], Self.list)
                : (200, [:], #"data: {"error":{"message":"\#(key)","type":"\#(key)","code":"\#(key)","param":null}}"# + "\n\ndata: [DONE]\n\n")
        }

        let stop = await #expect(throws: VeniceStop.self) {
            try await Self.ask(Venice(auth: .key(key), transport: standIn.transport), VeniceChat(model: "llama-3.3-70b", tier: .private, pays: .key))
        }

        #expect(stop?.kind == .failed)
        #expect(stop.map { !String(reflecting: $0).contains(key) } == true)
    }

    static let address = "0x1234567890AbcdEF1234567890aBcdef12345678"
    static let signature = "0x" + String(repeating: "5a", count: 65)

    /// The sign-in Venice's x402 guide builds (siwe's `prepareMessage`, and
    /// `JSON.stringify` of the fields), for these inputs.
    @Test
    func signInIsVenicesExample() async throws {
        let signed = Mutex<[String]>([])
        let signer = VeniceSigner(
            address: Self.address,
            personal: { message in
                signed.withLock { $0.append(message) }
                return Self.signature
            }, typed: { _ in Issue.record("a sign-in signs no typed data"); return "" })

        let header = try await VeniceWallet.signIn(
            for: URL(string: "https://api.venice.ai/api/v1/chat/completions")!, signer: signer, now: Date(timeIntervalSince1970: 1_795_176_000),
            nonce: "8f3b2c1d0e9a8b7c6d5e4f3a2b1c0d9e")

        #expect(
            signed.withLock { $0 } == [
                """
                api.venice.ai wants you to sign in with your Ethereum account:
                0x1234567890AbcdEF1234567890aBcdef12345678

                Sign in to Venice AI

                URI: https://api.venice.ai/api/v1/chat/completions
                Version: 1
                Chain ID: 8453
                Nonce: 8f3b2c1d0e9a8b7c6d5e4f3a2b1c0d9e
                Issued At: 2026-11-20T12:00:00.000Z
                Expiration Time: 2026-11-20T12:05:00.000Z
                """
            ])
        let json =
            #"{"domain":"api.venice.ai","address":"0x1234567890AbcdEF1234567890aBcdef12345678","statement":"Sign in to Venice AI","uri":"https://api.venice.ai/api/v1/chat/completions","version":"1","nonce":"8f3b2c1d0e9a8b7c6d5e4f3a2b1c0d9e","issuedAt":"2026-11-20T12:00:00.000Z","expirationTime":"2026-11-20T12:05:00.000Z","chainId":"eip155:8453","type":"eip191","signature":"\#(Self.signature)"}"#
        #expect(header == Data(json.utf8).base64EncodedString())
    }

    /// Venice's `402` answer to a bare top-up, with the Base entry as the
    /// guide spells it.
    static func terms(base: String) -> String {
        #"{"x402Version":2,"accepts":[{"scheme":"exact","network":"solana:5eykt4UsFv8P8NJdTREpY1vzqKqZKvdp","amount":"5000000","asset":"EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v","payTo":"8qUL23aSj7mDWdoLMXGHFvnVCT9wd7jXcysiekroADEL","maxTimeoutSeconds":300,"extra":{"feePayer":"BFK9TLC3edb13K6v4YyH3DwPb5DSUpkWvb7XnqCL9b4F"}},\#(base)]}"#
    }

    static let base =
        #"{"scheme":"exact","network":"eip155:8453","amount":"5000000","asset":"0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913","payTo":"0x2670B922ef37C7Df47158725C0CC407b5382293F","maxTimeoutSeconds":300,"extra":{"name":"USD Coin","version":"2"}}"#

    /// The payment Venice's x402 guide builds (x402 1.2.1's
    /// `createPaymentHeader` with version 2 and its Base terms) for five
    /// dollars, and the typed data it signs: exactly that amount, to
    /// Venice's address, in Base's USDC.
    @Test
    func topUpPaysExactlyAsVenicesExample() async throws {
        let standIn = StandIn { request in
            request.headers["payment-signature"] == nil
                ? (402, [:], Self.terms(base: Self.base))
                : (200, [:], #"{"success":true,"data":{"walletAddress":"\#(Self.address)","amountCredited":5,"newBalance":17.5,"paymentId":"payment_1"}}"#)
        }
        let typed = Mutex<[Data]>([])
        let signer = VeniceSigner(
            address: Self.address, personal: { _ in Issue.record("a top-up signs no sign-in"); return "" },
            typed: { data in
                typed.withLock { $0.append(data) }
                return Self.signature
            })
        let venice = Venice(
            auth: .wallet(signer), transport: standIn.transport, now: { Date(timeIntervalSince1970: 1_795_219_200) },
            random: { Array(repeating: 0xab, count: $0) })

        let terms = try await venice.topUpTerms()
        let taken = try await venice.topUp(Amount(units: 5_000_000), on: terms, by: signer)

        #expect(taken == VeniceTopUp(credited: 5, balance: Decimal(string: "17.5")!))
        let nonce = "0x" + String(repeating: "ab", count: 32)
        let authorization =
            #"{"from":"0x1234567890AbcdEF1234567890aBcdef12345678","to":"0x2670B922ef37C7Df47158725C0CC407b5382293F","value":"5000000","validAfter":"1795218600","validBefore":"1795219500","nonce":"\#(nonce)"}"#
        #expect(
            typed.withLock { $0.map { String(decoding: $0, as: UTF8.self) } } == [
                #"{"types":{"EIP712Domain":[{"name":"name","type":"string"},{"name":"version","type":"string"},{"name":"chainId","type":"uint256"},{"name":"verifyingContract","type":"address"}],"TransferWithAuthorization":[{"name":"from","type":"address"},{"name":"to","type":"address"},{"name":"value","type":"uint256"},{"name":"validAfter","type":"uint256"},{"name":"validBefore","type":"uint256"},{"name":"nonce","type":"bytes32"}]},"primaryType":"TransferWithAuthorization","domain":{"name":"USD Coin","version":"2","chainId":8453,"verifyingContract":"0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"},"message":\#(authorization)}"#
            ])
        let payment = #"{"x402Version":2,"scheme":"exact","network":"base","payload":{"signature":"\#(Self.signature)","authorization":\#(authorization)}}"#
        #expect(standIn.sent.map(\.headers) == [[:], ["payment-signature": Data(payment.utf8).base64EncodedString()]])
        #expect(standIn.sent.allSatisfy { $0.body == nil && $0.url.absoluteString == "https://api.venice.ai/api/v1/x402/top-up" })
    }

    @Test(arguments: [
        #"{"scheme":"exact","network":"eip155:1","amount":"5000000","asset":"0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913","payTo":"0x2670B922ef37C7Df47158725C0CC407b5382293F","maxTimeoutSeconds":300,"extra":{"name":"USD Coin","version":"2"}}"#,
        #"{"scheme":"exact","network":"eip155:8453","amount":"5000000","asset":"0x0000000000000000000000000000000000000001","payTo":"0x2670B922ef37C7Df47158725C0CC407b5382293F","maxTimeoutSeconds":300,"extra":{"name":"USD Coin","version":"2"}}"#,
        #"{"scheme":"upto","network":"eip155:8453","amount":"5000000","asset":"0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913","payTo":"0x2670B922ef37C7Df47158725C0CC407b5382293F","maxTimeoutSeconds":300,"extra":{"name":"USD Coin","version":"2"}}"#,
        #"{"scheme":"exact","network":"eip155:8453","amount":"5000000","asset":"0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913","payTo":"0x2670B922ef37C7Df47158725C0CC407b5382293F","maxTimeoutSeconds":300,"extra":{"name":"USDC","version":"2"}}"#,
        #"{"scheme":"exact","network":"eip155:8453","amount":"5000000","asset":"0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913","payTo":"0x2670B922ef37C7Df47158725C0CC407b5382293F","maxTimeoutSeconds":300,"extra":{"name":"USD Coin","version":"1"}}"#,
    ])
    func topUpTakesOnlyBaseUSDC(entry: String) async throws {
        let standIn = StandIn { _ in (402, [:], Self.terms(base: entry)) }
        let guest = Guest()
        let signer = guest.signer

        let stop = await #expect(throws: VeniceStop.self) {
            try await Venice(auth: .wallet(signer), transport: standIn.transport).add(Amount(units: 5_000_000), by: signer)
        }

        #expect(stop?.kind == .notUSDC)
        #expect(stop?.sent == false)
        #expect(guest.read.isEmpty)
        #expect(standIn.sent.count == 1)
    }

    /// Terms that do not come, or do not read, stop Add before anything is
    /// signed, and the stop says no payment went.
    @Test(arguments: [(429, "{}"), (500, "{}"), (503, "{}"), (402, "{}"), (402, "not json"), (200, Self.taken)])
    func termsThatDoNotReadPayNothing(status: Int, body: String) async throws {
        let standIn = StandIn { _ in (status, [:], body) }
        let guest = Guest()

        let stop = await #expect(throws: VeniceStop.self) {
            try await Venice(auth: .wallet(guest.signer), transport: standIn.transport).add(Amount(units: 5_000_000), by: guest.signer)
        }

        #expect(stop?.sent == false)
        #expect(guest.read.isEmpty)
        #expect(standIn.sent.count == 1)
    }

    @Test
    func termsThatDoNotComePayNothing() async throws {
        let tries = Mutex(0)
        let transport: VeniceTransport = { _ throws(VeniceUnreachable) in
            tries.withLock { $0 += 1 }
            throw VeniceUnreachable(sent: true)
        }
        let guest = Guest()

        let stop = await #expect(throws: VeniceStop.self) {
            try await Venice(auth: .wallet(guest.signer), transport: transport).add(Amount(units: 5_000_000), by: guest.signer)
        }

        #expect(stop?.kind == .unreachable)
        #expect(stop?.sent == false)
        #expect(guest.read.isEmpty)
        #expect(tries.withLock { $0 } == 1)
    }

    // MARK: Money

    /// The wallet's key, a test vector.
    static let walletKey = Data(repeating: 0x11, count: 32)

    /// A stand-in for the guest's sender, which signs for the one wallet:
    /// it keeps each request and answers each with a signature.
    final class Guest: Sendable {
        let requests = Mutex<[[String: String]]>([])

        var exchange: Exchange {
            { request, _ in
                let fields = try JSONSerialization.jsonObject(with: try request()) as? [String: String] ?? [:]
                self.requests.withLock { $0.append(fields) }
                return Data(#"{"ok":{"signature":"\#(VeniceTests.signature)"}}"#.utf8)
            }
        }

        /// The wallet's signer for Venice, as the app makes it.
        var signer: VeniceSigner {
            Remote.veniceSigner(address: VeniceTests.address, key: { VeniceTests.walletKey }, exchange: exchange)
        }

        var read: [[String: String]] { requests.withLock { $0 } }

        /// The transfer the guest was asked to sign in `signed`.
        static func transfer(_ signed: [String: String]) throws -> [String: String] {
            let text = try #require(signed["typed"])
            let typed = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            return try #require(typed["message"] as? [String: String])
        }
    }

    /// Venice's answer to a top-up it took.
    static let taken = #"{"success":true,"data":{"walletAddress":"\#(address)","amountCredited":5,"newBalance":5,"paymentId":"payment_1"}}"#

    /// Answers a bare top-up with Venice's terms, least `least`, and a paid
    /// one with `paid`.
    static func topUps(least: String = "5000000", paid: (status: Int, body: String) = (200, taken)) -> StandIn {
        StandIn { request in
            request.headers["payment-signature"] == nil
                ? (402, [:], Self.terms(base: Self.base.replacingOccurrences(of: #""amount":"5000000""#, with: #""amount":"\#(least)""#)))
                : (paid.status, [:], paid.body)
        }
    }

    /// Dollars as typed are read exactly, or not at all: never rounded.
    @Test(arguments: [
        ("5", 5_000_000), ("$7.50", 7_500_000), (" 12.345678 ", 12_345_678), ("0.000001", 1), ("$0.5", 500_000), ("5.", 5_000_000),
        ("18446744073709.551615", 18_446_744_073_709_551_615),
    ] as [(String, UInt64)])
    func dollarsReadExactly(text: String, units: UInt64) {
        #expect(Amount(dollars: text) == Amount(units: units))
    }

    @Test(arguments: [
        "", " ", "0", "0.00", "$0", "-5", "+5", "5.0000001", "1,000", "5e3", "five", "$", ".5", "$$5", "5 5", "５", "18446744073710",
        "18446744073709.551616",
    ])
    func whatIsNotDollarsReadsAsNothing(text: String) {
        #expect(Amount(dollars: text) == nil)
    }

    /// Add is held back only by the wallet's USDC on Base as last read: by
    /// what it lacks, and never when it was not read.
    @Test
    func addLacksOnlyWhatTheWalletIsShort() {
        let five = Amount(units: 5_000_000)
        #expect(five.lacking(in: nil) == nil)
        #expect(five.lacking(in: Amount(units: 5_000_000)) == nil)
        #expect(five.lacking(in: Amount(units: 9_000_000)) == nil)
        #expect(five.lacking(in: Amount(units: 2_900_000)) == Amount(units: 2_100_000))
        #expect(five.lacking(in: Amount(units: 0)) == five)
    }

    /// One press of Add for the dollars typed signs one transfer of exactly
    /// them to Venice, in the guest with the one wallet's key, and sends that
    /// payment once.
    @Test
    func addSignsExactlyTheDollarsTyped() async throws {
        let standIn = Self.topUps()
        let guest = Guest()
        let amount = try #require(Amount(dollars: "7.25"))

        _ = try await Venice(auth: .wallet(guest.signer), transport: standIn.transport).add(amount, by: guest.signer)

        #expect(standIn.sent.count == 2)
        let signed = try #require(guest.read.count == 1 ? guest.read.first : nil)
        #expect(signed["op"] == "venice_typed")
        #expect(signed["key"] == "0x" + String(repeating: "11", count: 32))
        let message = try Guest.transfer(signed)
        #expect(message["value"] == "7250000")
        #expect(message["from"] == Self.address)
        #expect(message["to"] == "0x2670B922ef37C7Df47158725C0CC407b5382293F")
        let header = try #require(standIn.sent.last?.headers["payment-signature"].flatMap { Data(base64Encoded: $0) })
        let payment = try #require(JSONSerialization.jsonObject(with: header) as? [String: Any])
        #expect((payment["payload"] as? [String: Any])?["authorization"] as? [String: String] == message)
    }

    /// When Venice's terms ask for more than the dollars typed, nothing is
    /// signed or paid.
    @Test(arguments: [("5000000", "4.99"), ("10000000", "7.25"), ("5000000", "4.999999")])
    func addBelowVenicesLeastSignsNothing(least: String, typed: String) async throws {
        let standIn = Self.topUps(least: least)
        let guest = Guest()
        let amount = try #require(Amount(dollars: typed))

        let stop = await #expect(throws: VeniceStop.self) {
            try await Venice(auth: .wallet(guest.signer), transport: standIn.transport).add(amount, by: guest.signer)
        }

        #expect(stop?.kind == .belowLeast)
        #expect(stop?.sent == false)
        #expect(guest.read.isEmpty)
        #expect(standIn.sent.count == 1)
    }

    /// A payment Venice turns down, or answers otherwise, was signed once
    /// and is never sent again; only Venice's own no says it was not taken.
    @Test(arguments: [
        (400, VeniceStop.Kind.paymentRefused), (401, .paymentRefused), (402, .paymentRefused), (403, .failed), (429, .failed), (500, .failed),
        (503, .failed), (200, .failed),
    ])
    func aPaymentNotTakenIsSignedOnce(status: Int, kind: VeniceStop.Kind) async throws {
        let standIn = Self.topUps(paid: (status, "{}"))
        let guest = Guest()

        let stop = await #expect(throws: VeniceStop.self) {
            try await Venice(auth: .wallet(guest.signer), transport: standIn.transport).add(Amount(units: 5_000_000), by: guest.signer)
        }

        #expect(stop?.kind == kind)
        #expect(stop?.sent == true)
        #expect(guest.read.count == 1)
        #expect(standIn.sent.count == 2)
    }

    /// Two presses of Add are two payments, each signed on its own with a
    /// nonce of its own.
    @Test
    func twoAddsAreTwoPayments() async throws {
        let standIn = Self.topUps()
        let guest = Guest()
        let venice = Venice(auth: .wallet(guest.signer), transport: standIn.transport)

        _ = try await venice.add(Amount(units: 5_000_000), by: guest.signer)
        _ = try await venice.add(Amount(units: 5_000_000), by: guest.signer)

        #expect(standIn.sent.count == 4)
        let nonces = try guest.read.map { try Guest.transfer($0)["nonce"] }
        #expect(nonces.count == 2)
        #expect(nonces.allSatisfy { $0?.count == 66 })
        #expect(Set(nonces).count == 2)
    }

    /// Venice's answer, through Tor on 20 November 2026, to a chat sent with
    /// no credentials, byte for byte.
    static let challenge = #"{"x402Version":2,"error":"Authentication required","resource":{"url":"https://api.venice.ai/api/v1/chat/completions","description":"Venice API","mimeType":"application/json"},"accepts":[{"scheme":"exact","network":"eip155:8453","amount":"10000000","asset":"0x833589fcd6edb6e08f4c7c32d4f71b54bda02913","payTo":"0x2670b922ef37c7df47158725c0cc407b5382293f","maxTimeoutSeconds":300,"extra":{"name":"USD Coin","version":"2"}},{"scheme":"exact","network":"solana:5eykt4UsFv8P8NJdTREpY1vzqKqZKvdp","amount":"10000000","asset":"EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v","payTo":"8qUL23aSj7mDWdoLMXGHFvnVCT9wd7jXcysiekroADEL","maxTimeoutSeconds":300,"extra":{"name":"USD Coin","version":"2","feePayer":"BFK9TLC3edb13K6v4YyH3DwPb5DSUpkWvb7XnqCL9b4F"}}],"extensions":{"sign-in-with-x":{"info":{"domain":"api.venice.ai","uri":"https://api.venice.ai/api/v1/chat/completions","version":"1","nonce":"02a34e25e4c4c78eba36bdd0be6642bb","issuedAt":"2026-11-20T22:57:45.626Z","expirationTime":"2026-11-20T23:02:45.626Z","statement":"Sign in to Venice AI"},"supportedChains":[{"chainId":"eip155:8453","type":"eip191"},{"chainId":"solana:5eykt4UsFv8P8NJdTREpY1vzqKqZKvdp","type":"ed25519"}],"schema":{"$schema":"https://json-schema.org/draft/2020-12/schema","type":"object","properties":{"domain":{"type":"string"},"address":{"type":"string"},"statement":{"type":"string"},"uri":{"type":"string","format":"uri"},"version":{"type":"string"},"chainId":{"type":"string"},"type":{"type":"string"},"nonce":{"type":"string"},"issuedAt":{"type":"string","format":"date-time"},"expirationTime":{"type":"string","format":"date-time"},"notBefore":{"type":"string","format":"date-time"},"requestId":{"type":"string"},"resources":{"type":"array","items":{"type":"string","format":"uri"}},"signature":{"type":"string"}},"required":["domain","address","uri","version","chainId","type","nonce","issuedAt","signature"]}}},"authOptions":{"apiKey":{"header":"Authorization: Bearer YOUR_API_KEY","getKey":"https://venice.ai/settings/api","docs":"https://docs.venice.ai/api-reference"},"x402Wallet":{"header":"SIGN-IN-WITH-X","legacyHeader":"X-Sign-In-With-X","topUp":"POST /api/v1/x402/top-up","docs":"https://docs.venice.ai/api-reference/endpoint/x402/top-up"}}}"#

    /// A 402 that asks for credentials says the key or sign-in was not
    /// taken, never that the balance is short, so nobody adds money for it;
    /// a 402 for balance still says so.
    @Test
    func challengeIsNeverNoBalance() async throws {
        let signer = VeniceSigner(address: Self.address, personal: { _ in Self.signature }, typed: { _ in Issue.record("nothing here pays"); return "" })
        for (auth, kind) in [(VeniceAuth.key("sk-test"), VeniceStop.Kind.key), (.wallet(signer), .signIn)] {
            for (body, expected) in [(Self.challenge, kind), (#"{"error":"Insufficient balance","code":"INSUFFICIENT_BALANCE"}"#, .noBalance)] {
                let standIn = StandIn { request in request.url.path == "/api/v1/models" ? (200, [:], Self.list) : (402, [:], body) }
                let venice = Venice(auth: auth, transport: standIn.transport)

                let asked = await #expect(throws: VeniceStop.self) { try await Self.ask(venice, VeniceChat(model: "llama-3.3-70b", tier: .private, pays: .key)) }
                let checked = await #expect(throws: VeniceStop.self) { try await venice.account() }

                #expect(asked?.kind == expected)
                #expect(checked?.kind == expected)
            }
        }
    }

    /// Venice's answer, through Tor on 20 November 2026, to a bare top-up,
    /// byte for byte: its Base entry is the terms, addresses as Venice
    /// writes them.
    @Test
    func realTopUpTermsRead() async throws {
        let terms = #"{"x402Version":2,"accepts":[{"scheme":"exact","network":"eip155:8453","amount":"5000000","asset":"0x833589fcd6edb6e08f4c7c32d4f71b54bda02913","payTo":"0x2670b922ef37c7df47158725c0cc407b5382293f","maxTimeoutSeconds":300,"extra":{"name":"USD Coin","version":"2"}},{"scheme":"exact","network":"solana:5eykt4UsFv8P8NJdTREpY1vzqKqZKvdp","amount":"5000000","asset":"EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v","payTo":"8qUL23aSj7mDWdoLMXGHFvnVCT9wd7jXcysiekroADEL","maxTimeoutSeconds":300,"extra":{"name":"USD Coin","version":"2","feePayer":"BFK9TLC3edb13K6v4YyH3DwPb5DSUpkWvb7XnqCL9b4F"}}]}"#
        let standIn = StandIn { _ in (402, ["payment-required": Data(terms.utf8).base64EncodedString()], terms) }

        let read = try await Venice(auth: .key("sk-test"), transport: standIn.transport).topUpTerms()

        #expect(
            read
                == VeniceTopUpTerms(
                    payTo: "0x2670b922ef37c7df47158725c0cc407b5382293f", least: Amount(units: 5_000_000), timeout: 300, name: "USD Coin", version: "2"))
    }
}
