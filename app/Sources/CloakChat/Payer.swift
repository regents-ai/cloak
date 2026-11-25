import Foundation
import Observation
import os

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
        /// With the address and the amount typed, to quote again: the
        /// amount in wei as a decimal string, or empty for all of the
        /// address's ETH less the fee, as the payer takes it.
        case transfer(PayQuote, to: String, wei: String)

        public var quote: PayQuote {
            switch self {
            case .deposit(let quote, _), .withdrawal(let quote), .transfer(let quote, _, _): quote
            }
        }

        /// The payer's name for the route that quoted it.
        var route: String {
            switch self {
            case .deposit: "funding"
            case .withdrawal: "withdrawal"
            case .transfer: "return"
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
        case nothingToTransfer
        case activeDeposit
        case pendingTransaction
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
    /// What the provider's public list says each model costs, by model; nil
    /// until read. Shown beside the models, and used for nothing else: a
    /// request is charged what the service measures.
    public private(set) var prices: [String: PayPrice]?
    /// The quote shown for its owner to confirm.
    public private(set) var review: Review?
    /// Why the last read stopped; nil once one works.
    public private(set) var readStop: PayStop?
    /// Which wallet section triggered `stop`, so the UI displays the error right
    /// next to the button the user clicked instead of off-screen at the top.
    public enum StopTarget: Equatable, Sendable {
        case deposit
        case withdrawal
        case transfer
    }

    /// Why the last press stopped; nil once one works.
    public private(set) var stop: Stop?
    /// Which section's press produced `stop`, so the error renders inline there.
    public private(set) var stopTarget: StopTarget?
    /// The expiry kept on the Mac, for while Cloak is paused.
    public private(set) var savedExpiry: Date?
    /// Active wallet press in flight so UI rows can show inline progress right
    /// beside the button that was clicked instead of only a footer spinner.
    public enum Activity: Equatable, Sendable {
        case quotingDeposit
        case quotingWithdrawal
        case quotingTransfer
        case approvingDeposit
        case approvingWithdrawal
        case approvingTransfer
    }

    /// Presses under way: quotes and approves.
    public private(set) var working = 0
    /// The specific quote or approval currently in flight, if any.
    public private(set) var activity: Activity?
    @ObservationIgnored private let running: @MainActor () -> Bool
    @ObservationIgnored private let keep: @MainActor (Date?) -> Void
    @ObservationIgnored private let chosen: @MainActor () -> String?
    private var reads = Reads.idle
    /// Approves answered so far. A read lands only if none was answered
    /// while it was out: what it read may be older than what the approve
    /// set.
    @ObservationIgnored private var approved = 0
    /// Monotonic counter incremented on cancel/new quote so an earlier
    /// in-flight quote returning over Tor can never resurrect a cancelled review.
    @ObservationIgnored private var quoteGeneration: UInt64 = 0
    /// Quotes currently being approved, preventing accidental double-approves
    /// of the exact same quote id.
    @ObservationIgnored private var approving: Set<String> = []
    @ObservationIgnored private let logger = Logger(subsystem: "sh.regents.cloak.app", category: "payer")
    private static let posix = Locale(identifier: "en_US_POSIX")

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
        if stop == .unread {
            stop = nil
            stopTarget = nil
        }
        guard running() else {
            state = .unread
            (funding, withdrawal, returning, view, readStop) = (nil, nil, nil, nil, nil)
            (models, prices) = (nil, nil)
            // A quote can't be approved while Cloak is not running, and stale
            // errors from a prior session must not mask fresh reads on restart.
            quoteGeneration &+= 1
            review = nil
            stop = nil
            stopTarget = nil
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
            pruneStaleReview()
            let expiry: Date? = state == .taken
                ? nil
                : view.wallet.note.map { Date(timeIntervalSince1970: TimeInterval($0.expiryTs)) }
            if expiry != savedExpiry {
                savedExpiry = expiry
                keep(expiry)
            }
        } catch {
            logger.error("anon-v refresh stopped: \(error.code.rawValue, privacy: .public) — \(error.detail, privacy: .public)")
            readStop = error
            // Keep the last valid view on transient read errors so safety
            // blocks and withdrawal quotes don't break on a brief Tor hiccup.
            return
        }
        if case .failed = state { return }
        let transitioned = await carryOn(allowRevertReset: false)
        if transitioned {
            // Re-read full wallet/chain state right after a deposit activates,
            // a withdrawal completes, or a transfer finalizes so `view`,
            // `funding.ethBalance`, `savedExpiry`, and `state` stay in sync.
            await refreshAfterTransition()
        }
    }

    /// Lightweight full state sync after `carryOn()` reports a terminal phase
    /// transition (e.g., deposit activated or withdrawal/transfer completed).
    private func refreshAfterTransition() async {
        guard running() else { return }
        let approved = approved
        do throws(PayStop) {
            let view = try await queue.view(chain: true)
            let funding: FundingStatus = try decode(await queue.call("GET", "/admin/funding/address"))
            let withdrawal: WithdrawalStatus = try decode(await queue.call("GET", "/admin/withdrawal"))
            let returning: ReturnStatus = try decode(await queue.call("GET", "/admin/return"))
            guard self.approved == approved else { return }
            (self.view, self.funding, self.withdrawal, self.returning, readStop) = (view, funding, withdrawal, returning, nil)
            settle()
            pruneStaleReview()
            let expiry: Date? = state == .taken
                ? nil
                : view.wallet.note.map { Date(timeIntervalSince1970: TimeInterval($0.expiryTs)) }
            if expiry != savedExpiry {
                savedExpiry = expiry
                keep(expiry)
            }
        } catch {
            logger.error("zkapi post-transition refresh stopped: \(error.code.rawValue, privacy: .public) — \(error.detail, privacy: .public)")
            readStop = error
        }
    }

    /// Clears a review quote when live chain/daemon state proves it is already
    /// superseded (e.g. a timed-out approve actually broadcast on-chain).
    private func pruneStaleReview() {
        guard let review else { return }
        switch review {
        case .deposit:
            if case .depositing = state { self.review = nil }
            else if state == .ready || state == .settling { self.review = nil }
        case .withdrawal:
            if case .withdrawing(let phase) = state, phase != "quoted" && phase != "reverted" { self.review = nil }
            else if state == .none || state == .taken { self.review = nil }
        case .transfer:
            if returning?.phase == "return_pending" { self.review = nil }
        }
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
            guard ["pending", "fee_wait", "finalizing", "activating", "failed_finalizing"].contains(stage) else { return .failed(stage) }
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
        case "quoted", "waiting_funds", "withdrawal_pending", "confirming", "reverted":
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
    /// call never signs anew. Returns `true` when any in-flight operation
    /// reached a terminal phase requiring a full `refresh()` of `view` and balances.
    @discardableResult
    private func carryOn(allowRevertReset: Bool) async -> Bool {
        let approved = approved
        var transitioned = false
        do throws(PayStop) {
            if let funding,
                (["deposit_pending", "confirming"].contains(funding.phase) || (allowRevertReset && funding.phase == "reverted")),
                let amount = funding.amount
            {
                let answer: FundingStatus = try decode(await queue.call("POST", "/admin/funding/deposit", body: json(["amount": amount])))
                guard self.approved == approved else { return false }
                let oldPhase = funding.phase
                self.funding = answer
                if answer.phase != oldPhase && !["deposit_pending", "confirming"].contains(answer.phase) {
                    transitioned = true
                }
            }
            if let withdrawal, ["withdrawal_pending", "confirming"].contains(withdrawal.phase),
                let destination = withdrawal.destination, let note = withdrawal.noteId
            {
                let answer: WithdrawalStatus = try decode(
                    await queue.call("POST", "/admin/withdrawal", body: json(["destination": destination, "note_id": note])))
                guard self.approved == approved else { return false }
                let oldPhase = withdrawal.phase
                self.withdrawal = answer
                if answer.phase != oldPhase && !["withdrawal_pending", "confirming"].contains(answer.phase) {
                    transitioned = true
                }
            }
            if returning?.phase == "return_pending" {
                let answer: ReturnStatus = try decode(await queue.call("POST", "/admin/return"))
                guard self.approved == approved else { return false }
                returning = answer
                if answer.phase != "return_pending" {
                    transitioned = true
                }
            }
            // Only settle immediately when no terminal transition occurred;
            // terminal transitions immediately re-read `view` + balances first
            // so `settle()` never computes `.none`/`.ready` against stale `view`.
            if !transitioned {
                settle()
            }
        } catch {
            logger.error("anon-v follow stopped: \(error.code.rawValue, privacy: .public) — \(error.detail, privacy: .public)")
            readStop = error
        }
        return transitioned
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
            } else if running(), moving || (readStop == nil && review.map({ !$0.quote.expired(at: .now) }) == true) {
                // Keep polling while money is moving even across a transient
                // Tor/RPC error (back off slightly to 15s on read error) so an
                // in-flight deposit, withdrawal, or transfer is never abandoned.
                let delay = readStop == nil ? 10 : 15
                let nap = Task { _ = try? await Task.sleep(for: .seconds(delay)) }
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

    /// Money is on its way: a deposit, a withdrawal, a send settling, or the
    /// funding address's ETH being sent out.
    public var moving: Bool {
        switch state {
        case .depositing, .withdrawing, .settling: true
        case .failed: false
        default: returning?.phase == "return_pending"
        }
    }

    /// Makes the follow calls of a state that stopped, where the payer
    /// allows a resume: Try Again.
    public func retry() async {
        stop = nil
        stopTarget = nil
        let transitioned = await carryOn(allowRevertReset: true)
        if transitioned {
            await refreshAfterTransition()
        }
        follow()
    }

    // MARK: Presses

    /// Quotes a deposit of `microUSD` millionths of a dollar, priced by the
    /// payer, and shows it for review.
    public func quoteDeposit(microUSD: UInt64) async {
        await quote(.quotingDeposit, target: .deposit) { () throws(PayStop) in
            .deposit(try decode(await queue.call("POST", "/admin/funding/quote", body: json(["micro_usd": microUSD]))), microUSD: microUSD)
        }
    }

    /// Quotes the withdrawal of the whole deposit to the payer's own funding
    /// address (decision 23), and shows it for review. With no deposit read,
    /// nothing is asked, and the stop says so.
    public func quoteWithdrawal() async {
        let note: UInt64? = view?.wallet.note.map { UInt64($0.noteId) } ?? withdrawal?.noteId
        guard let address = funding?.address, let note else {
            stop = .unread
            stopTarget = .withdrawal
            return
        }
        var payload: [String: Any] = ["destination": address, "note_id": note]
        if withdrawal?.phase == "reverted", let txHash = withdrawal?.transactionHash, !txHash.isEmpty {
            payload["retry_transaction_hash"] = txHash
        }
        await quote(.quotingWithdrawal, target: .withdrawal) { () throws(PayStop) in
            .withdrawal(try decode(await queue.call(
                "POST", "/admin/withdrawal/quote", body: json(payload))))
        }
    }

    /// Quotes sending `wei` of the funding address's ETH to `destination`,
    /// or all of it less the fee when `wei` is empty, and shows it for
    /// review.
    public func quoteTransfer(to destination: String, wei: String) async {
        await quote(.quotingTransfer, target: .transfer) { () throws(PayStop) in
            .transfer(
                try decode(await queue.call(
                    "POST", "/admin/return/quote", body: json(["destination": destination, "amount_wei": wei]))),
                to: destination, wei: wei)
        }
    }

    private func quote(_ kind: Activity, target: StopTarget, _ make: () async throws(PayStop) -> Review) async {
        // Never allow overlapping wallet quotes or approvals to clobber `activity`
        // or the daemon's single active quote slot.
        guard activity == nil else { return }
        quoteGeneration &+= 1
        let gen = quoteGeneration
        stop = nil
        stopTarget = nil
        working += 1
        activity = kind
        defer {
            working -= 1
            if activity == kind { activity = nil }
        }
        do {
            let next = try await make()
            // Ignore late response if user cancelled or paused while waiting over Tor.
            guard quoteGeneration == gen, running() else { return }
            review = next
            follow()
        } catch {
            guard quoteGeneration == gen else { return }
            logger.error("zkapi quote stopped: \(error.code.rawValue, privacy: .public) — \(error.detail, privacy: .public)")
            stop = .quote(error)
            stopTarget = target
        }
    }

    /// Its owner's press on the review's button, the one place an approve
    /// is sent from: approves the quote shown, or, once it has expired,
    /// quotes it again and shows that, unapproved. Each press is sent.
    public func confirm() async {
        guard activity == nil, let review else { return }
        let quote = review.quote
        guard !quote.expired(at: .now) else {
            switch review {
            case .deposit(_, let microUSD): await quoteDeposit(microUSD: microUSD)
            case .withdrawal: await quoteWithdrawal()
            case .transfer(_, let destination, let wei): await quoteTransfer(to: destination, wei: wei)
            }
            return
        }
        guard !approving.contains(quote.id) else { return }
        approving.insert(quote.id)
        defer { approving.remove(quote.id) }
        stop = nil
        stopTarget = nil
        working += 1
        let approveActivity: Activity = switch review {
        case .deposit: .approvingDeposit
        case .withdrawal: .approvingWithdrawal
        case .transfer: .approvingTransfer
        }
        let target: StopTarget = switch review {
        case .deposit: .deposit
        case .withdrawal: .withdrawal
        case .transfer: .transfer
        }
        activity = approveActivity
        defer {
            working -= 1
            if activity == approveActivity { activity = nil }
        }
        do throws(PayStop) {
            let answer = try await queue.call(
                "POST", "/admin/\(review.route)/approve", body: json(["quote_id": quote.id]), limit: PayLimit.approve)
            switch review {
            case .deposit: funding = try decode(answer)
            case .withdrawal: withdrawal = try decode(answer)
            case .transfer: returning = try decode(answer)
            }
            approved += 1
            if self.review == review { self.review = nil }
            settle()
        } catch {
            logger.error("zkapi approve stopped: \(error.code.rawValue, privacy: .public) — \(error.detail, privacy: .public)")
            // If the daemon rejected the quote as changed or expired before the
            // local 30s clock elapsed, immediately expire the local review so
            // the CTA switches straight to "New Quote" / "Update Fee".
            let lower = error.detail.lowercased()
            if (lower.contains("quote") && (lower.contains("expired") || lower.contains("changed"))),
                self.review == review
            {
                let expired = PayQuote(
                    inputMicroUsd: quote.inputMicroUsd, id: quote.id, kind: quote.kind, amount: quote.amount,
                    destination: quote.destination, noteId: quote.noteId, principalWei: quote.principalWei,
                    requiredFeeWei: quote.requiredFeeWei, requiredTotalWei: quote.requiredTotalWei,
                    shortfallWei: quote.shortfallWei, expiresAt: 0)
                switch review {
                case .deposit(_, let microUSD): self.review = .deposit(expired, microUSD: microUSD)
                case .withdrawal: self.review = .withdrawal(expired)
                case .transfer(_, let to, let wei): self.review = .transfer(expired, to: to, wei: wei)
                }
            }
            stop = .approve(error)
            stopTarget = target
        }
        follow()
    }

    /// Closes the review; nothing is approved.
    public func cancelReview() {
        quoteGeneration &+= 1
        review = nil
        if stopTarget != nil {
            stop = nil
            stopTarget = nil
        }
    }

    /// Clears why the last press stopped. Why the last read stopped stays
    /// until a read works.
    public func dismiss() {
        stop = nil
        stopTarget = nil
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

    /// Why Transfer is certain to fail now. Matches `ensureAddressReturnAllowed`
    /// in the guest payer so the UI disables Transfer instead of failing with 502.
    public var transferBlock: Block? {
        if returning?.phase == "return_pending" { return .pendingTransaction }
        if case .depositing = state { return .pendingTransaction }
        if case .withdrawing = state { return .pendingTransaction }
        if case .settling = state { return .pendingTransaction }
        if state != .taken && (view?.wallet.hasNote == true || view?.wallet.pendingRequest == true || state == .ready) {
            return .activeDeposit
        }
        guard let balance = view?.chain.flatMap({ Decimal(string: $0.balanceWei, locale: Self.posix) }) else { return nil }
        return balance == 0 ? .nothingToTransfer : nil
    }

    /// Why the review's button is certain to fail now: the address holds
    /// less than the quote needs.
    public func confirmBlock(_ review: Review) -> Block? {
        guard let chain = view?.chain, let balance = Decimal(string: chain.balanceWei, locale: Self.posix) else { return nil }
        switch review {
        case .deposit(let quote, _):
            if chain.paused { return .paused }
            guard let total = Decimal(string: quote.requiredTotalWei, locale: Self.posix), balance < total else { return nil }
            return .needs(total - balance)
        case .withdrawal(let quote):
            if chain.paused { return .paused }
            guard let fee = Decimal(string: quote.requiredFeeWei, locale: Self.posix), balance < fee else { return nil }
            return .needsFee
        case .transfer(let quote, _, _):
            guard let total = Decimal(string: quote.requiredTotalWei, locale: Self.posix), balance < total else { return nil }
            return .needs(total - balance)
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

    /// Reads what the models cost through the payer.
    public func loadPrices() async throws(PayStop) {
        struct List: Decodable { let data: [PayPrice] }
        let listed = try decode(await queue.call("GET", "/cloak/prices"), as: List.self).data
        prices = Dictionary(listed.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Preferred default models for Anon V when the user has not chosen one
    /// yet: starts with a strong, balanced frontier model (`claude-sonnet-5.5`,
    /// $2 hold — works out of the box with a $5 deposit) and falls through to
    /// widely recognized workhorse models.
    public static let preferredDefaults = [
        "anthropic/claude-sonnet-5.5",
        "anthropic/claude-haiku-5.5",
        "openai/gpt-5.6-terra",
        "openai/gpt-5.6-luna",
        "x-ai/grok-4.7",
        "google/gemini-3.8-flash",
        "deepseek/deepseek-v4.1-flash",
        "qwen/qwen3.8-flash",
    ]

    /// Curated top models surfaced in the "Recommended" section at the top of
    /// the Anon V model picker, spanning Tier 25 (best reasoning), Tier 5
    /// (flagship), Tier 3 (balanced frontier), and Tier 1 (fast & low-cost).
    public static let recommendedModels = [
        "anthropic/claude-fable-5.2",
        "anthropic/claude-opus-5.5",
        "anthropic/claude-sonnet-5.5",
        "openai/gpt-5.6-terra-pro",
        "openai/gpt-5.6-sol",
        "openai/gpt-5.6-terra",
        "x-ai/grok-4.7",
        "qwen/qwen3.8-max-prime",
        "anthropic/claude-haiku-5.5",
        "openai/gpt-5.6-luna",
        "google/gemini-3.8-flash",
        "deepseek/deepseek-v4.1-flash",
    ]

    /// The model V chats are answered with: the one its owner chose, while
    /// the service lists it; otherwise the first listed preferred default;
    /// otherwise the one whose requests cost least at most, the first such in
    /// the list. Nil before the list is read, or when it is empty.
    public var model: String? {
        guard let models else { return nil }
        if let chosen = chosen(), models.contains(where: { $0.id == chosen }) { return chosen }
        for candidate in Self.preferredDefaults where models.contains(where: { $0.id == candidate }) {
            return candidate
        }
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
