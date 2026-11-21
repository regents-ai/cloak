import SwiftUI

/// A button drawn as its symbol alone, as the Mac's own toolbars draw one:
/// 28 points square, all of it answering the pointer, with the hover
/// (`Hover.swift`). Its name is its help and what VoiceOver reads.
struct SymbolButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    init(_ title: String, symbol: String, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .labelStyle(.iconOnly)
                .frame(width: 28, height: 28)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .hover(Circle())
        .help(title)
    }
}

extension View {
    /// For a control 28 points tall beside a line of text in a form's row:
    /// it overhangs the line, as an `InfoButton` does, so the row is no
    /// taller and its label sits level with the words.
    func overhanging() -> some View {
        padding(.vertical, -6)
    }
}

/// Send's look, for the button under Chat's message box and, smaller, a
/// card's Send: the symbol, white on the accent colour, in a circle
/// `diameter` points across, grey while off. At least 28 points square
/// answer the pointer, and the hover (`Hover.swift`) rings the circle.
struct RoundButtonStyle: ButtonStyle {
    var diameter: CGFloat = 26
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.iconOnly)
            .font(.system(size: diameter / 2, weight: .semibold))
            .foregroundStyle(isEnabled ? AnyShapeStyle(.white) : AnyShapeStyle(.tertiary))
            .frame(width: diameter, height: diameter)
            .background(isEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), in: Circle())
            .opacity(configuration.isPressed ? 0.75 : 1)
            .hover(Circle(), outset: 3)
            .frame(width: max(diameter, 28), height: max(diameter, 28))
            .contentShape(.rect)
    }
}
