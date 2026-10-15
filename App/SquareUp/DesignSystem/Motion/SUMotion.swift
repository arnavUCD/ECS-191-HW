import SwiftUI

/// The motion vocabulary (CLAUDE.md §5.4). Every animation in the app is one of these.
///
/// With Reduce Motion enabled, movement collapses to a short cross-fade so state changes stay
/// visible without travel, scale, or bounce.
enum SUMotion: Sendable {
    /// Quick response to a touch.
    case press
    /// Cards and sheets appearing.
    case reveal
    /// Matched movement between a source and a destination.
    case transfer
    /// Success: checkmark, amount roll, haptic.
    case confirm
    /// One restrained pulse. Never repeating.
    case attention
    /// Allocations changing to new values.
    case reconcile

    var animation: Animation {
        switch self {
        case .press: .spring(duration: 0.18, bounce: 0)
        case .reveal: .spring(duration: 0.45, bounce: 0.12)
        case .transfer: .smooth(duration: 0.5)
        case .confirm: .spring(duration: 0.55, bounce: 0.28)
        case .attention: .easeInOut(duration: 0.6)
        case .reconcile: .snappy(duration: 0.35)
        }
    }

    static let reducedMotionFallback = Animation.easeInOut(duration: 0.18)

    func resolved(reduceMotion: Bool) -> Animation {
        reduceMotion ? Self.reducedMotionFallback : animation
    }
}

private struct SUAnimationModifier<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let motion: SUMotion
    let value: Value

    func body(content: Content) -> some View {
        content.animation(motion.resolved(reduceMotion: reduceMotion), value: value)
    }
}

extension View {
    /// Animates changes to `value` using a vocabulary motion, respecting Reduce Motion.
    func suAnimation(_ motion: SUMotion, value: some Equatable) -> some View {
        modifier(SUAnimationModifier(motion: motion, value: value))
    }
}

/// Runs a state change inside a vocabulary animation, respecting Reduce Motion.
@MainActor
func withSUAnimation<Result>(_ motion: SUMotion, reduceMotion: Bool, _ body: () throws -> Result) rethrows -> Result {
    try withAnimation(motion.resolved(reduceMotion: reduceMotion), body)
}

/// Press feedback for tappable cards and tiles: scale + dim, or dim only with Reduce Motion.
struct SUPressableStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(SUMotion.press.resolved(reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == SUPressableStyle {
    static var suPressable: SUPressableStyle { SUPressableStyle() }
}

/// Content rising into place once, in order of importance, when a screen first paints. Later
/// rows start a beat after earlier ones. Static under Reduce Motion; a short fade in the scroll
/// transition keeps depth without travel.
private struct SURiseModifier: ViewModifier {
    let order: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isRisen = false

    func body(content: Content) -> some View {
        let reduceMotion = reduceMotion
        return content
            .opacity(isRisen || reduceMotion ? 1 : 0)
            .offset(y: isRisen || reduceMotion ? 0 : 14)
            .scrollTransition(.interactive, axis: .vertical) { view, phase in
                view
                    .opacity(phase.isIdentity ? 1 : 0.6)
                    .scaleEffect(phase.isIdentity || reduceMotion ? 1 : 0.985)
            }
            .onAppear {
                guard !isRisen else { return }
                withAnimation(SUMotion.reveal.animation.delay(0.05 + Double(order) * 0.06)) { isRisen = true }
            }
    }
}

extension View {
    /// Rises in once on first appearance; `order` staggers siblings (0 first).
    func suRise(_ order: Int = 0) -> some View {
        modifier(SURiseModifier(order: order))
    }
}
