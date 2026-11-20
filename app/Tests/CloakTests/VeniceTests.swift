@testable import CloakChat
import Foundation
import Synchronization
import Testing

/// Proof before sending and money, for Venice: a chat whose model is gone,
/// may be answered by another, or changed tier sends nothing; a chat request
/// carries exactly the intended fields; the key never reaches a stop's words
/// or a log line; and the wallet's sign-in and payment are Venice's
/// documented messages byte for byte, paying only Base USDC. Against a
/// stand-in transport; test-only keys and signers; never the network.
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
        (VeniceChat(model: "retired-long-ago", tier: .private), .gone),
        (VeniceChat(model: "gemma-4-uncensored", tier: .private), .gone),
        (VeniceChat(model: "llama-3.3-70b", tier: .tee), .tierChanged),
        (VeniceChat(model: "e2ee-glm-5-3-flash", tier: .private), .tierChanged),
        (VeniceChat(model: "gemini-4-carbon", tier: .private), .tierChanged),
        (VeniceChat(model: "resting", tier: .private), .busy),
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

    @Test
    func chatCarriesExactlyItsFields() async throws {
        let standIn = StandIn(answer: Self.venice)

        let answer = try await Self.ask(Venice(auth: .key("sk-test"), transport: standIn.transport), VeniceChat(model: "llama-3.3-70b", tier: .private), earlier: true)

        #expect(answer.text == "pong")
        let chat = try #require(standIn.sent.last)
        #expect(chat.method == "POST")
        #expect(chat.url.absoluteString == "https://api.venice.ai/api/v1/chat/completions")
        #expect(chat.headers == ["authorization": "Bearer sk-test", "content-type": "application/json"])
        let body = try #require(chat.body)
        #expect(
            String(decoding: body, as: UTF8.self)
                == #"{"messages":[{"content":"first, reworded","role":"user"},{"content":"first answer","role":"assistant"},{"content":"now, reworded","role":"user"}],"model":"llama-3.3-70b","stream":true,"stream_options":{"include_usage":true},"venice_parameters":{"enable_web_search":"off","include_venice_system_prompt":false,"strip_thinking_response":true}}"#
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

        let asked = await #expect(throws: VeniceStop.self) { try await Self.ask(venice, VeniceChat(model: "llama-3.3-70b", tier: .private)) }
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
            try await Self.ask(Venice(auth: .key(key), transport: standIn.transport), VeniceChat(model: "llama-3.3-70b", tier: .private))
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
    ])
    func topUpTakesOnlyBaseUSDC(entry: String) async throws {
        let standIn = StandIn { _ in (402, [:], Self.terms(base: entry)) }

        let stop = await #expect(throws: VeniceStop.self) {
            try await Venice(auth: .key("sk-test"), transport: standIn.transport).topUpTerms()
        }

        #expect(stop?.kind == .failed)
        #expect(standIn.sent.count == 1)
    }
}
