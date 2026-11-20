import Foundation

/// What `cloak status --json` prints and the app shows: the supervisor's
/// state, the spec's status for automation (INS01, INS02), why it needs
/// attention and what to do next. It never carries prompt text, keys or
/// secrets: nothing here comes from a task.
public struct StatusDocument: Codable, Sendable, Equatable {
    /// Bumped on any change to this document's shape.
    public static let currentVersion = 1

    public var version = currentVersion
    public var release: String
    public var build: String
    public var state: State
    public var status: Status
    public var reason: Reason?
    public var nextAction: NextAction
    public var model: Model
    /// The last startup check, when one has finished since the app opened.
    public var check: Check?
    /// Technical detail, for whoever asks for it.
    public var detail: String

    public init(release: String, build: String, state: State, status: Status, reason: Reason?,
                nextAction: NextAction, model: Model, check: Check?, detail: String) {
        self.release = release
        self.build = build
        self.state = state
        self.status = status
        self.reason = reason
        self.nextAction = nextAction
        self.model = model
        self.check = check
        self.detail = detail
    }

    /// The one model that rewords, named in the app's manifest.
    public struct Model: Codable, Sendable, Equatable {
        public var name: String
        /// The model in plain words, such as "Qwen 3.5 9B".
        public var label: String

        public init(name: String, label: String) {
            self.name = name
            self.label = label
        }
    }

    public struct Check: Codable, Sendable, Equatable {
        public var passed: Bool
        public var at: Date
        public var detail: String

        public init(passed: Bool, at: Date, detail: String) {
            self.passed = passed
            self.at = at
            self.detail = detail
        }
    }
}

/// The supervisor's six states (spec section 6).
public enum State: String, Codable, Sendable, CaseIterable {
    case preparing
    case ready
    case running
    case paused
    case stopping
    case needsAttention = "needs_attention"

    public var title: String {
        switch self {
        case .preparing: "Starting"
        case .ready: "Ready"
        case .running: "Running"
        case .paused: "Paused"
        case .stopping: "Stopping"
        case .needsAttention: "Needs attention"
        }
    }
}

/// The spec's statuses for automation (INS02) that this build produces.
/// needs_os_approval and needs_funding come with the work that can need them.
public enum Status: String, Codable, Sendable, CaseIterable {
    case unsupportedHardware = "unsupported_hardware"
    case checking
    case ready
    case running
    case paused
    case failed
}

/// Why the supervisor needs attention. Each stops all work; none is retried.
public enum Reason: String, Codable, Sendable, CaseIterable {
    case unsupportedHardware = "unsupported_hardware"
    case partMissing = "part_missing"
    case partChanged = "part_changed"
    case modelMissing = "model_missing"
    case modelChanged = "model_changed"
    case torUnavailable = "tor_unavailable"
    case torStopped = "tor_stopped"
    case workerUnavailable = "worker_unavailable"
    case workerStopped = "worker_stopped"
    case guestFailed = "guest_failed"
    case checkFailed = "check_failed"

    /// What went wrong, in a few plain words: one sentence.
    public var title: String {
        switch self {
        case .unsupportedHardware: "This Mac isn't supported."
        case .partMissing: "Part of Cloak is missing."
        case .partChanged: "Part of Cloak has changed."
        case .modelMissing: "The model isn't installed."
        case .modelChanged: "The model has changed."
        case .torUnavailable: "Couldn't connect to Tor."
        case .torStopped: "Tor stopped."
        case .workerUnavailable: "The model couldn't load."
        case .workerStopped: "The model stopped."
        case .guestFailed: "The workspace stopped."
        case .checkFailed: "The startup check failed."
        }
    }

    /// The likely cause, said as likely, and the one thing to do about it.
    /// `cloak` prints it too, so it names no button.
    public var remedy: String {
        switch self {
        case .unsupportedHardware:
            "It likely lacks Apple silicon or enough memory for the model. Use a Mac with Apple silicon and more memory."
        case .partMissing: "A file Cloak needs may have been moved or deleted. Reinstall Cloak."
        case .partChanged: "A file Cloak needs may have been edited or replaced. Reinstall Cloak."
        case .modelMissing: "Its download may not have finished. Download the model, then start again."
        case .modelChanged:
            "A file in its folder may have been added or edited. Delete the model's folder, download it again, then start again."
        case .torUnavailable:
            "The internet may be down, or this network may block Tor. Check your connection, then start again."
        case .torStopped: "It may have quit unexpectedly, or been closed by another app. Start again."
        case .workerUnavailable: "Other apps may be using the memory it needs. Quit some, then start again."
        case .workerStopped: "It may have run out of memory. Quit some apps, then start again."
        case .guestFailed: "This Mac may be short of memory. Quit some apps, then start again."
        case .checkFailed: "The Mac may have been too busy to finish it in time. Start again."
        }
    }
}

/// The one thing to do next.
public enum NextAction: String, Codable, Sendable, CaseIterable {
    case start
    case pause
    /// The supervisor is changing state on its own.
    case wait
    /// Nothing the app can do; the remedy says what can.
    case none
}
