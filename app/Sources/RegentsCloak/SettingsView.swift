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
/// while there is a choice), Shortcut (the quick prompt's), Door (its port
/// on 127.0.0.1) and Advanced (how Cloak started its parts, this session's
/// log, and Restore Defaults).
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
    let venice: VeniceMode
    /// One for each model that answers Local Llama chats, smallest first.
    let downloads: [ModelDownload]
    @Bindable var selection: Selection

    static func window(
        _ settings: AppSettings, prompt: QuickPrompt, supervisor: Supervisor, door: Door, updates: Updates, near: NearMode,
        venice: VeniceMode, downloads: [ModelDownload], selection: Selection
    ) -> NSWindow {
        let window = ClosingWindow(
            contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Settings"
        let content = NSHostingController(
            rootView: SettingsView(
                settings: settings, prompt: prompt, supervisor: supervisor, door: door, updates: updates, near: near,
                venice: venice, downloads: downloads, selection: selection))
        content.sceneBridgingOptions = [.toolbars]
        window.contentViewController = content
        window.setContentSize(NSSize(width: 680, height: 500))
        return window
    }

    enum Pane: String, CaseIterable, Identifiable {
        case general, near, venice, llama, shortcut, door, advanced

        var id: Self { self }

        var title: String {
            switch self {
            case .general: "General"
            case .near: "NEAR"
            case .venice: "Venice"
            case .llama: "Local Llama"
            case .shortcut: "Shortcut"
            case .door: "Door"
            case .advanced: "Advanced"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .near: "cpu"
            case .venice: "water.waves"
            case .llama: "laptopcomputer"
            case .shortcut: "keyboard"
            case .door: "door.left.hand.open"
            case .advanced: "wrench.and.screwdriver"
            }
        }
    }

    var body: some View {
        // The sidebar's list can be left with nothing chosen.
        let shown = selection.pane ?? .general
        let panes = Pane.allCases.filter { $0 != .llama || LlamaPane.isListed(settings, downloads: downloads) }
        NavigationSplitView {
            List(panes, selection: $selection.pane) { row in
                Label(row.title, systemImage: row.symbol)
                    .sidebarHover(selected: row == selection.pane)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 180, max: 220)
        } detail: {
            Group {
                switch shown {
                case .general: GeneralPane(settings: settings, updates: updates)
                case .near: NearPane(settings: settings, mode: near)
                case .venice: VenicePane(settings: settings, mode: venice)
                case .llama: LlamaPane(settings: settings, downloads: downloads, rewording: supervisor.manifest.rewordingModel)
                case .shortcut: ShortcutPane(settings: settings, prompt: prompt)
                case .door: DoorPane(settings: settings, door: door)
                case .advanced: AdvancedPane(settings: settings, prompt: prompt, supervisor: supervisor, updates: updates)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .contentMargins(.top, 8, for: .scrollContent)
            .navigationTitle(shown.title)
        }
        .frame(width: 680, height: 500)
    }
}

private struct GeneralPane: View {
    @Bindable var settings: AppSettings
    let updates: Updates
    @State private var login = LoginItem.isOn

    var body: some View {
        Form {
            Section {
                Row("Launch at login", note: "Cloak opens paused, so nothing runs until you press Start or ask something in a Local Llama chat.") {
                    Toggle("Launch at login", isOn: Binding(get: { login }, set: { login = LoginItem.set($0) }))
                }
            }
            // Never both on (`AppSettings`), so side by side.
            Section {
                Row(
                    "Never reword text. Reduces your privacy.", about: "Never reword",
                    note: "Chat then sends each message as you wrote it. Tasks, and what other apps send through the door, are always reworded. Turning this on turns Review off."
                ) {
                    NeverReword(settings: settings)
                }
                Row("Review", note: "Chat shows each reworded message for you to edit and send. Off, it's sent as soon as it's reworded. Turning this on turns Never reword off.") {
                    Toggle("Review", isOn: $settings.review)
                }
            }
            Section {
                Row("Saved chats", note: "Off, chats you start or continue aren't saved and are gone when Cloak quits. Chats already saved stay until you delete them.") {
                    Toggle("Saved chats", isOn: $settings.savedChats)
                }
            }
            Section {
                Row("Cover traffic", note: "Cloak visits ordinary public pages in the background, so your real requests stand out less. It uses some bandwidth. A change applies after Pause, then Start; Cloak itself stays open.") {
                    Toggle("Cover traffic", isOn: $settings.cover)
                }
            }
            Section {
                Row("Free memory", note: "The model leaves memory once it has had nothing to do for that long, and the next message takes a few seconds longer.") {
                    Picker("Free memory", selection: $settings.freeMemory) {
                        ForEach(FreeMemory.allCases) { Text($0.title).tag($0) }
                    }
                }
            }
            UpdatesSection(updates: updates)
            FeedbackSection()
        }
        // The login item can change in System Settings while the window is
        // away, so it is read again each time the window comes back.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            login = LoginItem.isOn
        }
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
            Row("Updates", note: "Each check goes straight from this Mac to the update server, which sees this Mac's internet address but nothing from your chats.") {
                Toggle("Updates", isOn: Binding(get: { checks }, set: { updates.checksAutomatically = $0; checks = $0 }))
            }
        }
        // Sparkle's own question about checking can be answered while the
        // window is away, so the setting is read again when it comes back.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            checks = updates.checksAutomatically
        }
    }
}

