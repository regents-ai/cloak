import AppKit
import CloakChat
import CloakControl
import CloakSupervisor
import SwiftUI
import UniformTypeIdentifiers

/// The Chat window: conversations on the left, newest first; the one shown
/// on the right, each message as written and as reworded, side by side (or
/// as written alone when it goes so), and its answer once sent, with the box
/// to write the next one at the bottom. In the agent's conversations, each
/// task in place of a message, with the steps the agent took. In NEAR
/// Private AI's conversations, each message as written and its answer; in
/// Local Llama's, each message as written and the answer of the model on
/// this Mac. The mode's mark is at the top. The Modes page shows on it as a
/// sheet.
struct ChatView: View {
    @Bindable var chat: Chat
    let showDetails: () -> Void
    let showAgents: () -> Void
    let showNearSettings: () -> Void
    let showLlamaSettings: () -> Void
    let showLocalAccessSettings: () -> Void
    let showAdvancedSettings: () -> Void
    let showServingSettings: (() -> Void)?

    static func window(
        _ chat: Chat, showDetails: @escaping () -> Void, showAgents: @escaping () -> Void,
        showNearSettings: @escaping () -> Void, showLlamaSettings: @escaping () -> Void,
        showLocalAccessSettings: @escaping () -> Void = {},
        showAdvancedSettings: @escaping () -> Void = {},
        showServingSettings: (() -> Void)? = nil
    ) -> NSWindow {
        let window = ClosingWindow(
            contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Chat"
        window.titleVisibility = .hidden
        // Escape cancels a rewording here.
        window.closesOnEscape = false
        window.onKeyEquivalent = { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // Command-Shift-Delete (Backspace 51 or Forward Delete 117):
            // deletes the selected thread immediately and selects the prior one.
            if flags == [.command, .shift], event.keyCode == 51 || event.keyCode == 117 {
                chat.deleteSelected()
                return true
            }
            // Command-Shift-D toggles offline Local Voice dictation when a chat is active.
            if flags == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "d" {
                guard chat.isOpen, chat.selected != nil else { return false }
                chat.voice.toggleDictation(currentDraft: { chat.draft }) { updated in
                    chat.draft = updated
                }
                return true
            }
            guard flags == .command, let key = event.charactersIgnoringModifiers else { return false }
            switch key {
            case "n" where chat.isOpen:
                chat.newConversation()
                return true
            case "1":
                chat.selectMode(.llama)
                return true
            case "2":
                chat.selectMode(.near)
                return true
            case "3":
                chat.selectMode(.token)
                return true
            case "4":
                chat.selectMode(.v)
                return true
            case "/":
                chat.showingTour = true
                return true
            default:
                return false
            }
        }
        let content = NSHostingController(
            rootView: ChatView(
                chat: chat, showDetails: showDetails, showAgents: showAgents, showNearSettings: showNearSettings,
                showLlamaSettings: showLlamaSettings, showLocalAccessSettings: showLocalAccessSettings,
                showAdvancedSettings: showAdvancedSettings, showServingSettings: showServingSettings))
        content.sceneBridgingOptions = [.toolbars]
        window.contentViewController = content
        window.contentMinSize = NSSize(width: 640, height: 460)
        window.setContentSize(NSSize(width: 980, height: 660))
        window.setFrameAutosaveName("sh.regents.cloak.window.chat")
        return window
    }

    var body: some View {
        NavigationSplitView {
            Sidebar(chat: chat)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            Detail(
                chat: chat, showDetails: showDetails, showAgents: showAgents, showNearSettings: showNearSettings,
                showLlamaSettings: showLlamaSettings, showLocalAccessSettings: showLocalAccessSettings,
                showAdvancedSettings: showAdvancedSettings, showServingSettings: showServingSettings)
        }
        .frame(minWidth: 640, minHeight: 460)
        .task { await chat.open() }
        .alert(
            "Switch provider to \(chat.pendingProviderSwitch?.to.shortTitle ?? "")?",
            isPresented: Binding(
                get: { chat.pendingProviderSwitch != nil },
                set: { if !$0 { chat.cancelProviderSwitch() } }),
            presenting: chat.pendingProviderSwitch
        ) { _ in
            Button("Start New Thread") {
                chat.confirmProviderSwitchNewThread()
            }
            Button("Send All Thread Context") {
                chat.confirmProviderSwitchSendContext()
            }
            Button("Cancel", role: .cancel) {
                chat.cancelProviderSwitch()
            }
        } message: { pending in
            let turns = pending.priorTurnCount == 1 ? "1 earlier message" : "\(pending.priorTurnCount) earlier messages"
            Text("This thread has \(turns) from \(pending.from.shortTitle). Sending here shares the full conversation context with \(pending.to.shortTitle), or you can start a new thread on \(pending.to.shortTitle) with only this message.")
        }
    }
}

private struct Sidebar: View {
    @Bindable var chat: Chat
    @State private var deleting: Conversation?
    @State private var hoveringNewChat = false

    var body: some View {
        let selected = chat.conversations.first { $0.id == chat.selection }
        let isNewChatActive = selected.map {
            $0.turns.isEmpty && $0.id != chat.rewording?.conversation && $0.id != chat.autoStarting?.conversation
        } ?? true
        let visibleConversations = chat.conversations.filter {
            !$0.turns.isEmpty || $0.id == chat.rewording?.conversation || $0.id == chat.autoStarting?.conversation
        }
        VStack(spacing: 0) {
            Button {
                chat.newConversation()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                    Text("New Chat")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                    Text("⌘N")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(hoveringNewChat ? 0.09 : 0.05)))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75))
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .textSelection(.disabled)
            .disabled(!chat.isOpen)
            .onHover { hoveringNewChat = $0 }
            .tip("Start a new chat (⌘N)")
            .accessibilityLabel("New Chat")
            .accessibilityAddTraits(isNewChatActive ? .isSelected : [])
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 6)

            List(selection: $chat.selection) {
                ForEach(visibleConversations) { conversation in
                    let isEmpty = conversation.turns.isEmpty
                    let agent = chat.isAgent(conversation)
                    let mode = chat.kind(of: conversation)
                    let unsaved = chat.unsaved.contains(conversation.id)
                    HStack(spacing: 6) {
                        if isEmpty {
                            Image(systemName: "plus")
                                .imageScale(.small)
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            Text(agent ? "New task" : "New chat")
                                .fontWeight(.medium)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        } else {
                            Text(conversation.title)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            if unsaved {
                                Image(systemName: "externaldrive.badge.xmark")
                                    .imageScale(.small)
                                    .foregroundStyle(.tertiary)
                                    .accessibilityLabel("Not saved")
                                    .tip("Not saved. What's new here is gone when Cloak quits.")
                            } else if agent {
                                Image(systemName: Chat.Kind.agentSymbol)
                                    .imageScale(.small)
                                    .foregroundStyle(.tertiary)
                                    .accessibilityLabel("\(Chat.Kind.agentName) · \(mode.name)")
                                    .tip("\(Chat.Kind.agentName) · \(mode.name)")
                            } else {
                                if conversation.isNear, chat.nearMode.traces.isExported(conversation.id) {
                                    Image(systemName: "arrow.up.doc")
                                        .imageScale(.small)
                                        .foregroundStyle(.green)
                                        .accessibilityLabel("Trace exported")
                                        .tip("Exported to Cloak's Traces folder")
                                }
                                Image(systemName: mode.symbol)
                                    .imageScale(.small)
                                    .foregroundStyle(.tertiary)
                                    .accessibilityLabel(mode.name)
                                    .tip("\(mode.name) chat")
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .sidebarHover(selected: chat.selection == conversation.id)
                    .tag(conversation.id)
                    .contextMenu {
                        if conversation.isNear, !chat.unsaved.contains(conversation.id),
                            conversation.turns.contains(where: { $0.answer != nil })
                        {
                            if chat.nearMode.traces.isExported(conversation.id) {
                                Button("Remove Exported Trace") { chat.nearMode.traces.remove(conversation.id) }
                            } else {
                                Button("Export Trace") { chat.nearMode.traces.export(conversation) }
                            }
                            Divider()
                        }
                        Button("Delete", role: .destructive) { chat.delete(conversation.id) }
                            .keyboardShortcut(.delete, modifiers: [.command, .shift])
                            .disabled(isEmpty)
                    }
                }
                // Choosing one shows why it can't open; context menu lets users remove broken files.
                ForEach(chat.unreadable, id: \.self) { id in
                    Label("Can't open", systemImage: "lock")
                        .foregroundStyle(.secondary)
                        .sidebarHover(selected: chat.selection == id)
                        .tag(id)
                        .contextMenu {
                            Button("Delete", role: .destructive) { chat.deleteUnreadable(id) }
                                .keyboardShortcut(.delete, modifiers: [.command, .shift])
                        }
                }
            }
            .onDeleteCommand {
                if let selected = chat.selected, !selected.turns.isEmpty {
                    deleting = selected
                }
            }
            Divider()
            ActiveGuaranteesView(chat: chat)
        }
        .confirmationDialog(
            "Delete chat?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { conversation in
            Button("Delete", role: .destructive) { chat.delete(conversation.id) }
        } message: { _ in
            Text("It's removed from this Mac and can't be brought back.")
        }
    }
}

/// Live list of active privacy, network, cover, and isolation guarantees
/// pinned to the bottom-left of Chat. Every row appears IF AND ONLY IF that
/// guarantee is currently active for the selected mode, toggles, and app state.
private struct ActiveGuaranteesView: View {
    let chat: Chat
    @State private var inspectedID: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    private struct Item: Identifiable, Equatable {
        let id: String
        let symbol: String
        let title: String
        let detail: String
    }

    var body: some View {
        TimelineView(.everyMinute) { context in
            let items = activeItems(at: context.date)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.green)
                        .accessibilityHidden(true)
                    Text("ACTIVE GUARANTEES")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(items) { item in
                        GuaranteeRow(
                            symbol: item.symbol,
                            title: item.title,
                            detail: item.detail,
                            highContrast: contrast == .increased,
                            isPresented: Binding(
                                get: { inspectedID == item.id },
                                set: { inspectedID = $0 ? item.id : nil }
                            )
                        )
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: items.map(\.id))
        }
    }

    private func activeItems(at now: Date) -> [Item] {
        let conversation = chat.selected
        let mode = conversation.map(chat.kind(of:)) ?? chat.kind
        let agent = conversation.map(chat.isAgent) ?? false
        let settings = chat.settings
        let running = chat.supervisor.phase == .running
        let usesTorMode = (mode == .token && (agent || settings.tokenTor)) || mode == .v || (mode == .near && settings.nearTor)

        var items: [Item] = []

        if mode == .llama {
            items.append(Item(
                id: "local-offline",
                symbol: "laptopcomputer",
                title: "100% on this Mac",
                detail: "Runs locally with zero network calls, zero account, and zero cost."
            ))
            let sources = settings.activeLocalContextSummary
            if !sources.isEmpty {
                items.append(Item(
                    id: "local-context",
                    symbol: "person.crop.rectangle.stack",
                    title: "Local context active",
                    detail: "Offline-only context enabled for Local Mode: \(sources.joined(separator: ", ")). Zero bytes leave this Mac."
                ))
            }
        }

        if (mode == .token || mode == .v), (agent || !settings.neverReword) {
            items.append(Item(
                id: "local-rewrite",
                symbol: "pencil.line",
                title: settings.review && !agent ? "Local rewrite (review)" : "Local prompt rewrite",
                detail: "Your prompt is rewritten on this Mac before leaving to strip writing style and identifying details."
            ))
        }

        if running && usesTorMode {
            items.append(Item(
                id: "tor-active",
                symbol: torSymbol,
                title: "Tor routing active",
                detail: "Network traffic leaves through an isolated 3-hop Tor circuit, hiding this Mac's IP address."
            ))
        }

        if running && settings.cover && usesTorMode {
            items.append(Item(
                id: "cover-active",
                symbol: "waveform.path.ecg",
                title: "Cover traffic active",
                detail: "Background cover requests are running over Tor to mask when real prompts are sent."
            ))
        }

        if mode == .v {
            items.append(Item(
                id: "zkapi",
                symbol: "ticket",
                title: "Unlinkable keys (zkAPI)",
                detail: "Each request is paid with a fresh one-time ZK key — payment is unlinkable to your ETH deposit or other threads. Prompt content, thread history, and timing can still correlate turns."
            ))
        }

        let venicePays = conversation?.venice?.pays ?? settings.venicePays
        if mode == .token, (agent || !chat.usesVenice(for: conversation) || venicePays == .wallet) {
            items.append(Item(
                id: "no-account-wallet",
                symbol: "creditcard",
                title: "No account (local wallet)",
                detail: "Paid per prompt from a dedicated local crypto wallet with no provider account or credit card."
            ))
        }

        if mode == .near, let proof = chat.nearMode.proof {
            let everyMessage = settings.proofFreshness == .everyMessage
            let age = now.timeIntervalSince(proof.passedAt)
            let isFresh = everyMessage ? age < 300 : age < Double(settings.proofFreshness.rawValue)
            if isFresh {
                items.append(Item(
                    id: "near-tee",
                    symbol: "checkmark.shield",
                    title: everyMessage ? "Hardware TEE (every message)" : "Hardware TEE verified",
                    detail: everyMessage
                        ? "Last enclave check passed; Cloak re-verifies Intel TDX and NVIDIA GPU attestation before every message."
                        : "Intel TDX and NVIDIA GPU enclave attestation passed and is fresh."
                ))
            }
        }

        if agent {
            items.append(Item(
                id: "local-agent-box",
                symbol: "hammer",
                title: "Sealed local agent box",
                detail: "Runs multi-step tasks inside an isolated Linux micro-VM on this Mac with network routed through Tor."
            ))
        }

        let isEphemeral = conversation.map { chat.unsaved.contains($0.id) } ?? !settings.savedChats
        if !isEphemeral {
            items.append(Item(
                id: "encrypted-disk",
                symbol: "lock.doc",
                title: "Encrypted on disk",
                detail: "Saved conversations are encrypted with a 256-bit key kept in this Mac's Keychain."
            ))
        } else {
            items.append(Item(
                id: "no-disk-save",
                symbol: "eye.slash",
                title: "Memory only (not saved)",
                detail: "This chat never touches disk and vanishes when Cloak quits."
            ))
        }

        if chat.voice.isListening || chat.voice.speakingTurn != nil {
            items.append(Item(
                id: "local-voice",
                symbol: "waveform",
                title: "On-device voice",
                detail: "Speech dictation and read-aloud run 100% offline on this Mac using Apple's local speech engine. Zero audio leaves this Mac."
            ))
        }

        items.append(Item(
            id: "zero-telemetry",
            symbol: "hand.raised.slash",
            title: "Zero telemetry",
            detail: "Cloak sends zero analytics, zero crash reports, and requires no Regents account."
        ))

        return items
    }
}

