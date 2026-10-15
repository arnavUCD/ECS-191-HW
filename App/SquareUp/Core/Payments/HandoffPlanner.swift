import Foundation

/// The honest capability of a handoff (milestone 2 §11). Never "Verified", "Instant", or "Secure".
nonisolated enum HandoffCapability: String, Equatable, Sendable {
    /// Recipient and amount are both included in an official link.
    case amountPrepared
    /// An official destination opens; the payer may need to enter the rest.
    case opensProvider
    /// Square Up copies the details and explains how to finish.
    case copyAndContinue
    /// Pay outside any app (cash or other) and record it.
    case recordManually

    var label: String {
        switch self {
        case .amountPrepared: String(localized: "Amount prepared")
        case .opensProvider: String(localized: "Opens provider")
        case .copyAndContinue: String(localized: "Copy and continue")
        case .recordManually: String(localized: "Record manually")
        }
    }

    var symbolName: String {
        switch self {
        case .amountPrepared: "dollarsign.arrow.circlepath"
        case .opensProvider: "arrow.up.forward.app"
        case .copyAndContinue: "doc.on.doc"
        case .recordManually: "square.and.pencil"
        }
    }
}

/// A value the payer may need in the other app.
nonisolated struct HandoffCopyItem: Hashable, Sendable {
    let label: String
    let value: String
}

nonisolated struct HandoffLink: Hashable, Sendable {
    let title: String
    let url: URL
}

/// What Square Up does when the payer chooses this method.
nonisolated enum HandoffAction: Equatable, Sendable {
    /// Present the standard Messages composer (Apple Cash). Square Up cannot pick Apple Cash,
    /// insert the amount, send, or read status.
    case composeMessage(recipient: String, body: String)
    /// Open an allowlisted HTTPS link.
    case openURL(URL)
    /// Nothing to open: copy the details and finish in another app.
    case copyDetails
    /// No app involved (cash or other).
    case recordManually
}

nonisolated struct HandoffPlan: Equatable, Sendable {
    let provider: PaymentProviderKind
    let capability: HandoffCapability
    let primaryTitle: String
    let action: HandoffAction
    let copyItems: [HandoffCopyItem]
    let steps: [String]
    let warning: String?
    let secondaryLinks: [HandoffLink]
}

