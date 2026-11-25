import AppKit
import Carbon.HIToolbox
import CloakChat
import CloakDoor
import CloakSupervisor
import OSLog
import SwiftUI

/// The Settings window, where every setting changes (`AppSettings`):
/// General (whether the app opens at login, whether Chat never rewords,
/// whether it shows each reworded message before sending it, whether it
/// saves chats, whether the guest sends cover traffic, how long the model
/// may go unused before it leaves memory, and whether the app checks for
/// updates by itself), NEAR (the NEAR key, Tor, how
/// long a passed check is used again, and the model), Local Llama (the
/// model that answers its chats, and each model's download; listed only
/// while there is a choice) and Advanced (the quick prompt's shortcut, the
/// port on 127.0.0.1 that the door answers on, how Cloak started its
/// parts, this session's log, and Restore Defaults).
struct SettingsView: View {
    /// The pane shown, kept with the window, so the app can show it on one.
    @MainActor
    @Observable
    final class Selection {
        var pane: Pane? = .general
    }

    let settings: AppSettings
    let prompt: QuickPrompt
    let supervisor: Supervisor
    let door: Door
    let updates: Updates
    let near: NearMode
    let wallet: Wallet
    let veniceMode: VeniceMode
    let payer: Payer
    /// The download of the model that rewords, for Connected Apps' Start row.
    let download: ModelDownload
    /// One for each model that answers Local Llama chats, smallest first.
    let downloads: [ModelDownload]
    /// Optional 44 MB uncensored LoRA adapter downloads, keyed by adapter name.
    let adapterDownloads: [String: ModelDownload]
    let openDoor: () -> Void
    let showChat: () -> Void
    let showFunds: () -> Void
    let showTour: () -> Void
    #if DARKBLOOM
    let darkbloom: DarkbloomMode
    #endif
    @Bindable var selection: Selection

    #if DARKBLOOM
    static func window(
        _ settings: AppSettings, prompt: QuickPrompt, supervisor: Supervisor, door: Door, updates: Updates, near: NearMode,
        wallet: Wallet, veniceMode: VeniceMode, payer: Payer,
        download: ModelDownload, downloads: [ModelDownload], adapterDownloads: [String: ModelDownload] = [:],
        darkbloom: DarkbloomMode,
        openDoor: @escaping () -> Void, showChat: @escaping () -> Void, showFunds: @escaping () -> Void, showTour: @escaping () -> Void,
        selection: Selection
    ) -> NSWindow {
        let window = ClosingWindow(
            contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Settings"
        let content = NSHostingController(
            rootView: SettingsView(
                settings: settings, prompt: prompt, supervisor: supervisor, door: door, updates: updates, near: near,
                wallet: wallet, veniceMode: veniceMode, payer: payer,
                download: download, downloads: downloads, adapterDownloads: adapterDownloads,
                openDoor: openDoor, showChat: showChat, showFunds: showFunds, showTour: showTour, darkbloom: darkbloom, selection: selection))
        content.sceneBridgingOptions = [.toolbars]
        window.contentViewController = content
        window.setContentSize(NSSize(width: 680, height: 520))
        window.setFrameAutosaveName("sh.regents.cloak.window.settings")
        // ClosingWindow hides instead of destroying the SwiftUI view hierarchy,
        // so explicitly close Darkbloom's stream/key on window close and refresh
        // when the window becomes key again while Inference Serving is active.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { darkbloom.close() }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated {
                if selection.pane == .serving { darkbloom.open() }
            }
        }
        return window
    }
    #else
    static func window(
        _ settings: AppSettings, prompt: QuickPrompt, supervisor: Supervisor, door: Door, updates: Updates, near: NearMode,
        wallet: Wallet, veniceMode: VeniceMode, payer: Payer,
        download: ModelDownload, downloads: [ModelDownload], adapterDownloads: [String: ModelDownload] = [:],
        openDoor: @escaping () -> Void, showChat: @escaping () -> Void, showFunds: @escaping () -> Void, showTour: @escaping () -> Void,
        selection: Selection
    ) -> NSWindow {
        let window = ClosingWindow(
            contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Settings"
        let content = NSHostingController(
            rootView: SettingsView(
                settings: settings, prompt: prompt, supervisor: supervisor, door: door, updates: updates, near: near,
                wallet: wallet, veniceMode: veniceMode, payer: payer,
                download: download, downloads: downloads, adapterDownloads: adapterDownloads,
                openDoor: openDoor, showChat: showChat, showFunds: showFunds, showTour: showTour, selection: selection))
        content.sceneBridgingOptions = [.toolbars]
        window.contentViewController = content
        window.setContentSize(NSSize(width: 680, height: 520))
        window.setFrameAutosaveName("sh.regents.cloak.window.settings")
        return window
    }
    #endif

    enum Pane: String, CaseIterable, Identifiable {
        case general, llama, localAccess, wallets, near, connectedApps
        #if DARKBLOOM
        case serving
        #endif
        case offlineData, status, advanced, feedback

        var id: Self { self }

        var title: String {
            switch self {
            case .general: "General"
            case .llama: "Local Models"
            case .localAccess: "Local Access"
            case .wallets: "Wallets"
            case .near: "NEAR AI Gateway"
            case .connectedApps: "Connected Apps"
            #if DARKBLOOM
            case .serving: "Inference Serving"
            #endif
            case .offlineData: "Offline Data"
            case .status: "Status"
            case .advanced: "Advanced"
            case .feedback: "Feedback"
            }
        }

        var pageTitle: String {
            title
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .llama: "laptopcomputer"
            case .localAccess: "person.crop.rectangle.stack"
            case .wallets: "wallet.bifold"
            case .near: "cpu"
            case .connectedApps: "cable.connector"
            #if DARKBLOOM
            case .serving: "server.rack"
            #endif
            case .offlineData: "externaldrive"
            case .status: "info.circle"
            case .advanced: "wrench.and.screwdriver"
            case .feedback: "bubble.left.and.bubble.right"
            }
        }
    }

    var body: some View {
        // The sidebar's list can be left with nothing chosen.
        let shown = selection.pane ?? .general
        NavigationSplitView {
            List(Pane.allCases, selection: $selection.pane) { row in
                Label(row.title, systemImage: row.symbol)
                    .sidebarHover(selected: row == selection.pane)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 185, max: 220)
            .toolbar(removing: .sidebarToggle)
            .toolbar {
                ToolbarItem {
                    Button {
                        showChat()
                    } label: {
                        Label("Back to Chat", systemImage: "square.and.pencil")
                    }
                    .help("Back to Chat")
                }
            }
        } detail: {
            Group {
                switch shown {
                case .general: GeneralPane(settings: settings, updates: updates)
                case .llama:
                    LlamaPane(
                        settings: settings, downloads: downloads, adapterDownloads: adapterDownloads,
                        rewording: supervisor.manifest.rewordingModel)
                case .localAccess:
                    LocalAccessPane(settings: settings)
                case .wallets:
                    WalletsPane(
                        wallet: wallet, veniceMode: veniceMode, payer: payer, settings: settings,
                        nearMode: near, supervisor: supervisor, download: download,
                        showStatus: { selection.pane = .status },
                        showNearSettings: { selection.pane = .near })
                case .near: NearPane(settings: settings, mode: near)
                case .connectedApps:
                    AgentsView(
                        door: door, supervisor: supervisor, download: download, openDoor: openDoor,
                        showDetails: { selection.pane = .status }, showDoorSettings: { selection.pane = .advanced }, showFunds: showFunds)
                #if DARKBLOOM
                case .serving:
                    DarkbloomView(mode: darkbloom, embedded: true)
                #endif
                case .offlineData:
                    OfflineDataPane(settings: settings, manager: OfflineDataManager.shared)
                case .status:
                    DetailsView(supervisor: supervisor, download: download, showTour: showTour)
                case .advanced:
                    AdvancedPane(settings: settings, prompt: prompt, supervisor: supervisor, door: door, updates: updates)
                case .feedback:
                    FeedbackPane()
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .contentMargins(.top, 8, for: .scrollContent)
            .navigationTitle(shown.pageTitle)
        }
        .frame(minWidth: 620, minHeight: 460)
    }
}

/// Unified Wallets settings pane displaying all four funding rails at once:
/// zkAPI Anon Inference (ETH Mainnet), Cloud Inference · Venice (Base USDC / API Key),
/// Cloud Inference · Boundless (Tempo USDC.e), and NEAR AI Gateway (API Key).
private struct WalletsPane: View {
    @Bindable var wallet: Wallet
    let veniceMode: VeniceMode
    let payer: Payer
    @Bindable var settings: AppSettings
    let nearMode: NearMode
    let supervisor: Supervisor
    let download: ModelDownload
    let showStatus: () -> Void
    let showNearSettings: () -> Void

    var body: some View {
        let running = supervisor.phase == .running
        ScrollViewReader { proxy in
            Form {
                if !running {
                    Section {
                        BetaWalletNotice(includeZkAPILimit: true)
                    }
                    Section {
                        StartRow(supervisor: supervisor, download: download, showDetails: showStatus)
                    }
                } else {
                    Section {
                        BetaWalletNotice(includeZkAPILimit: true)
                        HStack {
                            Text("All Cloak wallets stay on this Mac only (never synced to iCloud).")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                refreshAll()
                            } label: {
                                Label("Refresh All", systemImage: "arrow.clockwise")
                            }
                            .controlSize(.small)
                        }
                    }
                }

                // 1. zkAPI Mode (zkAPI Anon Inference)
                Section {
                    WalletGroupHeader(
                        symbol: "theatermasks",
                        title: "zkAPI Mode · zkAPI Anon Inference",
                        subtitle: "Ethereum Mainnet ETH wallet & zero-knowledge deposit for fresh one-time keys over Tor.")
                }
                VWallet(payer: payer, settings: settings, running: running)

                // 2. Cloud Inference — Venice (Base USDC / API Key)
                Section {
                    WalletGroupHeader(
                        symbol: "dollarsign.circle",
                        title: "Cloud Inference · Venice",
                        subtitle: "Dedicated Base USDC wallet (x402 credit top-ups) or your Venice Inference API key over Tor.")
                }
                VeniceFundsSections(venice: veniceMode, settings: settings, running: running)

                // 3. Cloud Inference — Boundless (Tempo USDC.e)
                Section {
                    WalletGroupHeader(
                        symbol: "dollarsign.circle",
                        title: "Cloud Inference · Boundless",
                        subtitle: "Dedicated Tempo USDC.e wallet and MPP payment channel over Tor.")
                }
                WalletSections(wallet: wallet, running: running)

                // 4. NEAR AI Gateway (API Key)
                Section {
                    WalletGroupHeader(
                        symbol: "cpu",
                        title: "NEAR AI Gateway",
                        subtitle: "Hardware-attested Intel TDX + NVIDIA GPU enclaves paid with your NEAR AI Cloud API key.")
                }
                NearPayment(mode: nearMode, tokens: nil, openSettings: showNearSettings)
            }
            .onChange(of: payer.review) { _, review in
                guard review != nil else { return }
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("v-review-actions", anchor: .bottom)
                    }
                }
            }
            .onChange(of: payer.stop) { _, stop in
                guard stop != nil else { return }
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("v-stop-banner", anchor: .center)
                    }
                }
            }
        }
        .task(id: running) {
            await wallet.ensureLoaded()
            guard running else { return }
            refreshAll()
        }
        .onReturn {
            Task { await wallet.ensureLoaded() }
            guard running else { return }
            refreshAll()
        }
    }

    private func refreshAll() {
        payer.follow()
        Task { await veniceMode.refresh() }
        Task { await wallet.ensureLoaded() }
    }
}

