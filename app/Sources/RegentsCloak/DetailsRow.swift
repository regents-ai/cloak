import CloakSupervisor
import SwiftUI

/// The details of the message being written (decision 13 in docs/plan.md),
/// above its box: a pill for each, which opens its picker. A picked pill
/// shows its value and can be cleared. Nothing while there are none.
struct DetailsRow: View {
    let chat: Chat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let picks = chat.picks
        if !picks.details.isEmpty {
            Wrap(spacing: 6) {
                ForEach(Array(picks.details.enumerated()), id: \.offset) { index, detail in
                    Pill(detail: detail, pick: picks.picks[index]) { chat.pick($0, at: index) }
                        // A new answer's detail is a new pill, its picker closed.
                        .id(detail)
                }
                if chat.askingDetails {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityLabel("Updating")
                }
            }
            .font(.callout)
            .animation(reduceMotion ? nil : .snappy(duration: 0.15), value: picks.picks)
            .transition(.opacity)
        }
    }
}

/// One detail: its label, and its value once picked, with a clear button.
private struct Pill: View {
    let detail: Detail
    let pick: DetailPicks.Pick?
    let choose: (DetailPicks.Pick?) -> Void
    @State private var open = false

    var body: some View {
        let value = pick.map { DetailPicks.value(of: $0, for: detail) }
        HStack(spacing: 2) {
            Button {
                open = true
            } label: {
                HStack(spacing: 5) {
                    Text(detail.label)
                        .fontWeight(value == nil ? .regular : .medium)
                    if let value {
                        Text(value)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .frame(maxWidth: 260, alignment: .leading)
                .padding(.leading, 10)
                .padding(.trailing, value == nil ? 10 : 2)
                .frame(minHeight: 24)
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .help(detail.question)
            .accessibilityLabel(detail.label)
            .accessibilityValue(value ?? "")
            .accessibilityHint(detail.question)
            .popover(isPresented: $open, arrowEdge: .top) {
                DetailPicker(detail: detail, pick: pick, choose: choose)
            }
            if value != nil {
                Button("Clear \(detail.label)", systemImage: "xmark") { choose(nil) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 24)
                    .contentShape(.rect)
                    .help("Clear")
            }
        }
        .foregroundStyle(value == nil ? .secondary : .primary)
        .background {
            if value == nil {
                Capsule().strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            } else {
                Capsule().fill(.quaternary.opacity(0.6))
                    .overlay(Capsule().strokeBorder(.separator))
            }
        }
    }
}

/// A detail's question, its picker, and Something else.
private struct DetailPicker: View {
    let detail: Detail
    let pick: DetailPicks.Pick?
    let choose: (DetailPicks.Pick?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(detail.question)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            switch detail.picker {
            case .options(let options, let many):
                Options(options: options, many: many, pick: pick, choose: choose)
            case .range(let low, let high, let unit):
                RangePicker(detail: detail, bounds: low...high, unit: unit, pick: pick, choose: choose)
            case .colors(let swatches):
                Colors(swatches: swatches, pick: pick, choose: choose)
            case .pad(let left, let right, let top, let bottom):
                Pad(ends: (left, right, top, bottom), pick: pick, choose: choose)
            }
            TextField("Something else", text: Binding {
                if case .other(let text) = pick { text } else { "" }
            } set: { text in
                if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                    choose(.other(text))
                } else if case .other = pick {
                    choose(nil)
                }
            })
            .textFieldStyle(.roundedBorder)
        }
        .padding(16)
        .frame(width: 300)
    }
}

/// Chips, one chosen or several.
private struct Options: View {
    let options: [Detail.Option]
    let many: Bool
    let pick: DetailPicks.Pick?
    let choose: (DetailPicks.Pick?) -> Void

