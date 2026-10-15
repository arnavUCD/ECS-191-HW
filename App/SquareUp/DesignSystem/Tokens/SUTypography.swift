import SwiftUI

/// Typography built on Dynamic Type text styles. No fixed point sizes for ordinary content.
///
/// Hierarchy rule: amount first, meaning second, metadata third.
enum SUFont {
    /// Hero figure. Scales with Dynamic Type from `.largeTitle`.
    static let heroAmount = Font.system(.largeTitle, weight: .medium).monospacedDigit()
    /// Large amounts inside cards and panels.
    static let largeAmount = Font.system(.title, weight: .semibold).monospacedDigit()
    /// Row amounts — tabular digits so columns align.
    static let rowAmount = Font.body.weight(.semibold).monospacedDigit()
    static let smallAmount = Font.subheadline.weight(.semibold).monospacedDigit()

    static let screenTitle = Font.system(.largeTitle, design: .rounded, weight: .bold)
    static let sectionTitle = Font.title3.weight(.semibold)
    static let cardTitle = Font.headline
    static let body = Font.body
    static let supporting = Font.subheadline
    static let metadata = Font.footnote
    static let chip = Font.footnote.weight(.semibold)
    static let button = Font.body.weight(.semibold)
}

extension View {
    /// Applies a font and the matching semantic colour for a hierarchy level.
    func suText(_ level: SUTextLevel) -> some View {
        modifier(SUTextModifier(level: level))
    }
}

enum SUTextLevel {
    case title
    case primary
    case secondary
    case tertiary
}

private struct SUTextModifier: ViewModifier {
    let level: SUTextLevel

    func body(content: Content) -> some View {
        switch level {
        case .title:
            content.font(SUFont.cardTitle).foregroundStyle(SUColor.textPrimary)
        case .primary:
            content.font(SUFont.body).foregroundStyle(SUColor.textPrimary)
        case .secondary:
            content.font(SUFont.supporting).foregroundStyle(SUColor.textSecondary)
        case .tertiary:
            content.font(SUFont.metadata).foregroundStyle(SUColor.textTertiary)
        }
    }
}
