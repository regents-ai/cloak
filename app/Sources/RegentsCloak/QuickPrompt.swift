import AppKit
import Carbon.HIToolbox
import Observation

/// The quick prompt: a small box floating in the upper third of the screen,
/// opened from any app by the shortcut chosen in Settings, and closed by
/// Escape, the shortcut again or a click elsewhere. Return takes its text to
/// a new chat in the Chat window, into the message box, exactly as if typed
/// there: nothing is sent, reworded or spent. The box takes the keyboard
/// without bringing Cloak to the front. There is no shortcut until one is
/// chosen.
@MainActor
@Observable
final class QuickPrompt {
    /// Why the shortcut last chosen isn't the one working, in plain words,
    /// naming what is still the shortcut; nil when it is, or there is none.
    private(set) var refusal: String?
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let hotKey = HotKey()
    @ObservationIgnored private let panel: PromptPanel

    /// `hand` takes the text written to a new chat. Lasts as long as the app.
    init(settings: AppSettings, hand: @escaping (String) -> Void) {
        self.settings = settings
        panel = PromptPanel(submit: hand)
        hotKey.pressed = { [unowned self] in toggle() }
        if let shortcut = settings.shortcut, !hotKey.register(shortcut) {
            refusal = "macOS didn't accept \(shortcut.title). Choose another."
        }
    }

    /// Makes `shortcut` the quick prompt's, or takes it away with nil. One
    /// macOS refuses changes nothing kept: the shortcut before it stays,
    /// and still works if it did.
    func choose(_ shortcut: Shortcut?) {
        guard let shortcut else {
            hotKey.clear()
            refusal = nil
            settings.shortcut = nil
            return
        }
        // The shortcut already working needs nothing, and macOS may refuse
        // to take it a second time.
        guard shortcut != settings.shortcut || !hotKey.holds else {
            refusal = nil
            return
        }
        guard hotKey.register(shortcut) else {
            refusal = switch (settings.shortcut, hotKey.holds) {
            case (let kept?, true): "macOS didn't accept \(shortcut.title). \(kept.title) is still the shortcut."
            case (let kept?, false): "macOS didn't accept \(shortcut.title) or \(kept.title). Choose another."
            case (nil, _): "macOS didn't accept \(shortcut.title). Choose another."
            }
            return
        }
        refusal = nil
        settings.shortcut = shortcut
    }

    func toggle() {
        if panel.isVisible { panel.dismiss() } else { panel.present() }
    }
}

/// One shortcut for the whole system, through Carbon's hot keys, which need
/// no Accessibility permission. `pressed` runs at each press. Lasts as long
/// as the app, so its handler is never removed.
@MainActor
private final class HotKey {
    var pressed: () -> Void = {}
    private var registered: EventHotKeyRef?

    init() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            // Carbon calls it on the main thread, from the app's event loop.
            MainActor.assumeIsolated {
                Unmanaged<HotKey>.fromOpaque(context!).takeUnretainedValue().pressed()
            }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), nil)
        precondition(installed == noErr, "the quick prompt's key handler was not installed")
    }

    /// Whether a shortcut is registered now, and so works.
    var holds: Bool { registered != nil }

    /// Registers `shortcut` in place of the one before; false, with the one
    /// before kept, when the system refuses it.
    func register(_ shortcut: Shortcut) -> Bool {
        var made: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x434C_4B51), id: 1)  // "CLKQ"
        guard RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &made) == noErr else {
            return false
        }
        clear()
        registered = made
        return true
    }

    /// Unregisters the shortcut, if there is one.
    func clear() {
        if let registered { UnregisterEventHotKey(registered) }
        registered = nil
    }
}

/// The quick prompt's box: one line of text on glass, in a borderless panel
/// that takes the keyboard without making Cloak the app in front, over
/// whichever Space or full-screen app is shown. Return closes it, then hands
/// the text on.
private final class PromptPanel: NSPanel, NSTextFieldDelegate {
    private static let size = NSSize(width: 640, height: 56)
    private let field = NSTextField()
    private let submit: (String) -> Void

    init(submit: @escaping (String) -> Void) {
        self.submit = submit
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true

        field.placeholderAttributedString = NSAttributedString(
            string: "Message",
            attributes: [
                .font: NSFont.systemFont(ofSize: 20),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        field.setAccessibilityLabel("Message")
        field.font = .systemFont(ofSize: 20)
        field.textColor = .labelColor
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView(frame: NSRect(origin: .zero, size: Self.size))
        content.autoresizingMask = [.width, .height]
        content.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            field.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        let glass = NSGlassEffectView()
        glass.cornerRadius = 16
        glass.contentView = content
        contentView = glass
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Opens empty, centred across the screen in front and in its upper
    /// third.
    func present() {
        guard let screen = NSScreen.main else { return }
        let area = screen.visibleFrame
        setFrameOrigin(NSPoint(x: area.midX - Self.size.width / 2, y: area.minY + area.height * 0.75 - Self.size.height / 2))
        makeKeyAndOrderFront(nil)
        makeFirstResponder(field)
    }

    /// Closes, forgetting the text.
    func dismiss() {
        orderOut(nil)
        field.stringValue = ""
    }

    // A click elsewhere closes it, as Spotlight's does.
    override func resignKey() {
        super.resignKey()
        dismiss()
    }

    /// Standard Edit shortcuts when Cloak runs in `.accessory` mode with no main menu.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        if flags == .command {
            switch key {
            case "v": return NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self)
            case "c": return NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self)
            case "x": return NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self)
            case "a": return NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self)
            case "z": return NSApp.sendAction(Selector(("undo:")), to: nil, from: self)
            default: break
            }
        } else if flags == [.command, .shift], key == "z" {
            return NSApp.sendAction(Selector(("redo:")), to: nil, from: self)
        }
        return super.performKeyEquivalent(with: event)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            let text = field.stringValue
            dismiss()
            submit(text)
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss()
        default:
            return false
        }
        return true
    }
}
