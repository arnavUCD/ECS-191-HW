import SwiftUI

/// Spacing on a 4-point grid.
nonisolated enum SUSpacing {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let sm: CGFloat = 12
    static let md: CGFloat = 16
    static let lg: CGFloat = 20
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32

    /// Standard horizontal margin for screen content.
    static let screenMargin: CGFloat = 20
}

nonisolated enum SURadius {
    /// Large panels and covers' outer frames. Inner layers use concentric radii (outer − inset).
    static let panel: CGFloat = 36
    static let card: CGFloat = 24
    /// Action tiles.
    static let tile: CGFloat = 26
    static let compact: CGFloat = 16
    static let control: CGFloat = 14
}

nonisolated enum SUMetrics {
    static let minimumTouchTarget: CGFloat = 44
    /// Readable column width; wider scenes use additional columns instead of stretching.
    static let readableWidth: CGFloat = 640
    /// Above this content width Home switches to two columns.
    static let twoColumnThreshold: CGFloat = 860
}

enum SUShape {
    static let card = RoundedRectangle(cornerRadius: SURadius.card, style: .continuous)
    static let compact = RoundedRectangle(cornerRadius: SURadius.compact, style: .continuous)
    static let control = RoundedRectangle(cornerRadius: SURadius.control, style: .continuous)
}
