import AppKit
import CloakSupervisor
import Observation

/// The Darkbloom window's one model (docs/state-machines.md, section 9e):
/// what Cloak found of Darkbloom's runtime, what its control service last
/// reported, how its files say it serves, and what the person's last press
/// led to, read as one named `state`. Nothing runs until the window first
/// opens, and Darkbloom is followed only while it is open; whatever
/// Darkbloom serves goes on after the window closes or Cloak quits, since
/// it is Darkbloom's own service, not Cloak's.
@MainActor
@Observable
final class DarkbloomMode {
    enum State: Equatable {
        /// This Mac's system is older than Darkbloom's installer takes.
        case unsupported
        case looking
        case notSetUp
        /// Darkbloom's installer runs, at its step from 1 to 5.
        case installing(step: Int)
        /// Darkbloom is installed and checked, and its control service doesn't
        /// answer for this release.
        case notConnected
        case connecting
        /// The model isn't on this Mac, and nothing serves.
        case noModel
        /// From 0 to 1, when Darkbloom says.
        case downloading(Double?)
        case loading
        case serving
        case stopping
        case stopped
        case failed(DarkbloomFailure)
    }

    /// What Cloak found of the runtime.
    private enum Runtime {
        case looking
        case missing
        case installing(Int)
        case refused(DarkbloomFailure)
        case offline
        case connecting
        case connected
    }

    private let manifest: Manifest
    private let settings: AppSettings
    private var runtime = Runtime.looking
    private var found: Darkbloom.Found?
    private(set) var snapshot: DarkbloomSnapshot?
    private(set) var setup = DarkbloomSetup()
    /// Why the person's last press didn't do what it asked; gone at the next.
    private var failure: DarkbloomFailure?
    /// Whether Cloak's Start runs (`darkbloom start`, which returns once
    /// Darkbloom's service has the job).
    private var starting = false
    /// The last action Cloak asked the control service for, until it ends.
    private var asked: (id: String, failing: String)?
    /// Whether Start serves Darkbloom's network too, as Darkbloom's job does
    /// when the window opens; off for a Mac that has none.
    private(set) var alsoServe = false
    @ObservationIgnored private var following: Task<Void, Never>?

    init(manifest: Manifest, settings: AppSettings) {
        self.manifest = manifest
        self.settings = settings
    }

    var state: State {
        guard Darkbloom.systemFits else { return .unsupported }
        switch runtime {
        case .looking: return .looking
        case .missing: return failure.map(State.failed) ?? .notSetUp
        case .installing(let step): return .installing(step: step)
        case .refused(let failure): return .failed(failure)
        case .offline: return failure.map(State.failed) ?? .notConnected
        case .connecting: return .connecting
        case .connected: break
        }
        guard let snapshot else { return .connecting }
        if let failure { return .failed(failure) }
        if starting { return .loading }
        let running = snapshot.operations.first { $0.state == "running" }
        if running?.action == "stop" || snapshot.state == "draining" { return .stopping }
        if let running, running.action == "download", running.model == recommended?.id {
            return .downloading(running.progress)
        }
        switch snapshot.state {
        case "starting":
            return .loading
        case "running":
            // Only me reports running once its address listens, after its models load; the network's
            // job reports each model's load.
            let ready = setup.job?.mode == .onlyMe ? snapshot.endpoint != nil : snapshot.models.contains { $0.serving && $0.loaded }
            return ready ? .serving : .loading
        case "stopped":
            // Only me's job loads its model before its address listens, and reports nothing until then.
            if setup.job?.mode == .onlyMe, setup.job?.running == true { return .loading }
            return recommended?.downloaded == true ? .stopped : .noModel
        case "stale":
            return .failed(DarkbloomFailure("Status out of date", detail: "Darkbloom still serves, but its report is old."))
        default:
            return .failed(DarkbloomFailure("Unknown state", detail: "Darkbloom reports \(snapshot.state), which Cloak doesn't know."))
        }
    }

