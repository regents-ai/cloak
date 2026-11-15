import CloakChat
import SwiftUI

/// An answer with its Markdown drawn: headings, lists, fenced code, quotes,
/// rules, tables, and bold, italic, struck and code spans. A link shows its
/// words and then its address, and never opens: a click would open the
/// owner's browser outside Tor. An image is never loaded; its words and
/// address show instead. Raw HTML shows as written. The text can be selected
/// and copied within each block. It is as tall as its text, so a long answer
/// scrolls with the chat; only a code block scrolls on its own, sideways.
/// The answer is split, and its spans read, once for each text, never on a
/// redraw.
struct AnswerText: View {
    let text: String
    @State private var memo = Memo()

    var body: some View {
        Blocks(blocks: memo.blocks(text))
            .padding(.horizontal, 7)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Answer")
    }

    private static let options = AttributedString.MarkdownParsingOptions(
        interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)

    /// A block's spans, with nothing in them that opens or loads: each link
    /// and image keeps its words, its address after them. Spans Foundation
    /// does not read show as written, as the splitter's paragraphs do.
    private static func spans(_ markdown: String) -> AttributedString {
        let parsed = (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
        var spans = AttributedString()
        for (link, image, range) in parsed.runs[\.link, \.imageURL] {
            for run in parsed[range].runs {
                var piece = AttributedString(parsed[run.range])
                piece.link = nil
                piece.imageURL = nil
                if run.inlinePresentationIntent?.contains(.code) == true {
                    piece.swiftUI.backgroundColor = Color.primary.opacity(0.07)
                }
                spans.append(piece)
            }
            if let url = link ?? image {
                let words = String(parsed[range].characters)
                let address = url.absoluteString
                guard words != address else { continue }
                var shown = AttributedString(words.isEmpty ? address : " (\(address))")
                shown.swiftUI.foregroundColor = .secondary
                spans.append(shown)
            }
        }
        return spans
    }

    /// The blocks of the last text drawn, made again only for another text.
    @MainActor
    private final class Memo {
        private var text: String?
        private var blocks: [Markdown.Block<AttributedString>] = []

        func blocks(_ text: String) -> [Markdown.Block<AttributedString>] {
            if text != self.text {
                blocks = Markdown.blocks(text).map { $0.map(AnswerText.spans) }
                self.text = text
            }
            return blocks
        }
    }
}

private struct Blocks: View {
    let blocks: [Markdown.Block<AttributedString>]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(blocks.indices, id: \.self) { index in
                let block = blocks[index]
                BlockView(block: block)
                    // A heading sits closer to what it heads than to what
                    // comes before it.
                    .padding(.top, index > 0 && block.isHeading ? 6 : 0)
            }
        }
    }
}

private struct BlockView: View {
    let block: Markdown.Block<AttributedString>

    var body: some View {
        switch block {
        case .paragraph(let text):
            Text(text)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let text):
            Text(text)
                .font(level == 1 ? .title2 : level == 2 ? .title3 : .headline)
                .fontWeight(.semibold)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityHeading(Self.heading(level))
        case .code(let code):
            ScrollView(.horizontal) {
                Text(verbatim: code)
                    .font(.system(.callout, design: .monospaced))
                    .lineSpacing(2)
                    .fixedSize()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Code")
        case .list(let items):
            ListBlock(items: items)
        case .quote(let blocks):
            Blocks(blocks: blocks)
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(.separator)
                        .frame(width: 3)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Quote")
        case .rule:
            Divider()
                .padding(.vertical, 4)
                .accessibilityHidden(true)
        case .table(let header, let rows):
            TableBlock(header: header, rows: rows)
        }
    }

    private static func heading(_ level: Int) -> AccessibilityHeadingLevel {
        switch level {
        case 1: .h1
        case 2: .h2
        case 3: .h3
        case 4: .h4
        case 5: .h5
        default: .h6
        }
    }
}

/// Bullets or numbers in a column of their own, a sublist under its item.
private struct ListBlock: View {
    let items: [Markdown.Item<AttributedString>]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items.indices, id: \.self) { index in
                let item = items[index]
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Group {
                        if let number = item.number {
                            Text(verbatim: "\(number).")
                                .monospacedDigit()
                        } else {
                            Text(verbatim: item.depth == 0 ? "•" : "◦")
                                .accessibilityHidden(true)
                        }
                    }
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 20, alignment: .trailing)
                    Text(item.text)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, CGFloat(item.depth) * 26)
                .accessibilityElement(children: .combine)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("List")
    }
}

/// A plain grid: the header's cells in semibold, a line under each row.
private struct TableBlock: View {
    let header: [AttributedString]
    let rows: [[AttributedString]]

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(header.indices, id: \.self) { column in
                    cell(header[column])
                        .fontWeight(.semibold)
                }
            }
            ForEach(rows.indices, id: \.self) { row in
                Divider()
                GridRow {
                    ForEach(rows[row].indices, id: \.self) { column in
                        cell(rows[row][column])
                    }
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Table")
    }

    private func cell(_ text: AttributedString) -> some View {
        Text(text)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
    }
}

extension Markdown.Block {
    fileprivate var isHeading: Bool {
        if case .heading = self { true } else { false }
    }
}