private struct WalletGroupHeader: View {
    let symbol: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 24)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

private struct GeneralPane: View {
    @Bindable var settings: AppSettings
    let updates: Updates
    @State private var login = LoginItem.stage

    var body: some View {
        Form {
            Section {
                Row("Launch at login", note: "Opens Cloak paused in the menu bar — nothing runs until you start.") {
                    VStack(alignment: .trailing, spacing: 4) {
                        Switch("Launch at login", isOn: Binding(get: { login.isOn }, set: { login = LoginItem.set($0) }))
                        if let words = login.words {
                            HStack(spacing: 2) {
                                Text(words)
                                    .font(.caption)
                                    .foregroundStyle(login == .needsApproval ? Color.secondary : Color.red)
                                SymbolButton("Open Login Items", symbol: "arrow.up.forward.app", action: LoginItem.openSettings)
                                    .overhanging()
                            }
                        }
                    }
                }
            }
            Section {
                Row(
                    "Prompt rewriting",
                    note: "Rewrites prompts locally to remove writing style and personal details. Always on for Connected Apps and Agent tasks."
                ) {
                    Picker("Prompt rewriting", selection: $settings.promptRewriting) {
                        ForEach(PromptRewriting.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                }
                Row("Save chat history", note: "Off: new chats stay in memory only and disappear when Cloak quits.") {
                    Switch("Save chat history", isOn: $settings.savedChats)
                }
            }
            UpdatesSection(updates: updates)
        }
        // The login item can change in System Settings while the window is
        // away, so it is read again each time the window comes back, and the
        // words of a refused change go.
        .onReturn { login = LoginItem.stage }
    }
}

/// Whether Sparkle checks for updates by itself: its own setting, which it
/// keeps, shown here and changed here.
private struct UpdatesSection: View {
    let updates: Updates
    @State private var checks: Bool

    init(updates: Updates) {
        self.updates = updates
        _checks = State(initialValue: updates.checksAutomatically)
    }

    var body: some View {
        Section {
            Row("Updates", note: "Checks the update server directly from this Mac — never shares chat data.") {
                Switch("Updates", isOn: Binding(get: { checks }, set: { updates.checksAutomatically = $0; checks = $0 }))
            }
        }
        // Sparkle's own question about checking can be answered while the
        // window is away, so the setting is read again when it comes back.
        .onReturn { checks = updates.checksAutomatically }
    }
}

/// Opt-in offline context & macOS Personal Data connectors strictly for Local Mode.
/// Nothing configured here is ever sent to NEAR, Venice, Boundless, or Anon V.
private struct LocalAccessPane: View {
    @Bindable var settings: AppSettings
    private let memoryStore = LocalMemoryStore()

    @State private var userMemory = ""
    @State private var notesMemory = ""
    @State private var memoryDirty = false
    @State private var memoryStatus: String?
    @State private var calendarStatus = PersonalDataConnectors.calendarStatus()
    @State private var remindersStatus = PersonalDataConnectors.remindersStatus()
    @State private var contactsStatus = PersonalDataConnectors.contactsStatus()

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.title3)
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Local Mode only — never leaves this Mac")
                            .font(.subheadline.weight(.semibold))
                        Text("Everything enabled below is strictly offline and only included when chatting with a local model. Cloud modes (NEAR, Token Inference, zkAPI Anon Inference) never read this data.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 2)
            }

            Section("Offline Context") {
                Row(
                    "Share basic Mac info",
                    note: "Shares local date, time, timezone, Mac model, chip, RAM, macOS version, and available disk space with Local Mode. Never includes serial numbers, usernames, or network addresses."
                ) {
                    Switch("Share basic Mac info", isOn: $settings.localShareMacInfo)
                }

                Row(
                    "Local memory (USER.md & MEMORY.md)",
                    note: "Hermes-compatible local memory stored owner-only on this Mac and excluded from Spotlight and Time Machine. Included only in Local Mode."
                ) {
                    Switch("Local memory", isOn: $settings.localUseMemory)
                }

                if settings.localUseMemory {
                    Row(
                        "Sync with ~/.hermes/memories",
                        note: "Optionally mirrors USER.md and MEMORY.md with ~/.hermes/memories so Hermes Agent and Cloak Local Mode share the same bounded memory."
                    ) {
                        Switch("Sync with ~/.hermes/memories", isOn: $settings.localSyncHermesMemory)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("USER.md (about you & preferences)")
                                    .font(.caption.weight(.semibold))
                                Spacer()
                                Text("\(userMemory.count) / \(LocalMemoryStore.userLimit)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(userMemory.count >= LocalMemoryStore.userLimit ? .orange : .secondary)
                            }
                            TextEditor(text: Binding(
                                get: { userMemory },
                                set: {
                                    userMemory = LocalMemoryStore.clamped($0, limit: LocalMemoryStore.userLimit)
                                    memoryDirty = true
                                    memoryStatus = nil
                                }))
                                .font(.system(.caption, design: .monospaced))
                                .frame(minHeight: 74, maxHeight: 110)
                                .padding(4)
                                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("MEMORY.md (notes, projects & context)")
                                    .font(.caption.weight(.semibold))
                                Spacer()
                                Text("\(notesMemory.count) / \(LocalMemoryStore.memoryLimit)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(notesMemory.count >= LocalMemoryStore.memoryLimit ? .orange : .secondary)
                            }
                            TextEditor(text: Binding(
                                get: { notesMemory },
                                set: {
                                    notesMemory = LocalMemoryStore.clamped($0, limit: LocalMemoryStore.memoryLimit)
                                    memoryDirty = true
                                    memoryStatus = nil
                                }))
                                .font(.system(.caption, design: .monospaced))
                                .frame(minHeight: 90, maxHeight: 140)
                                .padding(4)
                                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                        }

                        HStack(spacing: 8) {
                            Button("Save Memory") { saveMemory() }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .disabled(!memoryDirty)
                            if memoryStore.hasHermesMemories {
                                Button("Import from ~/.hermes") { importHermes() }
                                    .controlSize(.small)
                            }
                            Button("Open Folder") { openMemoryFolder() }
                                .controlSize(.small)
                            Spacer()
                            if let memoryStatus {
                                Text(memoryStatus)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section {
                if settings.localApprovedFolders.isEmpty {
                    Text("No folders approved yet. Local Mode can search read-only Markdown, text, and code excerpts inside folders you explicitly approve.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(settings.localApprovedFolders, id: \.self) { path in
                        HStack(spacing: 8) {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                            Text(abbreviateHome(path))
                                .font(.callout)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button("Remove", role: .destructive) {
                                settings.localApprovedFolders.removeAll { $0 == path }
                            }
                            .controlSize(.small)
                        }
                    }
                }
                HStack {
                    Button("Add Folder…", action: addApprovedFolder)
                    Spacer()
                    Text("Always skips dotfiles, .env, and private keys.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Approved Local Folders")
            }

            Section {
                connectorRow(
                    title: "Calendar (next 7 days)",
                    note: "Read-only access to upcoming macOS Calendar events for Local Mode. macOS asks for permission only when you switch this on.",
                    status: calendarStatus,
                    privacyPane: "Privacy_Calendars",
                    isOn: Binding(
                        get: { settings.localUseCalendar },
                        set: { enable in
                            if !enable {
                                settings.localUseCalendar = false
                                return
                            }
                            Task {
                                let granted = await PersonalDataConnectors.requestCalendarAccess()
                                calendarStatus = PersonalDataConnectors.calendarStatus()
                                settings.localUseCalendar = granted
                            }
                        }))

                connectorRow(
                    title: "Reminders (open items)",
                    note: "Read-only access to incomplete macOS Reminders for Local Mode. macOS asks for permission only when you switch this on.",
                    status: remindersStatus,
                    privacyPane: "Privacy_Reminders",
                    isOn: Binding(
                        get: { settings.localUseReminders },
                        set: { enable in
                            if !enable {
                                settings.localUseReminders = false
                                return
                            }
                            Task {
                                let granted = await PersonalDataConnectors.requestRemindersAccess()
                                remindersStatus = PersonalDataConnectors.remindersStatus()
                                settings.localUseReminders = granted
                            }
                        }))

                connectorRow(
                    title: "Contacts (mentioned names only)",
                    note: "Read-only lookup of macOS Contacts only when a name appears in your Local Mode prompt — never loads your full address book.",
                    status: contactsStatus,
                    privacyPane: "Privacy_Contacts",
                    isOn: Binding(
                        get: { settings.localUseContacts },
                        set: { enable in
                            if !enable {
                                settings.localUseContacts = false
                                return
                            }
                            Task {
                                let granted = await PersonalDataConnectors.requestContactsAccess()
                                contactsStatus = PersonalDataConnectors.contactsStatus()
                                settings.localUseContacts = granted
                            }
                        }))
            } header: {
                Text("macOS Personal Data (Opt-in)")
            } footer: {
                Text("You can also attach PDF, document, image (OCR), Markdown, text, or code files per message directly from Local Mode's composer bar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            loadMemory()
            refreshStatuses()
        }
        .onReturn {
            refreshStatuses()
        }
    }

    @ViewBuilder
    private func connectorRow(
        title: String,
        note: String,
        status: PersonalDataConnectors.AccessStatus,
        privacyPane: String,
        isOn: Binding<Bool>
    ) -> some View {
        Row(title, note: note) {
            VStack(alignment: .trailing, spacing: 4) {
                Switch(title, isOn: isOn)
                if status == .denied || status == .restricted {
                    HStack(spacing: 4) {
                        Text(status.label)
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Button("Open Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(privacyPane)") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .controlSize(.mini)
                    }
                }
            }
        }
    }

    private func loadMemory() {
        let loaded = memoryStore.load(syncHermes: settings.localSyncHermesMemory)
        userMemory = loaded.user
        notesMemory = loaded.memory
        memoryDirty = false
    }

    private func saveMemory() {
        do {
            try memoryStore.save(
                LocalMemoryStore.Contents(user: userMemory, memory: notesMemory),
                syncHermes: settings.localSyncHermesMemory)
            memoryDirty = false
            memoryStatus = settings.localSyncHermesMemory ? "Saved & synced" : "Saved"
        } catch {
            memoryStatus = "Couldn't save"
        }
    }

    private func importHermes() {
        do {
            if let imported = try memoryStore.importFromHermes() {
                userMemory = imported.user
                notesMemory = imported.memory
                memoryDirty = false
                memoryStatus = "Imported from ~/.hermes"
            } else {
                memoryStatus = "No Hermes files found"
            }
        } catch {
            memoryStatus = "Import failed"
        }
    }

    private func openMemoryFolder() {
        try? FileManager.default.createDirectory(at: memoryStore.folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(memoryStore.folder)
    }

    private func addApprovedFolder() {
        let panel = NSOpenPanel()
        panel.title = "Approve Local Folder"
        panel.message = "Cloak Local Mode can search read-only text, Markdown, and code files inside this folder. Never sent off this Mac."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            var updated = settings.localApprovedFolders
            for url in panel.urls {
                let path = url.standardizedFileURL.path
                if !updated.contains(path) {
                    updated.append(path)
                }
            }
            settings.localApprovedFolders = updated
        }
    }

    private func refreshStatuses() {
        calendarStatus = PersonalDataConnectors.calendarStatus()
        remindersStatus = PersonalDataConnectors.remindersStatus()
        contactsStatus = PersonalDataConnectors.contactsStatus()
        if calendarStatus != .authorized && settings.localUseCalendar { settings.localUseCalendar = false }
        if remindersStatus != .authorized && settings.localUseReminders { settings.localUseReminders = false }
        if contactsStatus != .authorized && settings.localUseContacts { settings.localUseContacts = false }
    }

    private func abbreviateHome(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

/// Dedicated Feedback pane listing every official channel for bug reports,
/// feature requests, and questions.
private struct FeedbackPane: View {
    /// The release, which `build.sh` writes into the app.
    private static let release = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.2.0"
    private static let email = "build@regents.sh"
    private static let emailURL = URL(string: "mailto:build@regents.sh?subject=Cloak%20\(release)%20Feedback")!
    private static let patchbayURL = URL(string: "https://regents.sh/patchbay/cloak")!
    private static let xURL = URL(string: "https://x.com/regents_sh")!
    private static let githubURL = URL(string: "https://github.com/regents-ai/cloak")!

    private static let agentPrompt = """
        Post my feedback about the Regents Cloak Mac app, version \(release), on Patchbay at https://regents.sh/patchbay/cloak. \
        Ask me what I was doing, what happened and what I expected, and post exactly that. \
        Leave out keys, passwords, wallet addresses and what my chats said.
        """

    var body: some View {
        Form {
            Section {
                Text("Have a bug report, question, or feature idea for Cloak \(Self.release)? Reach us through any of the options below:")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Support & Feedback") {
                LabeledContent {
                    HStack(spacing: 6) {
                        CopyButton("Copy Agent Prompt", side: 26, text: Self.agentPrompt)
                        Button("Open Patchbay…") { NSWorkspace.shared.open(Self.patchbayURL) }
                            .buttonStyle(.borderedProminent)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Patchbay (Primary)")
                        Text("regents.sh/patchbay/cloak")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent {
                    HStack(spacing: 6) {
                        CopyButton("Copy Email", side: 26, text: Self.email)
                        Button("Email…") { NSWorkspace.shared.open(Self.emailURL) }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Email")
                        Text(Self.email)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent {
                    Button("Open…") { NSWorkspace.shared.open(Self.xURL) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("X")
                        Text("x.com/regents_sh")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent {
                    Button("Open…") { NSWorkspace.shared.open(Self.githubURL) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("GitHub")
                        Text("github.com/regents-ai/cloak")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Text("Posts on Patchbay, X, and GitHub are public. Please leave out API keys, recovery phrases, wallet addresses, and private chat transcripts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Curated open-source & public-domain offline datasets on this Mac or an
/// external drive, with progressive Minimum → Maximum sliders that remember
/// each downloaded level so users can start small and download more later.
private struct OfflineDataPane: View {
    @Bindable var settings: AppSettings
    @Bindable var manager: OfflineDataManager

    private static let pmcRegistryURL = URL(string: "https://registry.opendata.aws/ncbi-pmc/")!
    private static let pmcSyncCommand = "aws s3 ls s3://pmc-oa-opendata/ --no-sign-request"

    var body: some View {
        Form {
            ForEach(OfflineDataset.all) { dataset in
                OfflineDatasetSection(dataset: dataset, settings: settings, manager: manager)
            }

            Section {
                LabeledContent {
                    HStack(spacing: 6) {
                        CopyButton("Copy AWS CLI Command", side: 26, text: Self.pmcSyncCommand)
                        Button {
                            NSWorkspace.shared.open(Self.pmcRegistryURL)
                        } label: {
                            Label("Open", systemImage: "arrow.up.right.square")
                        }
                        .controlSize(.small)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("PubMed Central Open Access")
                        Text("Millions of peer-reviewed full-text biomedical & clinical articles in plain text and XML via anonymous AWS S3 download (~8M articles, selective per-PMCID sync).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("Downloads connect directly to each dataset's public host — never through Tor and never tied to an account. Stored locally in Application Support and excluded from Time Machine.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { manager.refreshFromDisk() }
        .onReturn { manager.refreshFromDisk() }
    }
}

private struct OfflineDatasetSection: View {
    let dataset: OfflineDataset
    @Bindable var settings: AppSettings
    @Bindable var manager: OfflineDataManager
    @State private var confirmingRemove = false

    private var selected: Int {
        manager.selectedLevel[dataset.id] ?? dataset.minLevel
    }

    private var downloaded: Int {
        manager.downloadedLevel[dataset.id] ?? 0
    }

    private var hasAnyDownloaded: Bool {
        downloaded > 0 || !(manager.installedFiles[dataset.id]?.isEmpty ?? true)
    }

    private var active: OfflineDataManager.ProgressState? {
        manager.activeDownloads[dataset.id]
    }

    private var missingCount: Int {
        manager.missingFiles(for: dataset, upTo: selected).count
    }

    private var missingBytes: Int64 {
        manager.missingBytes(for: dataset, upTo: selected)
    }

    private var totalAtSelected: Int64 {
        dataset.totalBytes(upTo: selected)
    }

    private var folderPath: String {
        manager.folder(for: dataset.id).standardizedFileURL.path
    }

    private var isApprovedForLocalMode: Bool {
        settings.localApprovedFolders.contains(folderPath)
    }

    var body: some View {
        let tier = dataset.tier(for: selected)
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(dataset.name)
                                .font(.body.weight(.medium))
                            if downloaded > 0 {
                                let dlTier = dataset.tier(for: downloaded)
                                Text("Saved · \(dlTier.label) (\(OfflineDataset.formatBytes(dataset.totalBytes(upTo: downloaded))))")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.green)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.green.opacity(0.14), in: Capsule())
                            }
                        }
                        Text(dataset.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button {
                        NSWorkspace.shared.open(dataset.websiteURL)
                    } label: {
                        Label(dataset.sourceLabel, systemImage: "arrow.up.right.square")
                    }
                    .controlSize(.small)
                }

                // Minimum -> Maximum progressive scale slider (shown for multi-tier datasets)
                if dataset.hasScaleSlider {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Scale: \(tier.label)")
                                .font(.caption.weight(.semibold))
                            Spacer()
                            Text("Total \(OfflineDataset.formatBytes(totalAtSelected))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Slider(
                            value: Binding(
                                get: { Double(selected) },
                                set: { manager.setSelectedLevel(Int($0.rounded()), for: dataset) }),
                            in: Double(dataset.minLevel)...Double(dataset.maxLevel),
                            step: 1
                        )
                        .disabled(active != nil)
                        HStack {
                            Text("Min (\(OfflineDataset.formatBytes(dataset.totalBytes(upTo: dataset.minLevel))))")
                            Spacer()
                            Text(tier.summary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer()
                            Text("Max (\(OfflineDataset.formatBytes(dataset.totalBytes(upTo: dataset.maxLevel))))")
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }

                if let active {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: active.fraction)
                        HStack {
                            Text("Downloading \(active.currentFileName) (\(active.completedFiles + 1)/\(active.totalFiles))…")
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text("\(OfflineDataset.formatBytes(active.completedBytes)) / \(OfflineDataset.formatBytes(active.totalBytes))")
                                .monospacedDigit()
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                if let error = manager.errors[dataset.id] {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                HStack(spacing: 8) {
                    if active != nil {
                        Button("Cancel") { manager.cancel(dataset.id) }
                            .controlSize(.small)
                    } else if missingCount > 0 {
                        let sizeText = OfflineDataset.formatBytes(missingBytes)
                        let label = downloaded > 0 ? "Download More (+\(sizeText))" : "Download (\(sizeText))"
                        Button {
                            manager.download(dataset, upTo: selected)
                        } label: {
                            Label(label, systemImage: "arrow.down.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    } else if downloaded > 0 {
                        Label(
                            dataset.hasScaleSlider && selected < downloaded
                                ? "Included in \(dataset.tier(for: downloaded).label)"
                                : "Downloaded",
                            systemImage: "checkmark.circle.fill"
                        )
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.green)
                    }

                    if hasAnyDownloaded {
                        Button("Open Folder") { manager.revealFolder(for: dataset.id) }
                            .controlSize(.small)
                        if dataset.searchableInLocalMode {
                            Button(isApprovedForLocalMode ? "Linked to Local Mode" : "Use in Local Mode") {
                                if isApprovedForLocalMode {
                                    settings.localApprovedFolders.removeAll { $0 == folderPath }
                                } else {
                                    var updated = settings.localApprovedFolders
                                    updated.append(folderPath)
                                    settings.localApprovedFolders = updated
                                }
                            }
                            .controlSize(.small)
                        }
                        Spacer(minLength: 0)
                        Button(role: .destructive) {
                            confirmingRemove = true
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .accessibilityLabel("Delete \(dataset.name)")
                        .tip("Delete downloaded \(dataset.name) files from this Mac.")
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .confirmationDialog("Delete \(dataset.name) files?", isPresented: $confirmingRemove) {
            Button("Delete Files", role: .destructive) {
                settings.localApprovedFolders.removeAll { $0 == folderPath }
                manager.remove(dataset)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes downloaded \(dataset.name) files from this Mac. You can download them again anytime.")
        }
    }
}

/// NEAR mode's key, kept in the keychain and never shown again, removed
/// only once asked; whether it goes through Tor; how long a passed check is
/// used again; and its one model.
private struct NearPane: View {
    @Bindable var settings: AppSettings
    let mode: NearMode
    @State private var confirmingDisableTraces = false

    var body: some View {
        let traces = mode.traces
        Form {
            Section {
                Row("Key", note: "Your API key from cloud.near.ai, kept in macOS Keychain. NEAR ties requests to your account.") {
                    KeyRow(mode: mode)
                }
            } footer: {
                if mode.hasKey != true {
                    Text("Get a free or paid API key at [cloud.near.ai](https://cloud.near.ai).")
                }
            }
            Section {
                Row("Route through Tor", note: "Hides your IP from NEAR and Intel via Tor (~30s hardware check).") {
                    Switch("Route through Tor", isOn: $settings.nearTor)
                }
            }
            Section {
                Row("Share traces", note: "Export selected NEAR AI Gateway chats to Cloak's local Traces folder for handoff to NEAR AI Gateway.") {
                    Switch(
                        "Share traces",
                        isOn: Binding(
                            get: { settings.nearShareTraces },
                            set: { on in
                                if on {
                                    traces.setEnabled(true)
                                } else if traces.exportedCount > 0 {
                                    confirmingDisableTraces = true
                                } else {
                                    traces.setEnabled(false)
                                }
                            }
                        )
                    )
                }
                if settings.nearShareTraces {
                    LabeledContent("Traces folder") {
                        HStack(spacing: 4) {
                            Text(traces.exportedCount == 0 ? "Empty" : "\(traces.exportedCount) exported")
                                .foregroundStyle(.secondary)
                            SymbolButton("Copy Path", symbol: "doc.on.doc") { traces.copyFolderPath() }
                                .overhanging()
                            SymbolButton("Show in Finder", symbol: "folder") { traces.revealInFinder() }
                                .overhanging()
                        }
                    }
                }
            } footer: {
                Text("Cloak keeps chats end-to-end encrypted and uploads nothing itself. Add the folder as Exported traces in [NEAR AI Gateway](https://gateway.near.ai) ([Trace Commons](https://github.com/TraceCommons/trace-commons)).")
            }
            Section {
                Row("Model", note: "Hardware attestation verifies the enclave server, not the model weights.") {
                    Text(Near.displayModel)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Powered by [NEAR AI Cloud](https://cloud.near.ai) · [NEAR AI Gateway](https://gateway.near.ai) · [Trace Commons](https://github.com/TraceCommons/trace-commons) · [Dstack TEE](https://github.com/Dstack-TEE/dstack).")
            }
        }
        .onAppear { traces.refresh() }
        .alert("Remove \(traces.exportedCount) exported \(traces.exportedCount == 1 ? "trace" : "traces")?", isPresented: $confirmingDisableTraces) {
            Button("Remove Traces", role: .destructive) { traces.setEnabled(false, deleteFiles: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The copies in Cloak's Traces folder are deleted. Traces NEAR AI Gateway already submitted stay with Trace Commons until you withdraw them there.")
        }
    }
}

/// The NEAR key's control: Saved, with Replace and Remove, which asks
/// first, while a key is kept; the field and Save while none is, or over
/// the one kept after Replace, with Cancel back to Saved. Each press's stop
/// shows here, with its way on: a read's has Try Again; a save's keeps what
/// was typed, so Save tries again; a remove's keeps the key shown as saved,
/// so Remove tries again.
private struct KeyRow: View {
    let mode: NearMode
    @State private var stage = Stage.reading
    @State private var key = ""
    @State private var confirmingRemove = false

    /// The row's own stage. Whether a key is kept is the keychain's last
    /// answer (`NearMode.hasKey`), which any read, the Wallet's included,
    /// keeps; each read's stop stays with whoever asked.
    enum Stage: Equatable {
        /// Asking whether a key is kept, as the row appears and at Try Again.
        case reading
        /// The keychain didn't say.
        case unread
        /// As the keychain answered: Saved, or the field to add a key.
        case shown
        /// The field over the key kept, after Replace.
        case replacing
        case saving
        /// The keychain didn't keep what was typed, which stays in the field.
        case notSaved
        case removing
        /// The keychain didn't remove the key, which is still kept.
        case notRemoved
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            switch stage {
            case .reading:
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Checking")
            case .unread:
                HStack(spacing: 2) {
                    Text("Couldn't check")
                        .foregroundStyle(.secondary)
                    SymbolButton("Try Again", symbol: "arrow.clockwise") { Task { await read() } }
                        .overhanging()
                }
            case .shown where mode.hasKey == true, .removing, .notRemoved:
                saved
            case .shown, .replacing, .saving, .notSaved:
                field
            }
            if let stop {
                Text(stop)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .task { await read() }
        // The words about a save go once what was typed changes.
        .onChange(of: key) {
            if stage == .notSaved { stage = mode.hasKey == true ? .replacing : .shown }
        }
        .alert("Remove key?", isPresented: $confirmingRemove) {
            Button("Remove", role: .destructive, action: remove)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("NEAR AI Gateway chats can't send until you save a key again.")
        }
    }

    private var saved: some View {
        HStack(spacing: 2) {
            Text("Saved")
                .foregroundStyle(.secondary)
            if stage == .removing {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Removing")
            } else {
                SymbolButton("Replace", symbol: "pencil") { stage = .replacing }
                    .overhanging()
                SymbolButton("Remove", symbol: "trash") { confirmingRemove = true }
                    .overhanging()
            }
        }
    }

    private var field: some View {
        HStack(spacing: 6) {
            SecureField("NEAR key", text: $key, prompt: Text("NEAR key"))
                .labelsHidden()
                .accessibilityLabel("NEAR API key")
                .frame(width: 220)
                .onSubmit(save)
                .disabled(stage == .saving)
            if stage == .saving {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Saving")
            } else {
                if mode.hasKey == true {
                    Button("Cancel") {
                        key = ""
                        stage = .shown
                    }
                }
                Button("Save", action: save)
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var stop: String? {
        switch stage {
        case .notSaved: "Couldn't save the key."
        case .notRemoved: "Couldn't remove the key."
        case .reading, .unread, .shown, .replacing, .saving, .removing: nil
        }
    }

    private func read() async {
        stage = .reading
        do {
            try await mode.find()
            stage = .shown
        } catch {
            stage = .unread
        }
    }

    /// Keeps the key typed; the field empties once it is kept.
    private func save() {
        let typed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return }
        stage = .saving
        Task {
            do {
                try await mode.save(typed)
                key = ""
                stage = .shown
            } catch {
                stage = .notSaved
            }
        }
    }

    private func remove() {
        stage = .removing
        Task {
            do {
                try await mode.remove()
                stage = .shown
            } catch {
                stage = .notRemoved
            }
        }
    }
}

/// The model that answers Local Llama chats (`AppSettings.answerModel`,
/// decision 21 in docs/plan.md), one row for each model that can, smallest
/// first, each with its own download. Rewording always uses the model that
/// rewords, whichever is chosen. A model this Mac can't run is dimmed and
/// can be neither chosen nor downloaded; any model but the one that rewords
/// can be removed, once asked.
private struct LlamaPane: View {
    @Bindable var settings: AppSettings
    let downloads: [ModelDownload]
    let adapterDownloads: [String: ModelDownload]
    let rewording: Manifest.Model

    /// Whether the pane is in the sidebar: while a model other than the one
    /// that rewords fits this Mac, or one is chosen.
    static func isListed(_ settings: AppSettings, downloads: [ModelDownload]) -> Bool {
        settings.answerModel != nil || downloads.contains { !$0.rewords && $0.fits }
    }

    var body: some View {
        let chatDownloads = downloads.filter { !$0.rewords }
        let rewriterDownload = downloads.first(where: \.rewords)
        let bestDownload = chatDownloads.last(where: { $0.fits && $0.model.engine == .vmlx }) ?? chatDownloads.last(where: \.fits)
        let chosen = settings.answerModel.flatMap { id in chatDownloads.contains { $0.model.name == id } ? id : nil } ?? bestDownload?.model.name
        let chosenDownload = chatDownloads.first { $0.model.name == chosen } ?? bestDownload
        let best = bestDownload?.model.name
        let hosts = downloads.flatMap(\.hosts).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let bullets = [
            "Downloads fetch verified weights straight from \(hosts.joined(separator: " and ")), which sees this Mac's IP address.",
            "MLX models run ~60 tok/s on 16 GB+ Apple Silicon Macs; GGUF models support the optional Unfiltered LoRA.",
            "Prompt rewriting always uses \(rewording.label) separately from your Local chat model.",
        ]
        Form {
            Section {
                ForEach(chatDownloads, id: \.model.name) { download in
                    ModelRow(download: download, chosen: download.model.name == chosen, best: download.model.name == best, selectable: true) {
                        settings.answerModel = download.model.name
                    }
                }
            } header: {
                HStack(spacing: 2) {
                    Text("Model")
                    InfoButton("About Model", hint: bullets.joined(separator: " ")) {
                        BulletNote("Local Models", bullets: bullets)
                    }
                }
            } footer: {
                Text("Engines: [vmlx-swift](https://github.com/osaurus-ai/vmlx-swift) (MLX) · [llama.cpp](https://github.com/ggml-org/llama.cpp) (GGUF & prompt rewriter).")
            }
            if let adapter = chosenDownload?.model.unfilteredLora, let adapterDownload = adapterDownloads[adapter.name] {
                UnfilteredAdapterSection(settings: settings, adapter: adapter, download: adapterDownload)
            }
            if let rewriterDownload {
                Section {
                    ModelRow(download: rewriterDownload, chosen: false, best: false, selectable: false) {}
                } header: {
                    Text("Prompt Rewriter")
                } footer: {
                    Text("Used automatically to rewrite prompts locally before sending over Tor (Token Inference, zkAPI Anon Inference, Connected Apps, and Agent tasks). Not selectable for Local chat.")
                }
            }
        }
        // The files and the free space are read again, so the words about
        // space and Download's state follow them: as the pane shows, as its
        // window comes back, and as any model's download changes stage,
        // since a download that ends, stops or is removed changes the space
        // the others have. Download reads them again at its press.
        .onAppear(perform: refresh)
        .onReturn(perform: refresh)
        .onChange(of: downloads.map(\.state), refresh)
    }

    private func refresh() {
        downloads.forEach { $0.refresh() }
        adapterDownloads.values.forEach { $0.refresh() }
    }
}

/// Optional 44 MB AtomicChat uncensored LoRA adapter toggle for Inkling 2 Mini.
/// Toggling it on automatically starts downloading the pinned 44 MB GGUF LoRA
/// if not already installed; toggling it off immediately restores the standard
/// model without re-downloading weights.
private struct UnfilteredAdapterSection: View {
    @Bindable var settings: AppSettings
    let adapter: Manifest.Model.Adapter
    let download: ModelDownload

    var body: some View {
        let size = DownloadSection.text(download.total)
        let repoURL = adapter.repositoryURL ?? URL(string: "https://huggingface.co/AtomicChat/Inkling-2-Mini-Uncensored-GGUF")!
        Section {
            Toggle(
                "Unfiltered (Uncensored)",
                isOn: Binding(
                    get: { settings.unfilteredLocal },
                    set: { enabled in
                        settings.unfilteredLocal = enabled
                        if enabled, download.state != .installed, !download.isUnderWay {
                            download.start()
                        }
                    })
            )
            if settings.unfilteredLocal && download.state != .installed {
                HStack(spacing: 8) {
                    if download.isUnderWay {
                        ProgressView(value: Double(download.done), total: Double(max(download.total, 1)))
                            .controlSize(.small)
                        Text("\(DownloadSection.status(download.state)) \(DownloadSection.text(download.done)) of \(size)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Spacer()
                        Button("Pause") { download.pause() }
                            .controlSize(.small)
                    } else {
                        Text(DownloadSection.note(download) ?? "Adapter download required (\(size)).")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(download.done > 0 ? "Continue" : "Download") { download.start() }
                            .controlSize(.small)
                            .disabled(download.blocked != nil)
                    }
                }
            }
        } header: {
            Text("Behavior")
        } footer: {
            Text(
                "Optional \(size) uncensored LoRA from [HuggingFace](\(repoURL.absoluteString)). Removes refusals (~1.5% lower benchmark accuracy)."
            )
        }
    }
}

/// One model in Local Llama: its radio mark, which chooses it, its name,
/// "Best for this Mac" under the name of the last one that fits, why its
/// download stopped, its download size, and its download's symbols:
/// Download or Continue; while under way, what it waits for when it isn't
/// fetching (the network, or its next try), its progress and Pause; and
/// Remove.
private struct ModelRow: View {
    let download: ModelDownload
    let chosen: Bool
    let best: Bool
    var selectable = true
    let choose: () -> Void
    @State private var removing = false

    var body: some View {
        let label = download.model.label
        let size = DownloadSection.text(download.total)
        let unfit = "Needs more memory than this Mac has."
        LabeledContent {
            HStack(spacing: 2) {
                Text(size)
                    .monospacedDigit()
                    .foregroundStyle(download.fits ? .secondary : .tertiary)
                    .padding(.trailing, 4)
                if let repoURL = download.model.repositoryURL {
                    SymbolButton("Open on HuggingFace", symbol: "arrow.up.right.square") {
                        NSWorkspace.shared.open(repoURL)
                    }
                    .overhanging()
                }
                if download.isUnderWay {
                    let status = DownloadSection.status(download.state)
                    let progress = "\(status), \(DownloadSection.text(download.done)) of \(size)"
                    if let waiting {
                        Image(systemName: waiting)
                            .foregroundStyle(.secondary)
                            .tip(status)
                            .accessibilityHidden(true)
                    }
                    ProgressView(value: Double(download.done), total: Double(max(download.total, 1)))
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .frame(width: 28, height: 28)
                        .overhanging()
                        .tip(progress)
                        .accessibilityLabel("Download")
                        .accessibilityValue(progress)
                    SymbolButton("Pause", symbol: "pause.circle") { download.pause() }
                        .overhanging()
                } else if download.state == .installed {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .tip("Installed")
                        .accessibilityLabel("Installed")
                        .padding(.horizontal, 4)
                } else {
                    SymbolButton(download.done > 0 ? "Continue" : "Download", symbol: "arrow.down.circle") { download.start() }
                        .disabled(download.blocked != nil)
                        .overhanging()
                }
                if !download.rewords, download.isUnderWay || download.done > 0 {
                    SymbolButton("Remove", symbol: "trash") { removing = true }
                        .overhanging()
                }
            }
        } label: {
            if selectable {
                Button(action: choose) {
                    HStack(spacing: 8) {
                        Image(systemName: chosen ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(chosen ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                            .accessibilityHidden(true)
                        rowText(label)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(!download.fits)
                .accessibilityAddTraits(chosen ? .isSelected : [])
                .accessibilityHint(download.fits ? "" : unfit)
            } else {
                rowText(label)
            }
        }
        .tip(download.fits ? "" : unfit)
        .alert("Remove \(label)?", isPresented: $removing) {
            Button("Remove", role: .destructive) { download.remove() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its files are deleted from this Mac. You can download it again.")
        }
    }

    private func rowText(_ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var subtitle: String? {
        if !selectable && download.rewords {
            return "Local prompt rewriter · GGUF"
        }
        var parts: [String] = []
        if download.model.engine == .vmlx { parts.append("MLX · ~60 tok/s") }
        if best { parts.append("Best for this Mac") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The symbol for a download under way that isn't fetching: one waiting
    /// for the network, or one waiting for its next try after a failed one.
    private var waiting: String? {
        switch download.state {
        case .waitingForNetwork: "wifi.slash"
        case .retrying: "exclamationmark.arrow.circlepath"
        case .downloading, .installed, .stopped: nil
        }
    }

    /// Why the download stopped, or why it can't start for want of space.
    private var problem: String? {
        guard !download.isUnderWay else { return nil }
        if let block = download.blocked, case .disk = block { return DownloadSection.text(block) }
        return DownloadSection.note(download)
    }
}

/// The shortcut, or Record Shortcut. Pressed, it records: it takes the
/// keyboard, and the next keys typed into it are the shortcut. Escape, a
/// second press or the keyboard going elsewhere stops it with nothing
/// changed. Keys without Command, Option or Control are refused, with the
/// words why, and so is a shortcut macOS won't take, with words that say
/// what is still the shortcut (`QuickPrompt.refusal`).
private struct ShortcutRecorder: View {
    let shortcut: Shortcut?
    let refusal: String?
    let choose: (Shortcut?) -> Void
    @State private var stage = Stage.idle

    enum Stage: Equatable {
        case idle
        /// Taking the keys typed into the recorder; `refused` once one came
        /// without Command, Option or Control.
        case recording(refused: Bool)
    }

    var body: some View {
        let recording = stage != .idle
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                RecorderButton.Field(
                    title: recording ? "Press Keys…" : shortcut?.title ?? "Record Shortcut",
                    hint: recording ? "Stops recording" : "Records a new shortcut",
                    recording: recording,
                    press: { stage = recording ? .idle : .recording(refused: false) },
                    end: { stage = .idle },
                    take: take
                )
                .fixedSize()
                if shortcut != nil, !recording {
                    Button("Clear Shortcut", systemImage: "xmark.circle.fill") { choose(nil) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .hover(Circle(), outset: 4)
                        .tip("Clear Shortcut")
                }
            }
            if let words = stage == .recording(refused: true) ? "Hold ⌘, ⌥ or ⌃ with the key." : refusal {
                Text(words)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .onDisappear { stage = .idle }
    }

    private func take(_ event: NSEvent) {
        if let shortcut = Shortcut(event) {
            stage = .idle
            choose(shortcut)
        } else if Int(event.keyCode) == kVK_Escape {
            stage = .idle
        } else {
            stage = .recording(refused: true)
        }
    }
}

/// The recorder's button: an AppKit one, so that while it records it holds
/// the keyboard and takes the keys typed into it, those with Command among
/// them, before the menus do. Keys typed anywhere else go where they always
/// go. It takes the keyboard at the press that starts recording; losing it
/// ends recording.
private final class RecorderButton: NSButton {
    var recording = false
    var press: () -> Void = {}
    var end: () -> Void = {}
    var take: (NSEvent) -> Void = { _ in }

    override var acceptsFirstResponder: Bool { true }

    @objc private func pressed() {
        // Recording starts only once this has the keyboard.
        guard recording || window?.makeFirstResponder(self) == true else { return }
        press()
    }

    override func keyDown(with event: NSEvent) {
        if recording { take(event) } else { super.keyDown(with: event) }
    }

    // A key with Command or Control comes here before it reaches this as a
    // key press, and before the menus see it. Let Command-W close the window
    // instead of recording it as a global shortcut.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
            event.charactersIgnoringModifiers == "w"
        {
            end()
            return false
        }
        take(event)
        return true
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned, recording { end() }
        return resigned
    }

    // Taken off screen, as when the pane changes, it records no more; the
    // recorder's own stage ends as it disappears.
    override func viewWillMove(toWindow window: NSWindow?) {
        if let old = self.window {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: old)
        }
        if window == nil, recording {
            recording = false
            end()
        }
        super.viewWillMove(toWindow: window)
        if let window {
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowResignedKey), name: NSWindow.didResignKeyNotification, object: window)
        }
    }

    @objc private func windowResignedKey() {
        if recording { end() }
    }

    struct Field: NSViewRepresentable {
        let title: String
        let hint: String
        let recording: Bool
        let press: () -> Void
        let end: () -> Void
        let take: (NSEvent) -> Void

        func makeNSView(context: Context) -> RecorderButton {
            let button = RecorderButton(title: title, target: nil, action: #selector(RecorderButton.pressed))
            button.target = button
            return button
        }

        func updateNSView(_ button: RecorderButton, context: Context) {
            button.title = title
            button.setAccessibilityHelp(hint)
            button.recording = recording
            button.press = press
            button.end = end
            button.take = take
        }
    }
}

/// The door's port, in Advanced: a field and Save, with what refused the
/// last Save under them until the field changes.
private struct PortRow: View {
    let settings: AppSettings
    let door: Door
    @State private var text = ""
    @State private var problem: String?

    var body: some View {
        Row(
            "Port",
            note: "Local port on 127.0.0.1 for Settings → Connected Apps. Only apps on this Mac can connect."
        ) {
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 6) {
                    TextField("Port", text: $text, prompt: Text(String(AppSettings.defaultDoorPort)))
                        .labelsHidden()
                        .accessibilityLabel("Local server port")
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                        .onSubmit(save)
                    Button("Save", action: save)
                        .disabled(text == String(settings.doorPort))
                }
                if let problem {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .onAppear { text = String(settings.doorPort) }
        .onChange(of: settings.doorPort) {
            text = String(settings.doorPort)
            problem = nil
        }
        .onChange(of: text) { problem = nil }
    }

    private func save() {
        do throws(AppSettings.PortRefusal) {
            try settings.choose(port: text, open: door.state == .open ? door.port : nil)
            text = String(settings.doorPort)
        } catch {
            problem = error.words
        }
    }
}

private struct AdvancedPane: View {
    @Bindable var settings: AppSettings
    let prompt: QuickPrompt
    let supervisor: Supervisor
    let door: Door
    let updates: Updates
    @State private var log: Result<[String], any Error>?
    @State private var restoring = false

    var body: some View {
        let commands = supervisor.commands.map(Self.line).joined(separator: "\n")
        let coverEntries = supervisor.coverLog.entries
        let coverLastHour = supervisor.coverLog.countInLastHour()
        Form {
            Section {
                Row(
                    "Cover traffic",
                    note: "Periodically fetches random public web pages over isolated Tor circuits (~3 requests/min) to blur when your real prompts leave this Mac. Toggles live with no restart."
                ) {
                    Switch("Cover traffic", isOn: $settings.cover)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Fetches random public pages (Wikipedia, Hacker News, arXiv, BBC, GitHub Trending, and 50+ other public URLs) over isolated Tor circuits. Never sends chat text, keys, or personal data.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ScrollView {
                        Text(
                            coverEntries.isEmpty
                                ? "No cover traffic logged yet. Turn Cover Traffic on while Cloak is running to see live requests."
                                : coverEntries.map(\.formattedLine).joined(separator: "\n")
                        )
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(coverEntries.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .defaultScrollAnchor(.bottom)
                    .frame(height: 140)
                    HStack(spacing: 8) {
                        Text(
                            coverEntries.isEmpty
                                ? "0 entries"
                                : "\(coverEntries.count) \(coverEntries.count == 1 ? "entry" : "entries") · \(coverLastHour) in last hour"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        Spacer(minLength: 4)
                        Button("Clear Last Hour") {
                            supervisor.coverLog.clearLastHour()
                        }
                        .controlSize(.small)
                        .disabled(coverLastHour == 0)
                        Button("Clear All", role: .destructive) {
                            supervisor.coverLog.clearAll()
                        }
                        .controlSize(.small)
                        .disabled(coverEntries.isEmpty)
                        if !coverEntries.isEmpty {
                            CopyButton("Copy Cover Log", side: 24, text: coverEntries.map(\.formattedLine).joined(separator: "\n"))
                        }
                    }
                }
            } header: {
                Text("Cover Traffic")
            }
            Section("Privacy & Memory") {
                Row("Free memory", note: "Unloads the local model after idle time to free RAM.") {
                    Picker("Free memory", selection: $settings.freeMemory) {
                        ForEach(FreeMemory.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                }
                Row("NEAR hardware check", note: "How long a verified enclave proof stays valid before re-checking.") {
                    Picker("NEAR hardware check", selection: $settings.proofFreshness) {
                        ForEach(ProofFreshness.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                }
                Row("Show all Venice tiers", note: "Adds Venice Anonymous models (third-party providers) alongside Private and TEE models.") {
                    Switch("Show all Venice tiers", isOn: $settings.veniceAllTiers)
                }
            }
            Section("Shortcut") {
                Row(
                    "Quick prompt",
                    note: "Global shortcut from any app. Opens a quick box to draft a new chat."
                ) {
                    ShortcutRecorder(shortcut: settings.shortcut, refusal: prompt.refusal, choose: prompt.choose)
                }
            }
            Section("Connected Apps") {
                PortRow(settings: settings, door: door)
            }
            Section("Commands") {
                if commands.isEmpty {
                    Text("Nothing has started yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView(.horizontal) {
                        Text(commands)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize()
                            .padding(.vertical, 2)
                    }
                    HStack {
                        Spacer()
                        CopyButton("Copy Commands", side: 28, text: commands)
                    }
                }
            }
            Section("Log") {
                let lines = switch log {
                case .success(let lines)?: lines.isEmpty ? "Nothing logged yet." : lines.joined(separator: "\n")
                case .failure?: "Cloak couldn't read its log."
                case nil: ""
                }
                ScrollView {
                    Text(lines)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .defaultScrollAnchor(.bottom)
                .frame(height: 180)
                HStack(spacing: 2) {
                    Spacer()
                    SymbolButton("Refresh", symbol: "arrow.clockwise") { Task { await read() } }
                    // Offered once there are lines read to copy.
                    if case .success(let logged)? = log, !logged.isEmpty {
                        CopyButton("Copy Log", side: 28, text: logged.joined(separator: "\n"))
                    }
                }
            }
            Section {
                let note = "Puts every setting in this window back. Your wallet, NEAR key, chats and downloaded models stay as they are."
                HStack(spacing: 2) {
                    Spacer()
                    Button("Restore Defaults…") { restoring = true }
                        .accessibilityHint(note)
                    InfoButton("About Restore Defaults", note: note)
                }
            }
        }
        .task { await read() }
        .alert("Restore defaults?", isPresented: $restoring) {
            Button("Restore Defaults", role: .destructive, action: restore)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(restored)
        }
    }

    /// What Restore Defaults does.
    private var restored: String {
        "Resets all preferences, shortcuts, and port back to defaults. Your wallets, keys, chats, and downloaded models stay intact."
    }

    private func read() async {
        do {
            log = .success(try await SessionLog.read())
        } catch {
            log = .failure(error)
        }
    }

    private func restore() {
        prompt.choose(nil)
        settings.restore()
        if LoginItem.stage != .off { _ = LoginItem.set(false) }
        updates.checksAutomatically = false
    }

    /// A command as a shell takes it, so it can be pasted into Terminal:
    /// each word in single quotes when it holds anything a shell reads
    /// specially.
    static func line(_ command: [String]) -> String {
        command.map { word in
            !word.isEmpty && word.allSatisfy { $0.isLetter || $0.isNumber || "-_./:=@%+,".contains($0) }
                ? word : "'" + word.replacing("'", with: #"'\''"#) + "'"
        }
        .joined(separator: " ")
    }
}

/// This session's lines of Cloak's log, oldest first: the time, the part
/// and the message.
enum SessionLog {
    @concurrent static func read() async throws -> [String] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        return try store.getEntries(matching: NSPredicate(format: "subsystem == %@", "sh.regents.cloak.app"))
            .compactMap { $0 as? OSLogEntryLog }
            .map { "\($0.date.formatted(.dateTime.hour().minute().second())) \($0.category) \($0.composedMessage)" }
    }
}

/// Never reword's one control, in General and in the drop-down beside a
/// Chat card's Send: off, each Chat message is reworded first; on, it goes
/// as written (decision 11 in docs/plan.md). Turning it on turns Review off
/// (`AppSettings`).
struct NeverReword: View {
    static let title = "Skip prompt rewriting (lower privacy)"
    @Bindable var settings: AppSettings

    var body: some View {
        Toggle(Self.title, isOn: $settings.neverReword)
    }
}

/// A row's switch: the row has its name, so the switch draws none. On macOS
/// a switch whose label is hidden offers VoiceOver no press, so it was read
/// out and could not be switched (found 21 November, in every row here);
/// VoiceOver is therefore given a switch of its own in the same place,
/// with a title, which keeps the press, even an empty one, and the name.
private struct Switch: View {
    let name: String
    @Binding var isOn: Bool

    init(_ name: String, isOn: Binding<Bool>) {
        self.name = name
        _isOn = isOn
    }

    var body: some View {
        Toggle(name, isOn: $isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .accessibilityRepresentation {
                Toggle("", isOn: $isOn)
                    .toggleStyle(.switch)
                    .accessibilityLabel(name)
            }
    }
}

/// A setting's row: its name, with an `info.circle` at the name's right
/// holding the note that explains it, and its control at the end, which
/// reads that note as its hint.
private struct Row<Control: View>: View {
    let title: String
    /// The info button's name: "About" and this, the title unless it is
    /// long.
    let about: String
    let note: String
    let control: Control

    init(_ title: String, about: String? = nil, note: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.about = about ?? title
        self.note = note
        self.control = control()
    }

    var body: some View {
        LabeledContent {
            // Each control hides its own label; a switch has none (`Switch`).
            control
                .accessibilityHint(note)
        } label: {
            HStack(spacing: 2) {
                Text(title)
                InfoButton("About \(about)", note: note)
            }
        }
    }
}