/// Where to say what broke or ask for help: Patchbay's board for regents.sh,
/// and words to give an agent that posts there for you.
private struct FeedbackSection: View {
    /// The release, which `build.sh` writes into the app.
    private static let release = Bundle.main.infoDictionary!["CFBundleShortVersionString"] as! String
    private static let words = """
        Post my feedback about the Regents Cloak Mac app, version \(release), on Patchbay's board for regents.sh. \
        First read https://patchbay.help/regents.sh as Markdown and follow its Ask section: call ask_question with the site regents.sh. \
        Ask me what I was doing, what happened and what I expected, and post exactly that. \
        Leave out keys, passwords, wallet addresses and what my chats said.
        """
    private static let note = "Posts there are public. Your agent needs pairing on patchbay.help once before it can post."

    var body: some View {
        Section {
            Text("Something broke, or you have a question? Post it at [patchbay.help/regents.sh](https://patchbay.help/regents.sh).")
            VStack(alignment: .leading, spacing: 8) {
                Text("Or give these words to your agent:")
                Text(Self.words)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Self.words, forType: .string)
                    }
                    .accessibilityLabel("Copy Words")
                    .accessibilityHint(Self.note)
                }
            }
        } header: {
            HStack(spacing: 2) {
                Text("Help")
                InfoButton("About Help", note: Self.note)
            }
        }
    }
}

/// NEAR mode's key, kept in the keychain and never shown again, removed
/// only once asked; whether it goes through Tor; how long a passed check is
/// used again; and its one model.
private struct NearPane: View {
    @Bindable var settings: AppSettings
    let mode: NearMode
    @State private var key = ""
    @State private var replacing = false
    @State private var removing = false