    /// Whether Darkbloom serves, or is set to, so Stop applies rather than Start.
    var isOn: Bool {
        guard let snapshot else { return false }
        return starting || ["starting", "running", "draining", "stale"].contains(snapshot.state) || setup.job?.loaded == true
    }

    /// The release found, once it is checked.
    var version: String? { found?.version }

    // MARK: The model

    /// The one model Cloak offers: of those in Darkbloom's list that
    /// Darkbloom can serve here and that fit `room`, one already on this Mac
    /// first, then the largest.
    var recommended: DarkbloomSnapshot.Model? {
        guard let snapshot, let room else { return nil }
        return snapshot.models
            .filter { model in model.network && model.eligible && Self.need(model).map { $0 <= room } == true }
            .max { (Self.rank($0), Self.need($0) ?? 0) < (Self.rank($1), Self.need($1) ?? 0) }
    }

    private static func need(_ model: DarkbloomSnapshot.Model) -> Double? { model.memoryGb ?? model.sizeGb }
    private static func rank(_ model: DarkbloomSnapshot.Model) -> Int { model.downloaded ? 1 : 0 }

    /// What Darkbloom lets models take on this Mac less what Cloak takes, in
    /// Darkbloom's GB (2³⁰ bytes, as it counts a model on disk); nil when
    /// Darkbloom doesn't say.
    var room: Double? {
        snapshot?.memory.pinBudgetGb.map { $0 - Double(cloakMemory) / 1_073_741_824 }
    }

    /// The memory Cloak needs: all of Cloak with its rewording model, and the
    /// model chosen for Local Llama when it is another, as both can be loaded
    /// at once (`Manifest.answerCheck`).
    var cloakMemory: UInt64 {
        let chosen = manifest.answerModels.first { $0.name == settings.answerModel && $0.name != manifest.model }
        return manifest.cloakMemory + (chosen?.memory ?? 0)
    }

    /// Why Start can't serve now, in a few words, or nil when it can.
    var startBlock: String? {
        guard let found, let snapshot else { return "Not connected" }
        guard found.flags.isSuperset(of: Darkbloom.startNeeds(alsoServe: alsoServe)) else { return "Needs a newer Darkbloom" }
        guard let recommended else { return snapshot.catalogError == nil ? "No model fits" : "Model list unavailable" }
        guard recommended.downloaded else { return "Download first" }
        return nil
    }

    /// The download under way, if any, for Cancel.
    private var download: DarkbloomSnapshot.Operation? {
        snapshot?.operations.first { $0.state == "running" && $0.action == "download" && $0.cancellable }
    }

    /// Linking under way, with its code and page once Darkbloom has them.
    var linking: DarkbloomSnapshot.Link? {
        guard snapshot?.operations.contains(where: { $0.state == "running" && $0.action == "link" }) == true else { return nil }
        return snapshot?.link
    }

    /// Something in how Darkbloom serves now that Cloak's Start would change.
    enum Change: Hashable {
        /// It serves Darkbloom's network alone, and Start serves this Mac alone.
        case network
        /// Its address answers beyond this Mac.
        case open
        /// It sends the person's requests on when this Mac is busy.
        case forwards

        var words: String {
            switch self {
            case .network: "Serves Darkbloom's network"
            case .open: "Open beyond this Mac"
            case .forwards: "Your requests can leave this Mac"
            }
        }

        /// What Start does about it.
        var start: String {
            switch self {
            case .network: "Darkbloom stops serving its network from this Mac."
            case .open: "Its address answers only apps on this Mac."
            case .forwards: "Your requests stay on this Mac."
            }
        }
    }