/// Interactive, touch- and mouse-friendly row inside `ActiveGuaranteesView`.
/// Clicking or tapping opens a calm 1-sentence popover so touchscreen MacBook Pro,
/// iPad Sidecar, and mouse users can inspect any guarantee instantly.
private struct GuaranteeRow: View {
    let symbol: String
    let title: String
    let detail: String
    let highContrast: Bool
    @Binding var isPresented: Bool
    @State private var hovering = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(.green)
                    .frame(width: 14, alignment: .center)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(highContrast ? Color.primary : Color.primary.opacity(0.88))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .background(
                hovering || isPresented ? Color.primary.opacity(0.06) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .tip(detail)
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 4) {
                Label(title, systemImage: symbol)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(width: 260, alignment: .leading)
        }
        .accessibilityLabel(title)
        .accessibilityHint(detail)
    }
}

private struct Detail: View {
    @Bindable var chat: Chat
    let showDetails: () -> Void
    let showAgents: () -> Void
    let showNearSettings: () -> Void
    let showLlamaSettings: () -> Void
    let showLocalAccessSettings: () -> Void
    let showAdvancedSettings: () -> Void
    let showServingSettings: (() -> Void)?
    @State private var deletingUnreadable: UUID?
    @State private var nearTab: NearGatewayTab = .chat

    /// The conversation in front's mode; Local while none is.
    private var kind: Chat.Kind {
        chat.selected.map(chat.kind(of:)) ?? .llama
    }

    /// The Settings pane matching the active chat mode.
    private var modeSettingsPane: SettingsView.Pane {
        switch kind {
        case .llama: .llama
        case .near: .near
        case .token, .v: .wallets
        }
    }

    var body: some View {
        content
            .toolbar {
                if #available(macOS 26.1, *) {
                    ToolbarItem(placement: .navigation) {
                        TitlebarModePill(
                            chat: chat, kind: kind, showLlamaSettings: showLlamaSettings,
                            showNearSettings: showNearSettings)
                    }
                    .visibilityPriority(.high)
                    if kind != .llama {
                        ToolbarItem {
                            WalletButton(chat: chat, v: kind == .v)
                        }
                        .visibilityPriority(.high)
                        ToolbarSpacer(.fixed)
                    }
                    ToolbarItem {
                        Button {
                            AppDelegate.current.showSettings(on: modeSettingsPane)
                        } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                        .tip("\(modeSettingsPane.title) Settings (⌘,)")
                    }
                    .visibilityPriority(.low)
                } else {
                    ToolbarItem(placement: .navigation) {
                        TitlebarModePill(
                            chat: chat, kind: kind, showLlamaSettings: showLlamaSettings,
                            showNearSettings: showNearSettings)
                    }
                    if kind != .llama {
                        ToolbarItem {
                            WalletButton(chat: chat, v: kind == .v)
                        }
                        ToolbarSpacer(.fixed)
                    }
                    ToolbarItem {
                        Button {
                            AppDelegate.current.showSettings(on: modeSettingsPane)
                        } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                        .tip("\(modeSettingsPane.title) Settings (⌘,)")
                    }
                }
            }
            .sheet(isPresented: $chat.showingWallet) {
                WalletView(
                    wallet: chat.wallet, veniceMode: chat.veniceMode, payer: chat.payer, settings: chat.settings,
                    nearMode: chat.nearMode, download: chat.rewordingDownload, kind: kind, tokens: chat.selected?.tokens,
                    showDetails: showDetails, showNearSettings: showNearSettings)
            }
            .sheet(isPresented: $chat.showingTour, onDismiss: { chat.tourStep = 0 }) {
                TourView(
                    chat: chat, initialStep: chat.tourStep, showNearSettings: showNearSettings, showLlamaSettings: showLlamaSettings,
                    showAdvancedSettings: showAdvancedSettings, showConnectedApps: showAgents,
                    showServingSettings: showServingSettings)
            }
            .task(id: chat.supervisor.phase == .running) {
                if chat.settings.payProvider == .boundless {
                    await chat.wallet.refresh()
                }
            }
    }

    @ViewBuilder private var content: some View {
        switch chat.access {
        case .unopened, .opening(again: false):
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .missingKey:
            ContentUnavailableView {
                Label("Locked", systemImage: "lock")
            } description: {
                Text("The key to your saved chats is missing from this Mac's keychain, so they can't be opened. They're kept as they are. If you restored the key, try again.")
            } actions: {
                Button("Try Again") { Task { await chat.open() } }
            }
        case .opening(again: true):
            ContentUnavailableView {
                Label("Can't open", systemImage: "lock")
            } description: {
                Text("Trying again…")
            } actions: {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Trying again")
            }
        case .failed(let again):
            ContentUnavailableView {
                Label("Can't open", systemImage: "lock")
            } description: {
                Text(
                    again
                        ? "Tried again, and your saved chats still couldn't be opened. The keychain may have said no."
                        : "Your saved chats couldn't be opened. The keychain may have said no.")
            } actions: {
                Button("Try Again") { Task { await chat.open() } }
            }
        case .open:
            if let conversation = chat.selected {
                VStack(spacing: 0) {
                    if kind == .near {
                        NearGatewayTabBar(selection: $nearTab, chat: chat, showNearSettings: showNearSettings)
                        Divider()
                    }
                    if kind == .near && nearTab == .traces {
                        NearGatewayTracesView(chat: chat, showNearSettings: showNearSettings) { targetID in
                            if let targetID {
                                chat.selection = targetID
                            }
                            nearTab = .chat
                        }
                    } else if kind == .near && nearTab == .insights {
                        NearGatewayInsightsView(
                            chat: chat,
                            showNearSettings: showNearSettings,
                            openChat: { targetID in
                                if let targetID {
                                    chat.selection = targetID
                                }
                                nearTab = .chat
                            },
                            openTraces: { nearTab = .traces }
                        )
                    } else {
                        Turns(chat: chat, conversation: conversation, showAgents: showAgents, showNearSettings: showNearSettings)
                        Divider()
                        Compose(
                            chat: chat, showDetails: showDetails, showNearSettings: showNearSettings,
                            showLlamaSettings: showLlamaSettings, showLocalAccessSettings: showLocalAccessSettings)
                    }
                }
                .background(Color(nsColor: .windowBackgroundColor))
                .onChange(of: kind) { _, newKind in
                    if newKind != .near {
                        nearTab = .chat
                    }
                }
                .onChange(of: chat.selection) { _, _ in
                    if nearTab != .chat {
                        nearTab = .chat
                    }
                }
            } else {
                ContentUnavailableView {
                    Label("Can't open", systemImage: "lock")
                } description: {
                    Text("This chat's file didn't open. It's kept as it is.")
                } actions: {
                    if let id = chat.selection, chat.unreadable.contains(id) {
                        Button("Delete…", role: .destructive) { deletingUnreadable = id }
                    }
                }
                .confirmationDialog(
                    "Delete unreadable chat?",
                    isPresented: Binding(get: { deletingUnreadable != nil }, set: { if !$0 { deletingUnreadable = nil } }),
                    presenting: deletingUnreadable
                ) { id in
                    Button("Delete", role: .destructive) { chat.deleteUnreadable(id) }
                } message: { _ in
                    Text("The unreadable file is removed from this Mac and can't be brought back.")
                }
            }
        }
    }
}

/// Funds button in Chat's toolbar (hidden in Local mode, Decision N2b).
/// In Paranoid (V) mode, uses a live `TimelineView` so the expiry warning badge
/// updates even if Cloak stays open overnight (Decision R6b).
private struct WalletButton: View {
    let chat: Chat
    let v: Bool

    var body: some View {
        TimelineView(.everyMinute) { context in
            let band = v ? chat.payer.band(at: context.date) : nil
            let warning: (Color, String)? =
                switch band {
                case .near?: (.orange, "Expires \(chat.payer.expiry?.formatted(.dateTime.day().month()) ?? ""). Withdraw before then.")
                case .due?: (.red, "Expired. Withdraw now.")
                case .far?, nil: nil
                }
            Button {
                chat.showingWallet = true
            } label: {
                Label {
                    Text("Funds")
                } icon: {
                    Image(systemName: "creditcard")
                        .overlay(alignment: .bottomTrailing) {
                            if let (tint, _) = warning {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(tint)
                                    .background(.background, in: .circle)
                                    .offset(x: 3, y: 3)
                            }
                        }
                }
                .labelStyle(.titleAndIcon)
            }
            .tip(warning.map { "Funds. \($0.1)" } ?? "Manage Funds")
            .accessibilityValue(warning?.1 ?? "")
            .disabled(!chat.isOpen)
        }
    }
}

/// The conversation's messages, in the order they were sent, each not yet
/// sent where it was added. One unsent message is open at a time, to be
/// edited, reworded again and sent; pressing another opens it instead.
/// Calm, understated empty-chat header replacing a duplicate "New chat" title
/// beside the sidebar's `+ New chat` action row.
private struct EmptyChatHeader: View {
    let mode: Chat.Kind
    let agent: Bool
    let provider: String?
    let model: String

    private var tagline: String {
        if agent {
            let target = provider.map { "\($0) · \(model)" } ?? model
            return "\(target) · sealed Linux VM over Tor"
        }
        return switch mode {
        case .llama: "\(model) · offline on this Mac · free"
        case .near: "NEAR · \(model) · hardware-verified enclave"
        case .token: "\(provider ?? "Token Inference") · \(model) · Tor + local rewrite"
        case .v: "\(model) · Tor + local rewrite · unlinkable zkAPI"
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: agent ? Chat.Kind.agentSymbol : mode.symbol)
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(agent ? "Local Agent Box" : mode.name)
                .font(.title3.weight(.semibold))
            Text(tagline)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 56)
        .padding(.bottom, 12)
        .accessibilityElement(children: .combine)
    }
}

private struct Turns: View {
    private struct ScrollBounds: Equatable {
        var contentHeight: CGFloat
        var containerHeight: CGFloat
        var atBottom: Bool
    }

    let chat: Chat
    let conversation: Conversation
    let showAgents: () -> Void
    let showNearSettings: () -> Void

    var body: some View {
        let rewording = chat.rewording?.conversation == conversation.id ? chat.rewording : nil
        let agent = chat.isAgent(conversation)
        let mode = chat.kind(of: conversation)
        let run = chat.agent.runs[conversation.id]
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // First-run Local onboarding card (Decision N6b) when the
                    // local model isn't installed yet; otherwise a calm, quiet empty state.
                    if conversation.turns.isEmpty, rewording == nil {
                        if mode == .llama, let block = chat.llamaBlock {
                            LocalOnboardingCard(chat: chat, block: block)
                        } else {
                            EmptyChatHeader(
                                mode: mode, agent: agent,
                                provider: chat.activeProviderName(for: mode, conversation: conversation),
                                model: chat.activeModelName(for: mode, conversation: conversation))
                            if let requirement = ModeSetupRequirement.evaluate(
                                chat: chat, mode: mode, agent: agent, conversation: conversation)
                            {
                                ModeSetupCard(
                                    requirement: requirement,
                                    openFunds: { chat.showingWallet = true },
                                    openNearSettings: showNearSettings)
                            }
                        }
                    }
                    ForEach(conversation.turns) { turn in
                        if agent {
                            let running = run?.turn.id == turn.id ? run : nil
                            TaskCard(
                                chat: chat, conversation: conversation.id, mode: mode, turn: running?.turn ?? turn, run: running,
                                newest: turn.id == conversation.turns.last?.id, showAgents: showAgents)
                        } else if mode == .llama {
                            LlamaCard(
                                chat: chat, conversation: conversation.id, turn: turn,
                                answering: chat.answering[conversation.id].flatMap { $0.turn == turn.id ? $0 : nil },
                                newest: turn.id == conversation.turns.last?.id)
                        } else {
                            TurnCard(
                                chat: chat, conversation: conversation.id, turn: turn, mode: mode,
                                open: chat.isOpen(turn, in: conversation),
                                rewording: rewording.flatMap { $0.turn == turn.id ? $0 : nil },
                                showNearSettings: showNearSettings)
                        }
                    }
                    if let rewording, rewording.turn == nil {
                        PendingCard(chat: chat, rewording: rewording)
                    }
                    Color.clear
                        .frame(height: 0)
                        .id("chat-bottom")
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Reads from the top; a long chat opens at its newest message.
            // While the end is in view it stays in view as messages are added
            // or the window changes size. Defer scrolling out of the geometry
            // callback so SwiftUI never flags multiple updates per frame.
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .onScrollGeometryChange(for: ScrollBounds.self) { geo in
                ScrollBounds(
                    contentHeight: geo.contentSize.height.rounded(),
                    containerHeight: geo.containerSize.height.rounded(),
                    atBottom: geo.visibleRect.maxY >= geo.contentSize.height - 4
                )
            } action: { old, new in
                let resized = new.contentHeight != old.contentHeight || new.containerHeight != old.containerHeight
                if resized, old.atBottom, new.contentHeight > new.containerHeight {
                    DispatchQueue.main.async {
                        proxy.scrollTo("chat-bottom", anchor: .bottom)
                    }
                }
            }
        }
        // A scroll view of its own for each chat, so one read part way up
        // leaves the next opening at its newest message too.
        .id(conversation.id)
    }
}

/// One message: Original and Reworded side by side, the words taken out
/// marked in one, the words put in marked in the other, then its answer; a
/// message going as written shows its Original alone. The open one has the
/// lights, Reword, which only rewords, and Send: nothing is sent unless
/// Cloak routes it through Tor and, unless its owner chose to send it as
/// written, it is reworded. In Token Inference a third light says the
/// provider can link the chats. While it has a reworded text, the drop-down
/// beside Send holds Send Original Text, which sends it as written instead,
/// and Never reword. Another unsent one is shrunk, marked so, and opens when
/// pressed anywhere, unless a rewording is under way in its chat. Why its
/// last send stopped, and why its own Reword stopped, stay on it until
/// dismissed or pressed again. A NEAR message is shown as written alone, and
/// the open one has Send, with no lights and no rewording; its answer, when
/// NEAR counted its tokens, has a mark that says how many.
private struct TurnCard: View {
    let chat: Chat
    let conversation: UUID
    let turn: Turn
    let mode: Chat.Kind
    let open: Bool
    let rewording: Chat.Rewording?
    let showNearSettings: () -> Void
    @State private var hovering = false

