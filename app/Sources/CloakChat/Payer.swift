import Foundation
import Observation

/// V's wallet: the payer in the guest, seen from the Mac (decision 24 in
/// docs/plan.md, docs/zkapi-mac-side.md sections 1 to 3). The payer owns
/// every payment fact; this is a mirror of it, read fresh each time, with
/// one named state (`State`) computed from one read and never stored. The
/// Mac keeps one payment fact itself, the deposit's expiry, to warn while
/// Cloak is paused. Opening, reading and following send no quote and no
/// approve: a quote is made only by its owner's press, and an approve is
/// sent only by the press of a review's button showing that quote
/// (`confirm`), never for a quote that has expired. Every press is sent.
@MainActor
@Observable
public final class Payer {
    /// Where the deposit is, from one read of the payer and the chain.
    public enum State: Equatable, Sendable {
        /// Cloak is not running, or nothing has been read yet.
        case unread
        /// No deposit: the address can be funded, and a deposit made.
        case none
        /// A deposit is on its way, at the payer's stage of it.
        case depositing(String)
        case ready
        /// The last request's settlement is unfinished, and no request is
        /// out.
        case settling
        /// A withdrawal is on its way, at the payer's phase of it.
        case withdrawing(String)
        /// The chain shows the deposit closed, and no withdrawal of the
        /// payer's took it.
        case taken
        /// A phase or stage the Mac does not go on from, as the payer
        /// named it: it makes no call for it.
        case failed(String)
    }

    /// How near the deposit's expiry is.
    public enum Band: Sendable, Equatable {
        case far
        /// Within `warning` of it.
        case near
        /// Passed: anyone may send the deposit to the service's operator.
        case due
    }

    /// A quote shown to its owner: the one thing an approve is sent for.
    public enum Review: Sendable, Equatable {
        /// With the dollars asked for, to quote again.
        case deposit(PayQuote, microUSD: UInt64)
        case withdrawal(PayQuote)
        /// With the address typed, to quote again.
        case sendOut(PayQuote, to: String)

        public var quote: PayQuote {
            switch self {
            case .deposit(let quote, _), .withdrawal(let quote), .sendOut(let quote, _): quote
            }
        }

        /// The payer's name for the route that quoted it.
        var route: String {
            switch self {
            case .deposit: "funding"
            case .withdrawal: "withdrawal"
            case .sendOut: "return"
            }
        }
    }

    /// Why a money button is certain to fail now, from the chain at the
    /// latest block read. A read that failed, or none, blocks nothing.
    public enum Block: Sendable, Equatable {
        case paused
        case oneAtATime
        case nothingToWithdraw
        /// The address needs this much more, in wei.
        case needs(Decimal)
        case needsFee
        case nothingToSend
    }

    /// A press that stopped, as one value: what it had asked for, and why.
    /// Its words follow what it asked: a quote sends nothing, an approve may
    /// have sent a transaction.
    public enum Stop: Sendable, Equatable {
        /// A quote was asked for.
        case quote(PayStop)
        /// An approve was sent.
        case approve(PayStop)
        /// Withdraw was pressed with no deposit read, so nothing was asked.
        /// The next read answers it.
        case unread
    }

    /// Where V's reads are: one round at a time, in one loop.
    private enum Reads: Equatable {
        /// No loop.
        case idle
        /// A round under way; `again` when a read was asked for meanwhile,
        /// which starts as soon as the round ends.
        case reading(again: Bool)
        /// Waiting to read again; ending `nap` reads at once.
        case waiting(nap: Task<Void, Never>)
    }

    /// How far ahead of the expiry the warning starts.
    public static let warning: TimeInterval = 10 * 24 * 60 * 60

    public let queue: PayQueue
    public private(set) var state = State.unread
    public private(set) var funding: FundingStatus?
    public private(set) var withdrawal: WithdrawalStatus?
    public private(set) var returning: ReturnStatus?
    public private(set) var view: DepositView?
    /// The service's models, as the payer read them; nil until read.
    public private(set) var models: [PayModel]?
    /// The quote shown for its owner to confirm.
    public private(set) var review: Review?
    /// Why the last read stopped; nil once one works.
    public private(set) var readStop: PayStop?
    /// Why the last press stopped; nil once one works.
    public private(set) var stop: Stop?
    /// The expiry kept on the Mac, for while Cloak is paused.
    public private(set) var savedExpiry: Date?
    /// Presses under way: quotes and approves.
    public private(set) var working = 0
    @ObservationIgnored private let running: @MainActor () -> Bool
    @ObservationIgnored private let keep: @MainActor (Date?) -> Void
    @ObservationIgnored private let chosen: @MainActor () -> String?
    private var reads = Reads.idle
    /// Approves answered so far. A read lands only if none was answered
    /// while it was out: what it read may be older than what the approve
    /// set.
    @ObservationIgnored private var approved = 0

