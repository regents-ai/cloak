import CloakChat
import Foundation
import Observation
import os
import UserNotifications

/// Safeguards a Paranoid (V) zkAPI deposit against its 30-day contract expiry
/// (Decision R6b):
/// 1. Schedules native macOS notifications 10, 5, and 2 days before expiry
///    (days 20, 25, and 28 of a 30-day deposit) and clears them once withdrawn.
/// 2. When the user opts into `AppSettings.autoWithdrawBeforeExpiry`, triggers
///    a single safe withdrawal 3 days before expiry while Cloak is open and
///    running.
@MainActor
final class ExpiryGuard {
    private let payer: Payer
    private let settings: AppSettings
    private let logger = Logger(subsystem: "sh.regents.cloak.app", category: "expiry")
    private var watchTask: Task<Void, Never>?
    private var autoWithdrawTask: Task<Void, Never>?
    private var notificationTask: Task<Void, Never>?
    /// True while `autoWithdrawTask` is actively executing `quoteWithdrawal()` /
    /// `confirm()`, so the resulting `.ready -> .withdrawing("quoted")` state
    /// transition never self-cancels our own in-flight `confirm()`.
    private var isExecutingAutoWithdraw = false
    /// The expiry timestamp we already attempted an automatic withdrawal for,
    /// so we never loop if a quote/withdrawal fails.
    private var attemptedExpiry: Date?

    private static let notificationIDs = [
        "sh.regents.cloak.expiry.10d",
        "sh.regents.cloak.expiry.5d",
        "sh.regents.cloak.expiry.2d",
    ]
    private static let autoWithdrawFailureID = "sh.regents.cloak.expiry.autowithdraw.failed"
    /// Automatically withdraw 3 days before expiry when opted in.
    private static let autoWithdrawLead: TimeInterval = 3 * 24 * 60 * 60

    init(payer: Payer, settings: AppSettings) {
        self.payer = payer
        self.settings = settings
        watchTask = Task { [weak self] in
            guard let self else { return }
            for await snapshot in Observations({
                Snapshot(
                    expiry: self.settings.depositExpires,
                    autoWithdraw: self.settings.autoWithdrawBeforeExpiry,
                    state: self.payer.state,
                    paused: self.payer.withdrawBlock == .paused)
            }) {
                self.handle(snapshot)
            }
        }
    }

    deinit {
        watchTask?.cancel()
        autoWithdrawTask?.cancel()
        notificationTask?.cancel()
    }

    private struct Snapshot: Equatable {
        var expiry: Date?
        var autoWithdraw: Bool
        var state: Payer.State
        var paused: Bool
    }

    private func handle(_ snapshot: Snapshot) {
        syncNotifications(expiry: snapshot.expiry)
        scheduleAutoWithdraw(snapshot)
    }

    private func syncNotifications(expiry: Date?) {
        // UNUserNotificationCenter requires a bundled app identifier.
        guard Bundle.main.bundleIdentifier != nil else { return }
        notificationTask?.cancel()
        notificationTask = nil
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: Self.notificationIDs)
        guard let expiry, expiry > .now else { return }

        let schedule: [(id: String, daysBefore: Int, title: String, body: String)] = [
            (
                Self.notificationIDs[0], 10,
                "zkAPI deposit expires in 10 days",
                "Withdraw your unspent ETH in Cloak Funds before \(expiry.formatted(date: .abbreviated, time: .omitted))."
            ),
            (
                Self.notificationIDs[1], 5,
                "zkAPI deposit expires in 5 days",
                "Open Cloak Funds and withdraw your deposit before \(expiry.formatted(date: .abbreviated, time: .omitted))."
            ),
            (
                Self.notificationIDs[2], 2,
                "Action needed: zkAPI deposit expires in 2 days",
                "Withdraw now in Cloak Funds so unspent ETH isn't claimed after expiry."
            ),
        ]