    var body: some View {
        let near = mode == .near
        let sending = chat.sending[turn.id]
        let sendStop = chat.sendStops[turn.id]
        let shrunk = !open && turn.answer == nil
        let notSent = rewording == nil && shrunk && sending == nil
        // A rewording in this chat keeps its own card open.
        let opens = shrunk && chat.rewording?.conversation != conversation
        // The accent edge says a press opens it.
        Card(highlighted: hovering && opens) {
            if let reworded = turn.reworded {
                let diff = WordDiff(original: turn.original, reworded: reworded)
                HStack(alignment: .top, spacing: 12) {
                    Pane(title: "Original", count: diff.removed.count, mark: .removed) {
                        TextBox(text: .constant(turn.original), label: "Original", editable: false, marks: diff.removed, mark: .removed)
                    }
                    Pane(title: "Rewritten", count: diff.added.count, mark: .added) {
                        TextBox(
                            text: open
                                ? Binding(get: { reworded }, set: { chat.edit(turn.id, in: conversation, to: $0) })
                                : .constant(reworded),
                            label: "Rewritten", editable: open && sending == nil && rewording == nil, marks: diff.added,
                            mark: .added)
                    }
                }
            } else {
                let title = near ? "Message" : "Original"
                Pane(title: title, count: nil, mark: .removed) {
                    TextBox(text: .constant(turn.original), label: title, editable: false)
                }
            }
            if let answer = turn.answer {
                Pane(title: "Answer", count: nil, mark: .added) {
                    AnswerText(text: answer)
                } accessory: {
                    HStack(spacing: 6) {
                        VoiceSpeakButton(voice: chat.voice, turnID: turn.id, text: answer)
                        if let tokens = turn.tokens {
                            TokenMark(tokens: tokens)
                        }
                    }
                }
            } else if let streaming = chat.veniceMode.partial[turn.id], !streaming.text.isEmpty {
                Pane(title: "Answer", count: nil, mark: .added) {
                    AnswerText(text: streaming.text)
                }
            }
            if let sendStop, !sendStop.dismissed {
                let dismiss: () -> Void = { chat.sendStops[turn.id]?.dismissed = true }
                Group {
                    switch sendStop.reason {
                    case .tempo(let stop):
                        StopRow(stop: stop, viaTor: chat.settings.tokenTor, showWallet: { chat.showingWallet = true }, dismiss: dismiss)
                    case .venice(let stop):
                        VeniceStopRow(stop: stop, showFunds: { chat.showingWallet = true }, dismiss: dismiss)
                    case .zkapi(let stop):
                        PayStopRow(stop: stop, showWallet: { chat.showingWallet = true }, dismiss: dismiss)
                    case .near(let stop):
                        NearStopRow(stop: stop, viaTor: chat.settings.nearTor, showSettings: showNearSettings, dismiss: dismiss)
                    }
                }
                .padding(12)
                .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            }
            if let stop = chat.stops[conversation], stop.turn == turn.id {
                Notice(symbol: "exclamationmark.circle.fill", tint: .orange, title: stop.title, detail: stop.detail) {
                    chat.stops[conversation] = nil
                }
            }
            if let rewording {
                Progress(chat: chat, started: rewording.started)
            } else if open {
                if !near {
                    Lights(
                        reworded: turn.reworded.map { !Chat.isBlank($0) } ?? false,
                        routed: mode == .token ? (chat.settings.tokenTor && chat.supervisor.phase == .running) : chat.supervisor.phase == .running,
                        linkable: mode == .token)
                }
                HStack(spacing: 12) {
                    if !near {
                        SymbolButton("Rewrite", symbol: "pencil.line") { chat.reword(turn, in: conversation) }
                            .disabled(!chat.canReword || sending != nil)
                    }
                    if let sending {
                        Busy(title: "Sending", started: sending.started)
                        if chat.veniceMode.partial[turn.id] != nil {
                            Button("Stop") { chat.veniceMode.stop(turn.id) }
                                .controlSize(.small)
                        }
                    } else if let autoStart = chat.autoStarting, autoStart.conversation == conversation {
                        Busy(title: "Starting Cloak", started: autoStart.started)
                    }
                    Spacer()
                    let isAutoStartingHere = chat.autoStarting?.conversation == conversation
                    let block = isAutoStartingHere ? nil : (near ? chat.nearMode.sendBlock : chat.sendBlock(turn, in: mode))
                    let originalBlock = (isAutoStartingHere || turn.reworded == nil) ? nil : chat.originalBlock(in: mode)
                    if let words = originalBlock ?? block {
                        Text(words)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    // The way on from a reason Funds or the key fixes.
                    if near, chat.nearMode.hasKey == false {
                        Button("Settings…", action: showNearSettings)
                    } else if !near, !isAutoStartingHere, chat.walletBlocks(in: mode) {
                        Button("Funds…") { chat.showingWallet = true }
                    }
                    // Each press of Send or Send Original Text sends, one
                    // under way or not.
                    HStack(spacing: 0) {
                        Button("Send", systemImage: "arrow.up") { chat.send(turn.id, in: conversation) }
                            .buttonStyle(RoundButtonStyle(diameter: 20))
                            .tip("Send")
                            .disabled(block != nil || isAutoStartingHere)
                        if turn.reworded != nil {
                            SendOptions(settings: chat.settings, blocked: originalBlock != nil || isAutoStartingHere) {
                                chat.sendOriginal(turn.id, in: conversation)
                            }
                        }
                    }
                }
            } else if let sending {
                Busy(title: "Sending", started: sending.started)
            } else if turn.answer == nil {
                // Only its room: the mark is drawn over the press that opens
                // the card, so its help shows.
                NotSent(mayHaveGone: false)
                    .hidden()
            }
        }
        .overlay(alignment: .bottomLeading) {
            // Over the whole card, text boxes included, so a press anywhere
            // opens it. Off while a rewording is under way in this chat,
            // which keeps its own card open.
            if shrunk {
                Button { chat.opened = turn.id } label: {
                    Color.clear
                        .contentShape(.rect(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open")
                .tip("Open")
                .disabled(!opens)
            }
            if notSent {
                NotSent(mayHaveGone: sendStop?.reason.mayHaveGone == true)
                    .padding(16)
            }
        }
        .onHover { hovering = $0 }
    }
}

/// A shrunk card's mark while it has no answer: a small hollow circle,
/// dashed, as the switches' hollow dot means off; with a question mark in
/// it when its last send stopped after the message may have gone out, as
/// that send's stop says.
private struct NotSent: View {
    let mayHaveGone: Bool

    var body: some View {
        let words = mayHaveGone ? "May have been sent" : "Not sent"
        Image(systemName: mayHaveGone ? "questionmark.circle.dashed" : "circle.dashed")
            .font(.callout)
            .foregroundStyle(.secondary)
            .tip(words)
            .accessibilityLabel(words)
    }
}

/// The drop-down beside a card's Send while it has a reworded text: Send
/// Original Text, off as Send is but for a blank reworded text, which it
/// does not send; and Never reword, the setting itself, which turns Review
/// off as it does in Settings (`AppSettings.neverReword`).
private struct SendOptions: View {
    let settings: AppSettings
    let blocked: Bool
    let sendOriginal: () -> Void

    var body: some View {
        Menu {
            Button("Send Original Text", action: sendOriginal)
                .disabled(blocked)
            NeverReword(settings: settings)
        } label: {
            Label("Send Options", systemImage: "chevron.down")
                .labelStyle(.iconOnly)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(.rect)
        }
        // Plain, so the whole 28 points answer the pointer, not only the
        // chevron.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .hover(Circle())
        .tip("Send Options")
    }
}

/// One task: as written and, once the door has reworded it, as reworded,
/// side by side, the words marked as in a message; the steps the agent took;
/// its answer. While it runs, its newest steps, how long it has run, and
/// Stop. One that ended without an answer says why and, as the newest, can
/// run again; in V, one stopped for want of a deposit says so, with
/// Wallet; one that couldn't reach Cloak has the way to Agents, which says
/// why and carries the fix. The newest without an answer has the lights.
private struct TaskCard: View {
    let chat: Chat
    let conversation: UUID
    let mode: Chat.Kind
    let turn: Turn
    let run: Agent.Run?
    let newest: Bool
    let showAgents: () -> Void
    @State private var showingSteps = false

    var body: some View {
        let steps = turn.steps ?? []
        Card {
            HStack(alignment: .top, spacing: 12) {
                if let reworded = turn.reworded {
                    let diff = WordDiff(original: turn.original, reworded: reworded)
                    Pane(title: "Original", count: diff.removed.count, mark: .removed) {
                        TextBox(text: .constant(turn.original), label: "Original", editable: false, marks: diff.removed, mark: .removed)
                    }
                    Pane(title: "Rewritten", count: diff.added.count, mark: .added) {
                        TextBox(text: .constant(reworded), label: "Rewritten", editable: false, marks: diff.added, mark: .added)
                    }
                } else {
                    Pane(title: "Original", count: nil, mark: .removed) {
                        TextBox(text: .constant(turn.original), label: "Original", editable: false)
                    }
                    if run != nil {
                        Pane(title: "Rewritten", count: nil, mark: .added) {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Rewriting")
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
            if !steps.isEmpty {
                if run != nil {
                    // The newest few, the newest last.
                    Pane(title: "Steps", count: nil, mark: .added) {
                        StepList(steps: steps.suffix(5))
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) { showingSteps.toggle() }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .rotationEffect(.degrees(showingSteps ? 90 : 0))
                                    .frame(width: 12)
                                    .accessibilityHidden(true)
                                Text("^[\(steps.count) step](inflect: true)")
                                    .font(.subheadline.weight(.semibold))
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .hover(RoundedRectangle(cornerRadius: 6), outset: 4)
                        .accessibilityValue(showingSteps ? "Expanded" : "Collapsed")
                        if showingSteps {
                            StepList(steps: steps[...])
                                .paneBox()
                        }
                    }
                }
            }
            if let answer = turn.answer, !Chat.isBlank(answer) {
                Pane(title: "Answer", count: nil, mark: .added) {
                    AnswerText(text: answer)
                } accessory: {
                    VoiceSpeakButton(voice: chat.voice, turnID: turn.id, text: answer)
                }
            }
            if run == nil, turn.answer == nil {
                if let end = chat.agent.ends[turn.id] {
                    EndRow(title: end.title, words: end.words)
                    if end == .unreachable {
                        HStack(spacing: 12) {
                            Text("Connected Apps says why.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Button("Connected Apps…", action: showAgents)
                        }
                    }
                    if mode == .v, case .failed = end, chat.payer.state == .none {
                        HStack(spacing: 12) {
                            Text("Deposit to run.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Button("Funds…") { chat.showingWallet = true }
                        }
                    }
                } else {
                    Text("Not finished")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            if newest, turn.answer == nil {
                // The door sends nothing of a task that it has not reworded.
                Lights(reworded: true, routed: chat.supervisor.phase == .running, linkable: mode == .token)
            }
            if let run {
                HStack(spacing: 8) {
                    Busy(title: "Working", started: run.started)
                    Spacer()
                    Button("Stop") { chat.agent.stop(conversation) }
                }
                .accessibilityElement(children: .contain)
            } else if newest, turn.answer == nil {
                HStack(spacing: 12) {
                    Spacer()
                    let block = chat.runBlock(in: mode)
                    if let block {
                        Text(block)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if chat.walletBlocks(in: mode) {
                        Button("Funds…") { chat.showingWallet = true }
                    }
                    SymbolButton("Run Again", symbol: "arrow.clockwise") { chat.runAgain(turn, in: conversation) }
                        .disabled(block != nil)
                }
            }
        }
    }
}

/// One Local Llama message: as written, then the answer of the model on
/// this Mac. While the model answers, how long it has worked, and Stop. One
/// without an answer says why and, as the newest, can be asked again,
/// unless the chat has grown too long for the model.
private struct LlamaCard: View {
    let chat: Chat
    let conversation: UUID
    let turn: Turn
    let answering: Chat.Answering?
    let newest: Bool

    var body: some View {
        Card {
            Pane(title: "Message", count: nil, mark: .removed) {
                VStack(alignment: .leading, spacing: 8) {
                    if let attachments = turn.attachments, !attachments.isEmpty {
                        let hasText = chat.hasLocalAttachments(for: turn.id)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(attachments) { item in
                                    HStack(spacing: 5) {
                                        Image(systemName: Self.attachmentSymbol(for: item.kind))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text(item.name)
                                            .font(.caption.weight(.medium))
                                            .lineLimit(1)
                                        if item.kind == LocalAttachment.Kind.image.rawValue {
                                            Text("· OCR")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                        if item.truncated {
                                            Text("· excerpt")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                        if !hasText {
                                            Text("· Reattach to use")
                                                .font(.caption2.weight(.medium))
                                                .foregroundStyle(.orange)
                                        }
                                    }
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 4)
                                    .background(.quaternary.opacity(0.65), in: Capsule())
                                    .help(
                                        hasText
                                            ? item.name
                                            : "Extracted file text is cleared when Cloak quits for privacy. Reattach this file if you want follow-up turns to reference it.")
                                }
                            }
                        }
                    }
                    TextBox(text: .constant(turn.original), label: "Message", editable: false)
                }
            }
            if let answer = turn.answer {
                Pane(title: "Answer", count: nil, mark: .added) {
                    AnswerText(text: answer)
                } accessory: {
                    VoiceSpeakButton(voice: chat.voice, turnID: turn.id, text: answer)
                }
            } else if let answering {
                if !answering.partial.isEmpty {
                    Pane(title: "Answer", count: nil, mark: .added) {
                        AnswerText(text: answering.partial)
                    }
                }
                HStack(spacing: 8) {
                    LocalBusy(answering: answering)
                    Spacer()
                    Button("Stop") { chat.stopAnswer(in: conversation) }
                }
                .accessibilityElement(children: .contain)
            } else {
                let stop = chat.answerStops[turn.id]
                EndRow(title: stop?.title ?? "Not answered", words: stop?.words)
                if newest, stop != .tooLong {
                    HStack(spacing: 12) {
                        Spacer()
                        if let block = chat.llamaBlock {
                            Text(block.words)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        SymbolButton("Ask Again", symbol: "arrow.clockwise") { chat.ask(turn.id, in: conversation) }
                            .disabled(chat.llamaBlock != nil)
                    }
                }
            }
        }
    }

    private static func attachmentSymbol(for kind: String) -> String {
        switch kind {
        case LocalAttachment.Kind.image.rawValue: "photo"
        case LocalAttachment.Kind.pdf.rawValue, LocalAttachment.Kind.document.rawValue: "doc.richtext"
        default: "doc.text"
        }
    }
}

/// A task's steps, one a line: the tool, then the command or the file.
private struct StepList: View {
    let steps: ArraySlice<Step>

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(steps.indices, id: \.self) { index in
                let step = steps[index]
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(step.label)
                        .fontWeight(.medium)
                    if let detail = step.detail {
                        Text(detail)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 2)
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Steps")
    }
}

/// Why a task, or a Local Llama message, ended without an answer.
private struct EndRow: View {
    let title: String
    let words: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .fontWeight(.medium)
                if let words {
                    Text(words)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .padding(12)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Whether the message is reworded and routed through Tor: a symbol each,
/// green when it is, orange when not, with the state in words as its help
/// and for VoiceOver. Routed has Tor's symbol, as the Tor switch does. In
/// Token Inference a third, always orange, says one wallet pays for every
/// chat.
private struct Lights: View {
    let reworded: Bool
    let routed: Bool
    let linkable: Bool

    var body: some View {
        HStack(spacing: 4) {
            Light(symbol: "textformat", good: reworded, words: reworded ? "Rewritten" : "Not rewritten")
            Light(symbol: torSymbol, good: routed, words: routed ? "Routed through Tor" : "Not routed: Cloak isn't running")
            if linkable {
                Light(symbol: "link", good: false, words: "The provider can link your chats, because one wallet pays for all of them.")
            }
        }
    }
}

private struct Light: View {
    let symbol: String
    let good: Bool
    let words: String

    var body: some View {
        Image(systemName: symbol)
            .foregroundStyle(good ? .green : .orange)
            .frame(width: 24, height: 24)
            .contentShape(.rect)
            .tip(words)
            .accessibilityLabel(words)
    }
}

/// A spinner and how long it has been since `started`, what is under way
/// named in its help and for VoiceOver: Sending or Working.
private struct Busy: View {
    let title: String
    let started: Date

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(title)
            Text(timerInterval: started...Date.distantFuture, countsDown: false)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .tip(title)
    }
}

/// Live local-model progress row: clearly shows cold model startup
/// ("Starting local model…") while loading weights into Apple Silicon memory,
/// then cycles through varied answering phrases (like Claude Code) while the
/// model reasons, and switches to "Writing reply…" once tokens begin streaming.
private struct LocalBusy: View {
    let answering: Chat.Answering
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phrases: [String] = Self.answeringPhrases
    @State private var phraseIndex = 0

    private static let answeringPhrases: [String] = [
        "Answering query…",
        "Thinking it through…",
        "Pondering…",
        "Connecting the dots…",
        "Reasoning locally…",
        "Working through the details…",
        "Mulling it over…",
        "Synthesizing on-device…",
        "Weighing the angles…",
        "Distilling the answer…",
        "Piecing it together…",
        "Composing a reply…",
        "Untangling the thread…",
        "Crunching on Apple Silicon…",
        "Drafting privately…",
        "Shaping the response…",
        "Refining the thought…",
    ]

    private var statusText: String {
        if !answering.partial.isEmpty {
            return "Writing reply…"
        }
        switch answering.stage {
        case .startingModel:
            return "Starting local model…"
        case .answering:
            return phrases.isEmpty ? "Answering query…" : phrases[phraseIndex % phrases.count]
        }
    }

    private var taskKey: String {
        "\(answering.turn.uuidString)-\(answering.stage)-\(answering.partial.isEmpty)"
    }

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)
            Text(statusText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .id(statusText)
                .transition(reduceMotion ? .identity : .opacity)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: statusText)
            Text(timerInterval: answering.started...Date.distantFuture, countsDown: false)
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .combine)
        .task(id: taskKey) {
            guard answering.stage == .answering, answering.partial.isEmpty else { return }
            var pool = Self.answeringPhrases.shuffled()
            if answering.didColdStart, let idx = pool.firstIndex(of: "Answering query…") {
                pool.swapAt(0, idx)
            }
            phrases = pool
            phraseIndex = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2.8))
                guard !Task.isCancelled else { return }
                phraseIndex = (phraseIndex + 1) % max(phrases.count, 1)
            }
        }
    }
}

/// A new message while it is being reworded.
private struct PendingCard: View {
    let chat: Chat
    let rewording: Chat.Rewording

    var body: some View {
        Card {
            Pane(title: "Original", count: nil, mark: .removed) {
                TextBox(text: .constant(rewording.original), label: "Original", editable: false)
            }
            Progress(chat: chat, started: rewording.started)
        }
    }
}

private struct Progress: View {
    let chat: Chat
    let started: Date

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Rewriting")
            Text(timerInterval: started...Date.distantFuture, countsDown: false)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Spacer()
            Button("Cancel", action: chat.cancel)
                .keyboardShortcut(.cancelAction)
        }
        .accessibilityElement(children: .contain)
    }
}

struct Card<Content: View>: View {
    /// An accent edge over the separator's, fading in and out as a hover
    /// does (`Hover.swift`).
    var highlighted = false
    @ViewBuilder let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .padding(16)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.separator)
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.accentColor)
                .opacity(highlighted ? 1 : 0)
                .animation(reduceMotion ? nil : .hover, value: highlighted)
        }
    }
}

/// A titled text, with how many words are marked and how they look, and
/// at the end of its title's line any mark of its own.
struct Pane<Content: View, Accessory: View>: View {
    let title: String
    let count: Int?
    let mark: TextBox.Mark
    @ViewBuilder let content: Content
    @ViewBuilder let accessory: Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let count {
                    Text(mark == .removed ? "\(count) removed" : "\(count) added")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color(nsColor: mark.tint).opacity(0.15), in: Capsule())
                }
                accessory
            }
            content
                .paneBox()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension Pane where Accessory == EmptyView {
    init(title: String, count: Int?, mark: TextBox.Mark, @ViewBuilder content: () -> Content) {
        self.init(title: title, count: count, mark: mark, content: content, accessory: { EmptyView() })
    }
}

