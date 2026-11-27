@testable import CloakChat
import Foundation
import Testing

@Suite
@MainActor
struct ExpiryGuardTests {
    private static let day: TimeInterval = 24 * 60 * 60

    @MainActor
    private final class Harness {
        var now: Date
        var expiry: Date?
        var autoWithdraw = true
        var state: Payer.State = .ready
        var block: Payer.Block?
        var busy = false
        var busyPollsRemaining = 0
        var estimateResult: WithdrawalFeeEstimate? = WithdrawalFeeEstimate(
            balanceWei: "10000000000000000",
            gasLimit: 250_000,
            expectedFeeWei: "1000000000000000",
            requiredFeeWei: "1500000000000000",
            feeReserveWei: "2000000000000000",
            shortfallWei: "0")
        var quoteSucceeds = true
        var confirmBlock: Payer.Block?
        var confirmNeedsAttention = false
        var estimateHook: (@MainActor () async -> Void)?

        var sleepCalls: [TimeInterval] = []
        var syncedReminders: [[ExpiryReminder]] = []
        var attentionMessages: [String] = []
        var estimateCount = 0
        var quoteCount = 0
        var cancelReviewCount = 0
        var confirmCount = 0

        init(now: Date = Date(timeIntervalSince1970: 1_780_000_000)) {
            self.now = now
        }

        func makeGuard() -> ExpiryGuard {
            ExpiryGuard(parts: ExpiryGuard.Parts(
                now: { self.now },
                sleep: { seconds in
                    guard !Task.isCancelled else { return false }
                    self.sleepCalls.append(seconds)
                    self.now = self.now.addingTimeInterval(seconds)
                    if seconds == 15, self.busyPollsRemaining > 0 {
                        self.busyPollsRemaining -= 1
                        if self.busyPollsRemaining == 0 {
                            self.busy = false
                        }
                    }
                    await Task.yield()
                    return !Task.isCancelled
                },
                autoWithdrawEnabled: { self.autoWithdraw },
                depositExpires: { self.expiry },
                payerState: { self.state },
                withdrawBlock: { self.block },
                isBusy: { self.busy },
                estimateWithdrawalFee: {
                    self.estimateCount += 1
                    if let hook = self.estimateHook {
                        await hook()
                    }
                    return self.estimateResult
                },
                quoteWithdrawal: {
                    self.quoteCount += 1
                    // Simulate live Payer transition to `.withdrawing("quoted")` during auto-withdraw!
                    self.state = .withdrawing("quoted")
                    return self.quoteSucceeds
                },
                withdrawalConfirmBlock: { self.confirmBlock },
                cancelReview: { self.cancelReviewCount += 1 },
                confirmWithdrawal: {
                    self.confirmCount += 1
                    return self.confirmNeedsAttention
                },
                syncNotifications: { reminders in
                    self.syncedReminders.append(reminders)
                },
                notifyAttention: { body in
                    self.attentionMessages.append(body)
                }
            ))
        }

        var snapshot: ExpiryGuard.Snapshot {
            ExpiryGuard.Snapshot(expiry: expiry, autoWithdraw: autoWithdraw, state: state, paused: block == .paused)
        }
    }

    @Test func schedules10d5d2dRemindersAndClearsWhenWithdrawn() {
        let base = Date(timeIntervalSince1970: 1_780_000_000)
        let expiry30d = base.addingTimeInterval(30 * Self.day)

        let allThree = ExpiryGuard.reminders(for: expiry30d, now: base)
        #expect(allThree.map(\.daysBefore) == [10, 5, 2])
        #expect(allThree.map(\.id) == ExpiryGuard.notificationIDs)

        // At day 23 (7 days before expiry), 10d has passed so only 5d and 2d remain.
        let twoLeft = ExpiryGuard.reminders(for: expiry30d, now: base.addingTimeInterval(23 * Self.day))
        #expect(twoLeft.map(\.daysBefore) == [5, 2])

        // Once withdrawn (`expiry == nil`) or already expired, reminders clear completely.
        #expect(ExpiryGuard.reminders(for: nil, now: base).isEmpty)
        #expect(ExpiryGuard.reminders(for: expiry30d, now: expiry30d.addingTimeInterval(60)).isEmpty)
    }

    @Test func autoWithdrawsAtThreeDayLeadAfterWaitingForVirtualClockAndIdle() async {
        let harness = Harness()
        // Deposit expires in 3 days + 2.5 hours -> must wait 2.5 hours (in <=1h chunks), then wait 2 busy ticks.
        let expiry = harness.now.addingTimeInterval(3 * Self.day + 2.5 * 3600)
        harness.expiry = expiry
        harness.busy = true
        harness.busyPollsRemaining = 2

        let guardObj = harness.makeGuard()
        guardObj.handle(harness.snapshot)
        await guardObj.waitForAutoWithdraw()

        // Virtual clock stepped in bounded 3600s, 3600s, 1800s chunks + two 15s busy waits!
        #expect(harness.sleepCalls == [3600, 3600, 1800, 15, 15])
        #expect(harness.estimateCount == 1)
        #expect(harness.quoteCount == 1)
        #expect(harness.confirmCount == 1)
        #expect(guardObj.attemptedExpiry == expiry)
        #expect(guardObj.isExecutingAutoWithdraw == false)
        #expect(harness.attentionMessages.isEmpty)
    }

