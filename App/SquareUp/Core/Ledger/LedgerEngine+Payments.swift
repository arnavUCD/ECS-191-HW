import Foundation

/// Payment-destination and payment-attempt rules. Split from `LedgerEngine.swift` for size;
/// same type, same single source of truth.
nonisolated extension LedgerEngine {

    // MARK: - Payment destinations

    static func saveDestination(_ destination: PaymentDestination, _ builder: inout Builder) throws {
        guard destination.ownerID == builder.actor else { throw LedgerRuleViolation.notDestinationOwner }
        if let existing = builder.state.destination(destination.id), existing.ownerID != destination.ownerID {
            throw LedgerRuleViolation.notDestinationOwner
        }
        // Defence in depth: links must pass the provider allowlist even if the UI was bypassed.
        let links = [destination.link] + [{ if case .link(let url) = destination.value { return url } else { return nil } }()]
        guard links.compactMap({ $0 }).allSatisfy({ ExternalURLPolicy.isAllowed($0, for: destination.provider) }) else {
            throw LedgerError.invalidDestination(.invalidLink)
        }
        let siblings = builder.state.paymentDestinations.filter { $0.ownerID == destination.ownerID && $0.id != destination.id }
        var saved = destination
        saved.updatedAt = builder.now
        // The first enabled method is preferred automatically; a disabled method cannot be preferred.
        if !saved.isEnabled { saved.isPreferred = false }
        if saved.isEnabled, !siblings.contains(where: { $0.isPreferred && $0.isEnabled }) { saved.isPreferred = true }
        if saved.isPreferred {
            for var sibling in siblings where sibling.isPreferred {
                sibling.isPreferred = false
                builder.result.changes.append(.upsertDestination(sibling))
            }
        }
        builder.result.changes.append(.upsertDestination(saved))
    }

    static func deleteDestination(_ id: PaymentDestinationID, _ builder: inout Builder) throws {
        guard let destination = builder.state.destination(id) else { throw LedgerRuleViolation.destinationNotFound }
        guard destination.ownerID == builder.actor else { throw LedgerRuleViolation.notDestinationOwner }
        builder.result.changes.append(.deleteDestination(id))
        if destination.isPreferred,
           var next = builder.state.destinations(of: destination.ownerID).first(where: { $0.id != id && $0.isEnabled }) {
            next.isPreferred = true
            builder.result.changes.append(.upsertDestination(next))
        }
    }

    // MARK: - Payments

    /// What the payer currently owes the recipient in the actionable plan (pending payments
    /// already reserved), or nil when there is no such obligation.
    static func availableObligation(groupID: GroupID, payerID: MemberID, recipientID: MemberID,
                                    in state: LedgerSnapshot, excluding attemptID: PaymentAttemptID? = nil) -> Money? {
        guard let group = state.group(groupID) else { return nil }
        let attempts = state.attempts(in: groupID).filter { $0.id != attemptID }
        let plan = SettlementPlanner.plan(for: group, expenses: state.expenses(in: groupID),
                                          settlements: state.settlements(in: groupID), attempts: attempts)
        return plan.payment(from: payerID, to: recipientID)?.amount
    }

    static func startPayment(_ request: PaymentRequest, _ builder: inout Builder, _ makeID: () -> UUID) throws {
        let state = builder.state
        let group = try requireGroup(request.groupID, state)
        guard request.payerID == builder.actor else { throw PaymentTransitionError.notAuthorized(action: "startPayment") }
        guard request.payerID != request.recipientID else { throw LedgerRuleViolation.cannotPaySelf }
        guard group.isActiveMember(request.payerID), group.isActiveMember(request.recipientID) else {
            throw LedgerRuleViolation.notAGroupMember
        }
        guard request.amount.currency == group.currency else { throw LedgerRuleViolation.currencyMismatch }
        guard request.amount.isPositive else { throw LedgerRuleViolation.nonPositiveAmount }
        guard let owed = availableObligation(groupID: group.id, payerID: request.payerID, recipientID: request.recipientID, in: state) else {
            throw LedgerRuleViolation.noObligation
        }
        guard request.amount <= owed else { throw LedgerRuleViolation.exceedsObligation(owed) }
        if let destinationID = request.destinationID {
            guard let destination = state.destination(destinationID), destination.ownerID == request.recipientID,
                  destination.isEnabled, destination.provider == request.provider
            else { throw LedgerRuleViolation.destinationUnavailable }
        }

        // Opening two handoffs for one obligation: the newer draft replaces the older one.
        let key = PaymentAttempt.obligationKey(groupID: group.id, payerID: request.payerID, recipientID: request.recipientID)
        for draft in state.attempts(in: group.id) where draft.obligationKey == key && draft.state.isDraft {
            let outcome = try PaymentAttemptMachine.apply(.cancel(.superseded), to: draft, actor: builder.actor, at: builder.now)
            builder.result.changes.append(.upsertAttempt(outcome.attempt))
            builder.event(group.id, .paymentCancelled(PaymentEventInfo(outcome.attempt), reason: .superseded), makeID)
        }

        let id = PaymentAttemptID(makeID())
        let attempt = PaymentAttempt(
            id: id, groupID: group.id, payerID: request.payerID, recipientID: request.recipientID,
            destinationID: request.destinationID, provider: request.provider, amount: request.amount,
            memo: String(localized: "Square Up · \(group.name) · \(PaymentAttempt.reference(for: id))"),
            state: .methodSelected,
            history: [PaymentAttemptTransition(state: .methodSelected, actorID: builder.actor, date: builder.now)]
        )
        builder.result.changes.append(.upsertAttempt(attempt))
        builder.result.attempt = attempt
        builder.event(group.id, .paymentStarted(PaymentEventInfo(attempt)), makeID)
    }

    static func advancePayment(_ id: PaymentAttemptID, _ action: PaymentAttemptAction,
                               _ builder: inout Builder, _ makeID: () -> UUID) throws {
        let state = builder.state
        guard let attempt = state.attempt(id) else { throw LedgerRuleViolation.attemptNotFound }
        let outcome: PaymentAttemptMachine.Outcome
        do {
            outcome = try PaymentAttemptMachine.apply(action, to: attempt, actor: builder.actor, at: builder.now)
        } catch {
            throw LedgerError.invalidTransition(error)
        }
        builder.result.attempt = outcome.attempt
        guard outcome.didChange else {
            builder.result.settlement = attempt.settlementID.flatMap { sid in state.settlements.first { $0.id == sid } }
            return
        }
        var updated = outcome.attempt
        let info = PaymentEventInfo(updated)

        switch action {
        case .openHandoff:
            break
        case .reportSent:
            // The plan may have changed since the draft began (edits, other payments). Never let
            // a report reserve more than is still owed.
            let owed = availableObligation(groupID: attempt.groupID, payerID: attempt.payerID,
                                           recipientID: attempt.recipientID, in: state, excluding: attempt.id)
            guard let owed else { throw LedgerRuleViolation.noObligation }
            guard attempt.amount <= owed else { throw LedgerRuleViolation.exceedsObligation(owed) }
            builder.event(attempt.groupID, .paymentReported(info), makeID)
        case .confirm:
            // Deterministic identifier: confirming the same attempt can only ever produce this one settlement.
            let settlementID = SettlementID(attempt.id.rawValue)
            if !state.settlements.contains(where: { $0.id == settlementID || $0.attemptID == attempt.id }) {
                let settlement = Settlement(
                    id: settlementID, groupID: attempt.groupID, fromID: attempt.payerID, toID: attempt.recipientID,
                    amount: attempt.amount, date: builder.now, note: attempt.memo, recordedBy: attempt.payerID,
                    provider: attempt.provider, attemptID: attempt.id, confirmedAt: builder.now, confirmedBy: builder.actor
                )
                builder.result.changes.append(.upsertSettlement(settlement))
                builder.result.settlement = settlement
            }
            updated.settlementID = settlementID
            builder.event(attempt.groupID, .paymentConfirmed(info, settlementID: settlementID), makeID)
        case .reject(let reason):
            builder.event(attempt.groupID, .paymentRejected(info, reason: reason), makeID)
        case .dispute(let reason):
            builder.event(attempt.groupID, .paymentDisputed(info, reason: reason), makeID)
        case .cancel(let reason):
            builder.event(attempt.groupID, .paymentCancelled(info, reason: reason), makeID)
        }
        builder.result.attempt = updated
        builder.result.changes.insert(.upsertAttempt(updated), at: 0)
    }
}