    /// `running` says whether Cloak is running; `expiry` is the expiry kept,
    /// and `keep` keeps a new one (nil, none); `chosen` is the model its
    /// owner chose for V chats, if any.
    public init(
        queue: PayQueue, running: @escaping @MainActor () -> Bool, expiry: Date?, keep: @escaping @MainActor (Date?) -> Void,
        chosen: @escaping @MainActor () -> String?
    ) {
        self.queue = queue
        self.running = running
        savedExpiry = expiry
        self.keep = keep
        self.chosen = chosen
    }

    // MARK: Reading

    /// Reads the deposit, the chain at one block, the funding address, the
    /// withdrawal and the leftover ETH, then makes the follow calls that
    /// carry a deposit, a withdrawal or a send on, as the payer allows them:
    /// with the amount and destination it saved, never a new one. What it
    /// read lands only if no approve was answered while it was out.
    public func refresh() async {
        // A press that stopped for want of a read is answered by this one.
        if stop == .unread { stop = nil }
        guard running() else {
            state = .unread
            (funding, withdrawal, returning, view, readStop) = (nil, nil, nil, nil, nil)
            // A quote can't be approved while Cloak is not running.
            review = nil
            return
        }
        let approved = approved
        do throws(PayStop) {
            let view = try await queue.view(chain: true)
            let funding: FundingStatus = try decode(await queue.call("GET", "/admin/funding/address"))
            let withdrawal: WithdrawalStatus = try decode(await queue.call("GET", "/admin/withdrawal"))
            let returning: ReturnStatus = try decode(await queue.call("GET", "/admin/return"))
            // The approve asked for a read of its own, which comes after.
            guard self.approved == approved else { return }
            (self.view, self.funding, self.withdrawal, self.returning, readStop) = (view, funding, withdrawal, returning, nil)
            settle()
            let expiry = view.wallet.note.map { Date(timeIntervalSince1970: TimeInterval($0.expiryTs)) }
            if expiry != savedExpiry {
                savedExpiry = expiry
                keep(expiry)
            }
        } catch {
            readStop = error
            // The chain is not known now, so it blocks no button.
            view = nil
            return
        }
        if case .failed = state { return }
        await carryOn()
    }

    /// The state, from the last read.
    private func settle() {
        guard let view, let funding, let withdrawal else { return }
        state = Self.state(view: view, funding: funding, withdrawal: withdrawal, sending: queue.sending)
    }

    /// The state one read gives. A phase or stage it does not know is
    /// `failed`, and nothing is guessed.
    public static func state(view: DepositView, funding: FundingStatus, withdrawal: WithdrawalStatus, sending: Bool) -> State {
        switch funding.phase {
        case "ready", "waiting_funds", "active", "withdrawal_pending", "return_pending":
            break
        case "approval_pending", "deposit_pending", "confirming":
            let stage = funding.depositStage ?? "pending"
            guard ["pending", "fee_wait", "finalizing", "activating"].contains(stage) else { return .failed(stage) }
            return .depositing(stage)
        default:
            return .failed(funding.phase)
        }
        switch withdrawal.phase {
        case "no_note", "ready", "complete":
            break
        case "waiting_settlement":
            // Without a saved destination it is only the last request settling.
            if withdrawal.destination != nil { return .withdrawing(withdrawal.phase) }
        case "quoted", "waiting_funds", "withdrawal_pending", "confirming":
            return .withdrawing(withdrawal.phase)
        default:
            return .failed(withdrawal.phase)
        }
        guard view.wallet.hasNote else { return .none }
        if view.chain?.note?.status == "closed" { return .taken }
        if view.wallet.pendingRequest && !sending { return .settling }
        return .ready
    }

    /// The follow calls the last read allows: a deposit sent or confirming,
    /// with its saved amount; a withdrawal sent or confirming, with its saved
    /// destination and note; a send of the leftover ETH under way. A follow
    /// call never signs anew. Each answer lands only if no approve was
    /// answered while it was out.
    private func carryOn() async {
        let approved = approved
        do throws(PayStop) {
            if let funding, ["deposit_pending", "confirming"].contains(funding.phase), let amount = funding.amount {
                let answer: FundingStatus = try decode(await queue.call("POST", "/admin/funding/deposit", body: json(["amount": amount])))
                guard self.approved == approved else { return }
                self.funding = answer
            }
            if let withdrawal, ["withdrawal_pending", "confirming"].contains(withdrawal.phase),
                let destination = withdrawal.destination, let note = withdrawal.noteId
            {
                let answer: WithdrawalStatus = try decode(
                    await queue.call("POST", "/admin/withdrawal", body: json(["destination": destination, "note_id": note])))
                guard self.approved == approved else { return }
                self.withdrawal = answer
            }
            if returning?.phase == "return_pending" {
                let answer: ReturnStatus = try decode(await queue.call("POST", "/admin/return"))
                guard self.approved == approved else { return }
                returning = answer
            }
            settle()
        } catch {
            readStop = error
        }
    }

