import AppKit
import CloakChat
import SwiftUI

/// Display LaTeX math block rendered natively in SwiftUI with horizontal
/// scrolling and a quiet top-right Copy LaTeX button matching `CodeBlock`.
struct MathBlock: View {
    let latex: String
    @State private var hovering = false
    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let nodes = LatexMath.parse(latex)
        ZStack(alignment: .topTrailing) {
            ScrollView(.horizontal) {
                MathNodesView(nodes: nodes, fontSize: 16.5)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .padding(.trailing, 24)
                    .frame(minWidth: 120)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .frame(maxWidth: .infinity, alignment: .center)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(latex, forType: .string)
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
            .opacity(hovering || copied ? 1 : 0.25)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovering)
            .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: copied)
            .tip(copied ? "Copied LaTeX" : "Copy LaTeX")
            .accessibilityLabel("Copy LaTeX")
        }
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.75))
        .onHover { hovering = $0 }
        .onDisappear { resetTask?.cancel() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Equation: \(latex)")
    }
}

/// Recursive SwiftUI math layout for a sequence of `LatexMath.Node` values.
private struct MathNodesView: View {
    let nodes: [LatexMath.Node]
    let fontSize: CGFloat

    var body: some View {
        HStack(alignment: .center, spacing: 1) {
            ForEach(nodes.indices, id: \.self) { index in
                MathNodeView(node: nodes[index], fontSize: fontSize)
            }
        }
    }
}

private struct MathNodeView: View {
    let node: LatexMath.Node
    let fontSize: CGFloat

