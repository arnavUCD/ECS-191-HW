import SwiftUI

/// Root styling applied once at the scene level.
///
/// Square Up is dark by design: every screen sits on the dusk backdrop (light burgundy falling
/// through navy into black), so the appearance is fixed to dark whatever the system setting and
/// the colour tokens always resolve to their dark variants. Scroll indicators are hidden app-wide
/// (they flashed along the side on every scroll); scrolling itself is unchanged.
struct SquareUpTheme: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollIndicators(.hidden)
            .tint(SUColor.accent)
            .background(SUColor.backgroundPrimary)
            .environment(\.colorScheme, .dark)
            .preferredColorScheme(.dark)
    }
}

extension View {
    func squareUpTheme() -> some View {
        modifier(SquareUpTheme())
    }

    /// The edge-to-edge dusk canvas behind a screen's scrolling content. The glow gathers at the
    /// top, behind the navigation bar, and the rest of the screen rests on near-black so cards,
    /// figures, and text keep their contrast. Never animated here.
    func suScreenBackground() -> some View {
        background { SUDuskBackdrop(style: .calm, isAnimated: false).ignoresSafeArea() }
            // Also here, because sheets and full-screen covers don't inherit the scene's setting.
            .scrollIndicators(.hidden)
    }
}

/// The panel material: a faint top-lit sheen and a bevelled hairline that is brighter along the
/// top edge, so stacked panels read as physical layers over the backdrop. Increased Contrast
/// swaps the bevel for a solid edge.
struct SUBevel<S: InsettableShape>: View {
    let shape: S
    var elevated = false
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        shape
            .fill(LinearGradient(colors: [.white.opacity(elevated ? 0.13 : 0.09), .white.opacity(elevated ? 0.08 : 0.045)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay {
                if contrast == .increased {
                    shape.strokeBorder(SUColor.textTertiary.opacity(0.6), lineWidth: 1)
                } else {
                    shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.07), .white.opacity(0.035)],
                                                      startPoint: .top, endPoint: .bottom), lineWidth: 1)
                }
            }
    }
}

/// The look of `SUCard` for rows, tiles, and fields that need their own shape.
private struct SUSurfaceModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    let elevated: Bool

    func body(content: Content) -> some View {
        content.background { SUBevel(shape: shape, elevated: elevated) }
    }
}

extension View {
    func suSurface(_ shape: some InsettableShape = SUShape.compact, elevated: Bool = false) -> some View {
        modifier(SUSurfaceModifier(shape: shape, elevated: elevated))
    }

    /// Rows of a `List` or `Form` as translucent surfaces over the backdrop. Apply to each `Section`.
    func suListRows() -> some View {
        listRowBackground(SUColor.glassFill)
    }
}
