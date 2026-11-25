import CloakControl
import CloakHost
import Foundation
import Observation
import os
import Synchronization

/// The one supervisor the menu-bar app and `cloak` both drive (spec
/// sections 5 and 6). It owns what scripts/boot.py and cloak-host drive in
/// the stage 2 and 3 kits: it checks the bundle's parts against their pins,
/// puts the pinned worker where it runs, starts tor, the worker and a guest,
/// watches them, and stops them all through one shutdown. Its states and
/// transitions are `Phase`'s.
///
/// Running means tor is up, the worker is up or resting, the startup check
/// sent a rewrite through the guest, the daemon and the worker, and the
/// guest's sender is ready: the guest stays up while Running, and its end is
/// a failure. The worker rests (`Relay.Resting`) once it has had nothing to
/// reword for the time `restAfter` gives, and the next request starts a new
/// one as the first was started. The sender is Token Inference's way to a
/// remote model, paid from the Tempo wallet (decisions 10 and 25 in
/// docs/plan.md); the payer, which the guest runs with its payment disk
/// (`PaymentDisk`), attached to every run, is V's, paid through zkAPI
/// (decision 24); and the guest's runner runs the owner's agent tasks
/// (decision 12). While the guest is up, its daemon runs its own cover
/// traffic through Tor from the one list in reference/cover.json: the
/// reference's background noise, about three page fetches a minute. When
/// the owner's Cover setting is off as the guest's boot files are written,
/// they lay a list with no URLs over that one, and no cover worker starts
/// in that run. A change of the setting while Running restarts the run
/// (`followCover`), once nothing a restart would cut is under way.
///
/// A Local Llama chat's message (`answer`) goes straight to the chosen
/// model on this Mac (decision 21 in docs/plan.md), and is no phase. When
/// that is the model that rewords and a run is up, it takes its turn at the
/// run's worker. Otherwise it goes to a relay of the app's own (`Local`) for
/// that model: the first message starts its worker, after the checks of the
/// Mac, the model's files and the worker a run makes, without tor or a
/// guest, and the worker rests as a run's does. A failure there stops that
/// message only. A message for another model, a Start and the shutdown end
/// it first and wait for its worker to exit, so two workers never hold the
/// same model; a message it had stops as interrupted.
@MainActor
@Observable
public final class Supervisor {
    /// The real stages `prepare()` walks through while `phase == .preparing`,
    /// in execution order.
    public enum StartStep: Int, CaseIterable, Sendable, Equatable, Identifiable {
        case checking = 0
        case tor = 1
        case rewriter = 2
        case guest = 3
        case verifying = 4

        public var id: Int { rawValue }

        /// Compact 1–3 word label for the menu bar header.
        public var menuTitle: String {
            switch self {
            case .checking: "Checking files…"
            case .tor: "Connecting Tor…"
            case .rewriter: "Loading rewriter…"
            case .guest: "Starting VM…"
            case .verifying: "Verifying checks…"
            }
        }

        /// Descriptive sentence for app windows (Funds, Chat, Settings).
        public func detail(cover: Bool) -> String {
            switch self {
            case .checking: "Checking Mac hardware and verified binaries."
            case .tor: "Connecting to the Tor network."
            case .rewriter: "Loading local prompt rewriter model into memory."
            case .guest:
                cover
                    ? "Booting isolated Linux VM and starting cover traffic."
                    : "Booting isolated Linux VM."
            case .verifying: "Verifying Tor routing, prompt rewriting, and isolation."
            }
        }
    }

    public private(set) var phase: Phase = .paused
    /// The startup stage currently running while `phase == .preparing`; nil otherwise.
    public private(set) var startStep: StartStep?
    /// Whether Cover Traffic is actively sending background Tor requests right now;
    /// nil while Cloak is not running.
    public private(set) var cover: Bool?
    /// Append-only log of Cover Traffic requests sent over Tor.
    public let coverLog = CoverLog()
    /// Whether the user's Cover Traffic setting is currently enabled.
    public var coverPreferred: Bool { wantsCover() }
    /// The last startup check since the app opened.
    public private(set) var check: StatusDocument.Check?
    /// The technical detail of the last failure, until the next start.
    public private(set) var problem: String?
    /// The worker rested while Running: the model is out of memory until the
    /// next request.
    public private(set) var resting = false
    /// How the last start since the app opened started tor and then the
    /// worker: each one's program and arguments, read back from the process
    /// started, as each came up. Kept once the run has ended; the next start
    /// begins them again. Every worker of a run starts the same way.
    public private(set) var commands: [[String]] = []
    /// The worker for Local Llama chats while no run is up.
    private var localWorker = LocalWorker.none
    public let manifest: Manifest
    /// Takes each connection the guest's agent opens to the door port, as a
    /// socket it owns: in the app, the door's. Set before the first start;
    /// with none, the guest's door port leads nowhere.
    @ObservationIgnored public var door: ((Int32) -> Void)?

