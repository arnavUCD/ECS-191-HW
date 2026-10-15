#if DEBUG
import SwiftUI

/// In-app catalogue of design-system components and signature haptics for device QA
/// (haptics cannot be evaluated in Xcode Previews or the simulator).
struct DesignSystemGallery: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var method: SplitMethod = .equal

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SUSpacing.xl) {
                group("Colour tokens") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: SUSpacing.sm)], spacing: SUSpacing.sm) {
                        swatch("Accent", SUColor.accent)
                        swatch("Violet", SUColor.violet)
                        swatch("Positive", SUColor.positive)
                        swatch("Warning", SUColor.warning)
                        swatch("Negative", SUColor.negative)
                        swatch("Info", SUColor.informational)
                        swatch("Surface", SUColor.surfacePrimary)
                        swatch("Elevated", SUColor.surfaceElevated)
                    }
                }
                group("Hero") {
                    SUBalanceCard(position: NetPosition(owedToYou: Money(552.30), youOwe: Money(29.69)), groupCount: 4)
                }
                group("Amounts") {
                    VStack(alignment: .leading) {
                        SUAmountView(money: Money(86.40), direction: .incoming, style: .large)
                        SUAmountView(money: Money(29.69), direction: .outgoing)
                    }
                }
                group("Split method") { SUSplitMethodPicker(selection: $method) }
                group("Status") {
                    FlowRow { SUStatusChip.offline; SUStatusChip.savedOnDevice; SUStatusChip.settled }
                }
                group("Signature haptics") {
                    VStack(alignment: .leading, spacing: SUSpacing.xs) {
                        if !environment.haptics.isAvailable {
                            Text("This device has no haptic engine (e.g. Simulator).").suText(.secondary)
                        }
                        ForEach(SignatureHaptic.allCases, id: \.self) { haptic in
                            Button(haptic.rawValue) { environment.haptics.play(haptic) }
                                .buttonStyle(.suSecondary)
                        }
                    }
                }
            }
            .padding(SUSpacing.screenMargin)
        }
        .suScreenBackground()
        .navigationTitle("Design system")
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: SUSpacing.sm) {
            SUSectionHeader(title: title)
            content()
        }
    }

    private func swatch(_ name: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: SUSpacing.xxs) {
            SUShape.compact.fill(color).frame(height: 48)
                .overlay(SUShape.compact.strokeBorder(SUColor.textTertiary.opacity(0.3)))
            Text(name).suText(.tertiary)
        }
    }
}

/// Simple wrapping row for chips.
private struct FlowRow: Layout {
    var spacing: CGFloat = SUSpacing.xs

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, point) in result.points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, width: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            width = max(width, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: width, height: y + rowHeight), points)
    }
}

#Preview {
    NavigationStack { DesignSystemGallery() }
        .environment(AppEnvironment.preview())
}
#endif
