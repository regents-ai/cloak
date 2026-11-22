import AppKit
import SwiftUI

/// Cloak's tooltip, for every tooltip in the app. macOS draws its own with
/// the words hard against the border and gives no way to change that, so
/// Cloak draws this one: the same words at the same size, with 10 points
/// of room each side and 7 above and below.
///
/// One panel shows them all (`TipPanel`). A tip comes up under the pointer
/// once it has been on a view for a second and is still, or as soon as it
/// is still where another tip went within the last half second, so pausing
/// along a row of symbols names each in turn and a pointer passing over
/// shows nothing. It goes when the pointer leaves, on any click, key or
/// scroll, when a menu closes and when Cloak stops being the app in
/// front; a window of Cloak's behind another app's shows none. It never
/// takes a click or the keyboard.
///
/// The box is drawn and measured by hand (`TipBox`), with no SwiftUI view
/// and no layout constraints in the panel: a hosting view as a panel's
/// content sizes its window in passes, and for some words those passes
/// never settled, which flickered and then ended the app (21 November).
///
/// The words are the view's hint for VoiceOver too, as `help` made them.
private struct Tip: ViewModifier {
    let words: String
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .accessibilityHint(words)
            .onHover { inside in
                // None in a window behind another app's.
                if inside, NSApp.isActive {
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
        /// The pointer is on a view; its tip shows once the wait has ended
        /// and the pointer is still.
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
    private let box = TipBox(frame: .zero)

    private init() {
        panel.contentView = box
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

    /// The pointer came onto `id`'s view.
    func rest(_ id: UUID, _ words: String) {
        hide()
        guard !words.isEmpty else { return }
        let quick = went.map { .now - $0 < .milliseconds(500) } == true
        stage = .resting(
            id,
            Task {
                // Sleeping throws once cancelled, so a pointer that leaves
                // first never shows it.
                if !quick {
                    guard (try? await Task.sleep(for: .milliseconds(880))) != nil else { return }
                }
                // Then once the pointer is where it was a moment ago, so
                // nothing comes up under one that is passing over.
                var place: NSPoint
                repeat {
                    place = NSEvent.mouseLocation
                    guard (try? await Task.sleep(for: .milliseconds(120))) != nil else { return }
                } while NSEvent.mouseLocation != place
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
        box.words = words
        panel.setFrame(Self.frame(for: TipBox.size(for: words), at: NSEvent.mouseLocation), display: true)
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
/// 10 points of room each side and 7 above and below. The box is as wide
/// as its words, which wrap at 260 points. Drawn by hand, and measured by
/// the same call that draws, so the two always agree.
final class TipBox: NSView {
    private static let room = NSSize(width: 10, height: 7)
    private static let widest: CGFloat = 260
    private static let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]

    var words = "" {
        didSet { needsDisplay = true }
    }

    private static func text(_ words: String) -> NSAttributedString {
        NSAttributedString(
            string: words,
            attributes: [.font: NSFont.toolTipsFont(ofSize: 0), .foregroundColor: NSColor.labelColor])
    }

    /// The box `words` need.
    static func size(for words: String) -> NSSize {
        let text = text(words).boundingRect(with: NSSize(width: widest, height: .greatestFiniteMagnitude), options: options).size
        return NSSize(width: ceil(text.width) + 2 * room.width, height: ceil(text.height) + 2 * room.height)
    }

    // Text is laid out from the top down.
    override var isFlipped: Bool { true }

    // Colours are read as it draws, so it follows a change to light or dark.
    override func draw(_ dirtyRect: NSRect) {
        let edge = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        NSColor.windowBackgroundColor.setFill()
        edge.fill()
        NSColor.separatorColor.setStroke()
        edge.stroke()
        Self.text(words).draw(with: bounds.insetBy(dx: Self.room.width, dy: Self.room.height), options: Self.options)
    }

    // The view it names reads the words out; the panel says nothing.
    override func isAccessibilityElement() -> Bool { false }
}