    @ObservationIgnored private let layout: Layout
    @ObservationIgnored private let hardware: Checks.Hardware
    /// Whether the next guest sends cover traffic: the owner's setting,
    /// asked each time a guest's boot files are written.
    @ObservationIgnored private let wantsCover: @MainActor () -> Bool
    /// How long the worker may go with nothing to reword before it rests;
    /// nil, never. Asked each time that time starts again.
    @ObservationIgnored private let restAfter: @Sendable () -> Duration?
    @ObservationIgnored private var stack = Stack()
    @ObservationIgnored private var preparation: Task<Void, Never>?
    @ObservationIgnored private var quitting: (() -> Void)?
    @ObservationIgnored private var local: Local?
    /// Ends the last local relay's worker. A Start, the shutdown and the next
    /// local worker wait for it.
    @ObservationIgnored private var localEnding: Task<Void, Never>?
    @ObservationIgnored private lazy var coverTraffic = CoverTraffic(log: coverLog)
    @ObservationIgnored private let logger = Logger(subsystem: "sh.regents.cloak.app", category: "supervisor")

    /// Everything started for one run, each part as soon as it is up, so
    /// that the shutdown stops exactly what started.
    private struct Stack {
        var tor: Tor?
        /// The worker serving now; none while it rests.
        var worker: WorkerChannel?
        var relay: Relay?
        var verification: Verification?
        var guest: Guest?
        /// One per part, raising its failure if it ends.
        var watches: [Task<Void, Never>] = []
        var tasks = AgentTasks()
    }

    /// The relay for Local Llama chats with one model (and optional LoRA),
    /// outside a run's, made with the first message after the last one ended,
    /// and what follows its changes.
    private struct Local {
        /// The name of the model its worker loads.
        let model: String
        /// Optional LoRA adapter name loaded alongside `model`.
        let lora: String?
        let relay: Relay
        let ending: Ending
        let follower: Task<Void, Never>
    }

    /// Why a local relay's messages have no answer, once something has
    /// decided: its worker could not start, or a Start or the shutdown ended
    /// it. The first reason given stands.
    private final class Ending: Sendable {
        private let reason = Mutex<AnswerStop?>(nil)

        func record(_ stop: AnswerStop) {
            reason.withLock { $0 = $0 ?? stop }
        }

        var recorded: AnswerStop? {
            reason.withLock { $0 }
        }
    }

    /// What the local relay tells, in order: its worker starts loading, then
    /// the relay's own changes.
    private enum LocalChange: Sendable {
        case loading
        case relay(Relay.Change)
    }

    private enum LocalWorker: Equatable {
        case none
        case loading
        case up(Int32)
    }

    public convenience init(
        manifest: Manifest, layout: Layout, cover: @escaping @MainActor () -> Bool,
        restAfter: @escaping @Sendable () -> Duration?
    ) throws {
        try self.init(manifest: manifest, layout: layout, hardware: .current, cover: cover, restAfter: restAfter)
    }

    /// A guest's boot files carry the relay's channel token and the rewriter
    /// key, and last only while it starts, so an app killed then leaves
    /// them. The supervisor starts by removing those and making the boot
    /// folder, owner-only, for its own guests.
    init(
        manifest: Manifest, layout: Layout, hardware: Checks.Hardware, cover: @escaping @MainActor () -> Bool,
        restAfter: @escaping @Sendable () -> Duration?
    ) throws {
        self.manifest = manifest
        self.layout = layout
        self.hardware = hardware
        wantsCover = cover
        self.restAfter = restAfter
        try Places.makeOwnerOnly(layout.bootFiles)
        try Guest.removeBootFiles(in: layout.bootFiles)
    }

    /// Applies `event`. A command that does not apply in this phase changes
    /// nothing and is refused; an event from work already being stopped is
    /// dropped.
    @discardableResult
    public func send(_ event: Phase.Event) -> Refusal? {
        guard let next = phase.after(event) else { return phase.refusal(of: event) }
        let previous = phase
        phase = next
        // A notice, which the Mac's log keeps; `app/log.sh` reads it back.
        logger.notice("\(String(describing: previous), privacy: .public) --\(String(describing: event), privacy: .public)--> \(String(describing: next), privacy: .public)")
        switch (previous, next) {
        case (.preparing, .preparing), (.stopping, .stopping):
            break
        case (_, .preparing):
            problem = nil
            commands = []
            startStep = .checking
            preparation = Task { await prepare() }
        case (_, .stopping):
            startStep = nil
            shutDown()
        case (_, .running):
            startStep = nil
            syncCover()
        default:
            break
        }
        return nil
    }

