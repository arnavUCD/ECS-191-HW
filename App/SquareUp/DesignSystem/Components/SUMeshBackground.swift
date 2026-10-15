import SwiftUI

/// The restrained aurora behind hero information, in the dusk palette.
///
/// A 3×3 `MeshGradient` whose interior points drift slowly. Animation stops entirely when:
/// Reduce Motion is on, Low Power Mode is on, the scene is not active, the view is scrolled
/// offscreen, or the caller disables it. The static frame is designed to look complete.
struct SUMeshBackground: View {
    struct Palette: Equatable {
        var base: Color
        var deep: Color
        var primaryGlow: Color
        var secondaryGlow: Color
        var warmth: Color

        /// Owed to you: cool — lilac and slate light with a touch of blush at the edge.
        static let positive = Palette(
            base: SUDusk.ink.mix(with: SUDusk.navy, by: 0.6), deep: SUDusk.navy,
            primaryGlow: SUDusk.lilac, secondaryGlow: SUDusk.slate,
            warmth: SUDusk.blush.opacity(0.7)
        )
        /// You owe: warmer — rose and blush gather, never alarming.
        static let attention = Palette(
            base: SUDusk.ink.mix(with: SUDusk.navy, by: 0.6), deep: SUDusk.navy.mix(with: SUDusk.mauve, by: 0.4),
            primaryGlow: SUDusk.blush, secondaryGlow: SUDusk.rose,
            warmth: SUDusk.lilac.opacity(0.6)
        )
        /// All square / neutral: quiet navy and slate.
        static let calm = Palette(
            base: SUDusk.ink.mix(with: SUDusk.navy, by: 0.6), deep: SUDusk.navy,
            primaryGlow: SUDusk.slate.mix(with: SUDusk.lilac, by: 0.3), secondaryGlow: SUDusk.slate,
            warmth: SUDusk.mauve.opacity(0.6)
        )
    }

    var palette: Palette = .positive
    var isAnimated = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = true
    @State private var isLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

    private var shouldAnimate: Bool {
        isAnimated && !reduceMotion && !isLowPower && scenePhase == .active && isVisible
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !shouldAnimate)) { context in
            let time = shouldAnimate ? context.date.timeIntervalSinceReferenceDate : 0
            mesh(at: time)
        }
        .background(palette.base)
        .onScrollVisibilityChange(threshold: 0.05) { visible in
            isVisible = visible
        }
        .task {
            for await _ in NotificationCenter.default.notifications(named: Notification.Name.NSProcessInfoPowerStateDidChange) {
                isLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            }
        }
        .accessibilityHidden(true)
    }

    private func mesh(at time: TimeInterval) -> some View {
        // Slow drift: ~20 s period, small amplitude so the hero never "swims".
        let slow = time / 20 * .pi * 2
        let dx = Float(sin(slow)) * 0.06
        let dy = Float(cos(slow * 0.8)) * 0.05
        let edge = Float(sin(slow * 0.6)) * 0.04
        return MeshGradient(
            width: 3,
            height: 3,
            points: [
                [0, 0], [0.5 + edge, 0], [1, 0],
                [0, 0.5 - edge], [0.62 + dx, 0.45 + dy], [1, 0.4 + edge],
                [0, 1], [0.45 - edge, 1], [1, 1],
            ],
            // The top-leading corner stays deep so header text keeps contrast; light gathers low
            // and to the trailing side, behind the glass controls rather than behind figures.
            colors: [
                palette.base, palette.base.mix(with: palette.deep, by: 0.5), palette.deep.mix(with: palette.warmth, by: 0.35),
                palette.base, palette.deep.mix(with: palette.secondaryGlow, by: 0.4), palette.secondaryGlow,
                palette.base.mix(with: palette.warmth, by: 0.35), palette.primaryGlow.mix(with: palette.deep, by: 0.4), palette.primaryGlow,
            ],
            background: palette.base,
            smoothsColors: true
        )
    }
}

#Preview("Mesh palettes", traits: .sizeThatFitsLayout) {
    VStack(spacing: SUSpacing.md) {
        SUMeshBackground(palette: .positive).frame(height: 180).clipShape(SUShape.card)
        SUMeshBackground(palette: .attention).frame(height: 180).clipShape(SUShape.card)
        SUMeshBackground(palette: .calm).frame(height: 180).clipShape(SUShape.card)
    }
    .padding()
    .environment(\.colorScheme, .dark)
}
