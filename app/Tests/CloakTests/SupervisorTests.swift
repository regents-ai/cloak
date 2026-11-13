import CloakControl
@testable import CloakSupervisor
import Foundation
import Testing

/// The supervisor driving real processes: stand-in scripts for tor and the
/// worker, and a guest that cannot start. Every failure ends in Needs
/// attention with everything that started stopped, and nothing is started
/// again or another way.
@MainActor
@Suite(.serialized)
struct SupervisorTests {
    @Test func aGuestThatCannotStartNeedsAttentionWithTorAndTheWorkerStopped() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let supervisor = fixture.supervisor()
        #expect(supervisor.phase == .paused)
        #expect(supervisor.send(.start) == nil)
        #expect(await supervisor.settled() == .needsAttention(.guestFailed))
        #expect(supervisor.problem?.hasPrefix("cannot start the guest: ") == true)
        #expect(supervisor.status.status == .failed)
        #expect(supervisor.status.nextAction == .start)
        let started = fixture.starts(.tor) + fixture.starts(.worker)
        #expect(fixture.starts(.tor).count == 1 && fixture.starts(.worker).count == 1)
        #expect(!started.contains(where: isRunning))

        // Nothing starts again by itself.
        try await Task.sleep(for: .seconds(2))
        #expect(supervisor.phase == .needsAttention(.guestFailed))
        #expect(fixture.starts(.tor) + fixture.starts(.worker) == started)

        // A relaunch comes back Paused, having started nothing.
        let relaunched = fixture.supervisor()
        #expect(relaunched.phase == .paused)
        #expect(relaunched.status.status == .paused)
        #expect(fixture.starts(.tor) + fixture.starts(.worker) == started)
    }

    @Test func aTorThatExitsBeforeItsPortOpensNeedsAttentionAndNoWorkerStarts() async throws {
        let fixture = try Fixture(tor: Fixture.failingTor)
        defer { fixture.remove() }
        let supervisor = fixture.supervisor()
        supervisor.send(.start)
        #expect(await supervisor.settled() == .needsAttention(.torUnavailable))
        #expect(fixture.starts(.tor).count == 1)
        #expect(fixture.starts(.worker).isEmpty)
    }

    @Test func aWorkerThatNeverBecomesReadyNeedsAttentionWithTorStopped() async throws {
        let fixture = try Fixture(worker: Fixture.failingWorker)
        defer { fixture.remove() }
        let supervisor = fixture.supervisor()
        supervisor.send(.start)
        #expect(await supervisor.settled() == .needsAttention(.workerUnavailable))
        #expect(fixture.starts(.tor).count == 1 && fixture.starts(.worker).count == 1)
        #expect(!fixture.starts(.tor).contains(where: isRunning))
    }

    @Test func aTorThatEndsWhileTheWorkerLoadsNeedsAttentionWithTheWorkerStopped() async throws {
        // The worker signals ready only once tor has been killed, as if tor
        // had died while the model loaded.
        let worker = """
            #!/bin/sh
            echo $$ >> "$(dirname "$0")/starts"
            kill -9 "$(head -1 "$(dirname "$0")/../../bundle/tor/starts")"
            sleep 1
            printf 'Y\\000\\000\\000\\000'
            exec cat > /dev/null
            """
        let fixture = try Fixture(worker: worker)
        defer { fixture.remove() }
        let supervisor = fixture.supervisor()
        supervisor.send(.start)
        #expect(await supervisor.settled() == .needsAttention(.torStopped))
        #expect(fixture.starts(.tor).count == 1 && fixture.starts(.worker).count == 1)
        #expect(!fixture.starts(.worker).contains(where: isRunning))
    }

    @Test(arguments: [
        Checks.Hardware(appleSilicon: false, memory: 64 << 30),
        Checks.Hardware(appleSilicon: true, memory: 4 << 30),
    ])
    func aMacOutsideTheManifestIsUnsupportedAndNothingStarts(hardware: Checks.Hardware) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let supervisor = fixture.supervisor(hardware: hardware)
        supervisor.send(.start)
        #expect(await supervisor.settled() == .needsAttention(.unsupportedHardware))
        #expect(supervisor.status.status == .unsupportedHardware)
        #expect(supervisor.status.nextAction == NextAction.none)
        #expect(fixture.starts(.tor).isEmpty)
    }

    @Test func aMissingPartAChangedPartAndAMissingModelEachNeedAttentionAndNothingStarts() async throws {
        let cases: [(Reason, (Fixture) throws -> Void)] = [
            (.partMissing, { try FileManager.default.removeItem(at: $0.url(.libevent)) }),
            (.partChanged, { try Data("another kernel".utf8).write(to: $0.url(.kernel)) }),
            (.modelMissing, { try Data("{ }".utf8).write(to: $0.layout.model($0.manifest).appending(path: "config.json")) }),
        ]
        for (reason, damage) in cases {
            let fixture = try Fixture()
            defer { fixture.remove() }
            try damage(fixture)
            let supervisor = fixture.supervisor()
            supervisor.send(.start)
            #expect(await supervisor.settled() == .needsAttention(reason))
            #expect(fixture.starts(.tor).isEmpty && fixture.starts(.worker).isEmpty)
        }
    }

    @Test func pausingWhileTorBootstrapsStopsItAndEndsPaused() async throws {
        let fixture = try Fixture(tor: Fixture.slowTor)
        defer { fixture.remove() }
        let supervisor = fixture.supervisor()
        supervisor.send(.start)
        try await eventually { !fixture.starts(.tor).isEmpty }
        #expect(supervisor.send(.pause) == nil)
        #expect(supervisor.phase == .stopping(.paused))
        #expect(await supervisor.settled() == .paused)
        #expect(!fixture.starts(.tor).contains(where: isRunning))
        #expect(fixture.starts(.worker).isEmpty)
    }

    @Test func quittingStopsEverythingThroughTheShutdown() async throws {
        let fixture = try Fixture(tor: Fixture.slowTor)
        defer { fixture.remove() }
        let supervisor = fixture.supervisor()
        supervisor.send(.start)
        try await eventually { !fixture.starts(.tor).isEmpty }
        await withCheckedContinuation { quit in
            supervisor.quit { quit.resume() }
        }
        #expect(supervisor.phase == .stopping(.quit))
        #expect(!fixture.starts(.tor).contains(where: isRunning))
    }
}

/// Waits, up to 10 seconds, for something the test cannot be told about.
@MainActor
func eventually(_ condition: () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(10)
    while !condition() {
        guard clock.now < deadline else { throw CancellationError() }
        try await Task.sleep(for: .milliseconds(50))
    }
}
