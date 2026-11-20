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
/// may go unused before it leaves memory, and, when the app has an updater,
/// whether it checks for updates by itself), NEAR (the NEAR key, Tor, how
/// long a passed check is used again, and the model), Shortcut (the
/// quick prompt's), Door (its port on 127.0.0.1) and Advanced (how Cloak
/// started its parts, this session's log, and Restore Defaults).
struct SettingsView: View {
    let settings: AppSettings
    let prompt: QuickPrompt
    let supervisor: Supervisor
    let door: Door
    let updates: Updates?
    let near: NearMode

    static func window(
        _ settings: AppSettings, prompt: QuickPrompt, supervisor: Supervisor, door: Door, updates: Updates?, near: NearMode
    ) -> NSWindow {
        let window = ClosingWindow(
            contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Settings"
        let content = NSHostingController(
            rootView: SettingsView(settings: settings, prompt: prompt, supervisor: supervisor, door: door, updates: updates, near: near))
        content.sceneBridgingOptions = [.toolbars]
        window.contentViewController = content
        window.setContentSize(NSSize(width: 680, height: 500))
        return window
    }

    private enum Pane: String, CaseIterable, Identifiable {
        case general, near, shortcut, door, advanced

        var id: Self { self }

        var title: String {
            switch self {
            case .general: "General"
            case .near: "NEAR"
            case .shortcut: "Shortcut"
            case .door: "Door"
            case .advanced: "Advanced"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .near: "cpu"
            case .shortcut: "keyboard"
            case .door: "door.left.hand.open"
            case .advanced: "wrench.and.screwdriver"
            }
        }
    }

    @State private var pane: Pane? = .general

    var body: some View {
        // The sidebar's list can be left with nothing chosen.
        let shown = pane ?? .general
        NavigationSplitView {
            List(Pane.allCases, selection: $pane) { pane in
                Label(pane.title, systemImage: pane.symbol)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 180, max: 220)
        } detail: {
            Group {
                switch shown {
                case .general: GeneralPane(settings: settings, updates: updates)
                case .near: NearPane(settings: settings, mode: near)
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
    let updates: Updates?
    @State private var login = LoginItem.isOn

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: Binding(get: { login }, set: { login = LoginItem.set($0) }))
            } footer: {
                Footnote("Cloak opens paused, so nothing runs until you press Start.")
            }
            Section {
                NeverReword(settings: settings)
            } footer: {
                Footnote("Chat then sends each message as you wrote it. Tasks, and what other apps send through the door, are always reworded.")
            }
            Section {
                Toggle("Review", isOn: $settings.review)
                    .disabled(settings.neverReword)
            } footer: {
                Footnote("Chat shows each reworded message for you to edit and send. Off, it's sent as soon as it's reworded. Not used while Never reword is on.")
            }
            Section {
                Toggle("Saved chats", isOn: $settings.savedChats)
            } footer: {
                Footnote("Off, chats you start or continue aren't saved and are gone when Cloak quits. Chats already saved stay until you delete them.")
            }
            Section {
                Toggle("Cover traffic", isOn: $settings.cover)
            } footer: {
                Footnote("Cloak visits ordinary public pages in the background, so your real requests stand out less. It uses some bandwidth, and a change applies at the next Start.")
            }
            Section {
                Picker("Free memory", selection: $settings.freeMemory) {
                    ForEach(FreeMemory.allCases) { Text($0.title).tag($0) }
                }
            } footer: {
                Footnote("The model leaves memory once Cloak has reworded nothing for that long, and the next message takes a few seconds longer.")
            }
            if let updates { UpdatesSection(updates: updates) }
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
            Toggle("Updates", isOn: Binding(get: { checks }, set: { updates.checksAutomatically = $0; checks = $0 }))
        } footer: {
            Footnote("Each check goes straight from this Mac to the update server, which sees this Mac's internet address but nothing from your chats.")
        }
        // Sparkle's own question about checking can be answered while the
        // window is away, so the setting is read again when it comes back.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            checks = updates.checksAutomatically
        }
    }
}

