import AppKit
import AppIntents
import CloakControl
import SwiftUI
import WidgetKit

@main
struct CloakWidgetBundle: WidgetBundle {
    var body: some Widget {
        CloakPrivacyWidget()
        CloakTorControl()
        CloakCoverControl()
        CloakNewChatControl()
    }
}

// MARK: - Control Center & Menu Bar Controls (macOS 26+)

struct CloakTorControl: ControlWidget {
    static let kind = "sh.regents.cloak.control.tor"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind, provider: TorStateProvider()) { isRunning in
            ControlWidgetToggle(
                "Cloak",
                isOn: isRunning,
                action: SetCloakRunningWidgetIntent()
            ) { on in
                Label(on ? "Running" : "Paused", systemImage: on ? "lock.shield.fill" : "lock.shield")
            }
        }
        .displayName("Cloak Tor & VM")
        .description("Start or pause Tor, the local rewriter, and the isolated VM.")
    }

    struct TorStateProvider: ControlValueProvider {
        var previewValue: Bool { true }
        func currentValue() async throws -> Bool {
            WidgetBridge.readSnapshot().isActiveOrStarting
        }
    }
}

struct CloakCoverControl: ControlWidget {
    static let kind = "sh.regents.cloak.control.cover"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind, provider: CoverStateProvider()) { enabled in
            ControlWidgetToggle(
                "Cover Traffic",
                isOn: enabled,
                action: SetCoverTrafficWidgetIntent()
            ) { on in
                Label(on ? "On" : "Off", systemImage: "waveform.path")
            }
        }
        .displayName("Cover Traffic")
        .description("Toggle background Tor cover traffic in Cloak.")
    }

    struct CoverStateProvider: ControlValueProvider {
        var previewValue: Bool { true }
        func currentValue() async throws -> Bool {
            WidgetBridge.readSnapshot().coverEnabled
        }
    }
}

struct CloakNewChatControl: ControlWidget {
    static let kind = "sh.regents.cloak.control.newChat"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OpenNewPrivateChatWidgetIntent()) {
                Label("Private Chat", systemImage: "bubble.left.and.text.bubble.right")
            }
        }
        .displayName("New Private Chat")
        .description("Open a fresh private chat in Cloak.")
    }
}

// MARK: - Widget Configuration Intent (macOS 26/27 Editable Widget Settings)

enum CloakWidgetFocus: String, AppEnum {
    case privacy
    case anonV
    case serving

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Widget Focus")

    static let caseDisplayRepresentations: [CloakWidgetFocus: DisplayRepresentation] = [
        .privacy: DisplayRepresentation(title: "Privacy Posture", subtitle: "Tor, Cover Traffic & active mode"),
        .anonV: DisplayRepresentation(title: "zkAPI Deposit Watch", subtitle: "Deposit expiry countdown & Tor"),
        .serving: DisplayRepresentation(title: "Inference Serving", subtitle: "Local provider throughput & health"),
    ]
}

struct CloakWidgetConfigIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Cloak Widget"
    static let description = IntentDescription("Choose what Cloak highlights on your desktop.")

    @Parameter(title: "Focus", default: .privacy)
    var focus: CloakWidgetFocus

    init() { self.focus = .privacy }
    init(focus: CloakWidgetFocus) { self.focus = focus }
}

// MARK: - Widget & Control Intents (Command-Only — Zero Prompt Data)

struct SetCloakRunningWidgetIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Toggle Cloak"

    @Parameter(title: "Running")
    var value: Bool

    init() { self.value = true }
    init(value: Bool) { self.value = value }

    func perform() async throws -> some IntentResult {
        var snapshot = WidgetBridge.readSnapshot()
        snapshot.phaseRaw = value ? "preparing" : "paused"
        snapshot.phaseTitle = value ? "Starting…" : "Paused"
        snapshot.updatedAt = .now
        WidgetBridge.writeSnapshot(snapshot)

        WidgetBridge.sendCommand(value ? .start : .pause)
        if value {
            let url = WidgetBridge.actionURL(for: .start)
            await MainActor.run {
                _ = NSWorkspace.shared.open(url)
            }
        }
        WidgetCenter.shared.reloadAllTimelines()
        ControlCenter.shared.reloadAllControls()
        return .result()
    }
}

struct SetCoverTrafficWidgetIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Toggle Cover Traffic"

    @Parameter(title: "Cover Traffic")
    var value: Bool

    init() { self.value = true }
    init(value: Bool) { self.value = value }

    func perform() async throws -> some IntentResult {
        var snapshot = WidgetBridge.readSnapshot()
        snapshot.coverEnabled = value
        snapshot.updatedAt = .now
        WidgetBridge.writeSnapshot(snapshot)

        WidgetBridge.sendCommand(value ? .enableCover : .disableCover)
        WidgetCenter.shared.reloadAllTimelines()
        ControlCenter.shared.reloadAllControls()
        return .result()
    }
}

struct OpenNewPrivateChatWidgetIntent: AppIntent {
    static let title: LocalizedStringResource = "New Private Chat"
    static let description = IntentDescription("Opens Cloak into a fresh private chat.")

    func perform() async throws -> some IntentResult {
        WidgetBridge.sendCommand(.newChat)
        let url = WidgetBridge.actionURL(for: .newChat)
        await MainActor.run {
            _ = NSWorkspace.shared.open(url)
        }
        return .result()
    }
}

struct OpenCloakFundsWidgetIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Cloak Funds"

    func perform() async throws -> some IntentResult {
        WidgetBridge.sendCommand(.openFunds)
        let url = WidgetBridge.actionURL(for: .openFunds)
        await MainActor.run {
            _ = NSWorkspace.shared.open(url)
        }
        return .result()
    }
}

struct OpenCloakServingWidgetIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Inference Serving"

    func perform() async throws -> some IntentResult {
        WidgetBridge.sendCommand(.openServing)
        let url = WidgetBridge.actionURL(for: .openServing)
        await MainActor.run {
            _ = NSWorkspace.shared.open(url)
        }
        return .result()
    }
}

struct ToggleCloakFromWidgetIntent: AppIntent {
    static let title: LocalizedStringResource = "Start or Pause Cloak"

    func perform() async throws -> some IntentResult {
        let current = WidgetBridge.readSnapshot()
        let nextRunning = !current.isActiveOrStarting
        var updated = current
        updated.phaseRaw = nextRunning ? "preparing" : "paused"
        updated.phaseTitle = nextRunning ? "Starting…" : "Paused"
        updated.updatedAt = .now
        WidgetBridge.writeSnapshot(updated)

        WidgetBridge.sendCommand(nextRunning ? .start : .pause)
        if nextRunning {
            let url = WidgetBridge.actionURL(for: .start)
            await MainActor.run {
                _ = NSWorkspace.shared.open(url)
            }
        }
        WidgetCenter.shared.reloadAllTimelines()
        ControlCenter.shared.reloadAllControls()
        return .result()
    }
}

// MARK: - Live Configurable Desktop / Notification Center Widget

struct CloakPrivacyEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
    let focus: CloakWidgetFocus
}

struct CloakPrivacyProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> CloakPrivacyEntry {
        CloakPrivacyEntry(date: .now, snapshot: .placeholder, focus: .privacy)
    }

    func snapshot(for configuration: CloakWidgetConfigIntent, in context: Context) async -> CloakPrivacyEntry {
        CloakPrivacyEntry(date: .now, snapshot: WidgetBridge.readSnapshot(), focus: configuration.focus)
    }

    func timeline(for configuration: CloakWidgetConfigIntent, in context: Context) async -> Timeline<CloakPrivacyEntry> {
        let entry = CloakPrivacyEntry(date: .now, snapshot: WidgetBridge.readSnapshot(), focus: configuration.focus)
        let nextRefresh = Calendar.current.date(byAdding: .minute, value: 15, to: .now) ?? .now.addingTimeInterval(900)
        return Timeline(entries: [entry], policy: .after(nextRefresh))
    }

    func recommendations() -> [AppIntentRecommendation<CloakWidgetConfigIntent>] {
        [
            AppIntentRecommendation(intent: CloakWidgetConfigIntent(focus: .privacy), description: "Privacy Posture"),
            AppIntentRecommendation(intent: CloakWidgetConfigIntent(focus: .anonV), description: "zkAPI Deposit Watch"),
            AppIntentRecommendation(intent: CloakWidgetConfigIntent(focus: .serving), description: "Inference Serving"),
        ]
    }
}

