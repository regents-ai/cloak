import AppKit
import CloakChat
import CloakControl
import CloakDoor
import CloakSupervisor
import os
import SwiftUI

/// The menu-bar app: one supervisor, each model's download, its menu, its
/// Chat, Agents, Details and Settings windows, the quick prompt,
/// Chat's Modes page on the first launch, NEAR mode's helper, the one way to
/// V's payer, the door other apps and the agent in the guest send through
/// while Cloak is Running, its AppleScript
/// commands (`StartCommand` and the others), the control channel `cloak`
/// uses to drive the same supervisor, and its updater (`Updates`).
@main
struct RegentsCloakApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var app

    // The menu is AppKit's (`StatusMenu`), and the Settings window is the
    // app's own (`SettingsView`); this scene shows nothing. Command-comma
    // opens Settings while one of the app's windows is in front.
    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") { app.showSettings() }
                        .keyboardShortcut(",")
                }
            }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The app's one delegate, for its AppleScript commands: SwiftUI puts
    /// its own in `NSApp.delegate`.
    private(set) static var current: AppDelegate!

    let supervisor = Launch.supervisor
    /// One for each model that answers Local Llama chats, smallest first.
    let downloads = Launch.manifest.answerModels.map { ModelDownload(model: $0, manifest: Launch.manifest, layout: Launch.layout) }
    /// The download of the model that rewords, which every Start needs: the
    /// one the menu and Details show.
    var download: ModelDownload { downloads.first(where: \.rewords)! }
    /// NEAR mode's helper, pinned in the manifest; it starts at the first
    /// check or message.
    let near: Near = {
        let near = Launch.layout.near(Launch.manifest)
        return Near(helper: near.helper, sha256: near.sha256)
    }()
    /// Made at the first show of Chat or Settings, or the quick prompt's
    /// first Return.
    private lazy var nearMode = NearMode(near: near, supervisor: supervisor, settings: .standard)
    /// Made at its window's first show or the quick prompt's first Return.
    private var madeChat: Chat?
    private var conversations: Chat {
        if let madeChat { return madeChat }
        let chat = Chat(
            supervisor: supervisor, settings: .standard, folder: Launch.layout.conversations, wallet: Launch.layout.wallet,
            queue: Launch.payQueue, door: door, nearMode: nearMode, downloads: downloads)
        madeChat = chat
        return chat
    }
    /// Something a restart would cut is under way, the one answer to it: a
    /// request at the door; in Chat, a message being reworded, sent or
    /// answered on this Mac, or an agent's task; with V's wallet or Token
    /// Inference's, a press, a read or money on its way. Before Chat is made
    /// there is none of Chat's.
    private var underWay: Bool {
        door.underWay
            || madeChat.map { chat in
                chat.rewording != nil || !chat.sending.isEmpty || !chat.answering.isEmpty || !chat.agent.runs.isEmpty
                    || chat.payer.working > 0 || chat.payer.reading || chat.payer.moving
                    || chat.wallet.working > 0 || chat.wallet.presence == .creating
            } == true
    }
    private lazy var chat = AppWindow { [unowned self] in
        ChatView.window(
            conversations, showDetails: { self.showDetails() }, showAgents: { self.showAgents() },
            showNearSettings: { self.showSettings(on: .near) }, showLlamaSettings: { self.showSettings(on: .llama) })
    }
    private lazy var details = AppWindow { [unowned self, supervisor, download] in
        DetailsView.window(supervisor, download, showModes: { self.showModes() })
    }
    private lazy var agents = AppWindow { [unowned self, door, supervisor, download] in
        AgentsView.window(
            door, supervisor: supervisor, download: download, openDoor: { self.turnDoor() },
            showDetails: { self.showDetails() }, showDoorSettings: { self.showSettings(on: .advanced) })
    }
    #if DARKBLOOM
    /// Made at its window's first show; it follows Darkbloom only while the
    /// window is open.
    private lazy var darkbloomMode = DarkbloomMode(manifest: Launch.manifest, settings: .standard)
    private lazy var darkbloom = AppWindow { [darkbloomMode] in DarkbloomView.window(darkbloomMode) }

    func showDarkbloom() {
        darkbloom.show()
        darkbloomMode.open()
    }
    #endif
    private let settingsSelection = SettingsView.Selection()
    private lazy var settings = AppWindow { [supervisor, prompt, door, updates, nearMode, downloads, settingsSelection] in
        SettingsView.window(
            .standard, prompt: prompt, supervisor: supervisor, door: door, updates: updates, near: nearMode,
            downloads: downloads, selection: settingsSelection)
    }
    private lazy var prompt = QuickPrompt(settings: .standard) { [unowned self] text in
        conversations.compose(text)
        showChat()
    }
    private var menu: StatusMenu?
    /// Made at launch, with the menu.
    private lazy var updates = Updates()
    let door: Door = {
        let supervisor = Launch.supervisor, conversations = Launch.layout.conversations
        return Door(
            file: Launch.layout.agents, wallet: Launch.layout.wallet,
            parts: Door.Parts(
                reword: { texts throws(RewriteStop) in try await supervisor.rewrite(texts) },
                queue: Launch.payQueue,
                exchange: { request, keep in try await supervisor.exchange(request: request, keep: keep) },
                wallet: { try await WalletKeychain.address() },
                key: { try WalletKeychain.key() },
                sealing: { try await ConversationStore.key(for: conversations, find: Keychain.find, make: Keychain.make) }),
            port: { AppSettings.standard.doorPort })
    }()
    /// The door's latest open or close, which the next one waits for, so
    /// the two never cross: the app's own as Cloak starts and stops, and
    /// Agents' Try Again.
    private var doorTurn: Task<Void, Never>?
    private var server: ControlServer?
    private let logger = Logger(subsystem: "sh.regents.cloak.app", category: "app")

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A write to a worker or a guest connection that has gone must fail
        // (the callers handle that), not end Cloak, as the signal's default
        // would. `cloak-host` and the worker do the same.
        signal(SIGPIPE, SIG_IGN)
        // Help shows after a second's rest on a control, not the system's two.
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 1000])
        Self.current = self
        // With "quit" below, the two ends of a run in the Mac's log: a run
        // with no "quit" ended some other way (`app/log.sh`).
        logger.notice("opened \(Launch.manifest.release, privacy: .public) (\(Launch.manifest.build, privacy: .public))")
        menu = StatusMenu(
            supervisor: supervisor, download: download, showChat: showChat,
            showAgents: showAgents, showDetails: showDetails, showSettings: showSettings,
            checkForUpdates: updates.check)
        // Made now, so the shortcut chosen works from launch.
        _ = prompt
        // The agent's model requests from the guest come in at the door.
        supervisor.door = { [door] socket in door.accept(guest: socket) }
        do {
            server = try ControlServer(path: Places.socket) { [supervisor] request in
                await supervisor.handle(request)
            }
        } catch {
            logger.error("cannot serve the control channel: \(String(describing: error), privacy: .public)")
            Launch.stop("Cloak can't open.", "Quit Cloak, then open it again.")
        }
        // The door is open only while Cloak is Running.
        Task { [unowned self, supervisor] in
            for await _ in Observations({ supervisor.phase == .running }) {
                turnDoor()
            }
        }
        // Cover's switch while Running restarts Cloak, once nothing a
        // restart would cut is under way.
        Task { [unowned self, supervisor] in
            await Supervisor.followCover(
                changed: { supervisor.coverChanged }, underWay: { self.underWay }, restart: { supervisor.send(.restart) })
        }
        // Sleep pauses a run, so a wake finds none running and starts
        // nothing. A worker up for Local Llama chats stays, and rests as
        // ever.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [supervisor] _ in
            MainActor.assumeIsolated { _ = supervisor.send(.sleep) }
        }
        // A minimized window reads "Cloak - Chat" and so on in the Dock;
        // Settings reads "Cloak - Settings" whatever pane it shows. Set as it
        // minimizes, since every change of title resets it.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willMiniaturizeNotification, object: nil, queue: .main
        ) { notification in
            guard let window = notification.object as? ClosingWindow else { return }
            MainActor.assumeIsolated {
                let name = window.contentViewController is NSHostingController<SettingsView> ? "Settings" : window.title
                window.miniwindowTitle = "Cloak - \(name)"
            }
        }
        // Once, on the first launch; it starts nothing.
        if !UserDefaults.standard.bool(forKey: Self.welcomed) {
            UserDefaults.standard.set(true, forKey: Self.welcomed)
            showModes()
        }
    }

    /// The flag in the defaults, set as the first launch shows Chat's Modes
    /// page.
    private static let welcomed = "welcomed"

    func showChat() {
        chat.show()
    }

    /// Chat, with its Modes page on it.
    func showModes() {
        conversations.showingModes = true
        chat.show()
    }

    func showAgents() {
        agents.show()
    }

    /// Opens the door while Cloak is Running and closes it otherwise, once
    /// its last open or close has ended.
    private func turnDoor() {
        let running = supervisor.phase == .running
        doorTurn = Task { [door, last = doorTurn] in
            await last?.value
            if running { await door.open() } else { await door.close() }
        }
    }

    func showDetails() {
        details.show()
    }

    func showSettings() {
        settings.show()
    }

    /// Settings, on `pane`.
    func showSettings(on pane: SettingsView.Pane) {
        settingsSelection.pane = pane
        settings.show()
    }

    /// Quit, from the menu or the system, goes through the one shutdown,
    /// and ends once every app with a request under way has been answered.
    /// NEAR mode's helper ends at once, a message under way or not.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        near.stop()
        supervisor.quit { [server, door, logger] in
            server?.close()
            Task {
                await door.close()
                logger.notice("quit")
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }
}

