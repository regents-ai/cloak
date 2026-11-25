import Foundation

/// Privacy-safe bridge between Cloak.app and CloakWidgets.appex (Control Center
/// toggles and Desktop Privacy Posture Widget).
///
/// ONLY non-sensitive operational status (phase, cover toggle, active mode,
/// local model readiness, whole-day deposit expiry countdown) is ever written
/// here. Prompts, transcripts, keys, and wallet addresses never enter shared
/// defaults or widget timelines.
public struct WidgetSnapshot: Codable, Sendable, Equatable {
    public var phaseRaw: String
    public var phaseTitle: String
    public var startStepTitle: String?
    public var coverEnabled: Bool
    public var activeMode: String
    public var localReady: Bool
    public var anonVExpiryDays: Int?
    public var servingActive: Bool?
    public var servingModel: String?
    public var servingTPS: Double?
    public var servingRequests: Int?
    public var updatedAt: Date

    public init(
        phaseRaw: String = "paused",
        phaseTitle: String = "Paused",
        startStepTitle: String? = nil,
        coverEnabled: Bool = true,
        activeMode: String = "local",
        localReady: Bool = false,
        anonVExpiryDays: Int? = nil,
        servingActive: Bool? = nil,
        servingModel: String? = nil,
        servingTPS: Double? = nil,
        servingRequests: Int? = nil,
        updatedAt: Date = .now
    ) {
        self.phaseRaw = phaseRaw
        self.phaseTitle = phaseTitle
        self.startStepTitle = startStepTitle
        self.coverEnabled = coverEnabled
        self.activeMode = activeMode
        self.localReady = localReady
        self.anonVExpiryDays = anonVExpiryDays
        self.servingActive = servingActive
        self.servingModel = servingModel
        self.servingTPS = servingTPS
        self.servingRequests = servingRequests
        self.updatedAt = updatedAt
    }

    public var isRunning: Bool { phaseRaw == "running" }
    public var isStarting: Bool { phaseRaw == "preparing" }
    public var isActiveOrStarting: Bool { isRunning || isStarting }

    public var modeLabel: String {
        switch activeMode {
        case "near": "NEAR AI Gateway"
        case "token": "Token Inference"
        case "v": "zkAPI Anon Inference"
        default: "Local"
        }
    }

    public var modeSymbol: String {
        switch activeMode {
        case "near": "cpu"
        case "token": "dollarsign.circle"
        case "v": "theatermasks"
        default: "laptopcomputer"
        }
    }

    public static let placeholder = WidgetSnapshot(
        phaseRaw: "running",
        phaseTitle: "Running",
        startStepTitle: nil,
        coverEnabled: true,
        activeMode: "local",
        localReady: true,
        anonVExpiryDays: nil,
        updatedAt: .now
    )
}

/// Control-only commands sent from Control Center, Desktop Widgets, or `cloak://`
/// deep links. Never carries prompt text.
public enum WidgetCommand: String, Codable, Sendable, CaseIterable {
    case start
    case pause
    case toggleTor
    case enableCover
    case disableCover
    case toggleCover
    case newChat
    case newLocalChat
    case newNearChat
    case newTokenChat
    case newAnonChat
    case openFunds
    case openTour
    case openSettings
    case openServing
}

public enum WidgetBridge {
    /// Team-prefixed macOS App Group shared by `Cloak.app` and `CloakWidgets.appex`.
    public static let appGroup = "367G3Z7G3J.sh.regents.cloak"
    /// Darwin notification posted whenever a Control Center / Widget control sends a command.
    public static let darwinCommandNotification = "sh.regents.cloak.widgetCommand"

    private static let snapshotKey = "cloak.widget.snapshot.v1"
    private static let commandKey = "cloak.widget.command.v1"

    private struct PendingCommand: Codable {
        let id: UUID
        let command: WidgetCommand
        let createdAt: Date
    }

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroup) ?? .standard
    }

    public static func readSnapshot() -> WidgetSnapshot {
        guard let data = defaults.data(forKey: snapshotKey),
            let decoded = try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
        else {
            return WidgetSnapshot()
        }
        return decoded
    }

    public static func writeSnapshot(_ snapshot: WidgetSnapshot) {
        guard !Places.isDev else { return }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: snapshotKey)
    }

    public static func sendCommand(_ command: WidgetCommand) {
        let pending = PendingCommand(id: UUID(), command: command, createdAt: .now)
        if let data = try? JSONEncoder().encode(pending) {
            defaults.set(data, forKey: commandKey)
        }
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(
            center, CFNotificationName(darwinCommandNotification as CFString), nil, nil, true)
    }

    public static func takePendingCommand(maxAge: TimeInterval = 30) -> WidgetCommand? {
        guard let data = defaults.data(forKey: commandKey),
            let pending = try? JSONDecoder().decode(PendingCommand.self, from: data)
        else {
            return nil
        }
        defaults.removeObject(forKey: commandKey)
        guard Date.now.timeIntervalSince(pending.createdAt) <= maxAge else { return nil }
        return pending.command
    }

    /// Active URL scheme for this bundle: `cloak-dev` in isolated Dev builds so
    /// Cloak Dev never intercepts production `cloak://` links, and `cloak` otherwise.
    public static var urlScheme: String {
        Bundle.main.bundleIdentifier == "sh.regents.cloak.dev" ? "cloak-dev" : "cloak"
    }

    public static func actionURL(for command: WidgetCommand) -> URL {
        URL(string: "\(urlScheme)://action/\(command.rawValue)")!
    }

    public static func command(from url: URL) -> WidgetCommand? {
        guard url.scheme?.lowercased() == urlScheme, url.host?.lowercased() == "action" else { return nil }
        let raw = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return WidgetCommand(rawValue: raw)
    }
}