    /// What Start would change of a setup made outside Cloak; Cloak changes
    /// none of it before Start. Serving both ways is the network switch's own.
    var changes: [Change] {
        var changes: [Change] = []
        if let job = setup.job, job.loaded, job.mode == .network, !alsoServe {
            changes.append(.network)
        }
        if let bind = setup.listens ?? setup.job?.bind, !DarkbloomSetup.loopback(bind) {
            changes.append(.open)
        }
        if let route = setup.route, route != "this-mac" {
            changes.append(.forwards)
        }
        return changes
    }

    /// Where requests to the local address go, as far as Darkbloom's files show.
    enum Reach {
        /// Its route is this Mac and its address listens on loopback.
        case thisMac
        /// Its address listens beyond this Mac.
        case beyond
        /// Its route sends requests on when this Mac is busy.
        case forwards
        /// The route or the address can't be read.
        case unknown
    }

    var reach: Reach {
        guard let listens = setup.listens, let route = setup.route else { return .unknown }
        guard DarkbloomSetup.loopback(listens) else { return .beyond }
        return route == "this-mac" ? .thisMac : .forwards
    }

    /// Whether `start` takes `--me-first`, so the network switch can work.
    var canAlsoServe: Bool {
        found?.flags.contains("--me-first") == true
    }

    /// Whether the window shows what Darkbloom reports, rather than Setup.
    var connected: Bool {
        switch runtime {
        case .connected, .connecting, .looking: snapshot != nil
        case .missing, .installing, .refused, .offline: false
        }
    }

    // MARK: Presses

    /// Looks for Darkbloom again and follows it while the window is open;
    /// on a system Darkbloom doesn't run on, nothing.
    func open() {
        guard Darkbloom.systemFits else { return }
        failure = nil
        follow { await self.look(ensuring: false) }
    }

    /// Stops following Darkbloom, and hides the key; nothing Darkbloom runs stops.
    func close() {
        following?.cancel()
        following = nil
        shownKey = nil
    }

    /// Installs Darkbloom's runtime, then starts its control service and
    /// follows it.
    func install() {
        failure = nil
        runtime = .installing(0)
        follow {
            do throws(DarkbloomFailure) {
                try await Darkbloom.install { step in self.runtime = .installing(step) }
            } catch {
                self.runtime = .missing
                self.failure = error
                return
            }
            await self.look(ensuring: true)
        }
    }

    /// Starts Darkbloom's control service (`desktop ensure`) and follows it.
    func connect() {
        failure = nil
        follow { await self.look(ensuring: true) }
    }

    /// Serves the model as `alsoServe` says, replacing whatever Darkbloom
    /// serves now.
    func start() {
        guard startBlock == nil, let found, let model = recommended else { return }
        failure = nil
        starting = true
        let arguments = Darkbloom.startArguments(model: model.id, alsoServe: alsoServe)
        Task {
            do throws(DarkbloomFailure) {
                try await Darkbloom.run(found.binary, arguments, failing: "Couldn't start")
            } catch {
                failure = error
            }
            starting = false
        }
    }

    func stop() {
        ask(.stop, failing: "Couldn't stop")
    }

    func downloadModel() {
        guard let recommended else { return }
        ask(.download(model: recommended.id), failing: "Download failed")
    }

    func cancelDownload() {
        guard let download else { return }
        ask(.cancel(operation: download.id), failing: "Couldn't cancel")
    }

    func removeModel() {
        guard let recommended else { return }
        ask(.remove(model: recommended.id), failing: "Couldn't remove")
    }

    /// Turns serving Darkbloom's network too on or off: on links this Mac to
    /// the person's Darkbloom account first, when it isn't; either way, a Mac
    /// that serves now serves again as chosen.
    func setAlsoServe(_ on: Bool) {
        failure = nil
        alsoServe = on
        if !on, let link = snapshot?.operations.first(where: { $0.state == "running" && $0.action == "link" }) {
            ask(.cancel(operation: link.id), failing: "Couldn't cancel")
            return
        }
        if on, snapshot?.linked == false {
            ask(.link, failing: "Couldn't link")
            return
        }
        if isOn { start() }
    }

