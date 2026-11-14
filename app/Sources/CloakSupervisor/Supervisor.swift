import CloakControl
import CloakHost
import Foundation
import Observation
import os

/// The one supervisor the menu-bar app and `cloak` both drive (spec
/// sections 5 and 6). It owns what scripts/boot.py and cloak-host drive in
/// the stage 2 and 3 kits: it checks the installed parts against their pins,
/// starts tor, the worker and a guest, watches them, and stops them all
/// through one shutdown. Its states and transitions are `Phase`'s.
///
/// Running means tor and the worker are up and the startup check sent a
/// rewrite through the guest, the daemon and the worker. Sessions, payment,
/// wallets and cover are not built yet. The guest is a check guest: it runs
/// its cases and powers off.
@MainActor
@Observable
public final class Supervisor {
    public private(set) var phase: Phase = .paused
    /// The last startup check since the app opened.
    public private(set) var check: StatusDocument.Check?
    /// The technical detail of the last failure, until the next start.
    public private(set) var problem: String?
    public let manifest: Manifest

    @ObservationIgnored private let layout: Layout
    @ObservationIgnored private let hardware: Checks.Hardware
    @ObservationIgnored private var stack = Stack()
    @ObservationIgnored private var preparation: Task<Void, Never>?
    @ObservationIgnored private var quitting: (() -> Void)?
    @ObservationIgnored private let logger = Logger(subsystem: "sh.regents.cloak.app", category: "supervisor")

    /// Everything started for one run, each part as soon as it is up, so
    /// that the shutdown stops exactly what started.
    private struct Stack {
        var tor: Tor?
        var worker: WorkerChannel?
        var relay: Relay?
        var verification: Verification?
        var guest: Guest?
        /// One per part, raising its failure if it ends.
        var watches: [Task<Void, Never>] = []
    }

    public convenience init(manifest: Manifest, layout: Layout) throws {
        try self.init(manifest: manifest, layout: layout, hardware: .current)
    }

