import SwiftUI

/// The hover for anything clickable that macOS doesn't light up itself:
/// while the pointer is over it, a faint fill behind it in the caller's
/// shape, so it reads as clickable. It fades in and out, at once under
/// Reduce Motion, and shows nothing while the control is off or while
/// something else already marks it. On a glass pill it goes on before the
/// glass, so it lies on the glass rather than behind it.
private struct Hover<S: Shape>: ViewModifier {
    let shape: S
    /// How far the fill reaches past the view, which keeps its size, its
    /// place and the area that answers the pointer.
    let outset: CGFloat
    /// True while something else marks the view, as the selection's own
    /// highlight does a sidebar's chosen row.
    let marked: Bool
    @State private var inside = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            // The whole frame answers the pointer, gaps in a row included.
            .contentShape(.rect)
            .onHover { inside = $0 }
            .background {
                shape
                    // The label colour, never a tint set around it: black
                    // in light mode, white in dark.
                    .fill(Color.primary.opacity(0.08))
                    .padding(-outset)
                    .opacity(inside && isEnabled && !marked ? 1 : 0)
                    // Keyed to the pointer alone, so a row chosen under it
                    // gives way to the selection at once.
                    .animation(reduceMotion ? nil : .hover, value: inside)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}

extension View {
    /// The hover for a button: a faint fill in `shape`, reaching `outset`
    /// points past it all round (a bare icon's fill wants a little room;
    /// below 0, the fill stays inside).
    func hover(_ shape: some Shape, outset: CGFloat = 0) -> some View {
        modifier(Hover(shape: shape, outset: outset, marked: false))
    }

    /// A sidebar row's hover, the size and shape of the selection's own
    /// highlight: the row's width less 2 points each side, 8 points above
    /// and below its text (32 points tall), corners of 8. The row keeps its size, and the whole of
    /// that area answers the pointer, as a click anywhere in it chooses the
    /// row. None on the chosen row, which has the highlight.
    func sidebarHover(selected: Bool) -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
            .modifier(Hover(shape: RoundedRectangle(cornerRadius: 8), outset: 0, marked: selected))
            .padding(.horizontal, -6)
            .padding(.vertical, -8)
    }
}

extension Animation {
    /// How a hover fades in and out.
    static var hover: Animation { .easeOut(duration: 0.12) }
}
