import Foundation

/// Pure-Swift LaTeX math splitter, recursive-descent AST parser, and inline run
/// formatter used by Cloak's chat renderer (`AnswerText` + `MathView`).
///
/// Supports:
/// - Display delimiters: `\[ ... \]`, `$$ ... $$`, and `\begin{equation|align|aligned|gather|multline}...`
/// - Inline delimiters: `\( ... \)` and currency-safe `$ ... $` (ignoring code spans and `$5–$10`)
/// - Stacked fractions, roots, scripts, big operators with limits, accents,
///   scalable `\left...\right` delimiters, matrices/aligned/cases environments,
///   and standard physics/mathematics Greek & operator symbols.
public enum LatexMath {
    public enum InlinePart: Equatable, Sendable {
        case markdown(String)
        case math(String, display: Bool)
    }

    public enum TextStyle: Equatable, Sendable {
        case roman
        case bold
        case italic
        case calligraphic
        case blackboard
        case monospace
        case sansSerif
    }

    public enum Accent: Equatable, Sendable {
        case hat
        case bar
        case vec
        case dot
        case ddot
        case tilde
        case underline
    }

    public enum MatrixKind: Equatable, Sendable {
        case plain
        case paren
        case bracket
        case brace
        case pipe
        case doublePipe
        case cases
        case aligned
        case gathered
    }

    public indirect enum Node: Equatable, Sendable {
        case symbol(String, italic: Bool)
        case binaryOp(String)
        case relation(String)
        case bigOp(String, limits: Bool)
        case text(String, style: TextStyle)
        case script(base: Node, sub: [Node]?, sup: [Node]?, stacked: Bool)
        case fraction(numerator: [Node], denominator: [Node], hasBar: Bool)
        case radical(index: [Node]?, radicand: [Node])
        case accent(Accent, body: [Node])
        case delimited(left: String, right: String, body: [Node])
        case matrix(kind: MatrixKind, rows: [[[Node]]])
        case space(Double)
        case group([Node])
    }

    public enum InlineRole: Equatable, Sendable {
        case normal
        case sub
        case sup
    }

    public struct InlineRun: Equatable, Sendable {
        public var text: String
        public var italic: Bool
        public var bold: Bool
        public var monospaced: Bool
        public var role: InlineRole

        public init(text: String, italic: Bool = false, bold: Bool = false, monospaced: Bool = false, role: InlineRole = .normal) {
            self.text = text
            self.italic = italic
            self.bold = bold
            self.monospaced = monospaced
            self.role = role
        }
    }

    // MARK: - Inline Splitter

    /// Splits a Markdown inline string into alternating Markdown and LaTeX math
    /// spans without touching backtick code spans or currency expressions such as
    /// `$5`, `$5–$10`, `$0.10 | $0.50`, or `\$5`.
    public static func splitInline(_ text: String) -> [InlinePart] {
        var parts: [InlinePart] = []
        var markdownBuffer = ""
        let chars = Array(text)
        let count = chars.count
        var i = 0

        func flushMarkdown() {
            guard !markdownBuffer.isEmpty else { return }
            parts.append(.markdown(markdownBuffer))
            markdownBuffer = ""
        }

        while i < count {
            // 1. Preserve inline code spans verbatim so `$var` or `\(` inside backticks stay code.
            if chars[i] == "`" {
                var ticks = 0
                while i + ticks < count, chars[i + ticks] == "`" { ticks += 1 }
                if let closeStart = findClosingBackticks(chars, from: i + ticks, tickCount: ticks) {
                    markdownBuffer.append(contentsOf: chars[i..<(closeStart + ticks)])
                    i = closeStart + ticks
                    continue
                }
                markdownBuffer.append(contentsOf: chars[i..<(i + ticks)])
                i += ticks
                continue
            }

            // 2. Backslash-delimited math: \( ... \) and \[ ... \]
            if chars[i] == "\\", i + 1 < count {
                let next = chars[i + 1]
                if next == "(" {
                    if let close = findBackslashDelimiter(chars, from: i + 2, closing: ")") {
                        let inner = String(chars[(i + 2)..<close]).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !inner.isEmpty {
                            flushMarkdown()
                            parts.append(.math(inner, display: false))
                            i = close + 2
                            continue
                        }
                    }
                } else if next == "[" {
                    if let close = findBackslashDelimiter(chars, from: i + 2, closing: "]") {
                        let inner = String(chars[(i + 2)..<close]).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !inner.isEmpty {
                            flushMarkdown()
                            parts.append(.math(inner, display: true))
                            i = close + 2
                            continue
                        }
                    }
                } else if next == "$" {
                    // Escaped dollar stays literal in Markdown (`\$`).
                    markdownBuffer.append("\\")
                    markdownBuffer.append("$")
                    i += 2
                    continue
                }
            }

            // 3. Dollar-delimited math: $$ ... $$ or currency-safe $ ... $
            if chars[i] == "$" {
                if i + 1 < count, chars[i + 1] == "$" {
                    if let close = findDoubleDollar(chars, from: i + 2) {
                        let inner = String(chars[(i + 2)..<close]).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !inner.isEmpty {
                            flushMarkdown()
                            parts.append(.math(inner, display: true))
                            i = close + 2
                            continue
                        }
                    }
                } else if let close = findSingleDollar(chars, open: i) {
                    let inner = String(chars[(i + 1)..<close])
                    flushMarkdown()
                    parts.append(.math(inner, display: false))
                    i = close + 1
                    continue
                }
            }

            markdownBuffer.append(chars[i])
            i += 1
        }

        flushMarkdown()
        return parts
    }

