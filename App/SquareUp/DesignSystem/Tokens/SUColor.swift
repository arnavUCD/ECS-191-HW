import SwiftUI

/// Semantic colour tokens. The only sanctioned way to reach brand colours.
///
/// Values live in the asset catalog with light, dark, and increased-contrast variants
/// (`Resources/Assets.xcassets`). Every text-bearing token meets WCAG AA (4.5:1) against
/// `backgroundPrimary`, `surfacePrimary`, and `surfaceElevated` in all four appearances;
/// `ContrastTests` enforces this.
///
/// Prefer system semantic styles (`.primary`, `.secondary`, `.separator`) inside standard
/// controls; use these tokens for Square Up surfaces and meaning.
enum SUColor {
    static let backgroundPrimary = Color(.backgroundPrimary)
    static let backgroundSecondary = Color(.backgroundSecondary)
    static let surfacePrimary = Color(.surfacePrimary)
    static let surfaceElevated = Color(.surfaceElevated)
    static let surfacePressed = Color(.surfacePressed)

    static let textPrimary = Color(.textPrimary)
    static let textSecondary = Color(.textSecondary)
    static let textTertiary = Color(.textTertiary)

    /// Interactive tint and primary-action fill.
    static let accent = Color(.accentPrimary)
    /// Foreground on `accent` fills.
    static let onAccent = Color(.onAccent)
    /// Decorative lime for glows and mesh points only. Never use for text.
    static let accentGlow = Color(.accentGlow)
    /// Secondary accent for AI suggestions and insight. Never money direction.
    static let violet = Color(.accentViolet)

    static let positive = Color(.positive)
    static let warning = Color(.warning)
    static let negative = Color(.negative)
    static let informational = Color(.informational)

    // Translucent layers over the dusk backdrop. Fills, never text: contrast is checked against
    // the opaque surface tokens above, which these sit on or stand in for.
    /// A card or row: lets the backdrop through faintly.
    static let glassFill = Color.white.opacity(0.07)
    /// A field, key, or tile inside a card.
    static let glassFillElevated = Color.white.opacity(0.11)
    /// Pressed or selected fill.
    static let glassFillPressed = Color.white.opacity(0.16)
    /// The one-point edge that separates a translucent layer from the backdrop.
    static let hairline = Color.white.opacity(0.1)
}

/// The Square Up "dusk" palette: light burgundy falling through navy into black. It is the
/// app-wide backdrop direction and is always dark — text placed on it uses dark-appearance tokens.
/// Gradient stops only; never use these for text or money meaning.
enum SUDusk {
    static let rose = Color(.duskRose)
    static let blush = Color(.duskBlush)
    static let lilac = Color(.duskLilac)
    static let mauve = Color(.duskMauve)
    static let slate = Color(.duskSlate)
    static let navy = Color(.duskNavy)
    static let ink = Color(.duskInk)
}