    /// Reads now, and again every 10 seconds while a deposit, a withdrawal,
    /// a settlement or a send is on its way, or a quote is under review; one
    /// round at a time, in one loop. Asked while a round is under way, it
    /// reads again as soon as that round ends; asked while the loop waits,
    /// it cuts the wait short.
    public func follow() {
        switch reads {
        case .idle:
            reads = .reading(again: false)
            Task { await loop() }
        case .reading:
            reads = .reading(again: true)
        case .waiting(let nap):
            nap.cancel()
        }
    }

    private func loop() async {
        while true {
            await refresh()
            if reads == .reading(again: true) {
                reads = .reading(again: false)
            } else if moving {
                let nap = Task { _ = try? await Task.sleep(for: .seconds(10)) }
                reads = .waiting(nap: nap)
                await nap.value
                reads = .reading(again: false)
            } else {
                reads = .idle
                return
            }
        }
    }

    /// A round of reads is under way.
    public var reading: Bool {
        if case .reading = reads { true } else { false }
    }

    /// A quote under review counts while it holds: what its button waits
    /// for, ETH arriving at the address, shows as the chain does.
    private var moving: Bool {
        switch state {
        case .depositing, .withdrawing, .settling: true
        default: returning?.phase == "return_pending" || review.map { !$0.quote.expired(at: .now) } == true
        }
    }

    /// Makes the follow calls of a state that stopped, where the payer
    /// allows a resume: Try Again.
    public func retry() async {
        stop = nil
        await carryOn()
        follow()
    }

    // MARK: Presses

    /// Quotes a deposit of `microUSD` millionths of a dollar, priced by the
    /// payer, and shows it for review.
    public func quoteDeposit(microUSD: UInt64) async {
        await quote { () throws(PayStop) in
            .deposit(try decode(await queue.call("POST", "/admin/funding/quote", body: json(["micro_usd": microUSD]))), microUSD: microUSD)
        }
    }

    /// Quotes the withdrawal of the whole deposit to the payer's own funding
    /// address (decision 23), and shows it for review. With no deposit read,
    /// nothing is asked, and the stop says so.
    public func quoteWithdrawal() async {
        guard let address = funding?.address, let note = view?.wallet.note?.noteId else {
            stop = .unread
            return
        }
        await quote { () throws(PayStop) in
            .withdrawal(try decode(await queue.call(
                "POST", "/admin/withdrawal/quote", body: json(["destination": address, "note_id": note]))))
        }
    }

    /// Quotes sending all of the funding address's ETH to `destination`, and
    /// shows it for review.
    public func quoteSendOut(to destination: String) async {
        await quote { () throws(PayStop) in
            .sendOut(try decode(await queue.call(
                "POST", "/admin/return/quote", body: json(["destination": destination, "amount_wei": ""]))), to: destination)
        }
    }

    private func quote(_ make: () async throws(PayStop) -> Review) async {
        stop = nil
        working += 1
        defer { working -= 1 }
        do {
            review = try await make()
            follow()
        } catch {
            stop = .quote(error)
        }
    }

    /// Its owner's press on the review's button, the one place an approve
    /// is sent from: approves the quote shown, or, once it has expired,
    /// quotes it again and shows that, unapproved. Each press is sent.
    public func confirm() async {
        guard let review else { return }
        let quote = review.quote
        guard !quote.expired(at: .now) else {
            switch review {
            case .deposit(_, let microUSD): await quoteDeposit(microUSD: microUSD)
            case .withdrawal: await quoteWithdrawal()
            case .sendOut(_, let destination): await quoteSendOut(to: destination)
            }
            return
        }
        stop = nil
        working += 1
        defer { working -= 1 }
        do throws(PayStop) {
            let answer = try await queue.call(
                "POST", "/admin/\(review.route)/approve", body: json(["quote_id": quote.id]), limit: PayLimit.approve)
            switch review {
            case .deposit: funding = try decode(answer)
            case .withdrawal: withdrawal = try decode(answer)
            case .sendOut: returning = try decode(answer)
            }
            approved += 1
            if self.review == review { self.review = nil }
            settle()
        } catch {
            stop = .approve(error)
        }
        follow()
    }

    /// Closes the review; nothing is approved.
    public func cancelReview() {
        review = nil
    }