    /// Stops everything through the one shutdown, then calls `done`.
    public func quit(then done: @escaping () -> Void) {
        quitting = done
        send(.quit)
    }

    /// The phase once it has settled.
    public func settled() async -> Phase {
        for await phase in Observations({ self.phase }) where phase.isSettled {
            return phase
        }
        return phase
    }

    /// While Running, the active Cover state differs from the setting.
    public var coverChanged: Bool {
        phase == .running && cover.map { $0 != wantsCover() } == true
    }

    /// Starts or stops live host-side Cover Traffic over Tor immediately
    /// without restarting Tor, the local prompt rewriter, or the Linux VM.
    public func syncCover() {
        guard phase == .running, let socket = torSocket else {
            coverTraffic.stop()
            cover = nil
            return
        }
        let on = wantsCover()
        if on {
            coverTraffic.start(torSocket: socket)
        } else {
            coverTraffic.stop()
        }
        cover = on
    }

    /// Cover's switch while Running, the one place that decides when a
    /// restart may run: calls `restart` each time `changed` holds while
    /// nothing a restart would cut is `underWay`, so as soon as the last of
    /// it ends, as observed, with no polling and no timer. It holds no press
    /// back: new work only keeps it waiting. Switched back first, `changed`
    /// no longer holds, and nothing restarts. In the app: `coverChanged`,
    /// the one answer to what is under way, and `send(.restart)`.
    public static func followCover(
        changed: @escaping @MainActor () -> Bool, underWay: @escaping @MainActor () -> Bool,
        restart: @escaping @MainActor () -> Void
    ) async {
        for await due in Observations({ changed() && !underWay() }) where due {
            restart()
        }
    }

    /// Answers one request from `cloak`; a command is answered once it has
    /// settled.
    public func handle(_ request: Request) async -> Response {
        let event: Phase.Event
        switch request.command {
        case .status:
            return Response(refusal: nil, status: status)
        case .doctor:
            let findings = await Checks.run(manifest, layout, hardware: hardware).map(\.0)
            return Response(refusal: nil, status: status, findings: findings)
        case .start: event = .start
        case .resume: event = .resume
        case .pause: event = .pause
        case .stop: event = .stop
        case .verify: event = .verify
        }
        if let refusal = send(event) {
            return Response(refusal: refusal, status: status)
        }
        _ = await settled()
        return Response(refusal: nil, status: status)
    }

    /// Rewords one message's texts through the worker in one call, exactly
    /// as the guest's daemon would (`Rewrite`), while Running. The log has
    /// how it ended and how long it took, never the text.
    public func rewrite(_ texts: [String]) async throws(RewriteStop) -> [String] {
        guard case .running = phase, let relay = stack.relay else { throw .stopped }
        let started = ContinuousClock.now
        do {
            let reworded = try await Rewrite.run(
                texts, model: manifest.model, relay: relay,
                deadline: Rewrite.deadline(characters: Rewrite.characters(texts)))
            logger.info("rewrite reworded in \(started.duration(to: .now), privacy: .public)")
            return reworded
        } catch {
            logger.info("rewrite \(String(describing: error), privacy: .public) after \(started.duration(to: .now), privacy: .public)")
            throw error
        }
    }

    /// The details `draft` leaves open, from the worker while Running
    /// (`Details`, decision 13). Any later request to the worker, a rewrite
    /// above all, has it stop this one first. The log has how it ended and
    /// how long it took, never the draft or its details.
    public func details(for draft: String) async throws(RewriteStop) -> [Detail] {
        guard case .running = phase, let relay = stack.relay else { throw .stopped }
        let started = ContinuousClock.now
        do {
            let details = try await Details.run(draft, model: manifest.model, relay: relay, deadline: Details.deadline)
            logger.info("details answered in \(started.duration(to: .now), privacy: .public)")
            return details
        } catch {
            logger.info("details \(String(describing: error), privacy: .public) after \(started.duration(to: .now), privacy: .public)")
            throw error
        }
    }

    /// `model`'s answer to the last of `messages`, a Local Llama chat's
    /// conversation so far (`LocalLlama`). For the model that rewords while a
    /// run is up, it takes its turn at the run's worker, in order with
    /// rewording, and never gives way; otherwise it goes to the local relay
    /// for `model`, whose worker it starts when none is up. It waits while
    /// Cloak prepares or stops. Cancelling the task stops it. The log has how
    /// it ended and how long it took, never the text.
    /// Whether the local worker for `model` (and optional `lora`) is already
    /// loaded in memory and ready to answer without cold-starting.
    public func isLocalModelWarm(_ model: Manifest.Model, lora: Manifest.Model.Adapter? = nil) -> Bool {
        if phase == .running && model.name == manifest.model && lora == nil {
            return !resting && stack.worker != nil
        }
        guard let local, local.model == model.name, local.lora == lora?.name else { return false }
        if case .up = localWorker { return true }
        return false
    }

