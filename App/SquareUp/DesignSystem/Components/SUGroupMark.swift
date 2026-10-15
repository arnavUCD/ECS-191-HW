import SwiftUI

/// A group's visual mark: its symbol on an accent-tinted tile.
struct SUGroupMark: View {
    let group: ExpenseGroup
    var size: CGFloat = 44

    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    var body: some View {
        let side = size * min(scale, 1.5)
        let tint = SUColor.accent
        Image(systemName: group.symbolName)
            .font(.system(size: side * 0.44, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: side, height: side)
            .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: side * 0.3, style: .continuous))
            .accessibilityHidden(true)
    }
}
