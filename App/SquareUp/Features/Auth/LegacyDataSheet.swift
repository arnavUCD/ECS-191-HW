import SwiftUI

/// Data from an earlier version of Square Up that belongs to no account yet, offered to the
/// signed-in account as a clear choice — counts only, never names or amounts. It is never bound
/// silently to anyone but the account that was using it.
struct LegacyDataSheet: View {
    let offer: AppSession.LegacyOffer
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var failed = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: SUSpacing.lg) {
                    SUAuthHeader(symbol: "tray.full", title: String(localized: "Earlier data on this iPhone"),
                                 subtitle: String(localized: "An earlier version of Square Up kept groups on this iPhone before accounts existed."))
                    Text(summary)
                        .font(SUFont.body)
                        .foregroundStyle(SUColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("legacy.summary")
                    Text(String(localized: """
                    Only use it if it's yours. Once it's added to this account, other people who sign in on this iPhone \
                    won't be offered it. Nothing is deleted either way.
                    """))
                    .font(SUFont.supporting)
                    .foregroundStyle(SUColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    if !offer.canClaim {
                        SUInlineStatus(text: String(localized: "This account already has its own groups, so the earlier data can't be added to it. It stays aside, unchanged."),
                                       identifier: "legacy.cannotClaim")
                    }
                    if failed {
                        SUInlineStatus(text: String(localized: "Couldn't add it right now. Nothing changed — try again."), identifier: "legacy.failure")
                    }
                    if offer.canClaim {
                        Button(String(localized: "Use with this account")) { claim() }
                            .buttonStyle(.suPrimary)
                            .accessibilityIdentifier("legacy.claim")
                    }
                    Button(String(localized: "It's not mine")) {
                        session.declineLegacyData()
                        dismiss()
                    }
                    .buttonStyle(.suSecondary)
                    .accessibilityIdentifier("legacy.decline")
                    Button(String(localized: "Decide later")) {
                        session.postponeLegacyOffer()
                        dismiss()
                    }
                    .buttonStyle(.suText)
                    .accessibilityIdentifier("legacy.later")
                }
                .padding(SUSpacing.screenMargin)
                .frame(maxWidth: SUMetrics.readableWidth)
                .frame(maxWidth: .infinity)
            }
            .background(SUColor.backgroundPrimary)
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled()
        .accessibilityIdentifier("auth.legacyData")
    }

    private var summary: String {
        let groups = Inflect.string("^[\(offer.counts.groups) group](inflect: true)")
        let expenses = Inflect.string("^[\(offer.counts.expenses) expense](inflect: true)")
        return String(localized: "It holds \(groups) and \(expenses).")
    }

    private func claim() {
        failed = false
        do throws(LegacyDataRegistry.ClaimError) {
            try session.claimLegacyData()
            dismiss()
        } catch {
            failed = true
        }
    }
}