    public func answer(
        _ messages: [LocalMessage], with model: Manifest.Model, lora: Manifest.Model.Adapter? = nil,
        onStage: (@Sendable (LocalAnswerStage) -> Void)? = nil,
        onPartial: (@Sendable (String) -> Void)? = nil
    ) async throws(AnswerStop) -> LocalAnswer {
        guard let request = LocalLlama.request(messages) else { throw .tooLong }
        _ = await settled()
        guard !Task.isCancelled else { throw .stopped }
        // A run has its relay from before it is Running until it stops.
        let (relay, ending): (Relay, Ending?) =
            phase == .running && model.name == manifest.model && lora == nil
                ? (stack.relay!, nil)
                : openLocal(model, lora: lora)
        let started = ContinuousClock.now
        let forward: (@Sendable (Data) -> Void)? = onPartial.map { handler in
            { @Sendable payload in
                let text = String(decoding: payload, as: UTF8.self)
                if !text.isEmpty { handler(text) }
            }
        }
        let answer = await relay.answer(
            to: request, as: .conversation,
            onWaking: onStage.map { handler in { @Sendable in handler(.startingModel) } },
            onReady: onStage.map { handler in { @Sendable in handler(.answering) } },
            onPartial: forward)
        do throws(AnswerStop) {
            let reply = try Self.reply(of: answer, cancelled: Task.isCancelled, ending: ending)
            logger.info("Local Llama answered in \(started.duration(to: .now), privacy: .public)")
            return reply
        } catch {
            logger.info("Local Llama \(String(describing: error), privacy: .public) after \(started.duration(to: .now), privacy: .public)")
            throw error
        }
    }

    /// The reply of a Local Llama answer, or why there is none. `ending` is
    /// the local relay's, nil for the run's.
    private static func reply(of answer: Data?, cancelled: Bool, ending: Ending?) throws(AnswerStop) -> LocalAnswer {
        if let answer, answer.prefix(2) == Data([0, 200]), let reply = LocalLlama.answer(answer.dropFirst(2)) {
            return reply
        }
        if cancelled { throw .stopped }
        if let stop = ending?.recorded { throw stop }
        guard let answer else { throw ending == nil ? .interrupted : .failed(.workerStopped) }
        switch UInt16(answer[answer.startIndex]) << 8 | UInt16(answer[answer.startIndex + 1]) {
        case LocalLlama.tooLongStatus: throw .tooLong
        case LocalLlama.thinkingLimitStatus: throw .thinkingLimit
        case Rewrite.cancelledStatus: throw .interrupted
        default: throw .failed(.workerStopped)
        }
    }

    /// The local relay for `model` (and optional `lora`), made when there is
    /// none for it; one open for another model or adapter state is ended first.
    /// When `model` cannot fit in Metal memory concurrently with the rewording
    /// worker (e.g. Unsloth UD-Q3_K_XL on a 24 GB Mac), rests the rewording
    /// relay first before spawning the Local worker.
    private func openLocal(_ model: Manifest.Model, lora: Manifest.Model.Adapter?) -> (Relay, Ending?) {
        if let local {
            if local.model == model.name, local.lora == lora?.name { return (local.relay, local.ending) }
            endLocal(.interrupted)
        }
        let ending = Ending()
        let (changes, change) = AsyncStream.makeStream(of: LocalChange.self)
        let rewriterRelay = manifest.canRunConcurrently(model, hardware: hardware) ? nil : stack.relay
        let start: @Sendable () async throws -> WorkerChannel = {
            [before = localEnding, manifest, layout, hardware, logger, rewriterRelay] in
            change.yield(.loading)
            await before?.value
            await rewriterRelay?.restNow()
            do {
                var checks = [
                    manifest.answerCheck(model, hardware: hardware),
                    Checks.modelCheck(model, in: layout.model(model)),
                ]
                if let lora {
                    let ok = Checks.isInPlace(lora.file, in: layout.adapter(lora))
                    let detail = "\(layout.adapterFile(lora).path): \(ok ? "in place" : "missing or incomplete")"
                    checks.append((Finding(name: "adapter", passed: ok, detail: detail), ok ? nil : Failure(.modelMissing, detail)))
                }
                for case (_, let failure?) in checks {
                    throw failure
                }
                let executable: URL
                var arguments = ["--name", model.name, "--dir", layout.model(model).path]
                switch model.engine {
                case .llama:
                    try await Self.placeWorker(manifest, layout)
                    executable = layout.worker
                    if let lora {
                        arguments += ["--lora", layout.adapterFile(lora).path]
                    }
                case .vmlx:
                    try await Self.placeVmlxWorker(manifest, layout)
                    executable = layout.vmlxWorker
                }
                try Task.checkCancellation()
                do {
                    return try await WorkerChannel.start(executable: executable, arguments: arguments)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw Self.cannotStart(error)
                }
            } catch let failure as Failure {
                logger.error("Local Llama: \(failure.reason.rawValue, privacy: .public): \(failure.detail, privacy: .public)")
                ending.record(.failed(failure.reason))
                throw failure
            }
        }
        let relay = Relay(resting: .init(after: restAfter, start: start, changed: { change.yield(.relay($0)) }))
        let follower = Task {
            for await change in changes {
                guard !Task.isCancelled else { return }
                followLocal(change)
            }
        }
        local = Local(model: model.name, lora: lora?.name, relay: relay, ending: ending, follower: follower)
        return (relay, ending)
    }

