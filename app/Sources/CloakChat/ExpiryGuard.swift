import Foundation
import os

/// One scheduled macOS reminder before a zkAPI 30-day deposit expires.
public struct ExpiryReminder: Equatable, Sendable {
    public let id: String
    public let daysBefore: Int
    public let fireAt: Date
    public let title: String
    public let body: String

    public init(id: String, daysBefore: Int, fireAt: Date, title: String, body: String) {
        self.id = id
        self.daysBefore = daysBefore
        self.fireAt = fireAt
        self.title = title
        self.body = body
    }
}

/// Safeguards a Paranoid (V) zkAPI deposit against its 30-day contract expiry
/// (Decision R6b):
/// 1. Schedules native macOS reminders 10, 5, and 2 days before expiry
///    (days 20, 25, and 28 of a 30-day deposit) and clears them once withdrawn.
/// 2. When the user opts into auto-withdraw before expiry, triggers a single safe
///    withdrawal 3 days before expiry while Cloak is open, running, and idle —
///    only after verifying live Ethereum gas covers the conservative reserve so
///    `quoteWithdrawal()` never irreversibly freezes chat spending with a gas shortfall.
@MainActor
public final class ExpiryGuard {
    public struct Snapshot: Equatable, Sendable {
        public var expiry: Date?
        public var autoWithdraw: Bool
        public var state: Payer.State
        public var paused: Bool
        public var busy: Bool

        public init(expiry: Date?, autoWithdraw: Bool, state: Payer.State, paused: Bool, busy: Bool = false) {
            self.expiry = expiry
            self.autoWithdraw = autoWithdraw
            self.state = state
            self.paused = paused
            self.busy = busy
        }
    }

    public struct Parts: Sendable {
        public var now: @MainActor () -> Date
        /// Sleeps for `seconds`; returns `true` when the sleep completed and `false` if cancelled.
        public var sleep: @MainActor (TimeInterval) async -> Bool
        public var autoWithdrawEnabled: @MainActor () -> Bool
        public var depositExpires: @MainActor () -> Date?
        public var payerState: @MainActor () -> Payer.State
        public var withdrawBlock: @MainActor () -> Payer.Block?
        public var isBusy: @MainActor () -> Bool
        public var estimateWithdrawalFee: @MainActor () async -> WithdrawalFeeEstimate?
        /// Quotes the withdrawal; returns `true` when a `.withdrawal` review is ready.
        public var quoteWithdrawal: @MainActor () async -> Bool
        /// Checks whether the quoted withdrawal review is blocked (e.g. gas shortfall).
        public var withdrawalConfirmBlock: @MainActor () -> Payer.Block?
        public var cancelReview: @MainActor () -> Void
        /// Confirms the quoted withdrawal; returns `true` when follow-up attention is needed.
        public var confirmWithdrawal: @MainActor () async -> Bool
        /// Applies the desired pending reminders (empty clears all expiry reminders).
        public var syncNotifications: @MainActor ([ExpiryReminder]) -> Void
        public var notifyAttention: @MainActor (String) -> Void
        /// Formats wei as human-readable ETH (e.g. `"0.0019 ETH"`).
        public var formatWei: @MainActor (String) -> String?

        public init(
            now: @escaping @MainActor () -> Date = { .now },
            sleep: @escaping @MainActor (TimeInterval) async -> Bool = { seconds in
                (try? await Task.sleep(for: .seconds(seconds))) != nil
            },
            autoWithdrawEnabled: @escaping @MainActor () -> Bool,
            depositExpires: @escaping @MainActor () -> Date?,
            payerState: @escaping @MainActor () -> Payer.State,
            withdrawBlock: @escaping @MainActor () -> Payer.Block?,
            isBusy: @escaping @MainActor () -> Bool,
            estimateWithdrawalFee: @escaping @MainActor () async -> WithdrawalFeeEstimate?,
            quoteWithdrawal: @escaping @MainActor () async -> Bool,
            withdrawalConfirmBlock: @escaping @MainActor () -> Payer.Block?,
            cancelReview: @escaping @MainActor () -> Void,
            confirmWithdrawal: @escaping @MainActor () async -> Bool,
            syncNotifications: @escaping @MainActor ([ExpiryReminder]) -> Void,
            notifyAttention: @escaping @MainActor (String) -> Void,
            formatWei: @escaping @MainActor (String) -> String? = ExpiryGuard.defaultFormatWei
        ) {
            self.now = now
            self.sleep = sleep
            self.autoWithdrawEnabled = autoWithdrawEnabled
            self.depositExpires = depositExpires
            self.payerState = payerState
            self.withdrawBlock = withdrawBlock
            self.isBusy = isBusy
            self.estimateWithdrawalFee = estimateWithdrawalFee
            self.quoteWithdrawal = quoteWithdrawal
            self.withdrawalConfirmBlock = withdrawalConfirmBlock
            self.cancelReview = cancelReview
            self.confirmWithdrawal = confirmWithdrawal
            self.syncNotifications = syncNotifications
            self.notifyAttention = notifyAttention
            self.formatWei = formatWei
        }
    }