    /// A guest's boot files carry the relay's channel token and the rewriter
    /// key, and last only while it starts, so an app killed then leaves
    /// them. The supervisor starts by removing those and making the boot
    /// folder, owner-only, for its own guests.
    init(manifest: Manifest, layout: Layout, hardware: Checks.Hardware) throws {
        self.manifest = manifest
        self.layout = layout
        self.hardware = hardware
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
        logger.info("\(String(describing: previous), privacy: .public) --\(String(describing: event), privacy: .public)--> \(String(describing: next), privacy: .public)")
        switch (previous, next) {
        case (.preparing, .preparing), (.stopping, .stopping):
            break
        case (_, .preparing):
            problem = nil
            preparation = Task { await prepare() }
        case (_, .stopping):
            shutDown()
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

    /// Rewords one message through the worker, exactly as the guest's daemon
    /// would (`Rewrite`), while Running. The log has how it ended and how
    /// long it took, never the text.
    public func rewrite(_ text: String) async throws(RewriteStop) -> String {
        guard case .running = phase, let relay = stack.relay else { throw .stopped }
        let started = ContinuousClock.now
        do {
            let reworded = try await Rewrite.run(
                text, model: manifest.model.name, relay: relay,
                deadline: Rewrite.deadline(characters: text.unicodeScalars.count))
            logger.info("rewrite reworded in \(started.duration(to: .now), privacy: .public)")
            return reworded
        } catch {
            logger.info("rewrite \(String(describing: error), privacy: .public) after \(started.duration(to: .now), privacy: .public)")
            throw error
        }
    }

    public var status: StatusDocument {
        manifest.status(of: phase, check: check, detail: detail)
    }

    /// What the state means, the last failure, the processes running, and
    /// the release, build and model.
    public var detail: String {
        var lines = [String]()
        switch phase {
        case .running:
            lines.append("Running: tor and the worker are up, and the startup check sent a rewrite through the guest, the daemon and the worker. Sessions, payment and cover are not built yet.")
        case .ready:
            lines.append("Ready: the startup check passed and everything has stopped again.")
        case .paused:
            lines.append("Paused: nothing is running, and nothing starts by itself.")
        case .preparing:
            lines.append("Preparing: checking the parts, then starting tor, the worker and a guest for the startup check.")
        case .stopping:
            lines.append("Stopping: the guest, the worker and tor, in that order.")
        case .needsAttention(let reason):
            lines.append("Needs attention (\(reason.rawValue)): everything has stopped, and nothing is tried again until Start.")
        }
        if let problem { lines.append(problem) }
        if let check { lines.append("Last check \(check.passed ? "passed" : "failed"): \(check.detail)") }
        if let tor = stack.tor { lines.append("tor: process \(tor.processIdentifier)") }
        if let worker = stack.worker { lines.append("worker: process \(worker.processIdentifier)") }
        lines.append("release \(manifest.release), build \(manifest.build)")
        lines.append("model: \(manifest.model.name), \(manifest.model.label), in \(layout.model(manifest).path)")
        return lines.joined(separator: "\n")
    }

    /// Checks, then starts tor, the worker and the check guest, each only
    /// once the one before it is up. Ends in `prepared`, or in the first
    /// failure; a cancelled preparation starts nothing more.
    private func prepare() async {
        do {
            for case (_, let failure?) in await Checks.run(manifest, layout, hardware: hardware) {
                throw failure
            }
            try Task.checkCancellation()

            let tor: Tor
            do {
                tor = try await Tor.start(executable: layout.url(.tor, in: manifest), data: layout.torData)
            } catch {
                throw Failure(.torUnavailable, "cannot start tor: \(error)")
            }
            stack.tor = tor
            watch("tor", as: .torStopped) { await tor.exited() }
            guard tor.bootstrapped else {
                throw Failure(.torUnavailable, "tor did not bootstrap within 90 seconds of its start, or exited first")
            }
            try Task.checkCancellation()

            let worker: WorkerChannel
            do {
                worker = try await WorkerChannel.start(
                    executable: layout.url(.worker, in: manifest),
                    arguments: ["--name", manifest.model.name, "--dir", layout.model(manifest).path])
            } catch let error as WorkerChannel.NotReady where error.ended == Self.modelChanged {
                throw Failure(.modelChanged, "the worker found the model's files differ from their pins: \(error)")
            } catch {
                throw Failure(.workerUnavailable, "cannot start the worker: \(error)")
            }
            // A lost worker is not replaced: its exit is a failure.
            let relay = Relay(worker: worker) { nil }
            stack.worker = worker
            stack.relay = relay
            watch("the worker", as: .workerStopped) { await worker.exited() }
            try Task.checkCancellation()

            let verification = Verification()
            stack.verification = verification
            let guest: Guest
            do {
                guest = try Guest(kernel: layout.url(.kernel, in: manifest), console: verification.console.fileHandleForWriting,
                                  bootFolder: layout.bootFiles)
                try guest.prepare(base: layout.url(.initrd, in: manifest), cases: Verification.cases,
                                  model: manifest.model.name, relay: relay, tor: tor)
                stack.guest = guest
                try await guest.start { verification.ended($0) }
            } catch {
                throw Failure(.guestFailed, "cannot start the guest: \(error)")
            }
            let detail: String
            do {
                detail = try await verification.passed()
            } catch let failure as Failure {
                check = .init(passed: false, at: .now, detail: failure.detail)
                throw failure
            }
            check = .init(passed: true, at: .now, detail: detail)
            send(.prepared)
        } catch let failure as Failure {
            fail(failure)
        } catch {
            // Cancelled: the shutdown under way stops what has started.
        }
    }

    /// How the worker exits when the model folder does not hold exactly the
    /// pinned files, which only its sha256 check of each file can find
    /// (llama-worker/Sources/cloak-rewriter-llama/main.swift).
    static let modelChanged = Termination(status: 3, signalled: false)

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

    /// The one shutdown: ends the preparation under way, then stops the
    /// guest, the worker and tor, in that order, each within its limit.
    private func shutDown() {
        let preparation = self.preparation
        preparation?.cancel()
        for watch in stack.watches { watch.cancel() }
        Task {
            await preparation?.value
            let stack = self.stack
            self.stack = Stack()
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
    /// The status document for `phase`: this release and model, and what the
    /// phase means for automation.
    func status(of phase: Phase, check: StatusDocument.Check?, detail: String) -> StatusDocument {
        StatusDocument(
            release: release, build: build, state: phase.state, status: phase.status, reason: phase.reason,
            nextAction: phase.nextAction, model: .init(name: model.name, label: model.label), check: check, detail: detail)
    }
}
