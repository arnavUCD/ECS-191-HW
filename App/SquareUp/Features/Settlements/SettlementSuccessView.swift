import SwiftUI

/// What to celebrate — only ever built after a recipient confirms.
struct PaymentSuccess: Identifiable {
    let attempt: PaymentAttempt
    let payerName: String
    let recipientName: String
    let groupName: String
    let isGroupSettled: Bool
    var id: PaymentAttemptID { attempt.id }
}

/// The app's strongest success moment (milestone 2 §13 "Success treatment"): shown only after
/// recipient confirmation, paired with the `settle` signature haptic. Reduce Motion gets a
/// short fade with the same information.
struct SettlementSuccessView: View {
    let success: PaymentSuccess
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppEnvironment.self) private var environment
    @State private var appeared = false

    var body: some View {
        ZStack {
            SUMeshBackground(palette: .positive, isAnimated: environment.allowsAmbientAnimation)
                .ignoresSafeArea()
            VStack(spacing: SUSpacing.lg) {
                Spacer()
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 88, weight: .semibold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.black, Color.white)
                    .symbolEffect(.drawOn, isActive: !appeared && !reduceMotion)
                    .scaleEffect(appeared || reduceMotion ? 1 : 0.85)
                    .accessibilityHidden(true)
                VStack(spacing: SUSpacing.xs) {
                    Text(String(localized: "Confirmed"))
                        .font(SUFont.screenTitle)
                        .foregroundStyle(SUColor.textPrimary)
                    SUAmountView(money: success.attempt.amount, style: .hero)
                    Text(String(localized: "\(success.recipientName) confirmed receiving it from \(success.payerName) via \(success.attempt.provider.displayName)."))
                        .font(SUFont.body)
                        .foregroundStyle(SUColor.textSecondary)
                        .multilineTextAlignment(.center)
                    if success.isGroupSettled {
                        Label(String(localized: "Everyone in \(success.groupName) is square"), systemImage: "person.3.fill")
                            .font(SUFont.cardTitle)
                            .foregroundStyle(SUColor.positive)
                            .padding(.top, SUSpacing.xs)
                    }
                }
                .opacity(appeared ? 1 : 0)
                Spacer()
                Button(String(localized: "Done")) { dismiss() }
                    .buttonStyle(.suPrimary)
                    .accessibilityIdentifier("success.done")
            }
            .padding(SUSpacing.xl)
            .frame(maxWidth: 520)
        }
        .environment(\.colorScheme, .dark)
        .onAppear {
            withSUAnimation(.confirm, reduceMotion: reduceMotion) { appeared = true }
        }
        .sensoryFeedback(.success, trigger: appeared)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("success.screen")
    }
}