    /// Opens Darkbloom's link page, where the person signs in and enters the code.
    func continueInBrowser() {
        guard let url = linking.flatMap({ URL(string: $0.url) }), url.scheme == "https" else { return }
        NSWorkspace.shared.open(url)
    }

    /// The local address's key, asked of Darkbloom now; nil when it can't be read.
    func key() async -> String? {
        guard let control = found?.control else { return nil }
        return try? await control.endpointKey()
    }

    /// The key while the person has it shown; hidden again when the window closes.
    private(set) var shownKey: String?

    func showKey() async {
        shownKey = await key()
    }

    func hideKey() {
        shownKey = nil
    }

    // MARK: Following

    private func follow(_ body: @escaping @MainActor () async -> Void) {
        following?.cancel()
        following = Task { await body() }
    }

    /// Finds and checks the runtime, starts its control service when
    /// `ensuring` and it doesn't answer, then follows its reports until the
    /// window closes.
    private func look(ensuring: Bool) async {
        runtime = ensuring ? .connecting : .looking
        do throws(DarkbloomFailure) {
            guard var found = try await Darkbloom.find() else {
                runtime = .missing
                return
            }
            if found.control == nil, ensuring {
                try await Darkbloom.run(found.binary, ["desktop", "ensure"], failing: "Couldn't connect")
                guard let again = try await Darkbloom.find() else {
                    runtime = .missing
                    return
                }
                found = again
            }
            guard !Task.isCancelled else { return }
            self.found = found
            guard let control = found.control, let first = found.snapshot else {
                runtime = .offline
                return
            }
            await accept(first)
            alsoServe = setup.job?.mode == .both
            await reports(control)
        } catch {
            guard !Task.isCancelled else { return }
            runtime = .refused(error)
        }
    }

    /// Follows the control service's reports. Each stream ends after a
    /// minute and is opened again at once; one that breaks is tried again
    /// every 5 seconds, from the service's file each time, since a service
    /// that restarted has a new port and token.
    private func reports(_ control: DarkbloomControl) async {
        var control = control
        while !Task.isCancelled {
            do {
                for try await snapshot in control.events() {
                    guard snapshot.protocol == 1, snapshot.version == found?.version else {
                        runtime = .offline
                        return
                    }
                    await accept(snapshot)
                }
            } catch DarkbloomError.unreadable {
                runtime = .refused(DarkbloomFailure("Unknown Darkbloom", detail: DarkbloomError.unreadable.reason))
                return
            } catch {
                guard !Task.isCancelled else { return }
                runtime = .connecting
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                guard let next = try? DarkbloomControl.discover() else {
                    runtime = .offline
                    return
                }
                control = next
                found?.control = next
            }
        }
    }

    private func accept(_ snapshot: DarkbloomSnapshot) async {
        let setup = await DarkbloomSetup.read(listening: snapshot.endpoint != nil)
        guard !Task.isCancelled else { return }
        self.setup = setup
        self.snapshot = snapshot
        runtime = .connected
        guard let asked, let operation = snapshot.operations.first(where: { $0.id == asked.id }), operation.state != "running"
        else { return }
        self.asked = nil
        if ["failed", "interrupted"].contains(operation.state) {
            failure = DarkbloomFailure(asked.failing, detail: operation.message)
        }
        guard operation.action == "link" else { return }
        if operation.state == "succeeded" {
            if isOn { start() }
        } else {
            alsoServe = false
        }
    }

    private func ask(_ action: DarkbloomAction, failing words: String) {
        guard let control = found?.control else { return }
        failure = nil
        Task {
            do throws(DarkbloomError) {
                asked = (try await control.act(action).id, words)
            } catch {
                failure = DarkbloomFailure(words, detail: error.reason)
                if case .link = action { alsoServe = false }
            }
        }
    }
}
