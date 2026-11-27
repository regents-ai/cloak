import Foundation
import Observation

/// The Darkbloom Inference Serving state machine (`docs/state-machines.md`,
/// section 9e), isolated from AppKit and CloakSupervisor via `Parts` (matching
/// `Door.Parts` and `Agent.Parts`) so every lifecycle, capability, and payout
/// invariant runs deterministically in `CloakTests`.
@MainActor
@Observable
public final class DarkbloomMode {
    public struct Parts: Sendable {
        public var systemFits: @Sendable () -> Bool
        public var cloakMemory: @MainActor @Sendable () -> UInt64
        public var find: @Sendable () async throws(DarkbloomFailure) -> Darkbloom.Lookup
        public var discoverControl: @Sendable () throws(DarkbloomFailure) -> DarkbloomControlClient?
        public var isDaemonAlive: @Sendable () -> Bool
        public var run: @Sendable (URL, [String], String) async throws(DarkbloomFailure) -> Void
        public var install: @Sendable (@escaping @MainActor @Sendable (Int) -> Void) async throws(DarkbloomFailure) -> Void
        public var capture: @Sendable (URL, [String]) async -> String
        public var readSetup: @Sendable (Bool) async -> DarkbloomSetup
        public var fetchPricing: @Sendable () async -> DarkbloomPricing?
        public var fetchCapabilities: @Sendable (URL) async -> [String: [String]]
        public var hostSupports: @Sendable ([String]) -> Bool
        public var openURL: @MainActor @Sendable (URL) -> Void
        public var loadChosenModel: @MainActor @Sendable () -> String?
        public var saveChosenModel: @MainActor @Sendable (String?) -> Void
        public var qosPolicy: @MainActor @Sendable () -> ServingQoSPolicy
        public var hostCondition: @Sendable () -> ServingHostCondition
        public var pollInterval: Duration
        public var reconnectDelay: Duration

        public init(
            systemFits: @escaping @Sendable () -> Bool = { Darkbloom.systemFits },
            cloakMemory: @escaping @MainActor @Sendable () -> UInt64,
            find: @escaping @Sendable () async throws(DarkbloomFailure) -> Darkbloom.Lookup = { () async throws(DarkbloomFailure) in
                try await Darkbloom.find()
            },
            discoverControl: @escaping @Sendable () throws(DarkbloomFailure) -> DarkbloomControlClient? = { () throws(DarkbloomFailure) in
                try DarkbloomControl.discover().map(DarkbloomControlClient.live)
            },
            isDaemonAlive: @escaping @Sendable () -> Bool = { Darkbloom.isDaemonAlive() },
            run: @escaping @Sendable (URL, [String], String) async throws(DarkbloomFailure) -> Void = { binary, args, failing throws(DarkbloomFailure) in
                try await Darkbloom.run(binary, args, failing: failing)
            },
            install: @escaping @Sendable (@escaping @MainActor @Sendable (Int) -> Void) async throws(DarkbloomFailure) -> Void = { step throws(DarkbloomFailure) in
                try await Darkbloom.install(step: step)
            },
            capture: @escaping @Sendable (URL, [String]) async -> String = { await Darkbloom.capture($0, $1) },
            readSetup: @escaping @Sendable (Bool) async -> DarkbloomSetup = { await Darkbloom.readSetup(listening: $0) },
            fetchPricing: @escaping @Sendable () async -> DarkbloomPricing? = { await Darkbloom.fetchPricing() },
            fetchCapabilities: @escaping @Sendable (URL) async -> [String: [String]] = {
                await Darkbloom.modelRequiredCapabilities($0)
            },
            hostSupports: @escaping @Sendable ([String]) -> Bool = { Darkbloom.hostSupports(requiredCapabilities: $0) },
            openURL: @escaping @MainActor @Sendable (URL) -> Void = { _ in },
            loadChosenModel: @escaping @MainActor @Sendable () -> String? = {
                UserDefaults.standard.string(forKey: DarkbloomMode.modelKey)
            },
            saveChosenModel: @escaping @MainActor @Sendable (String?) -> Void = { value in
                if let value {
                    UserDefaults.standard.set(value, forKey: DarkbloomMode.modelKey)
                } else {
                    UserDefaults.standard.removeObject(forKey: DarkbloomMode.modelKey)
                }
            },
            qosPolicy: @escaping @MainActor @Sendable () -> ServingQoSPolicy = { .default },
            hostCondition: @escaping @Sendable () -> ServingHostCondition = {
                ServingHostCondition(onBattery: false, thermal: .nominal, hour: 12)
            },
            pollInterval: Duration = .seconds(5),
            reconnectDelay: Duration = .seconds(3)
        ) {
            self.systemFits = systemFits
            self.cloakMemory = cloakMemory
            self.find = find
            self.discoverControl = discoverControl
            self.isDaemonAlive = isDaemonAlive
            self.run = run
            self.install = install
            self.capture = capture
            self.readSetup = readSetup
            self.fetchPricing = fetchPricing
            self.fetchCapabilities = fetchCapabilities
            self.hostSupports = hostSupports
            self.openURL = openURL
            self.loadChosenModel = loadChosenModel
            self.saveChosenModel = saveChosenModel
            self.qosPolicy = qosPolicy
            self.hostCondition = hostCondition
            self.pollInterval = pollInterval
            self.reconnectDelay = reconnectDelay
        }
    }

