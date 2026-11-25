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
    /// The expiry timestamp we already attempted an automatic withdrawal for,
    /// so we never loop if a quote/withdrawal fails.
    private var attemptedExpiry: Date?

    private static let notificationIDs = [
        "sh.regents.cloak.expiry.10d",
        "sh.regents.cloak.expiry.5d",
        "sh.regents.cloak.expiry.2d",
    ]
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
                    state: self.payer.state)
            }) {
                self.handle(snapshot)
            }
        }
    }

    deinit {
        watchTask?.cancel()
        autoWithdrawTask?.cancel()
    }

    private struct Snapshot: Equatable {
        var expiry: Date?
        var autoWithdraw: Bool
        var state: Payer.State
    }

    private func handle(_ snapshot: Snapshot) {
        syncNotifications(expiry: snapshot.expiry)
        scheduleAutoWithdraw(snapshot)
    }

    private func syncNotifications(expiry: Date?) {
        // UNUserNotificationCenter requires a bundled app identifier.
        guard Bundle.main.bundleIdentifier != nil else { return }
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

        Task { [logger] in
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            guard granted else { return }
            let now = Date.now
            for item in schedule {
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
            guard let self, !Task.isCancelled else { return }
            guard self.settings.autoWithdrawBeforeExpiry, self.payer.state == .ready, self.settings.depositExpires == expiry else {
                return
            }
            self.attemptedExpiry = expiry
            self.logger.notice("auto-withdrawing zkAPI deposit approaching expiry")
            await self.payer.quoteWithdrawal()
            if case .withdrawal = self.payer.review {
                await self.payer.confirm()
            }
        }
    }
}
