import AppKit
import CloakControl
import CloakSupervisor
import os
import SwiftUI

/// The menu-bar app: one supervisor, its menu, its Details window, and the
/// control channel `cloak` uses to drive the same supervisor.
@main
struct RegentsCloakApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var app

    var body: some Scene {
        MenuBarExtra {
            MenuContent(supervisor: app.supervisor, showDetails: app.showDetails)
        } label: {
            MenuLabel(phase: app.supervisor.phase)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let supervisor = Supervisor(manifest: Launch.manifest, layout: Layout(bundle: Bundle.main.resourceURL!, support: Places.support))
    private let details = DetailsWindow()
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

    func showDetails() {
        details.show(supervisor)
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

/// What the app needs before it can show anything: its manifest, and being
/// the only Regents Cloak running for this user.
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