    public enum State: Equatable, Sendable {
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

    public static let modelKey = "darkbloomModel"

    @ObservationIgnored private let parts: Parts
    private var runtime = Runtime.looking
    private var found: Darkbloom.Found?
    public private(set) var snapshot: DarkbloomSnapshot?
    /// Live per-token payout rates from `https://api.darkbloom.dev/v1/pricing`.
    public private(set) var pricing: DarkbloomPricing?
    /// Live account payout balance and settled earnings from `/control/v1/cloud`.
    public private(set) var cloudEarnings: DarkbloomCloudEarnings?
    /// Non-nil when `/control/v1/cloud` returned a refusal or error (e.g. sign-in needed).
    public private(set) var cloudEarningsError: String?
    /// Required runtime capabilities per model ID from `darkbloom models --json`.
    public private(set) var requiredCapabilities: [String: [String]] = [:]
    /// Model IDs dynamically rejected by Darkbloom as permanently ineligible on
    /// this hardware during the session.
    public private(set) var rejectedModelIDs: Set<String> = []
    /// Prompt shown in the Serve Network hero card when the user toggles it ON
    /// before downloading a model.
    public private(set) var needsModelNotice = false
    /// The user's explicitly chosen Darkbloom model ID.
    public private(set) var chosenModelID: String?
    public private(set) var setup = DarkbloomSetup()
    /// Why the person's last press didn't do what it asked; gone at the next.
    private var failure: DarkbloomFailure?
    /// Whether Cloak's Start runs (`darkbloom start`).
    private var starting = false
    /// In-flight control actions Cloak asked for, keyed by operation ID so
    /// back-to-back calls (e.g. cancelling a link then stopping) never clobber
    /// each other's completion or error handling.
    private var asked: [String: String] = [:]
    /// Whether Start serves Darkbloom's network too.
    public private(set) var alsoServe = false
    /// Whether the current `install()` run is upgrading an older install.
    public private(set) var installingUpdate = false
    /// True when the most recent serving status/mode/model change came from
    /// outside Cloak (e.g. `darkbloom start`, `stop`, or `switch` in Terminal).
    public private(set) var lastChangeFromCLI = false
    /// Live monitor telemetry timestamps (Decision N5.2).
    public private(set) var connectedSince: Date?
    public private(set) var lastHeartbeat: Date?
    /// Inline diagnostic output from `darkbloom doctor` / `darkbloom status`.
    public private(set) var diagnosticTitle: String?
    public private(set) var diagnosticOutput: String?
    public private(set) var runningDiagnostic = false
    /// The key while the person has it shown; hidden again when the window closes.
    public private(set) var shownKey: String?
    /// Latest Smart Mac QoS guardrail evaluation (battery, thermal, quiet hours).
    public private(set) var qosDecision: ServingQoSDecision = .allow
    /// True when Cloak automatically paused network serving due to a Mac QoS guardrail
    /// and will resume automatically once the guardrail clears.
    public private(set) var pausedByQoS = false

    @ObservationIgnored private var isWindowOpen = false
    @ObservationIgnored private var lastSetupState: String?
    @ObservationIgnored private var lastSetupReadAt: Date?
    @ObservationIgnored private var lastCloakActionAt: Date?
    @ObservationIgnored private var observedServingSignature: String?
    @ObservationIgnored private var isFollowing = false
    @ObservationIgnored private var following: Task<Void, Never>?
    @ObservationIgnored private var pricingTask: Task<Void, Never>?
    @ObservationIgnored private var capabilitiesTask: Task<Void, Never>?
    @ObservationIgnored private var earningsTask: Task<Void, Never>?
    @ObservationIgnored private var lastEarningsKey: String?
    @ObservationIgnored private var lastEarningsAt: Date?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var startGeneration: UInt64 = 0
    @ObservationIgnored private var followGeneration: UInt64 = 0

