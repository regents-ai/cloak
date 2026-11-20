import AppKit
import CloakChat
import CloakControl
import CloakDoor
import CloakSupervisor
import os
import SwiftUI

/// The menu-bar app: one supervisor, the model's download, its menu, its
/// Chat, Agents, Details and Settings windows, the quick prompt, a welcome
/// on the first launch, NEAR mode's helper, the door other apps and the
/// agent in the guest send through while Cloak is Running, its AppleScript
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
    let download = ModelDownload(manifest: Launch.manifest, layout: Launch.layout)
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
    private lazy var conversations = Chat(
        supervisor: supervisor, settings: .standard, folder: Launch.layout.conversations, wallet: Launch.layout.wallet,
        door: door, nearMode: nearMode, download: download)
    private lazy var chat = AppWindow { [unowned self] in
        ChatView.window(conversations, showDetails: { self.showDetails() }, showNearSettings: { self.showSettings(on: .near) })
    }
    private lazy var details = AppWindow { [supervisor, download] in DetailsView.window(supervisor, download) }
    private lazy var agents = AppWindow { [door] in AgentsView.window(door) }
    private let settingsSelection = SettingsView.Selection()
    private lazy var settings = AppWindow { [supervisor, prompt, door, updates, nearMode, settingsSelection] in
        SettingsView.window(
            .standard, prompt: prompt, supervisor: supervisor, door: door, updates: updates, near: nearMode,
            selection: settingsSelection)
    }
    private lazy var welcome = AppWindow { WelcomeView.window() }
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
                exchange: { request, keep in try await supervisor.exchange(request: request, keep: keep) },
                wallet: { try await WalletKeychain.address() },
                key: { try WalletKeychain.key() },
                sealing: { try await ConversationStore.key(for: conversations, find: Keychain.find, make: Keychain.make) }),
            port: { AppSettings.standard.doorPort })
    }()
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
            supervisor: supervisor, download: download, model: Launch.layout.model(Launch.manifest), showChat: showChat,
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
            Launch.stop("Regents Cloak can't open.", "Quit Regents Cloak, then open it again.")
        }
        // The door is open only while Cloak is Running.
        Task { [supervisor, door] in
            for await running in Observations({ supervisor.phase == .running }) {
                if running { await door.open() } else { await door.close() }
            }
        }
        // Sleep pauses a run, so a wake finds none running and starts
        // nothing. A worker up for Local Llama chats stays, and rests as
        // ever.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [supervisor] _ in
            MainActor.assumeIsolated { _ = supervisor.send(.sleep) }
        }
        // Once, on the first launch; it starts nothing.
        if !UserDefaults.standard.bool(forKey: WelcomeView.key) {
            UserDefaults.standard.set(true, forKey: WelcomeView.key)
            welcome.show()
        }
    }

    func showChat() {
        chat.show()
    }

    func showAgents() {
        agents.show()
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
            stop("Regents Cloak is damaged.", "Reinstall Regents Cloak.")
        }
    }()

    static let layout = Layout(bundle: Bundle.main.resourceURL!, support: Places.support)

    static let supervisor: Supervisor = {
        do {
            return try Supervisor(manifest: manifest, layout: layout, cover: { AppSettings.standard.cover }) {
                AppSettings.freeMemory(in: .standard).after
            }
        } catch {
            Logger(subsystem: "sh.regents.cloak.app", category: "app").error("cannot clear the boot files: \(String(describing: error), privacy: .public)")
            stop("Regents Cloak can't open.", "Quit Regents Cloak, then open it again.")
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
