import SwiftUI

/// Semantic meaning that maps to colour. A tone is never the only signal: components that
/// take a tone also require a label and/or symbol (Differentiate Without Color).
enum SUTone: Hashable, Sendable {
    case neutral
    case accent
    case positive
    case warning
    case negative
    case informational
    /// Violet: AI suggestions and other insight (never money direction).
    case insight

    var color: Color {
        switch self {
        case .neutral: SUColor.textSecondary
        case .accent: SUColor.accent
        case .positive: SUColor.positive
        case .warning: SUColor.warning
        case .negative: SUColor.negative
        case .informational: SUColor.informational
        case .insight: SUColor.violet
        }
    }
}