    private static func findClosingBackticks(_ chars: [Character], from start: Int, tickCount: Int) -> Int? {
        var i = start
        let count = chars.count
        while i < count {
            if chars[i] == "`" {
                var run = 0
                while i + run < count, chars[i + run] == "`" { run += 1 }
                if run == tickCount { return i }
                i += run
            } else {
                i += 1
            }
        }
        return nil
    }

    private static func findBackslashDelimiter(_ chars: [Character], from start: Int, closing: Character) -> Int? {
        var i = start
        let count = chars.count
        while i + 1 < count {
            if chars[i] == "\\" {
                if chars[i + 1] == closing {
                    return i
                }
                i += 2
            } else {
                i += 1
            }
        }
        return nil
    }

    private static func findDoubleDollar(_ chars: [Character], from start: Int) -> Int? {
        var i = start
        let count = chars.count
        while i + 1 < count {
            if chars[i] == "\\" {
                i += 2
            } else if chars[i] == "$", chars[i + 1] == "$" {
                return i
            } else {
                i += 1
            }
        }
        return nil
    }

    /// Pandoc/KaTeX currency-safe single-dollar scanner:
    /// - Opening `$` cannot be followed by whitespace or `$`.
    /// - Closing `$` cannot be preceded by whitespace, cannot be escaped, and cannot be followed by an ASCII digit.
    /// - Span cannot cross newlines.
    private static func findSingleDollar(_ chars: [Character], open: Int) -> Int? {
        let count = chars.count
        guard open + 1 < count else { return nil }
        let first = chars[open + 1]
        guard !first.isWhitespace, first != "$", !first.isNewline else { return nil }
        // Don't start inside an identifier like `foo$bar`.
        if open > 0, chars[open - 1].isLetter || chars[open - 1].isNumber {
            return nil
        }

        var i = open + 1
        while i < count {
            let c = chars[i]
            if c.isNewline || c == "`" { return nil }
            if c == "\\" {
                i += 2
                continue
            }
            if c == "$" {
                let prev = chars[i - 1]
                guard !prev.isWhitespace else { return nil }
                // Closing `$` followed by a digit (e.g., `$5-$10`, `$5–$10`) is currency, not math.
                if i + 1 < count, chars[i + 1].isASCII && chars[i + 1].isNumber {
                    return nil
                }
                // Closing `$` followed by `$` means this wasn't single-dollar math.
                if i + 1 < count, chars[i + 1] == "$" {
                    return nil
                }
                let inner = chars[(open + 1)..<i]
                // If span begins with a digit (like `$5 and ...` or `$0.50 ...`), require an explicit
                // math operator/command and disallow ordinary prose words so currency ranges never misfire.
                if first.isASCII && first.isNumber {
                    let hasMathSignal = inner.contains { "\\^_=<>".contains($0) }
                    if !hasMathSignal {
                        return nil
                    }
                    let innerStr = String(inner)
                    if innerStr.range(of: #"\b(and|or|to|for|with|the|is|are|of|per)\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
                        return nil
                    }
                }
                return i
            }
            i += 1
        }
        return nil
    }

