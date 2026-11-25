import SwiftUI

/// A mark beside what it explains, an `info.circle` unless another is
/// given, with a note behind it: the one view for every note, from the
/// Modes note under Chat's box and NEAR's Limits to the Agents window's
/// notes, each Settings row's and Token Inference's two marks. The note
/// opens when the pointer rests on the button for a moment, or on a click
/// or from the keyboard, and closes as any popover does. Leaving the button
/// doesn't close it, so the pointer can reach a link in the note. It has
/// no tip (`Tip.swift`), which would come up over the note the same rest
/// opens. Its name is what VoiceOver reads; a note of words is its hint
/// too, so it is heard without opening.
struct InfoButton<Mark: View, Note: View>: View {
    let title: String
    let hint: String?
    /// Where the note opens: `.top` above the button, `.bottom` under it.
    let arrowEdge: Edge
    let mark: Mark
    let note: Note
    @State private var showing = false
    @State private var opening: Task<Void, any Error>?

    init(
        _ title: String, hint: String? = nil, arrowEdge: Edge = .bottom, @ViewBuilder mark: () -> Mark, @ViewBuilder note: () -> Note
    ) {
        self.title = title
        self.hint = hint
        self.arrowEdge = arrowEdge
        self.mark = mark()
        self.note = note()
    }

    var body: some View {
        Button { showing = true } label: {
            mark
                .padding(.horizontal, 6)
                .frame(minWidth: 28, minHeight: 28)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        // A circle round the one symbol, a capsule round a wider mark.
        .hover(Capsule())
        .accessibilityLabel(title)
        .accessibilityHint(hint ?? "")
        .onHover { inside in
            opening?.cancel()
            guard inside, NSApp.isActive else { return }
            // Sleeping throws once cancelled, so a pointer that leaves first
            // never opens it.
            opening = Task {
                try await Task.sleep(for: .milliseconds(400))
                guard NSApp.isActive else { return }
                showing = true
            }
        }
        .onDisappear { opening?.cancel() }
        .popover(isPresented: $showing, arrowEdge: arrowEdge) {
            note
        }
        // All 28 points answer the pointer, but they overhang the line of
        // text beside them, so a row or heading holding one is no taller.
        .padding(.vertical, -6)
    }
}

extension InfoButton where Mark == Image {
    /// The usual mark, an `info.circle`.
    init(_ title: String, hint: String? = nil, arrowEdge: Edge = .bottom, @ViewBuilder note: () -> Note) {
        self.init(title, hint: hint, arrowEdge: arrowEdge, mark: { Image(systemName: "info.circle") }, note: note)
    }
}

extension InfoButton where Mark == Image, Note == NoteText {
    /// A note of words, read as the button's hint too.
    init(_ title: String, note: String, arrowEdge: Edge = .bottom) {
        self.init(title, hint: note, arrowEdge: arrowEdge) { NoteText(text: note) }
    }
}

/// A note of words, as an `InfoButton` opens it.
struct NoteText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(14)
            .frame(width: 300, alignment: .leading)
    }
}

/// A scannable bulleted popover note for `InfoButton`.
struct BulletNote: View {
    var lead: String?
    let bullets: [String]

    init(_ lead: String? = nil, bullets: [String]) {
        self.lead = lead
        self.bullets = bullets
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let lead {
                Text(lead)
                    .fontWeight(.medium)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(bullets, id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("•")
                        .foregroundStyle(.secondary)
                    Text(item)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.callout)
        .textSelection(.enabled)
        .padding(14)
        .frame(width: 310, alignment: .leading)
    }
}
