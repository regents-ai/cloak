import AppKit
import CloakChat
import CloakControl
import CloakDoor
import CloakSupervisor
import os
import SwiftUI

/// The menu-bar app: one supervisor, the model's download, its menu, its
/// Chat, Agents and Details windows, a welcome on the first launch, the door
/// other apps and the agent in the guest send through while Cloak is
/// Running, and the control channel `cloak` uses to drive the same
/// supervisor.
@main
struct RegentsCloakApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var app

    // The menu is AppKit's (`StatusMenu`); this scene shows nothing, and
    // takes no place in the app's menus.
    var body: some Scene {
        Settings { EmptyView() }
            .commands { CommandGroup(replacing: .appSettings) {} }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let supervisor = Launch.supervisor
    let download = ModelDownload(manifest: Launch.manifest, layout: Launch.layout)
    private lazy var chat = AppWindow { [supervisor, door, unowned self] in
        ChatView.window(
            Chat(supervisor: supervisor, folder: Launch.layout.conversations, wallet: Launch.layout.wallet, door: door),
            showDetails: { self.showDetails() })
    }
    private lazy var details = AppWindow { [supervisor, download] in DetailsView.window(supervisor, download) }
    private lazy var agents = AppWindow { [door] in AgentsView.window(door) }
    private lazy var welcome = AppWindow { WelcomeView.window() }
    private var menu: StatusMenu?
    let door: Door = {
        let supervisor = Launch.supervisor, conversations = Launch.layout.conversations
        return Door(
            file: Launch.layout.agents, wallet: Launch.layout.wallet,
            parts: Door.Parts(
                reword: { texts throws(RewriteStop) in try await supervisor.rewrite(texts) },
                exchange: { request, keep in try await supervisor.exchange(request: request, keep: keep) },
                wallet: { try await WalletKeychain.address() },
                key: { try WalletKeychain.key() },
                sealing: { try await ConversationStore.key(for: conversations, find: Keychain.find, make: Keychain.make) }))
    }()
    private var server: ControlServer?
    private let logger = Logger(subsystem: "sh.regents.cloak.app", category: "app")

    func applicationDidFinishLaunching(_ notification: Notification) {
        menu = StatusMenu(
            supervisor: supervisor, download: download, showChat: showChat, showAgents: showAgents, showDetails: showDetails)
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
        // Sleep pauses, so a wake finds nothing running and starts nothing.
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

    /// Quit, from the menu or the system, goes through the one shutdown,
    /// and ends once every app with a request under way has been answered.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        supervisor.quit { [server, door] in
            server?.close()
            Task {
                await door.close()
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
            return try Supervisor(manifest: manifest, layout: layout) { FreeMemory.chosen.after }
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