struct CloakPrivacyWidget: Widget {
    static let kind = "sh.regents.cloak.widget.privacyPosture"

    private static var families: [WidgetFamily] {
        if #available(macOS 27.0, *) {
            return [.systemSmall, .systemMedium, .systemLarge, .systemExtraLargePortrait]
        }
        return [.systemSmall, .systemMedium, .systemLarge]
    }

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: CloakWidgetConfigIntent.self, provider: CloakPrivacyProvider()) { entry in
            CloakPrivacyWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Cloak")
        .description("Live privacy status, zkAPI deposit expiry watch, or local inference serving.")
        .supportedFamilies(Self.families)
    }
}

private struct CloakPrivacyWidgetView: View {
    let entry: CloakPrivacyEntry
    @Environment(\.widgetFamily) private var family

    private var snap: WidgetSnapshot { entry.snapshot }

    private var statusColor: Color {
        switch snap.phaseRaw {
        case "running": .green
        case "preparing", "stopping": .secondary
        case "needsAttention": .red
        default: .yellow
        }
    }

    private var statusText: String {
        if snap.isStarting, let step = snap.startStepTitle {
            return step
        }
        return snap.phaseTitle
    }

    private var headlineText: String {
        switch entry.focus {
        case .privacy:
            statusText
        case .anonV:
            if let days = snap.anonVExpiryDays {
                days == 0 ? "Expires today" : "\(days)d remaining"
            } else {
                snap.isRunning ? "No active deposit" : statusText
            }
        case .serving:
            if snap.servingActive == true {
                if let tps = snap.servingTPS {
                    "\(tps.formatted(.number.precision(.fractionLength(1)))) tok/s"
                } else {
                    "Serving"
                }
            } else {
                "Stopped"
            }
        }
    }

    private var subtitleText: String {
        switch entry.focus {
        case .privacy:
            snap.modeLabel
        case .anonV:
            "zkAPI Anon Inference"
        case .serving:
            snap.servingModel ?? "Inference Serving"
        }
    }

    private var subtitleSymbol: String {
        switch entry.focus {
        case .privacy: snap.modeSymbol
        case .anonV: "theatermasks"
        case .serving: "server.rack"
        }
    }

    var body: some View {
        switch family {
        case .systemSmall:
            smallView
        case .systemMedium:
            mediumView
        default:
            largeView
        }
    }