    /// Clears why the last press stopped. Why the last read stopped stays
    /// until a read works.
    public func dismiss() {
        stop = nil
    }

    // MARK: Buttons

    /// Why Deposit is certain to fail now.
    public var depositBlock: Block? {
        guard let chain = view?.chain else { return nil }
        if chain.paused { return .paused }
        if chain.note?.status == "active" { return .oneAtATime }
        return nil
    }

    /// Why Withdraw is certain to fail now.
    public var withdrawBlock: Block? {
        guard let chain = view?.chain else { return nil }
        if chain.paused { return .paused }
        if chain.note?.status != "active" { return .nothingToWithdraw }
        return nil
    }

    /// Why Send Out is certain to fail now.
    public var sendOutBlock: Block? {
        guard let balance = view?.chain.flatMap({ Decimal(string: $0.balanceWei) }) else { return nil }
        return balance == 0 ? .nothingToSend : nil
    }

    /// Why the review's button is certain to fail now: the address holds
    /// less than the quote needs.
    public func confirmBlock(_ review: Review) -> Block? {
        guard let chain = view?.chain, let balance = Decimal(string: chain.balanceWei) else { return nil }
        switch review {
        case .deposit(let quote, _):
            if chain.paused { return .paused }
            guard let total = Decimal(string: quote.requiredTotalWei), balance < total else { return nil }
            return .needs(total - balance)
        case .withdrawal(let quote):
            if chain.paused { return .paused }
            guard let fee = Decimal(string: quote.requiredFeeWei), balance < fee else { return nil }
            return .needsFee
        case .sendOut:
            return balance == 0 ? .nothingToSend : nil
        }
    }

    /// The deposit's expiry: as read, or as kept while Cloak is paused.
    public var expiry: Date? {
        view?.wallet.note.map { Date(timeIntervalSince1970: TimeInterval($0.expiryTs)) } ?? savedExpiry
    }

    public func band(at now: Date) -> Band? {
        guard let expiry else { return nil }
        if expiry <= now { return .due }
        return expiry.timeIntervalSince(now) <= Self.warning ? .near : .far
    }

    /// Whether the chain at the latest block read shows the deposit closed:
    /// then a V request is certain to stop.
    public var closed: Bool {
        view?.wallet.hasNote == true && view?.chain?.note?.status == "closed"
    }

    // MARK: Models

    /// Reads the service's models through the payer.
    public func loadModels() async throws(PayStop) {
        struct List: Decodable { let data: [PayModel] }
        models = try decode(await queue.call("GET", "/v1/models"), as: List.self).data
    }

    /// The model V chats are answered with: the one its owner chose, while
    /// the service lists it; otherwise the one whose requests cost least at
    /// most, the first such in the list. Nil before the list is read, or
    /// when it is empty.
    public var model: String? {
        guard let models else { return nil }
        if let chosen = chosen(), models.contains(where: { $0.id == chosen }) { return chosen }
        return models.min { $0.cap < $1.cap }?.id
    }

    /// The model for a request now, reading the list first when it has not
    /// been read.
    public func modelForSend() async throws(PayStop) -> String {
        if models == nil { try await loadModels() }
        guard let model else { throw PayStop(.modelUnavailable, "the service lists no model") }
        return model
    }

    // MARK: Sending

    /// Sends `turn`'s text as sent, after the conversation's earlier turns as
    /// sent and answered, as `identity`, in the owner's turn. Returns the
    /// model's answer.
    public func send(_ turn: UUID, in conversation: Conversation, identity: String) async throws(PayStop) -> String {
        guard let messages = Remote.messages(for: turn, in: conversation) else {
            throw PayStop(.failed, "the turn is not in the conversation")
        }
        let model = try await modelForSend()
        let body: Data
        do {
            body = try JSONSerialization.data(
                withJSONObject: ["model": model, "messages": messages, "stream": false], options: .withoutEscapingSlashes)
        } catch {
            throw PayStop(.failed, "cannot build the body: \(error)")
        }
        let completion = try await queue.complete(body, identity: identity, rank: .owner)
        do {
            return try Remote.content(of: completion)
        } catch {
            throw PayStop(error.code == .answerRefused ? .answerRefused : .providerFailed, error.detail)
        }
    }

    // MARK: Helpers

    private func decode<T: Decodable>(_ data: Data, as type: T.Type = T.self) throws(PayStop) -> T {
        do {
            return try JSONDecoder.pay.decode(type, from: data)
        } catch {
            throw PayStop(.failed, "an answer did not read as \(type): \(error)")
        }
    }

    private func json(_ object: [String: Any]) -> Data {
        // Only numbers and strings: it always serializes.
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }
}
