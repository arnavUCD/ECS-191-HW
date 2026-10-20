import Foundation

/// Membership actions and plain-language summaries of commands (milestone 7). Split from
/// `SharedGroupLedger.swift` for size; same type, same rules.
extension SharedGroupLedger {

    // MARK: - Membership (§3.3)

    /// Leaves the group (members only; the owner transfers ownership or archives first).
    func leave() async throws {
        try await sendGroupCommand("leaveGroup", payload: [:], summary: String(localized: "Leave the group"))
    }

    /// Makes another joined member the owner. Invitations the previous owner created stop working.
    func transferOwnership(to member: MemberID) async throws {
        try await sendGroupCommand("transferOwnership", payload: ["memberId": .string(SharedGroupMapper.id(member))],
                                   summary: String(localized: "Change the owner"))
    }

    /// Archives the group: nothing new can be added, history stays readable, invitations stop.
    func archive() async throws {
        try await sendGroupCommand("archiveGroup", payload: [:], summary: String(localized: "Archive the group"))
    }

    /// A revision-strict, high-consequence group command: needs a live answer, never queued.
    private func sendGroupCommand(_ type: String, payload: [String: JSONValue], summary: String) async throws {
        _ = try await enqueue {
            if self.base == nil { try await self.refresh() }
            guard let current = self.base else { throw LedgerError.remote(.unavailable) }
            let envelope = GroupCommandEnvelope(type: type, payload: .object(payload), expectedRevision: current.revision, knownCursor: current.cursor)
            let wire = SharedGroupMapper.WireCommand(type: type, payload: envelope.payload, isRevisionStrict: true, requiresLiveResponse: true)
            return try await self.deliverAndAccept(envelope, wire: wire, command: nil, summary: summary, local: nil, previewID: nil)
        }
    }

    // MARK: - Descriptions

    static func summary(of command: LedgerCommand, in snapshot: LedgerSnapshot) -> String {
        func money(_ value: Money) -> String { MoneyFormatting.string(value) }
        switch command {
        case .addExpense(let expense): return String(localized: "Add \(expense.title) · \(money(expense.total))")
        case .updateExpense(let expense): return String(localized: "Edit \(expense.title)")
        case .deleteExpense(let id): return String(localized: "Delete \(snapshot.expense(id)?.title ?? "")")
        case .restoreExpense(let id): return String(localized: "Restore \(snapshot.expense(id)?.title ?? "")")
        case .updateGroup: return String(localized: "Edit the group")
        case .setSimplification: return String(localized: "Change simplified payments")
        case .addMember(_, let draft): return String(localized: "Add \(draft.displayName)")
        case .removeMember(_, let id): return String(localized: "Remove \(snapshot.members[id]?.displayName ?? "")")
        case .startPayment(let request): return String(localized: "Start paying \(snapshot.members[request.recipientID]?.displayName ?? "")")
        case .recordSettlement(let settlement):
            return String(localized: "Mark \(snapshot.members[settlement.fromID]?.displayName ?? "") as settled · \(money(settlement.amount))")
        case .advancePayment(_, let action):
            switch action {
            case .confirm: return String(localized: "Confirm receiving a payment")
            case .reject: return String(localized: "Say a payment didn't arrive")
            case .dispute: return String(localized: "Dispute a payment")
            case .reportSent: return String(localized: "Report a payment sent")
            case .openHandoff: return String(localized: "Open the payment app")
            case .cancel: return String(localized: "Cancel a payment")
            }
        default: return String(localized: "A change")
        }
    }
}

extension LedgerError {
    /// A shared-group refusal in the app's own terms where one exists, else the server's safe message.
    nonisolated static func from(group refusal: ServerRefusal, currency: CurrencyCode) -> LedgerError {
        let owed = refusal.owed.map { Money(minorUnits: Int64($0), currency: currency) }
        switch refusal.code {
        case "exceeds_obligation": return .rule(.exceedsObligation(owed ?? .zero(currency)))
        case "no_obligation": return .rule(.noObligation)
        case "pending_payment_conflict":
            return .rule(.pendingPaymentConflict((refusal.attemptIds ?? []).compactMap(PaymentAttemptID.init(string:))))
        case "member_has_open_payment": return .rule(.memberHasOpenPayment(MemberID()))
        case "currency_locked": return .rule(.currencyLocked)
        case "cannot_pay_self": return .rule(.cannotPaySelf)
        case "destination_unavailable": return .rule(.destinationUnavailable)
        case "attempt_not_found": return .rule(.attemptNotFound)
        case "expense_not_found": return .rule(.expenseNotFound)
        case "expense_deleted": return .rule(.expenseDeleted)
        case "invalid_expense":
            switch refusal.reason {
            case "emptyTitle": return .invalidExpense(.emptyTitle)
            case "noPayer": return .invalidExpense(.noPayer)
            case "noParticipants": return .invalidExpense(.noParticipants)
            case "negativeShare": return .invalidExpense(.negativeShare)
            default: return .remote(.refused(refusal.message))
            }
        default: return .remote(.refused(refusal.message))
        }
    }
}
