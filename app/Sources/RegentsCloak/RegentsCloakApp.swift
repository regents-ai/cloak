import AppKit
import CloakControl
import CloakSupervisor
import os
import SwiftUI

/// The menu-bar app: one supervisor, its menu, its Chat and Details windows,
/// and the control channel `cloak` uses to drive the same supervisor.
@main
struct RegentsCloakApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var app

    var body: some Scene {
        MenuBarExtra {
            MenuContent(supervisor: app.supervisor, showChat: app.showChat, showDetails: app.showDetails)
        } label: {
            MenuLabel(phase: app.supervisor.phase)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let supervisor = Launch.supervisor
    private lazy var chat = AppWindow { [supervisor] in
        ChatView.window(Chat(supervisor: supervisor, folder: Launch.layout.conversations, wallet: Launch.layout.wallet))
    }
    private lazy var details = AppWindow { [supervisor] in DetailsView.window(supervisor) }
    private var server: ControlServer?
    private let logger = Logger(subsystem: "sh.regents.cloak.app", category: "app")

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            server = try ControlServer(path: Places.socket) { [supervisor] request in
                await supervisor.handle(request)
            }
        } catch {
            logger.error("cannot serve the control channel: \(String(describing: error), privacy: .public)")
            Launch.stop("Regents Cloak can't open.", "Quit Regents Cloak, then open it again.")
        }
        // Sleep pauses, so a wake finds nothing running and starts nothing.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [supervisor] _ in
            MainActor.assumeIsolated { _ = supervisor.send(.sleep) }
        }
    }

    func showChat() {
        chat.show()
    }

    func showDetails() {
        details.show()
    }

    /// Quit, from the menu or the system, goes through the one shutdown.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        supervisor.quit { [server] in
            server?.close()
            NSApp.reply(toApplicationShouldTerminate: true)
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
            return try Supervisor(manifest: manifest, layout: layout)
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