    // MARK: - LaTeX AST Parser

    public static func parse(_ source: String) -> [Node] {
        var parser = Parser(source)
        return parser.parseTopLevel()
    }

    private struct Parser {
        private let chars: [Character]
        private var index: Int = 0

        init(_ source: String) {
            self.chars = Array(source)
        }

        mutating func parseTopLevel() -> [Node] {
            var lines: [[Node]] = []
            while !isAtEnd {
                let row = parseExpression(stoppingAt: ["\\\\"])
                lines.append(row)
                skipWhitespace()
                if peek() == "\\", peek(1) == "\\" {
                    advance()
                    advance()
                    _ = parseOptionalBracketGroup()
                } else {
                    break
                }
            }
            let nonEmpty = lines.filter { !$0.isEmpty }
            if nonEmpty.count > 1 {
                return [.matrix(kind: .gathered, rows: nonEmpty.map { [$0] })]
            }
            return nonEmpty.first ?? []
        }

        private var isAtEnd: Bool { index >= chars.count }

        private func peek(_ offset: Int = 0) -> Character? {
            let pos = index + offset
            return pos < chars.count ? chars[pos] : nil
        }

        @discardableResult
        private mutating func advance() -> Character {
            let c = chars[index]
            index += 1
            return c
        }

        private mutating func skipWhitespace() {
            while let c = peek(), c.isWhitespace {
                index += 1
            }
        }

        mutating func parseExpression(stoppingAt stops: Set<String>) -> [Node] {
            var nodes: [Node] = []
            while !isAtEnd {
                skipWhitespace()
                guard let c = peek() else { break }

                if c == "}" && stops.contains("}") {
                    break
                }
                if c == "&" && stops.contains("&") {
                    break
                }
                if c == "\\", peek(1) == "\\", stops.contains("\\\\") {
                    break
                }
                if c == "\\", stops.contains("\\right") || stops.contains("\\end") {
                    let saved = index
                    let cmd = readCommandName()
                    index = saved
                    if stops.contains("\\" + cmd) {
                        break
                    }
                }
                if c == "]" && stops.contains("]") {
                    break
                }

                if let atom = parseAtom() {
                    let scripted = parseScripts(on: atom)
                    nodes.append(scripted)
                }
            }
            return nodes
        }

        private mutating func parseAtom() -> Node? {
            skipWhitespace()
            guard let c = peek() else { return nil }

            switch c {
            case "{":
                advance()
                let inner = parseExpression(stoppingAt: ["}"])
                if peek() == "}" { advance() }
                return inner.count == 1 ? inner[0] : .group(inner)
            case "}":
                advance()
                return nil
            case "\\":
                return parseCommand()
            case "^", "_":
                // Bare script with empty base
                return .symbol("", italic: false)
            case "+":
                advance()
                return .binaryOp("+")
            case "-":
                advance()
                return .binaryOp("−")
            case "=":
                advance()
                return .relation("=")
            case "<":
                advance()
                return .relation("<")
            case ">":
                advance()
                return .relation(">")
            case "'":
                advance()
                return .symbol("′", italic: false)
            case "~":
                advance()
                return .space(4)
            case "&":
                advance()
                return .space(8)
            default:
                advance()
                if c.isASCII && c.isLetter {
                    return .symbol(String(c), italic: true)
                }
                return .symbol(String(c), italic: false)
            }
        }

