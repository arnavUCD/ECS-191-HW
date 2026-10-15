import SwiftUI

/// A halftone of soft square dots swelling toward a focal point, as if seen through a lens: the
/// printed texture on covers. Static, drawn once, and decorative.
struct SUHalftone: View {
    var focus = UnitPoint(x: 0.7, y: 0.36)
    var spacing: CGFloat = 11
    var strength: Double = 1

    var body: some View {
        Canvas { context, size in
            let focusX = size.width * focus.x
            let focusY = size.height * focus.y
            let reach = max(size.width, size.height) * 0.78
            let columns = Int(size.width / spacing) + 2
            let rows = Int(size.height / spacing) + 2
            for row in 0..<rows {
                for column in 0..<columns {
                    let gridX = CGFloat(column) * spacing
                    let gridY = CGFloat(row) * spacing
                    let offsetX = gridX - focusX
                    let offsetY = gridY - focusY
                    let distance = hypot(offsetX, offsetY) / reach
                    guard distance < 1 else { continue }
                    let nearness = 1 - distance
                    // The lens pulls the grid toward the focus, so dots crowd and swell there.
                    let pull = 1 - 0.22 * nearness
                    let centerX = focusX + offsetX * pull
                    let centerY = focusY + offsetY * pull
                    let side = spacing * 0.82 * pow(nearness, 1.25)
                    guard side > 0.7 else { continue }
                    let rect = CGRect(x: centerX - side / 2, y: centerY - side / 2, width: side, height: side * (0.86 + 0.14 * nearness))
                    context.fill(Path(roundedRect: rect, cornerRadius: side * 0.34),
                                 with: .color(.white.opacity((0.05 + 0.16 * nearness) * strength)))
                }
            }
        }
        .drawingGroup()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The processing mark: a ring of halftone dots that swell in a bright band and fade toward the
/// centre and the rim, coloured in dusk tones lifted toward fog white — blush at the top, fog along
/// the left and foot, lilac to the right. Animated, a soft light travels around the ring while the
/// band breathes; still under Reduce Motion (and in UI tests). Decorative.
struct SUHalftoneRing: View {
    var isAnimated = true
    var spacing: CGFloat = 8.5

    /// Dusk stops around the ring (clockwise from the top), lifted toward white so dots glow on black.
    private static let palette: [(red: Double, green: Double, blue: Double)] = [
        lifted(SUDusk.blush, 0.32), lifted(SUDusk.rose, 0.38), lifted(SUDusk.lilac, 0.42),
        lifted(SUDusk.lilac, 0.62), lifted(.white, 0), lifted(SUDusk.blush, 0.62), lifted(SUDusk.blush, 0.32),
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isAnimated)) { timeline in
            let time = isAnimated ? timeline.date.timeIntervalSinceReferenceDate : 0
            Canvas { context, size in
                Self.draw(in: &context, size: size, spacing: spacing, time: time)
            }
        }
        .drawingGroup()
        .aspectRatio(1, contentMode: .fit)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static func draw(in context: inout GraphicsContext, size: CGSize, spacing: CGFloat, time: TimeInterval) {
        let side = min(size.width, size.height)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = side / 2
        // The band breathes slowly; a light travels around it once every ~7 seconds.
        let band = 0.6 + 0.025 * sin(time * 1.1)
        let width = 0.2
        let light = time * 0.9
        let count = Int(side / spacing) + 1
        for row in 0...count {
            for column in 0...count {
                let x = CGFloat(column) * spacing - side / 2 + spacing / 2
                let y = CGFloat(row) * spacing - side / 2 + spacing / 2
                let distance = hypot(x, y) / radius
                guard distance < 1 else { continue }
                let offset = (distance - band) / width
                let angle = atan2(Double(x), Double(-y)) // 0 at the top, clockwise
                let glow = 0.72 + 0.28 * cos(angle - light)
                let intensity = exp(-offset * offset) * glow
                let dot = spacing * 0.92 * intensity
                guard dot > 0.55 else { continue }
                let color = colour(at: angle)
                let rect = CGRect(x: center.x + x - dot / 2, y: center.y + y - dot / 2, width: dot, height: dot)
                context.fill(Path(ellipseIn: rect),
                             with: .color(Color(red: color.red, green: color.green, blue: color.blue).opacity(0.35 + 0.65 * intensity)))
            }
        }
    }

    /// The palette colour at an angle (radians, 0 at the top, clockwise), blended between stops.
    private static func colour(at angle: Double) -> (red: Double, green: Double, blue: Double) {
        let turn = (angle / (2 * .pi)).truncatingRemainder(dividingBy: 1)
        let position = (turn < 0 ? turn + 1 : turn) * Double(palette.count - 1)
        let lower = Int(position)
        let upper = min(lower + 1, palette.count - 1)
        let mix = position - Double(lower)
        let a = palette[lower], b = palette[upper]
        return (a.red + (b.red - a.red) * mix, a.green + (b.green - a.green) * mix, a.blue + (b.blue - a.blue) * mix)
    }

    /// A dusk token in the dark appearance, mixed toward white by `amount`.
    private static func lifted(_ color: Color, _ amount: Double) -> (red: Double, green: Double, blue: Double) {
        var red: CGFloat = 1, green: CGFloat = 1, blue: CGFloat = 1, alpha: CGFloat = 1
        UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return (Double(red) + (1 - Double(red)) * amount, Double(green) + (1 - Double(green)) * amount, Double(blue) + (1 - Double(blue)) * amount)
    }
}

/// Short readouts drawn on a 5 × 7 dot matrix, like a small LED panel: digits, signs, and a few
/// symbols. Only lit dots are drawn. The caller provides the spoken label.
struct SUDotMatrix: View {
    let text: String
    @ScaledMetric(relativeTo: .title2) private var dot: CGFloat = 3.2

