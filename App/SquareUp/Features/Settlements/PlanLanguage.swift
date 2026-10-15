import Foundation

/// Plain-language settlement copy (milestone 2 §9 "Plain-language plan").
nonisolated enum PlanLanguage {
    /// "Alex pays Maya $27.83." / "You pay Maya $27.83." / "Alex pays you $27.83."
    static func sentence(
        for payment: PlannedPayment,
        members: [MemberID: Member],
        currentUserID: MemberID,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        let labels = PersonIdentity.shortLabels(for: Array(members.values))
        let amount = MoneyFormatting.string(payment.amount, locale: locale)
        let payer = labels[payment.payerID] ?? ""
        let recipient = labels[payment.recipientID] ?? ""
        if payment.payerID == currentUserID {
            return String(localized: "You pay \(recipient) \(amount).")
        }
        if payment.recipientID == currentUserID {
            return String(localized: "\(payer) pays you \(amount).")
        }
        return String(localized: "\(payer) pays \(recipient) \(amount).")
    }

    /// "2 payments instead of 5." and its variants.
    static func countSummary(_ plan: SettlementPlan) -> String {
        if plan.payments.isEmpty {
            return plan.pending.isEmpty
                ? String(localized: "Everyone is square.")
                : Inflect.string("Waiting on ^[\(plan.pending.count) payment](inflect: true) to be confirmed.")
        }
        if plan.isSimplified {
            if plan.simplifiedPaymentCount < plan.directPaymentCount {
                return Inflect.string("^[\(plan.simplifiedPaymentCount) payment](inflect: true) instead of \(plan.directPaymentCount).")
            }
            return Inflect.string("^[\(plan.simplifiedPaymentCount) payment](inflect: true) — already as simple as it gets.")
        }
        if plan.simplifiedPaymentCount < plan.directPaymentCount {
            return Inflect.string("^[\(plan.directPaymentCount) payment](inflect: true). Simplifying would need \(plan.simplifiedPaymentCount).")
        }
        return Inflect.string("^[\(plan.directPaymentCount) payment](inflect: true).")
    }

    /// "Accepts Apple Cash, PayPal, and Zelle" — text only, never logos alone.
    static func acceptedMethods(_ destinations: [PaymentDestination]) -> String {
        let names = destinations.filter(\.isEnabled).map(\.provider.displayName)
        var unique: [String] = []
        for name in names where !unique.contains(name) { unique.append(name) }
        guard !unique.isEmpty else { return String(localized: "Hasn't added payment methods yet") }
        return String(localized: "Accepts \(unique.formatted(.list(type: .and)))")
    }
}