        private mutating func parseScripts(on base: Node) -> Node {
            var sub: [Node]? = nil
            var sup: [Node]? = nil
            var forceStacked = false
            var forceInline = false

            while true {
                skipWhitespace()
                guard let c = peek() else { break }
                if c == "_" {
                    advance()
                    sub = parseScriptArgument()
                } else if c == "^" {
                    advance()
                    sup = parseScriptArgument()
                } else if c == "\\" {
                    let saved = index
                    let cmd = readCommandName()
                    if cmd == "limits" {
                        forceStacked = true
                    } else if cmd == "nolimits" {
                        forceInline = true
                    } else {
                        index = saved
                        break
                    }
                } else {
                    break
                }
            }

            guard sub != nil || sup != nil else { return base }
            let defaultStacked: Bool = {
                if case .bigOp(_, let limits) = base { return limits }
                return false
            }()
            let stacked = forceStacked || (defaultStacked && !forceInline)
            return .script(base: base, sub: sub, sup: sup, stacked: stacked)
        }

        private mutating func parseScriptArgument() -> [Node] {
            skipWhitespace()
            guard let c = peek() else { return [] }
            if c == "{" {
                advance()
                let inner = parseExpression(stoppingAt: ["}"])
                if peek() == "}" { advance() }
                return inner
            }
            if let atom = parseAtom() {
                return [atom]
            }
            return []
        }

        private mutating func parseGroupOrAtom() -> [Node] {
            skipWhitespace()
            guard let c = peek() else { return [] }
            if c == "{" {
                advance()
                let inner = parseExpression(stoppingAt: ["}"])
                if peek() == "}" { advance() }
                return inner
            }
            if let atom = parseAtom() {
                return [atom]
            }
            return []
        }

        private mutating func parseOptionalBracketGroup() -> [Node]? {
            skipWhitespace()
            guard peek() == "[" else { return nil }
            advance()
            let inner = parseExpression(stoppingAt: ["]"])
            if peek() == "]" { advance() }
            return inner
        }

        private mutating func readRawBraceText() -> String {
            skipWhitespace()
            guard peek() == "{" else {
                guard !isAtEnd else { return "" }
                return String(advance())
            }
            advance()
            var depth = 1
            var out = ""
            while !isAtEnd, depth > 0 {
                let c = advance()
                if c == "\\" && !isAtEnd {
                    let next = advance()
                    if next == "{" || next == "}" || next == "%" || next == "_" || next == "&" || next == "#" || next == "$" {
                        out.append(next)
                    } else {
                        out.append("\\")
                        out.append(next)
                    }
                } else if c == "{" {
                    depth += 1
                    out.append(c)
                } else if c == "}" {
                    depth -= 1
                    if depth > 0 { out.append(c) }
                } else {
                    out.append(c)
                }
            }
            return out
        }

        private mutating func readCommandName() -> String {
            guard peek() == "\\" else { return "" }
            advance()
            guard let first = peek() else { return "" }
            if !first.isLetter {
                return String(advance())
            }
            var name = ""
            while let c = peek(), c.isLetter {
                name.append(advance())
            }
            return name
        }

        private mutating func readDelimiter() -> String {
            skipWhitespace()
            guard let c = peek() else { return "" }
            if c == "." {
                advance()
                return ""
            }
            if c == "\\" {
                let cmd = readCommandName()
                switch cmd {
                case "{": return "{"
                case "}": return "}"
                case "|", "Vert", "lVert", "rVert": return "‖"
                case "vert", "lvert", "rvert": return "|"
                case "langle": return "⟨"
                case "rangle": return "⟩"
                case "lfloor": return "⌊"
                case "rfloor": return "⌋"
                case "lceil": return "⌈"
                case "rceil": return "⌉"
                default: return LatexMath.symbols[cmd] ?? cmd
                }
            }
            return String(advance())
        }

