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
    /// One for each model that answers Local Llama chats, smallest first.
    let downloads: [ModelDownload]
    @Bindable var selection: Selection

    static func window(
        _ settings: AppSettings, prompt: QuickPrompt, supervisor: Supervisor, door: Door, updates: Updates, near: NearMode,
        downloads: [ModelDownload], selection: Selection
    ) -> NSWindow {
        let window = ClosingWindow(
            contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Settings"
        let content = NSHostingController(
            rootView: SettingsView(
                settings: settings, prompt: prompt, supervisor: supervisor, door: door, updates: updates, near: near,
                downloads: downloads, selection: selection))
        content.sceneBridgingOptions = [.toolbars]
        window.contentViewController = content
        window.setContentSize(NSSize(width: 680, height: 500))
        return window
    }

    enum Pane: String, CaseIterable, Identifiable {
        case general, near, llama, advanced

        var id: Self { self }

        var title: String {
            switch self {
            case .general: "General"
            case .near: "NEAR"
            case .llama: "Local Llama"
            case .advanced: "Advanced"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .near: "cpu"
            case .llama: "laptopcomputer"
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
                case .general: GeneralPane(settings: settings, supervisor: supervisor, updates: updates)
                case .near: NearPane(settings: settings, mode: near)
                case .llama: LlamaPane(settings: settings, downloads: downloads, rewording: supervisor.manifest.rewordingModel)
                case .advanced:
                    AdvancedPane(settings: settings, prompt: prompt, supervisor: supervisor, door: door, updates: updates)
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
    let supervisor: Supervisor
    let updates: Updates
    @State private var login = LoginItem.stage

    var body: some View {
        Form {
            Section {
                Row("Launch at login", note: "Cloak opens paused, so nothing runs until you press Start or ask something in a Local Llama chat.") {
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
            // Never both on (`AppSettings`), so side by side.
            Section {
                Row(
                    NeverReword.title, about: "Never reword",
                    note: "Chat then sends each message as you wrote it. Tasks, and what other apps send through Cloak, are always reworded. Turning this on turns Review off."
                ) {
                    Switch(NeverReword.title, isOn: $settings.neverReword)
                }
                Row("Review", note: "Chat shows each reworded message for you to edit and send. Off, it's sent as soon as it's reworded. Turning this on turns Never reword off.") {
                    Switch("Review", isOn: $settings.review)
                }
            }
            Section {
                Row("Saved chats", note: "Off, chats you start or continue aren't saved and are gone when Cloak quits. Chats already saved stay until you delete them.") {
                    Switch("Saved chats", isOn: $settings.savedChats)
                }
            }
            Section {
                Row("Cover traffic", note: "Cloak visits ordinary public pages in the background, so your real requests stand out less. It uses some bandwidth. Switching it while Cloak is running restarts Cloak, which takes about 10 seconds.") {
                    VStack(alignment: .trailing, spacing: 4) {
                        Switch("Cover traffic", isOn: $settings.cover)
                        // The restart waits for what is being sent.
                        if supervisor.coverChanged {
                            Label("Switches once what's being sent has finished.", systemImage: "clock")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                Row("Free memory", note: "The model leaves memory once it has had nothing to do for that long, and the next message takes a few seconds longer.") {
                    Picker("Free memory", selection: $settings.freeMemory) {
                        ForEach(FreeMemory.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                }
            }
            UpdatesSection(updates: updates)
            FeedbackSection()
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
            Row("Updates", note: "Each check goes straight from this Mac to the update server, which sees this Mac's internet address but nothing from your chats.") {
                Switch("Updates", isOn: Binding(get: { checks }, set: { updates.checksAutomatically = $0; checks = $0 }))
            }
        }
        // Sparkle's own question about checking can be answered while the
        // window is away, so the setting is read again when it comes back.
        .onReturn { checks = updates.checksAutomatically }
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
                    CopyButton("Copy Words", side: 28, text: Self.words)
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

    var body: some View {
        Form {
            Section {
                Row("Key", note: "Your API key from NEAR AI Cloud. You can create one at cloud.near.ai. It pays for the messages you send in NEAR Private AI chats, so NEAR can connect those messages to your account. Cloak keeps it in this Mac's keychain, and it can't be viewed here after you save it.") {
                    KeyRow(mode: mode)
                }
            }
            Section {
                Row("Tor", note: "Sends your NEAR Private AI chats through the Tor network, so NEAR and Intel see a Tor address instead of your internet address. It's slower: checking NEAR's servers takes about half a minute, and Cloak needs to be started first.") {
                    Switch("Tor", isOn: $settings.nearTor)
                }
            }
            Section {
                Row("Freshness", note: "Before sending a message, Cloak checks proof from NEAR's servers, with Intel's help, that they are the hardware and software this version of Cloak accepts. This sets how long a successful check counts before Cloak checks again. “Every message” is the most careful and adds a few seconds to each one.") {
                    Picker("Freshness", selection: $settings.proofFreshness) {
                        ForEach(ProofFreshness.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                }
            }
            Section {
                Row("Model", note: "The model that answers your NEAR Private AI chats. Cloak's check covers the servers it runs on, not the model software itself.") {
                    Text("Qwen3.8-27B")
                        .foregroundStyle(.secondary)
                }
            }
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
            Text("NEAR Private AI chats can't send until you save a key again.")
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
                } else if download.state != .installed {
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
        .tip(download.fits ? "" : unfit)
        .alert("Remove \(label)?", isPresented: $removing) {
            Button("Remove", role: .destructive) { download.remove() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its files are deleted from this Mac. You can download it again.")
        }
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
    // key press, and before the menus see it.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
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
        if window == nil { recording = false }
        super.viewWillMove(toWindow: window)
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
            note: "Apps you add in the Agents window, such as a coding agent, send their AI requests through Cloak at 127.0.0.1 on this port. Only apps on this Mac can connect. A new port is used as soon as it's saved, so apps you added earlier need the new address from the Agents window."
        ) {
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
    let door: Door
    let updates: Updates
    @State private var log: Result<[String], any Error>?
    @State private var restoring = false

    var body: some View {
        let commands = supervisor.commands.map(Self.line).joined(separator: "\n")
        Form {
            Section("Shortcut") {
                Row(
                    "Quick prompt",
                    note: "A keyboard shortcut that works in any app. It opens a small box: type a message and press Return, and Cloak opens a new chat with it written in, not sent."
                ) {
                    ShortcutRecorder(shortcut: settings.shortcut, refusal: prompt.refusal, choose: prompt.choose)
                }
            }
            Section("Agents") {
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

    /// What Restore Defaults does, from the defaults themselves.
    private var restored: String {
        let settings = """
        Launch at login, Updates and Tor for NEAR turn off, \
        rewording, Review, Saved chats and Cover traffic turn back on, \
        Free memory goes back to “\(AppSettings.defaultFreeMemory.title)”, \
        Freshness to “\(AppSettings.defaultProofFreshness.title)” \
        and Local Llama to \(supervisor.manifest.rewordingModel.label), \
        the quick prompt loses its shortcut, and the port goes back to \(AppSettings.defaultDoorPort).
        """
        // Cover back on under a guest that runs without it.
        return supervisor.phase == .running && supervisor.cover == false
            ? settings + " Cloak restarts to turn Cover traffic back on."
            : settings
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
    static let title = "Never reword text. Reduces your privacy."
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
