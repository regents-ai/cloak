// Compiled only by `app/build.sh darkbloom`: Darkbloom's window is in no
// release until its makers allow it (decision 36 in docs/plan.md).
#if DARKBLOOM
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
        /// Installed, but older than the minimum version Cloak requires.
        case needsUpdate(version: String)
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
        case outdated(String)
        case installing(Int)
        case refused(DarkbloomFailure)
        case offline
        case connecting
        case connected
    }

    private static let modelKey = "darkbloomModel"

    private let manifest: Manifest
    private let settings: AppSettings
    private var runtime = Runtime.looking
    private var found: Darkbloom.Found?
    private(set) var snapshot: DarkbloomSnapshot?
    /// Live per-token payout rates from `https://api.darkbloom.dev/v1/pricing`.
    private(set) var pricing: DarkbloomPricing?
    /// Required runtime capabilities per model ID from `darkbloom models --json`
    /// (used to exclude Apple M5-only / `mlx_nax` models on M1–M4 Macs).
    private(set) var requiredCapabilities: [String: [String]] = [:]
    /// Model IDs dynamically rejected by Darkbloom as permanently ineligible on
    /// this hardware during the session.
    private(set) var rejectedModelIDs: Set<String> = []
    /// Prompt shown in the Serve Network hero card when the user toggles it ON
    /// before downloading a model.
    private(set) var needsModelNotice = false
    /// The user's explicitly chosen Darkbloom model ID (persisted in UserDefaults).
    private(set) var chosenModelID: String?
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
    /// Whether the current `install()` run is upgrading an older install.
    private(set) var installingUpdate = false
    /// True when the most recent serving status/mode/model change came from
    /// outside Cloak (e.g. `darkbloom start`, `stop`, or `switch` in Terminal).
    private(set) var lastChangeFromCLI = false
    /// Live monitor telemetry timestamps (Decision N5.2).
    private(set) var connectedSince: Date?
    private(set) var lastHeartbeat: Date?
    /// Inline diagnostic output from `darkbloom doctor` / `darkbloom status`.
    private(set) var diagnosticTitle: String?
    private(set) var diagnosticOutput: String?
    private(set) var runningDiagnostic = false
    /// Tracks whether the Darkbloom window is currently open so async key reads
    /// completing after close never leak into `shownKey`.
    @ObservationIgnored private var isWindowOpen = false
    @ObservationIgnored private var lastSetupState: String?
    @ObservationIgnored private var lastSetupReadAt: Date?
    @ObservationIgnored private var lastCloakActionAt: Date?
    @ObservationIgnored private var observedServingSignature: String?
    @ObservationIgnored private var isFollowing = false
    @ObservationIgnored private var following: Task<Void, Never>?
    @ObservationIgnored private var pricingTask: Task<Void, Never>?
    @ObservationIgnored private var capabilitiesTask: Task<Void, Never>?

    init(manifest: Manifest, settings: AppSettings) {
        self.manifest = manifest
        self.settings = settings
        self.chosenModelID = UserDefaults.standard.string(forKey: Self.modelKey)
    }

    var state: State {
        guard Darkbloom.systemFits else { return .unsupported }
        switch runtime {
        case .looking: return .looking
        case .missing: return failure.map(State.failed) ?? .notSetUp
        case .outdated(let version): return failure.map(State.failed) ?? .needsUpdate(version: version)
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
        return starting || ["starting", "running", "draining", "stale"].contains(snapshot.state) || setup.job?.running == true
    }

    /// True when `model` is currently being served (either reported as
    /// `serving` by `/control/v1/state` or configured via `--model` on a
    /// running `--local` on-demand daemon).
    func isModelServing(_ model: DarkbloomSnapshot.Model) -> Bool {
        if model.serving { return true }
        guard isOn, let configured = setup.job?.models, !configured.isEmpty else { return false }
        return configured.contains(model.id)
    }

    /// The release found, once it is checked.
    var version: String? { found?.version }

    // MARK: The model

    /// All network models Darkbloom can serve on this Mac that fit beside Cloak
    /// and match this Mac's hardware capabilities, ranked highest payout first
    /// using Darkbloom's live `/v1/pricing` rates (falling back to largest model
    /// size when offline).
    var eligibleModels: [DarkbloomSnapshot.Model] {
        guard let snapshot, let room else { return [] }
        return snapshot.models
            .filter { model in
                guard model.network && model.eligible && !rejectedModelIDs.contains(model.id) else { return false }
                if let caps = requiredCapabilities[model.id], !Darkbloom.hostSupports(requiredCapabilities: caps) {
                    return false
                }
                return Self.need(model).map { $0 <= room } == true
            }
            .sorted { lhs, rhs in
                if pricing != nil {
                    let lScore = earningScore(for: lhs)
                    let rScore = earningScore(for: rhs)
                    if abs(lScore - rScore) > 0.0001 { return lScore > rScore }
                }
                let lNeed = Self.need(lhs) ?? 0
                let rNeed = Self.need(rhs) ?? 0
                if abs(lNeed - rNeed) > 0.01 { return lNeed > rNeed }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
    }

    /// True when at least one eligible Darkbloom model is downloaded on this Mac.
    var hasDownloadedModel: Bool {
        eligibleModels.contains(where: \.downloaded)
    }

    /// The three user-facing Darkbloom serving modes controlled by the top
    /// segmented picker in Settings → Inference Serving.
    enum ServingMode: String, CaseIterable, Identifiable, Sendable {
        case off
        case localOnly
        case network

        var id: Self { self }

        var label: String {
            switch self {
            case .off: "Off"
            case .localOnly: "Local Only"
            case .network: "Network + Local"
            }
        }
    }

    /// True when Darkbloom is actively serving (or starting to serve) the network.
    var isServingNetwork: Bool {
        alsoServe && (isOn || linking != nil)
    }

    /// Current effective serving mode reflected in the 3-way picker.
    var servingMode: ServingMode {
        if linking != nil { return .network }
        guard isOn else { return .off }
        return alsoServe ? .network : .localOnly
    }

    /// The #1 highest-earning model this Mac can serve right now.
    var topEarnerID: String? {
        eligibleModels.first?.id
    }

    /// Live Darkbloom token rate for `model`, when pricing has loaded.
    func price(for model: DarkbloomSnapshot.Model) -> DarkbloomPricing.Price? {
        pricing?.price(for: model.id)
    }

    private func earningScore(for model: DarkbloomSnapshot.Model) -> Double {
        guard let pricing else { return 0 }
        return pricing.price(for: model.id)?.earningScore ?? pricing.fallbackEarningScore
    }

    /// The active model selected for serving: the user's explicit choice if it
    /// still fits, otherwise whichever fitting model is currently serving,
    /// otherwise the highest-earning downloaded model, otherwise the #1 highest
    /// earner that fits this Mac.
    var recommended: DarkbloomSnapshot.Model? {
        let fitting = eligibleModels
        guard !fitting.isEmpty else { return nil }
        if let chosenModelID, let match = fitting.first(where: { $0.id == chosenModelID }) {
            return match
        }
        if let active = fitting.first(where: { isModelServing($0) || $0.loaded }) {
            return active
        }
        if let downloaded = fitting.first(where: \.downloaded) {
            return downloaded
        }
        return fitting.first
    }

    /// True when Darkbloom is currently running a different model than the one
    /// the user has selected (and the newly selected model is downloaded).
    var needsSwitch: Bool {
        guard isOn, let selected = recommended, selected.downloaded else { return false }
        return !isModelServing(selected)
    }

    /// Selects a fitting model to download or serve.
    func selectModel(_ id: String) {
        chosenModelID = id
        needsModelNotice = false
        UserDefaults.standard.set(id, forKey: Self.modelKey)
    }

    /// Running download operation for `modelID`, if any.
    func activeDownload(for modelID: String) -> DarkbloomSnapshot.Operation? {
        snapshot?.operations.first { $0.state == "running" && $0.action == "download" && $0.model == modelID }
    }

    private static func need(_ model: DarkbloomSnapshot.Model) -> Double? { model.memoryGb ?? model.sizeGb }

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
        guard recommended.downloaded else { return "Download above" }
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
        case .missing, .outdated, .installing, .refused, .offline: false
        }
    }

    // MARK: Presses

    /// Looks for Darkbloom again and follows it while the window is open;
    /// on a system Darkbloom doesn't run on, nothing. Never cancels an active
    /// install or live stream when the user clicks Darkbloom in the menu bar
    /// again to bring the window forward.
    func open() {
        guard Darkbloom.systemFits else { return }
        isWindowOpen = true
        refreshPricing()
        if case .installing = runtime { return }
        if isFollowing {
            switch runtime {
            case .connected, .connecting, .looking: return
            case .missing, .outdated, .refused, .offline, .installing: break
            }
        }
        failure = nil
        follow { await self.look(ensuring: false) }
    }

    /// Fetches live per-token pricing from Darkbloom's public catalog so
    /// eligible models are ranked highest-earning first.
    private func refreshPricing() {
        pricingTask?.cancel()
        pricingTask = Task {
            let fetched = await DarkbloomPricing.fetch()
            guard !Task.isCancelled, let fetched else { return }
            self.pricing = fetched
        }
    }

    /// Fetches `required_provider_capabilities` via `darkbloom models --json`
    /// in the background so hardware filtering never stalls initial opening.
    private func refreshCapabilities(binary: URL) {
        capabilitiesTask?.cancel()
        capabilitiesTask = Task {
            let caps = await Darkbloom.modelRequiredCapabilities(binary)
            guard !Task.isCancelled else { return }
            self.requiredCapabilities = caps
        }
    }

    /// Stops following Darkbloom, and hides the key; nothing Darkbloom runs stops.
    func close() {
        isWindowOpen = false
        following?.cancel()
        following = nil
        isFollowing = false
        pricingTask?.cancel()
        pricingTask = nil
        capabilitiesTask?.cancel()
        capabilitiesTask = nil
        shownKey = nil
    }

    /// Installs or updates Darkbloom's runtime, then starts its control
    /// service and follows it.
    func install(updating: Bool = false) {
        failure = nil
        installingUpdate = updating
        runtime = .installing(0)
        follow {
            do throws(DarkbloomFailure) {
                try await Darkbloom.install { step in self.runtime = .installing(step) }
            } catch {
                self.runtime = .refused(error)
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
        lastCloakActionAt = .now
        lastChangeFromCLI = false
        starting = true
        let arguments = Darkbloom.startArguments(model: model.id, alsoServe: alsoServe)
        Task {
            do throws(DarkbloomFailure) {
                try await Darkbloom.run(found.binary, arguments, failing: "Couldn't start")
                // Refresh plist/launchd setup immediately before clearing `starting`
                // so the next SSE snapshot never reverts `alsoServe` using stale setup.
                let refreshed = await DarkbloomSetup.read(listening: snapshot?.endpoint != nil)
                self.setup = refreshed
                self.lastSetupReadAt = .now
            } catch {
                failure = error
            }
            starting = false
        }
    }

    func stop() {
        lastCloakActionAt = .now
        lastChangeFromCLI = false
        lastSetupReadAt = nil
        ask(.stop, failing: "Couldn't stop")
    }

    func downloadModel(_ id: String? = nil) {
        let target = id ?? recommended?.id
        guard let target else { return }
        selectModel(target)
        ask(.download(model: target), failing: "Download failed")
    }

    func cancelDownload(_ operationID: String? = nil) {
        let targetID = operationID ?? download?.id
        guard let targetID else { return }
        ask(.cancel(operation: targetID), failing: "Couldn't cancel")
    }

    func removeModel(_ id: String? = nil) {
        let target = id ?? recommended?.id
        guard let target else { return }
        ask(.remove(model: target), failing: "Couldn't remove")
    }

    /// Unified 3-way serving mode controller (`Off` | `Local Only` | `Network + Local`):
    /// - `.off`: stops Darkbloom cleanly (and cancels any pending link).
    /// - `.localOnly`: starts Darkbloom with `--local` (local OpenAI endpoint on this Mac only).
    /// - `.network`: starts Darkbloom with `--me-first` (earns on Darkbloom's network while idle
    ///   and prioritizes local apps), initiating browser linking first if needed.
    func setServingMode(_ target: ServingMode) {
        failure = nil
        needsModelNotice = false
        lastCloakActionAt = .now
        lastChangeFromCLI = false
        switch target {
        case .off:
            alsoServe = false
            if let link = snapshot?.operations.first(where: { $0.state == "running" && $0.action == "link" }) {
                ask(.cancel(operation: link.id), failing: "Couldn't cancel")
                return
            }
            if isOn { stop() }
        case .localOnly:
            guard let model = recommended, model.downloaded else {
                alsoServe = false
                needsModelNotice = true
                return
            }
            if let link = snapshot?.operations.first(where: { $0.state == "running" && $0.action == "link" }) {
                ask(.cancel(operation: link.id), failing: "Couldn't cancel")
            }
            alsoServe = false
            start()
        case .network:
            guard canAlsoServe else { return }
            guard let model = recommended, model.downloaded else {
                alsoServe = false
                needsModelNotice = true
                return
            }
            alsoServe = true
            if snapshot?.linked == false {
                ask(.link, failing: "Couldn't link")
                return
            }
            start()
        }
    }

    func setAlsoServe(_ on: Bool) {
        setServingMode(on ? .network : .off)
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
        let fetched = await key()
        guard isWindowOpen else { return }
        shownKey = fetched
    }

    func hideKey() {
        shownKey = nil
    }

    /// Runs a quick read-only Darkbloom CLI diagnostic (`doctor` or `status`)
    /// and stores its output for inline troubleshooting inside Settings.
    func runDiagnostic(_ subcommand: String) {
        guard !runningDiagnostic, let binary = found?.binary else { return }
        runningDiagnostic = true
        diagnosticTitle = "darkbloom \(subcommand)"
        diagnosticOutput = nil
        Task {
            let output = await Darkbloom.capture(binary, [subcommand])
            diagnosticOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
            runningDiagnostic = false
        }
    }

    func clearDiagnostic() {
        diagnosticTitle = nil
        diagnosticOutput = nil
    }

    // MARK: Following

    private func follow(_ body: @escaping @MainActor () async -> Void) {
        following?.cancel()
        isFollowing = true
        following = Task {
            defer { self.isFollowing = false }
            await body()
        }
    }

    /// Finds and checks the runtime, starts its control service when
    /// `ensuring` and it doesn't answer, then follows its reports until the
    /// window closes.
    private func look(ensuring: Bool) async {
        // Keep showing the last live snapshot while reconnecting so switching
        // tabs doesn't flash back to Setup → Checking.
        if snapshot == nil {
            runtime = ensuring ? .connecting : .looking
        }
        do throws(DarkbloomFailure) {
            var found: Darkbloom.Found
            switch try await Darkbloom.find() {
            case .missing:
                snapshot = nil
                runtime = .missing
                return
            case .outdated(let version):
                snapshot = nil
                runtime = .outdated(version)
                return
            case .ready(let ready):
                found = ready
            }
            if found.control == nil, ensuring || Darkbloom.isDaemonAlive() {
                try await Darkbloom.run(found.binary, ["desktop", "ensure"], failing: "Couldn't connect")
                switch try await Darkbloom.find() {
                case .missing:
                    snapshot = nil
                    runtime = .missing
                    return
                case .outdated(let version):
                    snapshot = nil
                    runtime = .outdated(version)
                    return
                case .ready(let again):
                    found = again
                }
            }
            guard !Task.isCancelled else { return }
            self.found = found
            // Fetch model hardware capabilities in the background so it never
            // delays displaying the connected Inference Serving view.
            refreshCapabilities(binary: found.binary)
            guard let control = found.control, let first = found.snapshot else {
                snapshot = nil
                runtime = .offline
                await waitForCLIControl(binary: found.binary)
                return
            }
            await accept(first)
            await reports(control)
        } catch {
            guard !Task.isCancelled else { return }
            snapshot = nil
            runtime = .refused(error)
        }
    }

    /// While Darkbloom's desktop control API isn't running, polls every 5s so
    /// if the user starts Darkbloom from Terminal (`darkbloom start`), Cloak
    /// automatically attaches and displays live CLI state.
    private func waitForCLIControl(binary: URL) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            if let existing = try? DarkbloomControl.discover(), let snap = try? await existing.state(),
                snap.protocol == 1, snap.version == found?.version
            {
                found?.control = existing
                await accept(snap)
                await reports(existing)
                return
            }
            if Darkbloom.isDaemonAlive() {
                try? await Darkbloom.run(binary, ["desktop", "ensure"], failing: "Couldn't connect")
                if let control = try? DarkbloomControl.discover(), let snap = try? await control.state(),
                    snap.protocol == 1, snap.version == found?.version
                {
                    found?.control = control
                    lastChangeFromCLI = true
                    await accept(snap)
                    await reports(control)
                    return
                }
            }
        }
    }

    /// Follows the control service's reports. Each stream ends after a
    /// minute and is opened again at once; one that breaks is tried again
    /// every 5 seconds, from the service's file each time, since a service
    /// that restarted (e.g. via CLI `darkbloom restart` or `update`) has a
    /// new port and token.
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
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                if let next = try? DarkbloomControl.discover() {
                    control = next
                    found?.control = next
                } else if let binary = found?.binary, Darkbloom.isDaemonAlive() {
                    try? await Darkbloom.run(binary, ["desktop", "ensure"], failing: "Couldn't connect")
                    if let next = try? DarkbloomControl.discover() {
                        control = next
                        found?.control = next
                    } else {
                        snapshot = nil
                        runtime = .offline
                        await waitForCLIControl(binary: binary)
                        return
                    }
                } else {
                    snapshot = nil
                    runtime = .offline
                    if let binary = found?.binary {
                        await waitForCLIControl(binary: binary)
                    }
                    return
                }
            }
        }
    }

    private func accept(_ snapshot: DarkbloomSnapshot) async {
        // Re-read launchd / provider.toml on state changes or every 5 seconds so
        // CLI `darkbloom start` / `stop` / `--local` / `--me-first` changes
        // reflect live in Cloak's Serving status and Serve Network switch.
        let shouldReadSetup = lastSetupState != snapshot.state
            || lastSetupReadAt.map { Date.now.timeIntervalSince($0) >= 5 } ?? true
        if shouldReadSetup {
            let setup = await DarkbloomSetup.read(listening: snapshot.endpoint != nil)
            guard !Task.isCancelled else { return }
            self.setup = setup
            lastSetupState = snapshot.state
            lastSetupReadAt = .now
        }
        self.snapshot = snapshot
        if connectedSince == nil { connectedSince = .now }
        lastHeartbeat = .now
        runtime = .connected
        // Sync Serve Network toggle with live CLI/launchd state whenever Cloak
        // isn't mid-start or mid-link, so starting/stopping via CLI updates UI.
        let linkInFlight = snapshot.operations.contains { $0.state == "running" && $0.action == "link" }
        let servingModels = Set(
            snapshot.models.filter(\.serving).map(\.id)
                + (setup.job?.running == true ? (setup.job?.models ?? []) : [])
        ).sorted().joined(separator: ",")
        let modeTag = setup.job.map { "\($0.mode)" } ?? "none"
        let signature = "\(snapshot.state)|\(modeTag)|\(servingModels)"
        if let previous = observedServingSignature, previous != signature {
            let triggeredByCloak = starting || asked != nil
                || lastCloakActionAt.map { Date.now.timeIntervalSince($0) < 12 } == true
            if !triggeredByCloak {
                lastChangeFromCLI = true
            }
        }
        observedServingSignature = signature
        if !starting, !linkInFlight {
            let daemonActive = ["starting", "running", "draining"].contains(snapshot.state) || setup.job?.running == true
            let networkMode = setup.job?.mode == .both || setup.job?.mode == .network
            let liveAlsoServe = daemonActive && networkMode
            if alsoServe != liveAlsoServe {
                alsoServe = liveAlsoServe
            }
            if daemonActive, failure != nil {
                failure = nil
            }
        }
        guard let asked, let operation = snapshot.operations.first(where: { $0.id == asked.id }), operation.state != "running"
        else { return }
        self.asked = nil
        if ["failed", "interrupted"].contains(operation.state) {
            if operation.action == "download", let modelID = operation.model,
                operation.message.localizedCaseInsensitiveContains("permanently ineligible")
                    || operation.message.localizedCaseInsensitiveContains("missing runtime capabilities")
            {
                rejectedModelIDs.insert(modelID)
                if chosenModelID == modelID {
                    chosenModelID = nil
                    UserDefaults.standard.removeObject(forKey: Self.modelKey)
                }
            }
            failure = DarkbloomFailure(asked.failing, detail: operation.message)
        } else if operation.action == "download", operation.state == "succeeded" {
            needsModelNotice = false
        }
        guard operation.action == "link" else { return }
        if operation.state == "succeeded" {
            if alsoServe && startBlock == nil { start() }
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
#endif
