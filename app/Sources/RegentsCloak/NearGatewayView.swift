import AppKit
import CloakChat
import SwiftUI

/// Top-level tabs shown inside NEAR AI Gateway mode (`Chat.Kind.near`).
enum NearGatewayTab: String, CaseIterable, Identifiable {
    case chat
    case traces
    case insights

    var id: Self { self }

    var title: String {
        switch self {
        case .chat: "Chat"
        case .traces: "Traces"
        case .insights: "Insights"
        }
    }
}

/// Sleek horizontal tab bar rendered at the top of NEAR AI Gateway mode:
/// `Chat` (with live hardware TEE status dot), `Traces` (with count pill), and `Insights`.
struct NearGatewayTabBar: View {
    @Binding var selection: NearGatewayTab
    let chat: Chat
    let showNearSettings: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    private var answeredNearChats: [Conversation] {
        chat.conversations.filter {
            !chat.unsaved.contains($0.id) && !NearTraceExporter.eligibleTurns(in: $0).isEmpty
        }
    }

    private var tracesBadgeCount: Int {
        let traces = chat.nearMode.traces
        if traces.exportedCount > 0 {
            return traces.exportedCount
        }
        return answeredNearChats.count
    }

    private var verificationColor: Color? {
        let mode = chat.nearMode
        if let stop = mode.checkStop {
            let refused = stop.kind == .refused || stop.kind == .pin || stop.kind == .reply
            return refused ? .orange : .secondary
        }
        if let proof = mode.proof {
            let age = Date.now.timeIntervalSince(proof.passedAt)
            let fresh = chat.settings.proofFreshness == .everyMessage
                ? age < 300
                : age < Double(chat.settings.proofFreshness.rawValue)
            return fresh ? .green : .secondary
        }
        return nil
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(NearGatewayTab.allCases) { tab in
                NearGatewayTabItem(
                    tab: tab,
                    selected: selection == tab,
                    dotColor: tab == .chat ? verificationColor : nil,
                    badgeCount: tab == .traces ? tracesBadgeCount : 0,
                    badgeHighlighted: tab == .traces && chat.nearMode.traces.exportedCount > 0,
                    highContrast: contrast == .increased
                ) {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                        selection = tab
                    }
                }
            }

            Spacer(minLength: 8)