    private var smallView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "lock.shield.fill")
                    .font(.headline)
                    .foregroundStyle(statusColor)
                Text("Cloak")
                    .font(.headline)
                Spacer()
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(headlineText)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                Label(subtitleText, systemImage: subtitleSymbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                if entry.focus == .anonV {
                    Button(intent: OpenCloakFundsWidgetIntent()) {
                        Label("Funds", systemImage: "creditcard")
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                } else if entry.focus == .serving {
                    Button(intent: OpenCloakServingWidgetIntent()) {
                        Label("Open", systemImage: "server.rack")
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                } else {
                    Button(intent: OpenNewPrivateChatWidgetIntent()) {
                        Label("Chat", systemImage: "plus.bubble")
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

                Button(intent: ToggleCloakFromWidgetIntent()) {
                    Image(systemName: snap.isActiveOrStarting ? "pause.fill" : "play.fill")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(2)
    }

    private var mediumView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield.fill")
                    .font(.title3)
                    .foregroundStyle(statusColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Cloak")
                        .font(.headline)
                    Text(headlineText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                HStack(spacing: 6) {
                    Button(intent: ToggleCloakFromWidgetIntent()) {
                        Label(
                            snap.isActiveOrStarting ? "Pause" : "Start",
                            systemImage: snap.isActiveOrStarting ? "pause.fill" : "play.fill"
                        )
                        .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button(intent: OpenNewPrivateChatWidgetIntent()) {
                        Label("New Chat", systemImage: "plus.bubble")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }

            HStack(spacing: 6) {
                WidgetPill(symbol: subtitleSymbol, text: subtitleText, tint: .accentColor)
                if snap.isRunning {
                    WidgetPill(
                        symbol: "network.badge.shield.half.filled",
                        text: snap.coverEnabled ? "Tor + Cover" : "Tor",
                        tint: .green
                    )
                } else if snap.localReady {
                    WidgetPill(symbol: "laptopcomputer", text: "Offline Ready", tint: .green)
                }
                if let days = snap.anonVExpiryDays {
                    WidgetPill(
                        symbol: "clock",
                        text: "V: \(days)d",
                        tint: days <= 7 ? .orange : .secondary
                    )
                }
                Spacer(minLength: 0)
            }

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
                Text("Zero telemetry · Sealed chats")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(2)
    }

    /// Calm, scannable vertical layout for `.systemLarge` and macOS 27's
    /// `.systemExtraLargePortrait` tall widget.
    private var largeView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield.fill")
                    .font(.title2)
                    .foregroundStyle(statusColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cloak")
                        .font(.headline)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
            }

            Divider().opacity(0.5)

            VStack(spacing: 8) {
                MetricRow(
                    symbol: snap.modeSymbol,
                    label: "Active Mode",
                    value: snap.modeLabel,
                    tint: .accentColor
                )
                MetricRow(
                    symbol: "network.badge.shield.half.filled",
                    label: "Network",
                    value: snap.isRunning ? (snap.coverEnabled ? "Tor + Cover Traffic" : "Tor Connected") : (snap.localReady ? "Offline Ready" : "Paused"),
                    tint: snap.isRunning || snap.localReady ? .green : .secondary
                )
                MetricRow(
                    symbol: "theatermasks",
                    label: "zkAPI Deposit",
                    value: snap.anonVExpiryDays.map { $0 == 0 ? "Expires today" : "\($0) days left" } ?? "Not active",
                    tint: (snap.anonVExpiryDays ?? 99) <= 7 ? .orange : .secondary
                )
                if snap.servingActive == true || entry.focus == .serving {
                    MetricRow(
                        symbol: "server.rack",
                        label: "Inference Serving",
                        value: servingSummary,
                        tint: snap.servingActive == true ? .green : .secondary
                    )
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Button(intent: OpenNewPrivateChatWidgetIntent()) {
                    Label("New Chat", systemImage: "plus.bubble")
                        .font(.callout.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)

                Button(intent: OpenCloakFundsWidgetIntent()) {
                    Label("Funds", systemImage: "creditcard")
                        .font(.callout.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                Button(intent: ToggleCloakFromWidgetIntent()) {
                    Image(systemName: snap.isActiveOrStarting ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }

            HStack(spacing: 6) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
                Text("Zero telemetry · Local prompt rewriting · Sealed chats")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(4)
    }

    private var servingSummary: String {
        guard snap.servingActive == true else { return "Stopped" }
        var parts: [String] = []
        if let tps = snap.servingTPS {
            parts.append("\(tps.formatted(.number.precision(.fractionLength(1)))) tok/s")
        }
        if let reqs = snap.servingRequests {
            parts.append("\(reqs.formatted()) req")
        }
        return parts.isEmpty ? "Serving" : parts.joined(separator: " · ")
    }
}

private struct MetricRow: View {
    let symbol: String
    let label: String
    let value: String
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.callout)
                .foregroundStyle(tint)
                .frame(width: 20, alignment: .center)
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value)
                .font(.callout.weight(.medium))
                .monospacedDigit()
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct WidgetPill: View {
    let symbol: String
    let text: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.14), in: Capsule())
            .foregroundStyle(tint)
            .lineLimit(1)
    }
}