    public init(parts: Parts) {
        self.parts = parts
        self.chosenModelID = parts.loadChosenModel()
    }

    public var state: State {
        guard parts.systemFits() else { return .unsupported }
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
            let ready = setup.job?.mode == .onlyMe ? snapshot.endpoint != nil : snapshot.models.contains { $0.serving && $0.loaded }
            return ready ? .serving : .loading
        case "stopped":
            if setup.job?.mode == .onlyMe, setup.job?.running == true { return .loading }
            return recommended?.downloaded == true ? .stopped : .noModel
        case "stale":
            return .failed(DarkbloomFailure("Status out of date", detail: "Darkbloom still serves, but its report is old."))
        default:
            return .failed(DarkbloomFailure("Unknown state", detail: "Darkbloom reports \(snapshot.state), which Cloak doesn't know."))
        }
    }

    /// Whether Darkbloom serves, or is set to, so Stop applies rather than Start.
    public var isOn: Bool {
        guard let snapshot else { return false }
        return starting || ["starting", "running", "draining", "stale"].contains(snapshot.state) || setup.job?.running == true
    }

    public func isModelServing(_ model: DarkbloomSnapshot.Model) -> Bool {
        if model.serving { return true }
        guard isOn, let configured = setup.job?.models, !configured.isEmpty else { return false }
        return configured.contains(model.id)
    }

    /// The release found, once it is checked.
    public var version: String? { found?.version }

    // MARK: The model

