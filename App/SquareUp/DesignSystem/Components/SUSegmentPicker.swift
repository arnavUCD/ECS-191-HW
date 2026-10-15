import SwiftUI

/// A segmented choice on a Liquid Glass track: the selected segment is bright glass that morphs
/// between positions. VoiceOver and Voice Control get a standard picker through
/// `accessibilityRepresentation`, so the identifiers and labels stay conventional.
struct SUSegmentPicker<Option: Hashable & Identifiable & Sendable>: View {
    struct Segment {
        var title: String
        var systemImage: String?
    }

    let title: String
    @Binding var selection: Option
    let options: [Option]
    let segment: (Option) -> Segment
    /// Equal-width segments that fill the row (tabs within a screen) or hugging capsules in a
    /// scrolling row (filters).
    var fills = true

    @Namespace private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GlassEffectContainer(spacing: SUSpacing.xxs) {
            if fills {
                HStack(spacing: SUSpacing.xxs) { segments }
                    .padding(SUSpacing.xxs)
                    .glassEffect(.regular, in: Capsule())
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: SUSpacing.xs) { segments }
                }
            }
        }
        .sensoryFeedback(.selection, trigger: selection)
        .accessibilityRepresentation {
            Picker(title, selection: $selection) {
                ForEach(options) { Text(segment($0).title).tag($0) }
            }
        }
    }

    private var segments: some View {
        ForEach(options) { option in
            let isSelected = option == selection
            let details = segment(option)
            Button {
                withSUAnimation(.reconcile, reduceMotion: reduceMotion) { selection = option }
            } label: {
                Group {
                    if let symbol = details.systemImage {
                        Label(details.title, systemImage: symbol)
                    } else {
                        Text(details.title)
                    }
                }
                .font(SUFont.chip)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.horizontal, SUSpacing.sm)
                .frame(maxWidth: fills ? .infinity : nil, minHeight: SUMetrics.minimumTouchTarget - 6)
                .foregroundStyle(isSelected ? Color.black : SUColor.textPrimary)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .glassEffect(isSelected ? .regular.tint(.white).interactive() : (fills ? .identity : .regular.interactive()), in: Capsule())
            .glassEffectID(option, in: namespace)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }
}

#Preview("Segment pickers") {
    @Previewable @State var tab = "expenses"
    @Previewable @State var filter = "all"
    VStack(spacing: SUSpacing.lg) {
        SUSegmentPicker(title: "Section", selection: $tab, options: ["expenses", "balances", "activity"]) { option in
            .init(title: option.capitalized)
        }
        SUSegmentPicker(title: "Filter", selection: $filter, options: ["all", "expenses", "payments"], segment: { option in
            .init(title: option.capitalized, systemImage: option == "all" ? "square.stack" : (option == "expenses" ? "receipt" : "arrow.left.arrow.right"))
        }, fills: false)
    }
    .padding()
    .suScreenBackground()
    .squareUpTheme()
}

extension String: @retroactive Identifiable {
    public var id: String { self }
}