    public static let notificationIDs = [
        "sh.regents.cloak.expiry.10d",
        "sh.regents.cloak.expiry.5d",
        "sh.regents.cloak.expiry.2d",
    ]
    public static let autoWithdrawFailureID = "sh.regents.cloak.expiry.autowithdraw.failed"
    /// Automatically withdraw 3 days before expiry when opted in.
    public static let autoWithdrawLead: TimeInterval = 3 * 24 * 60 * 60

    private let parts: Parts
    private let logger = Logger(subsystem: "sh.regents.cloak.app", category: "expiry")
    private var watchTask: Task<Void, Never>?
    private var autoWithdrawTask: Task<Void, Never>?
    private var scheduledKey: (expiry: Date, paused: Bool)?
    /// True while `autoWithdrawTask` is actively executing `quoteWithdrawal()` /
    /// `confirmWithdrawal()`, so the resulting `.ready -> .withdrawing("quoted")` state
    /// transition never self-cancels our own in-flight confirmation.
    public private(set) var isExecutingAutoWithdraw = false
    /// The expiry timestamp we already attempted an automatic withdrawal for,
    /// so we never loop if a quote/withdrawal fails.
    public private(set) var attemptedExpiry: Date?

    public init(parts: Parts) {
        self.parts = parts
    }

    deinit {
        watchTask?.cancel()
        autoWithdrawTask?.cancel()
    }

    /// Attaches a lifecycle-managed observation task that feeds `handle(_:)` until `ExpiryGuard` deinitializes.
    public func attachWatch(_ task: Task<Void, Never>) {
        watchTask?.cancel()
        watchTask = task
    }

    /// Computes the remaining future expiry reminders (10, 5, and 2 days before expiry) at `now`.
    public static func reminders(for expiry: Date?, now: Date) -> [ExpiryReminder] {
        guard let expiry, expiry > now else { return [] }
        let formatted = expiry.formatted(date: .abbreviated, time: .omitted)
        let schedule: [(id: String, daysBefore: Int, title: String, body: String)] = [
            (
                notificationIDs[0], 10,
                "zkAPI deposit expires in 10 days",
                "Withdraw your unspent ETH in Cloak Funds before \(formatted)."
            ),
            (
                notificationIDs[1], 5,
                "zkAPI deposit expires in 5 days",
                "Open Cloak Funds and withdraw your deposit before \(formatted)."
            ),
            (
                notificationIDs[2], 2,
                "Action needed: zkAPI deposit expires in 2 days",
                "Withdraw now in Cloak Funds so unspent ETH isn't claimed after expiry."
            ),
        ]
        return schedule.compactMap { item in
            let fireAt = expiry.addingTimeInterval(-TimeInterval(item.daysBefore) * 24 * 60 * 60)
            guard fireAt > now else { return nil }
            return ExpiryReminder(id: item.id, daysBefore: item.daysBefore, fireAt: fireAt, title: item.title, body: item.body)
        }
    }

    /// Reacts to a change in expiry, opt-in toggle, payer state, or vault pause state.
    public func handle(_ snapshot: Snapshot) {
        parts.syncNotifications(Self.reminders(for: snapshot.expiry, now: parts.now()))
        scheduleAutoWithdraw(snapshot)
    }

    /// Cancels any pending auto-withdraw wait/estimate task (used by tests and shutdown).
    public func cancelPendingAutoWithdraw() {
        autoWithdrawTask?.cancel()
        autoWithdrawTask = nil
        scheduledKey = nil
    }

    /// Awaits completion of the currently scheduled auto-withdraw task, if any.
    public func waitForAutoWithdraw() async {
        await autoWithdrawTask?.value
    }