        private mutating func parseCommand() -> Node? {
            let cmd = readCommandName()
            guard !cmd.isEmpty else { return nil }

            switch cmd {
            // Fractions & binomials
            case "frac", "dfrac", "tfrac", "cfrac":
                let num = parseGroupOrAtom()
                let den = parseGroupOrAtom()
                return .fraction(numerator: num, denominator: den, hasBar: true)
            case "binom", "dbinom", "tbinom":
                let num = parseGroupOrAtom()
                let den = parseGroupOrAtom()
                return .delimited(left: "(", right: ")", body: [.fraction(numerator: num, denominator: den, hasBar: false)])

            // Radicals
            case "sqrt":
                let idx = parseOptionalBracketGroup()
                let body = parseGroupOrAtom()
                return .radical(index: idx, radicand: body)

            // Accents & decorations
            case "hat", "widehat":
                return .accent(.hat, body: parseGroupOrAtom())
            case "bar", "overline":
                return .accent(.bar, body: parseGroupOrAtom())
            case "vec", "overrightarrow":
                return .accent(.vec, body: parseGroupOrAtom())
            case "dot":
                return .accent(.dot, body: parseGroupOrAtom())
            case "ddot":
                return .accent(.ddot, body: parseGroupOrAtom())
            case "tilde", "widetilde":
                return .accent(.tilde, body: parseGroupOrAtom())
            case "underline":
                return .accent(.underline, body: parseGroupOrAtom())

            // Text & font styles
            case "text", "textrm", "mbox", "hbox":
                return .text(readRawBraceText(), style: .roman)
            case "mathrm", "operatorname":
                return .text(readRawBraceText(), style: .roman)
            case "mathbf", "textbf", "bm", "boldsymbol":
                return .text(renderPlain(parseGroupOrAtom()), style: .bold)
            case "mathit", "textit":
                return .text(renderPlain(parseGroupOrAtom()), style: .italic)
            case "mathcal", "mathscr":
                return .text(renderPlain(parseGroupOrAtom()), style: .calligraphic)
            case "mathbb":
                return .text(mapBlackboard(readRawBraceText()), style: .blackboard)
            case "mathsf":
                return .text(renderPlain(parseGroupOrAtom()), style: .sansSerif)
            case "mathtt", "texttt":
                return .text(readRawBraceText(), style: .monospace)

            // Scalable delimiters
            case "left":
                let leftDelim = readDelimiter()
                let body = parseExpression(stoppingAt: ["\\right"])
                var rightDelim = ""
                if peek() == "\\" {
                    let saved = index
                    if readCommandName() == "right" {
                        rightDelim = readDelimiter()
                    } else {
                        index = saved
                    }
                }
                return .delimited(left: leftDelim, right: rightDelim, body: body)
            case "right":
                _ = readDelimiter()
                return nil
            case "big", "Big", "bigg", "Bigg", "bigl", "bigr", "Bigl", "Bigr", "biggl", "biggr", "Biggl", "Biggr":
                return .symbol(readDelimiter(), italic: false)

            // Environments
            case "begin":
                let env = readRawBraceText()
                return parseEnvironment(env)
            case "end":
                _ = readRawBraceText()
                return nil

            // Spacing & line breaks
            case ",": return .space(3)
            case ":": return .space(4)
            case ";": return .space(5)
            case "!": return .space(-2)
            case " ": return .space(5)
            case "quad": return .space(14)
            case "qquad": return .space(24)
            case "\\": return .space(8)
            case "displaystyle", "textstyle", "scriptstyle", "scriptscriptstyle", "limits", "nolimits", "notag", "nonumber":
                return nil
            case "tag":
                let label = readRawBraceText()
                return .text("  (\(label))", style: .roman)

            // Escaped punctuation
            case "{", "}", "%", "_", "#", "$", "&":
                return .symbol(cmd, italic: false)

            default:
                if let op = LatexMath.bigOperators[cmd] {
                    return .bigOp(op.symbol, limits: op.limits)
                }
                if let bin = LatexMath.binaryOperators[cmd] {
                    return .binaryOp(bin)
                }
                if let rel = LatexMath.relations[cmd] {
                    return .relation(rel)
                }
                if let sym = LatexMath.symbols[cmd] {
                    let italic = LatexMath.italicGreek.contains(cmd)
                    return .symbol(sym, italic: italic)
                }
                if LatexMath.romanFunctions.contains(cmd) {
                    return .text(cmd, style: .roman)
                }
                // Unknown command: show cleanly without crashing.
                return .text(cmd, style: .roman)
            }
        }

