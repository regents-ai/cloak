import CloakControl
import CloakSupervisor
@testable import RegentsCloak
import Testing

/// The menu's header: its dot follows the state now and goes grey while
/// Cloak changes state, its line keeps the last settled state meanwhile, and
/// a failure takes the line only once Cloak has stopped for it.
struct MenuHeaderTests {
    static let settled: [Phase] = [.paused, .ready, .running, .needsAttention(.workerStopped)]
    static let changing: [Phase] = [
        .preparing(.run), .preparing(.verify), .stopping(.paused), .stopping(.ready),
        .stopping(.needsAttention(.torStopped)), .stopping(.quit),
    ]

    @Test(arguments: settled)
    func aSettledPhaseShowsItself(phase: Phase) {
        let header = MenuHeader(phase: phase, settled: phase, resting: false, downloading: false)
        #expect(header.state == phase.state)
        switch phase {
        case .running:
            #expect(header.dot == .running)
            #expect(header.line == .state(.running, unloaded: false, downloading: false))
        case .needsAttention(let reason):
            #expect(header.dot == .attention)
            #expect(header.line == .failure(reason, fix: .start))
        default:
            #expect(header.dot == .stopped)
            #expect(header.line == .state(phase.state, unloaded: false, downloading: false))
        }
    }

    @Test(arguments: changing, settled)
    func whileCloakChangesStateOnlyTheDotChanges(phase: Phase, settled: Phase) {
        let header = MenuHeader(phase: phase, settled: settled, resting: false, downloading: false)
        #expect(header.dot == .changing)
        #expect(header.state == phase.state)
        // A failure's remedy and fix never stay through a start, nor show
        // before the stop it causes has ended.
        #expect(header.line == .state(settled.state, unloaded: false, downloading: false))
    }

    @Test func theModelsRestShowsOnlyWithRunning() {
        #expect(MenuHeader(phase: .running, settled: .running, resting: true, downloading: false).line
            == .state(.running, unloaded: true, downloading: false))
        #expect(MenuHeader(phase: .stopping(.paused), settled: .running, resting: true, downloading: false).line
            == .state(.running, unloaded: true, downloading: false))
        #expect(MenuHeader(phase: .paused, settled: .paused, resting: true, downloading: false).line
            == .state(.paused, unloaded: false, downloading: false))
    }

    @Test(arguments: [false, true])
    func theDownloadIsOfferedInOnePlace(downloading: Bool) {
        let paused = MenuHeader(phase: .paused, settled: .paused, resting: false, downloading: downloading)
        #expect(paused.line == .state(.paused, unloaded: false, downloading: downloading))
        #expect(!paused.offersDownload)
        let missing = MenuHeader(phase: .needsAttention(.modelMissing), settled: .needsAttention(.modelMissing), resting: false, downloading: downloading)
        #expect(missing.line == .failure(.modelMissing, fix: .download(underWay: downloading)))
        #expect(missing.offersDownload)
        for reason in Reason.allCases where reason != .modelMissing {
            #expect(!MenuHeader(phase: .needsAttention(reason), settled: .needsAttention(reason), resting: false, downloading: downloading)
                .offersDownload)
        }
    }
}