            if chat.nearMode.hasKey == false {
                Button {
                    showNearSettings()
                } label: {
                    Label("Add NEAR Key", systemImage: "key")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { chat.nearMode.traces.refresh() }
    }
}

private struct NearGatewayTabItem: View {
    let tab: NearGatewayTab
    let selected: Bool
    let dotColor: Color?
    let badgeCount: Int
    let badgeHighlighted: Bool
    let highContrast: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Text(tab.title)
                        .font(.callout.weight(selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color.primary : Color.secondary)

                    if let dotColor {
                        Circle()
                            .fill(dotColor)
                            .frame(width: 7, height: 7)
                            .accessibilityHidden(true)
                    }

                    if badgeCount > 0 {
                        Text("\(badgeCount)")
                            .font(.caption2.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(badgeHighlighted ? Color.accentColor : Color.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(
                                (badgeHighlighted ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.08)),
                                in: Capsule()
                            )
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 6)

                Rectangle()
                    .fill(selected ? Color.accentColor : Color.clear)
                    .frame(height: 2)
                    .clipShape(Capsule())
            }
            .background(
                hovering && !selected ? Color.primary.opacity(0.04) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Traces Tab

/// Dedicated Trace Commons workspace inside NEAR AI Gateway mode.
/// Manages local Letta Trajectory v1 exports into Cloak's owner-only `Traces`
/// folder (excluded from Time Machine & Spotlight) for handoff to the NEAR AI
/// Gateway app — keeping Cloak's E2EE v2 intact and uploading nothing from Cloak.
struct NearGatewayTracesView: View {
    @Bindable var chat: Chat
    let showNearSettings: () -> Void
    let openChat: (UUID?) -> Void

    @State private var confirmingDisable = false
    @State private var copiedPath = false
    @Environment(\.colorSchemeContrast) private var contrast

    private var traces: NearTraces { chat.nearMode.traces }

    private var nearChats: [Conversation] {
        chat.conversations.filter {
            !chat.unsaved.contains($0.id) && !NearTraceExporter.eligibleTurns(in: $0).isEmpty
        }
    }

    private var notExportedChats: [Conversation] {
        nearChats.filter { !traces.isExported($0.id) }
    }

    private var pendingExportChats: [Conversation] {
        nearChats.filter { !traces.isExported($0.id) || traces.hasNewTurns(for: $0) }
    }

    private var notExportedBytes: Int {
        notExportedChats.reduce(0) { $0 + NearTraceExporter.estimatedBytes(for: $1) }
    }

    private var cardFill: Color {
        Color.primary.opacity(contrast == .increased ? 0.08 : 0.045)
    }

    private var cardStroke: Color {
        Color.primary.opacity(contrast == .increased ? 0.28 : 0.09)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                summarySection
                handoffCard
                if let err = traces.errorMessage {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(err)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                chatsSection
                aboutTraceCommonsCard
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { traces.refresh() }
        .alert(
            "Remove \(traces.exportedCount) exported \(traces.exportedCount == 1 ? "trace" : "traces")?",
            isPresented: $confirmingDisable
        ) {
            Button("Remove Traces", role: .destructive) {
                traces.setEnabled(false, deleteFiles: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The copies in Cloak's Traces folder are deleted. Traces NEAR AI Gateway already submitted stay with Trace Commons until you withdraw them there.")
        }
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Traces")
                .font(.headline)

            HStack(spacing: 10) {
                MetricTile(
                    label: "EXPORTED",
                    value: "\(traces.exportedCount)",
                    subtitle: traces.exportedBytes > 0 ? formattedBytes(traces.exportedBytes) : "Waiting for Gateway",
                    fill: cardFill,
                    stroke: cardStroke
                )
                MetricTile(
                    label: "NOT EXPORTED",
                    value: "\(notExportedChats.count)",
                    subtitle: notExportedBytes > 0 ? formattedBytes(notExportedBytes) : "Eligible NEAR chats",
                    fill: cardFill,
                    stroke: cardStroke
                )
                VStack(alignment: .leading, spacing: 6) {
                    Text("SHARE TRACES")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(.secondary)
                    HStack {
                        Text(chat.settings.nearShareTraces ? "On" : "Off")
                            .font(.title2.weight(.semibold))
                        Spacer(minLength: 8)
                        Toggle(
                            "Share traces",
                            isOn: Binding(
                                get: { chat.settings.nearShareTraces },
                                set: { on in
                                    if on {
                                        traces.setEnabled(true)
                                    } else if traces.exportedCount > 0 {
                                        confirmingDisable = true
                                    } else {
                                        traces.setEnabled(false)
                                    }
                                }
                            )
                        )
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }
                    Text("Opt-in per chat · never automatic")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(cardStroke, lineWidth: 1))
            }
        }
    }

    private var handoffCard: some View {
        let gatewayInstalled = traces.installedGatewayAppURL != nil
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Exported Traces Folder")
                        .font(.subheadline.weight(.semibold))
                    Text("Add Cloak's local Traces folder under **Exported traces** in NEAR AI Gateway. The Gateway runs secret redaction, shows Before/After review, and uploads for NEAR AI credit.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
            }

            HStack(spacing: 8) {
                Button {
                    traces.revealInFinder()
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                .controlSize(.small)

                Button {
                    traces.copyFolderPath()
                    copiedPath = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copiedPath = false
                    }
                } label: {
                    Label(copiedPath ? "Copied Path" : "Copy Path", systemImage: copiedPath ? "checkmark" : "doc.on.doc")
                }
                .controlSize(.small)
                .tip("Paste with ⇧⌘G inside NEAR AI Gateway's folder picker.")

                Spacer(minLength: 0)

                Button {
                    traces.openGatewayAppOrWebsite()
                } label: {
                    Label(
                        gatewayInstalled ? "Open NEAR AI Gateway" : "Get NEAR AI Gateway",
                        systemImage: gatewayInstalled ? "arrow.up.forward.app" : "arrow.up.right.square"
                    )
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(14)
        .background(cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(cardStroke, lineWidth: 1))
    }

    private var chatsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("NEAR AI Gateway Chats")
                    .font(.headline)
                Spacer(minLength: 0)
                if !pendingExportChats.isEmpty, chat.settings.nearShareTraces {
                    let hasUpdates = pendingExportChats.count > notExportedChats.count
                    Button(
                        hasUpdates
                            ? "Export & Update All (\(pendingExportChats.count))"
                            : "Export All Ready (\(pendingExportChats.count))"
                    ) {
                        for conversation in pendingExportChats {
                            traces.export(conversation)
                        }
                    }
                    .controlSize(.small)
                }
            }

            if nearChats.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No NEAR AI Gateway chats yet")
                        .font(.subheadline.weight(.medium))
                    Text("Start a chat in NEAR AI Gateway mode to review token usage and optionally export traces.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Go to Chat") { openChat(nil) }
                        .controlSize(.small)
                        .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(cardStroke, lineWidth: 1))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(nearChats.enumerated()), id: \.element.id) { index, conversation in
                        TraceChatRow(
                            conversation: conversation,
                            exported: traces.file(for: conversation.id),
                            hasNewTurns: traces.hasNewTurns(for: conversation),
                            onOpen: { openChat(conversation.id) },
                            onExport: { traces.export(conversation) },
                            onRemove: { traces.remove(conversation.id) }
                        )
                        if index < nearChats.count - 1 {
                            Divider().padding(.leading, 14)
                        }
                    }
                }
                .background(cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(cardStroke, lineWidth: 1))
            }
        }
    }