/// NEAR mode's key, kept in the keychain and never shown again; whether it
/// goes through Tor; how long a passed check is used again; and its one
/// model.
private struct NearPane: View {
    @Bindable var settings: AppSettings
    let mode: NearMode
    @State private var key = ""
    @State private var replacing = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Key") {
                    VStack(alignment: .trailing, spacing: 4) {
                        if mode.hasKey == true, !replacing {
                            HStack(spacing: 6) {
                                Text("Saved")
                                    .foregroundStyle(.secondary)
                                Button("Replace") { replacing = true }
                                Button("Remove") { Task { await mode.remove() } }
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
            } footer: {
                Footnote("Your API key from NEAR AI Cloud. You can create one at cloud.near.ai. It pays for the messages you send in NEAR chats, so NEAR can connect those messages to your account. Cloak keeps it in this Mac's keychain, and it can't be viewed here after you save it.")
            }
            Section {
                Toggle("Tor", isOn: $settings.nearTor)
            } footer: {
                Footnote("Sends your NEAR chats through the Tor network, so NEAR and Intel see a Tor address instead of your internet address. It's slower: checking NEAR's servers takes about half a minute, and Cloak needs to be started first.")
            }
            Section {
                Picker("Freshness", selection: $settings.proofFreshness) {
                    ForEach(ProofFreshness.allCases) { Text($0.title).tag($0) }
                }
            } footer: {
                Footnote("Before sending a message, Cloak checks proof from NEAR's servers, with Intel's help, that they are the hardware and software this version of Cloak accepts. This sets how long a successful check counts before Cloak checks again. “Every message” is the most careful and adds a few seconds to each one.")
            }
            Section {
                LabeledContent("Model", value: "Qwen3.8-27B")
            } footer: {
                Footnote("The model that answers your NEAR chats. Cloak's check covers the servers it runs on, not the model software itself.")
            }
        }
        .task { await mode.find() }
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

private struct ShortcutPane: View {
    let settings: AppSettings
    let prompt: QuickPrompt

    var body: some View {
        Form {
            Section {
                LabeledContent("Quick prompt") {
                    ShortcutRecorder(shortcut: settings.shortcut, refusal: prompt.refusal, choose: prompt.choose)
                }
            } footer: {
                Footnote("Opens a box over any app. Return takes what you wrote to a new chat, unsent.")
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
                LabeledContent("Port") {
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
            } footer: {
                Footnote("Only apps on this Mac can connect. A new port applies at the next Start.")
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
    let updates: Updates?
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
                    Button("Copy") { copy(commands) }
                        .accessibilityLabel("Copy Commands")
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
                HStack {
                    Spacer()
                    Button("Refresh") { Task { await read() } }
                    Button("Copy") { copy(lines) }
                        .accessibilityLabel("Copy Log")
                }
            }
            Section {
                HStack {
                    Spacer()
                    Button("Restore Defaults…") { restoring = true }
                }
            } footer: {
                Footnote("Puts every setting in this window back. Your wallet, NEAR key, chats and model stay as they are.")
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
        \(updates == nil ? "Launch at login and Tor for NEAR turn" : "Launch at login, Updates and Tor for NEAR turn") off, \
        rewording, Review, Saved chats and Cover traffic turn back on, \
        Free memory goes back to “\(AppSettings.defaultFreeMemory.title)” \
        and Freshness to “\(AppSettings.defaultProofFreshness.title)”, \
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
        updates?.checksAutomatically = false
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

/// Never reword's one control, in General and in Chat's review area: off,
/// each Chat message is reworded and shown before it goes; on, it goes as
/// written (decision 11 in docs/plan.md).
struct NeverReword: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Toggle("Never reword text. Reduces your privacy.", isOn: $settings.neverReword)
    }
}

/// A form section's footer: one plain line.
private struct Footnote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
    }
}
