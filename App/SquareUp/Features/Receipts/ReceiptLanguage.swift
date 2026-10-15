import Foundation

/// Plain-language text for receipts and rooms. Pure, so wording is unit-tested.
nonisolated enum ReceiptLanguage {
    typealias Names = [MemberID: String]

    static func names(_ members: [MemberID: Member]) -> Names {
        PersonIdentity.shortLabels(for: Array(members.values))
    }

    // MARK: - Attention

    static func label(_ attention: ReceiptAttention) -> String {
        switch attention {
        case .looksGood: String(localized: "Looks good")
        case .check: String(localized: "Check this")
        case .needsResolution: String(localized: "Needs resolution")
        }
    }

    static func symbol(_ attention: ReceiptAttention) -> String {
        switch attention {
        case .looksGood: "checkmark.circle"
        case .check: "eye.circle"
        case .needsResolution: "exclamationmark.triangle.fill"
        }
    }

    static func reason(_ reason: AttentionReason) -> String {
        switch reason {
        case .strongEvidence: String(localized: "Read clearly from the receipt.")
        case .lowConfidence: String(localized: "The text was hard to read.")
        case .notFound: String(localized: "Not found on the receipt.")
        case .multipleCandidates: String(localized: "More than one possible value was found.")
        case .ambiguousFormat: String(localized: "This could be read more than one way.")
        case .quantityMismatch: String(localized: "Quantity × price doesn't match the line total.")
        case .possibleDuplicate: String(localized: "Looks like the line above. Remove it if it's a duplicate.")
        case .invalidValue: String(localized: "This value isn't valid.")
        case .mathConflict: String(localized: "Doesn't match the other amounts.")
        case .defaultValue: String(localized: "Not printed; using the group's default.")
        case .confirmedByPerson: String(localized: "Confirmed by you.")
        case .enteredByPerson: String(localized: "Entered by you.")
        case .derived: String(localized: "Worked out from the other amounts, not printed. Check it against the receipt.")
        case .evidenceMismatch: String(localized: "Read differently in different places. Check it against the receipt.")
        case .noEvidence: String(localized: "Couldn't find where this appears on the receipt.")
        }
    }

    /// One calm line when AI processing was intended but the on-device parser prepared the receipt.
    static let preparedOnDevice = String(localized: "AI processing wasn't available. We prepared this receipt on your device.")

    /// Why the receipt was read on this iPhone instead of with AI, in the person's terms.
    static func preparedOnDevice(_ fallback: ReceiptIntelligenceFallback?) -> String {
        fallback == .demoLimitReached
            ? String(localized: "The demo's AI receipt reading is used up for today, so this receipt was read on your iPhone. Check the values against the receipt.")
            : preparedOnDevice
    }

    // MARK: - Charges

    static func name(_ kind: ReceiptChargeKind) -> String {
        switch kind {
        case .tax: String(localized: "Tax")
        case .tip: String(localized: "Tip")
        case .serviceCharge: String(localized: "Service charge")
        case .fee: String(localized: "Fee")
        case .discount: String(localized: "Discount")
        case .adjustment: String(localized: "Adjustment")
        }
    }

    static func symbol(_ kind: ReceiptChargeKind) -> String {
        switch kind {
        case .tax: "building.columns"
        case .tip: "heart"
        case .serviceCharge: "bell"
        case .fee: "tag"
        case .discount: "percent"
        case .adjustment: "plusminus"
        }
    }

    static func name(_ kind: ChargeAllocation.Kind) -> String {
        switch kind {
        case .proportional: String(localized: "By what each person ordered")
        case .equal: String(localized: "Equally")
        case .shares: String(localized: "By shares")
        case .exact: String(localized: "Exact amounts")
        case .payer: String(localized: "Payer covers it")
        }
    }

    static func explanation(_ kind: ChargeAllocation.Kind) -> String {
        switch kind {
        case .proportional: String(localized: "Each person pays in proportion to their items. Usual for tax.")
        case .equal: String(localized: "Divided evenly among the people you choose.")
        case .shares: String(localized: "Weighted, e.g. 2 shares for one person and 1 for another.")
        case .exact: String(localized: "Type each person's amount. It must add up exactly.")
        case .payer: String(localized: "The payer keeps the whole charge.")
        }
    }

    // MARK: - States

    static func label(_ state: ReceiptRoomState) -> String {
        switch state {
        case .draft: String(localized: "Reviewing receipt")
        case .ready: String(localized: "Ready to open")
        case .open: String(localized: "Open for claims")
        case .resolving: String(localized: "Host is resolving")
        case .readyToFinalize: String(localized: "Final review")
        case .finalized: String(localized: "Saved as expense")
        case .cancelled: String(localized: "Closed")
        }
    }

    static func symbol(_ state: ReceiptRoomState) -> String {
        switch state {
        case .draft: "doc.text.magnifyingglass"
        case .ready: "door.left.hand.closed"
        case .open: "hand.raised"
        case .resolving: "wrench.and.screwdriver"
        case .readyToFinalize: "checklist"
        case .finalized: "checkmark.seal.fill"
        case .cancelled: "xmark.circle"
        }
    }

    // MARK: - Statements

    /// "The receipt total is $84.37. 8 items and 3 additional charges account for the full amount." (§5.5)
    static func reviewStatement(_ reconciliation: ReceiptReconciliation, locale: Locale = .autoupdatingCurrent) -> String {
        guard let total = reconciliation.printedTotal else { return String(localized: "Enter the receipt total to check the math.") }
        let totalText = MoneyFormatting.string(total, locale: locale)
        let items = Inflect.string("^[\(reconciliation.itemCount) item](inflect: true)")
        let charges = Inflect.string("^[\(reconciliation.chargeCount) additional charge](inflect: true)")
        if let difference = reconciliation.difference, !difference.isZero {
            let gap = MoneyFormatting.string(difference.magnitude, locale: locale)
            return difference.isPositive
                ? String(localized: "The receipt total is \(totalText), but the lines add up to \(gap) less.")
                : String(localized: "The receipt total is \(totalText), but the lines add up to \(gap) more.")
        }
        if reconciliation.chargeCount == 0 {
            return String(localized: "The receipt total is \(totalText). \(items) account for the full amount.")
        }
        return String(localized: "The receipt total is \(totalText). \(items) and \(charges) account for the full amount.")
    }

    /// "The $84.37 receipt is fully assigned. Alex paid, Maya owes $26.42, … and Alex's own share is $26.85." (§9.2)
    static func finalStatement(
        room: ReceiptRoom, allocation: ReceiptAllocation, names: Names, currentUserID: MemberID, locale: Locale = .autoupdatingCurrent
    ) -> String {
        guard let total = allocation.receiptTotal, let payerID = room.payerID else { return "" }
        let money = { (value: Money) in MoneyFormatting.string(value, locale: locale) }
        func name(_ id: MemberID) -> String { id == currentUserID ? String(localized: "you") : names[id] ?? String(localized: "Someone") }
        let payer = payerID == currentUserID ? String(localized: "You") : names[payerID] ?? String(localized: "Someone")
        var parts = [String(localized: "\(payer) paid")]
        for participant in allocation.participants where participant.memberID != payerID && !participant.total.isZero {
            parts.append(participant.memberID == currentUserID
                ? String(localized: "you owe \(money(participant.total))")
                : String(localized: "\(name(participant.memberID)) owes \(money(participant.total))"))
        }
        let own = allocation.participant(payerID).total
        parts.append(payerID == currentUserID
            ? String(localized: "your own share is \(money(own))")
            : String(localized: "\(names[payerID] ?? "")'s own share is \(money(own))"))
        return String(localized: "The \(money(total)) receipt is fully assigned. \(parts.formatted(.list(type: .and))).")
    }

    /// "Maya pays 1¢ more on Shared nachos because $12.00 doesn't divide evenly."
    static func rounding(_ note: RoundingNote, receipt: ReceiptDraft, names: Names, locale: Locale = .autoupdatingCurrent) -> String {
        let person = names[note.memberID] ?? String(localized: "Someone")
        let cents = MoneyFormatting.string(note.amount.magnitude, locale: locale)
        let source: String
        switch note.source {
        case .item(let id): source = receipt.item(id)?.name.value ?? String(localized: "an item")
        case .charge(let id): source = receipt.charge(id)?.label ?? String(localized: "a charge")
        }
        return note.amount.isPositive
            ? String(localized: "\(person) pays \(cents) more on \(source) so it divides exactly.")
            : String(localized: "\(person) pays \(cents) less on \(source) so it divides exactly.")
    }

    // MARK: - Issues

    static func issue(_ kind: ReceiptIssue.Kind, in draft: ReceiptDraft, locale: Locale = .autoupdatingCurrent) -> String {
        let money = { (value: Money) in MoneyFormatting.string(value, locale: locale) }
        func item(_ id: ReceiptItemID) -> String { draft.item(id).map { $0.name.value.isEmpty ? String(localized: "An item") : $0.name.value } ?? String(localized: "An item") }
        func charge(_ id: ReceiptChargeID) -> String { draft.charge(id)?.label ?? String(localized: "A charge") }
        switch kind {
        case .merchantMissing: return String(localized: "Add the merchant's name.")
        case .totalMissing: return String(localized: "Enter the receipt total.")
        case .totalNotPositive: return String(localized: "The total must be more than zero.")
        case .noItems: return String(localized: "Add at least one item with a price.")
        case .itemNameBlank: return String(localized: "Every item needs a name.")
        case .itemQuantityInvalid(let id): return String(localized: "\(item(id)): quantity must be at least 1.")
        case .negativeItemNotMarkedRefund(let id): return String(localized: "\(item(id)) is negative. Mark it as a refund or correct the amount.")
        case .refundNotNegative(let id): return String(localized: "\(item(id)) is marked as a refund but isn't negative.")
        case .chargeSignInvalid(let id): return String(localized: "\(charge(id)) has the wrong sign. Discounts subtract; other charges add.")
        case .chargeZero(let id): return String(localized: "\(charge(id)) is zero. Enter the amount or remove it.")
        case .adjustmentLabelMissing: return String(localized: "Explain the adjustment, e.g. \u{201C}Printed rounding\u{201D}.")
        case .itemNeedsResolution(let id): return String(localized: "\(item(id)) needs a correct amount. Check it against the receipt.")
        case .chargeNeedsResolution(let id): return String(localized: "\(charge(id)) needs a correct amount. Check it against the receipt.")
        case .totalNeedsConfirmation: return String(localized: "Confirm the total printed on the receipt.")
        case .mixedCurrencies: return String(localized: "This receipt shows more than one currency. Choose the one it was paid in.")
        case .currencyDiffersFromGroup(let receipt, let group):
            return String(localized: "This receipt is in \(receipt.rawValue), but the group uses \(group.rawValue). Square Up doesn't convert currencies.")
        case .totalMismatch(let difference):
            return difference.isPositive
                ? String(localized: "The lines are \(money(difference)) less than the total. Fix a line or add a labelled adjustment.")
                : String(localized: "The lines are \(money(difference.magnitude)) more than the total. Fix a line or add a labelled adjustment.")
        case .subtotalMismatch(let printed, let items):
            return String(localized: "Items add up to \(money(items)); the printed subtotal is \(money(printed)).")
        case .quantityTimesPriceMismatch(let id): return String(localized: "\(item(id)): quantity × price doesn't match the line total.")
        case .possibleDuplicate(let id): return String(localized: "\(item(id)) appears twice in a row. Remove one if it's a duplicate.")
        case .fieldsToCheck(let count): return Inflect.string("^[\(count) value](inflect: true) to check against the receipt.")
        }
    }

    static func readiness(_ issue: ReadinessIssue, room: ReceiptRoom, names: Names, locale: Locale = .autoupdatingCurrent) -> String {
        let money = { (value: Money) in MoneyFormatting.string(value, locale: locale) }
        func item(_ id: ReceiptItemID) -> String { room.receipt.item(id)?.name.value ?? String(localized: "An item") }
        func charge(_ id: ReceiptChargeID) -> String { room.receipt.charge(id)?.label ?? String(localized: "A charge") }
        func person(_ id: MemberID) -> String { names[id] ?? String(localized: "Someone") }
        switch issue {
        case .receipt(let kind): return Self.issue(kind, in: room.receipt, locale: locale)
        case .unclaimedItem(let id): return String(localized: "\(item(id)) isn't claimed yet.")
        case .partiallyAssignedItem(let id, let remaining): return String(localized: "\(item(id)) has \(money(remaining.magnitude)) unassigned.")
        case .invalidItemSplit(let id, let reason):
            switch reason {
            case .mixedModes: return String(localized: "\(item(id)) mixes exact amounts with shares. Set one split.")
            case .exceeds(let excess): return String(localized: "\(item(id)) is over-assigned by \(money(excess)).")
            case .zeroWeights: return String(localized: "\(item(id)) has no shares assigned.")
            case .notAParticipant(let member): return String(localized: "\(item(id)) is claimed by \(person(member)), who isn't in the room.")
            case .wrongSign: return String(localized: "\(item(id)) has an amount with the wrong sign.")
            case .noQuantity: return String(localized: "\(item(id)) is claimed by quantity but doesn't list one. Set one split.")
            case .unitsExceed(let excess): return Inflect.string("\(item(id)) has ^[\(excess) more](inflect: true) claimed than it lists.")
            }
        case .unallocatedCharge(let id, let status):
            switch status {
            case .noBasis: return String(localized: "\(charge(id)) is divided by items, but nobody has claimed any yet.")
            case .exactMismatch(let remaining): return String(localized: "\(charge(id)) is off by \(money(remaining.magnitude)).")
            case .noRecipients: return String(localized: "Choose who shares \(charge(id)).")
            case .payerMissing: return String(localized: "Choose who paid before assigning \(charge(id)) to the payer.")
            case .notAParticipant(let member): return String(localized: "\(charge(id)) includes \(person(member)), who isn't in the room.")
            case .allocated: return ""
            }
        case .openDispute(let id):
            guard let dispute = room.disputes.first(where: { $0.id == id }) else { return String(localized: "A dispute is open.") }
            let target: String
            switch dispute.target {
            case .item(let itemID): target = item(itemID)
            case .charge(let chargeID): target = charge(chargeID)
            }
            return String(localized: "\(person(dispute.raisedBy)) disputed \(target).")
        case .totalsDoNotMatch(let remaining): return String(localized: "Participant totals are \(money(remaining.magnitude)) away from the receipt total.")
        case .groupMissing: return String(localized: "Choose a group.")
        case .payerMissing: return String(localized: "Choose who paid.")
        case .payerNotInGroup(let id): return String(localized: "\(person(id)) paid but is no longer in the group.")
        case .participantNotInGroup(let id): return String(localized: "\(person(id)) left the group. Remove them from the room.")
        case .negativeParticipantTotal(let id, let total):
            return String(localized: "\(person(id))'s credits exceed their items by \(money(total.magnitude)). Change how a discount or refund is divided.")
        case .onlyPayerOwes: return String(localized: "Everything is assigned to the payer. Confirm that's intended to save it.")
        }
    }

    static func error(_ error: ReceiptRoomError, names: Names, locale: Locale = .autoupdatingCurrent) -> String {
        func person(_ id: MemberID) -> String { names[id] ?? String(localized: "Someone") }
        switch error {
        case .roomNotFound: return String(localized: "This receipt is no longer available.")
        case .roomAlreadyExists: return String(localized: "This receipt was already started.")
        case .staleRevision: return String(localized: "The room changed while you were looking. Review the latest and try again.")
        case .notAllowedInState(let state): return String(localized: "That isn't possible while the room is \u{201C}\(label(state))\u{201D}.")
        case .hostOnly: return String(localized: "Only the host can do that.")
        case .notAParticipant: return String(localized: "Only people in this room can do that.")
        case .itemNotFound: return String(localized: "That item is no longer on the receipt.")
        case .itemNotClaimable: return String(localized: "Zero-value lines are notes and can't be claimed.")
        case .chargeNotFound: return String(localized: "That charge is no longer on the receipt.")
        case .disputeNotFound: return String(localized: "That dispute is no longer open.")
        case .itemAlreadyClaimed(let holder): return String(localized: "\(person(holder)) already claimed this. Share it or dispute it instead.")
        case .itemHasCustomSplit: return String(localized: "This item has exact amounts. Use \u{201C}Custom split\u{201D} to change it.")
        case .noClaimToRemove: return String(localized: "You haven't claimed this item.")
        case .cannotIncludeOthers: return String(localized: "You can divide an item only among people who claimed it. Ask others to tap Share.")
        case .cannotRemoveOthers: return String(localized: "You can't remove someone else's claim. Ask them, or the host.")
        case .unitsUnavailable(let available):
            return available == 0 ? String(localized: "Everyone else already claimed all of this line.")
                : Inflect.string("Only ^[\(available) is](inflect: true) left on this line.")
        case .itemQuantityUnknown: return String(localized: "This item doesn't list a quantity. Claim it or share it instead.")
        case .unreviewedShares(let people):
            return String(localized: "\(people.map(person).formatted(.list(type: .and))) haven't reviewed their share yet.")
        case .roomExpired: return String(localized: "This room expired. Nothing more can change.")
        case .roomClosed: return String(localized: "This room has ended.")
        case .invalidSplit(let issue):
            switch issue {
            case .noOne: return String(localized: "Choose at least one person.")
            case .negativeValue: return String(localized: "Amounts can't have the opposite sign of the item.")
            case .doesNotAddUp(let remaining):
                let gap = MoneyFormatting.string(remaining.magnitude, locale: locale)
                return remaining.isPositive ? String(localized: "\(gap) still to assign.") : String(localized: "\(gap) too much assigned.")
            case .noQuantity: return String(localized: "This item doesn't list a quantity to divide by.")
            case .tooManyUnits(let excess): return Inflect.string("^[\(excess) more](inflect: true) than the receipt lists.")
            }
        case .invalidChargeAllocation: return String(localized: "That split doesn't add up to the charge.")
        case .disputeAlreadyResolved: return String(localized: "This dispute was already resolved.")
        case .noteRequired: return String(localized: "Add a short note explaining why no change is needed.")
        case .noteTooLong: return String(localized: "Keep the note under 140 characters.")
        case .receiptNotReady: return String(localized: "Finish reviewing the receipt first.")
        case .currencyChangeAfterOpen: return String(localized: "The currency can't change after the room opens.")
        case .groupRequired: return String(localized: "Choose a group.")
        case .payerRequired: return String(localized: "Choose who paid.")
        case .payerNotInGroup: return String(localized: "The payer must be in the group.")
        case .participantNotInGroup(let id): return String(localized: "\(person(id)) isn't an active member of this group.")
        case .participantsRequired: return String(localized: "Choose at least one person.")
        case .notReadyToFinalize: return String(localized: "Some items or charges still need attention.")
        case .sharedTotalsDiffer:
            return String(localized: "The shared room's totals don't match this iPhone's. Nothing was saved — update Square Up and try again.")
        }
    }

    // MARK: - History

    /// One room event in words, naming the actual (possibly simulated) actor.
    static func history(_ event: ReceiptRoomEvent, room: ReceiptRoom, names: Names, locale: Locale = .autoupdatingCurrent) -> String {
        let actor = names[event.actorID] ?? String(localized: "Someone")
        func item(_ id: ReceiptItemID) -> String {
            room.receipt.item(id)?.name.value ?? room.finalSnapshot?.items.first { $0.id == id }?.name ?? String(localized: "an item")
        }
        func people(_ ids: [MemberID]) -> String { ids.map { names[$0] ?? "" }.formatted(.list(type: .and)) }
        switch event.kind {
        case .created(let source):
            return source == .camera ? String(localized: "\(actor) scanned the receipt") : String(localized: "\(actor) added the receipt")
        case .recognitionFinished(let provider, let count):
            return provider == .fixture
                ? Inflect.string("Sample recognition proposed ^[\(count) item](inflect: true)")
                : Inflect.string("Read on device: ^[\(count) item](inflect: true) proposed")
        case .receiptEdited(let revision): return String(localized: "\(actor) edited the receipt (version \(revision))")
        case .receiptConfirmed(_, let payerID, let total):
            return String(localized: "\(actor) confirmed the receipt: \(MoneyFormatting.string(total, locale: locale)), paid by \(names[payerID] ?? "")")
        case .opened(let participants): return String(localized: "\(actor) opened the room for \(people(participants))")
        case .participantsChanged(let added, let removed, _):
            if !removed.isEmpty, added.isEmpty { return String(localized: "\(actor) removed \(people(removed)) from the room") }
            if removed.isEmpty { return String(localized: "\(actor) added \(people(added)) to the room") }
            return String(localized: "\(actor) added \(people(added)) and removed \(people(removed))")
        case .claimed(let id, let mode):
            if case .full = mode { return String(localized: "\(actor) claimed \(item(id))") }
            if case .units(let count) = mode { return String(localized: "\(actor) claimed \(count) of \(item(id))") }
            return String(localized: "\(actor) shared \(item(id))")
        case .unclaimed(let id, _): return String(localized: "\(actor) unclaimed \(item(id))")
        case .itemSplitSet(let id, _, let split), .itemAssigned(let id, _, let split):
            if split.memberIDs.isEmpty { return String(localized: "\(actor) cleared the claims on \(item(id))") }
            return String(localized: "\(actor) split \(item(id)) among \(people(split.memberIDs))")
        case .disputed(_, let target):
            switch target {
            case .item(let id): return String(localized: "\(actor) disputed \(item(id))")
            case .charge(let id): return String(localized: "\(actor) disputed \(room.receipt.charge(id)?.label ?? String(localized: "a charge"))")
            }
        case .disputeResolved(_, let status):
            return status == .dismissed ? String(localized: "\(actor) dismissed a dispute with a note") : String(localized: "\(actor) resolved a dispute")
        case .chargeAllocationChanged(let id, _, let to):
            return String(localized: "\(actor) set \(room.receipt.charge(id)?.label ?? "") to \(name(to.kind).lowercased())")
        case .receiptRevised(_, let cleared, _):
            return cleared.isEmpty ? String(localized: "\(actor) edited the receipt")
                : Inflect.string("\(actor) edited the receipt and cleared ^[\(cleared.count) claim](inflect: true)")
        case .portionReviewed: return String(localized: "\(actor) reviewed their portion")
        case .payerAcceptanceChanged(let accepts):
            return accepts ? String(localized: "\(actor) confirmed the payer keeps the whole receipt") : String(localized: "\(actor) changed the payer confirmation")
        case .stateChanged(_, let to): return String(localized: "Room: \(label(to))")
        case .finalized: return String(localized: "\(actor) saved it as an itemized expense")
        case .cancelled: return String(localized: "\(actor) closed the room")
        case .imagesRemoved: return String(localized: "\(actor) removed the receipt images")
        case .sharedRoomAdopted: return String(localized: "Saved the shared room's final state on this iPhone")
        }
    }
}