    /// What a change to the local worker means: it is shown; one that cannot
    /// start, or ends by itself, ends the local relay, so the next message
    /// starts afresh.
    private func followLocal(_ change: LocalChange) {
        switch change {
        case .loading:
            localWorker = .loading
        case .relay(.woke(let worker)):
            logger.info("a worker is ready for Local Llama chats")
            localWorker = .up(worker.processIdentifier)
        case .relay(.rested):
            logger.info("the worker for Local Llama chats rested")
            localWorker = .none
        case .relay(.cannotWake):
            endLocal()
        case .relay(.exited(let end)):
            logger.error("the worker for Local Llama chats ended (\(String(describing: end), privacy: .public))")
            endLocal()
        }
    }

    /// Ends the local relay, if there is one: a message it has stops with
    /// `reason`, unless one was given first. The worker is ended once the
    /// last local one has.
    private func endLocal(_ reason: AnswerStop? = nil) {
        guard let local else { return }
        self.local = nil
        localWorker = .none
        if let reason { local.ending.record(reason) }
        local.follower.cancel()
        localEnding = Task { [before = localEnding, relay = local.relay] in
            await before?.value
            await relay.finish()
        }
    }

    /// One exchange with the guest's sender while Running (`Sender.exchange`):
    /// the request is built when the sender gives it its turn, and each
    /// deposit change is kept before the sender goes on. The log has how long
    /// it took, never what it carried.
    public func exchange(
        request: @escaping @Sendable () throws -> Data, keep: @escaping @Sendable (Data) throws -> Void
    ) async throws -> Data {
        guard case .running = phase, let guest = stack.guest else { throw Sender.Failure(description: "Cloak is not running") }
        let started = ContinuousClock.now
        defer { logger.info("sender exchange ended after \(started.duration(to: .now), privacy: .public)") }
        let socket = try await guest.connect(to: Sender.port)
        return try await Sender.exchange(socket, request: request, keep: keep)
    }

    /// One Venice request through the guest's sender while Running
    /// (`Sender.stream`): Venice's answer as it comes. Ending the stream
    /// first closes its connection. One under way when Cloak pauses, stops
    /// or quits fails, as an exchange does.
    public func venice(_ request: Data) async throws -> AsyncThrowingStream<Sender.Piece, any Error> {
        guard case .running = phase, let guest = stack.guest else { throw Sender.Failure(description: "Cloak is not running") }
        return Sender.stream(try await guest.connect(to: Sender.port), request: request)
    }

    /// One exchange with the guest's payer while Running (`Pay.exchange`):
    /// the payer's frames as they come, the answer last. Ending the stream
    /// first closes the exchange's connection, which the payer takes as its
    /// cancel. One under way when Cloak pauses, stops or quits ends without
    /// an answer.
    public func pay(_ ask: Pay.Ask, _ payload: Data) async throws -> AsyncThrowingStream<Pay.Event, any Error> {
        guard case .running = phase, let guest = stack.guest else { throw Pay.Failure(description: "Cloak is not running") }
        return Pay.exchange(try await guest.connect(to: Pay.port), ask, payload)
    }

