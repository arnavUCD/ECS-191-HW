import SwiftUI

/// The AI-processing disclosure (milestone 5 §7.1), shown once before the first receipt that
/// could be sent. Two equal choices, neither preselected or styled as destructive. Dismissing
/// without choosing keeps this receipt on the device and asks again next time.
struct ReceiptAIConsentSheet: View {
    let choose: (ReceiptAIMode) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SUSpacing.lg) {
                Image(systemName: "doc.text.viewfinder")
                    .font(.system(.largeTitle))
                    .foregroundStyle(SUColor.accent)
                    .accessibilityHidden(true)
                Text(String(localized: "Process receipts with AI?"))
                    .font(SUFont.sectionTitle)
                    .foregroundStyle(SUColor.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                VStack(alignment: .leading, spacing: SUSpacing.md) {
                    point("arrow.up.doc", String(localized: """
                    The receipt image and the text read on this iPhone are sent to Square Up's server and to \
                    Anthropic's Claude to identify items and totals.
                    """))
                    point("lock.shield", String(localized: """
                    Receipts can include sensitive details, such as where you shopped, what you bought, and part \
                    of a card number.
                    """))
                    point("checkmark.circle", String(localized: "You'll review and can correct everything before anything is saved."))
                    point("iphone", String(localized: "You can keep processing on this iPhone instead, and change this anytime in Profile."))
                }
                VStack(spacing: SUSpacing.sm) {
                    Button(String(localized: "Use AI processing")) { choose(.automatic) }
                        .buttonStyle(.suSecondary)
                        .accessibilityIdentifier("receipt.ai.accept")
                    Button(String(localized: "Keep on this iPhone")) { choose(.onDeviceOnly) }
                        .buttonStyle(.suSecondary)
                        .accessibilityIdentifier("receipt.ai.decline")
                }
                .padding(.top, SUSpacing.sm)
            }
            .padding(.horizontal, SUSpacing.screenMargin)
            .padding(.vertical, SUSpacing.xl)
            .frame(maxWidth: SUMetrics.readableWidth)
            .frame(maxWidth: .infinity)
        }
        .suScreenBackground()
        .presentationDetents([.large])
        .accessibilityIdentifier("receipt.ai.consent")
    }

    private func point(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: SUSpacing.sm) {
            Image(systemName: symbol)
                .foregroundStyle(SUColor.textSecondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            Text(text)
                .font(SUFont.body)
                .foregroundStyle(SUColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    ReceiptAIConsentSheet { _ in }
        .environment(AppEnvironment.preview())
}
