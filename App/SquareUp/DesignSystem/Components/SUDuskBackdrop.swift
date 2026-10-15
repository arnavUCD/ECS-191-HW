import SwiftUI

/// Square Up's full-bleed backdrop: light burgundy at the top falling through navy into black.
///
/// - `hero`: the full gradient with the signal field (a ring of short strokes drifting around a
///   focal point). For brand moments only — Welcome and launch.
/// - `calm`: a lower, quieter glow that leaves the rest of the screen near-black. For forms and
///   anything with text entry, and never animated there.
///
/// Motion is slow and stops when Reduce Motion or Low Power Mode is on, the app isn't active, or
/// the caller (UI tests, snapshots) turns it off. Always dark; decorative and hidden from VoiceOver.
struct SUDuskBackdrop: View {
    nonisolated enum Style { case hero, calm }

    var style: Style = .hero
    var isAnimated = true
    /// Where the signal field radiates from, in global coordinates (the logo's centre). Without
    /// one it gathers in the upper third.
    var focus: CGPoint?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.scenePhase) private var scenePhase
    @State private var isLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

    private var shouldAnimate: Bool {
        style == .hero && isAnimated && !reduceMotion && !isLowPower && scenePhase == .active
    }

    var body: some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .global)
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !shouldAnimate)) { context in
                let time = shouldAnimate ? context.date.timeIntervalSinceReferenceDate : 0
                ZStack {
                    mesh(at: time)
                    if style == .hero {
                        SUSignalField(time: time, strength: contrast == .increased ? 0.6 : 1,
                                      focus: focus.map { CGPoint(x: $0.x - frame.minX, y: $0.y - frame.minY) })
                    }
                }
            }
        }
        .background(SUDusk.ink)
        .task {
            for await _ in NotificationCenter.default.notifications(named: Notification.Name.NSProcessInfoPowerStateDidChange) {
                isLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            }
        }
        .accessibilityHidden(true)
    }

    private func mesh(at time: TimeInterval) -> some View {
        let slow = time / 28 * .pi * 2
        let dx = Float(sin(slow)) * 0.08
        let dy = Float(cos(slow * 0.8)) * 0.03
        // Calm screens compress the glow into the top and dim it, so fields sit on near-black.
        let calm = style == .calm
        let dim = calm ? 0.45 : (contrast == .increased ? 0.25 : 0)
        let rose = SUDusk.rose.mix(with: SUDusk.navy, by: dim)
        let blush = SUDusk.blush.mix(with: SUDusk.navy, by: calm ? 0.6 : dim)
        let lilac = SUDusk.lilac.mix(with: SUDusk.navy, by: calm ? 0.55 : dim)
        let mauve = SUDusk.mauve.mix(with: SUDusk.navy, by: dim)
        let rows: [Float] = calm ? [0, 0.12, 0.24, 0.38, 0.6] : [0, 0.17, 0.33, 0.5, 0.72]
        return MeshGradient(
            width: 3,
            height: 5,
            points: [
                [0, rows[0]], [0.55 + dx, rows[0]], [1, rows[0]],
                [0, rows[1]], [0.45 + dx, rows[1] + dy], [1, rows[1]],
                [0, rows[2]], [0.5 - dx, rows[2] - dy], [1, rows[2]],
                [0, rows[3]], [0.5, rows[3]], [1, rows[3]],
                [0, 1], [0.5, 1], [1, 1],
            ],
            colors: [
                rose, blush, lilac,
                mauve, lilac.mix(with: mauve, by: 0.5), lilac.mix(with: SUDusk.slate, by: 0.5),
                SUDusk.slate, SUDusk.slate.mix(with: SUDusk.navy, by: 0.3), SUDusk.slate.mix(with: SUDusk.navy, by: 0.15),
                SUDusk.navy, SUDusk.navy.mix(with: SUDusk.ink, by: 0.25), SUDusk.navy,
                SUDusk.ink, SUDusk.ink, SUDusk.ink,
            ],
            background: SUDusk.ink,
            smoothsColors: true
        )
    }
}

/// A field of short strokes that point away from a focal point, brightest in a ring around it,
/// with a slow ripple travelling outward. Drawn in one Canvas pass.
struct SUSignalField: View {
    var time: TimeInterval
    var strength: Double = 1
    /// The focal point in the field's own coordinates. A focal point holds a logo, so the strokes
    /// keep clear of it.
    var focus: CGPoint?

    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 19
            let center = focus ?? CGPoint(x: size.width * 0.5, y: size.height * 0.27)
            let clearance = focus == nil ? 0.08 : 0.3
            let radius = max(1, min(size.width * 0.78, size.height * 0.36))
            let columns = Int(size.width / spacing) + 1
            let rows = Int(min(size.height, center.y + radius) / spacing) + 1
            let originX = (size.width - CGFloat(columns - 1) * spacing) / 2
            for row in 0..<rows {
                for column in 0..<columns {
                    let point = CGPoint(x: originX + CGFloat(column) * spacing, y: spacing + CGFloat(row) * spacing)
                    let offsetX = point.x - center.x
                    let offsetY = point.y - center.y
                    let distance = hypot(offsetX, offsetY) / radius
                    guard distance > clearance, distance < 1 else { continue }
                    let fadeOut = focus == nil ? 0.6 : 0.5
                    let ring = Self.smoothstep(clearance, clearance + 0.3, distance) * (1 - Self.smoothstep(fadeOut, 0.9, distance))
                    let ripple = sin(time * 0.4 - distance * 8)
                    let alpha = ring * (0.42 + 0.22 * ripple) * strength
                    guard alpha > 0.02 else { continue }
                    let angle = atan2(offsetY, offsetX) + 0.32 * sin(time * 0.15 + distance * 3)
                    let length = 3 + 7 * ring * (0.8 + 0.2 * ripple)
                    let direction = CGVector(dx: cos(angle) * length / 2, dy: sin(angle) * length / 2)
                    var stroke = Path()
                    stroke.move(to: CGPoint(x: point.x - direction.dx, y: point.y - direction.dy))
                    stroke.addLine(to: CGPoint(x: point.x + direction.dx, y: point.y + direction.dy))
                    context.stroke(stroke, with: .color(.white.opacity(alpha)), style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
                }
            }
        }
        .allowsHitTesting(false)
    }

    private static func smoothstep(_ edge0: Double, _ edge1: Double, _ value: Double) -> Double {
        let t = min(max((value - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}

#Preview("Dusk · hero") {
    SUDuskBackdrop(style: .hero).ignoresSafeArea()
}

#Preview("Dusk · calm") {
    SUDuskBackdrop(style: .calm).ignoresSafeArea()
}