/// What NEAR counted for an answer: a small mark at the end of its title's
/// line, the counts in its help and for VoiceOver, as "1,204 tokens in, 356
/// out", the numbers as this Mac writes them.
private struct TokenMark: View {
    let tokens: Tokens

    var body: some View {
        let words = String(AttributedString(localized: "^[\(tokens.input) token](inflect: true) in, \(tokens.output) out").characters)
        Image(systemName: "number.circle")
            .imageScale(.small)
            .foregroundStyle(.secondary)
            .tip(words)
            .accessibilityLabel("Tokens")
            .accessibilityValue(words)
    }
}

extension View {
    /// The box a pane's text sits in.
    fileprivate func paneBox() -> some View {
        padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator.opacity(0.6)))
    }
}

/// The box for the next message, with a warning under it while Never
/// reword is ticked, what stopped this chat's last new message's rewording,
/// unless Cloak is running, the state and its way on, and, while another
/// chat's rewording runs in a chat that would reword, that, with Cancel.
/// Its button rewords, its symbol
/// Reword's, or sends when nothing is left to review: with Never reword
/// ticked or Review off. In the agent's conversation, the box for the next
/// task, with Run, or Stop while a task runs there, and a note when the
/// agent starts without the earlier tasks. While the conversation is empty,
/// what it is to be: V, Token Inference, NEAR Private AI or Local Llama,
/// and in V and Token Inference the Agent switch, which makes it the
/// agent's; beside them Modes, which shows the Modes page. Above either
/// box, its details; at the foot, the Tor and zkAPI switches. In a NEAR
/// Private AI conversation,
/// the box's button sends each message as written, with no details, and at
/// the foot NEAR's Tor switch and what its hardware check last found. In a
/// Local Llama conversation, it asks the model on this Mac, with Stop while
/// the model answers, no details and no switches, and Cloak need not be
/// running; when asking is certain to stop, why, and the way on.
private struct Compose: View {
    private struct FocusKey: Hashable {
        var selection: UUID?
        var tick: Int
    }

    @Bindable var chat: Chat
    let showDetails: () -> Void
    let showNearSettings: () -> Void
    let showLlamaSettings: () -> Void
    let showLocalAccessSettings: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var agentToast: Bool?
    @State private var agentToastTask: Task<Void, Never>?
    @State private var focusTick = 0
    @State private var isDroppingLocalFiles = false