    /// Default wei-to-ETH formatter used when no UI-layer formatter is supplied.
    public static func defaultFormatWei(_ wei: String) -> String? {
        guard let parsed = Decimal(string: wei, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        let eth = Decimal(sign: .plus, exponent: -18, significand: parsed)
        return "\(eth.formatted(.number.precision(.fractionLength(0...6)))) ETH"
    }

    private func scheduleAutoWithdraw(_ snapshot: Snapshot) {
        // Never self-cancel while our own quoteWithdrawal -> confirm flow is
        // executing (quoteWithdrawal transitions `payer.state` from `.ready`
        // to `.withdrawing("quoted")`).
        if isExecutingAutoWithdraw { return }

        guard snapshot.autoWithdraw, let expiry = snapshot.expiry, snapshot.state == .ready else {
            autoWithdrawTask?.cancel()
            autoWithdrawTask = nil
            scheduledKey = nil
            return
        }
        guard attemptedExpiry != expiry else {
            autoWithdrawTask?.cancel()
            autoWithdrawTask = nil
            scheduledKey = nil
            return
        }

        // Keep an already-running watcher alive across transient `busy` flips
        // (e.g. an ordinary wallet refresh running concurrently with fee estimation).
        if autoWithdrawTask != nil,
            let key = scheduledKey,
            key.expiry == expiry,
            key.paused == snapshot.paused
        {
            return
        }

        autoWithdrawTask?.cancel()
        autoWithdrawTask = nil
        scheduledKey = (expiry, snapshot.paused)

        let withdrawAt = expiry.addingTimeInterval(-Self.autoWithdrawLead)
        let token = UUID()
        autoWithdrawTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.scheduledKey?.expiry == expiry, !self.isExecutingAutoWithdraw {
                    self.autoWithdrawTask = nil
                    self.scheduledKey = nil
                }
            }
            _ = token
            // Sleep in bounded chunks so system sleep/clock jumps wake promptly.
            while self.parts.now() < withdrawAt {
                guard !Task.isCancelled else { return }
                let remaining = withdrawAt.timeIntervalSince(self.parts.now())
                guard remaining > 0 else { break }
                let step = min(remaining, 3600)
                guard await self.parts.sleep(step), !Task.isCancelled else { return }
            }

            // Loop cleanly across transient busy overlaps (e.g. an ordinary wallet
            // refresh starting while `estimateWithdrawalFee()` is in flight) rather
            // than silently exiting without attempting or alerting.
            while !Task.isCancelled {
                guard self.parts.autoWithdrawEnabled(),
                    self.parts.payerState() == .ready,
                    self.parts.depositExpires() == expiry
                else {
                    return
                }
                if self.parts.isBusy() {
                    guard await self.parts.sleep(15), !Task.isCancelled else { return }
                    continue
                }
                if self.parts.withdrawBlock() == .paused {
                    self.logger.notice("auto-withdraw deferred: vault paused by operator")
                    self.parts.notifyAttention(
                        "zkAPI withdrawals are temporarily paused by the operator. Check Cloak Funds before your deposit expires.")
                    return
                }
                if self.parts.withdrawBlock() != nil {
                    guard await self.parts.sleep(15), !Task.isCancelled else { return }
                    continue
                }
                // Estimate live Ethereum gas fees BEFORE calling `quoteWithdrawal()` —
                // quoting irreversibly enters `withdrawal_pending` and freezes chat spending.
                // Only proceed if live wallet ETH covers the conservative gas reserve.
                let estimate = await self.parts.estimateWithdrawalFee()
                guard !Task.isCancelled else { return }
                guard self.parts.autoWithdrawEnabled(),
                    self.parts.payerState() == .ready,
                    self.parts.depositExpires() == expiry
                else {
                    return
                }
                if self.parts.withdrawBlock() == .paused {
                    self.logger.notice("auto-withdraw deferred after fee check: vault paused by operator")
                    self.parts.notifyAttention(
                        "zkAPI withdrawals are temporarily paused by the operator. Check Cloak Funds before your deposit expires.")
                    return
                }
                if self.parts.isBusy() || self.parts.withdrawBlock() != nil {
                    // Wallet became busy during the fee check (e.g. periodic refresh or
                    // chat turn): wait until idle and re-check instead of silently exiting.
                    guard await self.parts.sleep(15), !Task.isCancelled else { return }
                    continue
                }
                guard let estimate else {
                    self.attemptedExpiry = expiry
                    self.logger.notice("auto-withdraw deferred before quoting: could not estimate live Ethereum gas fee")
                    self.parts.notifyAttention(
                        "Cloak couldn't check Ethereum gas fees for automatic zkAPI withdrawal. Open Funds to withdraw before expiry.")
                    return
                }
                if let shortfall = Decimal(string: estimate.shortfallWei, locale: Locale(identifier: "en_US_POSIX")),
                    shortfall > 0
                {
                    self.attemptedExpiry = expiry
                    self.logger.notice("auto-withdraw skipped before quoting: wallet balance short of live gas reserve by \(estimate.shortfallWei, privacy: .public) wei")
                    let needed = self.parts.formatWei(estimate.shortfallWei) ?? "a small amount of ETH"
                    self.parts.notifyAttention(
                        "Add at least \(needed) more ETH for Ethereum gas in Cloak Funds, then withdraw your expiring zkAPI deposit.")
                    return
                }
                self.attemptedExpiry = expiry
                self.isExecutingAutoWithdraw = true
                defer { self.isExecutingAutoWithdraw = false }
                self.logger.notice("auto-withdrawing zkAPI deposit approaching expiry")
                guard await self.parts.quoteWithdrawal() else {
                    self.parts.notifyAttention(
                        "Cloak couldn't prepare your automatic zkAPI withdrawal. Open Funds to withdraw before expiry.")
                    return
                }
                if let block = self.parts.withdrawalConfirmBlock() {
                    self.parts.cancelReview()
                    self.logger.notice("auto-withdraw blocked: \(String(describing: block), privacy: .public)")
                    self.parts.notifyAttention(
                        "Add a small amount of ETH for Ethereum gas in Cloak Funds, then withdraw your expiring zkAPI deposit.")
                    return
                }
                if await self.parts.confirmWithdrawal() {
                    self.parts.notifyAttention(
                        "Automatic zkAPI withdrawal needs your attention in Cloak Funds before the 30-day limit.")
                }
                return
            }
        }
    }
}