        private mutating func parseEnvironment(_ name: String) -> Node {
            let kind: MatrixKind = switch name {
            case "pmatrix": .paren
            case "bmatrix": .bracket
            case "Bmatrix": .brace
            case "vmatrix": .pipe
            case "Vmatrix": .doublePipe
            case "cases", "dcases": .cases
            case "aligned", "align", "align*", "eqnarray", "eqnarray*", "split": .aligned
            case "gathered", "gather", "gather*", "multline", "multline*": .gathered
            default: .plain
            }

            var rows: [[[Node]]] = []
            var currentRow: [[Node]] = []

            while !isAtEnd {
                let cell = parseExpression(stoppingAt: ["&", "\\\\", "\\end"])
                currentRow.append(cell)

                skipWhitespace()
                if peek() == "&" {
                    advance()
                    continue
                }
                if peek() == "\\", peek(1) == "\\" {
                    advance()
                    advance()
                    // Optional vertical spacing like \\[4pt]
                    _ = parseOptionalBracketGroup()
                    rows.append(currentRow)
                    currentRow = []
                    continue
                }
                if peek() == "\\" {
                    let saved = index
                    if readCommandName() == "end" {
                        _ = readRawBraceText()
                        break
                    } else {
                        index = saved
                        break
                    }
                }
                break
            }

            if !currentRow.isEmpty && !(currentRow.count == 1 && currentRow[0].isEmpty) {
                rows.append(currentRow)
            }

            // Single-row equation/equation* just unwraps cleanly.
            if (name == "equation" || name == "equation*") && rows.count == 1 && rows[0].count == 1 {
                return .group(rows[0][0])
            }
            return .matrix(kind: kind, rows: rows)
        }

        private func renderPlain(_ nodes: [Node]) -> String {
            LatexMath.inlineRuns(from: nodes).map(\.text).joined()
        }

        private func mapBlackboard(_ raw: String) -> String {
            let map: [Character: String] = [
                "C": "ℂ", "H": "ℍ", "N": "ℕ", "P": "ℙ", "Q": "ℚ", "R": "ℝ", "Z": "ℤ",
            ]
            return raw.map { map[$0] ?? String($0) }.joined()
        }
    }

    // MARK: - Inline Attributed Runs

    /// Converts LaTeX source into flat styled runs suitable for inline rendering
    /// inside a continuous selectable `AttributedString`.
    public static func inlineRuns(_ source: String) -> [InlineRun] {
        inlineRuns(from: parse(source))
    }

