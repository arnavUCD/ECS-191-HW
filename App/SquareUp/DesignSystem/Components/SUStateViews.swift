import SwiftUI

/// An empty-but-valid state: what this place is for and the one action that fills it.
struct SUEmptyState: View {
    let systemImage: String
    let title: String
    let message: String
    var primaryTitle: String?
    var primaryAction: (() -> Void)?
    var secondaryTitle: String?
    var secondaryAction: (() -> Void)?

    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: SUSpacing.md) {
            Image(systemName: systemImage)
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(SUColor.textPrimary)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 84, height: 84)
                .glassEffect(.regular, in: Circle())
                .symbolEffect(.drawOn, isActive: !appeared && !reduceMotion)
                .accessibilityHidden(true)
            VStack(spacing: SUSpacing.xs) {
                Text(title)
                    .font(SUFont.sectionTitle)
                    .foregroundStyle(SUColor.textPrimary)
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(SUFont.supporting)
                    .foregroundStyle(SUColor.textSecondary)
                    .multilineTextAlignment(.center)
            }
            if let primaryTitle, let primaryAction {
                Button(primaryTitle, action: primaryAction)
                    .buttonStyle(.suPrimary)
                    .padding(.top, SUSpacing.xs)
            }
            if let secondaryTitle, let secondaryAction {
                Button(secondaryTitle, action: secondaryAction)
                    .buttonStyle(.suSecondary)
            }
        }
        .padding(SUSpacing.xl)
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity)
        .onAppear { appeared = true }
    }
}

/// A recoverable failure with a retry. Copy states what failed and what still works.
struct SUErrorState: View {
    let title: String
    let message: String
    var retryTitle = String(localized: "Try again")
    let retry: () -> Void

    var body: some View {
        VStack(spacing: SUSpacing.md) {
            Image(systemName: "exclamationmark.arrow.trianglehead.counterclockwise")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(SUColor.warning)
                .frame(width: 84, height: 84)
                .glassEffect(.regular, in: Circle())
                .accessibilityHidden(true)
            VStack(spacing: SUSpacing.xs) {
                Text(title)
                    .font(SUFont.sectionTitle)
                    .foregroundStyle(SUColor.textPrimary)
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(SUFont.supporting)
                    .foregroundStyle(SUColor.textSecondary)
                    .multilineTextAlignment(.center)
            }
            Button(retryTitle, systemImage: "arrow.clockwise", action: retry)
                .buttonStyle(.suPrimary(fullWidth: false))
        }
        .padding(SUSpacing.xl)
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }
}

/// Skeleton treatment: real layout, native redaction, and a restrained shimmer that is
/// disabled under Reduce Motion.
struct SUShimmer: ViewModifier {
    var isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .redacted(reason: isActive ? .placeholder : [])
            .overlay {
                if isActive && !reduceMotion {
                    GeometryReader { proxy in
                        LinearGradient(
                            colors: [.clear, SUColor.textPrimary.opacity(0.08), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: proxy.size.width * 0.6)
                        .offset(x: phase * proxy.size.width)
                    }
                    .allowsHitTesting(false)
                    .mask(content.redacted(reason: .placeholder))
                    .onAppear {
                        withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { phase = 1.4 }
                    }
                }
            }
            .accessibilityLabel(isActive ? Text("Loading") : Text(""))
    }
}

extension View {
    func suSkeleton(_ isActive: Bool) -> some View {
        modifier(SUShimmer(isActive: isActive))
    }
}

/// A generic loading placeholder made of card-shaped skeletons.
struct SULoadingState: View {
    var cardCount = 3

    var body: some View {
        VStack(spacing: SUSpacing.md) {
            SUShape.card.fill(SUColor.glassFillElevated).frame(height: 220)
            ForEach(0..<cardCount, id: \.self) { _ in
                SUCard {
                    HStack(spacing: SUSpacing.sm) {
                        Circle().fill(SUColor.glassFillPressed).frame(width: 40, height: 40)
                        VStack(alignment: .leading, spacing: SUSpacing.xs) {
                            Text("Placeholder group name")
                            Text("Placeholder detail text")
                        }
                        Spacer()
                        Text("$000.00")
                    }
                }
            }
        }
        .suSkeleton(true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Loading"))
    }
}

#Preview("Empty") {
    SUEmptyState(
        systemImage: "person.3.sequence.fill",
        title: "No groups yet",
        message: "Create a group for your apartment, a trip, or a night out, then add what people paid.",
        primaryTitle: "Explore sample data", primaryAction: {},
        secondaryTitle: "Create a group", secondaryAction: {}
    )
    .suScreenBackground()
    .squareUpTheme()
}

#Preview("Error") {
    SUErrorState(title: "Couldn't load your balances", message: "Your data is still on this iPhone. Try again.") {}
        .suScreenBackground()
        .squareUpTheme()
}

#Preview("Loading") {
    SULoadingState().padding().suScreenBackground().squareUpTheme()
}
