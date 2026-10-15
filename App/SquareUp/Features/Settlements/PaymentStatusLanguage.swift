import SwiftUI

/// Copy for payment attempts. Never claims Square Up verified or moved money.
nonisolated enum PaymentStatusLanguage {
    static func label(for state: PaymentAttemptState) -> String {
        switch state {
        case .methodSelected: String(localized: "Not paid yet")
        case .handoffOpened: String(localized: "Not reported yet")
        case .reportedSent: String(localized: "Awaiting confirmation")
        case .confirmed: String(localized: "Confirmed received")
        case .rejected: String(localized: "Not received")
        case .disputed: String(localized: "Disputed")
        case .cancelled: String(localized: "Cancelled")
        }
    }

    /// Past-tense wording for a payment's timeline.
    static func timelineLabel(for state: PaymentAttemptState, provider: PaymentProviderKind) -> String {
        switch state {
        case .methodSelected: String(localized: "Started paying with \(provider.displayName)")
        case .handoffOpened: String(localized: "Opened \(provider.displayName)")
        case .reportedSent: String(localized: "Reported as sent")
        case .confirmed: String(localized: "Confirmed received")
        case .rejected: String(localized: "Marked not received")
        case .disputed: String(localized: "Disputed")
        case .cancelled: String(localized: "Cancelled")
        }
    }

    static func symbol(for state: PaymentAttemptState) -> String {
        switch state {
        case .methodSelected: "circle.dashed"
        case .handoffOpened: "arrow.up.forward.app"
        case .reportedSent: "hourglass"
        case .confirmed: "checkmark.seal.fill"
        case .rejected: "xmark.octagon"
        case .disputed: "exclamationmark.bubble"
        case .cancelled: "xmark.circle"
        }
    }

    /// "You reported paying Maya" / "Alex reported paying you" / "Alex reported paying Maya".
    static func headline(for attempt: PaymentAttempt, members: [MemberID: Member], currentUserID: MemberID) -> String {
        let labels = PersonIdentity.shortLabels(for: Array(members.values))
        let isMine = attempt.payerID == currentUserID
        let payer = isMine ? String(localized: "You") : (labels[attempt.payerID] ?? "")
        let recipient = attempt.recipientID == currentUserID ? String(localized: "you") : (labels[attempt.recipientID] ?? "")
        switch attempt.state {
        case .methodSelected, .handoffOpened:
            return String(localized: "\(payer) started paying \(recipient)")
        case .reportedSent:
            return String(localized: "\(payer) reported paying \(recipient)")
        case .confirmed:
            return String(localized: "\(payer) paid \(recipient)")
        case .rejected:
            return isMine ? String(localized: "Your payment to \(recipient) wasn't received")
                : String(localized: "\(payer)'s payment to \(recipient) wasn't received")
        case .disputed:
            return isMine ? String(localized: "Your payment to \(recipient) is disputed")
                : String(localized: "\(payer)'s payment to \(recipient) is disputed")
        case .cancelled:
            return String(localized: "\(payer) cancelled a payment to \(recipient)")
        }
    }

    /// The recipient's question (milestone 2 §13 "Confirmation copy").
    static func recipientQuestion(for attempt: PaymentAttempt, members: [MemberID: Member], locale: Locale = .autoupdatingCurrent) -> String {
        let payer = members[attempt.payerID]?.displayName ?? ""
        let amount = MoneyFormatting.string(attempt.amount, locale: locale)
        return String(localized: "\(payer) reported paying you \(amount) through \(attempt.provider.displayName). Did you receive it?")
    }

    /// The payer's return prompt (milestone 2 §12 "Return prompt").
    static func returnQuestion(for attempt: PaymentAttempt, members: [MemberID: Member], locale: Locale = .autoupdatingCurrent) -> String {
        let recipient = members[attempt.recipientID]?.firstName ?? ""
        let amount = MoneyFormatting.string(attempt.amount, locale: locale)
        return String(localized: "Did you send \(amount) to \(recipient)?")
    }
}

extension PaymentAttemptState {
    var tone: SUTone {
        switch self {
        case .methodSelected, .handoffOpened, .cancelled: .neutral
        case .reportedSent, .disputed: .warning
        case .confirmed: .positive
        case .rejected: .negative
        }
    }
}

/// A payment state as text + symbol + tone.
struct PaymentStateChip: View {
    let state: PaymentAttemptState

    var body: some View {
        SUStatusChip(
            title: PaymentStatusLanguage.label(for: state),
            systemImage: PaymentStatusLanguage.symbol(for: state),
            tone: state.tone
        )
    }
}
