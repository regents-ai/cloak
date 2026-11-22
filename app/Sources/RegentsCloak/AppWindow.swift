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

    init(_ make: @escaping () -> NSWindow) {
        self.make = make
    }

    func show() {
        let window = self.window ?? make()
        if self.window == nil {
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        Self.leaveDock(closing: notification.object as? NSWindow)
    }

    /// Makes the app a menu-bar app again, unless one of its windows other
    /// than `closing` is open.
    static func leaveDock(closing: NSWindow? = nil) {
        guard !NSApp.windows.contains(where: { $0 !== closing && $0 is ClosingWindow && $0.isVisible }) else { return }
        NSApp.setActivationPolicy(.accessory)
    }
}

/// A menu-bar app has no menus of its own, so the window closes itself on
/// Command-W, and on Escape unless it has a use of its own for it.
final class ClosingWindow: NSWindow {
    var closesOnEscape = true

    override func cancelOperation(_ sender: Any?) {
        if closesOnEscape { close() }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
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