    var body: some View {
        let conversation = chat.selected
        let mode = conversation.map(chat.kind(of:)) ?? chat.kind
        let agent = conversation.map(chat.isAgent) ?? false
        let near = conversation.map(chat.isNear) ?? false
        let llama = conversation.map(chat.isLlama) ?? false
        let running = conversation.flatMap { chat.agent.runs[$0.id] } != nil
        let answering = conversation.flatMap { chat.answering[$0.id] } != nil
        let neverReword = !agent && !near && !llama && chat.settings.neverReword
        let sends = neverReword || near || (!agent && !chat.settings.review)
        let label = agent ? "Task" : "Message"
        VStack(alignment: .leading, spacing: 10) {
            // A turn's own Reword that stopped says so on its card.
            if let conversation, let stop = chat.stops[conversation.id], stop.turn == nil {
                Notice(symbol: "exclamationmark.circle.fill", tint: .orange, title: stop.title, detail: stop.detail) {
                    chat.stops[conversation.id] = nil
                }
            }
            if let problem = chat.problem {
                Notice(symbol: "externaldrive.badge.exclamationmark", tint: .red, title: problem.title, detail: problem.detail) {
                    chat.problem = nil
                }
            }
            // Inline auto-start banner when Send/Run triggered Cloak startup (Decision R3b).
            if let autoStart = chat.autoStarting {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Starting Cloak…")
                            .fontWeight(.medium)
                        Text(timerInterval: autoStart.started...Date.distantFuture, countsDown: false)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Stop") { chat.stopAutoStart() }
                            .controlSize(.small)
                    }
                    StartupProgressView(supervisor: chat.supervisor)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            } else if llama {
                // Local needs only the model; hide duplicate banner when the
                // inline onboarding card is already showing on an empty chat.
                if let block = chat.llamaBlock, conversation?.turns.isEmpty != true {
                    LlamaStop(block: block, showDetails: showDetails, showLlamaSettings: showLlamaSettings)
                }
            } else if near {
                if chat.nearMode.route == nil, !chat.canAutoStart {
                    Waiting(
                        supervisor: chat.supervisor, download: chat.rewordingDownload, to: "send through Tor",
                        autoStarts: false, showDetails: showDetails)
                }
            } else if mode == .token, !agent, !chat.settings.tokenTor {
                // Direct Token Inference (Tor OFF) uses the pinned host helper — no VM/Tor startup needed.
            } else if chat.supervisor.phase != .running,
                !(chat.canAutoStart && (chat.supervisor.phase == .paused || chat.supervisor.phase == .ready))
            {
                Waiting(
                    supervisor: chat.supervisor, download: chat.rewordingDownload,
                    to: agent ? "run" : sends ? "send" : "rewrite", autoStarts: chat.canAutoStart, showDetails: showDetails)
            }
            if chat.rewordsElsewhere {
                RewordingElsewhere(cancel: chat.cancel)
            }
            if !near, !llama {
                DetailsRow(chat: chat)
            }
            if let enabled = agentToast {
                HStack(spacing: 6) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(enabled ? Color.green : Color.secondary)
                    Image(systemName: Chat.Kind.agentSymbol)
                        .imageScale(.small)
                    Text(enabled ? "Local agent box enabled" : "Local agent box disabled")
                        .font(.callout.weight(.medium))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .glassEffect(.regular, in: .capsule)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if llama, (!chat.localAttachments.isEmpty || chat.attachingLocalFiles || chat.localAttachmentError != nil) {
                VStack(alignment: .leading, spacing: 6) {
                    if !chat.localAttachments.isEmpty || chat.attachingLocalFiles {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(chat.localAttachments) { item in
                                    HStack(spacing: 5) {
                                        Image(systemName: Self.localAttachmentSymbol(for: item.kind))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text(item.name)
                                            .font(.caption.weight(.medium))
                                            .lineLimit(1)
                                        if item.kind == .image {
                                            Text("· OCR")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                        if item.truncated {
                                            Text("· excerpt")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                        Button {
                                            chat.removeLocalAttachment(item.id)
                                        } label: {
                                            Image(systemName: "xmark")
                                                .font(.system(size: 9, weight: .semibold))
                                                .foregroundStyle(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                        .tip("Remove \(item.name)")
                                    }
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 4)
                                    .background(.quaternary.opacity(0.65), in: Capsule())
                                }
                                if chat.attachingLocalFiles {
                                    HStack(spacing: 5) {
                                        ProgressView()
                                            .controlSize(.mini)
                                        Text("Reading file…")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 4)
                                    .background(.quaternary.opacity(0.5), in: Capsule())
                                }
                            }
                        }
                    }
                    if let error = chat.localAttachmentError {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.circle")
                                .foregroundStyle(.orange)
                            Text(error)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            Button {
                                chat.localAttachmentError = nil
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.caption2)
                            }
                            .buttonStyle(.plain)
                        }
                        .font(.caption)
                    }
                }
            }
            if chat.voice.isListening {
                HStack(spacing: 8) {
                    VoiceLevelBars(level: chat.voice.level)
                    Text(chat.voice.statusTitle)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Stop") { chat.voice.stopDictation() }
                        .controlSize(.mini)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.red.opacity(0.08), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.red.opacity(0.22), lineWidth: 0.75))
            } else if let voiceError = chat.voice.errorInfo {
                HStack(spacing: 6) {
                    Image(systemName: "mic.slash")
                        .foregroundStyle(.orange)
                    Text(voiceError.message)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if let pane = voiceError.settingsPane {
                        Button(pane.buttonTitle) {
                            chat.voice.openSettings(pane)
                        }
                        .controlSize(.mini)
                    }
                    Button {
                        chat.voice.dismissError()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                }
                .font(.caption)
            }
            // Clean prompt input bubble with integrated Local Voice + Send/Stop button.
            HStack(alignment: .bottom, spacing: 8) {
                TextBox(
                    text: $chat.draft, label: label, maxHeight: 160, autofocus: true,
                    focusTrigger: FocusKey(selection: chat.selection, tick: focusTick),
                    submit: chat.submit,
                    onDropFiles: llama ? { chat.attachLocalFiles($0) } : nil)
                    .overlay(alignment: .topLeading) {
                        if chat.draft.isEmpty {
                            Text(label)
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 7)
                                .padding(.top, 6)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                VoiceMicButton(voice: chat.voice) {
                    chat.voice.toggleDictation(currentDraft: { chat.draft }) { updated in
                        chat.draft = updated
                    }
                }
                .padding(.bottom, 2)
                if running || answering, let conversation {
                    Button("Stop", systemImage: "stop.fill") {
                        if llama { chat.stopAnswer(in: conversation.id) } else { chat.agent.stop(conversation.id) }
                    }
                    .buttonStyle(RoundButtonStyle())
                    .tip("Stop")
                    .keyboardShortcut(".", modifiers: .command)
                    .padding(.bottom, 2)
                } else {
                    let title = agent ? "Run" : llama ? "Ask" : sends ? "Send" : "Rewrite"
                    Button(title, systemImage: !agent && !llama && !sends ? "pencil.line" : "arrow.up") { chat.submit() }
                        .buttonStyle(RoundButtonStyle())
                        .tip(title)
                        .disabled(!chat.canSubmit)
                        .padding(.bottom, 2)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(
                        chat.voice.isListening
                            ? Color.red.opacity(0.6)
                            : (llama && isDroppingLocalFiles ? Color.accentColor : Color(nsColor: .separatorColor)),
                        lineWidth: (chat.voice.isListening || (llama && isDroppingLocalFiles)) ? 1.5 : 1)
            )
            .overlay(alignment: .center) {
                if llama && isDroppingLocalFiles {
                    Label("Drop files to attach locally", systemImage: "paperclip")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.regularMaterial, in: Capsule())
                        .allowsHitTesting(false)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 14))
            .onTapGesture { focusTick += 1 }
            .onDrop(of: [.fileURL], isTargeted: $isDroppingLocalFiles) { providers in
                guard llama else { return false }
                return handleLocalFileDrop(providers)
            }

            // Mode selector & controls cleanly below the prompt input bubble.
            let showModeControls = conversation.map {
                $0.turns.isEmpty && chat.rewording?.conversation != $0.id && chat.autoStarting?.conversation != $0.id
            } ?? false
            let showTokenProvider = mode == .token && !agent
            let showCoverToggle = mode == .v || (mode == .token && (agent || chat.settings.tokenTor))
            let setupRequirement = ModeSetupRequirement.evaluate(
                chat: chat, mode: mode, agent: agent, conversation: conversation)
            let showBottomRow = showModeControls || showTokenProvider || showCoverToggle || setupRequirement != nil || llama || near || neverReword
                || (agent && chat.supervisor.phase == .running && (conversation.map(chat.startsFresh) == true || chat.runBlock(in: mode) != nil))
            if showBottomRow {
                HStack(spacing: 8) {
                    if showModeControls {
                        ModeSwitch(kind: $chat.kind)
                            .fixedSize()
                        if chat.kind.hasAgent {
                            AgentPill(
                                isOn: Binding(
                                    get: { chat.agentOn },
                                    set: { newValue in
                                        chat.agentOn = newValue
                                        showAgentToast(enabled: newValue)
                                    }),
                                showTour: { chat.openTour(step: 1) })
                        }
                    }
                    if llama {
                        LocalComposeControls(
                            activeCount: chat.settings.activeLocalContextSummary.count,
                            onAttachFiles: pickLocalFiles,
                            onOpenLocalAccess: showLocalAccessSettings)
                    }
                    if showTokenProvider {
                        TokenProviderToggle(
                            provider: Binding(
                                get: { chat.settings.payProvider },
                                set: { chat.selectPayProvider($0) }))
                        CompactPrivacyToggleButton(
                            symbol: torSymbol,
                            label: "Tor",
                            isOn: chat.settings.tokenTor,
                            isActive: chat.settings.tokenTor && chat.supervisor.phase == .running,
                            isBusy: chat.settings.tokenTor && chat.supervisor.phase.state == .preparing,
                            tip: chat.settings.tokenTor
                                ? (chat.supervisor.phase == .running
                                    ? "Tor is ON for Token Inference — hides your IP from Boundless/Venice (slower). Click to switch to direct (faster)."
                                    : "Tor is ON for Token Inference (starts Cloak on Send). Click to switch to direct HTTPS (faster, no VM/Tor).")
                                : "Tor is OFF for Token Inference — faster direct HTTPS (provider sees your IP). Click to route through Tor."
                        ) {
                            let next = !chat.settings.tokenTor
                            chat.settings.tokenTor = next
                            if next, chat.supervisor.phase != .running, chat.supervisor.phase.state != .preparing,
                                chat.rewordingDownload.state == .installed
                            {
                                chat.supervisor.send(.start)
                            }
                        }
                    }
                    if showCoverToggle {
                        CompactPrivacyToggleButton(
                            symbol: "waveform.path",
                            label: "Cover Traffic",
                            isOn: chat.settings.cover,
                            isActive: chat.settings.cover && chat.supervisor.phase == .running,
                            isBusy: false,
                            tip: chat.settings.cover
                                ? (chat.supervisor.phase == .running
                                    ? "Cover Traffic is ON — sending random public Tor fetches (~3/min) to blur prompt timing. Click to turn off."
                                    : "Cover Traffic is ON (starts when Cloak runs). Click to turn off.")
                                : "Cover Traffic is OFF — click to send random public Tor fetches (~3/min) to blur prompt timing."
                        ) {
                            chat.settings.cover.toggle()
                        }
                    }
                    if near {
                        NearSwitches(
                            settings: chat.settings, nearMode: chat.nearMode,
                            supervisor: chat.supervisor, download: chat.rewordingDownload)
                    }
                    if neverReword {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .tip("Prompt rewriting is off — messages send as written.")
                            .accessibilityLabel("Prompt rewriting is off — messages send as written.")
                    } else if agent, let conversation, chat.supervisor.phase == .running, chat.startsFresh(conversation) {
                        Label("Starts fresh", systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .tip("The agent won't remember the earlier tasks here.")
                    }
                    Spacer(minLength: 0)
                    if let setupRequirement {
                        ModeSetupPill(
                            requirement: setupRequirement,
                            openFunds: { chat.showingWallet = true },
                            openNearSettings: showNearSettings)
                    } else if agent, chat.supervisor.phase == .running, let block = chat.runBlock(in: mode) {
                        Text(block)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Funds…") { chat.showingWallet = true }
                            .controlSize(.small)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: chat.picks.details)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: agentToast)
        .onDisappear {
            agentToastTask?.cancel()
            chat.voice.stopAll()
        }
    }

    private func showAgentToast(enabled: Bool) {
        agentToastTask?.cancel()
        agentToast = enabled
        agentToastTask = Task {
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            agentToast = nil
        }
    }

    private static func localAttachmentSymbol(for kind: LocalAttachment.Kind) -> String {
        switch kind {
        case .image: "photo"
        case .pdf, .document: "doc.richtext"
        case .file: "doc.text"
        }
    }

    private func pickLocalFiles() {
        let panel = NSOpenPanel()
        panel.title = "Attach Local Files"
        panel.message = "Selected PDF, document, image (OCR), Markdown, text, or code files stay strictly on this Mac in Local Mode."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        let handleResponse: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, !panel.urls.isEmpty else { return }
            chat.attachLocalFiles(panel.urls)
        }
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: handleResponse)
        } else {
            panel.begin(completionHandler: handleResponse)
        }
    }

    private func handleLocalFileDrop(_ providers: [NSItemProvider]) -> Bool {
        let matching = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !matching.isEmpty else { return false }
        Task {
            var urls: [URL] = []
            for provider in matching {
                if let url = await Self.loadFileURL(from: provider) {
                    urls.append(url)
                }
            }
            if !urls.isEmpty {
                chat.attachLocalFiles(urls)
            }
        }
        return true
    }

    private static func loadFileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url)
                } else if let url = item as? URL {
                    continuation.resume(returning: url)
                } else if let nsurl = item as? NSURL, let url = nsurl as URL? {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

/// Compact offline-only controls in the Local Mode composer bar: attach local
/// files (PDF, documents, images via OCR, Markdown, text, code) or configure Local Access.
private struct LocalComposeControls: View {
    let activeCount: Int
    let onAttachFiles: () -> Void
    let onOpenLocalAccess: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onAttachFiles) {
                HStack(spacing: 4) {
                    Image(systemName: "paperclip")
                        .font(.caption.weight(.medium))
                    Text("Attach")
                        .font(.caption.weight(.medium))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .frame(minHeight: 26)
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .hover(Capsule())
            .glassEffect(.regular.interactive(), in: .capsule)
            .tip("Attach local PDF, document, image (OCR), Markdown, text, or code files — or drag & drop them into the message box.")

            Button(action: onOpenLocalAccess) {
                HStack(spacing: 5) {
                    if activeCount > 0 {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 6, weight: .bold))
                            .foregroundStyle(.green)
                    }
                    Image(systemName: "person.crop.rectangle.stack")
                        .font(.caption.weight(.medium))
                    Text(activeCount > 0 ? "Local Access (\(activeCount))" : "Local Access")
                        .font(.caption.weight(.medium))
                }
                .foregroundStyle(activeCount > 0 ? .primary : .secondary)
                .padding(.horizontal, 9)
                .frame(minHeight: 26)
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .hover(Capsule())
            .glassEffect(.regular.interactive(), in: .capsule)
            .tip("Configure offline-only Mac info, Hermes memory, approved folders, and macOS Calendar, Reminders & Contacts.")
        }
    }
}

/// Onboarding requirement for any remote mode whose wallet, deposit, or API key
/// is not ready yet. Surfaced both as an inviting card below `EmptyChatHeader`
/// and as a compact clickable pill in the composer bar (including mid-chat).
private struct ModeSetupRequirement: Equatable {
    enum Destination: Equatable {
        case funds
        case nearSettings
    }

    let badge: String
    let symbol: String
    let headline: String
    let detail: String
    let buttonTitle: String
    let destination: Destination

    @MainActor
    static func evaluate(
        chat: Chat, mode: Chat.Kind, agent: Bool, conversation: Conversation?
    ) -> ModeSetupRequirement? {
        switch mode {
        case .llama:
            return nil

        case .near:
            guard chat.nearMode.hasKey == false else { return nil }
            return ModeSetupRequirement(
                badge: "Requires API Key",
                symbol: "key.fill",
                headline: "Add your NEAR AI Cloud API key",
                detail: "Enter your key from cloud.near.ai to chat with hardware-verified Qwen3.8-27B enclaves (no crypto required).",
                buttonTitle: "Set Up Key…",
                destination: .nearSettings)

        case .token:
            // Built-in Pi Agent in Token Inference uses Boundless / Tempo USDC.e.
            if !agent && chat.usesVenice(for: conversation) {
                switch chat.settings.venicePays {
                case .wallet:
                    if chat.veniceMode.presence == .absent {
                        return ModeSetupRequirement(
                            badge: "Requires Funding",
                            symbol: "creditcard.fill",
                            headline: "Set up your Venice Base USDC wallet",
                            detail: "Create a local Base USDC wallet and top up $5–$10 via x402, or switch to a Venice API Key.",
                            buttonTitle: "Set Up Venice…",
                            destination: .funds)
                    }
                    if let credit = chat.veniceMode.credit, !credit.canSpend {
                        return ModeSetupRequirement(
                            badge: "Requires Funding",
                            symbol: "creditcard.fill",
                            headline: "Add Venice credit to send",
                            detail: "Top up $5–$10 from your Base USDC wallet via x402 to start chatting over Tor.",
                            buttonTitle: "Add Funds…",
                            destination: .funds)
                    }
                    return nil
                case .key:
                    if chat.veniceMode.hasKey == false {
                        return ModeSetupRequirement(
                            badge: "Requires API Key",
                            symbol: "key.fill",
                            headline: "Add your Venice Inference API key",
                            detail: "Save your key from venice.ai, or switch to a local Base USDC wallet in Funds.",
                            buttonTitle: "Set Up Key…",
                            destination: .funds)
                    }
                    if let account = chat.veniceMode.keyAccount, !account.canSpend {
                        return ModeSetupRequirement(
                            badge: "Requires Funding",
                            symbol: "creditcard.fill",
                            headline: "Your Venice API key has no spendable balance",
                            detail: "Add credit on venice.ai or switch to a local Base USDC wallet in Funds.",
                            buttonTitle: "Manage Funds…",
                            destination: .funds)
                    }
                    return nil
                }
            } else {
                if chat.wallet.presence == .absent {
                    return ModeSetupRequirement(
                        badge: "Requires Funding",
                        symbol: "creditcard.fill",
                        headline: "Set up your Boundless Tempo wallet",
                        detail: "Create a local Tempo wallet and add USDC.e to pay per request through Boundless over Tor.",
                        buttonTitle: "Set Up Wallet…",
                        destination: .funds)
                }
                if chat.wallet.lacksFunds {
                    return ModeSetupRequirement(
                        badge: "Requires Funding",
                        symbol: "creditcard.fill",
                        headline: "Add USDC.e on Tempo to send",
                        detail: "Send USDC.e on Tempo to your Boundless wallet address in Funds to start chatting.",
                        buttonTitle: "Add Funds…",
                        destination: .funds)
                }
                return nil
            }

        case .v:
            switch chat.payer.state {
            case .none:
                return ModeSetupRequirement(
                    badge: "Requires Funding",
                    symbol: "creditcard.fill",
                    headline: "Deposit ETH to activate zkAPI Anon Inference",
                    detail: "Send ETH on Ethereum Mainnet and make a $5–$10 deposit to unlock one-time zkAPI credentials (including Tier 5 & Tier 25 models).",
                    buttonTitle: "Add Funds…",
                    destination: .funds)
            case .taken:
                return ModeSetupRequirement(
                    badge: "Requires Funding",
                    symbol: "creditcard.fill",
                    headline: "Previous zkAPI deposit closed",
                    detail: "Your earlier zkAPI deposit was closed on-chain. Make a new $5–$10 deposit in Funds to keep chatting.",
                    buttonTitle: "Add Funds…",
                    destination: .funds)
            case .unread:
                guard chat.payer.savedExpiry == nil else { return nil }
                return ModeSetupRequirement(
                    badge: "Requires Funding",
                    symbol: "creditcard.fill",
                    headline: "Set up your zkAPI ETH deposit",
                    detail: "Start Cloak and make a $5–$10 ETH deposit on Ethereum Mainnet to pay each turn with a fresh one-time zkAPI credential.",
                    buttonTitle: "Open Funds…",
                    destination: .funds)
            case .depositing, .ready, .settling, .withdrawing, .failed:
                return nil
            }
        }
    }
}

