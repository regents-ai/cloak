import CloakControl

/// The supervisor's state machine: the spec's six states (section 6), with
/// every transition named by the event that causes it. docs/state-machines.md
/// section 9 draws it.
///
/// It starts Paused, on every launch: nothing resumes by itself after a
/// relaunch, a restart or a wake. Any failed requirement stops all work and
/// ends in Needs attention with its reason; nothing is restarted, and no
/// other route or model is tried (REF04).
public enum Phase: Sendable, Equatable {
    /// What a preparation is for.
    public enum Goal: Sendable, Equatable {
        /// Start, and stay Running.
        case run
        /// Check, then stop again and be Ready.
        case verify
    }

    /// Where a shutdown ends.
    public enum Destination: Sendable, Equatable {
        case paused
        case ready
        case needsAttention(Reason)
        /// The app ends once the shutdown has.
        case quit
    }

    case paused
    case preparing(Goal)
    case running
    case ready
    case stopping(Destination)
    case needsAttention(Reason)

    public enum Event: Sendable, Equatable {
        // Asked for, by the menu or `cloak`.
        case start, resume, verify, pause, stop, quit
        // From the system.
        case sleep
        // From the supervisor's own work.
        case prepared
        case failed(Reason)
        case stopped
    }

    /// The phase after `event`, or nil when `event` does not apply here:
    /// a command that is refused, or a late event from work already being
    /// stopped. The same phase back means the event was accepted and
    /// changes nothing.
    public func after(_ event: Event) -> Phase? {
        switch (self, event) {
        // Starting and checking, from wherever nothing runs.
        case (.paused, .start), (.ready, .start), (.needsAttention, .start), (.paused, .resume):
            .preparing(.run)
        case (.paused, .verify), (.ready, .verify), (.needsAttention, .verify):
            .preparing(.verify)
        // A start during a check keeps the stack once the check passes.
        case (.preparing, .start), (.preparing(.run), .resume):
            .preparing(.run)
        case (.preparing(.verify), .verify), (.running, .start), (.running, .resume):
            self
        case (.preparing(.run), .prepared):
            .running
        case (.preparing(.verify), .prepared):
            .stopping(.ready)

        // Every failure stops everything; nothing is tried again.
        case (.preparing, .failed(let reason)), (.running, .failed(let reason)):
            .stopping(.needsAttention(reason))

        // Pausing and stopping. Sleep pauses, so a wake finds nothing running.
        case (.preparing, .pause), (.running, .pause), (.preparing, .sleep), (.running, .sleep):
            .stopping(.paused)
        case (.preparing, .stop), (.running, .stop):
            .stopping(.ready)
        case (.ready, .pause), (.needsAttention, .pause):
            .paused
        case (.paused, .pause), (.paused, .stop), (.ready, .stop), (.needsAttention, .stop),
             (.paused, .sleep), (.ready, .sleep), (.needsAttention, .sleep):
            self

        // Quitting, from anywhere, through the one shutdown.
        case (_, .quit):
            .stopping(.quit)
        case (.stopping(.paused), .stopped):
            .paused
        case (.stopping(.ready), .stopped):
            .ready
        case (.stopping(.needsAttention(let reason)), .stopped):
            .needsAttention(reason)

        default:
            nil
        }
    }

    /// Why a command that does not apply here is refused.
    func refusal(of command: Event) -> Refusal {
        if command == .resume, !isStopping { return .notPaused }
        return .busy
    }

    /// No change is under way: the phase stays until something asks for one
    /// or fails.
    public var isSettled: Bool {
        switch self {
        case .preparing, .stopping: false
        case .paused, .running, .ready, .needsAttention: true
        }
    }

    var isStopping: Bool {
        if case .stopping = self { return true }
        return false
    }

    public var state: State {
        switch self {
        case .paused: .paused
        case .preparing: .preparing
        case .running: .running
        case .ready: .ready
        case .stopping: .stopping
        case .needsAttention: .needsAttention
        }
    }

    /// The spec's status for automation (INS02). Stopping blocks new work:
    /// it is paused, or failed when it ends in Needs attention.
    public var status: Status {
        switch self {
        case .paused, .stopping(.paused), .stopping(.ready), .stopping(.quit): .paused
        case .preparing: .checking
        case .running: .running
        case .ready: .ready
        case .needsAttention(.unsupportedHardware), .stopping(.needsAttention(.unsupportedHardware)): .unsupportedHardware
        case .needsAttention, .stopping(.needsAttention): .failed
        }
    }

    public var reason: Reason? {
        switch self {
        case .needsAttention(let reason), .stopping(.needsAttention(let reason)): reason
        default: nil
        }
    }

    public var nextAction: NextAction {
        switch self {
        case .paused, .ready: .start
        case .preparing, .stopping: .wait
        case .running: .pause
        case .needsAttention(.unsupportedHardware): .none
        case .needsAttention: .start
        }
    }
}
