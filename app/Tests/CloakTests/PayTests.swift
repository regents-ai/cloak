import CloakChat
import CloakDoor
import CloakHost
import CloakSupervisor
import CryptoKit
import Foundation
import Synchronization
import Testing

/// V's payment on the Mac (docs/zkapi-mac-side.md, item 14 of section 6),
/// against a stand-in for the guest's payer on the far end of a socket pair
/// for each exchange, through the host's own frames (`Pay.exchange`): money
/// moves only on its owner's press, the queue sends one request at a time
/// in its order, and nothing leaves before it is reworded. Test-only
/// folders; never the keychain, the network or a real payer.
@MainActor
@Suite
struct PayTests {
    /// The far end of one exchange: the frame the Mac sent, and its socket,
    /// on which the check answers.
    final class Far: Sendable {
        let kind: UInt8
        let payload: Data
        private let socket: Int32

        init(kind: UInt8, payload: Data, socket: Int32) {
            self.kind = kind
            self.payload = payload
            self.socket = socket
        }

        deinit {
            close(socket)
        }

        var call: PayFrame.Call? {
            kind == Pay.Ask.call.rawValue ? try? JSONDecoder().decode(PayFrame.Call.self, from: payload) : nil
        }

        var request: PayFrame.Request? {
            kind == Pay.Ask.request.rawValue ? try? JSONDecoder().decode(PayFrame.Request.self, from: payload) : nil
        }

        /// A call's method and path, as "GET /admin/withdrawal"; otherwise
        /// the frame's kind, "R" or "V".
        var route: String {
            call.map { "\($0.method) \($0.path)" } ?? String(UnicodeScalar(kind))
        }

        /// A call's JSON body.
        var body: [String: AnyHashable]? {
            call.flatMap { try? JSONSerialization.jsonObject(with: Data($0.body.utf8)) as? [String: AnyHashable] }
        }

        func held(_ held: Bool) {
            send("H", ["held": held])
        }

        func answer(_ body: String, status: Int = 200) {
            send("A", ["status": status, "body": body])
        }

        /// Ends the exchange with no answer.
        func end() {
            shutdown(socket, SHUT_RDWR)
        }

        /// Returns once the Mac has closed its end.
        func hungUp() async {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                Thread { [self] in
                    var byte: UInt8 = 0
                    while read(socket, &byte, 1) > 0 {}
                    done.resume()
                }.start()
            }
        }

