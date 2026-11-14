import AppKit
import SwiftUI

/// A text box on NSTextView, for what SwiftUI's own cannot do: marks on words
/// that follow the text as it is edited, and Return that submits while
/// Shift-Return starts a new line. It grows with its text up to `maxHeight`,
/// then scrolls; Tab moves to the next control.
struct TextBox: NSViewRepresentable {
    /// How a marked word looks. Each has a line of its own shape besides its
    /// colour, so the marks never rest on colour alone.
    enum Mark {
        /// Lightly tinted red, with a dotted underline: quiet enough that an
        /// original whose words were nearly all taken out still reads easily.
        case removed
        /// Tinted green, with a solid underline.
        case added

        var tint: NSColor {
            switch self {
            case .removed: .systemRed
            case .added: .systemGreen
            }
        }

        var attributes: [NSAttributedString.Key: Any] {
            switch self {
            case .removed:
                [.backgroundColor: tint.withAlphaComponent(0.12),
                 .underlineStyle: NSUnderlineStyle([.single, .patternDot]).rawValue, .underlineColor: tint]
            case .added:
                [.backgroundColor: tint.withAlphaComponent(0.2), .underlineStyle: NSUnderlineStyle.single.rawValue,
                 .underlineColor: tint]
            }
        }
    }

    @Binding var text: String
    let label: String
    var editable = true
    var marks: [NSRange] = []
    var mark = Mark.added
    var maxHeight: CGFloat = 320
    /// Takes the keyboard when it first appears.
    var autofocus = false
    /// When set, Return calls it and Shift-Return starts a new line.
    var submit: (() -> Void)?

    private static let font = NSFont.systemFont(ofSize: 13)
    private static let inset = NSSize(width: 2, height: 6)

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> PassingScrollView {
        let textView = NSTextView(usingTextLayoutManager: false)
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.drawsBackground = false
        textView.font = Self.font
        textView.textContainerInset = Self.inset
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)

        let scrollView = PassingScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        if autofocus {
            DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        }
        return scrollView
    }

    func updateNSView(_ scrollView: PassingScrollView, context: Context) {
        context.coordinator.box = self
        let textView = scrollView.textView
        textView.isEditable = editable && context.environment.isEnabled
        textView.setAccessibilityLabel(label)
        if textView.string != text { textView.string = text }
        // Marks wait while a character is being composed.
        guard !textView.hasMarkedText(), let storage = textView.textStorage else { return }
        let plain: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: NSColor.textColor]
        storage.beginEditing()
        storage.setAttributes(plain, range: NSRange(location: 0, length: storage.length))
        for range in marks where NSMaxRange(range) <= storage.length {
            storage.addAttributes(mark.attributes, range: range)
        }
        storage.endEditing()
        textView.typingAttributes = plain
    }

    /// As wide as offered, as tall as the text laid out at that width. The
    /// text is measured on a copy: SwiftUI also offers widths it never gives
    /// (none at all, or unbounded), and the box's own layout must keep
    /// following the width it really has.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView scrollView: PassingScrollView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, let storage = scrollView.textView.textStorage else { return nil }
        let container = NSTextContainer(size: NSSize(width: max(width - 2 * Self.inset.width, 1), height: .greatestFiniteMagnitude))
        let layout = NSLayoutManager()
        layout.addTextContainer(container)
        let copy = NSTextStorage(attributedString: storage)
        copy.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        let lines = max(layout.usedRect(for: container).height, layout.defaultLineHeight(for: Self.font))
        return CGSize(width: width, height: min(ceil(lines) + 2 * Self.inset.height, maxHeight))
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var box: TextBox

        init(_ box: TextBox) {
            self.box = box
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            box.text = textView.string
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                guard let submit = box.submit else { return false }
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                } else {
                    submit()
                }
                return true
            case #selector(NSResponder.insertTab(_:)):
                textView.window?.selectNextKeyView(nil)
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                textView.window?.selectPreviousKeyView(nil)
                return true
            default:
                return false
            }
        }
    }
}

/// Scrolls only when its text is taller than it; otherwise the scroll goes
/// to what holds it, so a short box never stops the page scrolling.
final class PassingScrollView: NSScrollView {
    var textView: NSTextView {
        documentView as! NSTextView
    }

    override func scrollWheel(with event: NSEvent) {
        if textView.frame.height > contentView.bounds.height + 1 {
            super.scrollWheel(with: event)
        } else {
            nextResponder?.scrollWheel(with: event)
        }
    }
}
