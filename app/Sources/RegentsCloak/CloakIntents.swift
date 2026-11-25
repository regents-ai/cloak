import AppIntents
import CloakControl
import CloakSupervisor
import Foundation

/// Privacy-safe Spotlight, Shortcuts, and macOS 27 Search-or-Ask control actions.
///
/// Strictly limited to state-control and navigation commands: Cloak NEVER accepts
/// prompt text through Spotlight/Siri and NEVER indexes sealed chats or screen
/// content into OS search/Siri pipelines.
enum CloakModeOption: String, AppEnum {
    case local
    case near
    case token
    case anonV

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Cloak Mode")

    static let caseDisplayRepresentations: [CloakModeOption: DisplayRepresentation] = [
        .local: DisplayRepresentation(title: "Local", subtitle: "Offline on this Mac"),
        .near: DisplayRepresentation(title: "NEAR AI Gateway", subtitle: "Hardware-verified TEE"),
        .token: DisplayRepresentation(title: "Token Inference", subtitle: "Tor + USDC pay-per-prompt"),
        .anonV: DisplayRepresentation(title: "zkAPI Anon Inference", subtitle: "Tor + unlinkable zkAPI"),
    ]

    var chatKind: Chat.Kind {
        switch self {
        case .local: .llama
        case .near: .near
        case .token: .token
        case .anonV: .v
        }
    }
}

struct StartCloakIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Cloak"
    static let description = IntentDescription(
        "Starts Cloak's Tor connection, local prompt rewriter, and isolated VM.",
        categoryName: "Privacy Controls"
    )
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        AppDelegate.current?.handleWidgetCommand(.start)
        return .result(dialog: "Starting Cloak.")
    }
}

struct PauseCloakIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause Cloak"
    static let description = IntentDescription(
        "Pauses Cloak's Tor connection and isolated VM to save memory and battery.",
        categoryName: "Privacy Controls"
    )
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        AppDelegate.current?.handleWidgetCommand(.pause)
        return .result(dialog: "Paused Cloak.")
    }
}

struct ToggleCoverTrafficIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Cover Traffic"
    static let description = IntentDescription(
        "Turns Cloak's background Tor cover traffic on or off.",
        categoryName: "Privacy Controls"
    )
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        AppDelegate.current?.handleWidgetCommand(.toggleCover)
        let on = AppSettings.standard.cover
        return .result(dialog: on ? "Cover traffic is on." : "Cover traffic is off.")
    }
}

struct NewPrivateChatIntent: AppIntent {
    static let title: LocalizedStringResource = "New Private Chat"
    static let description = IntentDescription(
        "Opens a new private chat in Cloak without sharing any prompt text with Spotlight or Siri.",
        categoryName: "Chat"
    )
    static let openAppWhenRun: Bool = true

    @Parameter(title: "Mode")
    var mode: CloakModeOption?

    static var parameterSummary: some ParameterSummary {
        Summary("Open a new \(\.$mode) chat in Cloak")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        AppDelegate.current?.openNewChat(mode: mode?.chatKind)
        return .result()
    }
}

struct OpenCloakFundsIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Cloak Funds"
    static let description = IntentDescription(
        "Opens Cloak's Funds sheet for Token Inference, zkAPI Anon Inference, and NEAR AI Gateway.",
        categoryName: "Navigation"
    )
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppDelegate.current?.showFunds()
        return .result()
    }
}

struct TakeCloakTourIntent: AppIntent {
    static let title: LocalizedStringResource = "Take Cloak Tour"
    static let description = IntentDescription(
        "Opens Cloak's 3-step Welcome Tour.",
        categoryName: "Navigation"
    )
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppDelegate.current?.showTour()
        return .result()
    }
}

struct OpenCloakSettingsIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Cloak Settings"
    static let description = IntentDescription(
        "Opens Cloak's Settings window.",
        categoryName: "Navigation"
    )
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppDelegate.current?.showSettings()
        return .result()
    }
}

struct GetCloakStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Cloak Status"
    static let description = IntentDescription(
        "Returns Cloak's current operational status (Running, Starting, or Paused) for Shortcuts automations. Never accesses chats or keys.",
        categoryName: "Privacy Controls"
    )
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let supervisor = AppDelegate.current?.supervisor
        let phase = supervisor?.phase
        let status: String
        if let phase, phase.state == .preparing {
            status = supervisor?.startStep?.menuTitle ?? "Starting…"
        } else {
            status = phase?.title ?? "Paused"
        }
        let cover = AppSettings.standard.cover ? "Cover traffic on" : "Cover traffic off"
        return .result(value: status, dialog: "Cloak is \(status). \(cover).")
    }
}

struct IsCloakRunningIntent: AppIntent {
    static let title: LocalizedStringResource = "Is Cloak Running"
    static let description = IntentDescription(
        "Returns true when Cloak's Tor connection and isolated VM are running, for conditional Shortcuts automations.",
        categoryName: "Privacy Controls"
    )
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        let running = AppDelegate.current?.supervisor.phase == .running
        return .result(value: running)
    }
}

struct CloakAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: NewPrivateChatIntent(),
            phrases: [
                "New private chat in \(.applicationName)",
                "Start a private chat in \(.applicationName)",
                "Open \(.applicationName) chat",
            ],
            shortTitle: "New Private Chat",
            systemImageName: "bubble.left.and.text.bubble.right"
        )
        AppShortcut(
            intent: StartCloakIntent(),
            phrases: [
                "Start \(.applicationName)",
                "Connect \(.applicationName) to Tor",
            ],
            shortTitle: "Start Cloak",
            systemImageName: "lock.shield.fill"
        )
        AppShortcut(
            intent: PauseCloakIntent(),
            phrases: [
                "Pause \(.applicationName)",
                "Stop \(.applicationName) Tor",
            ],
            shortTitle: "Pause Cloak",
            systemImageName: "pause.circle"
        )
        AppShortcut(
            intent: ToggleCoverTrafficIntent(),
            phrases: [
                "Toggle cover traffic in \(.applicationName)",
                "Switch cover traffic in \(.applicationName)",
            ],
            shortTitle: "Toggle Cover Traffic",
            systemImageName: "waveform.path"
        )
        AppShortcut(
            intent: OpenCloakFundsIntent(),
            phrases: [
                "Open funds in \(.applicationName)",
                "Check \(.applicationName) funds",
            ],
            shortTitle: "Open Funds",
            systemImageName: "creditcard"
        )
        AppShortcut(
            intent: TakeCloakTourIntent(),
            phrases: [
                "Take a tour in \(.applicationName)",
                "Show \(.applicationName) welcome tour",
            ],
            shortTitle: "Take a Tour",
            systemImageName: "sparkles"
        )
    }
}
