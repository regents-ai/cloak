import Foundation

/// The details shown for the message being written, and what its owner has
/// picked for each (decision 13 in docs/plan.md). The first pick fixes the
/// set: a later answer no longer replaces it until it is cleared, as when the
/// message is submitted or its draft emptied.
public struct DetailPicks: Sendable, Equatable {
    /// What was picked for one detail.
    public enum Pick: Sendable, Equatable {
        /// The options chosen, by their place in the detail's list.
        case options(Set<Int>)
        /// Part of the detail's span, `low` at most `high`.
        case range(low: Int, high: Int)
        /// One colour, by its place in the detail's list.
        case color(Int)
        /// A cell of the pad, each of `x` and `y` -1, 0 or 1, not both 0:
        /// `x` from left to right, `y` from top to bottom.
        case pad(x: Int, y: Int)
        /// "Something else", as typed, not blank.
        case other(String)
    }

    public private(set) var details: [Detail] = []
    /// By detail, in the same order.
    public private(set) var picks: [Pick?] = []
    /// Something has been picked since the details were shown.
    public private(set) var fixed = false

    public init() {}

    /// Shows an answer's details in place of those shown, unless the set is
    /// fixed.
    public mutating func show(_ details: [Detail]) {
        guard !fixed else { return }
        self.details = details
        picks = details.map { _ in nil }
    }

    /// Picks for the detail at `index`, or clears its pick with nil. Any pick
    /// fixes the set, and it stays fixed when the pick is cleared.
    public mutating func pick(_ pick: Pick?, at index: Int) {
        picks[index] = pick
        if pick != nil { fixed = true }
    }

    /// The message to submit: the draft, then, after a blank line, one line
    /// `Label: value` for each detail picked. The draft alone when none is.
    public func message(_ draft: String) -> String {
        let lines = zip(details, picks).compactMap { detail, pick in
            pick.map { "\(detail.label): \(Self.value(of: $0, for: detail))" }
        }
        return lines.isEmpty ? draft : draft + "\n\n" + lines.joined(separator: "\n")
    }

    /// A pick as it reads in the message and on its detail's pill.
    public static func value(of pick: Pick, for detail: Detail) -> String {
        switch (pick, detail.picker) {
        case (.other(let text), _):
            return text.trimmingCharacters(in: .whitespaces)
        case (.options(let chosen), .options(let options, _)):
            return options.indices.filter(chosen.contains).map { options[$0].text }.joined(separator: ", ")
        case (.range(let low, let high), .range(_, _, let unit)):
            let span = low == high ? "\(low)" : "\(low)–\(high)"
            return unit.isEmpty ? span : "\(span) \(unit)"
        case (.color(let index), .colors(let swatches)):
            return swatches[index].name
        case (.pad(let x, let y), .pad(let left, let right, let top, let bottom)):
            return [[top, "", bottom][y + 1], [left, "", right][x + 1]].filter { !$0.isEmpty }.joined(separator: ", ")
        default:
            preconditionFailure("a pick of another kind than its detail")
        }
    }
}
