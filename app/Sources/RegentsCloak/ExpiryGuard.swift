import CloakChat
import Foundation
import Observation
import os
import UserNotifications

extension ExpiryGuard {
    /// Wires `CloakChat.ExpiryGuard` to live `Payer`, `AppSettings`, `Observations`, and
    /// macOS `UNUserNotificationCenter` notifications.
    @MainActor
    convenience init(payer: Payer, settings: AppSettings) {
        let logger = Logger(subsystem: "sh.regents.cloak.app", category: "expiry")
        let notifier = ExpiryNotificationBridge(logger: logger)

        let isBusy: @MainActor () -> Bool = {
            payer.queue.sending
                || payer.queue.held
                || payer.review != nil
                || payer.working > 0
                || payer.activity != nil
                || payer.view == nil
        }

        self.init(parts: Parts(
            autoWithdrawEnabled: { settings.autoWithdrawBeforeExpiry },
            depositExpires: { settings.depositExpires },
            payerState: { payer.state },
            withdrawBlock: { payer.withdrawBlock },
            isBusy: isBusy,
            estimateWithdrawalFee: { await payer.estimateWithdrawalFee() },
            quoteWithdrawal: {
                await payer.quoteWithdrawal()
                if case .withdrawal = payer.review { return true }
                return false
            },
            withdrawalConfirmBlock: {
                guard case .withdrawal(let quote) = payer.review else { return nil }
                return payer.confirmBlock(.withdrawal(quote))
            },
            cancelReview: { payer.cancelReview() },
            confirmWithdrawal: {
                await payer.confirm()
                return payer.stop != nil || payer.withdrawal?.phase == "waiting_funds"
            },
            syncNotifications: { reminders in
                notifier.sync(reminders)
            },
            notifyAttention: { body in
                notifier.postAttention(body)
            },
            formatWei: { Ether.text(wei: $0) }
        ))

        let task = Task { [weak self] in
            guard let self else { return }
            for await snapshot in Observations({
                Snapshot(
                    expiry: settings.depositExpires,
                    autoWithdraw: settings.autoWithdrawBeforeExpiry,
                    state: payer.state,
                    paused: payer.withdrawBlock == .paused,
                    busy: isBusy())
            }) {
                self.handle(snapshot)
            }
        }
        attachWatch(task)
    }
}

@MainActor
private final class ExpiryNotificationBridge {
    private let logger: Logger
    private var notificationTask: Task<Void, Never>?

    init(logger: Logger) {
        self.logger = logger
    }

    deinit {
        notificationTask?.cancel()
    }

    func sync(_ reminders: [ExpiryReminder]) {
        // UNUserNotificationCenter requires a bundled app identifier.
        guard Bundle.main.bundleIdentifier != nil else { return }
        notificationTask?.cancel()
        notificationTask = nil
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ExpiryGuard.notificationIDs)
        guard !reminders.isEmpty else { return }

        notificationTask = Task { [logger] in
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            guard granted, !Task.isCancelled else { return }
            for item in reminders {
                guard !Task.isCancelled else { return }
                let content = UNMutableNotificationContent()
                content.title = item.title
                content.body = item.body
                content.sound = .default
                let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: item.fireAt)
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

    func postAttention(_ body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        Task { [logger] in
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Action needed: zkAPI auto-withdraw"
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(identifier: ExpiryGuard.autoWithdrawFailureID, content: content, trigger: nil)
            try? await center.add(request)
            logger.notice("posted auto-withdraw attention alert")
        }
    }
}
