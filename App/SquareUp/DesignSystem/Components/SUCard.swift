import SwiftUI

/// The standard content container: a translucent, top-lit surface with a bevelled edge, so the
/// dusk backdrop shows through faintly and cards read as one layer above it.
///
/// Cards are not Liquid Glass on purpose — glass is reserved for functional controls, and
/// financial text never sits on a blurred, moving layer.
struct SUCard<Content: View>: View {
    enum Style {
        case standard
        case elevated
    }

    var style: Style = .standard
    var padding: CGFloat = SUSpacing.md
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { SUBevel(shape: SUShape.card, elevated: style == .elevated) }
            .contentShape(SUShape.card)
    }
}

#Preview("Cards", traits: .sizeThatFitsLayout) {
    VStack(spacing: SUSpacing.md) {
        SUCard {
            VStack(alignment: .leading, spacing: SUSpacing.xxs) {
                Text("Apartment 4B").suText(.title)
                Text("3 members · Personal").suText(.secondary)
            }
        }
        SUCard(style: .elevated) {
            Text("An elevated card with a much longer description that needs to wrap across multiple lines without truncation.")
                .suText(.primary)
        }
    }
    .padding()
    .suScreenBackground()
    .squareUpTheme()
}