/// Builds the strongest officially supported handoff for a destination (milestone 2 §12).
/// Every link it returns has passed `ExternalURLPolicy`; nothing else is ever opened.
nonisolated enum HandoffPlanner {
    static let zelleBankFinder = URL(string: "https://www.zelle.com/get-started")!

    static func plan(
        destination: PaymentDestination?,
        provider: PaymentProviderKind,
        amount: Money,
        memo: String,
        reference: String,
        recipientName: String,
        groupName: String,
        locale: Locale = .autoupdatingCurrent
    ) -> HandoffPlan {
        let plainAmount = amount.amount.formatted(
            .number.locale(Locale(identifier: "en_US_POSIX")).grouping(.never).precision(.fractionLength(amount.currency.minorUnitDigits))
        )
        let ctx = Context(
            destination: destination, provider: provider, amount: amount, reference: reference,
            recipientName: recipientName, groupName: groupName,
            amountText: MoneyFormatting.string(amount, locale: locale),
            amountItem: HandoffCopyItem(label: String(localized: "Amount"), value: plainAmount),
            memoItem: HandoffCopyItem(label: String(localized: "Note"), value: memo),
            value: destination?.value,
            revealed: destination.map { DestinationPresentation.revealed($0.value, provider: provider) }
        )
        switch provider {
        case .appleCash: return appleCash(ctx)
        case .paypal: return payPal(ctx)
        case .cashApp: return cashApp(ctx)
        case .zelle: return zelle(ctx)
        case .venmo: return venmo(ctx)
        case .cash, .other: return manual(ctx)
        }
    }

    /// Everything a provider-specific planner needs.
    private nonisolated struct Context {
        let destination: PaymentDestination?
        let provider: PaymentProviderKind
        let amount: Money
        let reference: String
        let recipientName: String
        let groupName: String
        let amountText: String
        let amountItem: HandoffCopyItem
        let memoItem: HandoffCopyItem
        let value: DestinationValue?
        let revealed: String?
    }

    private static func appleCash(_ ctx: Context) -> HandoffPlan {
        let recipient: String? = switch ctx.value {
        case .phone(let phone): phone
        case .email(let email): email
        default: nil
        }
        let body = String(localized: "Square Up: Paying you \(ctx.amountText) for \(ctx.groupName). Settlement \(ctx.reference).")
        let steps = [
            String(localized: "Square Up copies \(ctx.amountText) and opens Messages to \(ctx.recipientName)."),
            String(localized: "In Messages, tap +, choose Apple Cash, paste \(ctx.amountText), review, and send."),
            String(localized: "Come back here and say whether you sent it."),
        ]
        guard let recipient else {
            return HandoffPlan(provider: ctx.provider, capability: .copyAndContinue, primaryTitle: String(localized: "Copy ctx.amount"),
                               action: .copyDetails, copyItems: [ctx.amountItem, ctx.memoItem], steps: steps, warning: nil, secondaryLinks: [])
        }
        return HandoffPlan(
            provider: ctx.provider, capability: .copyAndContinue, primaryTitle: String(localized: "Continue in Messages"),
            action: .composeMessage(recipient: recipient, body: body),
            copyItems: [ctx.amountItem, HandoffCopyItem(label: String(localized: "Recipient"), value: ctx.revealed ?? recipient)],
            steps: steps, warning: String(localized: "Square Up can't see Apple Cash. Only you can confirm you sent it."), secondaryLinks: []
        )
    }

    private static func payPal(_ ctx: Context) -> HandoffPlan {
        guard case .username(let username)? = ctx.value,
              let url = payPalLink(username: username, amount: ctx.amount) else {
            return unavailable(ctx.provider, amountItem: ctx.amountItem, memoItem: ctx.memoItem)
        }
        return HandoffPlan(
            provider: ctx.provider, capability: .amountPrepared, primaryTitle: String(localized: "Open PayPal"),
            action: .openURL(url),
            copyItems: [HandoffCopyItem(label: String(localized: "PayPal.Me"), value: ctx.revealed ?? ""), ctx.amountItem, ctx.memoItem],
            steps: [
                String(localized: "PayPal opens with \(ctx.amountText) to \(ctx.revealed ?? "") filled in."),
                String(localized: "Check the name, review, and send in PayPal."),
                String(localized: "Come back here and say whether you sent it."),
            ],
            warning: nil, secondaryLinks: []
        )
    }

    private static func cashApp(_ ctx: Context) -> HandoffPlan {
        var items: [HandoffCopyItem] = []
        if case .username = ctx.value, let revealed = ctx.revealed { items.append(HandoffCopyItem(label: String(localized: "$Cashtag"), value: revealed)) }
        items += [ctx.amountItem, ctx.memoItem]
        let link: URL? = if case .link(let url)? = ctx.value { url } else { ctx.destination?.link }
        if let link, ExternalURLPolicy.isAllowed(link, for: .cashApp) {
            return HandoffPlan(
                provider: ctx.provider, capability: .opensProvider, primaryTitle: String(localized: "Open \(ctx.recipientName)'s Cash App link"),
                action: .openURL(link), copyItems: items,
                steps: [
                    String(localized: "Opens the payment link \(ctx.recipientName) shared."),
                    String(localized: "Enter \(ctx.amountText), add the note, and send in Cash App."),
                    String(localized: "Come back here and say whether you sent it."),
                ],
                warning: nil, secondaryLinks: []
            )
        }
        guard case .username = ctx.value else { return unavailable(ctx.provider, amountItem: ctx.amountItem, memoItem: ctx.memoItem) }
        return HandoffPlan(
            provider: ctx.provider, capability: .copyAndContinue, primaryTitle: String(localized: "Copy details"),
            action: .copyDetails, copyItems: items,
            steps: [
                String(localized: "Open Cash App and tap $."),
                String(localized: "Enter \(ctx.amountText), tap Pay, and search \(ctx.revealed ?? "")."),
                String(localized: "Paste the note, review, and send. Then come back here."),
            ],
            warning: nil, secondaryLinks: []
        )
    }

    private static func zelle(_ ctx: Context) -> HandoffPlan {
        var items: [HandoffCopyItem] = []
        if let revealed = ctx.revealed { items.append(HandoffCopyItem(label: String(localized: "Zelle email or phone"), value: revealed)) }
        items += [ctx.amountItem, ctx.memoItem]
        var links: [HandoffLink] = []
        if let qr = ctx.destination?.link, ExternalURLPolicy.isAllowed(qr, for: .zelle) {
            links.append(HandoffLink(title: String(localized: "Open \(ctx.recipientName)'s Zelle QR link"), url: qr))
        }
        links.append(HandoffLink(title: String(localized: "Find Zelle in your bank's app"), url: zelleBankFinder))
        return HandoffPlan(
            provider: ctx.provider, capability: .copyAndContinue, primaryTitle: String(localized: "Copy details"),
            action: .copyDetails, copyItems: items,
            steps: [
                String(localized: "Open your bank or credit union app and go to Zelle."),
                String(localized: "Send \(ctx.amountText) to \(ctx.revealed ?? ctx.recipientName)."),
                String(localized: "Check that your bank shows \(ctx.recipientName) as the recipient before you send. Then come back here."),
            ],
            warning: String(localized: "Zelle payments usually can't be cancelled. Only send money to people you know and trust."),
            secondaryLinks: links
        )
    }

    private static func venmo(_ ctx: Context) -> HandoffPlan {
        guard case .username = ctx.value, let revealed = ctx.revealed else { return unavailable(ctx.provider, amountItem: ctx.amountItem, memoItem: ctx.memoItem) }
        return HandoffPlan(
            provider: ctx.provider, capability: .copyAndContinue, primaryTitle: String(localized: "Copy details"),
            action: .copyDetails,
            copyItems: [HandoffCopyItem(label: String(localized: "Venmo username"), value: revealed), ctx.amountItem, ctx.memoItem],
            steps: [
                String(localized: "Open Venmo and tap Pay/Request."),
                String(localized: "Search \(revealed), enter \(ctx.amountText), and paste the note."),
                String(localized: "Review and pay, then come back here."),
            ],
            warning: nil, secondaryLinks: []
        )
    }

    private static func manual(_ ctx: Context) -> HandoffPlan {
        let instructions: String? = if case .instructions(let text)? = ctx.value { text } else { nil }
        return HandoffPlan(
            provider: ctx.provider, capability: .recordManually,
            primaryTitle: ctx.provider == .cash ? String(localized: "I'll pay in cash") : String(localized: "Pay another way"),
            action: .recordManually, copyItems: [ctx.amountItem],
            steps: [
                instructions ?? (ctx.provider == .cash ? String(localized: "Pay \(ctx.recipientName) \(ctx.amountText) in person.")
                    : String(localized: "Pay \(ctx.recipientName) \(ctx.amountText) the way you agreed.")),
                String(localized: "Then report it here so \(ctx.recipientName) can confirm."),
            ],
            warning: nil, secondaryLinks: []
        )
    }

    /// `https://paypal.me/<name>/<amount><CUR>` — PayPal's documented amount + currency format.
    static func payPalLink(username: String, amount: Money) -> URL? {
        guard PaymentDestinationValidator.payPalUsername(from: username) == username, amount.isPositive else { return nil }
        let value = amount.amount.formatted(
            .number.locale(Locale(identifier: "en_US_POSIX")).grouping(.never).precision(.fractionLength(amount.currency.minorUnitDigits))
        )
        guard let url = URL(string: "https://paypal.me/\(username)/\(value)\(amount.currency.rawValue)"),
              ExternalURLPolicy.isAllowed(url, for: .paypal) else { return nil }
        return url
    }

    /// A destination that can't be handed off safely (malformed or missing details).
    private static func unavailable(_ provider: PaymentProviderKind, amountItem: HandoffCopyItem, memoItem: HandoffCopyItem) -> HandoffPlan {
        HandoffPlan(
            provider: provider, capability: .copyAndContinue, primaryTitle: String(localized: "Copy amount"),
            action: .copyDetails, copyItems: [amountItem, memoItem],
            steps: [String(localized: "These details can't be opened safely. Ask the recipient to update this payment method, or copy the amount and pay another way.")],
            warning: String(localized: "This payment method looks incomplete."), secondaryLinks: []
        )
    }

    /// Whether a destination has what its provider needs (for the "unavailable" row state).
    static func isUsable(_ destination: PaymentDestination) -> Bool {
        switch (destination.provider, destination.value) {
        case (.appleCash, .phone), (.appleCash, .email), (.zelle, .phone), (.zelle, .email): true
        case (.paypal, .username(let name)): PaymentDestinationValidator.payPalUsername(from: name) == name
        case (.cashApp, .username(let tag)): PaymentDestinationValidator.cashtag(from: tag) == tag
        case (.cashApp, .link(let url)): ExternalURLPolicy.isAllowed(url, for: .cashApp)
        case (.venmo, .username(let name)): PaymentDestinationValidator.venmoUsername(from: name) == name
        case (.cash, .instructions), (.other, .instructions): true
        default: false
        }
    }
}
