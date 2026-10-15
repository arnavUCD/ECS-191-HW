import SwiftUI

/// Bright Liquid Glass capsule for the single most important action on a screen.
struct SUPrimaryButtonStyle: ButtonStyle {
    var fullWidth = true

    func makeBody(configuration: Configuration) -> some View {
        SUGlassButtonStyle(kind: .prominent, fullWidth: fullWidth).makeBody(configuration: configuration)
    }
}

/// Clear Liquid Glass capsule for secondary actions.
struct SUSecondaryButtonStyle: ButtonStyle {
    var fullWidth = true

    func makeBody(configuration: Configuration) -> some View {
        SUGlassButtonStyle(kind: .regular, fullWidth: fullWidth).makeBody(configuration: configuration)
    }
}

/// Destructive capsule. Use only with an explanation of downstream effects nearby.
struct SUDestructiveButtonStyle: ButtonStyle {
    var fullWidth = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(SUFont.button)
            .foregroundStyle(SUColor.negative)
            .padding(.horizontal, SUSpacing.lg)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: 52)
            .background(SUColor.negative.opacity(configuration.isPressed ? 0.22 : 0.14), in: Capsule())
            .overlay { Capsule().strokeBorder(SUColor.negative.opacity(0.35), lineWidth: 1) }
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(SUMotion.press.resolved(reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == SUPrimaryButtonStyle {
    static var suPrimary: SUPrimaryButtonStyle { SUPrimaryButtonStyle() }
    static func suPrimary(fullWidth: Bool) -> SUPrimaryButtonStyle { SUPrimaryButtonStyle(fullWidth: fullWidth) }
}

extension ButtonStyle where Self == SUSecondaryButtonStyle {
    static var suSecondary: SUSecondaryButtonStyle { SUSecondaryButtonStyle() }
    static func suSecondary(fullWidth: Bool) -> SUSecondaryButtonStyle { SUSecondaryButtonStyle(fullWidth: fullWidth) }
}

extension ButtonStyle where Self == SUDestructiveButtonStyle {
    static var suDestructive: SUDestructiveButtonStyle { SUDestructiveButtonStyle() }
}

#Preview("Buttons", traits: .sizeThatFitsLayout) {
    VStack(spacing: SUSpacing.sm) {
        Button("Save expense") {}.buttonStyle(.suPrimary)
        Button("Save expense") {}.buttonStyle(.suPrimary).disabled(true)
        Button("Add a note") {}.buttonStyle(.suSecondary)
        Button("Remove receipt image") {}.buttonStyle(.suDestructive)
        Button("Settle up", systemImage: "checkmark.circle") {}.buttonStyle(.glassProminent)
    }
    .padding()
    .suScreenBackground()
    .squareUpTheme()
}
