import AppKit
import CloakChat
import SwiftUI

/// An answer with its Markdown drawn: headings, lists, fenced code, quotes,
/// rules, tables, and bold, italic, struck and code spans. A link shows its
/// words and then its address, and never opens: a click would open the
/// owner's browser outside Tor. An image is never loaded; its words and
/// address show instead. Raw HTML shows as written.
///
/// Consecutive prose blocks (headings, paragraphs, and lists) are joined into
/// a single continuous `AttributedString` so macOS drag-selection sweeps across
/// paragraphs and headings without hitting block boundaries. Code blocks have
/// a quiet hover Copy button with instant checkmark confirmation.
struct AnswerText: View {
    let text: String
    @State private var memo = Memo()

    var body: some View {
        SegmentsView(segments: memo.segments(text))
            .padding(.horizontal, 7)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Answer")
    }

    private static let options = AttributedString.MarkdownParsingOptions(
        interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)

    /// A block's spans, with inline LaTeX math (`\(...\)` and currency-safe `$...$`)
    /// rendered in serif math styling and nothing in Markdown that opens or loads:
    /// each link and image keeps its words, its address after them.
    fileprivate static func spans(_ markdown: String) -> AttributedString {
        let parts = LatexMath.splitInline(markdown)
        var result = AttributedString()
        for part in parts {
            switch part {
            case .markdown(let chunk):
                result.append(markdownSpans(chunk))
            case .math(let latex, _):
                result.append(inlineMathSpans(latex))
            }
        }
        return result
    }

    private static func markdownSpans(_ markdown: String) -> AttributedString {
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

    private static func inlineMathSpans(_ latex: String) -> AttributedString {
        let runs = LatexMath.inlineRuns(latex)
        guard !runs.isEmpty else { return AttributedString(latex) }
        var out = AttributedString()
        for run in runs {
            var piece = AttributedString(run.text)
            let size: CGFloat = run.role == .normal ? 14 : 10
            var font: Font =
                if run.monospaced {
                    .system(size: size * 0.92, design: .monospaced)
                } else {
                    .system(size: size, weight: run.bold ? .semibold : .regular, design: .serif)
                }
            if run.italic && !run.monospaced {
                font = font.italic()
            }
            piece.swiftUI.font = font
            switch run.role {
            case .normal:
                break
            case .sub:
                piece.swiftUI.baselineOffset = -3
            case .sup:
                piece.swiftUI.baselineOffset = 4.5
            }
            out.append(piece)
        }
        return out
    }

    /// Combines consecutive prose blocks (headings, paragraphs, lists) into
    /// continuous selectable `AttributedString` segments while keeping code,
    /// quotes, dividers, and tables as distinct structural blocks.
    fileprivate static func buildSegments(_ blocks: [Markdown.Block<AttributedString>]) -> [Segment] {
        var result: [Segment] = []
        var pendingProse = AttributedString()

        func flushProse() {
            guard !pendingProse.characters.isEmpty else { return }
            result.append(.prose(pendingProse))
            pendingProse = AttributedString()
        }

        for block in blocks {
            switch block {
            case .paragraph(let text):
                if !pendingProse.characters.isEmpty {
                    pendingProse.append(AttributedString("\n\n"))
                }
                pendingProse.append(text)
            case .heading(let level, let text):
                if !pendingProse.characters.isEmpty {
                    pendingProse.append(AttributedString("\n\n"))
                }
                var styled = text
                let font: Font = switch level {
                case 1: .title2.weight(.semibold)
                case 2: .title3.weight(.semibold)
                default: .headline.weight(.semibold)
                }
                styled.swiftUI.font = font
                pendingProse.append(styled)
            case .list(let items):
                if !pendingProse.characters.isEmpty {
                    pendingProse.append(AttributedString("\n\n"))
                }
                for (index, item) in items.enumerated() {
                    if index > 0 {
                        pendingProse.append(AttributedString("\n"))
                    }
                    let indent = String(repeating: "    ", count: max(0, item.depth))
                    let markerText = item.number.map { "\($0). " } ?? (item.depth == 0 ? "• " : "◦ ")
                    var prefix = AttributedString(indent + markerText)
                    prefix.swiftUI.foregroundColor = .secondary
                    pendingProse.append(prefix)
                    pendingProse.append(item.text)
                }
            case .code(let code):
                flushProse()
                result.append(.code(code))
            case .math(let latex):
                flushProse()
                result.append(.math(latex))
            case .quote(let inner):
                flushProse()
                result.append(.quote(buildSegments(inner)))
            case .rule:
                flushProse()
                result.append(.rule)
            case .table(let header, let rows):
                flushProse()
                result.append(.table(header: header, rows: rows))
            }
        }
        flushProse()
        return result
    }

    /// Memoized parsed segments for the last text drawn.
    @MainActor
    private final class Memo {
        private var text: String?
        private var cached: [Segment] = []

        func segments(_ text: String) -> [Segment] {
            if text != self.text {
                let blocks = Markdown.blocks(text).map { $0.map(AnswerText.spans) }
                cached = AnswerText.buildSegments(blocks)
                self.text = text
            }
            return cached
        }
    }
}

private enum Segment {
    case prose(AttributedString)
    case code(String)
    case math(String)
    case quote([Segment])
    case rule
    case table(header: [AttributedString], rows: [[AttributedString]])
}

private struct SegmentsView: View {
    let segments: [Segment]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(segments.indices, id: \.self) { index in
                SegmentView(segment: segments[index])
            }
        }
    }
}

private struct SegmentView: View {
    let segment: Segment

    var body: some View {
        switch segment {
        case .prose(let text):
            Text(text)
                .lineSpacing(3.5)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .code(let code):
            CodeBlock(code: code)
        case .math(let latex):
            MathBlock(latex: latex)
        case .quote(let inner):
            SegmentsView(segments: inner)
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
}

/// Fenced code block with horizontal scrolling and a quiet top-right Copy button
/// that transitions smoothly to a green checkmark confirmation.
private struct CodeBlock: View {
    let code: String
    @State private var hovering = false
    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView(.horizontal) {
                Text(verbatim: code)
                    .font(.system(.callout, design: .monospaced))
                    .lineSpacing(2)
                    .fixedSize()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .padding(.trailing, 32)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
                copied = true
                resetTask?.cancel()
                resetTask = Task {
                    try? await Task.sleep(for: .milliseconds(1500))
                    guard !Task.isCancelled else { return }
                    copied = false
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(copied ? .green : .secondary)
                        .contentTransition(.symbolEffect(.replace))
                    if copied {
                        Text("Copied")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.green)
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.75))
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .padding(6)
            .opacity(hovering || copied ? 1 : 0.28)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovering)
            .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: copied)
            .tip(copied ? "Copied" : "Copy code")
            .accessibilityLabel("Copy code")
        }
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75))
        .onHover { hovering = $0 }
        .onDisappear { resetTask?.cancel() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Code")
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
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator))
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
