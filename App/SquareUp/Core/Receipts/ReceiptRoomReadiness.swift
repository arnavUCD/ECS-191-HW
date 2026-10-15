import Foundation

/// Something that must be resolved before a room can be finalized (milestone 3 §9.1).
nonisolated enum ReadinessIssue: Hashable, Sendable {
    case receipt(ReceiptIssue.Kind)
    case unclaimedItem(ReceiptItemID)
    case partiallyAssignedItem(ReceiptItemID, remaining: Money)
    case invalidItemSplit(ReceiptItemID, ItemAllocation.InvalidReason)
    case unallocatedCharge(ReceiptChargeID, ChargeAllocationResult.Status)
    case openDispute(ReceiptDisputeID)
    /// Receipt total − participant totals.
    case totalsDoNotMatch(remaining: Money)
    case groupMissing
    case payerMissing
    case payerNotInGroup(MemberID)
    case participantNotInGroup(MemberID)
    /// Credits exceed this person's items; the expense can't record a negative share.
    case negativeParticipantTotal(MemberID, Money)
    /// Everything is assigned to the payer and the host hasn't confirmed that is intended.
    case onlyPayerOwes
}

/// Readiness rules shared by the room UI and the finalization command (one source of truth).
nonisolated enum ReceiptRoomReadiness {
    static func issues(for room: ReceiptRoom, in state: LedgerSnapshot) -> [ReadinessIssue] {
        issues(for: room, allocation: ReceiptAllocationEngine.allocate(room), group: room.groupID.flatMap(state.group))
    }

    static func issues(for room: ReceiptRoom, allocation: ReceiptAllocation, group: ExpenseGroup?) -> [ReadinessIssue] {
        var issues: [ReadinessIssue] = []
        guard let group else { return [.groupMissing] }
        let reconciliation = ReceiptValidator.reconcile(room.receipt, groupCurrency: group.currency)
        issues += reconciliation.blockingIssues.map { .receipt($0.kind) }
        if let payerID = room.payerID {
            if !group.isActiveMember(payerID) { issues.append(.payerNotInGroup(payerID)) }
        } else {
            issues.append(.payerMissing)
        }
        for id in room.participantIDs where !group.isActiveMember(id) {
            issues.append(.participantNotInGroup(id))
        }
        for item in allocation.items {
            switch item.status {
            case .note, .allocated: continue
            case .unclaimed: issues.append(.unclaimedItem(item.itemID))
            case .partial(let remaining): issues.append(.partiallyAssignedItem(item.itemID, remaining: remaining))
            case .invalid(let reason): issues.append(.invalidItemSplit(item.itemID, reason))
            }
        }
        for charge in allocation.charges where !charge.isAllocated {
            issues.append(.unallocatedCharge(charge.chargeID, charge.status))
        }
        issues += room.openDisputes.map { .openDispute($0.id) }
        if let remaining = allocation.remaining, !remaining.isZero, reconciliation.isReconciled {
            issues.append(.totalsDoNotMatch(remaining: remaining))
        }
        for participant in allocation.participants where participant.total.isNegative {
            issues.append(.negativeParticipantTotal(participant.memberID, participant.total))
        }
        let owing = allocation.participants.filter { !$0.total.isZero && $0.memberID != room.payerID }
        if issues.isEmpty, owing.isEmpty, !room.payerAcceptsFullReceipt {
            issues.append(.onlyPayerOwes)
        }
        return issues
    }

    static func isReady(_ room: ReceiptRoom, in state: LedgerSnapshot) -> Bool {
        issues(for: room, in: state).isEmpty
    }
}