/// What the app needs before it can show anything: its manifest, being the
/// only Regents Cloak running for this user, and its supervisor, which first
/// clears what a killed app left behind.
@MainActor
enum Launch {
    static let manifest: Manifest = {
        do {
            try Places.makeOwnerOnly(Places.control)
            guard try Instance.claim() else { exit(0) }
            return try Manifest.bundled()
        } catch {
            Logger(subsystem: "sh.regents.cloak.app", category: "app").error("cannot open: \(String(describing: error), privacy: .public)")
            stop("Cloak is damaged.", "Reinstall Cloak.")
        }
    }()

    static let layout = Layout(bundle: Bundle.main.resourceURL!, support: Places.support)

    /// The one way to V's payer in the guest, Chat's and the door's, so
    /// their requests take their turns in one queue.
    static let payQueue = PayQueue { [supervisor] ask, payload in try await supervisor.pay(ask, payload) }

    static let supervisor: Supervisor = {
        do {
            return try Supervisor(manifest: manifest, layout: layout, cover: { AppSettings.standard.cover }) {
                AppSettings.freeMemory(in: .standard).after
            }
        } catch {
            Logger(subsystem: "sh.regents.cloak.app", category: "app").error("cannot clear the boot files: \(String(describing: error), privacy: .public)")
            stop("Cloak can't open.", "Quit Cloak, then open it again.")
        }
    }()

    /// Says why the app cannot run, then ends it.
    static func stop(_ message: String, _ remedy: String) -> Never {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = message
        alert.informativeText = remedy
        NSApp.activate()
        alert.runModal()
        exit(1)
    }
}
