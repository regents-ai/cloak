import AppKit
import SwiftUI

/// Cloak's tooltip, for every tooltip in the app. macOS draws its own with
/// the words hard against the border and gives no way to change that, so
/// Cloak draws this one: the same words at the same size, with 10 points
/// of room each side and 7 above and below.
///
/// One panel shows them all (`TipPanel`). A tip comes up under the pointer
/// once it has rested on a view for 0.7 seconds, or after 0.1 where another
/// tip went within the last half second, so moving along a row of symbols
/// names each in turn. It goes when the pointer leaves, on any click, key
/// or scroll, when a menu closes and when Cloak stops being the app in
/// front. It never takes a click or the keyboard.
///
/// The words are the view's hint for VoiceOver too, as `help` made them.
private struct Tip: ViewModifier {
    let words: String
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .accessibilityHint(words)
            .onHover { inside in
                if inside {
                    TipPanel.shared.rest(id, words)
                } else {
                    TipPanel.shared.leave(id)
                }
            }
            // Words that change under a resting pointer, as a countdown's do.
            .onChange(of: words) { TipPanel.shared.reword(id, words) }
            // A view taken away under the pointer is never told it left.
            .onDisappear { TipPanel.shared.leave(id) }
    }
}

extension View {
    /// Cloak's tooltip: `words` under the pointer once it rests here. No
    /// words, no tip.
    func tip(_ words: String) -> some View {
        modifier(Tip(words: words))
    }
}

/// The same tip for an AppKit view, as the menu's header has two. Whoever
/// makes it keeps it for as long as the view lasts.
@MainActor
final class TipArea: NSObject {
    var words = ""
    private let id = UUID()

    init(on view: NSView) {
        super.init()
        // A menu's views are in no key window and Cloak is not in front
        // while its menu is open, so the area is always active.
        view.addTrackingArea(
            NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    @objc func mouseEntered(with event: NSEvent) {
        TipPanel.shared.rest(id, words)
    }

    @objc func mouseExited(with event: NSEvent) {
        TipPanel.shared.leave(id)
    }
}

/// The one panel every tip shows in, and whose tip it is.
@MainActor
final class TipPanel {
    static let shared = TipPanel()

    private enum Stage {
        /// No tip, and none on its way.
        case away
        /// The pointer rests on a view; its tip shows when the wait ends.
        case resting(UUID, Task<Void, Never>)
        case showing(UUID)

        var owner: UUID? {
            switch self {
            case .away: nil
            case .resting(let id, _), .showing(let id): id
            }
        }
    }

    private var stage = Stage.away
    /// When the last tip went, which makes the next one quick.
    private var went: ContinuousClock.Instant?
    private let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    private let host = NSHostingController(rootView: TipWords(words: ""))

    private init() {
        // The panel is sized here, from its words (`show`); the view never
        // sizes it.
        host.sizingOptions = []
        panel.contentView = host.view
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        // The menu's tips show while Cloak is not the app in front.
        panel.hidesOnDeactivate = false
        // Over a menu, a popover and a sheet, where macOS puts its own.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.helpWindow)))
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.animationBehavior = .none

        // All three last as long as the app, as this does.
        _ = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel]) {
            [weak self] event in
            MainActor.assumeIsolated { self?.hide() }
            return event
        }
        for name in [NSApplication.didResignActiveNotification, NSMenu.didEndTrackingNotification] {
            _ = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.hide() }
            }
        }
    }

    /// The pointer came to rest on `id`'s view.
    func rest(_ id: UUID, _ words: String) {
        hide()
        guard !words.isEmpty else { return }
        let quick = went.map { .now - $0 < .milliseconds(500) } == true
        stage = .resting(
            id,
            Task {
                // Sleeping throws once cancelled, so a pointer that leaves
                // first never shows it.
                guard (try? await Task.sleep(for: .milliseconds(quick ? 100 : 700))) != nil else { return }
                show(id, words)
            })
    }

    /// The words under a pointer that is still on `id`'s view changed.
    func reword(_ id: UUID, _ words: String) {
        guard case .showing(id) = stage else { return }
        if words.isEmpty {
            hide()
        } else {
            show(id, words)
        }
    }

    /// The pointer left `id`'s view, or the view went.
    func leave(_ id: UUID) {
        if stage.owner == id { hide() }
    }

    private func show(_ id: UUID, _ words: String) {
        stage = .showing(id)
        host.rootView = TipWords(words: words)
        // As wide as its words up to the widest box, and as tall as they
        // then wrap to.
        let size = host.sizeThatFits(in: NSSize(width: TipWords.widest, height: .greatestFiniteMagnitude))
        panel.setFrame(Self.frame(for: size, at: NSEvent.mouseLocation), display: true)
        panel.invalidateShadow()
        panel.orderFrontRegardless()
    }

    private func hide() {
        switch stage {
        case .away: return
        case .resting(_, let wait): wait.cancel()
        case .showing:
            panel.orderOut(nil)
            went = .now
        }
        stage = .away
    }

    /// Under the pointer and clear of its arrow, its leading edge at the
    /// pointer; above the pointer where there is no room under it, and
    /// moved in from the screen's edges.
    static func frame(for size: NSSize, at pointer: NSPoint) -> NSRect {
        var origin = NSPoint(x: pointer.x, y: pointer.y - 22 - size.height)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) })?.visibleFrame else {
            return NSRect(origin: origin, size: size)
        }
        if origin.y < screen.minY + 4 { origin.y = pointer.y + 10 }
        origin.x = max(screen.minX + 4, min(origin.x, screen.maxX - 4 - size.width))
        return NSRect(origin: origin, size: size)
    }
}

/// A tip's words and the box round them: the Mac's own tooltip size, with
/// 10 points of room each side and 7 above and below. It is as wide as its
/// words, which wrap where whoever sizes it stops them (`widest`).
struct TipWords: View {
    /// The box at its widest, its room included.
    static let widest: CGFloat = 280

    let words: String

    var body: some View {
        let box = RoundedRectangle(cornerRadius: 7, style: .continuous)
        Text(words)
            .font(.system(size: NSFont.smallSystemFontSize))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color(nsColor: .windowBackgroundColor), in: box)
            .overlay { box.strokeBorder(.separator) }
            // The view it names reads the words out; the panel says nothing.
            .accessibilityHidden(true)
    }
}
