import AppKit
import Foundation
import os

/// Prompts users who launched `Cloak.app` directly from a mounted DMG
/// (`/Volumes/…`), macOS App Translocation, `~/Downloads`, or `~/Desktop`
/// to move Cloak into `/Applications` (or `~/Applications`) in one click and
/// relaunch cleanly. Automatically skips development builds (`app/build/`,
/// `.build/`, `DerivedData`, `repos/`).
@MainActor
enum MoveToApplications {
    private static let logger = Logger(subsystem: "sh.regents.cloak.app", category: "install")
    private static let suppressKey = "suppressMoveToApplications"

    /// Returns true if the app moved and relaunched (so the caller should skip
    /// opening first-launch UI in the exiting process).
    @discardableResult
    static func promptIfNeeded() -> Bool {
        guard !UserDefaults.standard.bool(forKey: suppressKey) else { return false }
        let bundleURL = Bundle.main.bundleURL.standardizedFileURL
        guard shouldPrompt(for: bundleURL) else { return false }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Move Cloak to your Applications folder?"
        alert.informativeText =
            "Running Cloak from Applications keeps automatic updates working and prevents Cloak from disappearing after you eject the disk image or restart."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"

        let response = alert.runModal()
        if alert.suppressionButton?.state == .on {
            UserDefaults.standard.set(true, forKey: suppressKey)
        }
        guard response == .alertFirstButtonReturn else { return false }

        do {
            let destination = try installCopy(from: bundleURL)
            relaunchAndQuit(at: destination, previous: bundleURL)
            return true
        } catch {
            logger.error("move to Applications failed: \(String(describing: error), privacy: .public)")
            let failed = NSAlert()
            failed.alertStyle = .warning
            failed.messageText = "Couldn't move Cloak automatically"
            failed.informativeText = "Drag Cloak.app into your Applications folder in Finder, then open it from there."
            failed.runModal()
            return false
        }
    }

    /// Pure path check so unit tests and dev builds are never interrupted.
    static func shouldPrompt(for bundleURL: URL) -> Bool {
        let path = bundleURL.path
        guard bundleURL.pathExtension == "app" else { return false }

        // Already in system or user Applications.
        let userApps = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications").path
        if path.hasPrefix("/Applications/") || path.hasPrefix(userApps + "/") {
            return false
        }

        // Never nag developers running local builds from a repo or Xcode.
        let devMarkers = ["/app/build/", "/.build/", "/DerivedData/", "/Build/Products/", "/repos/"]
        if devMarkers.contains(where: { path.contains($0) }) {
            return false
        }

        // Only prompt for real user-install danger zones: mounted DMG,
        // Gatekeeper App Translocation, ~/Downloads, or ~/Desktop.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix("/Volumes/")
            || path.contains("/AppTranslocation/")
            || path.hasPrefix(home + "/Downloads/")
            || path.hasPrefix(home + "/Desktop/")
    }

    private static func installCopy(from source: URL) throws -> URL {
        let fm = FileManager.default
        let systemApps = URL(filePath: "/Applications", directoryHint: .isDirectory)
        let targetDir: URL
        if fm.isWritableFile(atPath: systemApps.path) {
            targetDir = systemApps
        } else {
            let userApps = fm.homeDirectoryForCurrentUser.appending(path: "Applications", directoryHint: .isDirectory)
            try fm.createDirectory(at: userApps, withIntermediateDirectories: true)
            targetDir = userApps
        }

        let appName = source.lastPathComponent
        let destination = targetDir.appending(path: appName)
        let staging = targetDir.appending(path: ".\(appName).\(UUID().uuidString).staging")
        defer { try? fm.removeItem(at: staging) }

        // `ditto` preserves Frameworks, Sparkle XPC symlinks, and code signatures.
        let copy = Process()
        copy.executableURL = URL(filePath: "/usr/bin/ditto")
        copy.arguments = [source.path, staging.path]
        try copy.run()
        copy.waitUntilExit()
        guard copy.terminationStatus == 0 else {
            throw NSError(domain: "sh.regents.cloak.move", code: Int(copy.terminationStatus))
        }

        // Best-effort clear quarantine so the moved copy opens without a second translocation.
        let xattr = Process()
        xattr.executableURL = URL(filePath: "/usr/bin/xattr")
        xattr.arguments = ["-dr", "com.apple.quarantine", staging.path]
        try? xattr.run()
        xattr.waitUntilExit()

        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: destination)
        }
        return destination
    }

    private static func relaunchAndQuit(at destination: URL, previous: URL) {
        // Spawn a tiny detached helper that waits for this PID to exit so the
        // single-instance lock (`Instance.claim`) is free, then opens the new copy.
        let pid = ProcessInfo.processInfo.processIdentifier
        let destPath = destination.path
        let mountedVolume: String? = previous.path.hasPrefix("/Volumes/")
            ? previous.deletingLastPathComponent().path : nil

        let script: String
        if let volume = mountedVolume {
            script = """
                while kill -0 \(pid) 2>/dev/null; do sleep 0.1; done
                open -a "$1"
                hdiutil detach "$2" -quiet 2>/dev/null || true
                """
            let helper = Process()
            helper.executableURL = URL(filePath: "/bin/sh")
            helper.arguments = ["-c", script, "cloak-relaunch", destPath, volume]
            try? helper.run()
        } else {
            script = """
                while kill -0 \(pid) 2>/dev/null; do sleep 0.1; done
                open -a "$1"
                """
            let helper = Process()
            helper.executableURL = URL(filePath: "/bin/sh")
            helper.arguments = ["-c", script, "cloak-relaunch", destPath]
            try? helper.run()
        }

        NSApp.terminate(nil)
    }
}