private struct ModeSetupCard: View {
    let requirement: ModeSetupRequirement
    let openFunds: () -> Void
    let openNearSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label(requirement.badge, systemImage: requirement.symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.orange.opacity(0.14)))
                Spacer(minLength: 0)
            }
            Text(requirement.headline)
                .font(.headline)
            Text(requirement.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(requirement.buttonTitle) {
                    switch requirement.destination {
                    case .funds: openFunds()
                    case .nearSettings: openNearSettings()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                Spacer(minLength: 0)
            }
            .padding(.top, 2)
        }
        .padding(16)
        .frame(maxWidth: 480, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.28), lineWidth: 1))
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

private struct ModeSetupPill: View {
    let requirement: ModeSetupRequirement
    let openFunds: () -> Void
    let openNearSettings: () -> Void

    var body: some View {
        Button {
            switch requirement.destination {
            case .funds: openFunds()
            case .nearSettings: openNearSettings()
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: requirement.symbol)
                    .font(.system(size: 10, weight: .semibold))
                Text(requirement.badge)
                    .font(.caption.weight(.semibold))
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .opacity(0.75)
            }
            .foregroundStyle(.orange)
            .padding(.horizontal, 9)
            .frame(minHeight: 26)
            .background(Capsule().fill(Color.orange.opacity(0.13)))
            .overlay(Capsule().strokeBorder(Color.orange.opacity(0.32), lineWidth: 0.75))
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .tip("\(requirement.headline) — click to \(requirement.buttonTitle.lowercased())")
        .accessibilityLabel("\(requirement.badge). \(requirement.buttonTitle)")
    }
}

/// Compact logo toggle for switching between Venice AI (Base USDC) and
/// Boundless + Tempo (USDC.e) directly below the Token Inference composer —
/// works both on new chats (beside the Agent hammer) and mid-chat.
/// Clicking anywhere on the capsule switches to the other provider.
private struct TokenProviderToggle: View {
    @Binding var provider: PayProvider
    @Namespace private var pillNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var nextProvider: PayProvider {
        provider == .venice ? .boundless : .venice
    }

    var body: some View {
        Button {
            provider = nextProvider
        } label: {
            HStack(spacing: 2) {
                badge(.venice) {
                    BrandMark.venice
                        .fill(style: FillStyle(eoFill: true))
                        .frame(width: 12, height: 13.5)
                }
                badge(.boundless) {
                    BrandMark.boundless
                        .fill(style: FillStyle(eoFill: true))
                        .frame(width: 13.5, height: 13)
                }
            }
            .padding(3)
            .frame(minHeight: 28)
            .hover(Capsule())
            .glassEffect(.regular.interactive(), in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .contentShape(.capsule)
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: provider)
        .tip("\(provider.title) — click to switch to \(nextProvider.title)")
        .accessibilityLabel("Token Inference provider")
        .accessibilityValue(provider.title)
        .accessibilityHint("Switches to \(nextProvider.title)")
    }

    @ViewBuilder
    private func badge<Icon: View>(
        _ value: PayProvider, @ViewBuilder icon: () -> Icon
    ) -> some View {
        let selected = provider == value
        icon()
            .foregroundStyle(selected ? HierarchicalShapeStyle.primary : HierarchicalShapeStyle.tertiary)
            .frame(width: 26, height: 22)
            .background {
                if selected {
                    Capsule()
                        .fill(Color.primary.opacity(0.14))
                        .matchedGeometryEffect(id: "token-provider-active", in: pillNamespace)
                }
            }
    }
}

/// Interactive Agent (hammer) toggle pill with a non-transient explanatory hover
/// popover (including a clickable learn-more link) so clicking anywhere on the
/// pill toggles Agent immediately even while the tooltip is open or opening.
private struct AgentPill: View {
    @Binding var isOn: Bool
    let showTour: () -> Void
    @State private var showingInfo = false
    @State private var hoveringPill = false
    @State private var hoveringPopover = false
    @State private var hoverTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let docsURL = URL(string: "https://regents.sh/cloak#agent")!

    var body: some View {
        HStack(spacing: 2) {
            Button {
                isOn.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: isOn ? "circle.fill" : "circle")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(isOn ? Color.green : Color.secondary)
                        .contentTransition(.symbolEffect(.replace))
                    Image(systemName: Chat.Kind.agentSymbol)
                        .foregroundStyle(HierarchicalShapeStyle.primary)
                    Text(Chat.Kind.agentName)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(HierarchicalShapeStyle.primary)
                }
                .padding(.horizontal, 10)
                .frame(minHeight: 28)
                .hover(Capsule())
                .glassEffect(.regular.interactive(), in: .capsule)
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .textSelection(.disabled)
            .contentShape(.capsule)
            .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: isOn)
            .onHover { inside in
                hoveringPill = inside
                schedulePopover()
            }

            Button {
                hoverTask?.cancel()
                showingInfo.toggle()
            } label: {
                Image(systemName: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("About Local Agent Box")
            .help("About Local Agent Box")
        }
        .hoverPopover(isPresented: $showingInfo, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 0) {
                BulletNote(
                    "Local Agent Box",
                    bullets: [
                        "Runs multi-step tasks inside an isolated Linux VM on this Mac.",
                        "Shell and coding tools never touch your macOS files directly.",
                        "Prompts are rewritten locally and routed over Tor.",
                        "Paid via zkAPI Anon Inference or Boundless/Tempo USDC.e in Token Inference.",
                    ])
                Divider()
                HStack(spacing: 12) {
                    Link(destination: Self.docsURL) {
                        HStack(spacing: 3) {
                            Text("Learn more")
                            Image(systemName: "arrow.up.right")
                                .font(.caption2)
                        }
                    }
                    Spacer()
                    Button("Tour (⌘/)") {
                        showingInfo = false
                        showTour()
                    }
                    .buttonStyle(.link)
                }
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .frame(width: 310)
            .onHover { inside in
                hoveringPopover = inside
                schedulePopover()
            }
        }
        .onDisappear { hoverTask?.cancel() }
        .accessibilityRepresentation {
            Toggle(Chat.Kind.agentName, isOn: $isOn)
                .toggleStyle(.switch)
                .accessibilityHint(Chat.Kind.agentAbout)
        }
    }

    private func schedulePopover() {
        hoverTask?.cancel()
        if hoveringPill || hoveringPopover {
            guard !showingInfo, NSApp.isActive else { return }
            hoverTask = Task {
                guard (try? await Task.sleep(for: .milliseconds(450))) != nil else { return }
                guard NSApp.isActive, hoveringPill || hoveringPopover else { return }
                showingInfo = true
            }
        } else if showingInfo {
            hoverTask = Task {
                guard (try? await Task.sleep(for: .milliseconds(250))) != nil else { return }
                if !hoveringPill, !hoveringPopover {
                    showingInfo = false
                }
            }
        }
    }
}

/// Tor's symbol, shared by the toolbar Tor button, NEAR's Tor switch, Menu bar, and the Routed light.
let torSymbol = "point.3.connected.trianglepath.dotted"

/// Compact clickable Mode + Model capsule in Chat's native titlebar.
/// Clicking opens a concise bulleted explanation popover + quick Settings/Tour links.
private struct TitlebarModePill: View {
    let chat: Chat
    let kind: Chat.Kind
    let showLlamaSettings: () -> Void
    let showNearSettings: () -> Void
    @State private var showingInfo = false
    @Environment(\.colorSchemeContrast) private var contrast

    private var subtitle: String {
        let model = chat.activeModelName(for: kind, conversation: chat.selected)
        if let provider = chat.activeProviderName(for: kind, conversation: chat.selected),
            !kind.name.localizedCaseInsensitiveContains(provider)
        {
            return "\(provider) · \(model)"
        }
        return model
    }

    private var tint: Color {
        switch kind {
        case .llama: .green
        case .near: .accentColor
        case .token: .orange
        case .v: .purple
        }
    }

    var body: some View {
        Button {
            showingInfo.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: kind.symbol)
                    .imageScale(.small)
                    .foregroundStyle(tint)
                Text(kind.shortTitle)
                    .fontWeight(.medium)
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(subtitle)
                    .foregroundStyle(contrast == .increased ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 4)
        }
        .popover(isPresented: $showingInfo, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                BulletNote(popoverTitle, bullets: popoverBullets)
                if let credit = popoverCredit {
                    Text(credit)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 10)
                }
                Divider()
                HStack(spacing: 12) {
                    if kind == .llama {
                        Button("Local Models…") {
                            showingInfo = false
                            showLlamaSettings()
                        }
                        .buttonStyle(.link)
                    } else if kind == .near {
                        Button("NEAR AI Gateway Settings…") {
                            showingInfo = false
                            showNearSettings()
                        }
                        .buttonStyle(.link)
                    } else {
                        Button("Manage Funds…") {
                            showingInfo = false
                            chat.showingWallet = true
                        }
                        .buttonStyle(.link)
                    }
                    Spacer()
                    Button("Tour (⌘/)") {
                        showingInfo = false
                        chat.showingTour = true
                    }
                    .buttonStyle(.link)
                }
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .frame(width: 310)
        }
        .tip(
            kind == .near
                ? "About \(kind.name) · Model: \(chat.activeModelFullName(for: kind, conversation: chat.selected)) · More models in next update (⌘1–⌘4 to switch modes)"
                : "About \(kind.name) · Model: \(chat.activeModelFullName(for: kind, conversation: chat.selected)) (⌘1–⌘4 to switch modes)"
        )
    }

    private var popoverTitle: String {
        "\(kind.shortTitle) · \(subtitle)"
    }

    private var popoverCredit: LocalizedStringKey? {
        if kind == .token, chat.usesVenice(for: chat.selected) {
            return "Powered by [Venice AI](https://venice.ai) ([Docs](https://docs.venice.ai) · [GitHub](https://github.com/veniceai))."
        }
        return kind.credit
    }

    private var popoverBullets: [String] {
        let modelLine = "Model: \(chat.activeModelFullName(for: kind, conversation: chat.selected))"
        return switch kind {
        case .llama:
            [
                modelLine,
                "100% offline on this Mac — free, no account, no crypto.",
                "Model weights are SHA-256 verified before loading.",
                "Switch MLX/GGUF tiers or toggle Unfiltered LoRA in Settings.",
            ]
        case .near:
            [
                "\(modelLine) (More models in next update.)",
                "Hardware-verified Intel TDX + NVIDIA enclaves using a NEAR API key.",
                chat.settings.nearTor ? "Routing through Tor (hides your IP; slower)." : "Tor is off — toggle Tor below to hide your IP.",
                "Attestation verifies enclave hardware; your key ties chats to one NEAR account.",
            ]
        case .token:
            [
                modelLine,
                "Pays per prompt with a local USDC wallet — no account or card.",
                chat.usesVenice(for: chat.selected)
                    ? "Venice (Base USDC): Private & TEE models via dedicated Keychain wallet."
                    : "Boundless (Tempo USDC.e): per-request payment channel.",
                chat.settings.tokenTor
                    ? "Routing through Tor (hides your IP; slower). Toggle Tor off below for speed."
                    : "Direct HTTPS (faster, no Tor/VM). Toggle Tor on below to hide your IP.",
            ]
        case .v:
            [
                modelLine,
                "Zero-knowledge proofs (zkAPI) pay every prompt with a fresh one-time key.",
                "Unlinkable even to your own earlier prompts.",
                "Prompts are rewritten locally and routed through Tor.",
            ]
        }
    }
}

/// NEAR mode's switch, Tor (`AppSettings.nearTor`), and beside it what
/// NEAR's hardware check last found. The check runs as this shows, and
/// again each time the route changes.
private struct NearSwitches: View {
    @Bindable var settings: AppSettings
    let nearMode: NearMode
    let supervisor: Supervisor
    let download: ModelDownload

    var body: some View {
        HStack(spacing: 6) {
            CompactPrivacyToggleButton(
                symbol: torSymbol,
                label: "Tor",
                isOn: settings.nearTor,
                isActive: settings.nearTor && supervisor.phase == .running,
                isBusy: settings.nearTor && supervisor.phase.state == .preparing,
                tip: settings.nearTor
                    ? (supervisor.phase == .running
                        ? "Tor is ON for NEAR — NEAR and Intel see a Tor exit IP (slower). Click to turn off."
                        : "Tor is ON for NEAR (starting Cloak…). Click to switch back to direct.")
                    : "Tor is OFF for NEAR — NEAR and Intel see this Mac's IP. Click to route through Tor."
            ) {
                let next = !settings.nearTor
                settings.nearTor = next
                if next, supervisor.phase != .running, supervisor.phase.state != .preparing, download.state == .installed {
                    supervisor.send(.start)
                }
            }
            if settings.nearTor {
                CompactPrivacyToggleButton(
                    symbol: "waveform.path",
                    label: "Cover Traffic",
                    isOn: settings.cover,
                    isActive: settings.cover && supervisor.phase == .running,
                    isBusy: false,
                    tip: settings.cover
                        ? (supervisor.phase == .running
                            ? "Cover Traffic is ON — sending random public Tor fetches (~3/min) to blur prompt timing. Click to turn off."
                            : "Cover Traffic is ON (starts when Cloak runs). Click to turn off.")
                        : "Cover Traffic is OFF — click to send random public Tor fetches (~3/min) to blur prompt timing."
                ) {
                    settings.cover.toggle()
                }
            }
            NearStatus(settings: settings, nearMode: nearMode)
                .font(.caption)
                .padding(.leading, 2)
        }
        .task(id: nearMode.route) { await nearMode.check() }
    }
}

/// What NEAR's hardware check last found: under way, with how long it has
/// taken; passed, as a shield and how long ago, the shield grey once the
/// next message checks again; verified & refused, with an orange shield and
/// Check Again; failed to reach NEAR/Intel, saying check failed; or paused
/// while Tor needs Cloak running.
private struct NearStatus: View {
    let settings: AppSettings
    let nearMode: NearMode

