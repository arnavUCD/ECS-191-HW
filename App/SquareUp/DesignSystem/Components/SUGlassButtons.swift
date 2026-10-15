import SwiftUI

/// Liquid Glass capsules for the dusk screens. `prominent` is the one main action (bright glass,
/// dark label); `regular` is clear glass for the alternative. The glass is interactive, so it
/// responds to touch the way system controls do, with a soft tap on press. Reduce Transparency and
/// Increase Contrast are handled by the system's glass.
struct SUGlassButtonStyle: ButtonStyle {
    nonisolated enum Kind { case prominent, regular }

    var kind: Kind
    var fullWidth = true

    // The look lives in a view so its environment (enabled, Reduce Motion) is always resolved,
    // even when another style forwards to this one.
    func makeBody(configuration: Configuration) -> some View {
        SUGlassButtonBody(configuration: configuration, kind: kind, fullWidth: fullWidth)
    }
}

private struct SUGlassButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: SUGlassButtonStyle.Kind
    let fullWidth: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .font(SUFont.button)
            .foregroundStyle(kind == .prominent ? Color.black : SUColor.textPrimary)
            // On the bright glass, secondary content (a progress spinner) resolves dark.
            .modifier(BrightGlassContent(isActive: kind == .prominent))
            .padding(.horizontal, SUSpacing.lg)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: 54)
            .contentShape(Capsule())
            .glassEffect(glass, in: Capsule())
            .opacity(isEnabled ? 1 : 0.5)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(SUMotion.press.resolved(reduceMotion: reduceMotion), value: configuration.isPressed)
            .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.55), trigger: configuration.isPressed) { _, isPressed in isPressed }
    }

    private var glass: Glass {
        switch kind {
        case .prominent: .regular.tint(.white).interactive(isEnabled)
        case .regular: .regular.interactive(isEnabled)
        }
    }
}

private struct BrightGlassContent: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        if isActive {
            content.environment(\.colorScheme, .light)
        } else {
            content
        }
    }
}

extension ButtonStyle where Self == SUGlassButtonStyle {
    static var suGlassPrimary: SUGlassButtonStyle { SUGlassButtonStyle(kind: .prominent) }
    static var suGlassSecondary: SUGlassButtonStyle { SUGlassButtonStyle(kind: .regular) }
}

#Preview("Glass buttons") {
    ZStack {
        SUDuskBackdrop(style: .hero).ignoresSafeArea()
        GlassEffectContainer {
            VStack(spacing: SUSpacing.sm) {
                Button("Create account") {}.buttonStyle(.suGlassPrimary)
                Button("Sign in") {}.buttonStyle(.suGlassSecondary)
                Button("Sign in") {}.buttonStyle(.suGlassPrimary).disabled(true)
            }
        }
        .padding(SUSpacing.screenMargin)
    }
    .environment(\.colorScheme, .dark)
}
