import Foundation

/// "Mine" or "Share" from the item row (milestone 3 §8.6).
nonisolated enum ClaimRequest: Hashable, Sendable {
    /// The whole item; refused if someone else has claimed it.
    case mine
    /// Join (or start) an equal or weighted share.
    case share
}

/// Host-driven lifecycle moves between the claiming states.
nonisolated enum ReceiptRoomTransition: Hashable, Sendable {
    /// open → resolving: participants can no longer change claims; the host resolves the rest.
    case beginResolving
    /// resolving → open.
    case reopenClaims
    /// open/resolving → readyToFinalize, only when every readiness rule passes.
    case requestFinalReview
    /// readyToFinalize → resolving.
    case returnToRoom
}

/// Every change to a receipt draft or room (milestone 3 §11 `ReceiptRoomCommandHandling`).
///
/// Commands after creation carry the room revision they were based on; a stale revision is
/// refused (`staleRevision`) so an older view can never silently overwrite newer state. A future
/// server-backed repository receives exactly these commands.
nonisolated enum ReceiptRoomCommand: Sendable {
    case createDraft(ReceiptRoomID, groupID: GroupID?, pages: [ReceiptAsset], currency: CurrencyCode)
    case saveDraft(ReceiptRoomID, expectedRevision: Int, receipt: ReceiptDraft, groupID: GroupID?, payerID: MemberID?)
    case confirmReceipt(ReceiptRoomID, expectedRevision: Int)
    case reopenReview(ReceiptRoomID, expectedRevision: Int)
    case openRoom(ReceiptRoomID, expectedRevision: Int, participants: [MemberID])
    case setParticipants(ReceiptRoomID, expectedRevision: Int, participants: [MemberID])
    case claim(ReceiptRoomID, expectedRevision: Int, item: ReceiptItemID, ClaimRequest)
    case unclaim(ReceiptRoomID, expectedRevision: Int, item: ReceiptItemID)
    /// "I had 2 of the 3": sets the actor's own claim to a number of the line's printed quantity
    /// (`0` removes it). Never changes anyone else's claim; asking for more than is left is refused.
    case claimUnits(ReceiptRoomID, expectedRevision: Int, item: ReceiptItemID, units: Int)
    case setItemSplit(ReceiptRoomID, expectedRevision: Int, item: ReceiptItemID, ItemSplit)
    case dispute(ReceiptRoomID, expectedRevision: Int, DisputeTarget, note: String?)
    case resolveDispute(ReceiptRoomID, expectedRevision: Int, ReceiptDisputeID, DisputeStatus, note: String?)
    case setChargeAllocation(ReceiptRoomID, expectedRevision: Int, ReceiptChargeID, ChargeAllocation)
    case reviseReceipt(ReceiptRoomID, expectedRevision: Int, ReceiptDraft)
    case markReviewed(ReceiptRoomID, expectedRevision: Int)
    case setPayerAcceptsFullReceipt(ReceiptRoomID, expectedRevision: Int, Bool)
    case transition(ReceiptRoomID, expectedRevision: Int, ReceiptRoomTransition)
    /// Idempotent: repeating it after success changes nothing and creates no second expense.
    /// `acknowledging`: people whose share the host finalizes without their review (temporary rooms
    /// and group receipts refuse to finalize anyone's unreviewed share without it).
    case finalize(ReceiptRoomID, expectedRevision: Int, acknowledging: [MemberID] = [])
    case cancel(ReceiptRoomID, expectedRevision: Int)
    /// Deletes a never-opened draft. Image files are removed by the asset store afterwards.
    case discardDraft(ReceiptRoomID)
    /// Records that the receipt image files were removed; allocations and history remain.
    case markImagesRemoved(ReceiptRoomID)
    /// Milestone 4, host only: mirrors the authoritative shared room (participants already
    /// mapped to this device's members) onto the local room. When the shared room was finalized
    /// it finalizes locally — creating the itemized expense once — and refuses if the app's
    /// totals differ from the server's `finalTotals`. Idempotent.
    case adoptShared(ReceiptRoomID, room: ReceiptRoom, finalTotals: [MemberID: Money]?)

    var roomID: ReceiptRoomID {
        switch self {
        case .createDraft(let id, _, _, _), .saveDraft(let id, _, _, _, _), .confirmReceipt(let id, _), .reopenReview(let id, _),
             .openRoom(let id, _, _), .setParticipants(let id, _, _), .claim(let id, _, _, _), .unclaim(let id, _, _),
             .claimUnits(let id, _, _, _), .setItemSplit(let id, _, _, _), .dispute(let id, _, _, _), .resolveDispute(let id, _, _, _, _),
             .setChargeAllocation(let id, _, _, _), .reviseReceipt(let id, _, _), .markReviewed(let id, _),
             .setPayerAcceptsFullReceipt(let id, _, _), .transition(let id, _, _), .finalize(let id, _, _), .cancel(let id, _),
             .discardDraft(let id), .markImagesRemoved(let id), .adoptShared(let id, _, _):
            id
        }
    }
}

/// Receipt and room rule violations, each specific enough to explain in plain language.
nonisolated enum ReceiptRoomError: Error, Equatable, Sendable {
    case roomNotFound
    case roomAlreadyExists
    /// The room changed since the view loaded it. Associated value: the current revision.
    case staleRevision(current: Int)
    case notAllowedInState(ReceiptRoomState)
    case hostOnly
    case notAParticipant
    case itemNotFound
    case itemNotClaimable
    case chargeNotFound
    case disputeNotFound
    case itemAlreadyClaimed(by: MemberID)
    /// Exact amounts are set on this item; change it in the shared-item editor.
    case itemHasCustomSplit
    case noClaimToRemove
    /// Participants may divide an item only among people who already claimed it, plus themselves.
    case cannotIncludeOthers
    /// Re-dividing an item can't drop someone else's claim; only they (by unclaiming) or the host can.
    case cannotRemoveOthers
    /// Only this many of the line's quantity are still unclaimed.
    case unitsUnavailable(available: Int)
    /// Units can only be claimed on a line with a printed quantity.
    case itemQuantityUnknown
    /// These people haven't reviewed their current share; the host must wait or finalize for them.
    case unreviewedShares([MemberID])
    /// A temporary room passed its deadline; nothing more can change.
    case roomExpired
    /// A temporary room ended (everyone square, cancelled, or expired).
    case roomClosed
    case invalidSplit(ItemSplitIssue)
    case invalidChargeAllocation(ChargeAllocationResult.Status)
    case disputeAlreadyResolved
    case noteRequired
    case noteTooLong
    case receiptNotReady([ReceiptIssue.Kind])
    case currencyChangeAfterOpen
    case groupRequired
    case payerRequired
    case payerNotInGroup
    case participantNotInGroup(MemberID)
    case participantsRequired
    case notReadyToFinalize([ReadinessIssue])
    /// The shared room's final totals differ from this app's calculation; nothing was saved.
    case sharedTotalsDiffer
}
