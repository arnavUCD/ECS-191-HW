import Foundation

nonisolated enum PaymentTransitionError: Error, Equatable, Sendable {
    /// The action is not allowed from the attempt's current state.
    case notAllowed(from: PaymentAttemptState, action: String)
    /// Only the payer (or recipient, depending on the action) may do this.
    case notAuthorized(action: String)
}

/// The legal payment-attempt lifecycle (milestone 2 §13).
///
/// ```text
/// methodSelected → handoffOpened → reportedSent → confirmed
/// methodSelected/handoffOpened → reportedSent      (cash, or paid without a handoff)
/// methodSelected/handoffOpened/reportedSent → cancelled   (payer, before confirmation)
/// reportedSent → rejected | disputed
/// disputed → confirmed | rejected
/// ```
///
/// Repeating an action that already took effect (report twice, confirm twice) is an idempotent
/// no-op rather than an error, so double taps and retries can never duplicate money.
nonisolated enum PaymentAttemptMachine {
    nonisolated struct Outcome: Equatable, Sendable {
        let attempt: PaymentAttempt
        /// False when the action was a repeat of a state already reached.
        let didChange: Bool
    }

    static func apply(
        _ action: PaymentAttemptAction,
        to attempt: PaymentAttempt,
        actor: MemberID,
        at date: Date
    ) throws(PaymentTransitionError) -> Outcome {
        let isPayer = actor == attempt.payerID
        let isRecipient = actor == attempt.recipientID
        let state = attempt.state

        func move(_ next: PaymentAttemptState, note: String? = nil, mutate: (inout PaymentAttempt) -> Void = { _ in }) -> Outcome {
            var updated = attempt
            updated.state = next
            updated.history.append(PaymentAttemptTransition(state: next, actorID: actor, date: date, note: note))
            mutate(&updated)
            return Outcome(attempt: updated, didChange: true)
        }
        let unchanged = Outcome(attempt: attempt, didChange: false)

        switch action {
        case .openHandoff:
            guard isPayer else { throw .notAuthorized(action: "openHandoff") }
            switch state {
            case .methodSelected: return move(.handoffOpened)
            case .handoffOpened: return unchanged
            default: throw .notAllowed(from: state, action: "openHandoff")
            }

        case .reportSent(let reference):
            guard isPayer else { throw .notAuthorized(action: "reportSent") }
            switch state {
            case .methodSelected, .handoffOpened:
                let trimmed = reference?.trimmingCharacters(in: .whitespacesAndNewlines)
                return move(.reportedSent) { $0.externalReference = (trimmed?.isEmpty ?? true) ? nil : trimmed }
            case .reportedSent: return unchanged
            default: throw .notAllowed(from: state, action: "reportSent")
            }

        case .confirm:
            guard isRecipient else { throw .notAuthorized(action: "confirm") }
            switch state {
            case .reportedSent, .disputed: return move(.confirmed)
            case .confirmed: return unchanged
            default: throw .notAllowed(from: state, action: "confirm")
            }

        case .reject(let reason):
            guard isRecipient else { throw .notAuthorized(action: "reject") }
            switch state {
            case .reportedSent, .disputed: return move(.rejected, note: reason)
            case .rejected: return unchanged
            default: throw .notAllowed(from: state, action: "reject")
            }

        case .dispute(let reason):
            guard isPayer || isRecipient else { throw .notAuthorized(action: "dispute") }
            switch state {
            case .reportedSent: return move(.disputed, note: reason)
            case .disputed: return unchanged
            default: throw .notAllowed(from: state, action: "dispute")
            }

        case .cancel(let reason):
            guard isPayer else { throw .notAuthorized(action: "cancel") }
            switch state {
            case .methodSelected, .handoffOpened, .reportedSent: return move(.cancelled, note: reason.rawValue)
            case .cancelled: return unchanged
            default: throw .notAllowed(from: state, action: "cancel")
            }
        }
    }
}
