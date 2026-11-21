import CloakHost
import Foundation
import Observation

/// The owner's agent tasks (decision 12 in docs/plan.md): one at a time in a
/// conversation, any number of conversations at once. A task is a turn of
/// its conversation, kept as it starts and again as it ends; while it runs,
/// its steps so far and the task as the door reworded it are here. Nothing
/// of a task's text, steps or answer is logged.
@MainActor
@Observable
public final class Agent {
    /// What a task needs from the rest of Cloak.
    public struct Parts {
        /// Runs a task in the guest (`Supervisor.run`).
        let run: @MainActor (Runner.Request) -> AsyncThrowingStream<Runner.Event, any Error>
        /// A conversation's box pass, its requests paid as given
        /// (`Door.pass(for:paying:)`): nil while the door is not open.
        let pass: @MainActor (UUID, Payment) -> String?
        /// A conversation's task as the door last reworded it
        /// (`Door.reworded(for:)`).
        let reworded: @MainActor (UUID) -> String?

        public init(
            run: @escaping @MainActor (Runner.Request) -> AsyncThrowingStream<Runner.Event, any Error>,
            pass: @escaping @MainActor (UUID, Payment) -> String?, reworded: @escaping @MainActor (UUID) -> String?
        ) {
            self.run = run
            self.pass = pass
            self.reworded = reworded
        }
    }

    /// A task under way.
    public struct Run {
        /// The task as far as it has come.
        public internal(set) var turn: Turn
        public let started: Date
        let task: Task<Void, Never>
    }

    /// How a task ended without an answer.
    public enum End: Error, Sendable, Equatable {
        /// Its owner pressed Stop.
        case stopped
        /// Cloak paused, stopped or quit with the task under way, or was not
        /// running.
        case cloakStopped
        /// The door was not open, so the agent had no way to the model.
        case unreachable
        /// The agent ended without an answer: the door's sentence for why,
        /// when the door refused its last request; or, before it ran, why
        /// its model could not be had.
        case failed(String?)
    }

    /// By conversation.
    public private(set) var runs: [UUID: Run] = [:]
    /// By turn: the tasks that ended without an answer since this launch.
    public private(set) var ends: [UUID: End] = [:]
    /// The conversations that ran a task since Cloak last started. Only
    /// theirs has the earlier tasks' work: each start is a new guest.
    public private(set) var ran: Set<UUID> = []
    @ObservationIgnored private let parts: Parts

    public init(parts: Parts) {
        self.parts = parts
    }

    /// Cloak has started again, in a new guest.
    public func restarted() {
        ran = []
    }

    /// Runs `task` as a new turn of `conversation`, under way from now, its
    /// model requests paid as `payment` says, unless a task runs there
    /// already, which the guest would refuse. The model comes from `model`
    /// first, which may take a while or throw how the task ends; only then
    /// is the door's pass asked for and the task run in the guest, so a task
    /// stopped meanwhile never runs. `keep` takes the turn as it starts,
    /// then as it ends.
    public func run(
        _ task: String, in conversation: UUID, paying payment: Payment,
        model: @escaping @MainActor () async throws(End) -> String, keep: @escaping (Turn) -> Void
    ) {
        guard runs[conversation] == nil else { return }
        let turn = Turn(original: task, reworded: nil, steps: [])
        runs[conversation] = Run(turn: turn, started: .now, task: Task {
            await follow(task, in: conversation, paying: payment, model: model, keep: keep)
        })
        keep(turn)
    }

    /// Ends the task under way in `conversation`, and everything it started.
    public func stop(_ conversation: UUID) {
        runs[conversation]?.task.cancel()
    }

    /// Has the model, then the door's pass, runs the task in the guest, and
    /// keeps how it ended.
    private func follow(
        _ task: String, in conversation: UUID, paying payment: Payment, model: () async throws(End) -> String,
        keep: (Turn) -> Void
    ) async {
        let ending: Result<String, End>
        do throws(End) {
            let model = try await model()
            guard !Task.isCancelled else { throw .stopped }
            guard let pass = parts.pass(conversation, payment) else { throw .unreachable }
            let request = Runner.Request(task: task, session: conversation.uuidString, model: model, pass: pass)
            ending = await answer(parts.run(request), in: conversation)
        } catch {
            ending = .failure(Task.isCancelled ? .stopped : error)
        }
        guard var turn = runs.removeValue(forKey: conversation)?.turn else { return }
        switch ending {
        case .success(let answer): turn.answer = answer
        case .failure(let end): ends[turn.id] = end
        }
        keep(turn)
    }

    /// Takes the task's events until they end, then how it ended: its
    /// answer when there is one; else its owner's Stop; else Cloak no longer
    /// running; else its last failure, unless the agent went on after it.
    private func answer(_ events: AsyncThrowingStream<Runner.Event, any Error>, in conversation: UUID) async -> Result<String, End> {
        var last: PiEvent?
        var stop: (any Error)?
        do {
            for try await event in events {
                // Standard error, and the exit, say nothing Pi's own lines don't.
                guard case .output(let line) = event else { continue }
                if !ran.contains(conversation) { ran.insert(conversation) }
                switch PiEvent(line: line) {
                case .step(let step)?:
                    // A retried request went through: an earlier failure is not why it ends.
                    last = nil
                    runs[conversation]?.turn.steps?.append(step)
                    learnReworded(in: conversation)
                case .answer(let answer)?:
                    last = .answer(answer)
                    learnReworded(in: conversation)
                case .failure(let sentence)?:
                    last = .failure(sentence)
                case nil:
                    break
                }
            }
        } catch {
            stop = error
        }
        switch (last, stop as? Runner.Stop) {
        // A blank answer is no answer: the task did not finish.
        case (.answer(let answer)?, _) where !answer.allSatisfy(\.isWhitespace): return .success(answer)
        case _ where Task.isCancelled: return .failure(.stopped)
        case (_, .stopped?), (_, .notRunning?): return .failure(.cloakStopped)
        case (.failure(let sentence)?, _): return .failure(.failed(sentence))
        default: return .failure(.failed(nil))
        }
    }

    /// The task as the door reworded it, once a model request of this task
    /// has gone through: the door rewords each request's user messages
    /// before it sends them, and this task is the last of them.
    private func learnReworded(in conversation: UUID) {
        guard runs[conversation]?.turn.reworded == nil, let reworded = parts.reworded(conversation) else { return }
        runs[conversation]?.turn.reworded = reworded
    }
}

/// Why a request to the model is certain to stop if sent now, as Cloak and
/// the wallet last showed: Cloak not running, so nothing is routed through
/// Tor; in Token Inference, no wallet, or, as the network last showed the
/// wallet, no funds; in V, the chain at the latest block read shows the
/// deposit closed. Send and Run are held back for these only: a V request
/// with no deposit goes, and the payer answers it.
public enum Block: Sendable, Equatable {
    case notRunning
    case noWallet
    case noFunds
    case closed

    /// V's: through the payer.
    public init?(running: Bool, closed: Bool) {
        if !running {
            self = .notRunning
        } else if closed {
            self = .closed
        } else {
            return nil
        }
    }

    /// Token Inference's: from the Tempo wallet.
    public init?(running: Bool, hasWallet: Bool, lacksFunds: Bool) {
        if !running {
            self = .notRunning
        } else if !hasWallet {
            self = .noWallet
        } else if lacksFunds {
            self = .noFunds
        } else {
            return nil
        }
    }
}