    var body: some View {
        Form {
            Section {
                Row("Key", note: "Your API key from NEAR AI Cloud. You can create one at cloud.near.ai. It pays for the messages you send in NEAR Private AI chats, so NEAR can connect those messages to your account. Cloak keeps it in this Mac's keychain, and it can't be viewed here after you save it.") {
                    VStack(alignment: .trailing, spacing: 4) {
                        if mode.hasKey == true, !replacing {
                            HStack(spacing: 2) {
                                Text("Saved")
                                    .foregroundStyle(.secondary)
                                SymbolButton("Replace", symbol: "pencil") { replacing = true }
                                SymbolButton("Remove", symbol: "trash") { removing = true }
                            }
                        } else {
                            HStack(spacing: 6) {
                                SecureField("NEAR key", text: $key, prompt: Text("NEAR key"))
                                    .labelsHidden()
                                    .frame(width: 220)
                                    .onSubmit(save)
                                Button("Save", action: save)
                                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                        if mode.keyFailed {
                            Text("The keychain said no. Try again.")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
            Section {
                Row("Tor", note: "Sends your NEAR Private AI chats through the Tor network, so NEAR and Intel see a Tor address instead of your internet address. It's slower: checking NEAR's servers takes about half a minute, and Cloak needs to be started first.") {
                    Toggle("Tor", isOn: $settings.nearTor)
                }
            }
            Section {
                Row("Freshness", note: "Before sending a message, Cloak checks proof from NEAR's servers, with Intel's help, that they are the hardware and software this version of Cloak accepts. This sets how long a successful check counts before Cloak checks again. “Every message” is the most careful and adds a few seconds to each one.") {
                    Picker("Freshness", selection: $settings.proofFreshness) {
                        ForEach(ProofFreshness.allCases) { Text($0.title).tag($0) }
                    }
                }
            }
            Section {
                Row("Model", note: "The model that answers your NEAR Private AI chats. Cloak's check covers the servers it runs on, not the model software itself.") {
                    Text("Qwen3.8-27B")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task { await mode.find() }
        .alert("Remove key?", isPresented: $removing) {
            Button("Remove", role: .destructive) { Task { await mode.remove() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("NEAR Private AI chats can't send until you save a key again.")
        }
    }

    /// Keeps the key typed, and clears the field at once.
    private func save() {
        let typed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        key = ""
        guard !typed.isEmpty else { return }
        Task {
            if await mode.save(typed) { replacing = false }
        }
    }
}

/// Venice's key, kept in the keychain and never shown again, removed only
/// once asked, and whether the wallet sheet lists the models Venice calls
/// Anonymous. Venice always goes through Tor, as Token Inference does.
private struct VenicePane: View {
    @Bindable var settings: AppSettings
    let mode: VeniceMode
    @State private var key = ""
    @State private var replacing = false
    @State private var removing = false

    var body: some View {
        Form {
            Section {
                Row("Key", note: "Your Inference Only key from Venice. You can create one at venice.ai/settings/api. It pays for Venice chats that pay with a key, so Venice can connect those chats to your account. Cloak keeps it in this Mac's keychain, and it can't be viewed here after you save it.") {
                    VStack(alignment: .trailing, spacing: 4) {
                        if mode.hasKey == true, !replacing {
                            HStack(spacing: 2) {
                                Text("Saved")
                                    .foregroundStyle(.secondary)
                                SymbolButton("Replace", symbol: "pencil") { replacing = true }
                                SymbolButton("Remove", symbol: "trash") { removing = true }
                            }
                        } else {
                            HStack(spacing: 6) {
                                SecureField("Venice key", text: $key, prompt: Text("Venice key"))
                                    .labelsHidden()
                                    .frame(width: 220)
                                    .onSubmit(save)
                                Button("Save", action: save)
                                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                        if mode.keyFailed {
                            Text("The keychain said no. Try again.")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
            Section {
                Row("All tiers", note: "Off, Cloak lists only the models Venice calls Private or TEE. On, it also lists those Venice calls Anonymous, whose own companies can read your messages.") {
                    Toggle("All tiers", isOn: $settings.veniceAllTiers)
                }
            }
        }
        .task { await mode.find() }
        .alert("Remove key?", isPresented: $removing) {
            Button("Remove", role: .destructive) { Task { await mode.remove() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Venice chats that pay with a key can't send until you save a key again.")
        }
    }

    /// Keeps the key typed, and clears the field at once.
    private func save() {
        let typed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        key = ""
        guard !typed.isEmpty else { return }
        Task {
            if await mode.save(typed) { replacing = false }
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
    let rewording: Manifest.Model

    /// Whether the pane is in the sidebar: while a model other than the one
    /// that rewords fits this Mac, or one is chosen.
    static func isListed(_ settings: AppSettings, downloads: [ModelDownload]) -> Bool {
        settings.answerModel != nil || downloads.contains { !$0.rewords && $0.fits }
    }

    var body: some View {
        let chosen = settings.answerModel ?? rewording.name
        let best = downloads.last(where: \.fits)?.model.name
        let hosts = downloads.flatMap(\.hosts).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let note = """
            Rewording always uses \(rewording.label), whichever model answers. \
            Each download goes straight from this Mac to \(hosts.joined(separator: " and ")) and its download servers, \
            so they see this Mac's internet address.
            """
        Form {
            Section {
                ForEach(downloads, id: \.model.name) { download in
                    ModelRow(download: download, chosen: download.model.name == chosen, best: download.model.name == best) {
                        settings.answerModel = download.rewords ? nil : download.model.name
                    }
                }
            } header: {
                HStack(spacing: 2) {
                    Text("Model")
                    InfoButton("About Model", note: note)
                }
            }
        }
        .onAppear { downloads.forEach { $0.refresh() } }
    }
}

/// One model in Local Llama: its radio mark, which chooses it, its name,
/// "Best for this Mac" under the name of the last one that fits, why its
/// download stopped, its download size, and its download's symbols:
/// Download or Continue, progress and Pause while under way, and Remove.
private struct ModelRow: View {
    let download: ModelDownload
    let chosen: Bool
    let best: Bool
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
                if download.isUnderWay {
                    let progress = "\(DownloadSection.text(download.done)) of \(size)"
                    ProgressView(value: Double(download.done), total: Double(max(download.total, 1)))
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .frame(width: 28, height: 28)
                        .help(progress)
                        .accessibilityLabel("Download")
                        .accessibilityValue(progress)
                    SymbolButton("Pause", symbol: "pause.circle") { download.pause() }
                } else if download.state != .installed {
                    SymbolButton(download.done > 0 ? "Continue" : "Download", symbol: "arrow.down.circle") { download.start() }
                        .disabled(download.blocked != nil)
                }
                if !download.rewords, download.isUnderWay || download.done > 0 {
                    SymbolButton("Remove", symbol: "trash") { removing = true }
                }
            }
        } label: {
            Button(action: choose) {
                HStack(spacing: 8) {
                    Image(systemName: chosen ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(chosen ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(label)
                        if best {
                            Text("Best for this Mac")
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
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(!download.fits)
            .accessibilityAddTraits(chosen ? .isSelected : [])
            .accessibilityHint(download.fits ? "" : unfit)
        }
        .help(download.fits ? "" : unfit)
        .alert("Remove \(label)?", isPresented: $removing) {
            Button("Remove", role: .destructive) { download.remove() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its files are deleted from this Mac. You can download it again.")
        }
    }

    /// Why the download stopped, or why it can't start for want of space.
    private var problem: String? {
        guard !download.isUnderWay else { return nil }
        if let block = download.blocked, case .disk = block { return DownloadSection.text(block) }
        return DownloadSection.note(download)
    }
}

private struct ShortcutPane: View {
    let settings: AppSettings
    let prompt: QuickPrompt

    var body: some View {
        Form {
            Section {
                Row("Quick prompt", note: "Opens a box over any app. Return takes what you wrote to a new chat, unsent.") {
                    ShortcutRecorder(shortcut: settings.shortcut, refusal: prompt.refusal, choose: prompt.choose)
                }
            }
        }
    }
}

/// The shortcut, or Record Shortcut. Pressed, it takes the next keys
/// pressed as the shortcut; Escape stops it with nothing changed. Keys
/// without Command, Option or Control are refused, with the words why, and
/// so is a shortcut the system won't take.
private struct ShortcutRecorder: View {
    let shortcut: Shortcut?
    let refusal: String?
    let choose: (Shortcut?) -> Void
    @State private var monitor: Any?
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                Button(monitor == nil ? shortcut?.title ?? "Record Shortcut" : "Press Keys…") {
                    if monitor == nil { record() } else { stop() }
                }
                .accessibilityHint(monitor == nil ? "Records a new shortcut" : "Stops recording")
                if shortcut != nil, monitor == nil {
                    Button("Clear Shortcut", systemImage: "xmark.circle.fill") { choose(nil) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .hover(Circle(), outset: 4)
                        .help("Clear Shortcut")
                }
            }
            if let words = problem ?? refusal {
                Text(words)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .onDisappear(perform: stop)
    }

    private func record() {
        problem = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { take(event) }
            return nil
        }
    }

    private func take(_ event: NSEvent) {
        if let shortcut = Shortcut(event) {
            stop()
            choose(shortcut)
        } else if Int(event.keyCode) == kVK_Escape {
            stop()
        } else {
            problem = "Hold ⌘, ⌥ or ⌃ with the key."
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

private struct DoorPane: View {
    let settings: AppSettings
    let door: Door
    @State private var text = ""
    @State private var problem: String?

    var body: some View {
        Form {
            Section {
                Row("Port", note: "Only apps on this Mac can connect. A new port applies at the next Start.") {
                    VStack(alignment: .trailing, spacing: 4) {
                        HStack(spacing: 6) {
                            TextField("Port", text: $text, prompt: Text(String(AppSettings.defaultDoorPort)))
                                .labelsHidden()
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
            }
        }
        .onAppear { text = String(settings.doorPort) }
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
    let settings: AppSettings
    let prompt: QuickPrompt
    let supervisor: Supervisor
    let updates: Updates
    @State private var log: Result<[String], any Error>?
    @State private var restoring = false

    var body: some View {
        let commands = supervisor.commands.map(Self.line).joined(separator: "\n")
        Form {
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
                }
                HStack {
                    Spacer()
                    SymbolButton("Copy Commands", symbol: "doc.on.doc") { copy(commands) }
                        .disabled(commands.isEmpty)
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
                    SymbolButton("Copy Log", symbol: "doc.on.doc") { copy(lines) }
                }
            }
            Section {
                let note = "Puts every setting in this window back. Your wallet, NEAR and Venice keys, chats and downloaded models stay as they are."
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

    /// What Restore Defaults does, from the defaults themselves.
    private var restored: String {
        """
        Launch at login, Updates, Tor for NEAR and All tiers for Venice turn off, \
        rewording, Review, Saved chats and Cover traffic turn back on, \
        Free memory goes back to “\(AppSettings.defaultFreeMemory.title)”, \
        Freshness to “\(AppSettings.defaultProofFreshness.title)”, \
        Local Llama to \(supervisor.manifest.rewordingModel.label), \
        new Token Inference chats to Boundless, Venice's Pay with to “Key”, the chosen Venice model is cleared, \
        the quick prompt loses its shortcut, and the door goes back to port \(AppSettings.defaultDoorPort).
        """
    }

    private func read() async {
        do {
            log = .success(try await SessionLog.read())
        } catch {
            log = .failure(error)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func restore() {
        prompt.choose(nil)
        settings.restore()
        if LoginItem.isOn { _ = LoginItem.set(false) }
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
    @Bindable var settings: AppSettings

    var body: some View {
        Toggle("Never reword text. Reduces your privacy.", isOn: $settings.neverReword)
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
            control
                .labelsHidden()
                // What a grouped form draws a toggle as when it is the row.
                .toggleStyle(.switch)
                .accessibilityHint(note)
        } label: {
            HStack(spacing: 2) {
                Text(title)
                InfoButton("About \(about)", note: note)
            }
        }
    }
}