    var body: some View {
        if nearMode.route == nil {
            Text("Not checked · Tor paused")
                .foregroundStyle(.secondary)
                .tip("Hardware check over Tor runs once Cloak starts.")
        } else if let started = nearMode.checking {
            Busy(title: settings.nearTor ? "Checking NEAR's hardware through Tor" : "Checking NEAR's hardware", started: started)
        } else if let stop = nearMode.checkStop {
            let verificationFailed = stop.kind == .refused || stop.kind == .pin || stop.kind == .reply
            let viaTor = settings.nearTor
            HStack(spacing: 4) {
                Label {
                    Text(verificationFailed ? stop.title(viaTor: viaTor) : "Check failed: \(stop.title(viaTor: viaTor))")
                        .foregroundStyle(verificationFailed ? Color.orange : Color.secondary)
                } icon: {
                    Image(systemName: verificationFailed ? "exclamationmark.shield.fill" : "shield.slash")
                        .foregroundStyle(verificationFailed ? Color.orange : Color.secondary)
                }
                .tip("\(stop.title(viaTor: viaTor)): \(stop.words(viaTor: viaTor))")
                SymbolButton("Check Again", symbol: "arrow.clockwise") { Task { await nearMode.check() } }
            }
        } else if let proof = nearMode.proof {
            // Each minute from the check, so the age and the freshness
            // passing show as they happen.
            TimelineView(.periodic(from: proof.passedAt, by: 60)) { context in
                let age = context.date.timeIntervalSince(proof.passedAt)
                let everyMessage = settings.proofFreshness == .everyMessage
                let fresh = everyMessage ? age < 300 : age < Double(settings.proofFreshness.rawValue)
                let words = Self.checked(proof, age: age) + (everyMessage ? ". Next message checks again." : (fresh ? "." : ". Next message checks again."))
                Label {
                    if everyMessage {
                        Text(fresh ? "Verified · re-checks next send" : "\(Self.age(age)) · re-checks next send")
                    } else {
                        Text(fresh ? "Verified · \(Self.age(age))" : Self.age(age))
                    }
                } icon: {
                    Image(systemName: "checkmark.shield")
                        .foregroundStyle(fresh ? .green : .secondary)
                }
                .foregroundStyle(.secondary)
                .tip(words)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(words)
            }
        }
    }

    /// "Checked 2 min ago: 1 server, 8 GPUs", or with several servers,
    /// "Checked 2 min ago: 3 servers, 8 GPUs on one", plus negotiated TLS
    /// key exchange when reported by `cloak-near`.
    private static func checked(_ proof: NearProof, age: TimeInterval) -> String {
        let minutes = Int(age / 60)
        let when = minutes < 1 ? "just now" : "\(minutes) min ago"
        let gpus = proof.gpus == 1 ? "1 GPU" : "\(proof.gpus) GPUs"
        let base = proof.modelServers == 1
            ? "Checked \(when): 1 server, \(gpus)"
            : "Checked \(when): \(proof.modelServers) servers, \(gpus) on one"
        if let tls = proof.tlsSummary {
            return "\(base) · \(tls)"
        }
        return base
    }

    /// "now", or "9 min".
    private static func age(_ age: TimeInterval) -> String {
        let minutes = Int(age / 60)
        return minutes < 1 ? "now" : "\(minutes) min"
    }
}

/// The mode switch under an empty chat's box: a segment a mode, each its
/// symbol and the chosen one its name too. Agent stays as it is across a
/// change, and shows again in a mode that has it. A segment's help names
/// its mode and says what it does and who pays. VoiceOver reads it as a radio group, each segment by
/// its mode's name. AppKit's own segmented control, since SwiftUI's draws a
/// segment's symbol or its name, never both.
private struct ModeSwitch: NSViewRepresentable {
    @Binding var kind: Chat.Kind

    func makeCoordinator() -> Coordinator {
        Coordinator(kind: $kind)
    }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.trackingMode = .selectOne
        control.segmentCount = Chat.Kind.modes.count
        for (index, mode) in Chat.Kind.modes.enumerated() {
            control.setImage(NSImage(systemSymbolName: mode.symbol, accessibilityDescription: mode.name), forSegment: index)
            control.setToolTip(mode.about, forSegment: index)
        }
        control.target = context.coordinator
        control.action = #selector(Coordinator.choose(_:))
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.kind = $kind
        for (index, mode) in Chat.Kind.modes.enumerated() {
            control.setLabel(mode == kind ? mode.name : "", forSegment: index)
        }
        control.selectedSegment = Chat.Kind.modes.firstIndex(of: kind) ?? -1
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }

    @MainActor final class Coordinator: NSObject {
        var kind: Binding<Chat.Kind>

        init(kind: Binding<Chat.Kind>) {
            self.kind = kind
        }

        @objc func choose(_ control: NSSegmentedControl) {
            kind.wrappedValue = Chat.Kind.modes[control.selectedSegment]
        }
    }
}

extension Chat.Kind {
    /// The modes, in the switch's and the Modes page's order: simplest first
    /// (Local) to most paranoid (Paranoid (V)) (Decision R2b).
    static let modes: [Chat.Kind] = [.llama, .near, .token, .v]

    static let agentName = "Agent"
    static let agentSymbol = "hammer"
    /// The Agent switch's help.
    static let agentAbout =
        "Runs multi-step tasks inside a sealed Linux VM on this Mac over Tor, paid the same way as this chat."

    var name: String {
        switch self {
        case .llama: "Local"
        case .near: "NEAR AI Gateway"
        case .token: "Token Inference"
        case .v: "zkAPI Anon Inference"
        }
    }

    var shortTitle: String {
        switch self {
        case .llama: "Local"
        case .near: "NEAR AI Gateway"
        case .token: "Token Inference"
        case .v: "zkAPI Anon Inference"
        }
    }

    /// Its symbol, here and in the chat list.
    var symbol: String {
        switch self {
        case .v: "theatermasks"
        case .token: "dollarsign.circle"
        case .near: "cpu"
        case .llama: "laptopcomputer"
        }
    }

    /// Plain-English tooltip including approved "Why crypto?" rationale (Decision N4).
    var about: String {
        switch self {
        case .llama: "Local: 100% offline on your Mac. Free, no account, no crypto."
        case .near: "NEAR AI Gateway: Hardware-verified enclaves using a NEAR API key, with optional Trace Commons sharing."
        case .token: "Token Inference: Pay per prompt over Tor with local USDC — no account or credit card."
        case .v: "zkAPI Anon Inference: Zero-knowledge proofs pay every prompt with a fresh one-time key — unlinkable even to your own chats."
        }
    }

    /// What pays for it, on the Modes page.
    var paidWith: String {
        switch self {
        case .llama: "Free · Runs on this Mac"
        case .near: "NEAR API key (no crypto)"
        case .token: CardOnRamp.isConfigured ? "Base USDC · Card / Apple Pay" : "Base USDC · Venice key · Tempo"
        case .v: CardOnRamp.isConfigured ? "ETH via zkAPI (Card / crypto)" : "Ethereum Mainnet ETH (zkAPI)"
        }
    }

    /// What Cloak does in it, on the Modes page, a short line each.
    var lines: [String] {
        switch self {
        case .llama:
            ["Runs completely on your Mac.", "No internet, no account, no cost, no crypto.", "Works offline immediately once downloaded."]
        case .near:
            ["Remote hardware cryptographically proves it's isolated.", "Paid with a standard NEAR API key — no crypto required.", "Optional Tor routing and Trace Commons export."]
        case .token:
            [
                "Prompts are rewritten locally and sent through Tor.",
                "Why stablecoins? Credit cards tie every prompt to your name; a local USDC wallet pays per prompt with no account.",
                "Supports Agent tasks.",
            ]
        case .v:
            [
                "Prompts are rewritten locally and sent through Tor.",
                "Why ETH? Zero-knowledge proofs (zkAPI) pay every prompt with a fresh one-time key — impossible to link, even to your own earlier prompts.",
                "Supports Agent tasks.",
            ]
        }
    }

    /// Where it comes from, with links to its makers' website, repo, or post.
    var credit: LocalizedStringKey? {
        switch self {
        case .v: "Powered by [zkAPI](https://zkapi.openanonymity.ai) ([GitHub](https://github.com/ethereum/zkapi)). Inspired by Vitalik's [X post](https://x.com/VitalikButerin/status/2111046730959433793)."
        case .token: "Powered by [Boundless](https://boundless.network) on [Tempo](https://tempo.xyz) via [MPP](https://mpp.dev) ([GitHub](https://github.com/tempoxyz/mpp-rs))."
        case .near: "Powered by [NEAR AI Cloud](https://cloud.near.ai) and [Trace Commons](https://github.com/TraceCommons/trace-commons) ([NEAR AI Gateway](https://gateway.near.ai))."
        case .llama: "Powered by [vmlx-swift](https://github.com/osaurus-ai/vmlx-swift) and [llama.cpp](https://github.com/ggml-org/llama.cpp) ([X post](https://x.com/ggerganov/status/2121246103312212124))."
        }
    }
}

/// Why a Venice message stopped, with a direct Funds CTA for balance/key issues.
private struct VeniceStopRow: View {
    let stop: VeniceStop
    let showFunds: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(stop.kind.title)
                    .fontWeight(.medium)
                Text(stop.kind.words)
                    .foregroundStyle(.secondary)
                Text(stop.sent ? "Your message may have reached Venice." : "Nothing was sent.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if [.noBalance, .key, .keychain, .paymentRefused, .spendLimit].contains(stop.kind) {
                Button("Funds…", action: showFunds)
            }
            Button("Dismiss", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .hover(Circle(), outset: 4)
                .tip("Dismiss")
        }
    }
}

/// Why a NEAR message stopped, in plain words, and whether it may have
/// reached NEAR. A key NEAR refused comes with the way to replace it.
private struct NearStopRow: View {
    let stop: NearStop
    let viaTor: Bool
    let showSettings: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(stop.title(viaTor: viaTor))
                    .fontWeight(.medium)
                Text(stop.words(viaTor: viaTor))
                    .foregroundStyle(.secondary)
                Text(stop.sent ? "Your message may have reached NEAR. Sending again may be charged twice." : "Nothing was sent.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if stop.kind == .status, stop.code == 401 || stop.code == 403 {
                Button("Settings…", action: showSettings)
            }
            Button("Dismiss", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .hover(Circle(), outset: 4)
                .tip("Dismiss")
        }
    }
}

/// Inline first-run onboarding card in Chat's Local mode (Decision N6b):
/// shows a single primary "Download Recommended Local Model (<size>)" CTA with
/// inline progress + pause/cancel, secondary quick-switch links for cloud modes,
/// and a 0.5-second interactive hover popover explaining the recommended model
/// with a clickable hyperlink to its exact pinned HuggingFace repository.
private struct LocalOnboardingCard: View {
    let chat: Chat
    let block: Chat.LlamaBlock
    @State private var showingInfo = false
    @State private var hoveringButton = false
    @State private var hoveringPopover = false
    @State private var hoverTask: Task<Void, Never>?
    @State private var confirmingCancel = false

    private var download: ModelDownload {
        switch block {
        case .missing(let missing), .mac(let missing): missing
        case .unknown: chat.recommendedLocalDownload
        }
    }

    private var isRecommended: Bool {
        download.model.name == chat.recommendedLocalDownload.model.name && download.model.memory > 0
    }

    private var isAdapter: Bool {
        download.model.memory == 0
    }