    public static func inlineRuns(from nodes: [Node], role: InlineRole = .normal) -> [InlineRun] {
        var out: [InlineRun] = []

        func appendRun(_ text: String, italic: Bool = false, bold: Bool = false, monospaced: Bool = false, role: InlineRole = role) {
            guard !text.isEmpty else { return }
            if let last = out.last,
                last.italic == italic,
                last.bold == bold,
                last.monospaced == monospaced,
                last.role == role
            {
                out[out.count - 1].text += text
            } else {
                out.append(InlineRun(text: text, italic: italic, bold: bold, monospaced: monospaced, role: role))
            }
        }

        for node in nodes {
            switch node {
            case .symbol(let s, let italic):
                appendRun(s, italic: italic)
            case .binaryOp(let op):
                appendRun(role == .normal ? " \(op) " : op)
            case .relation(let rel):
                appendRun(role == .normal ? " \(rel) " : rel)
            case .bigOp(let op, _):
                appendRun(op)
            case .text(let s, let style):
                appendRun(
                    s,
                    italic: style == .italic || style == .calligraphic,
                    bold: style == .bold,
                    monospaced: style == .monospace)
            case .script(let base, let sub, let sup, _):
                out.append(contentsOf: inlineRuns(from: [base], role: role))
                if let sub, !sub.isEmpty {
                    out.append(contentsOf: inlineRuns(from: sub, role: .sub))
                }
                if let sup, !sup.isEmpty {
                    out.append(contentsOf: inlineRuns(from: sup, role: .sup))
                }
            case .fraction(let num, let den, let hasBar):
                let numRuns = inlineRuns(from: num, role: role)
                let denRuns = inlineRuns(from: den, role: role)
                let numText = numRuns.map(\.text).joined()
                let denText = denRuns.map(\.text).joined()
                if hasBar, let pretty = commonFraction(numText, denText) {
                    appendRun(pretty)
                } else {
                    let wrapNum = num.count > 1 && hasBar
                    let wrapDen = den.count > 1 && hasBar
                    if wrapNum { appendRun("(") }
                    out.append(contentsOf: numRuns)
                    if wrapNum { appendRun(")") }
                    appendRun(hasBar ? "/" : " choose ")
                    if wrapDen { appendRun("(") }
                    out.append(contentsOf: denRuns)
                    if wrapDen { appendRun(")") }
                }
            case .radical(let idx, let body):
                if let idx, !idx.isEmpty {
                    out.append(contentsOf: inlineRuns(from: idx, role: .sup))
                }
                appendRun("√(")
                out.append(contentsOf: inlineRuns(from: body, role: role))
                appendRun(")")
            case .accent(let kind, let body):
                let combining: String = switch kind {
                case .hat: "\u{0302}"
                case .bar: "\u{0304}"
                case .vec: "\u{20D7}"
                case .dot: "\u{0307}"
                case .ddot: "\u{0308}"
                case .tilde: "\u{0303}"
                case .underline: "\u{0332}"
                }
                var inner = inlineRuns(from: body, role: role)
                if !inner.isEmpty {
                    inner[inner.count - 1].text += combining
                }
                out.append(contentsOf: inner)
            case .delimited(let left, let right, let body):
                if !left.isEmpty { appendRun(left) }
                out.append(contentsOf: inlineRuns(from: body, role: role))
                if !right.isEmpty { appendRun(right) }
            case .matrix(let kind, let rows):
                let open: String = switch kind {
                case .paren: "("
                case .bracket: "["
                case .brace, .cases: "{"
                case .pipe: "|"
                case .doublePipe: "‖"
                default: ""
                }
                let close: String = switch kind {
                case .paren: ")"
                case .bracket: "]"
                case .brace: "}"
                case .pipe: "|"
                case .doublePipe: "‖"
                default: ""
                }
                if !open.isEmpty { appendRun(open) }
                for (rIdx, row) in rows.enumerated() {
                    if rIdx > 0 { appendRun("; ") }
                    for (cIdx, cell) in row.enumerated() {
                        if cIdx > 0 { appendRun(", ") }
                        out.append(contentsOf: inlineRuns(from: cell, role: role))
                    }
                }
                if !close.isEmpty { appendRun(close) }
            case .space(let width):
                if width > 0 { appendRun(" ") }
            case .group(let inner):
                out.append(contentsOf: inlineRuns(from: inner, role: role))
            }
        }

        return out
    }

    private static func commonFraction(_ num: String, _ den: String) -> String? {
        switch (num.trimmingCharacters(in: .whitespaces), den.trimmingCharacters(in: .whitespaces)) {
        case ("1", "2"): "½"
        case ("1", "3"): "⅓"
        case ("2", "3"): "⅔"
        case ("1", "4"): "¼"
        case ("3", "4"): "¾"
        default: nil
        }
    }

    // MARK: - Symbol Tables

    private static let italicGreek: Set<String> = [
        "alpha", "beta", "gamma", "delta", "epsilon", "varepsilon", "zeta", "eta",
        "theta", "vartheta", "iota", "kappa", "lambda", "mu", "nu", "xi",
        "pi", "varpi", "rho", "varrho", "sigma", "varsigma", "tau", "upsilon",
        "phi", "varphi", "chi", "psi", "omega", "ell",
    ]

    private static let romanFunctions: Set<String> = [
        "sin", "cos", "tan", "cot", "sec", "csc",
        "arcsin", "arccos", "arctan", "sinh", "cosh", "tanh", "coth",
        "log", "ln", "lg", "exp", "arg", "deg", "dim", "gcd", "hom", "ker",
        "Pr", "Re", "Im", "Tr", "tr", "rank", "diag", "sgn", "mod",
    ]

