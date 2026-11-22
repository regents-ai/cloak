import AppKit
import SwiftUI

/// Copy, as a symbol, for every Copy in the app: puts its text on the
/// pasteboard, then shows a checkmark for a second and a half, named
/// "Copied" for VoiceOver, which also says it, before it goes back. The
/// symbol changes with a cross-fade under Reduce Motion. A text read at the
/// press that comes back nil copies nothing and shows nothing. `side` is
/// the square that answers the pointer: 24 points beside a line of text,
/// 28 beside a `SymbolButton`.
struct CopyButton: View {
    let title: String
    let side: CGFloat
    let text: () async -> String?
    /// When the last copy landed, while its checkmark shows.
    @State private var copied: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ title: String = "Copy", side: CGFloat = 24, text: String) {
        self.init(title, side: side) { text }
    }

    init(_ title: String = "Copy", side: CGFloat = 24, text: @escaping () async -> String?) {
        self.title = title
        self.side = side
        self.text = text
    }

    var body: some View {
        let name = copied == nil ? title : "Copied"
        Button {
            Task { await copy() }
        } label: {
            Label(name, systemImage: copied == nil ? "doc.on.doc" : "checkmark")
                .labelStyle(.iconOnly)
                .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
                .frame(width: side, height: side)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .hover(Circle())
        .help(name)
        // A press while the checkmark shows starts its second and a half again.
        .task(id: copied) {
            guard copied != nil, (try? await Task.sleep(for: .seconds(1.5))) != nil else { return }
            withAnimation { copied = nil }
        }
    }

    private func copy() async {
        guard let text = await text() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation { copied = .now }
        AccessibilityNotification.Announcement("Copied").post()
    }
}