    /// Runs one of the owner's agent tasks in the guest while Running
    /// (`Runner.run`): Pi's events as they come, undecoded, ending with how
    /// it exited. Ending the stream first, as a consumer that stops does,
    /// closes the task's connection, which ends the task and every process
    /// it started. A task under way when Cloak pauses, stops or quits fails
    /// with `Runner.Stop.stopped`, and one asked for while not Running with
    /// `.notRunning`. The log has how each task ended and how long it took,
    /// never what it carried.
    public func run(_ request: Runner.Request) -> AsyncThrowingStream<Runner.Event, any Error> {
        guard case .running = phase, let guest = stack.guest else { return AgentTasks.refused(.notRunning) }
        return stack.tasks.run(request) { try await guest.connect(to: Runner.port) }
    }

    public var status: StatusDocument {
        manifest.status(of: phase, check: check, detail: detail)
    }

    /// tor's SOCKS socket file while Running, for NEAR mode with Tor on; nil
    /// otherwise.
    public var torSocket: String? {
        phase == .running ? stack.tor?.socket : nil
    }

    /// The most recent memory snapshot read asynchronously by `readMemory()`.
    @ObservationIgnored private var lastMemory: Memory?

    /// What Cloak holds in memory now (`Memory`); a guest started for this
    /// run must have its virtual machine among it.
    public func memory() -> Memory {
        let reading = Memory.read(guest: stack.guest != nil)
        lastMemory = reading
        return reading
    }

    /// Reads Cloak's memory footprint off `@MainActor` and caches it for
    /// `detail`.
    public func readMemory() async -> Memory {
        let reading = await Memory.readAsync(guest: stack.guest != nil)
        lastMemory = reading
        return reading
    }

    /// What the state means, the last failure, the processes running, what
    /// Cloak holds in memory now, and the release, build and model.
    public var detail: String {
        var lines = [String]()
        switch phase {
        case .running:
            lines.append("Running: tor is up, the worker is up or resting, the guest opened its payment disk for V's payer, the startup check sent a rewrite through the guest, the daemon and the worker, and the sender is ready for Token Inference.")
            lines.append(
                cover == false
                    ? "Cover traffic is off in this run: the guest's daemon started no cover worker."
                    : "Cover traffic runs in the guest while Cloak is running: the reference's own background noise, about three page fetches a minute through Tor.")
            if coverChanged {
                lines.append("The Cover setting has changed since this run started: Cloak restarts to switch it once nothing under way would be cut.")
            }
        case .ready:
            lines.append(
                localWorker == .none
                    ? "Ready: the startup check passed and everything has stopped again."
                    : "Ready: the startup check passed and everything has stopped again, but for the worker, which runs for Local Llama chats.")
        case .paused:
            lines.append(
                localWorker == .none
                    ? "Paused: nothing is running, and nothing starts by itself."
                    : "Paused: only the worker is running, for Local Llama chats, and nothing else starts by itself.")
        case .preparing:
            if let step = startStep {
                lines.append("Starting: \(step.detail(cover: wantsCover()))")
            } else {
                lines.append("Starting: checking the parts, then starting tor, the worker and the guest, which opens its payment disk, runs the startup check and then starts the sender and the payer.")
            }
        case .stopping(.restart):
            lines.append("Restarting: stopping the guest, the worker and tor, in that order, then starting again.")
        case .stopping:
            lines.append("Stopping: the guest, the worker and tor, in that order.")
        case .needsAttention(let reason):
            lines.append(
                localWorker == .none
                    ? "Needs attention (\(reason.rawValue)): everything has stopped, and nothing is tried again until Start."
                    : "Needs attention (\(reason.rawValue)): everything has stopped but the worker, which runs for Local Llama chats, and nothing is tried again until Start.")
        }
        if let problem { lines.append(problem) }
        if let check { lines.append("Last check \(check.passed ? "passed" : "failed"): \(check.detail)") }
        if let tor = stack.tor { lines.append("tor: process \(tor.processIdentifier)") }
        if let worker = stack.worker {
            lines.append("worker: process \(worker.processIdentifier)")
        } else if resting {
            lines.append("worker: resting; the model is out of memory until the next request")
        }
        switch localWorker {
        case .none: break
        case .loading: lines.append("worker: loading the model for a Local Llama chat")
        case .up(let process): lines.append("worker: process \(process), for Local Llama chats; it rests as a run's does")
        }
        if let lastMemory {
            lines.append(lastMemory.detail)
        }
        lines.append("release \(manifest.release), build \(manifest.build)")
        let model = manifest.rewordingModel
        lines.append("model: \(model.name), \(model.label), in \(layout.model(model).path)")
        return lines.joined(separator: "\n")
    }

