import Foundation

/// An answer's Markdown as the blocks Cloak draws: paragraphs, headings,
/// fenced code, lists with one level of nesting, quotes, rules and pipe
/// tables. Not CommonMark: a small line-by-line splitter, and any line it does
/// not understand belongs to a paragraph, so every text splits. The spans
/// inside a block (bold, code, links) stay as written, for the caller.
public enum Markdown {
    public indirect enum Block<Inline> {
        case paragraph(Inline)
        /// Level 1 to 6, as many as its `#`s.
        case heading(level: Int, Inline)
        /// A fenced block's lines as written, its language dropped.
        case code(String)
        /// A display LaTeX math block (`\[...\]`, `$$...$$`, or `\begin{equation|align|...}`).
        case math(String)
        case list([Item<Inline>])
        case quote([Block<Inline>])
        case rule
        /// Each row has as many cells as the header.
        case table(header: [Inline], rows: [[Inline]])
    }

    public struct Item<Inline> {
        /// 0, or 1 under another item.
        public var depth: Int
        /// Its number in a numbered list; nil for a bullet.
        public var number: Int?
        public var text: Inline

        public init(depth: Int, number: Int?, text: Inline) {
            self.depth = depth
            self.number = number
            self.text = text
        }
    }

    /// Quotes inside quotes go this deep; a `>` deeper shows as written.
    static let quoteDepth = 3

