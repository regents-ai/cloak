import CloakControl
@testable import CloakSupervisor
import Testing

/// The state machine on its own: every failure stops everything and ends in
/// Needs attention, and nothing leads back to Preparing or Running but an
/// explicit Start, Resume or Verify.
struct PhaseTests {
    static let commands: [Phase.Event] = [.start, .resume, .verify, .pause, .stop, .quit]
    static let ownEvents: [Phase.Event] = [.sleep, .prepared, .stopped] + Reason.allCases.map { .failed($0) }

    @Test(arguments: Reason.allCases)
    func aFailureWhilePreparingOrRunningStopsEverythingAndNeedsAttention(reason: Reason) {
        for phase in [Phase.preparing(.run), .preparing(.verify), .running] {
            let stopping = phase.after(.failed(reason))
            #expect(stopping == .stopping(.needsAttention(reason)))
            #expect(stopping?.after(.stopped) == .needsAttention(reason))
        }
    }

    @Test(arguments: Reason.allCases)
    func nothingStartsAgainAfterAFailureUnlessAsked(reason: Reason) {
        let stopping = Phase.stopping(.needsAttention(reason))
        // While stopping, only the end of the shutdown or a quit changes anything.
        for event in Self.commands + Self.ownEvents where event != .stopped && event != .quit {
            #expect(stopping.after(event) == nil, "\(event)")
        }
        // Once stopped, only Start or Verify prepare again.
        let attention = Phase.needsAttention(reason)
        for event in Self.ownEvents {
            let next = attention.after(event)
            #expect(next == nil || next == attention, "\(event)")
        }
        #expect(attention.after(.start) == .preparing(.run))
        #expect(attention.after(.verify) == .preparing(.verify))
        #expect(attention.after(.resume) == nil)
    }

    @Test func sleepPausesAndAWakeStartsNothing() {
        for phase in [Phase.preparing(.run), .preparing(.verify), .running] {
            #expect(phase.after(.sleep) == .stopping(.paused))
        }
        for phase in [Phase.paused, .ready, .needsAttention(.torStopped)] {
            #expect(phase.after(.sleep) == phase)
        }
        #expect(Phase.stopping(.paused).after(.stopped) == .paused)
    }

    @Test func pauseAndStopEndDifferently() {
        #expect(Phase.running.after(.pause) == .stopping(.paused))
        #expect(Phase.running.after(.stop) == .stopping(.ready))
        #expect(Phase.stopping(.ready).after(.stopped) == .ready)
        #expect(Phase.paused.after(.resume) == .preparing(.run))
        #expect(Phase.ready.after(.resume) == nil)
        #expect(Phase.ready.refusal(of: .resume) == .notPaused)
    }

    @Test func aCheckEndsReadyAndAStartDuringItKeepsRunning() {
        #expect(Phase.preparing(.verify).after(.prepared) == .stopping(.ready))
        #expect(Phase.preparing(.verify).after(.start) == .preparing(.run))
        #expect(Phase.preparing(.run).after(.prepared) == .running)
    }

    @Test func everyPhaseQuitsThroughTheShutdown() {
        let phases: [Phase] = [.paused, .preparing(.run), .running, .ready, .stopping(.paused), .needsAttention(.guestFailed)]
        for phase in phases {
            #expect(phase.after(.quit) == .stopping(.quit))
        }
        #expect(Phase.stopping(.quit).after(.stopped) == nil)
    }

    @Test func aCommandDuringAShutdownIsRefusedAsBusy() {
        for command in Self.commands where command != .quit {
            #expect(Phase.stopping(.paused).after(command) == nil)
            #expect(Phase.stopping(.paused).refusal(of: command) == .busy)
        }
    }
}
