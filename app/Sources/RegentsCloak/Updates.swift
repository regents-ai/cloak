import AppKit
import CloakControl
import os
import Sparkle
import SwiftUI

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
    nonisolated static let changelogURL = URL(string: "https://github.com/regents-ai/cloak/releases")!

    private let statusPresenter = UpdateStatusPresenter()
    private lazy var userDriver = CloakUpdateUserDriver(
        hostBundle: .main,
        delegate: self,
        statusPresenter: statusPresenter)
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
            statusPresenter.show(
                title: "Updates Disabled in Cloak Dev",
                message:
                    "This is an isolated local test build (sh.regents.cloak.dev). Your release Cloak.app in /Applications updates independently through the normal channel.",
                changelogURL: Self.changelogURL,
                onDismiss: {}
            )
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

/// Thin `SPUStandardUserDriver` subclass that replaces Sparkle's blocking
/// `NSAlert.runModal()` dialogs ("You're up to date!" and updater errors) with
/// a non-modal native window that also includes a clickable "View Changelog"
/// link. Avoiding `NSAlert.runModal()` inside Sparkle's `DispatchQueue.main`
/// callbacks prevents deadlocking `@MainActor` tasks and locking out the
/// menu bar panel if the user switches apps or opens the changelog in a browser.
private final class CloakUpdateUserDriver: SPUStandardUserDriver {
    private let statusPresenter: UpdateStatusPresenter

    init(hostBundle: Bundle, delegate: (any SPUStandardUserDriverDelegate)?, statusPresenter: UpdateStatusPresenter) {
        self.statusPresenter = statusPresenter
        super.init(hostBundle: hostBundle, delegate: delegate)
    }

    override func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        let nsError = error as NSError
        let reason = (nsError.userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber)?.intValue
        let isUpToDate = reason == Int(SPUNoUpdateFoundReason.onLatestVersion.rawValue)
            || reason == Int(SPUNoUpdateFoundReason.onNewerThanLatestVersion.rawValue)
            || reason == nil

        // Close Sparkle's "Checking for updates…" spinner cleanly before presenting our status window.
        super.dismissUpdateInstallation()
        let item = nsError.userInfo[SPULatestAppcastItemFoundKey] as? SUAppcastItem
        let changelogURL = isUpToDate ? (item?.fullReleaseNotesURL ?? Updates.changelogURL) : item?.fullReleaseNotesURL
        let title = nsError.localizedDescription.isEmpty ? "You’re up to date!" : nsError.localizedDescription
        let fallbackVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let message = nsError.localizedRecoverySuggestion
            ?? (fallbackVersion.isEmpty
                ? "Cloak is currently the newest version available."
                : "Cloak \(fallbackVersion) is currently the newest version available.")

        let presenter = self.statusPresenter
        nonisolated(unsafe) let ack = acknowledgement
        MainActor.assumeIsolated {
            presenter.show(
                title: title,
                message: message,
                changelogURL: changelogURL,
                onDismiss: ack
            )
        }
    }

    override func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        let nsError = error as NSError
        super.dismissUpdateInstallation()
        let title = nsError.localizedDescription.isEmpty ? "Update Error" : nsError.localizedDescription
        let parts = [nsError.localizedFailureReason, nsError.localizedRecoverySuggestion]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let message = parts.isEmpty
            ? "An error occurred while checking for updates. Please try again later."
            : parts.joined(separator: "\n\n")

        let presenter = self.statusPresenter
        nonisolated(unsafe) let ack = acknowledgement
        MainActor.assumeIsolated {
            presenter.show(
                title: title,
                message: message,
                changelogURL: nil,
                onDismiss: ack
            )
        }
    }

    override func showUpdateInFocus() {
        let presenter = self.statusPresenter
        let handled = MainActor.assumeIsolated {
            presenter.bringToFrontIfVisible()
        }
        if !handled {
            super.showUpdateInFocus()
        }
    }

    override func dismissUpdateInstallation() {
        let presenter = self.statusPresenter
        MainActor.assumeIsolated {
            presenter.dismiss()
        }
        super.dismissUpdateInstallation()
    }
}

/// Non-modal native status window for Sparkle up-to-date and error notifications.
/// Never calls `NSAlert.runModal()`, so switching apps or clicking "View Changelog"
/// can never freeze `DispatchQueue.main` or block clicks in Cloak's menu bar panel.
@MainActor
private final class UpdateStatusPresenter: NSObject, NSWindowDelegate {
    private var window: ClosingWindow?
    private var onDismiss: (() -> Void)?

    func show(title: String, message: String, changelogURL: URL?, onDismiss: @escaping () -> Void) {
        // Finish any previous status window cleanly before presenting the next one.
        dismiss()

        self.onDismiss = onDismiss

        let view = UpdateStatusView(
            title: title,
            message: message,
            changelogURL: changelogURL,
            openChangelog: { [weak self] url in
                NSWorkspace.shared.open(url)
                self?.dismiss()
            },
            close: { [weak self] in
                self?.dismiss()
            }
        )
        let hosting = NSHostingController(rootView: view)
        let fitting = hosting.sizeThatFits(in: CGSize(width: 300, height: 420))
        let width: CGFloat = 300
        let height = max(fitting.height, 180)

        let window = ClosingWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = ""
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: width, height: height))
        window.center()
        window.delegate = self
        self.window = window

        let wasAccessory = NSApp.activationPolicy() != .regular
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if wasAccessory {
            DispatchQueue.main.async { [weak window] in
                guard let window, window.isVisible else { return }
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    func bringToFrontIfVisible() -> Bool {
        guard let window, window.isVisible else { return false }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return true
    }

    func dismiss() {
        let closing = window
        window = nil
        let callback = onDismiss
        onDismiss = nil
        if let closing {
            closing.delegate = nil
            closing.orderOut(nil)
            AppWindow.leaveDock(closing: closing)
        }
        callback?()
    }

    func windowWillClose(_ notification: Notification) {
        let closed = notification.object as? NSWindow
        if closed === window {
            window = nil
        }
        let callback = onDismiss
        onDismiss = nil
        AppWindow.leaveDock(closing: closed)
        callback?()
    }
}

private struct UpdateStatusView: View {
    let title: String
    let message: String
    let changelogURL: URL?
    let openChangelog: (URL) -> Void
    let close: () -> Void
    @State private var hoveringLink = false

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 64, height: 64)

            VStack(spacing: 6) {
                Text(title)
                    .font(.headline)
                    .multilineTextAlignment(.center)

                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let changelogURL {
                Button {
                    openChangelog(changelogURL)
                } label: {
                    Text("View Changelog")
                        .font(.footnote.weight(.medium))
                        .underline()
                        .foregroundStyle(Color(nsColor: .linkColor))
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    if hovering != hoveringLink {
                        hoveringLink = hovering
                        if hovering {
                            NSCursor.pointingHand.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                }
                .onDisappear {
                    if hoveringLink {
                        hoveringLink = false
                        NSCursor.pop()
                    }
                }
                .help("Opens Cloak's release notes on GitHub.")
                .accessibilityLabel("View Changelog")
            }

            Button(action: close) {
                Text("OK")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .padding(.top, 4)
        }
        .padding(.horizontal, 22)
        .padding(.top, 4)
        .padding(.bottom, 20)
        .frame(width: 300)
    }
}