    /// Ends the worker for Local Llama chats, then checks, puts the pinned
    /// worker where it runs, and starts tor, the worker and the check guest,
    /// each only once the one before it is up. Ends in `prepared`, or in the
    /// first failure; a cancelled preparation starts nothing more.
    private func prepare() async {
        startStep = .checking
        endLocal(.interrupted)
        await localEnding?.value
        do {
            for case (_, let failure?) in await Checks.run(manifest, layout, hardware: hardware) {
                throw failure
            }
            try await Self.placeWorker(manifest, layout)
            try Task.checkCancellation()

            startStep = .tor
            let tor: Tor
            do {
                tor = try await Tor.start(executable: layout.url(.tor, in: manifest), data: layout.torData)
            } catch {
                throw Failure(.torUnavailable, "cannot start tor: \(error)")
            }
            stack.tor = tor
            commands.append(tor.command)
            watch("tor", as: .torStopped) { await tor.exited() }
            guard tor.bootstrapped else {
                throw Failure(.torUnavailable, "tor did not bootstrap within 90 seconds of its start, or exited first")
            }
            try Task.checkCancellation()

            startStep = .rewriter
            // Every worker of the run, the first and each after a rest,
            // starts the same way.
            let start: @Sendable () async throws -> WorkerChannel = {
                [executable = layout.worker, arguments = ["--name", manifest.model, "--dir", layout.model(manifest.rewordingModel).path]] in
                try await WorkerChannel.start(executable: executable, arguments: arguments)
            }
            let worker: WorkerChannel
            do {
                worker = try await start()
            } catch {
                throw Self.cannotStart(error)
            }
            commands.append(worker.command)
            // The relay owns the worker from here: it rests and wakes it, and
            // tells of each change. A lost worker is not replaced, and a
            // worker that ends by itself or cannot start on a wake is a
            // failure.
            let (changes, change) = AsyncStream.makeStream(of: Relay.Change.self)
            let relay = Relay(worker: worker, resting: .init(after: restAfter, start: start, changed: { change.yield($0) }))
            stack.worker = worker
            stack.relay = relay
            stack.watches.append(Task {
                for await change in changes {
                    guard !Task.isCancelled else { return }
                    follow(change)
                }
            })
            try Task.checkCancellation()

            startStep = .guest
            let disk = try await PaymentDisk.attach(layout.paymentDisk)
            try Task.checkCancellation()

            let verification = Verification()
            stack.verification = verification
            let guest: Guest
            do {
                guest = try Guest(kernel: layout.url(.kernel, in: manifest), console: verification.console.fileHandleForWriting,
                                  bootFolder: layout.bootFiles, disk: disk)
                // Cover Traffic runs live on the host over Tor (`CoverTraffic`) so
                // toggling it takes effect instantly without rebooting the guest VM.
                try await guest.prepare(base: layout.url(.initrd, in: manifest), cases: Verification.cases,
                                  model: manifest.model, relay: relay, tor: tor, cover: false, serve: true, door: door)
                stack.guest = guest
                try await guest.start { verification.ended($0) }
            } catch {
                throw Failure(.guestFailed, "cannot start the guest: \(error)")
            }

            startStep = .verifying
            let detail: String
            do {
                detail = try await verification.passed()
            } catch let failure as Failure {
                check = .init(passed: false, at: .now, detail: failure.detail)
                throw failure
            }
            check = .init(passed: true, at: .now, detail: detail)
            stack.watches.append(Task {
                let end = await verification.end()
                guard !Task.isCancelled else { return }
                fail(Failure(.guestFailed, "the guest ended (\(end.map { "\($0)" } ?? "its console closed"))"))
            })
            send(.prepared)
        } catch let failure as Failure {
            fail(failure)
        } catch {
            // Cancelled: the shutdown under way stops what has started.
            startStep = nil
        }
    }

    /// Makes the worker where it runs (`Layout.worker`) the pinned one. When
    /// the file there is missing or is not the pinned one, it is replaced by
    /// a copy of the bundle's worker, which the checks have just matched to
    /// its pin, byte for byte, so it keeps the signature that puts it in its
    /// sandbox. The copy is written under a new name in the same folder and
    /// renamed over the file, so a cut copy never sits under the real name
    /// and a signed program is never written over in place, which macOS may
    /// then refuse to run. Then the file there is checked against the pin.
    @concurrent
    private static func placeWorker(_ manifest: Manifest, _ layout: Layout) async throws(Failure) {
        guard let pin = manifest.pins.first(where: { $0.part == .worker }) else {
            throw Failure(.partMissing, "worker: not pinned in manifest")
        }
        try await placeFile(pin: pin, bundled: layout.url(pin), target: layout.worker, permissions: 0o755)
    }