    public var eligibleModels: [DarkbloomSnapshot.Model] {
        guard let snapshot, let room else { return [] }
        return snapshot.models
            .filter { model in
                guard model.network && model.eligible && !rejectedModelIDs.contains(model.id) else { return false }
                if let caps = requiredCapabilities[model.id], !parts.hostSupports(caps) {
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

    public var hasDownloadedModel: Bool {
        eligibleModels.contains(where: \.downloaded)
    }

    public enum ServingMode: String, CaseIterable, Identifiable, Sendable {
        case off
        case localOnly
        case network

        public var id: Self { self }

        public var label: String {
            switch self {
            case .off: "Off"
            case .localOnly: "Local Only"
            case .network: "Network + Local"
            }
        }
    }

    public var isServingNetwork: Bool {
        alsoServe && (isOn || linking != nil)
    }

    public var servingMode: ServingMode {
        if linking != nil { return .network }
        guard isOn else { return .off }
        return alsoServe ? .network : .localOnly
    }

    public var topEarnerID: String? {
        eligibleModels.first?.id
    }

    public func price(for model: DarkbloomSnapshot.Model) -> DarkbloomPricing.Price? {
        pricing?.price(for: model.id)
    }

    private func earningScore(for model: DarkbloomSnapshot.Model) -> Double {
        guard let pricing else { return 0 }
        return pricing.price(for: model.id)?.earningScore ?? pricing.fallbackEarningScore
    }

    public var recommended: DarkbloomSnapshot.Model? {
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

    public var needsSwitch: Bool {
        guard isOn, let selected = recommended, selected.downloaded else { return false }
        return !isModelServing(selected)
    }

    public func selectModel(_ id: String) {
        chosenModelID = id
        needsModelNotice = false
        parts.saveChosenModel(id)
    }

    public func activeDownload(for modelID: String) -> DarkbloomSnapshot.Operation? {
        snapshot?.operations.first { $0.state == "running" && $0.action == "download" && $0.model == modelID }
    }

    private static func need(_ model: DarkbloomSnapshot.Model) -> Double? { model.memoryGb ?? model.sizeGb }

    public var room: Double? {
        snapshot?.memory.pinBudgetGb.map { $0 - Double(cloakMemory) / 1_073_741_824 }
    }

    public var cloakMemory: UInt64 {
        parts.cloakMemory()
    }

    public var startBlock: String? {
        guard let found, let snapshot else { return "Not connected" }
        guard found.flags.isSuperset(of: Darkbloom.startNeeds(alsoServe: alsoServe)) else { return "Needs a newer Darkbloom" }
        guard let recommended else { return snapshot.catalogError == nil ? "No model fits" : "Model list unavailable" }
        guard recommended.downloaded else { return "Download above" }
        return nil
    }

    private var download: DarkbloomSnapshot.Operation? {
        snapshot?.operations.first { $0.state == "running" && $0.action == "download" && $0.cancellable }
    }

    /// Linking or dashboard account sign-in under way, with its code and page
    /// once Darkbloom has them.
    public var linking: DarkbloomSnapshot.Link? {
        guard snapshot?.operations.contains(where: {
            $0.state == "running" && ($0.action == "link" || $0.action == "account-signin")
        }) == true else { return nil }
        return snapshot?.link
    }

    public enum Change: Hashable, Sendable {
        case network
        case open
        case forwards

        public var words: String {
            switch self {
            case .network: "Serves Darkbloom's network"
            case .open: "Open beyond this Mac"
            case .forwards: "Your requests can leave this Mac"
            }
        }

        public var start: String {
            switch self {
            case .network: "Darkbloom stops serving its network from this Mac."
            case .open: "Its address answers only apps on this Mac."
            case .forwards: "Your requests stay on this Mac."
            }
        }
    }

    public var changes: [Change] {
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

    public enum Reach: Equatable, Sendable {
        case thisMac
        case beyond
        case forwards
        case unknown
    }

    public var reach: Reach {
        guard let listens = setup.listens, let route = setup.route else { return .unknown }
        guard DarkbloomSetup.loopback(listens) else { return .beyond }
        return route == "this-mac" ? .thisMac : .forwards
    }

    public var canAlsoServe: Bool {
        found?.flags.contains("--me-first") == true
    }

    public var connected: Bool {
        switch runtime {
        case .connected, .connecting, .looking: snapshot != nil
        case .missing, .outdated, .installing, .refused, .offline: false
        }
    }

    // MARK: Presses

    public func open() {
        guard parts.systemFits() else { return }
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

    private func refreshPricing() {
        pricingTask?.cancel()
        pricingTask = Task {
            let fetched = await parts.fetchPricing()
            guard !Task.isCancelled, let fetched else { return }
            self.pricing = fetched
        }
    }

    private func refreshCapabilities(binary: URL) {
        capabilitiesTask?.cancel()
        capabilitiesTask = Task {
            let caps = await parts.fetchCapabilities(binary)
            guard !Task.isCancelled else { return }
            self.requiredCapabilities = caps
        }
    }

    /// Fetches live account balance and settled earnings from Darkbloom's
    /// local `/control/v1/cloud` endpoint.
    public func refreshEarnings(force: Bool = false) {
        guard let control = found?.control, snapshot?.linked == true else {
            cloudEarnings = nil
            cloudEarningsError = nil
            lastEarningsKey = nil
            lastEarningsAt = nil
            return
        }
        let revKey = "\(snapshot?.accountRevision ?? "")|\(snapshot?.resourceRevision ?? "")"
        if !force, lastEarningsKey == revKey,
            let at = lastEarningsAt, Date.now.timeIntervalSince(at) < 30
        {
            return
        }
        lastEarningsKey = revKey
        lastEarningsAt = .now
        earningsTask?.cancel()
        earningsTask = Task {
            do throws(DarkbloomError) {
                let fetched = try await control.cloud()
                guard !Task.isCancelled else { return }
                self.cloudEarnings = fetched
                self.cloudEarningsError = fetched.error
            } catch {
                guard !Task.isCancelled else { return }
                if case .refused(let reason) = error {
                    self.cloudEarningsError = reason
                }
            }
        }
    }

    public func signInAccount() {
        failure = nil
        ask(.accountSignIn, failing: "Couldn't sign in")
    }

    /// Stops following Darkbloom, cancels background tasks, and hides the key;
    /// nothing Darkbloom runs stops.
    public func close() {
        isWindowOpen = false
        following?.cancel()
        following = nil
        isFollowing = false
        pricingTask?.cancel()
        pricingTask = nil
        capabilitiesTask?.cancel()
        capabilitiesTask = nil
        earningsTask?.cancel()
        earningsTask = nil
        shownKey = nil
    }

    public func install(updating: Bool = false) {
        failure = nil
        installingUpdate = updating
        runtime = .installing(0)
        follow {
            do throws(DarkbloomFailure) {
                try await self.parts.install { step in self.runtime = .installing(step) }
            } catch {
                self.runtime = .refused(error)
                return
            }
            await self.look(ensuring: true)
        }
    }

    public func connect() {
        failure = nil
        follow { await self.look(ensuring: true) }
    }

    public func start() {
        guard startBlock == nil, let found, let model = recommended else { return }
        startTask?.cancel()
        startGeneration &+= 1
        let gen = startGeneration
        failure = nil
        lastCloakActionAt = .now
        lastChangeFromCLI = false
        starting = true
        let arguments = Darkbloom.startArguments(model: model.id, alsoServe: alsoServe)
        startTask = Task {
            do throws(DarkbloomFailure) {
                try await parts.run(found.binary, arguments, "Couldn't start")
                guard self.startGeneration == gen, !Task.isCancelled else { return }
                let refreshed = await parts.readSetup(snapshot?.endpoint != nil)
                guard self.startGeneration == gen, !Task.isCancelled else { return }
                self.setup = refreshed
                self.lastSetupReadAt = .now
            } catch {
                if self.startGeneration == gen && !Task.isCancelled {
                    failure = error
                }
            }
            if self.startGeneration == gen {
                starting = false
            }
        }
    }

    public func stop() {
        startTask?.cancel()
        startGeneration &+= 1
        starting = false
        lastCloakActionAt = .now
        lastChangeFromCLI = false
        lastSetupReadAt = nil
        ask(.stop, failing: "Couldn't stop")
    }

    public func downloadModel(_ id: String? = nil) {
        let target = id ?? recommended?.id
        guard let target else { return }
        selectModel(target)
        ask(.download(model: target), failing: "Download failed")
    }

    public func cancelDownload(_ operationID: String? = nil) {
        let targetID = operationID ?? download?.id
        guard let targetID else { return }
        ask(.cancel(operation: targetID), failing: "Couldn't cancel")
    }

    public func removeModel(_ id: String? = nil) {
        let target = id ?? recommended?.id
        guard let target else { return }
        ask(.remove(model: target), failing: "Couldn't remove")
    }

    public func setServingMode(_ target: ServingMode) {
        failure = nil
        needsModelNotice = false
        pausedByQoS = false
        lastCloakActionAt = .now
        lastChangeFromCLI = false
        switch target {
        case .off:
            alsoServe = false
            if let link = snapshot?.operations.first(where: { $0.state == "running" && $0.action == "link" }) {
                ask(.cancel(operation: link.id), failing: "Couldn't cancel")
            }
            if isOn || starting { stop() }
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

    public func setAlsoServe(_ on: Bool) {
        setServingMode(on ? .network : .off)
    }

    public func continueInBrowser() {
        guard let url = linking.flatMap({ URL(string: $0.url) }), url.scheme == "https" else { return }
        parts.openURL(url)
    }

    public func key() async -> String? {
        guard let control = found?.control else { return nil }
        return try? await control.endpointKey()
    }

    public func showKey() async {
        let fetched = await key()
        guard isWindowOpen else { return }
        shownKey = fetched
    }

    public func hideKey() {
        shownKey = nil
    }

    public func runDiagnostic(_ subcommand: String) {
        guard !runningDiagnostic, let binary = found?.binary else { return }
        runningDiagnostic = true
        diagnosticTitle = "darkbloom \(subcommand)"
        diagnosticOutput = nil
        Task {
            let output = await parts.capture(binary, [subcommand])
            diagnosticOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
            runningDiagnostic = false
        }
    }

    public func clearDiagnostic() {
        diagnosticTitle = nil
        diagnosticOutput = nil
    }

    /// Evaluates Mac QoS guardrails (battery, thermal safety, quiet hours).
    /// Auto-pauses network serving when a guardrail triggers and auto-resumes
    /// once host conditions return to `.allow`.
    public func evaluateQoS() {
        let decision = ServingQoS.evaluate(policy: parts.qosPolicy(), condition: parts.hostCondition())
        qosDecision = decision
        switch decision {
        case .pause:
            if alsoServe, isOn, !pausedByQoS {
                pausedByQoS = true
                stop()
            }
        case .allow:
            if pausedByQoS {
                pausedByQoS = false
                if alsoServe, !isOn, startBlock == nil {
                    start()
                }
            }
        }
    }

    // MARK: Following

    private func follow(_ body: @escaping @MainActor () async -> Void) {
        following?.cancel()
        followGeneration &+= 1
        let gen = followGeneration
        isFollowing = true
        following = Task {
            defer {
                if self.followGeneration == gen {
                    self.isFollowing = false
                }
            }
            await body()
        }
    }

    private func look(ensuring: Bool) async {
        if snapshot == nil {
            runtime = ensuring ? .connecting : .looking
        }
        do throws(DarkbloomFailure) {
            var found: Darkbloom.Found
            switch try await parts.find() {
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
            if found.control == nil, ensuring || parts.isDaemonAlive() {
                try await parts.run(found.binary, ["desktop", "ensure"], "Couldn't connect")
                switch try await parts.find() {
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

    private func waitForCLIControl(binary: URL) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: parts.pollInterval)
            guard !Task.isCancelled else { return }
            if let existing = try? parts.discoverControl(), let snap = try? await existing.state(),
                snap.protocol == 1, snap.version == found?.version
            {
                found?.control = existing
                await accept(snap)
                await reports(existing)
                return
            }
            if parts.isDaemonAlive() {
                try? await parts.run(binary, ["desktop", "ensure"], "Couldn't connect")
                if let control = try? parts.discoverControl(), let snap = try? await control.state(),
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

    private func reports(_ control: DarkbloomControlClient) async {
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
                try? await Task.sleep(for: parts.reconnectDelay)
                guard !Task.isCancelled else { return }
                if let next = try? parts.discoverControl() {
                    control = next
                    found?.control = next
                } else if let binary = found?.binary, parts.isDaemonAlive() {
                    try? await parts.run(binary, ["desktop", "ensure"], "Couldn't connect")
                    if let next = try? parts.discoverControl() {
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
        let shouldReadSetup = lastSetupState != snapshot.state
            || lastSetupReadAt.map { Date.now.timeIntervalSince($0) >= 5 } ?? true
        if shouldReadSetup {
            let setup = await parts.readSetup(snapshot.endpoint != nil)
            guard !Task.isCancelled else { return }
            self.setup = setup
            lastSetupState = snapshot.state
            lastSetupReadAt = .now
        }
        self.snapshot = snapshot
        if connectedSince == nil { connectedSince = .now }
        lastHeartbeat = .now
        runtime = .connected
        let linkInFlight = snapshot.operations.contains { $0.state == "running" && $0.action == "link" }
        let linkJustSucceeded = asked.keys.contains { opID in
            snapshot.operations.contains { $0.id == opID && $0.action == "link" && $0.state == "succeeded" }
        }
        let servingModels = Set(
            snapshot.models.filter(\.serving).map(\.id)
                + (setup.job?.running == true ? (setup.job?.models ?? []) : [])
        ).sorted().joined(separator: ",")
        let modeTag = setup.job.map { "\($0.mode)" } ?? "none"
        let signature = "\(snapshot.state)|\(modeTag)|\(servingModels)"
        if let previous = observedServingSignature, previous != signature {
            let triggeredByCloak = starting || !asked.isEmpty
                || lastCloakActionAt.map { Date.now.timeIntervalSince($0) < 12 } == true
            if !triggeredByCloak {
                lastChangeFromCLI = true
            }
        }
        observedServingSignature = signature
        refreshEarnings()
        if !starting, !linkInFlight, !linkJustSucceeded, !pausedByQoS {
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
        evaluateQoS()
        for (opID, failingWords) in asked {
            guard let operation = snapshot.operations.first(where: { $0.id == opID }), operation.state != "running"
            else { continue }
            asked.removeValue(forKey: opID)
            if ["failed", "interrupted"].contains(operation.state) {
                if operation.action == "download", let modelID = operation.model,
                    operation.message.localizedCaseInsensitiveContains("permanently ineligible")
                        || operation.message.localizedCaseInsensitiveContains("missing runtime capabilities")
                {
                    rejectedModelIDs.insert(modelID)
                    if chosenModelID == modelID {
                        chosenModelID = nil
                        parts.saveChosenModel(nil)
                    }
                }
                failure = DarkbloomFailure(failingWords, detail: operation.message)
                if operation.action == "link" { alsoServe = false }
            } else if operation.action == "download", operation.state == "succeeded" {
                needsModelNotice = false
            } else if operation.action == "link", operation.state == "succeeded" {
                refreshEarnings(force: true)
                if alsoServe && startBlock == nil { start() }
            } else if operation.action == "account-signin", operation.state == "succeeded" {
                cloudEarningsError = nil
                refreshEarnings(force: true)
            }
        }
    }

    private func ask(_ action: DarkbloomAction, failing words: String) {
        guard let control = found?.control else { return }
        failure = nil
        Task {
            do throws(DarkbloomError) {
                let op = try await control.act(action)
                asked[op.id] = words
            } catch {
                failure = DarkbloomFailure(words, detail: error.reason)
                if case .link = action { alsoServe = false }
            }
        }
    }
}
