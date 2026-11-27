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
    static let changelogURL = URL(string: "https://github.com/regents-ai/cloak/releases")!

    private lazy var userDriver = CloakUpdateUserDriver(hostBundle: .main, delegate: self)
    private lazy var updater = SPUUpdater(
        hostBundle: .main,
        applicationBundle: .main,
        userDriver: userDriver,
        delegate: self)
    private let logger = Logger(subsystem: "sh.regents.cloak.app", category: "updates")

    private let updatesEnabled = !Places.isDev && Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil

    /// Started once its User-Agent is set, so no check goes out with
    /// Sparkle's own, which names the app and its version. Disabled completely
    /// in isolated `Cloak Dev.app` builds so they never compete with release updates.
    override init() {
        super.init()
        guard updatesEnabled else { return }
        updater.userAgentString = "curl/8.7.1"
        do {
            try updater.start()
        } catch {
            logger.error("updater could not start: \(String(describing: error), privacy: .public)")
        }
    }

    /// Whether Sparkle checks by itself, once a day. Off until the person
    /// answers Sparkle's question or turns it on.
    var checksAutomatically: Bool {
        get { updatesEnabled ? updater.automaticallyChecksForUpdates : false }
        set {
            guard updatesEnabled else { return }
            updater.automaticallyChecksForUpdates = newValue
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
            alert.accessoryView = ChangelogLinkAccessory(url: Self.changelogURL)
            alert.runModal()
            AppWindow.leaveDock()
            return
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        updater.checkForUpdates()
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

    func standardUserDriverShouldShowVersionHistory(for item: SUAppcastItem) -> Bool {
        true
    }

    func standardUserDriverShowVersionHistory(for item: SUAppcastItem) {
        NSWorkspace.shared.open(item.fullReleaseNotesURL ?? Self.changelogURL)
    }

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

/// Thin `SPUStandardUserDriver` subclass that preserves every standard Sparkle
/// dialog while adding a clickable "View Changelog" hyperlink directly inside
/// the "You're up to date!" alert.
private final class CloakUpdateUserDriver: SPUStandardUserDriver {
    override func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        let nsError = error as NSError
        let reason = (nsError.userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber)?.intValue
        let isUpToDate = reason == Int(SPUNoUpdateFoundReason.onLatestVersion.rawValue)
            || reason == Int(SPUNoUpdateFoundReason.onNewerThanLatestVersion.rawValue)
            || reason == nil
        guard isUpToDate else {
            super.showUpdateNotFoundWithError(error, acknowledgement: acknowledgement)
            return
        }

        // Close Sparkle's "Checking for updates…" spinner cleanly before presenting our alert.
        super.dismissUpdateInstallation()
        let item = nsError.userInfo[SPULatestAppcastItemFoundKey] as? SUAppcastItem
        let url = item?.fullReleaseNotesURL

        MainActor.assumeIsolated {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert(error: nsError)
            alert.alertStyle = .informational
            alert.icon = NSApp.applicationIconImage
            alert.accessoryView = ChangelogLinkAccessory(url: url ?? Updates.changelogURL)
            alert.runModal()
            AppWindow.leaveDock()
        }
        acknowledgement()
    }
}

/// Centered clickable "View Changelog" link accessory for macOS `NSAlert`.
@MainActor
private final class ChangelogLinkAccessory: NSView {
    private let url: URL

    init(url: URL) {
        self.url = url
        super.init(frame: NSRect(x: 0, y: 0, width: 220, height: 22))
        let button = LinkCursorButton(frame: bounds)
        button.isBordered = false
        button.target = self
        button.action = #selector(openChangelog)
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        button.attributedTitle = NSAttributedString(
            string: "View Changelog",
            attributes: [
                .foregroundColor: NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium),
                .paragraphStyle: style,
            ]
        )
        button.setAccessibilityLabel("View Changelog")
        button.setAccessibilityHelp("Opens Cloak's release notes on GitHub.")
        button.autoresizingMask = [.width, .height]
        addSubview(button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func openChangelog() {
        NSWorkspace.shared.open(url)
    }
}

private final class LinkCursorButton: NSButton {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