    var body: some View {
        let size = DownloadSection.text(download.total)
        let isInkling = download.model.label.localizedCaseInsensitiveContains("Inkling")
        let repoURL = download.model.repositoryURL ?? URL(string: "https://huggingface.co")!

        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: download.fits ? "laptopcomputer" : "cpu")
                        .font(.title2)
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(
                            !download.fits
                                ? "Use NEAR AI Gateway on this Mac"
                                : isRecommended
                                    ? "Private AI on this Mac"
                                    : isAdapter
                                        ? "Download Unfiltered Adapter"
                                        : "Download \(download.model.label)"
                        )
                        .font(.headline)
                        Text(
                            !download.fits
                                ? "Local models need 16 GB+ Apple Silicon. NEAR AI Gateway works right away on this Mac."
                                : isRecommended
                                    ? "\(download.model.label) (\(size)) · runs offline with no account, cost, or crypto."
                                    : isAdapter
                                        ? "Optional \(size) uncensored LoRA adapter is enabled in Settings."
                                        : "Download \(download.model.label) (\(size)) once to chat offline."
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if !download.fits {
                    HStack(spacing: 10) {
                        Button {
                            chat.kind = .near
                        } label: {
                            Label("Use NEAR AI Gateway", systemImage: "cpu")
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Take a Tour") { chat.showingTour = true }
                        Spacer(minLength: 0)
                    }
                } else {
                    if download.isUnderWay || download.done > 0 {
                        VStack(alignment: .leading, spacing: 6) {
                            ProgressView(value: Double(download.done), total: Double(max(download.total, 1)))
                                .accessibilityLabel("Downloading \(download.model.label)")
                                .accessibilityValue("\(DownloadSection.text(download.done)) of \(size)")
                            HStack {
                                Text("\(DownloadSection.status(download.state)) \(download.model.label)…")
                                Spacer()
                                Text("\(DownloadSection.text(download.done)) of \(size)")
                                    .monospacedDigit()
                            }
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        }
                    }

                    if let note = DownloadSection.note(download) {
                        Label(note, systemImage: "exclamationmark.circle.fill")
                            .symbolRenderingMode(.multicolor)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else if !download.isUnderWay, let block = download.blocked {
                        Text(DownloadSection.text(block))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 10) {
                        if download.isUnderWay {
                            Button("Pause") { download.pause() }
                            Button("Cancel") { confirmingCancel = true }
                        } else {
                            let title = download.done > 0 ? "Continue (\(size))" : "Download (\(size))"
                            Button {
                                if isRecommended {
                                    chat.downloadRecommendedLocalModel()
                                } else {
                                    download.start()
                                }
                            } label: {
                                Label(title, systemImage: "arrow.down.circle.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(download.blocked != nil)
                            .onHover { inside in
                                hoveringButton = inside
                                schedulePopover()
                            }
                            .popover(isPresented: $showingInfo, arrowEdge: .bottom) {
                                VStack(alignment: .leading, spacing: 6) {
                                    if download.model.engine == .vmlx {
                                        Text("Best recent model is the Inkling 2 Mini (Fast, runs on 16 GB+ Macs at 60+ tok/s). Downloads from [HuggingFace](\(repoURL.absoluteString)).")
                                    } else if isInkling {
                                        Text("Best recent model is the Inkling 2 Mini. Downloads from [HuggingFace](\(repoURL.absoluteString)).")
                                    } else {
                                        Text("Downloads \(download.model.label) from [HuggingFace](\(repoURL.absoluteString)).")
                                    }
                                }
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(12)
                                .frame(width: 280, alignment: .leading)
                                .onHover { inside in
                                    hoveringPopover = inside
                                    schedulePopover()
                                }
                            }
                            if download.hasPartials {
                                Button("Cancel") { confirmingCancel = true }
                            }
                        }
                        Spacer(minLength: 0)
                    }

                    Divider()

                    HStack(spacing: 8) {
                        Text("Or start right away without downloading:")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button("NEAR AI Gateway") { chat.kind = .near }
                            .buttonStyle(.link)
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Button("Take a Tour") { chat.showingTour = true }
                            .buttonStyle(.link)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(.top, 8)
        .onDisappear { hoverTask?.cancel() }
        .confirmationDialog("Cancel the download?", isPresented: $confirmingCancel) {
            Button("Cancel Download", role: .destructive) { download.cancel() }
            Button("Keep Downloading", role: .cancel) {}
        } message: {
            Text("What has downloaded so far is deleted from this Mac.")
        }
    }

    /// Shows the popover after 0.5 s of hovering the download button, and
    /// keeps it open while the pointer moves into the popover to click the
    /// HuggingFace hyperlink.
    private func schedulePopover() {
        hoverTask?.cancel()
        if hoveringButton || hoveringPopover {
            guard !showingInfo, NSApp.isActive else { return }
            hoverTask = Task {
                guard (try? await Task.sleep(for: .milliseconds(500))) != nil else { return }
                guard NSApp.isActive, hoveringButton || hoveringPopover else { return }
                showingInfo = true
            }
        } else if showingInfo {
            hoverTask = Task {
                guard (try? await Task.sleep(for: .milliseconds(250))) != nil else { return }
                if !hoveringButton, !hoveringPopover {
                    showingInfo = false
                }
            }
        }
    }
}

/// Interactive switch pill (used for real toggles like NEAR's Tor and Agent)
/// with a short visible label so controls never rely on cryptic icons alone.
private struct SwitchPill: View {
    let title: String
    let symbol: String
    @Binding var isOn: Bool
    let help: String
    var fixed: String?
    @State private var explaining = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            if fixed == nil { isOn.toggle() } else { explaining = true }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isOn ? "circle.fill" : "circle")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(isOn ? Color.green : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
                Image(systemName: symbol)
                    .foregroundStyle(fixed == nil ? HierarchicalShapeStyle.primary : .secondary)
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(fixed == nil ? HierarchicalShapeStyle.primary : .secondary)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 28)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        // Before the glass, so the hover lies on it rather than behind it.
        .hover(Capsule())
        .glassEffect(.regular.interactive(), in: .capsule)
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: isOn)
        .popover(isPresented: $explaining, arrowEdge: .top) {
            Text(fixed ?? "")
                .font(.callout)
                .padding(12)
        }
        .accessibilityRepresentation {
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)
                .disabled(fixed != nil)
                .accessibilityHint(fixed ?? "")
        }
        .tip(help)
    }
}

/// Cloak's state while it is not running, with a visible 1-3 word status label
/// and labeled primary CTA (Decision R1b). When `autoStarts` is true (Decision
/// R3b), notes that Cloak will start automatically on Send.
private struct Waiting: View {
    let supervisor: Supervisor
    /// The model that rewords', whose files the fix reads.
    let download: ModelDownload
    /// What waits, as the verb ending each sentence: reword, send or run.
    let to: String
    var autoStarts = false
    let showDetails: () -> Void

    var body: some View {
        let phase = supervisor.phase
        let needsRewriter = (phase == .paused || phase == .ready) && download.state != .installed
        let fix = phase.reason.flatMap { Fix(for: $0, download: download) }
        let words = needsRewriter
            ? (download.isUnderWay ? "Downloading the local rewriter model to \(to)." : "Download the local rewriter model to \(to).")
            : text(phase, fix: fix)
        let failed = if case .needsAttention = phase { true } else { false }
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: needsRewriter ? "arrow.down.circle" : phase.symbol)
                    .foregroundStyle(failed ? Color.orange : Color.secondary)
                    .accessibilityHidden(true)
                if needsRewriter {
                    Text(download.isUnderWay ? "Downloading local rewriter…" : "Download local rewriter to \(to)")
                        .fontWeight(.medium)
                        .accessibilityHidden(true)
                } else if failed {
                    Text(words)
                        .accessibilityHidden(true)
                } else {
                    Text(shortLabel(phase))
                        .fontWeight(.medium)
                        .accessibilityHidden(true)
                    if autoStarts, phase == .paused || phase == .ready {
                        Text("· Starts automatically when you send")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                }
                Spacer(minLength: 4)
                if needsRewriter {
                    Button(download.isUnderWay ? "Downloading…" : "Download Model…", action: showDetails)
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                } else {
                    switch phase {
                    case .needsAttention:
                        switch fix {
                        case .start?:
                            Button { supervisor.send(.start) } label: {
                                Label(Fix.start.title, systemImage: "play.fill")
                            }
                            .controlSize(.small)
                        case .download(let underWay)?:
                            Button(Fix.download(underWay: underWay).title, action: showDetails)
                                .controlSize(.small)
                                .buttonStyle(.borderedProminent)
                        case .repair?:
                            Button(Fix.repair.title) { download.repair() }
                                .controlSize(.small)
                                .buttonStyle(.borderedProminent)
                        case .showModel?:
                            Button(Fix.showModel.title, action: Fix.showModel)
                                .controlSize(.small)
                        case nil: EmptyView()
                        }
                    case .paused, .ready:
                        Button { supervisor.send(.start) } label: {
                            Label("Start", systemImage: "play.fill")
                        }
                        .controlSize(.small)
                    case .preparing:
                        let stepIndex = (supervisor.startStep?.rawValue ?? 0) + 1
                        let stepTotal = Supervisor.StartStep.allCases.count
                        Text("Step \(stepIndex) of \(stepTotal)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        ProgressView()
                            .controlSize(.small)
                            .tip(words)
                    case .stopping, .running:
                        ProgressView()
                            .controlSize(.small)
                            .tip(words)
                    }
                }
            }
            if phase.state == .preparing {
                StartupProgressView(supervisor: supervisor)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, phase.state == .preparing ? 10 : 8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        // The sentence, read once, then the button.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(words)
    }

    private func shortLabel(_ phase: Phase) -> String {
        switch phase {
        case .paused, .ready: "Paused"
        case .preparing: "Starting…"
        case .stopping(.restart): "Restarting…"
        case .stopping: "Stopping…"
        case .running: "Running"
        case .needsAttention: "Needs attention"
        }
    }

    private func text(_ phase: Phase, fix: Fix?) -> String {
        switch phase {
        case .paused: autoStarts ? "Cloak is paused. Send to auto-start, or press Start." : "Cloak is paused. Start it to \(to)."
        case .ready: autoStarts ? "Cloak isn't running. Send to auto-start, or press Start." : "Cloak isn't running. Start it to \(to)."
        case .preparing: "Cloak is starting."
        case .stopping(.restart): "Cloak is restarting."
        case .stopping: "Cloak is stopping."
        case .needsAttention(let reason):
            switch fix {
            case .start?:
                if reason == .torUnavailable || reason == .torStopped {
                    "\(reason.title(with: fix)) \(reason.remedy)"
                } else {
                    "\(reason.title(with: fix)) Start Cloak again to \(to)."
                }
            case .download?: "\(reason.title) Download it to \(to)."
            case .repair?: "\(reason.title) Repair it to \(to)."
            // No button does it all, so the words say what to do.
            case .showModel?, nil: "\(reason.title) \(reason.remedy)"
            }
        case .running: "Cloak is running."
        }
    }
}

/// In a chat that would reword, while another chat's rewording runs: that,
/// and Cancel, which cancels it there. One model on this Mac rewords one
/// message at a time.
private struct RewordingElsewhere: View {
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "pencil.line")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Another chat is rewriting a prompt.")
            Spacer()
            Button("Cancel", action: cancel)
                .tip("Cancel the other chat's prompt rewrite")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }
}

/// Why a Local Llama chat can't ask (`Chat.LlamaBlock`), and the way on:
/// for the model that rewords, its download in Details; for any other, the
/// Local Llama settings, to download it or choose another. A Mac that can't
/// run the model that rewords can run none, so that stop has no button.
private struct LlamaStop: View {
    let block: Chat.LlamaBlock
    let showDetails: () -> Void
    let showLlamaSettings: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(block.words)
            Spacer()
            switch block {
            case .missing(let download):
                Button(
                    download.isUnderWay ? "Downloading Model…" : "Download Model…",
                    action: download.rewords ? showDetails : showLlamaSettings)
            case .mac(let download) where download.rewords:
                EmptyView()
            case .unknown, .mac:
                Button("Choose Model…", action: showLlamaSettings)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private var symbol: String {
        switch block {
        case .missing: "arrow.down.circle"
        case .unknown, .mac: "laptopcomputer"
        }
    }
}

private struct Notice: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .fontWeight(.medium)
                Text(detail)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Dismiss", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .hover(Circle(), outset: 4)
                .tip("Dismiss")
        }
        .padding(12)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tint.opacity(0.3)))
    }
}

extension Chat.Stop {
    var title: String {
        switch reason {
        case .tooLong: "This message is too long."
        case .timedOut: "Prompt rewriting took too long."
        case .refused: "Couldn't rewrite this prompt."
        case .cancelled: "Rewriting cancelled."
        case .stopped: "The model stopped."
        }
    }

    var detail: String {
        let next = switch reason {
        case .tooLong(let characters):
            "It has \(characters.formatted()) characters; the most is \(Rewrite.maxCharacters.formatted()). Shorten it, then try again."
        case .timedOut: "Try again, or shorten it."
        case .refused: "Try again."
        case .cancelled: ""
        case .stopped: "Start Cloak, then try again."
        }
        let back = turn == nil ? "Your message is back in the box." : "The message is as it was."
        return next.isEmpty ? back : back + " " + next
    }
}

extension NearStop {
    var title: String { title(viaTor: false) }
    var words: String { words(viaTor: false) }

    func title(viaTor: Bool) -> String {
        switch kind {
        case .line: "Cloak error"
        case .request: "Can't send"
        case .fetch: viaTor ? "Tor check failed" : "No proof"
        case .refused: "Proof refused"
        case .connect: viaTor ? "Tor connection failed" : "No connection"
        case .pin: "Server changed"
        case .send: viaTor ? "Dropped over Tor" : "Interrupted"
        case .status:
            switch code {
            case 401: "Invalid key"
            case 403: viaTor ? "Blocked over Tor" : "Invalid key"
            case 429: "Rate limited"
            default: "NEAR error"
            }
        case .reply: "Answer refused"
        case .helper: "Damaged"
        case .ended: "Stopped"
        case .key: "Key unreadable"
        }
    }

    func words(viaTor: Bool) -> String {
        switch kind {
        case .line: "Cloak's request wasn't formed right."
        case .request: "This message can't go as it is."
        case .fetch:
            viaTor
                ? "Tor couldn't reach NEAR or Intel's attestation servers (slow or blocked Tor exit). Try again for a fresh Tor circuit, or turn off Tor for NEAR in Settings."
                : "Cloak couldn't fetch NEAR's proof. Try again."
        case .refused: "NEAR's servers don't match what this version of Cloak accepts. Update Cloak."
        case .connect:
            viaTor
                ? "The proof passed, but the Tor circuit to NEAR failed. Try again for a fresh Tor exit."
                : "The proof passed, but Cloak couldn't connect to NEAR."
        case .pin: "NEAR answered from a server other than the one checked."
        case .send:
            viaTor
                ? "The Tor circuit dropped before NEAR's answer finished. Try again for a fresh Tor exit."
                : "The connection dropped before NEAR's answer came."
        case .status:
            switch code {
            case 401: "NEAR didn't accept your key. Replace it in Settings."
            case 403:
                viaTor
                    ? "NEAR or its firewall rejected this Tor exit (403). Try again for a fresh Tor exit, check your key in Settings, or turn off Tor for NEAR."
                    : "NEAR didn't accept your key. Replace it in Settings."
            case 429: "NEAR is limiting your account. Wait, then send again."
            default: "NEAR answered with error \(code ?? 0)."
            }
        case .reply: "NEAR's answer didn't open, so it isn't shown."
        case .helper: "Reinstall Cloak."
        case .ended: "The part of Cloak that talks to NEAR quit."
        case .key: "The keychain didn't give Cloak your NEAR key."
        }
    }
}

extension Step {
    /// What the agent did, in a word: its four own tools by what they do,
    /// any other by its name.
    var label: String {
        switch tool {
        case "bash": "Ran"
        case "read": "Read"
        case "edit": "Edited"
        case "write": "Wrote"
        default: tool.prefix(1).uppercased() + tool.dropFirst()
        }
    }
}

extension Agent.End {
    var title: String {
        switch self {
        case .stopped: "Stopped"
        case .cloakStopped: "Cloak stopped"
        case .unreachable: "No connection"
        case .failed: "Not finished"
        }
    }

    var words: String? {
        switch self {
        case .stopped: nil
        case .cloakStopped: "Cloak was paused or stopped, so the task ended."
        case .unreachable: "The agent couldn't reach Cloak."
        case .failed(let sentence): sentence ?? "The agent stopped before it finished."
        }
    }
}

extension AnswerStop {
    var title: String {
        switch self {
        case .stopped: "Stopped"
        case .interrupted: "Interrupted"
        case .tooLong: "Too long"
        case .thinkingLimit: "Thinking limit reached"
        case .failed: "No answer"
        }
    }

    var words: String? {
        switch self {
        case .stopped: nil
        case .interrupted: "Cloak started or stopped while the model was answering. Ask again."
        case .tooLong: "This chat is too long for the model on this Mac. Start a new chat."
        case .thinkingLimit: "The model spent its thinking budget before writing an answer. Try a simpler question or ask again."
        case .failed(let reason): "\(reason.title) Ask again."
        }
    }
}

extension Chat.Problem {
    var title: String {
        switch self {
        case .save: "Couldn't save this chat."
        case .delete: "Couldn't delete this chat."
        }
    }

    var detail: String {
        switch self {
        case .save: "Your latest change isn't on disk."
        case .delete: "It's still on this Mac."
        }
    }
}