    public static func blocks(_ text: String) -> [Block<String>] {
        blocks(text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)[...], quotes: 0)
    }

    private static func blocks(_ lines: ArraySlice<Substring>, quotes: Int) -> [Block<String>] {
        var blocks: [Block<String>] = []
        var paragraph: [Substring] = []
        var index = lines.startIndex

        func endParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph = []
        }

        while index < lines.endIndex {
            let line = lines[index]
            if isBlank(line) {
                endParagraph()
                index += 1
            } else if let fence = Fence(line) {
                endParagraph()
                var code: [Substring] = []
                index += 1
                while index < lines.endIndex, !fence.isClosed(by: lines[index]) {
                    code.append(dropIndent(lines[index], upTo: fence.indent))
                    index += 1
                }
                blocks.append(.code(code.joined(separator: "\n")))
                index += 1
            } else if let math = parseMathBlock(lines, from: &index) {
                endParagraph()
                blocks.append(.math(math))
            } else if let heading = heading(line) {
                endParagraph()
                blocks.append(heading)
                index += 1
            } else if isRule(line) {
                endParagraph()
                blocks.append(.rule)
                index += 1
            } else if quotes < quoteDepth, let first = quoted(line) {
                endParagraph()
                var quote = [first]
                index += 1
                while index < lines.endIndex, let next = quoted(lines[index]) {
                    quote.append(next)
                    index += 1
                }
                blocks.append(.quote(Self.blocks(quote[...], quotes: quotes + 1)))
            } else if index + 1 < lines.endIndex, let header = cells(line), let width = delimiterWidth(lines[index + 1]),
                header.count == width
            {
                endParagraph()
                let start = index
                index += 2
                var rows: [[String]] = []
                while index < lines.endIndex, !isBlank(lines[index]), let row = cells(lines[index]) {
                    rows.append(row)
                    index += 1
                }
                if rows.allSatisfy({ $0.count <= width }) {
                    let padded = rows.map { $0 + Array(repeating: "", count: width - $0.count) }
                    blocks.append(.table(header: header, rows: padded))
                } else {
                    // A row with more cells than the header: a table no more.
                    blocks.append(.paragraph(lines[start..<index].joined(separator: "\n")))
                }
            } else if let marker = Marker(line), paragraph.isEmpty || marker.canInterruptParagraph {
                endParagraph()
                let list = list(lines, from: &index, first: marker)
                blocks.append(.list(list))
            } else {
                paragraph.append(line)
                index += 1
            }
        }
        endParagraph()
        return blocks
    }

    /// The list that starts at `index` with `first`, up to the first line
    /// that is neither an item of the same kind nor indented under one.
    /// Items indented under another are its sublist, however deep.
    private static func list(_ lines: ArraySlice<Substring>, from index: inout Int, first: Marker) -> [Item<String>] {
        let base = first.indent
        let numbered = first.number != nil
        var items: [Item<String>] = []
        var count = 0
        // The sublist under the last item: numbered or not, its first
        // number, and how many so far.
        var sublist: (numbered: Bool, start: Int, count: Int)?
        var blank = false
        while index < lines.endIndex {
            let line = lines[index]
            if isBlank(line) {
                blank = true
                index += 1
                continue
            }
            if !isRule(line), let marker = Marker(line) {
                if marker.indent <= base + 1 {
                    // A blank line, then an item: the same list. An item of
                    // the other kind starts another.
                    guard (marker.number != nil) == numbered else { break }
                    items.append(Item(depth: 0, number: first.number.map { $0 + count }, text: String(marker.text)))
                    count += 1
                    sublist = nil
                } else {
                    // An item of the other kind starts another sublist.
                    let numbered = marker.number != nil
                    let run = sublist.flatMap { $0.numbered == numbered ? $0 : nil }
                        ?? (numbered: numbered, start: marker.number ?? 1, count: 0)
                    let number = numbered ? run.start + run.count : nil
                    items.append(Item(depth: 1, number: number, text: String(marker.text)))
                    sublist = (numbered, run.start, run.count + 1)
                }
                blank = false
                index += 1
                continue
            }
            // An indented line goes on with the last item, unless it opens a
            // fenced block, which ends the list and is drawn on its own.
            guard indent(of: line) > base, Fence(line) == nil, !items.isEmpty else { break }
            items[items.count - 1].text += (blank ? "\n\n" : "\n") + dropIndent(line, upTo: .max)
            blank = false
            index += 1
        }
        return items
    }

    // MARK: Lines

    private static func isBlank(_ line: Substring) -> Bool {
        line.allSatisfy { $0 == " " || $0 == "\t" }
    }

    /// Leading spaces, a tab as four.
    private static func indent(of line: Substring) -> Int {
        var width = 0
        for character in line {
            switch character {
            case " ": width += 1
            case "\t": width += 4
            default: return width
            }
        }
        return width
    }

    private static func dropIndent(_ line: Substring, upTo limit: Int) -> Substring {
        var width = 0
        var rest = line
        while let first = rest.first, first == " " || first == "\t", width < limit {
            width += first == "\t" ? 4 : 1
            rest = rest.dropFirst()
        }
        return rest
    }

    private static func trimmed(_ text: Substring) -> Substring {
        let isText: (Character) -> Bool = { $0 != " " && $0 != "\t" }
        guard let start = text.firstIndex(where: isText), let end = text.lastIndex(where: isText) else { return "" }
        return text[start...end]
    }

    /// `#` to `######`, a space, then the heading; `#`s closing it dropped.
    private static func heading(_ line: Substring) -> Block<String>? {
        let rest = dropIndent(line, upTo: 3)
        let level = rest.prefix { $0 == "#" }.count
        guard (1...6).contains(level) else { return nil }
        let after = rest.dropFirst(level)
        guard after.isEmpty || after.first == " " || after.first == "\t" else { return nil }
        var text = trimmed(after)
        let open = text.reversed().drop { $0 == "#" }
        if open.isEmpty {
            text = ""
        } else if open.count < text.count, open.first == " " || open.first == "\t" {
            text = trimmed(text.prefix(open.count))
        }
        return .heading(level: level, String(text))
    }

    /// Three or more of one of `-`, `*` or `_`, spaces between allowed.
    private static func isRule(_ line: Substring) -> Bool {
        let marks = dropIndent(line, upTo: 3).filter { $0 != " " && $0 != "\t" }
        guard let mark = marks.first, "-*_".contains(mark) else { return false }
        return marks.count >= 3 && marks.allSatisfy { $0 == mark } && indent(of: line) <= 3
    }

    /// The line with its `>` and one space after it taken off.
    private static func quoted(_ line: Substring) -> Substring? {
        let rest = dropIndent(line, upTo: 3)
        guard rest.first == ">" else { return nil }
        let inner = rest.dropFirst()
        return inner.first == " " ? inner.dropFirst() : inner
    }

    /// A table row's cells, split at each `|` not escaped, the outer ones
    /// optional; nil for a line with no `|`.
    private static func cells(_ line: Substring) -> [String]? {
        var cells: [String] = []
        var cell = ""
        var escaped = false
        var pipes = 0
        for character in trimmed(line) {
            if escaped {
                cell.append(character == "|" ? "|" : "\\\(character)")
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                cells.append(cell)
                cell = ""
                pipes += 1
            } else {
                cell.append(character)
            }
        }
        if escaped { cell.append("\\") }
        cells.append(cell)
        guard pipes > 0 else { return nil }
        let row = trimmed(line)
        if row.first == "|" { cells.removeFirst() }
        if row.last == "|", row.dropLast().last != "\\" { cells.removeLast() }
        return cells.map { String(trimmed($0[...])) }
    }

    /// How many columns a delimiter row such as `| --- | :-: |` sets out.
    private static func delimiterWidth(_ line: Substring) -> Int? {
        guard let cells = cells(line), !cells.isEmpty else { return nil }
        let delimits = cells.allSatisfy { cell in
            var dashes = cell[...]
            if dashes.first == ":" { dashes = dashes.dropFirst() }
            if dashes.last == ":" { dashes = dashes.dropLast() }
            return !dashes.isEmpty && dashes.allSatisfy { $0 == "-" }
        }
        return delimits ? cells.count : nil
    }

    /// Parses a display LaTeX block starting at `lines[index]`:
    /// - `\[ ... \]` (single-line or multi-line)
    /// - `$$ ... $$` (single-line or multi-line)
    /// - `\begin{equation|equation*|align|align*|aligned|gather|gather*|multline|multline*} ... \end{...}`
    private static func parseMathBlock(_ lines: ArraySlice<Substring>, from index: inout Int) -> String? {
        let line = trimmed(lines[index])

        // 1. `\[ ... \]`
        if line.hasPrefix("\\[") {
            let afterOpen = trimmed(line.dropFirst(2))
            if afterOpen.hasSuffix("\\]") {
                let inner = String(trimmed(afterOpen.dropLast(2)))
                index += 1
                return inner
            }
            var body: [String] = []
            if !afterOpen.isEmpty { body.append(String(afterOpen)) }
            index += 1
            while index < lines.endIndex {
                let current = trimmed(lines[index])
                if current == "\\]" {
                    index += 1
                    break
                }
                if current.hasSuffix("\\]") {
                    let prefix = trimmed(current.dropLast(2))
                    if !prefix.isEmpty { body.append(String(prefix)) }
                    index += 1
                    break
                }
                body.append(String(lines[index]))
                index += 1
            }
            return body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 2. `$$ ... $$`
        if line.hasPrefix("$$") {
            let afterOpen = trimmed(line.dropFirst(2))
            if !afterOpen.isEmpty, afterOpen.hasSuffix("$$") {
                let inner = String(trimmed(afterOpen.dropLast(2)))
                index += 1
                return inner
            }
            var body: [String] = []
            if !afterOpen.isEmpty { body.append(String(afterOpen)) }
            index += 1
            while index < lines.endIndex {
                let current = trimmed(lines[index])
                if current == "$$" {
                    index += 1
                    break
                }
                if current.hasSuffix("$$") {
                    let prefix = trimmed(current.dropLast(2))
                    if !prefix.isEmpty { body.append(String(prefix)) }
                    index += 1
                    break
                }
                body.append(String(lines[index]))
                index += 1
            }
            return body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 3. Top-level `\begin{env} ... \end{env}` display math environment.
        let displayEnvs = [
            "equation", "equation*", "align", "align*", "aligned",
            "gather", "gather*", "multline", "multline*", "eqnarray", "eqnarray*",
        ]
        for env in displayEnvs {
            let openTag = "\\begin{\(env)}"
            let closeTag = "\\end{\(env)}"
            if line.hasPrefix(openTag) {
                if line.contains(closeTag) {
                    index += 1
                    return String(line)
                }
                var body: [String] = [String(lines[index])]
                index += 1
                while index < lines.endIndex {
                    body.append(String(lines[index]))
                    let done = lines[index].contains(closeTag)
                    index += 1
                    if done { break }
                }
                return body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return nil
    }

        /// A fenced block's opening line: three or more backticks or tildes.
    private struct Fence {
        let mark: Character
        let length: Int
        let indent: Int

        init?(_ line: Substring) {
            let rest = Markdown.dropIndent(line, upTo: .max)
            guard let mark = rest.first, mark == "`" || mark == "~" else { return nil }
            let length = rest.prefix { $0 == mark }.count
            // A backtick in what follows makes it inline code, not a fence.
            guard length >= 3, mark == "~" || !rest.dropFirst(length).contains("`") else { return nil }
            self.mark = mark
            self.length = length
            self.indent = Markdown.indent(of: line)
        }

        func isClosed(by line: Substring) -> Bool {
            let rest = Markdown.dropIndent(line, upTo: .max)
            let length = rest.prefix { $0 == mark }.count
            return length >= self.length && Markdown.isBlank(rest.dropFirst(length))
        }
    }

    /// A list item's opening: `-`, `*` or `+`, or a number and `.` or `)`,
    /// then a space and its text.
    private struct Marker {
        let indent: Int
        let number: Int?
        let text: Substring

        init?(_ line: Substring) {
            let rest = Markdown.dropIndent(line, upTo: .max)
            let after: Substring
            if let first = rest.first, "-*+".contains(first) {
                after = rest.dropFirst()
                number = nil
            } else {
                let digits = rest.prefix(while: \.isASCII).prefix { $0.isNumber }
                guard (1...9).contains(digits.count), let delimiter = rest.dropFirst(digits.count).first,
                    delimiter == "." || delimiter == ")"
                else { return nil }
                after = rest.dropFirst(digits.count + 1)
                number = Int(digits)
            }
            guard after.isEmpty || after.first == " " || after.first == "\t" else { return nil }
            indent = Markdown.indent(of: line)
            text = Markdown.dropIndent(after, upTo: .max)
        }

        /// As in CommonMark: a bullet, or a list counting from 1, with text.
        var canInterruptParagraph: Bool {
            (number == nil || number == 1) && !text.isEmpty
        }
    }
}

extension Markdown.Block {
    /// The same blocks with each span made into another kind.
    public func map<T>(_ transform: (Inline) throws -> T) rethrows -> Markdown.Block<T> {
        switch self {
        case .paragraph(let text): .paragraph(try transform(text))
        case .heading(let level, let text): .heading(level: level, try transform(text))
        case .code(let code): .code(code)
        case .math(let latex): .math(latex)
        case .list(let items): .list(try items.map { .init(depth: $0.depth, number: $0.number, text: try transform($0.text)) })
        case .quote(let blocks): .quote(try blocks.map { try $0.map(transform) })
        case .rule: .rule
        case .table(let header, let rows): .table(header: try header.map(transform), rows: try rows.map { try $0.map(transform) })
        }
    }
}

extension Markdown.Block: Equatable where Inline: Equatable {}
extension Markdown.Block: Sendable where Inline: Sendable {}
extension Markdown.Item: Equatable where Inline: Equatable {}
extension Markdown.Item: Sendable where Inline: Sendable {}