    /// Places the pure-Swift vMLX worker and its sibling `default.metallib`
    /// shader bundle into `Application Support/Regents Cloak/worker/`, verifying
    /// both against their SHA-256 pins.
    @concurrent
    private static func placeVmlxWorker(_ manifest: Manifest, _ layout: Layout) async throws(Failure) {
        guard let workerPin = manifest.pins.first(where: { $0.part == .vmlxWorker }),
            let metalPin = manifest.pins.first(where: { $0.part == .vmlxMetallib })
        else {
            throw Failure(.partMissing, "vmlx_worker: not bundled in this build")
        }
        try await placeFile(pin: metalPin, bundled: layout.url(metalPin), target: layout.vmlxMetallib, permissions: 0o644)
        try await placeFile(pin: workerPin, bundled: layout.url(workerPin), target: layout.vmlxWorker, permissions: 0o755)
    }

    @concurrent
    private static func placeFile(pin: Manifest.Pin, bundled: URL, target: URL, permissions: Int) async throws(Failure) {
        if (try? await Checks.sha256(target)) == pin.sha256 { return }
        let folder = target.deletingLastPathComponent()
        let partial = folder.appending(path: ".\(UUID().uuidString).partial")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(contentsOf: bundled).write(to: partial, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: partial.path)
            guard rename(partial.path, target.path) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw Failure(.partMissing, "\(pin.part.rawValue): cannot copy \(bundled.path) to \(target.path): \(error)")
        }
        if case (_, let failure?) = await Checks.pinCheck(pin, at: target) { throw failure }
    }

    /// How the worker exits when the model folder does not hold exactly the
    /// pinned files, which only its sha256 check of each file can find
    /// (llama-worker/Sources/cloak-rewriter-llama/main.swift).
    nonisolated static let modelChanged = Termination(status: 3, signalled: false)

    /// Why a worker did not start, at Start, on a wake or for a Local Llama
    /// chat: the model's files differ from their pins, or anything else.
    private nonisolated static func cannotStart(_ error: any Error) -> Failure {
        if let error = error as? WorkerChannel.NotReady, error.ended == modelChanged {
            return Failure(.modelChanged, "the worker found the model's files differ from their pins: \(error)")
        }
        return Failure(.workerUnavailable, "cannot start the worker: \(error)")
    }

    /// What a change to the worker means while this run lasts: a rest or a
    /// wake is shown; a worker that cannot wake, or ends by itself, is a
    /// failure, as the first one's would be.
    private func follow(_ change: Relay.Change) {
        switch change {
        case .rested:
            logger.info("the worker rested; the model is out of memory until the next request")
            stack.worker = nil
            resting = true
        case .woke(let worker):
            logger.info("a new worker is ready")
            stack.worker = worker
            resting = false
        case .cannotWake(let error):
            fail(Self.cannotStart(error))
        case .exited(let end):
            fail(Failure(.workerStopped, "the worker ended (\(end))"))
        }
    }

    /// Raises `reason` if the part ends while this run lasts.
    private func watch(_ name: String, as reason: Reason, exited: @escaping @Sendable () async -> Termination) {
        stack.watches.append(Task {
            let end = await exited()
            guard !Task.isCancelled else { return }
            fail(Failure(reason, "\(name) ended (\(end))"))
        })
    }

    /// Records the failure and stops everything, unless it comes from work
    /// already being stopped.
    private func fail(_ failure: Failure) {
        guard phase.after(.failed(failure.reason)) != nil else { return }
        logger.error("\(failure.reason.rawValue, privacy: .public): \(failure.detail, privacy: .public)")
        problem = failure.detail
        send(.failed(failure.reason))
    }

    /// The one shutdown: ends the preparation, the agent's tasks under way
    /// and the worker for Local Llama chats, then stops the guest, the
    /// worker and tor, in that order, each within its limit.
    private func shutDown() {
        coverTraffic.stop()
        let preparation = self.preparation
        preparation?.cancel()
        for watch in stack.watches { watch.cancel() }
        stack.tasks.stop()
        endLocal(.interrupted)
        Task {
            await preparation?.value
            await localEnding?.value
            let stack = self.stack
            self.stack = Stack()
            resting = false
            cover = nil
            for watch in stack.watches { watch.cancel() }
            try? await stack.guest?.stop()
            stack.verification?.close()
            await stack.relay?.finish()
            await stack.tor?.stop()
            if case .stopping(.quit) = phase {
                quitting?()
            } else {
                send(.stopped)
            }
        }
    }
}

extension Manifest {
    /// The status document for `phase`: this release and the model that
    /// rewords, and what the phase means for automation.
    func status(of phase: Phase, check: StatusDocument.Check?, detail: String) -> StatusDocument {
        StatusDocument(
            release: release, build: build, state: phase.state, status: phase.status, reason: phase.reason,
            nextAction: phase.nextAction, model: .init(name: rewordingModel.name, label: rewordingModel.label), check: check,
            detail: detail)
    }
}
