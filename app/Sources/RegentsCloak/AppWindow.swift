import AppKit
import SwiftUI

/// One of the app's windows, made the first time it is shown and kept.
///
/// A menu-bar app is never the app in front, so its window would open behind
/// the one in front. While one of its windows is open the app is an ordinary
/// one, with a Dock icon, so it comes to the front with the window, which
/// takes the keyboard; closing the last one makes it a menu-bar app again,
/// still running. It comes to the front whatever app is there, since the
/// person asked for it: chosen with the menu's Command-D, the polite
/// `activate()` left it behind.
@MainActor
final class AppWindow: NSObject, NSWindowDelegate {
    private let make: () -> NSWindow
    private var window: NSWindow?
    var onBecomeKey: (() -> Void)?
    var onWillClose: (() -> Void)?

    init(_ make: @escaping () -> NSWindow) {
        self.make = make
    }

    /// True when this window is visible and currently frontmost/key in the active app.
    var isVisibleAndKey: Bool {
        NSApp.isActive && window?.isVisible == true && window?.isKeyWindow == true
    }

    func show() {
        let window = self.window ?? make()
        if self.window == nil {
            window.isReleasedWhenClosed = false
            window.delegate = self
            let autosave = window.frameAutosaveName
            if autosave.isEmpty || !window.setFrameUsingName(autosave) {
                window.center()
            }
            self.window = window
        }
        let wasAccessory = NSApp.activationPolicy() != .regular
        NSApp.setActivationPolicy(.regular)
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if wasAccessory {
            // Promoting an LSUIElement app from .accessory to .regular completes
            // asynchronously with WindowServer; re-assert key/front on the next
            // turn so windows opened from the menu bar always come to front.
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        onBecomeKey?()
    }

    func windowWillClose(_ notification: Notification) {
        onWillClose?()
        Self.leaveDock(closing: notification.object as? NSWindow)
    }

    /// Makes the app a menu-bar app again, unless one of its windows other
    /// than `closing` is still open or minimized (including updater windows).
    static func leaveDock(closing: NSWindow? = nil) {
        let keepsDock = NSApp.windows.contains { window in
            guard window !== closing, !(window is NSPanel) else { return false }
            if window is ClosingWindow { return window.isVisible || window.isMiniaturized }
            // Keep Dock active while a non-panel window (such as Sparkle's updater)
            // is open on screen.
            return window.isVisible && window.canBecomeMain && !window.title.isEmpty
        }
        guard !keepsDock else { return }
        NSApp.setActivationPolicy(.accessory)
    }
}

/// A menu-bar app has no menus of its own, so the window closes itself on
/// Command-W, and on Escape unless it has a use of its own for it.
final class ClosingWindow: NSWindow {
    var closesOnEscape = true
    var onKeyEquivalent: ((NSEvent) -> Bool)?

    override func cancelOperation(_ sender: Any?) {
        if closesOnEscape { close() }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let onKeyEquivalent, onKeyEquivalent(event) {
            return true
        }
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, event.charactersIgnoringModifiers == "w" {
            close()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Runs its action each time the view's own window comes back in front:
/// from behind another window or another app, or shown again after it was
/// closed. A note or a menu opened over the window is no return, and
/// neither is another of Cloak's windows coming forward.
private struct OnReturn: ViewModifier {
    let action: () -> Void
    @Environment(\.appearsActive) private var inFront

    func body(content: Content) -> some View {
        content.onChange(of: inFront) { if inFront { action() } }
    }
}

extension View {
    /// What can change while the window is away is read again as it comes
    /// back.
    func onReturn(perform action: @escaping () -> Void) -> some View {
        modifier(OnReturn(action: action))
    }
}