    private var aboutTraceCommonsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.shield")
                    .foregroundStyle(.secondary)
                Text("Privacy & Trace Commons (v1.0.19)")
                    .font(.subheadline.weight(.semibold))
            }
            Text("Cloak keeps every NEAR AI Gateway chat end-to-end encrypted (E2EE v2) and never uploads traces itself. Exported files use Letta Trajectory v1 (`source: \"cloak\"`, `Qwen/Qwen3.8-27B`) with only answered turns, kept out of Time Machine and Spotlight. Local, Token Inference, zkAPI Anon Inference, and Agent chats are never exported.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Source & protocol updates: [github.com/TraceCommons/trace-commons](https://github.com/TraceCommons/trace-commons) (supports native adapters for Codex, Claude Code, OpenCode, Cline, Gemini CLI, and Antigravity, plus Exported Traces).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(cardStroke, lineWidth: 1))
    }
}

private struct TraceChatRow: View {
    let conversation: Conversation
    let exported: NearTraceExporter.ExportedFile?
    let hasNewTurns: Bool
    let onOpen: () -> Void
    let onExport: () -> Void
    let onRemove: () -> Void

    @State private var hovering = false

    private var answeredCount: Int {
        NearTraceExporter.eligibleTurns(in: conversation).count
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(conversation.title)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if exported != nil {
                            Text(hasNewTurns ? "Updated" : "Exported")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(hasNewTurns ? .orange : .green)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(
                                    (hasNewTurns ? Color.orange : Color.green).opacity(0.14),
                                    in: Capsule()
                                )
                        }
                    }
                    HStack(spacing: 8) {
                        Text("\(answeredCount) \(answeredCount == 1 ? "turn" : "turns")")
                        if let tokens = conversation.tokens {
                            Text("·")
                            Text("\(formattedTokenCount(tokens.input + tokens.output)) tokens")
                                .monospacedDigit()
                        }
                        Text("·")
                        Text(formattedBytes(exported?.bytes ?? NearTraceExporter.estimatedBytes(for: conversation)))
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 6) {
                if exported != nil {
                    if hasNewTurns {
                        Button("Update", action: onExport)
                            .controlSize(.small)
                    }
                    Button("Remove", role: .destructive, action: onRemove)
                        .controlSize(.small)
                } else {
                    Button("Export Trace", action: onExport)
                        .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(hovering ? Color.primary.opacity(0.035) : Color.clear)
        .onHover { hovering = $0 }
    }
}

// MARK: - Insights Tab

/// Local NEAR AI Gateway insights: live Intel TDX + NVIDIA GPU enclave status,
/// call/token totals counted strictly on this Mac, session breakdown, and NEAR
/// AI Gateway / NEAR AI Red links.
struct NearGatewayInsightsView: View {
    @Bindable var chat: Chat
    let showNearSettings: () -> Void
    let openChat: (UUID?) -> Void
    let openTraces: () -> Void