    var body: some View {
        switch node {
        case .symbol(let text, let italic):
            Text(verbatim: text)
                .font(mathFont(size: fontSize, italic: italic))
        case .binaryOp(let op):
            Text(verbatim: op)
                .font(mathFont(size: fontSize, italic: false))
                .padding(.horizontal, max(2.5, fontSize * 0.2))
        case .relation(let rel):
            Text(verbatim: rel)
                .font(mathFont(size: fontSize, italic: false))
                .padding(.horizontal, max(3.5, fontSize * 0.28))
        case .bigOp(let op, _):
            let isWord = op.unicodeScalars.allSatisfy { $0.isASCII }
            Text(verbatim: op)
                .font(mathFont(size: isWord ? fontSize : fontSize * 1.45, italic: false))
                .padding(.horizontal, 2)
        case .text(let s, let style):
            Text(verbatim: s)
                .font(styledFont(style: style, size: fontSize))
        case .script(let base, let sub, let sup, let stacked):
            scriptView(base: base, sub: sub, sup: sup, stacked: stacked)
        case .fraction(let numerator, let denominator, let hasBar):
            let childSize = max(10.5, fontSize * 0.84)
            VStack(spacing: hasBar ? 2 : 3) {
                MathNodesView(nodes: numerator, fontSize: childSize)
                    .padding(.horizontal, 3)
                if hasBar {
                    Rectangle()
                        .fill(Color.primary.opacity(0.85))
                        .frame(height: 1)
                }
                MathNodesView(nodes: denominator, fontSize: childSize)
                    .padding(.horizontal, 3)
            }
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 3)
        case .radical(let index, let radicand):
            radicalView(index: index, radicand: radicand)
        case .accent(let kind, let body):
            accentView(kind: kind, body: body)
        case .delimited(let left, let right, let body):
            HStack(alignment: .center, spacing: 2) {
                if !left.isEmpty {
                    StretchDelimiter(symbol: left, fontSize: fontSize)
                }
                MathNodesView(nodes: body, fontSize: fontSize)
                if !right.isEmpty {
                    StretchDelimiter(symbol: right, fontSize: fontSize)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        case .matrix(let kind, let rows):
            matrixView(kind: kind, rows: rows)
        case .space(let width):
            Spacer()
                .frame(width: max(0, CGFloat(width)))
        case .group(let inner):
            MathNodesView(nodes: inner, fontSize: fontSize)
        }
    }

    @ViewBuilder
    private func scriptView(base: LatexMath.Node, sub: [LatexMath.Node]?, sup: [LatexMath.Node]?, stacked: Bool) -> some View {
        let scriptSize = max(9.5, fontSize * 0.68)
        if stacked {
            VStack(spacing: 1) {
                if let sup, !sup.isEmpty {
                    MathNodesView(nodes: sup, fontSize: scriptSize)
                }
                MathNodeView(node: base, fontSize: fontSize)
                if let sub, !sub.isEmpty {
                    MathNodesView(nodes: sub, fontSize: scriptSize)
                }
            }
            .padding(.horizontal, 2)
        } else {
            HStack(alignment: .center, spacing: 0.5) {
                MathNodeView(node: base, fontSize: fontSize)
                if let sup, !sup.isEmpty, let sub, !sub.isEmpty {
                    VStack(alignment: .leading, spacing: max(1, fontSize * 0.08)) {
                        MathNodesView(nodes: sup, fontSize: scriptSize)
                        MathNodesView(nodes: sub, fontSize: scriptSize)
                    }
                } else if let sup, !sup.isEmpty {
                    MathNodesView(nodes: sup, fontSize: scriptSize)
                        .offset(y: -fontSize * 0.36)
                } else if let sub, !sub.isEmpty {
                    MathNodesView(nodes: sub, fontSize: scriptSize)
                        .offset(y: fontSize * 0.32)
                }
            }
        }
    }

    @ViewBuilder
    private func radicalView(index: [LatexMath.Node]?, radicand: [LatexMath.Node]) -> some View {
        HStack(alignment: .bottom, spacing: 0) {
            ZStack(alignment: .topLeading) {
                RadicalHookShape()
                    .stroke(Color.primary.opacity(0.9), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                    .frame(width: max(10, fontSize * 0.65))
                if let index, !index.isEmpty {
                    MathNodesView(nodes: index, fontSize: max(8.5, fontSize * 0.56))
                        .offset(x: 1, y: -2)
                }
            }
            MathNodesView(nodes: radicand, fontSize: fontSize)
                .padding(.horizontal, 4)
                .padding(.top, 3)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.9))
                        .frame(height: 1.15)
                }
        }
        .fixedSize(horizontal: true, vertical: true)
        .padding(.horizontal, 2)
    }

    @ViewBuilder
    private func accentView(kind: LatexMath.Accent, body: [LatexMath.Node]) -> some View {
        switch kind {
        case .bar:
            VStack(spacing: 1) {
                Rectangle()
                    .fill(Color.primary.opacity(0.9))
                    .frame(height: 1)
                MathNodesView(nodes: body, fontSize: fontSize)
            }
            .fixedSize(horizontal: true, vertical: false)
        case .underline:
            VStack(spacing: 1) {
                MathNodesView(nodes: body, fontSize: fontSize)
                Rectangle()
                    .fill(Color.primary.opacity(0.9))
                    .frame(height: 1)
            }
            .fixedSize(horizontal: true, vertical: false)
        case .vec:
            VStack(spacing: -2) {
                Text("→")
                    .font(.system(size: max(9, fontSize * 0.58), design: .serif))
                MathNodesView(nodes: body, fontSize: fontSize)
            }
        case .hat:
            VStack(spacing: -4) {
                Text("^")
                    .font(.system(size: max(10, fontSize * 0.65), design: .serif))
                MathNodesView(nodes: body, fontSize: fontSize)
            }
        case .tilde:
            VStack(spacing: -4) {
                Text("˜")
                    .font(.system(size: max(10, fontSize * 0.65), design: .serif))
                MathNodesView(nodes: body, fontSize: fontSize)
            }
        case .dot:
            VStack(spacing: -4) {
                Text("·")
                    .font(.system(size: max(12, fontSize * 0.78), weight: .bold, design: .serif))
                MathNodesView(nodes: body, fontSize: fontSize)
            }
        case .ddot:
            VStack(spacing: -4) {
                Text("··")
                    .font(.system(size: max(10, fontSize * 0.66), weight: .bold, design: .serif))
                MathNodesView(nodes: body, fontSize: fontSize)
            }
        }
    }

    @ViewBuilder
    private func matrixView(kind: LatexMath.MatrixKind, rows: [[[LatexMath.Node]]]) -> some View {
        let content = Grid(horizontalSpacing: kind == .aligned ? 4 : 12, verticalSpacing: 6) {
            ForEach(rows.indices, id: \.self) { rowIdx in
                let row = rows[rowIdx]
                GridRow {
                    ForEach(row.indices, id: \.self) { colIdx in
                        let alignment: HorizontalAlignment =
                            if kind == .aligned {
                                colIdx.isMultiple(of: 2) ? .trailing : .leading
                            } else if kind == .cases {
                                .leading
                            } else {
                                .center
                            }
                        MathNodesView(nodes: row[colIdx], fontSize: fontSize)
                            .gridColumnAlignment(alignment)
                    }
                }
            }
        }
        .padding(.vertical, 2)

        switch kind {
        case .paren:
            HStack(spacing: 3) {
                StretchDelimiter(symbol: "(", fontSize: fontSize)
                content
                StretchDelimiter(symbol: ")", fontSize: fontSize)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .bracket:
            HStack(spacing: 3) {
                StretchDelimiter(symbol: "[", fontSize: fontSize)
                content
                StretchDelimiter(symbol: "]", fontSize: fontSize)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .brace:
            HStack(spacing: 3) {
                StretchDelimiter(symbol: "{", fontSize: fontSize)
                content
                StretchDelimiter(symbol: "}", fontSize: fontSize)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .cases:
            HStack(spacing: 5) {
                StretchDelimiter(symbol: "{", fontSize: fontSize)
                content
            }
            .fixedSize(horizontal: false, vertical: true)
        case .pipe:
            HStack(spacing: 3) {
                StretchDelimiter(symbol: "|", fontSize: fontSize)
                content
                StretchDelimiter(symbol: "|", fontSize: fontSize)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .doublePipe:
            HStack(spacing: 3) {
                StretchDelimiter(symbol: "‖", fontSize: fontSize)
                content
                StretchDelimiter(symbol: "‖", fontSize: fontSize)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .plain, .aligned, .gathered:
            content
        }
    }

    private func mathFont(size: CGFloat, italic: Bool) -> Font {
        let base = Font.system(size: size, design: .serif)
        return italic ? base.italic() : base
    }

    private func styledFont(style: LatexMath.TextStyle, size: CGFloat) -> Font {
        switch style {
        case .roman, .blackboard:
            .system(size: size, design: .serif)
        case .bold:
            .system(size: size, weight: .bold, design: .serif)
        case .italic, .calligraphic:
            .system(size: size, design: .serif).italic()
        case .monospace:
            .system(size: size * 0.9, design: .monospaced)
        case .sansSerif:
            .system(size: size, design: .default)
        }
    }
}

/// Vector radical hook (`√` left half) that scales cleanly to match the height
/// of any radicand (including tall fractions).
private struct RadicalHookShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let startY = rect.minY + rect.height * 0.56
        let hookX = rect.minX + rect.width * 0.25
        let bottomX = rect.minX + rect.width * 0.52
        path.move(to: CGPoint(x: rect.minX, y: startY + 2))
        path.addLine(to: CGPoint(x: hookX, y: startY))
        path.addLine(to: CGPoint(x: bottomX, y: rect.maxY - 1))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + 0.6))
        return path
    }
}