        private func send(_ kind: Character, _ object: [String: Any]) {
            let payload = try! JSONSerialization.data(withJSONObject: object)
            let length = UInt32(payload.count).bigEndian
            let frame = Data([kind.asciiValue!]) + withUnsafeBytes(of: length) { Data($0) } + payload
            frame.withUnsafeBytes { bytes in
                var sent = 0
                while sent < bytes.count {
                    let n = write(socket, bytes.baseAddress! + sent, bytes.count - sent)
                    guard n > 0 else { return }
                    sent += n
                }
            }
        }
    }

    /// A stand-in for the payer: it keeps each exchange's frame, in the
    /// order they come, answers each whose route it has an answer for, and
    /// hands on the rest, for the check to answer when it likes.
    final class StandIn: Sendable {
        let pending: AsyncStream<Far>
        private let hand: AsyncStream<Far>.Continuation
        private let kept = Mutex<[Far]>([])
        private let answers: Mutex<[String: String]>

        init(answers: [String: String] = [:]) {
            (pending, hand) = AsyncStream.makeStream()
            self.answers = Mutex(answers)
        }

        var frames: [Far] { kept.withLock { $0 } }
        var routes: [String] { frames.map(\.route) }

        func set(_ route: String, _ answer: String) {
            answers.withLock { $0[route] = answer }
        }

        /// Hands on the route's next exchanges, for the check to answer.
        func unset(_ route: String) {
            answers.withLock { $0[route] = nil }
        }

        var line: PayLine {
            { [self] ask, payload in
                var pair: [Int32] = [0, 0]
                guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw POSIXError(.EIO) }
                let (near, far) = (pair[0], pair[1])
                Thread { self.serve(far) }.start()
                return Pay.exchange(near, ask, payload)
            }
        }

        private func serve(_ socket: Int32) {
            var on: Int32 = 1
            setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            guard let (kind, payload) = Self.frame(socket) else {
                close(socket)
                return
            }
            let far = Far(kind: kind, payload: payload, socket: socket)
            kept.withLock { $0.append(far) }
            if let answer = answers.withLock({ $0[far.route] }) {
                far.answer(answer)
            } else {
                hand.yield(far)
            }
        }

        private static func frame(_ socket: Int32) -> (UInt8, Data)? {
            guard let head = exactly(socket, 5) else { return nil }
            let length = head.dropFirst().reduce(0) { $0 << 8 | Int($1) }
            guard let payload = length == 0 ? Data() : exactly(socket, length) else { return nil }
            return (head[head.startIndex], payload)
        }

        private static func exactly(_ socket: Int32, _ count: Int) -> Data? {
            var data = Data(count: count)
            var got = 0
            while got < count {
                let n = data.withUnsafeMutableBytes { read(socket, $0.baseAddress! + got, count - got) }
                guard n > 0 else { return nil }
                got += n
            }
            return data
        }
    }

    static let address = "0x" + String(repeating: "a1", count: 20)
    static let identity = String(repeating: "ab", count: 32)
    static let quoteID = String(repeating: "c3", count: 32)
    static let body = Data(#"{"model":"cheap","messages":[{"role":"user","content":"Name a calm colour."}],"stream":false}"#.utf8)

    static func view(note: Bool) -> String {
        note
            ? #"{"wallet":{"has_note":true,"pending_request":false,"note":{"note_id":7,"expiry_ts":1900000000}},"chain":{"block":24000000,"time":1800000000,"paused":false,"balance_wei":"3000000000000000","note":{"status":"active","expiry_ts":1900000000}}}"#
            : #"{"wallet":{"has_note":false,"pending_request":false},"chain":{"block":24000000,"time":1800000000,"paused":false,"balance_wei":"3000000000000000"}}"#
    }

    static func funding(_ phase: String) -> String {
        #"{"address":"\#(address)","chain_id":1,"eth_balance":"3000000000000000","amount":5000000,"phase":"\#(phase)","deposit_stage":"finalizing","transaction_hash":"0x01"}"#
    }

    static func withdrawal(_ phase: String) -> String {
        #"{"eth_balance":"3000000000000000","private_balance":5000000,"destination":"\#(address)","note_id":7,"phase":"\#(phase)","transaction_hash":"0x02"}"#
    }

    static func returning(_ phase: String) -> String {
        #"{"eth_balance":"3000000000000000","phase":"\#(phase)","destination":"0x\#(String(repeating: "b2", count: 20))","transaction_hash":"0x03"}"#
    }

    /// A deposit's quote as the payer gives it, its expiry in milliseconds.
    static func quote(expires: Int64) -> String {
        #"{"input_micro_usd":20000000,"id":"\#(quoteID)","kind":"deposit","amount":5000000,"principal_wei":"5000000000000000","required_fee_wei":"100000000000000","required_total_wei":"5100000000000000","shortfall_wei":"0","expires_at":\#(expires)}"#
    }

    static let models = #"{"object":"list","data":[{"id":"dear","oa_request_limit_micro_usd":9000},{"id":"cheap","oa_request_limit_micro_usd":2000}]}"#

    /// A deposit at rest: no note, nothing under way.
    static let atRest = [
        "V": view(note: false), "GET /admin/funding/address": funding("ready"), "GET /admin/withdrawal": withdrawal("no_note"),
        "GET /admin/return": returning("ready"),
    ]

    static func payer(_ standIn: StandIn) -> Payer {
        Payer(queue: PayQueue(line: standIn.line), running: { true }, expiry: nil, keep: { _ in }, chosen: { nil })
    }

    /// Returns once `condition` holds, as observed.
    static func until(_ condition: @escaping @MainActor () -> Bool) async {
        for await met in Observations(condition) where met { return }
    }

    @Test func openingRefreshingAndFollowingSendNoQuoteAndNoApprove() async {
        let standIn = StandIn(answers: [
            "V": Self.view(note: true), "GET /admin/funding/address": Self.funding("deposit_pending"),
            "GET /admin/withdrawal": Self.withdrawal("withdrawal_pending"), "GET /admin/return": Self.returning("return_pending"),
            "POST /admin/funding/deposit": Self.funding("confirming"), "POST /admin/withdrawal": Self.withdrawal("confirming"),
            "POST /admin/return": Self.returning("return_pending"),
        ])
        let payer = Self.payer(standIn)
        // The sheet opening, Refresh, and a round of following.
        for _ in 0..<3 { await payer.refresh() }

        #expect(payer.state == .depositing("finalizing"))
        #expect(!standIn.routes.contains { $0.contains("quote") || $0.contains("approve") })
        let follows = standIn.frames.filter { $0.route.hasPrefix("POST") }
        #expect(follows.count == 9)
        for far in follows {
            switch far.route {
            case "POST /admin/funding/deposit": #expect(far.body == ["amount": 5_000_000])
            case "POST /admin/withdrawal": #expect(far.body == ["destination": Self.address, "note_id": 7])
            case "POST /admin/return": #expect(far.call?.body == "")
            default: Issue.record("an unexpected call: \(far.route)")
            }
        }
    }

    @Test func anApproveIsSentOnlyFromConfirmAndNeverForAnExpiredQuote() async {
        let now = Int64(Date.now.timeIntervalSince1970 * 1000)
        var answers = Self.atRest
        answers["POST /admin/funding/quote"] = Self.quote(expires: now + 30_000)
        answers["POST /admin/funding/approve"] = Self.funding("deposit_pending")
        let standIn = StandIn(answers: answers)
        let payer = Self.payer(standIn)
        var approves: [PayTests.Far] { standIn.frames.filter { $0.route == "POST /admin/funding/approve" } }

        await payer.quoteDeposit(microUSD: 20_000_000)
        #expect(payer.review?.quote.id == Self.quoteID)
        payer.cancelReview()
        #expect(payer.review == nil)
        #expect(approves.isEmpty)

        await payer.quoteDeposit(microUSD: 20_000_000)
        await payer.confirm()
        #expect(approves.count == 1)
        #expect(approves.first?.body == ["quote_id": Self.quoteID])
        #expect(payer.review == nil)

        // A quote already past its 30 seconds is quoted again and shown,
        // never approved.
        standIn.set("POST /admin/funding/quote", Self.quote(expires: now - 1_000))
        await payer.quoteDeposit(microUSD: 20_000_000)
        let quotes = standIn.routes.count { $0 == "POST /admin/funding/quote" }
        await payer.confirm()
        #expect(approves.count == 1)
        #expect(standIn.routes.count { $0 == "POST /admin/funding/quote" } == quotes + 1)
        #expect(payer.review?.quote.expired(at: .now) == true)
    }

    /// A quote pressed while an approve is out leaves the approve's stop its
    /// own: one that got no answer may have sent a transaction.
    @Test func aStopIsAboutItsOwnPress() async throws {
        var answers = Self.atRest
        answers["POST /admin/funding/quote"] = Self.quote(expires: Int64(Date.now.timeIntervalSince1970 * 1000) + 30_000)
        let standIn = StandIn(answers: answers)
        let payer = Self.payer(standIn)
        var pending = standIn.pending.makeAsyncIterator()

        await payer.quoteDeposit(microUSD: 20_000_000)
        let confirming = Task { await payer.confirm() }
        let approve = try #require(await pending.next())
        #expect(approve.route == "POST /admin/funding/approve")

        await payer.quoteDeposit(microUSD: 20_000_000)
        #expect(payer.stop == nil)
        approve.end()
        await confirming.value
        if case .approve(let stop)? = payer.stop {
            #expect(stop.code == .ended)
        } else {
            Issue.record("the approve stopped as \(String(describing: payer.stop))")
        }

        // A quote that stops is a quote's.
        standIn.unset("POST /admin/funding/quote")
        let quoting = Task { await payer.quoteDeposit(microUSD: 20_000_000) }
        let quote = try #require(await pending.next())
        quote.end()
        await quoting.value
        if case .quote(let stop)? = payer.stop {
            #expect(stop.code == .ended)
        } else {
            Issue.record("the quote stopped as \(String(describing: payer.stop))")
        }
        payer.cancelReview()
    }

    /// Refresh, and the read asked for as Cloak starts or pauses, read now.
    /// One asked for while a round is out reads as soon as it ends; one asked
    /// for while the loop waits cuts the wait short. One round at a time.
    @Test func aCallToReadNowCutsTheWaitShortOneRoundAtATime() async throws {
        // Every read but the deposit's, which the check answers, so each
        // round shows as it goes; the deposit on its way keeps the loop on.
        let standIn = StandIn(answers: [
            "GET /admin/funding/address": Self.funding("deposit_pending"), "GET /admin/withdrawal": Self.withdrawal("no_note"),
            "GET /admin/return": Self.returning("ready"), "POST /admin/funding/deposit": Self.funding("deposit_pending"),
        ])
        let payer = Self.payer(standIn)
        var pending = standIn.pending.makeAsyncIterator()
        var rounds: Int { standIn.routes.count { $0 == "V" } }

        // Well inside the 10 seconds the loop waits.
        let soon = Duration.seconds(5)
        payer.follow()
        let first = try #require(await pending.next())
        payer.follow()
        payer.follow()
        var asked = ContinuousClock.now
        first.answer(Self.view(note: false))
        let second = try #require(await pending.next())
        #expect(ContinuousClock.now - asked < soon)
        second.answer(Self.view(note: false))
        await Self.until { !payer.reading }
        #expect(rounds == 2)
        #expect(payer.state == .depositing("finalizing"))

        asked = ContinuousClock.now
        payer.follow()
        let third = try #require(await pending.next())
        #expect(ContinuousClock.now - asked < soon)
        #expect(rounds == 3)

        // At rest, the loop ends.
        standIn.set("GET /admin/funding/address", Self.funding("ready"))
        third.answer(Self.view(note: false))
        await Self.until { !payer.reading }
        #expect(payer.state == .none)
        #expect(rounds == 3)
    }

    /// A round's reads begun before an approve's answer can't put back the
    /// funding the approve replaced; the approve's own read comes after.
    @Test func aReadBegunBeforeAnApprovesAnswerDoesNotLandOverIt() async throws {
        var answers = Self.atRest
        answers["POST /admin/funding/quote"] = Self.quote(expires: Int64(Date.now.timeIntervalSince1970 * 1000) + 30_000)
        let standIn = StandIn(answers: answers)
        let payer = Self.payer(standIn)
        var pending = standIn.pending.makeAsyncIterator()

        await payer.quoteDeposit(microUSD: 20_000_000)
        await Self.until { !payer.reading }
        #expect(payer.state == .none)

        // The next round's funding read waits for the check.
        standIn.unset("GET /admin/funding/address")
        payer.follow()
        let older = try #require(await pending.next())
        #expect(older.route == "GET /admin/funding/address")
        // Reads from here show the deposit sent; the round after waits on
        // its "V" for the check.
        standIn.set("GET /admin/funding/address", Self.funding("deposit_pending"))
        standIn.set("POST /admin/funding/deposit", Self.funding("deposit_pending"))
        standIn.unset("V")

        let confirming = Task { await payer.confirm() }
        let approve = try #require(await pending.next())
        #expect(approve.route == "POST /admin/funding/approve")
        approve.answer(Self.funding("deposit_pending"))
        await confirming.value
        #expect(payer.state == .depositing("finalizing"))

        older.answer(Self.funding("ready"))
        let next = try #require(await pending.next())
        #expect(next.route == "V")
        #expect(payer.funding?.phase == "deposit_pending")
        #expect(payer.state == .depositing("finalizing"))

        // At rest, the loop ends.
        standIn.set("GET /admin/funding/address", Self.funding("ready"))
        standIn.set("V", Self.view(note: false))
        next.answer(Self.view(note: false))
        await Self.until { !payer.reading }
    }

    @Test func aDepositsFeeAndTotalAreShownInDollarsAtTheQuotesOwnRate() async {
        var answers = Self.atRest
        answers["POST /admin/funding/quote"] = Self.quote(expires: Int64(Date.now.timeIntervalSince1970 * 1000) + 30_000)
        let payer = Self.payer(StandIn(answers: answers))

        await payer.quoteDeposit(microUSD: 20_000_000)
        // 20 dollars bought 0.005 ETH, so a fee of 0.0001 ETH is 40 cents.
        let quote = payer.review?.quote
        #expect(quote?.dollars(wei: "100000000000000") == Decimal(string: "0.4"))
        #expect(quote?.dollars(wei: "5100000000000000") == Decimal(string: "20.4"))
    }

    @Test func twoPressesSendTwoRequests() async throws {
        let standIn = StandIn(answers: ["GET /v1/models": Self.models, "R": SendTests.said("Bubbles.")])
        let payer = Self.payer(standIn)
        let conversation = SendTests.conversation
        let turn = conversation.turns[2].id
        async let first = payer.send(turn, in: conversation, identity: Self.identity)
        async let second = payer.send(turn, in: conversation, identity: Self.identity)
        #expect(try await [first, second] == ["Bubbles.", "Bubbles."])
        let requests = standIn.frames.compactMap(\.request)
        #expect(requests.map(\.identity) == [Self.identity, Self.identity])
        let bodies = requests.map { try? JSONSerialization.jsonObject(with: Data($0.body.utf8)) as? NSDictionary }
        #expect(bodies.count == 2 && bodies[0] != nil && bodies[0] == bodies[1])
    }

    @Test func oneRequestIsOutAtATimeAndTheOwnersGoFirst() async throws {
        let standIn = StandIn()
        let queue = PayQueue(line: standIn.line)
        var pending = standIn.pending.makeAsyncIterator()
        let first = Task { try await queue.complete(Self.body, identity: "door 1", rank: .door) }
        let out = try #require(await pending.next())
        #expect(out.request?.identity == "door 1")

        let second = Task { try await queue.complete(Self.body, identity: "door 2", rank: .door) }
        let third = Task { try await queue.complete(Self.body, identity: "owner", rank: .owner) }
        await Self.until { queue.waiting == 2 }
        #expect(standIn.frames.count == 1)

        out.answer(SendTests.said("one"))
        let next = try #require(await pending.next())
        #expect(next.request?.identity == "owner")
        #expect(standIn.frames.count == 2)

        next.answer(SendTests.said("two"))
        let last = try #require(await pending.next())
        #expect(last.request?.identity == "door 2")
        last.answer(SendTests.said("three"))

        _ = try await (first.value, second.value, third.value)
        #expect(!queue.sending)
    }

    @Test func aRequestBeingSentIsNotCutForAnother() async throws {
        let standIn = StandIn()
        let queue = PayQueue(line: standIn.line)
        var pending = standIn.pending.makeAsyncIterator()
        let door = Task { try await queue.complete(Self.body, identity: "door", rank: .door) }
        let out = try #require(await pending.next())

        let owner = Task { try await queue.complete(Self.body, identity: "owner", rank: .owner) }
        await Self.until { queue.waiting == 1 }
        #expect(queue.sending)
        #expect(standIn.frames.count == 1)

        out.answer(SendTests.said("the door's"))
        #expect(try await door.value == Data(SendTests.said("the door's").utf8))
        let next = try #require(await pending.next())
        #expect(next.request?.identity == "owner")
        next.answer(SendTests.said("the owner's"))
        #expect(try await owner.value == Data(SendTests.said("the owner's").utf8))
    }

    @Test func aHoldThatGoesQuietEndsAtTheLimitWithNothingSent() async throws {
        let standIn = StandIn()
        let queue = PayQueue(line: standIn.line, hold: .milliseconds(300))
        var pending = standIn.pending.makeAsyncIterator()
        let request = Task { try await queue.complete(Self.body, identity: Self.identity, rank: .owner) }
        let far = try #require(await pending.next())

        far.held(true)
        await Self.until { queue.held }
        // The Mac hangs up at the limit, which the payer takes as the
        // request's cancel, before its key is asked for.
        await far.hungUp()
        let stop = await #expect(throws: PayStop.self) { try await request.value }
        #expect(stop?.code == .heldTooLong)
        #expect(standIn.frames.count == 1)
        #expect(!queue.sending)
    }

    /// Beside the phase not known, another record waits for its follow
    /// call, which is not made either.
    @Test(arguments: [("migrating", "withdrawal_pending"), ("active", "mystery")])
    func aPhaseNotKnownMakesNoCall(funding: String, withdrawal: String) async {
        let standIn = StandIn(answers: [
            "V": Self.view(note: true), "GET /admin/funding/address": Self.funding(funding),
            "GET /admin/withdrawal": Self.withdrawal(withdrawal), "GET /admin/return": Self.returning("return_pending"),
        ])
        let payer = Self.payer(standIn)
        await payer.refresh()
        #expect(payer.state == .failed(funding == "migrating" ? funding : withdrawal))
        #expect(!standIn.routes.contains { $0.hasPrefix("POST") })
    }

    @Test func aRequestFrameCarriesOnlyIdentityAndBody() async throws {
        let standIn = StandIn(answers: ["GET /v1/models": Self.models, "R": SendTests.said("Bubbles.")])
        let payer = Self.payer(standIn)
        let conversation = SendTests.conversation
        #expect(try await payer.send(conversation.turns[2].id, in: conversation, identity: Self.identity) == "Bubbles.")

        let frame = try #require(standIn.frames.first { $0.route == "R" })
        let request = try #require(JSONSerialization.jsonObject(with: frame.payload) as? [String: Any])
        #expect(Set(request.keys) == ["identity", "body"])
        #expect(request["identity"] as? String == Self.identity)
        let sent = try #require(request["body"] as? String)
        let body = try #require(JSONSerialization.jsonObject(with: Data(sent.utf8)) as? [String: Any])
        #expect(Set(body.keys) == ["model", "messages", "stream"])
        // With none chosen, the model whose requests cost least at most.
        #expect(body["model"] as? String == "cheap")
        #expect(body["messages"] as? [[String: String]] == [
            ["role": "user", "content": "Name a calm colour."],
            ["role": "assistant", "content": "Sage green."],
            ["role": "user", "content": "Suggest a goldfish name."],
        ])
        for text in conversation.turns.map(\.original) + ["Skip this."] {
            #expect(frame.payload.range(of: Data(text.utf8)) == nil)
        }
    }

    @Test func aRewordingThatStopsSendsNoRequest() async throws {
        let folder = URL(filePath: "/tmp").appending(path: "cloak-pay-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: folder) }
        // A request sent would be answered, so one sent too soon shows.
        let standIn = StandIn(answers: ["GET /v1/models": Self.models, "R": SendTests.said("Sent too soon.")])
        let door = Door(
            file: folder.appending(path: "apps"), wallet: folder.appending(path: "wallet"),
            parts: Door.Parts(
                reword: { _ throws(RewriteStop) in throw .refused }, queue: PayQueue(line: standIn.line),
                exchange: { _, _ in throw POSIXError(.EIO) }, wallet: { nil }, key: { Data() }, sealing: { nil }),
            port: { 0 })
        await door.open()
        await Self.until { door.state != .closed }
        try #require(door.state == .open)
        let pass = try #require(door.pass(for: UUID(), paying: .zkapi))

        var pair: [Int32] = [0, 0]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        door.accept(guest: pair[0])
        let message = #"{"model":"cheap","messages":[{"role":"user","content":"um so what colour is calm"}]}"#
        let request = Data(
            ("POST /v1/chat/completions HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer \(pass)\r\n"
                + "Content-Type: application/json\r\nContent-Length: \(message.utf8.count)\r\n\r\n\(message)").utf8)
        let response = String(decoding: await Self.ask(pair[1], request), as: UTF8.self)

        #expect(response.hasPrefix("HTTP/1.1 502"))
        #expect(response.contains("rewrite_failed"))
        #expect(standIn.routes == ["GET /v1/models"])
        await door.close()
    }

    /// An app that leaves while its request is reworded, before it is sent,
    /// is not charged, whichever way the request would be paid: nothing
    /// reaches the payer or the Tempo wallet's sender but the list of
    /// models, and its line says it left with nothing paid.
    @Test(.timeLimit(.minutes(1)), arguments: [Payment.zkapi, .tempo])
    func anAppThatLeavesBeforeItsRequestIsSentIsNotCharged(paying payment: Payment) async throws {
        let folder = URL(filePath: "/tmp").appending(path: "cloak-pay-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: folder) }
        // A request sent either way would be answered, so one sent shows.
        let payer = StandIn(answers: ["GET /v1/models": Self.models, "R": SendTests.said("Paid for nothing.")])
        let models = try JSONSerialization.data(withJSONObject: ["ok": ["models": Self.models]])
        let sender = SendTests.StandIn { request in
            request["op"] as? String == "models" ? models : SendTests.completed(SendTests.said("Paid for nothing."))
        }
        let address = Self.address
        let (rewording, began) = AsyncStream<Void>.makeStream()
        let door = Door(
            file: folder.appending(path: "apps"), wallet: folder.appending(path: "wallet"),
            parts: Door.Parts(
                reword: { _ throws(RewriteStop) in
                    began.yield()
                    // Until the door ends it.
                    try? await Task.sleep(for: .seconds(600))
                    throw .cancelled
                },
                queue: PayQueue(line: payer.line), exchange: sender.exchange, wallet: { address },
                key: { SendTests.walletKey }, sealing: { SymmetricKey(size: .bits256) }),
            port: { 0 })
        await door.open()
        await Self.until { door.state != .closed }
        try #require(door.state == .open)
        let pass = try #require(door.pass(for: UUID(), paying: payment))

        var pair: [Int32] = [0, 0]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        door.accept(guest: pair[0])
        let message = #"{"model":"cheap","messages":[{"role":"user","content":"um so what colour is calm"}]}"#
        let request = Data(
            ("POST /v1/chat/completions HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer \(pass)\r\n"
                + "Content-Type: application/json\r\nContent-Length: \(message.utf8.count)\r\n\r\n\(message)").utf8)
        request.withUnsafeBytes { _ = write(pair[1], $0.baseAddress, $0.count) }
        var started = rewording.makeAsyncIterator()
        await started.next()
        // The app leaves.
        close(pair[1])

        await Self.until { door.requests.first?.stage == .left(paid: false) }
        await door.close()
        #expect(payer.routes == (payment == .zkapi ? ["GET /v1/models"] : []))
        #expect(sender.read.map { $0["op"] as? String } == (payment == .tempo ? ["models"] : []))
    }

    /// Writes `request` on `socket`, then reads until the other end closes,
    /// on a thread of its own, so the door goes on meanwhile; closes it.
    static func ask(_ socket: Int32, _ request: Data) async -> Data {
        await withCheckedContinuation { done in
            Thread {
                defer { close(socket) }
                request.withUnsafeBytes { _ = write(socket, $0.baseAddress, $0.count) }
                var response = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let n = read(socket, &buffer, buffer.count)
                    guard n > 0 else { break }
                    response.append(contentsOf: buffer[..<n])
                }
                done.resume(returning: response)
            }.start()
        }
    }
}