    private static let bigOperators: [String: (symbol: String, limits: Bool)] = [
        "sum": ("∑", true),
        "prod": ("∏", true),
        "coprod": ("∐", true),
        "int": ("∫", false),
        "iint": ("∬", false),
        "iiint": ("∭", false),
        "oint": ("∮", false),
        "bigcup": ("⋃", true),
        "bigcap": ("⋂", true),
        "bigoplus": ("⨁", true),
        "bigotimes": ("⨂", true),
        "lim": ("lim", true),
        "limsup": ("lim sup", true),
        "liminf": ("lim inf", true),
        "sup": ("sup", true),
        "inf": ("inf", true),
        "max": ("max", true),
        "min": ("min", true),
        "det": ("det", true),
        "argmin": ("arg min", true),
        "argmax": ("arg max", true),
    ]

    private static let binaryOperators: [String: String] = [
        "pm": "±",
        "mp": "∓",
        "times": "×",
        "cdot": "·",
        "div": "÷",
        "ast": "∗",
        "star": "⋆",
        "circ": "∘",
        "bullet": "•",
        "oplus": "⊕",
        "ominus": "⊖",
        "otimes": "⊗",
        "oslash": "⊘",
        "odot": "⊙",
        "wedge": "∧",
        "land": "∧",
        "vee": "∨",
        "lor": "∨",
        "cap": "∩",
        "cup": "∪",
        "setminus": "∖",
        "dagger": "†",
        "ddagger": "‡",
    ]

    private static let relations: [String: String] = [
        "leq": "≤",
        "le": "≤",
        "geq": "≥",
        "ge": "≥",
        "neq": "≠",
        "ne": "≠",
        "approx": "≈",
        "equiv": "≡",
        "propto": "∝",
        "sim": "∼",
        "simeq": "≃",
        "cong": "≅",
        "ll": "≪",
        "gg": "≫",
        "in": "∈",
        "notin": "∉",
        "ni": "∋",
        "subset": "⊂",
        "subseteq": "⊆",
        "supset": "⊃",
        "supseteq": "⊇",
        "to": "→",
        "rightarrow": "→",
        "leftarrow": "←",
        "leftrightarrow": "↔",
        "Rightarrow": "⇒",
        "Leftarrow": "⇐",
        "Leftrightarrow": "⇔",
        "implies": "⇒",
        "iff": "⇔",
        "mapsto": "↦",
        "perp": "⊥",
        "parallel": "∥",
        "mid": "∣",
        "vdash": "⊢",
        "models": "⊨",
        "triangleq": "≜",
        "coloneqq": "≔",
    ]

    private static let symbols: [String: String] = [
        // Lowercase Greek
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ",
        "epsilon": "ϵ", "varepsilon": "ε", "zeta": "ζ", "eta": "η",
        "theta": "θ", "vartheta": "ϑ", "iota": "ι", "kappa": "κ",
        "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ",
        "pi": "π", "varpi": "ϖ", "rho": "ρ", "varrho": "ϱ",
        "sigma": "σ", "varsigma": "ς", "tau": "τ", "upsilon": "υ",
        "phi": "ϕ", "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
        // Uppercase Greek
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ",
        "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ", "Upsilon": "Υ",
        "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
        // Calculus, Physics & Logic
        "partial": "∂", "nabla": "∇", "hbar": "ℏ", "hslash": "ℏ",
        "infty": "∞", "ell": "ℓ", "aleph": "ℵ", "wp": "℘",
        "emptyset": "∅", "varnothing": "∅",
        "forall": "∀", "exists": "∃", "nexists": "∄", "neg": "¬", "lnot": "¬",
        "angle": "∠", "triangle": "△", "square": "□", "Box": "□", "Diamond": "◇",
        "prime": "′", "deg": "°", "degree": "°", "AA": "Å",
        "cdots": "⋯", "ldots": "…", "dots": "…", "vdots": "⋮", "ddots": "⋱",
        "langle": "⟨", "rangle": "⟩", "lfloor": "⌊", "rfloor": "⌋", "lceil": "⌈", "rceil": "⌉",
        "vert": "|", "lvert": "|", "rvert": "|", "Vert": "‖", "lVert": "‖", "rVert": "‖",
        "therefore": "∴", "because": "∵", "checkmark": "✓",
    ]
}