/// Height-adaptive delimiter for `\left...\right` and matrix brackets.
private struct StretchDelimiter: View {
    let symbol: String
    let fontSize: CGFloat

    var body: some View {
        switch symbol {
        case "(", ")", "[", "]", "{", "}", "|", "‖", "⟨", "⟩":
            DelimiterShape(symbol: symbol)
                .stroke(Color.primary.opacity(0.9), style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
                .frame(width: symbol == "|" ? 3 : (symbol == "‖" ? 6 : max(6, fontSize * 0.42)))
                .padding(.vertical, 1)
        default:
            Text(verbatim: symbol)
                .font(.system(size: fontSize, design: .serif))
        }
    }
}

private struct DelimiterShape: Shape {
    let symbol: String

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width
        let h = rect.height
        switch symbol {
        case "(":
            p.move(to: CGPoint(x: w * 0.85, y: 0))
            p.addQuadCurve(to: CGPoint(x: w * 0.85, y: h), control: CGPoint(x: -w * 0.15, y: h * 0.5))
        case ")":
            p.move(to: CGPoint(x: w * 0.15, y: 0))
            p.addQuadCurve(to: CGPoint(x: w * 0.15, y: h), control: CGPoint(x: w * 1.15, y: h * 0.5))
        case "[":
            p.move(to: CGPoint(x: w * 0.9, y: 0))
            p.addLine(to: CGPoint(x: w * 0.25, y: 0))
            p.addLine(to: CGPoint(x: w * 0.25, y: h))
            p.addLine(to: CGPoint(x: w * 0.9, y: h))
        case "]":
            p.move(to: CGPoint(x: w * 0.1, y: 0))
            p.addLine(to: CGPoint(x: w * 0.75, y: 0))
            p.addLine(to: CGPoint(x: w * 0.75, y: h))
            p.addLine(to: CGPoint(x: w * 0.1, y: h))
        case "{":
            p.move(to: CGPoint(x: w * 0.9, y: 0))
            p.addCurve(
                to: CGPoint(x: w * 0.15, y: h * 0.5),
                control1: CGPoint(x: w * 0.35, y: h * 0.05),
                control2: CGPoint(x: w * 0.65, y: h * 0.45))
            p.addCurve(
                to: CGPoint(x: w * 0.9, y: h),
                control1: CGPoint(x: w * 0.65, y: h * 0.55),
                control2: CGPoint(x: w * 0.35, y: h * 0.95))
        case "}":
            p.move(to: CGPoint(x: w * 0.1, y: 0))
            p.addCurve(
                to: CGPoint(x: w * 0.85, y: h * 0.5),
                control1: CGPoint(x: w * 0.65, y: h * 0.05),
                control2: CGPoint(x: w * 0.35, y: h * 0.45))
            p.addCurve(
                to: CGPoint(x: w * 0.1, y: h),
                control1: CGPoint(x: w * 0.35, y: h * 0.55),
                control2: CGPoint(x: w * 0.65, y: h * 0.95))
        case "|":
            p.move(to: CGPoint(x: w * 0.5, y: 0))
            p.addLine(to: CGPoint(x: w * 0.5, y: h))
        case "‖":
            p.move(to: CGPoint(x: w * 0.28, y: 0))
            p.addLine(to: CGPoint(x: w * 0.28, y: h))
            p.move(to: CGPoint(x: w * 0.72, y: 0))
            p.addLine(to: CGPoint(x: w * 0.72, y: h))
        case "⟨":
            p.move(to: CGPoint(x: w * 0.85, y: 0))
            p.addLine(to: CGPoint(x: w * 0.15, y: h * 0.5))
            p.addLine(to: CGPoint(x: w * 0.85, y: h))
        case "⟩":
            p.move(to: CGPoint(x: w * 0.15, y: 0))
            p.addLine(to: CGPoint(x: w * 0.85, y: h * 0.5))
            p.addLine(to: CGPoint(x: w * 0.15, y: h))
        default:
            break
        }
        return p
    }
}