    @Test func skipsBeforeQuotingWhenGasShortfallExists() async {
        let harness = Harness()
        let expiry = harness.now.addingTimeInterval(2 * Self.day) // already inside 3-day window
        harness.expiry = expiry
        harness.estimateResult = WithdrawalFeeEstimate(
            balanceWei: "100000000000000",
            gasLimit: 250_000,
            expectedFeeWei: "1000000000000000",
            requiredFeeWei: "1500000000000000",
            feeReserveWei: "2000000000000000",
            shortfallWei: "1900000000000000")

        let guardObj = harness.makeGuard()
        guardObj.handle(harness.snapshot)
        await guardObj.waitForAutoWithdraw()

        // CRITICAL: quoteWithdrawal() MUST NOT be called when gas is short (would lock deposit)!
        #expect(harness.estimateCount == 1)
        #expect(harness.quoteCount == 0)
        #expect(harness.confirmCount == 0)
        #expect(guardObj.attemptedExpiry == expiry)
        #expect(harness.attentionMessages.count == 1)
        #expect(harness.attentionMessages[0].contains("ETH for Ethereum gas"))
    }

    @Test func vaultPauseDefersWithoutBurningAttemptedExpiryThenSucceedsWhenUnpaused() async {
        let harness = Harness()
        let expiry = harness.now.addingTimeInterval(2 * Self.day)
        harness.expiry = expiry
        harness.block = .paused

        let guardObj = harness.makeGuard()
        guardObj.handle(harness.snapshot)
        await guardObj.waitForAutoWithdraw()

        #expect(harness.estimateCount == 0)
        #expect(harness.quoteCount == 0)
        #expect(guardObj.attemptedExpiry == nil)
        #expect(harness.attentionMessages.count == 1)
        #expect(harness.attentionMessages[0].contains("temporarily paused"))

        // Operator unpauses vault -> ExpiryGuard automatically retries and succeeds!
        harness.block = nil
        guardObj.handle(harness.snapshot)
        await guardObj.waitForAutoWithdraw()

        #expect(harness.estimateCount == 1)
        #expect(harness.quoteCount == 1)
        #expect(harness.confirmCount == 1)
        #expect(guardObj.attemptedExpiry == expiry)
    }

    @Test func benignCancellationDuringFeeEstimateDoesNotBurnAttemptedExpiryOrAlert() async {
        let harness = Harness()
        let expiry = harness.now.addingTimeInterval(2 * Self.day)
        harness.expiry = expiry

        var enteredEstimate: CheckedContinuation<Void, Never>?
        var releaseEstimate: CheckedContinuation<Void, Never>?
        harness.estimateResult = nil // simulates cancelled estimate returning nil
        harness.estimateHook = {
            enteredEstimate?.resume()
            enteredEstimate = nil
            await withCheckedContinuation { releaseEstimate = $0 }
        }

        let guardObj = harness.makeGuard()
        await withCheckedContinuation { continuation in
            enteredEstimate = continuation
            guardObj.handle(harness.snapshot)
        }

        // Cancel while fee estimate is in flight (e.g. user toggled auto-withdraw off or paused Cloak).
        guardObj.cancelPendingAutoWithdraw()
        releaseEstimate?.resume()
        releaseEstimate = nil
        await Task.yield()
        await Task.yield()

        // Must NOT burn attemptedExpiry and must NOT post a false failure alert!
        #expect(guardObj.attemptedExpiry == nil)
        #expect(harness.attentionMessages.isEmpty)
        #expect(harness.quoteCount == 0)
    }

    @Test func selfTransitionDuringQuoteDoesNotCancelInFlightConfirmation() async {
        let harness = Harness()
        let expiry = harness.now.addingTimeInterval(2 * Self.day)
        harness.expiry = expiry

        var selfRef: ExpiryGuard?
        let guarded = ExpiryGuard(parts: ExpiryGuard.Parts(
            now: { harness.now },
            sleep: { _ in true },
            autoWithdrawEnabled: { harness.autoWithdraw },
            depositExpires: { harness.expiry },
            payerState: { harness.state },
            withdrawBlock: { harness.block },
            isBusy: { harness.busy },
            estimateWithdrawalFee: { harness.estimateResult },
            quoteWithdrawal: {
                harness.quoteCount += 1
                harness.state = .withdrawing("quoted")
                // Simulate Swift Observation firing right when quoteWithdrawal transitions payer.state!
                selfRef?.handle(harness.snapshot)
                return true
            },
            withdrawalConfirmBlock: { nil },
            cancelReview: { harness.cancelReviewCount += 1 },
            confirmWithdrawal: {
                harness.confirmCount += 1
                return false
            },
            syncNotifications: { _ in },
            notifyAttention: { harness.attentionMessages.append($0) }
        ))
        selfRef = guarded

        guarded.handle(harness.snapshot)
        await guarded.waitForAutoWithdraw()

        #expect(harness.quoteCount == 1)
        #expect(harness.confirmCount == 1)
        #expect(guarded.isExecutingAutoWithdraw == false)
        #expect(harness.attentionMessages.isEmpty)
    }

    @Test func walletBecomingBusyDuringFeeEstimateRetriesOnceIdleInsteadOfSilentlyExiting() async {
        let harness = Harness()
        let expiry = harness.now.addingTimeInterval(2 * Self.day)
        harness.expiry = expiry

        // Simulate an ordinary periodic wallet refresh overlapping the FIRST fee check:
        // `isBusy` flips true while `estimateWithdrawalFee()` is in flight, then clears
        // after one 15s idle poll. Auto-withdraw MUST loop and succeed on attempt 2.
        harness.estimateHook = {
            if harness.estimateCount == 1 {
                harness.busy = true
                harness.busyPollsRemaining = 1
            }
        }

        let guardObj = harness.makeGuard()
        guardObj.handle(harness.snapshot)
        await guardObj.waitForAutoWithdraw()

        #expect(harness.estimateCount == 2)
        #expect(harness.quoteCount == 1)
        #expect(harness.confirmCount == 1)
        #expect(guardObj.attemptedExpiry == expiry)
        #expect(harness.attentionMessages.isEmpty)
    }
}