        notificationTask = Task { [logger] in
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            guard granted, !Task.isCancelled else { return }
            let now = Date.now
            for item in schedule {
                guard !Task.isCancelled else { return }
                let fireAt = expiry.addingTimeInterval(-TimeInterval(item.daysBefore) * 24 * 60 * 60)
                guard fireAt > now else { continue }
                let content = UNMutableNotificationContent()
                content.title = item.title
                content.body = item.body
                content.sound = .default
                let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireAt)
                let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                let request = UNNotificationRequest(identifier: item.id, content: content, trigger: trigger)
                do {
                    try await center.add(request)
                } catch {
                    logger.error("could not schedule expiry alert: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    private func scheduleAutoWithdraw(_ snapshot: Snapshot) {
        // Never self-cancel while our own quoteWithdrawal -> confirm flow is
        // executing (quoteWithdrawal triggers `follow()` which transitions
        // `payer.state` from `.ready` to `.withdrawing("quoted")`).
        if isExecutingAutoWithdraw { return }
        autoWithdrawTask?.cancel()
        autoWithdrawTask = nil
        guard snapshot.autoWithdraw, let expiry = snapshot.expiry, snapshot.state == .ready else { return }
        guard attemptedExpiry != expiry else { return }

        let withdrawAt = expiry.addingTimeInterval(-Self.autoWithdrawLead)
        let wait = withdrawAt.timeIntervalSinceNow
        autoWithdrawTask = Task { [weak self] in
            if wait > 0 {
                // Sleep in bounded chunks so system sleep/clock jumps wake promptly.
                while Date.now < withdrawAt {
                    let remaining = withdrawAt.timeIntervalSinceNow
                    guard remaining > 0 else { break }
                    let step = min(remaining, 3600)
                    guard (try? await Task.sleep(for: .seconds(step))) != nil else { return }
                }
            }
            // Wait briefly if a chat turn, wallet review, or another press is in flight
            // rather than clobbering user UI or burning our single attempt.
            while let self, !Task.isCancelled {
                guard self.settings.autoWithdrawBeforeExpiry, self.settings.depositExpires == expiry else { return }
                guard self.payer.state == .ready else { return }
                let busy = self.payer.queue.sending
                    || self.payer.queue.held
                    || self.payer.review != nil
                    || self.payer.working > 0
                    || self.payer.activity != nil
                    || self.payer.view == nil
                if !busy { break }
                guard (try? await Task.sleep(for: .seconds(15))) != nil else { return }
            }
            guard let self, !Task.isCancelled else { return }
            guard self.settings.autoWithdrawBeforeExpiry,
                self.payer.state == .ready,
                self.settings.depositExpires == expiry
            else {
                return
            }
            if self.payer.withdrawBlock == .paused {
                self.logger.notice("auto-withdraw deferred: vault paused by operator")
                self.notifyAutoWithdrawNeedsAttention(
                    body: "zkAPI withdrawals are temporarily paused by the operator. Check Cloak Funds before your deposit expires.")
                return
            }
            guard self.payer.withdrawBlock == nil else { return }
            // Estimate live Ethereum gas fees BEFORE calling `quoteWithdrawal()` —
            // quoting irreversibly enters `withdrawal_pending` and freezes chat spending.
            // Only proceed if live wallet ETH covers the conservative gas reserve.
            guard let estimate = await self.payer.estimateWithdrawalFee() else {
                self.attemptedExpiry = expiry
                self.logger.notice("auto-withdraw deferred before quoting: could not estimate live Ethereum gas fee")
                self.notifyAutoWithdrawNeedsAttention(
                    body: "Cloak couldn't check Ethereum gas fees for automatic zkAPI withdrawal. Open Funds to withdraw before expiry.")
                return
            }
            if let shortfall = Decimal(string: estimate.shortfallWei, locale: Locale(identifier: "en_US_POSIX")),
                shortfall > 0
            {
                self.attemptedExpiry = expiry
                self.logger.notice("auto-withdraw skipped before quoting: wallet balance short of live gas reserve by \(estimate.shortfallWei, privacy: .public) wei")
                let needed = Ether.text(wei: estimate.shortfallWei) ?? "a small amount of ETH"
                self.notifyAutoWithdrawNeedsAttention(
                    body: "Add at least \(needed) more ETH for Ethereum gas in Cloak Funds, then withdraw your expiring zkAPI deposit.")
                return
            }
            self.attemptedExpiry = expiry
            self.isExecutingAutoWithdraw = true
            defer { self.isExecutingAutoWithdraw = false }
            self.logger.notice("auto-withdrawing zkAPI deposit approaching expiry")
            await self.payer.quoteWithdrawal()
            guard case .withdrawal(let quote) = self.payer.review else {
                self.notifyAutoWithdrawNeedsAttention(
                    body: "Cloak couldn't prepare your automatic zkAPI withdrawal. Open Funds to withdraw before expiry.")
                return
            }
            if let block = self.payer.confirmBlock(.withdrawal(quote)) {
                self.payer.cancelReview()
                self.logger.notice("auto-withdraw blocked: \(String(describing: block), privacy: .public)")
                self.notifyAutoWithdrawNeedsAttention(
                    body: "Add a small amount of ETH for Ethereum gas in Cloak Funds, then withdraw your expiring zkAPI deposit.")
                return
            }
            await self.payer.confirm()
            if self.payer.stop != nil || self.payer.withdrawal?.phase == "waiting_funds" {
                self.notifyAutoWithdrawNeedsAttention(
                    body: "Automatic zkAPI withdrawal needs your attention in Cloak Funds before the 30-day limit.")
            }
        }
    }

    private func notifyAutoWithdrawNeedsAttention(body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        Task { [logger] in
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Action needed: zkAPI auto-withdraw"
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(identifier: Self.autoWithdrawFailureID, content: content, trigger: nil)
            try? await center.add(request)
            logger.notice("posted auto-withdraw attention alert")
        }
    }
}