    var body: some View {
        let glyphs = text.map { Self.glyph(for: $0) }
        let pitch = dot * 1.55
        let width = glyphs.reduce(0) { $0 + CGFloat($1.width) * pitch } + CGFloat(max(0, glyphs.count - 1)) * pitch
        Canvas { context, _ in
            var originX: CGFloat = 0
            for glyph in glyphs {
                for row in 0..<7 {
                    for column in 0..<glyph.width {
                        let isLit = glyph.isLit(row: row, column: column)
                        let rect = CGRect(x: originX + CGFloat(column) * pitch, y: CGFloat(row) * pitch, width: dot, height: dot)
                        context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(isLit ? 0.97 : 0)))
                    }
                }
                originX += CGFloat(glyph.width + 1) * pitch
            }
        }
        .frame(width: max(width, dot), height: pitch * 6 + dot)
        .accessibilityHidden(true)
    }

    private struct Glyph {
        let rows: [String]
        var width: Int { rows.first?.count ?? 0 }

        func isLit(row: Int, column: Int) -> Bool {
            let line = Array(rows[row])
            return column < line.count && line[column] == "#"
        }
    }

    private static func glyph(for character: Character) -> Glyph {
        Glyph(rows: font[character] ?? font["?"]!)
    }

    private static let font: [Character: [String]] = [
        "0": [" ### ", "#   #", "#  ##", "# # #", "##  #", "#   #", " ### "],
        "1": ["  #  ", " ##  ", "  #  ", "  #  ", "  #  ", "  #  ", " ### "],
        "2": [" ### ", "#   #", "    #", "   # ", "  #  ", " #   ", "#####"],
        "3": [" ### ", "#   #", "    #", "  ## ", "    #", "#   #", " ### "],
        "4": ["   # ", "  ## ", " # # ", "#  # ", "#####", "   # ", "   # "],
        "5": ["#####", "#    ", "#### ", "    #", "    #", "#   #", " ### "],
        "6": ["  ## ", " #   ", "#    ", "#### ", "#   #", "#   #", " ### "],
        "7": ["#####", "    #", "   # ", "  #  ", "  #  ", "  #  ", "  #  "],
        "8": [" ### ", "#   #", "#   #", " ### ", "#   #", "#   #", " ### "],
        "9": [" ### ", "#   #", "#   #", " ####", "    #", "   # ", " ##  "],
        "+": ["     ", "  #  ", "  #  ", "#####", "  #  ", "  #  ", "     "],
        "-": ["     ", "     ", "     ", "#####", "     ", "     ", "     "],
        "\u{2212}": ["     ", "     ", "     ", "#####", "     ", "     ", "     "],
        ".": ["  ", "  ", "  ", "  ", "  ", "##", "##"],
        ",": ["  ", "  ", "  ", "  ", "##", " #", "# "],
        ":": ["  ", "##", "##", "  ", "##", "##", "  "],
        "$": ["  #  ", " ####", "# #  ", " ### ", "  # #", "#### ", "  #  "],
        "%": ["##   ", "##  #", "   # ", "  #  ", " #   ", "#  ##", "   ##"],
        "/": ["    #", "   # ", "   # ", "  #  ", " #   ", " #   ", "#    "],
        "×": ["     ", "#   #", " # # ", "  #  ", " # # ", "#   #", "     "],
        " ": ["   ", "   ", "   ", "   ", "   ", "   ", "   "],
        "?": [" ### ", "#   #", "    #", "   # ", "  #  ", "     ", "  #  "],
    ]
}

/// A fine, deterministic grain for leather-like surfaces. Static and decorative.
struct SUGrain: View {
    var density: Double = 1

    var body: some View {
        Canvas { context, size in
            var seed: UInt64 = 0x5EED_5A5A
            func next() -> CGFloat {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return CGFloat(seed >> 33) / CGFloat(UInt32.max >> 1)
            }
            let count = Int(size.width * size.height / 38 * density)
            for index in 0..<count {
                let rect = CGRect(x: next() * size.width, y: next() * size.height, width: 0.8, height: 0.8)
                let isLight = index.isMultiple(of: 3)
                context.fill(Path(ellipseIn: rect), with: .color(isLight ? .white.opacity(0.045) : .black.opacity(0.09)))
            }
        }
        .drawingGroup()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

#Preview("Textures") {
    VStack(spacing: SUSpacing.lg) {
        ZStack {
            SUMeshBackground(palette: .attention, isAnimated: false)
            SUHalftone()
        }
        .frame(height: 220)
        .clipShape(SUShape.card)
        HStack(spacing: SUSpacing.sm) {
            SUDotMatrix(text: "3")
            SUDotMatrix(text: "+377.00")
            SUDotMatrix(text: "12/25")
        }
        .padding()
        .background(.black, in: SUShape.compact)
        ZStack {
            SUDusk.navy
            SUGrain()
        }
        .frame(height: 120)
        .clipShape(SUShape.card)
    }
    .padding()
    .suScreenBackground()
    .squareUpTheme()
}

#Preview("Processing ring") {
    SUHalftoneRing(isAnimated: false)
        .frame(width: 340)
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .squareUpTheme()
}