    @Environment(\.colorSchemeContrast) private var contrast

    private var nearChats: [Conversation] {
        chat.conversations.filter {
            $0.isNear
                && !chat.unsaved.contains($0.id)
                && $0.turns.contains(where: { $0.answer != nil })
        }
    }

    private var totalCalls: Int {
        nearChats.reduce(0) { $0 + $1.turns.filter { $0.answer != nil }.count }
    }

    private var totalInputTokens: Int {
        nearChats.compactMap(\.tokens).reduce(0) { $0 + $1.input }
    }

    private var totalOutputTokens: Int {
        nearChats.compactMap(\.tokens).reduce(0) { $0 + $1.output }
    }

    private var cardFill: Color {
        Color.primary.opacity(contrast == .increased ? 0.08 : 0.045)
    }

    private var cardStroke: Color {
        Color.primary.opacity(contrast == .increased ? 0.28 : 0.09)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                privateAICard
                usageSection
                sessionsSection
                nearAIRedCard
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { chat.nearMode.traces.refresh() }
    }

    private var privateAICard: some View {
        let mode = chat.nearMode
        return VStack(alignment: .leading, spacing: 10) {
            Text("Private AI")
                .font(.headline)

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 12) {
                            HStack(spacing: 4) {
                                Text("Calls")
                                    .foregroundStyle(.secondary)
                                Text("\(totalCalls)")
                                    .fontWeight(.semibold)
                                    .monospacedDigit()
                            }
                            HStack(spacing: 4) {
                                Text("Model")
                                    .foregroundStyle(.secondary)
                                Text(Near.displayModel)
                                    .fontWeight(.semibold)
                            }
                            HStack(spacing: 4) {
                                Text("Route")
                                    .foregroundStyle(.secondary)
                                Text(chat.settings.nearTor ? "Tor" : "Direct")
                                    .fontWeight(.semibold)
                            }
                        }
                        .font(.callout)

                        if let proof = mode.proof {
                            let servers = proof.modelServers == 1 ? "1 enclave server" : "\(proof.modelServers) enclave servers"
                            let gpus = proof.gpus == 1 ? "1 GPU" : "\(proof.gpus) GPUs"
                            Label("Intel TDX + NVIDIA TEE verified · \(servers), \(gpus)", systemImage: "checkmark.shield.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        } else if mode.checking != nil {
                            Label("Checking NEAR's hardware attestation…", systemImage: "shield")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if let stop = mode.checkStop {
                            Label("Hardware check stopped: \(stop.title)", systemImage: "exclamationmark.shield.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        } else {
                            Label(
                                mode.route == nil ? "Start Cloak to verify over Tor" : "Hardware attestation runs before every message",
                                systemImage: "shield"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }

                    Spacer(minLength: 8)

                    Button("Verify Now") {
                        Task { await mode.check() }
                    }
                    .controlSize(.small)
                    .disabled(mode.route == nil || mode.checking != nil)

                    Button("Settings…", action: showNearSettings)
                        .controlSize(.small)
                }
            }
            .padding(14)
            .background(cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(cardStroke, lineWidth: 1))
        }
    }

    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Local Usage")
                    .font(.headline)
                Spacer(minLength: 0)
                Text("Counted on this Mac")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                MetricTile(
                    label: "INPUT TOKENS",
                    value: formattedTokenCount(totalInputTokens),
                    subtitle: "Prompt tokens sent",
                    fill: cardFill,
                    stroke: cardStroke
                )
                MetricTile(
                    label: "OUTPUT TOKENS",
                    value: formattedTokenCount(totalOutputTokens),
                    subtitle: "Completion tokens",
                    fill: cardFill,
                    stroke: cardStroke
                )
                Button(action: openTraces) {
                    MetricTile(
                        label: "TRACES EXPORTED",
                        value: "\(chat.nearMode.traces.exportedCount)",
                        subtitle: "of \(nearChats.count) NEAR \(nearChats.count == 1 ? "chat" : "chats")",
                        fill: cardFill,
                        stroke: cardStroke
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sessions")
                .font(.headline)

            if nearChats.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No sessions recorded yet")
                        .font(.subheadline.weight(.medium))
                    Text("Token counts and verified call metrics appear here as you chat in NEAR AI Gateway mode.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Start Chatting") { openChat(nil) }
                        .controlSize(.small)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(cardStroke, lineWidth: 1))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(nearChats.prefix(12).enumerated()), id: \.element.id) { index, conversation in
                        let turns = conversation.turns.filter { $0.answer != nil }.count
                        let exported = chat.nearMode.traces.isExported(conversation.id)
                        Button {
                            openChat(conversation.id)
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(conversation.title)
                                        .font(.callout.weight(.medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text("\(turns) \(turns == 1 ? "call" : "calls") · \(conversation.created.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                if exported {
                                    Image(systemName: "arrow.up.doc")
                                        .font(.caption)
                                        .foregroundStyle(.green)
                                        .tip("Exported to Cloak's Traces folder")
                                }
                                if let tokens = conversation.tokens {
                                    Text("\(formattedTokenCount(tokens.input)) in · \(formattedTokenCount(tokens.output)) out")
                                        .font(.caption)
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if index < min(nearChats.count, 12) - 1 {
                            Divider().padding(.leading, 14)
                        }
                    }
                }
                .background(cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(cardStroke, lineWidth: 1))
            }
        }
    }

    private var nearAIRedCard: some View {
        let gatewayInstalled = chat.nearMode.traces.installedGatewayAppURL != nil
        return VStack(alignment: .leading, spacing: 8) {
            Text("NEAR AI Red & Gateway")
                .font(.headline)
            Text("NEAR AI Gateway (v1.0.19) adds NEAR AI Red — abliterated DeepSeek V4.1 Flash and Qwen 3.8 in NEAR AI's enclaves for security work — plus coding-agent trace capture (Codex, Claude Code, OpenCode, Cline, Gemini CLI, and Antigravity) and NEAR AI credit payouts.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button {
                    chat.nearMode.traces.openGatewayAppOrWebsite()
                } label: {
                    Label(
                        gatewayInstalled ? "Open NEAR AI Gateway" : "Visit gateway.near.ai",
                        systemImage: gatewayInstalled ? "arrow.up.forward.app" : "arrow.up.right.square"
                    )
                }
                .controlSize(.small)
                Button {
                    NSWorkspace.shared.open(NearTraces.traceCommonsGitHubURL)
                } label: {
                    Label("Trace Commons GitHub", systemImage: "arrow.up.right.square")
                }
                .controlSize(.small)
            }
            .padding(.top, 2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [Color.accentColor.opacity(0.14), Color.accentColor.opacity(0.04)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.24), lineWidth: 1)
        )
    }
}

// MARK: - Shared Helpers

private struct MetricTile: View {
    let label: String
    let value: String
    let subtitle: String
    let fill: Color
    let stroke: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(stroke, lineWidth: 1))
    }
}

private func formattedBytes(_ bytes: Int) -> String {
    if bytes < 1024 {
        return "\(bytes) B"
    }
    let kb = Double(bytes) / 1024
    if kb < 1024 {
        return kb >= 10 ? "\(Int(kb.rounded())) KB" : String(format: "%.1f KB", kb)
    }
    return String(format: "%.1f MB", kb / 1024)
}

private func formattedTokenCount(_ count: Int) -> String {
    if count >= 1_000_000 {
        return String(format: "%.1fM", Double(count) / 1_000_000)
    }
    if count >= 10_000 {
        return String(format: "%.1fk", Double(count) / 1_000)
    }
    return count.formatted()
}
