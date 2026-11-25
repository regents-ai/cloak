import AppKit
import CloakControl
import os
import Sparkle

/// Updates, through Sparkle: its window, its own setting for checking by
/// itself (`checksAutomatically`; Sparkle keeps it and asks the person on
/// the app's second launch), and Check for Updates… in the menu. The feed
/// and the update key's public half are in the bundle's Info.plist
/// (`SUFeedURL`, `SUPublicEDKey`), written by app/build.sh from
/// app/release.json.
///
/// What the spec asks of it (UPD01, UPD02, NET09):
/// - A check is maintenance traffic and never carries task content. It goes
///   straight from this Mac to the feed's host, not through Tor or the
///   door, with the generic User-Agent the model's download sends
///   (`ModelDownload`), and with no system profile: the bundle has no
///   `SUEnableSystemProfiling`, so Sparkle never offers to send one.
/// - An update never resumes anything by itself. Sparkle replaces the app
///   once it has quit through its one shutdown (`applicationShouldTerminate`
///   in `AppDelegate`), and the new app opens Paused, as every launch does
///   (`Phase`, and `Supervisor.phase`'s first value).
/// - An update is taken only with a signature Sparkle checks: an EdDSA
///   signature for the bundle's `SUPublicEDKey`, or, so that key can be
///   changed, a code signature that matches the installed app's. A
///   development build is signed ad hoc, which no other build matches, so
///   there the EdDSA signature is the only way in. Nothing here changes
///   how Sparkle checks either.
///
/// Gentle reminders, and a Dock icon while Sparkle's window shows, follow
/// the Llama app (decision 14 in docs/plan.md).
@MainActor
final class Updates: NSObject {
    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
    private let logger = Logger(subsystem: "sh.regents.cloak.app", category: "updates")

    private let updatesEnabled = !Places.isDev && Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil

    /// Started once its User-Agent is set, so no check goes out with
    /// Sparkle's own, which names the app and its version. Disabled completely
    /// in isolated `Cloak Dev.app` builds so they never compete with release updates.
    override init() {
        super.init()
        guard updatesEnabled else { return }
        controller.updater.userAgentString = "curl/8.7.1"
        controller.startUpdater()
    }

    /// Whether Sparkle checks by itself, once a day. Off until the person
    /// answers Sparkle's question or turns it on.
    var checksAutomatically: Bool {
        get { updatesEnabled ? controller.updater.automaticallyChecksForUpdates : false }
        set {
            guard updatesEnabled else { return }
            controller.updater.automaticallyChecksForUpdates = newValue
        }
    }

    /// Checks now, in Sparkle's window, with the app in front.
    func check() {
        guard updatesEnabled else {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "Updates Disabled in Cloak Dev"
            alert.informativeText =
                "This is an isolated local test build (sh.regents.cloak.dev). Your release Cloak.app in /Applications updates independently through the normal channel."
            alert.runModal()
            AppWindow.leaveDock()
            return
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }
}

extension Updates: @preconcurrency SPUUpdaterDelegate {
    /// A check, download or install that failed, by its error's domain and
    /// code only: never its words, which can hold the feed's address or a
    /// file's path. Finding no update is not a failure.
    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        let error = error as NSError
        guard !(error.domain == SUSparkleErrorDomain && error.code == Int(SUError.noUpdateError.rawValue)) else { return }
        logger.error("update stopped: \(error.domain, privacy: .public) \(error.code, privacy: .public)")
    }
}

extension Updates: @preconcurrency SPUStandardUserDriverDelegate {
    /// A scheduled check that finds an update shows it without taking the
    /// keyboard from the app in front.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// A menu-bar app's window would open behind the one in front, so the
    /// app has a Dock icon while Sparkle shows an update.
    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        NSApp.setActivationPolicy(.regular)
    }

    /// Back to the menu bar once Sparkle is done, unless one of the app's
    /// own windows is open.
    func standardUserDriverWillFinishUpdateSession() {
        AppWindow.leaveDock()
    }
}