    var body: some View {
        let chosen: Set<Int> = if case .options(let chosen) = pick { chosen } else { [] }
        Wrap(spacing: 6) {
            ForEach(options.indices, id: \.self) { index in
                let on = chosen.contains(index)
                Button {
                    var next = many ? chosen : []
                    if on { next.remove(index) } else { next.insert(index) }
                    choose(next.isEmpty ? nil : .options(next))
                } label: {
                    HStack(spacing: 4) {
                        if !options[index].mark.isEmpty {
                            Text(options[index].mark)
                                .accessibilityHidden(true)
                        }
                        Text(options[index].text)
                    }
                    .padding(.horizontal, 10)
                    .frame(minHeight: 26)
                    .foregroundStyle(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    .background(on ? AnyShapeStyle(.tint.opacity(0.12)) : AnyShapeStyle(.clear), in: .capsule)
                    .overlay(Capsule().strokeBorder(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator)))
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(options[index].text)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

/// Filled circles, the chosen one ringed with its name under it.
private struct Colors: View {
    let swatches: [Detail.Swatch]
    let pick: DetailPicks.Pick?
    let choose: (DetailPicks.Pick?) -> Void

    var body: some View {
        HStack(spacing: 12) {
            ForEach(swatches.indices, id: \.self) { index in
                let on = pick == .color(index)
                Button {
                    choose(on ? nil : .color(index))
                } label: {
                    Circle()
                        .fill(Color(hex: swatches[index].hex))
                        .overlay(Circle().strokeBorder(.separator))
                        .frame(width: 28, height: 28)
                        .padding(3)
                        .overlay(Circle().strokeBorder(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 2))
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .help(swatches[index].name)
                .accessibilityLabel(swatches[index].name)
                .accessibilityAddTraits(on ? .isSelected : [])
                .overlay(alignment: .top) {
                    if on {
                        Text(swatches[index].name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .offset(y: 40)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity)
    }
}

/// A two-ended slider over the detail's span, in steps that suit it.
private struct RangePicker: View {
    private enum End { case low, high }

    let detail: Detail
    let bounds: ClosedRange<Int>
    let unit: String
    let pick: DetailPicks.Pick?
    let choose: (DetailPicks.Pick?) -> Void
    @State private var dragging: End?
    @FocusState private var focus: End?

    private static let thumb: CGFloat = 18

    var body: some View {
        let (low, high) = if case .range(let low, let high) = pick { (low, high) } else { (bounds.lowerBound, bounds.upperBound) }
        VStack(spacing: 8) {
            Text(DetailPicks.value(of: .range(low: low, high: high), for: detail))
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(pick == nil ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHidden(true)
            GeometryReader { geometry in
                let width = geometry.size.width - Self.thumb
                let x = { (value: Int) in Self.thumb / 2 + width * fraction(value) }
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                        .frame(height: 4)
                    Capsule().fill(pick == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tint))
                        .frame(width: x(high) - x(low), height: 4)
                        .offset(x: x(low))
                    thumb(.low, value: low, others: (low, high))
                        .position(x: x(low), y: geometry.size.height / 2)
                    thumb(.high, value: high, others: (low, high))
                        .position(x: x(high), y: geometry.size.height / 2)
                }
                .frame(maxHeight: .infinity)
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            let value = value(at: (drag.location.x - Self.thumb / 2) / width)
                            let end = dragging ?? (abs(value - low) <= abs(value - high) ? .low : .high)
                            dragging = end
                            set(end, to: value, in: (low, high))
                        }
                        .onEnded { _ in dragging = nil })
            }
            .frame(height: 28)
            HStack {
                Text(bounds.lowerBound, format: .number.grouping(.never))
                Spacer()
                Text(bounds.upperBound, format: .number.grouping(.never))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
    }

    private func thumb(_ end: End, value: Int, others: (Int, Int)) -> some View {
        Circle()
            .fill(.white)
            .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
            .overlay(Circle().strokeBorder(.separator))
            .frame(width: Self.thumb, height: Self.thumb)
            .focusable()
            .focused($focus, equals: end)
            .onKeyPress(keys: [.leftArrow, .downArrow, .rightArrow, .upArrow]) { press in
                step(end, from: value, up: press.key == .rightArrow || press.key == .upArrow, in: others)
                return .handled
            }
            .accessibilityElement()
            .accessibilityLabel(end == .low ? "Minimum" : "Maximum")
            .accessibilityValue(unit.isEmpty ? "\(value)" : "\(value) \(unit)")
            .accessibilityAdjustableAction { direction in
                step(end, from: value, up: direction == .increment, in: others)
            }
    }

    /// A step that keeps the slider to a hundred stops or so: 1, 10, 100…
    private var step: Int {
        var step = 1
        while (bounds.upperBound - bounds.lowerBound) / step > 100 { step *= 10 }
        return step
    }

    private func fraction(_ value: Int) -> CGFloat {
        CGFloat(value - bounds.lowerBound) / CGFloat(bounds.upperBound - bounds.lowerBound)
    }

    /// The stop nearest a place on the track: a multiple of the step, or
    /// either end of the span.
    private func value(at fraction: CGFloat) -> Int {
        let raw = Double(bounds.lowerBound) + Double(min(max(fraction, 0), 1)) * Double(bounds.upperBound - bounds.lowerBound)
        let snapped = min(max(Int((raw / Double(step)).rounded()) * step, bounds.lowerBound), bounds.upperBound)
        return [snapped, bounds.lowerBound, bounds.upperBound].min { abs(Double($0) - raw) < abs(Double($1) - raw) }!
    }

    /// The next stop up or down from `value`.
    private func step(_ end: End, from value: Int, up: Bool, in span: (Int, Int)) {
        let place = Double(value) / Double(step)
        let next = up ? Int(place.rounded(.down) + 1) * step : Int(place.rounded(.up) - 1) * step
        set(end, to: min(max(next, bounds.lowerBound), bounds.upperBound), in: span)
    }

    /// Moves one end, never past the other.
    private func set(_ end: End, to value: Int, in span: (low: Int, high: Int)) {
        switch end {
        case .low: choose(.range(low: min(value, span.high), high: span.high))
        case .high: choose(.range(low: span.low, high: max(value, span.low)))
        }
    }
}

/// A square with a word at each edge and a dot that settles in one of its
/// nine cells: the middle one picks nothing.
private struct Pad: View {
    let ends: (left: String, right: String, top: String, bottom: String)
    let pick: DetailPicks.Pick?
    let choose: (DetailPicks.Pick?) -> Void
    @State private var dragged: CGPoint?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let side: CGFloat = 220

    var body: some View {
        let (x, y) = if case .pad(let x, let y) = pick { (x, y) } else { (0, 0) }
        let cell = Self.side / 3
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5))
            RoundedRectangle(cornerRadius: 10).strokeBorder(.separator)
            // The middle, where nothing is picked.
            Path { path in
                path.move(to: CGPoint(x: Self.side / 2, y: Self.side / 2 - 8))
                path.addLine(to: CGPoint(x: Self.side / 2, y: Self.side / 2 + 8))
                path.move(to: CGPoint(x: Self.side / 2 - 8, y: Self.side / 2))
                path.addLine(to: CGPoint(x: Self.side / 2 + 8, y: Self.side / 2))
            }
            .stroke(.tertiary, lineWidth: 1)
            word(ends.top, on: y == -1).frame(maxHeight: .infinity, alignment: .top)
            word(ends.bottom, on: y == 1).frame(maxHeight: .infinity, alignment: .bottom)
            word(ends.left, on: x == -1).frame(maxWidth: .infinity, alignment: .leading)
            word(ends.right, on: x == 1).frame(maxWidth: .infinity, alignment: .trailing)
            Circle()
                .fill(pick == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                .frame(width: 16, height: 16)
                .overlay(Circle().strokeBorder(.white.opacity(0.8), lineWidth: 2))
                .shadow(color: .black.opacity(0.2), radius: 1.5, y: 0.5)
                .position(dragged ?? CGPoint(x: cell * (CGFloat(x) + 1.5), y: cell * (CGFloat(y) + 1.5)))
                .focusable()
                .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                    switch press.key {
                    case .leftArrow: move(to: (x - 1, y))
                    case .rightArrow: move(to: (x + 1, y))
                    case .upArrow: move(to: (x, y - 1))
                    default: move(to: (x, y + 1))
                    }
                    return .handled
                }
                .accessibilityHidden(true)
        }
        .frame(width: Self.side, height: Self.side)
        .contentShape(.rect)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    let point = CGPoint(x: min(max(drag.location.x, 0), Self.side), y: min(max(drag.location.y, 0), Self.side))
                    dragged = point
                    move(to: (Self.third(point.x), Self.third(point.y)))
                }
                .onEnded { _ in
                    withAnimation(settle) { dragged = nil }
                })
        .animation(dragged == nil ? settle : nil, value: pick)
        .accessibilityElement(children: .contain)
        .accessibilityChildren {
            axis(ends.left, ends.right, at: x) { move(to: (x + $0, y)) }
            axis(ends.top, ends.bottom, at: y) { move(to: (x, y + $0)) }
        }
        .frame(maxWidth: .infinity)
    }

    /// How the dot settles in its cell; at once under Reduce Motion.
    private var settle: Animation? {
        reduceMotion ? nil : .spring(duration: 0.25, bounce: 0)
    }

    private func word(_ text: String, on: Bool) -> some View {
        Text(text)
            .font(.caption.weight(on ? .semibold : .regular))
            .foregroundStyle(on ? .primary : .secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 72)
            .padding(8)
            .accessibilityHidden(true)
    }

    /// One axis for VoiceOver, from one end's word to the other's.
    private func axis(_ from: String, _ to: String, at place: Int, move: @escaping (Int) -> Void) -> some View {
        Color.clear
            .accessibilityElement()
            .accessibilityLabel("\(from) or \(to)")
            .accessibilityValue([from, "Neither", to][place + 1])
            .accessibilityAdjustableAction { move($0 == .increment ? 1 : -1) }
    }

    /// Picks the cell, kept on the pad; the middle one picks nothing.
    private func move(to cell: (x: Int, y: Int)) {
        let x = min(max(cell.x, -1), 1), y = min(max(cell.y, -1), 1)
        let next: DetailPicks.Pick? = x == 0 && y == 0 ? nil : .pad(x: x, y: y)
        if next != pick { choose(next) }
    }

    /// The third of the side `place` is in: -1, 0 or 1.
    private static func third(_ place: CGFloat) -> Int {
        min(Int(place / (side / 3)), 2) - 1
    }
}

/// Lays out its views in rows, starting a new row where one is full; each
/// row's views centred on it.
private struct Wrap: SwiftUI.Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        rows(width: proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, frame) in rows(width: bounds.width, subviews).frames.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    private func rows(width: CGFloat, _ subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = [], row: [Int] = []
        var x: CGFloat = 0, y: CGFloat = 0, height: CGFloat = 0, widest: CGFloat = 0
        func endRow() {
            for index in row { frames[index].origin.y = y + (height - frames[index].height) / 2 }
            y += height + spacing
            row = []
            x = 0
            height = 0
        }
        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            if size.width > width { size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
            if !row.isEmpty, x + size.width > width { endRow() }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            row.append(frames.count - 1)
            x += size.width + spacing
            height = max(height, size.height)
            widest = max(widest, x - spacing)
        }
        endRow()
        return (frames, CGSize(width: widest, height: max(y - spacing, 0)))
    }
}

extension Color {
    /// A colour from `#rrggbb`.
    fileprivate init(hex: String) {
        let value = Int(hex.dropFirst(), radix: 16)!
        self.init(
            .sRGB, red: Double(value >> 16 & 0xFF) / 255, green: Double(value >> 8 & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255)
    }
}
