import Foundation

/// Receipt drafts and Live Receipt Rooms (milestone 3 §8–§9). Same purity as the rest of the
/// engine: validate against the snapshot, return changes, or throw without side effects. Roles,
/// permissions, state transitions, and revisions are enforced here, not in the interface.
nonisolated extension LedgerEngine {
    static let maximumNoteLength = 140

    static func performReceipt(_ command: ReceiptRoomCommand, _ builder: inout Builder, _ makeID: () -> UUID) throws {
        let state = builder.state
        let actor = builder.actor
        let now = builder.now

        if case .createDraft(let id, let groupID, let pages, let currency) = command {
            guard state.room(id) == nil else { throw ReceiptRoomError.roomAlreadyExists }
            if let groupID { _ = try requireGroup(groupID, state) }
            var room = ReceiptRoom(id: id, groupID: groupID, hostID: actor,
                                   receipt: .empty(pages: pages, currency: currency, date: now), createdAt: now)
            record(.created(source: pages.first?.source), on: &room, builder, bumpRevision: false)
            commit(room, &builder)
            return
        }
        guard var room = state.room(command.roomID) else { throw ReceiptRoomError.roomNotFound }

        if case .adoptShared(_, let shared, let totals) = command {
            try adoptShared(&room, shared, finalTotals: totals, &builder, makeID)
            return
        }
        // Idempotent finalization: a repeat (double tap, retry) is a no-op returning the expense.
        if case .finalize = command, room.state == .finalized {
            builder.result.room = room
            builder.result.expenseID = room.finalExpenseID
            return
        }
        if let expected = command.expectedRevision, expected != room.revision {
            throw ReceiptRoomError.staleRevision(current: room.revision)
        }
        // Permissions and allowed states are declared per command (see `ReceiptRoomCommand.role`).
        let isHost = actor == room.hostID
        switch command.role {
        case .host: guard isHost else { throw ReceiptRoomError.hostOnly }
        case .participant: guard room.participantIDs.contains(actor) || isHost else { throw ReceiptRoomError.notAParticipant }
        }
        if let allowed = command.allowedStates {
            guard allowed.contains(room.state) else { throw ReceiptRoomError.notAllowedInState(room.state) }
        } else {
            try requireClaimingAllowed(room, isHost: isHost)
        }

        switch command {
        case .createDraft:
            return
        case .saveDraft(_, _, let receipt, let groupID, let payerID):
            try saveDraft(&room, receipt: receipt, groupID: groupID, payerID: payerID, builder)
        case .confirmReceipt:
            try confirm(&room, builder)
        case .reopenReview:
            transition(&room, to: .draft, builder)
        case .openRoom(_, _, let participants):
            try open(&room, participants: participants, &builder, makeID)
        case .setParticipants(_, _, let participants):
            try setParticipants(&room, participants, state: state, builder)
        case .claim(_, _, let itemID, let request):
            try claim(&room, itemID, request, builder)
        case .unclaim(_, _, let itemID):
            guard let previous = room.claim(on: itemID, by: actor) else { throw ReceiptRoomError.noClaimToRemove }
            room.claims.removeAll { $0.itemID == itemID && $0.memberID == actor }
            record(.unclaimed(itemID, previous: previous.mode), on: &room, builder)
        case .claimUnits(_, _, let itemID, let units):
            guard try claimUnits(&room, itemID, units, builder) else { return }
        case .setItemSplit(_, _, let itemID, let split):
            try setSplit(&room, itemID, split, isHost: isHost, builder)
        case .dispute(_, _, let target, let note):
            try dispute(&room, target, note: note, builder, makeID)
        case .resolveDispute(_, _, let disputeID, let status, let note):
            try resolveDispute(&room, disputeID, status, note: note, builder)
        case .setChargeAllocation(_, _, let chargeID, let allocation):
            try setChargeAllocation(&room, chargeID, allocation, builder)
        case .reviseReceipt(_, _, let receipt):
            try revise(&room, with: receipt, builder)
        case .markReviewed:
            markReviewed(&room, builder)
        case .setPayerAcceptsFullReceipt(_, _, let accepts):
            guard room.payerAcceptsFullReceipt != accepts else { return }
            room.payerAcceptsFullReceipt = accepts
            record(.payerAcceptanceChanged(accepts), on: &room, builder)
        case .transition(_, _, let move):
            try lifecycle(&room, move, state: state, builder)
        case .finalize:
            try finalize(&room, state: state, &builder, makeID)
        case .cancel:
            cancel(&room, &builder, makeID)
        case .discardDraft:
            builder.result.changes.append(.deleteRoom(room.id))
            builder.result.room = nil
            return
        case .markImagesRemoved:
            guard room.receipt.pages.contains(where: { !$0.isRemoved }) else { return }
            for index in room.receipt.pages.indices where room.receipt.pages[index].removedAt == nil {
                room.receipt.pages[index].removedAt = builder.now
            }
            record(.imagesRemoved, on: &room, builder)
        case .adoptShared:
            return
        }
        commit(room, &builder)
    }

    /// See `ReceiptRoomCommand.adoptShared`.
    private static func adoptShared(
        _ room: inout ReceiptRoom, _ shared: ReceiptRoom, finalTotals: [MemberID: Money]?, _ builder: inout Builder, _ makeID: () -> UUID
    ) throws {
        guard builder.actor == room.hostID, shared.hostID == room.hostID else { throw ReceiptRoomError.hostOnly }
        switch room.state {
        case .finalized:
            builder.result.room = room
            builder.result.expenseID = room.finalExpenseID
            return
        case .cancelled:
            builder.result.room = room
            return
        case .open, .resolving, .readyToFinalize:
            break
        case .draft, .ready:
            throw ReceiptRoomError.notAllowedInState(room.state)
        }
        room.receipt = shared.receipt
        room.payerID = shared.payerID
        room.participantIDs = shared.participantIDs
        room.claims = shared.claims
        room.disputes = shared.disputes
        room.reviews = shared.reviews
        room.needsReview = shared.needsReview
        room.payerAcceptsFullReceipt = shared.payerAcceptsFullReceipt
        record(.sharedRoomAdopted(serverRevision: shared.revision), on: &room, builder)
        switch shared.state {
        case .finalized:
            guard let finalTotals else { throw ReceiptRoomError.sharedTotalsDiffer }
            transition(&room, to: .readyToFinalize, builder)
            try finalize(&room, state: builder.state, &builder, makeID)
            let local = Dictionary((room.finalSnapshot?.participants ?? []).map { ($0.memberID, $0.total) }, uniquingKeysWith: +)
            let nonZero = { (totals: [MemberID: Money]) in totals.filter { !$0.value.isZero } }
            guard nonZero(local) == nonZero(finalTotals) else { throw ReceiptRoomError.sharedTotalsDiffer }
        case .cancelled:
            cancel(&room, &builder, makeID)
        case .open, .resolving, .readyToFinalize:
            transition(&room, to: shared.state, builder)
        case .draft, .ready:
            throw ReceiptRoomError.notAllowedInState(shared.state)
        }
        commit(room, &builder)
    }

    private static func open(_ room: inout ReceiptRoom, participants: [MemberID], _ builder: inout Builder, _ makeID: () -> UUID) throws {
        room.participantIDs = try validatedParticipants(participants, room: room, state: builder.state)
        room.openedAt = builder.now
        transition(&room, to: .open, builder)
        record(.opened(participants: room.participantIDs), on: &room, builder, bumpRevision: false)
        if let groupID = room.groupID {
            builder.event(groupID, .receiptRoomOpened(room.id, title: room.title, participantCount: room.participantIDs.count), makeID)
        }
    }

    private static func markReviewed(_ room: inout ReceiptRoom, _ builder: Builder) {
        record(.portionReviewed, on: &room, builder)
        room.reviews.removeAll { $0.memberID == builder.actor }
        room.reviews.append(ReviewMark(memberID: builder.actor, revision: room.revision))
        room.needsReview.removeAll { $0 == builder.actor }
    }

    private static func cancel(_ room: inout ReceiptRoom, _ builder: inout Builder, _ makeID: () -> UUID) {
        let wasOpened = room.openedAt != nil
        room.cancelledAt = builder.now
        transition(&room, to: .cancelled, builder)
        record(.cancelled, on: &room, builder, bumpRevision: false)
        if wasOpened, let groupID = room.groupID {
            builder.event(groupID, .receiptRoomCancelled(room.id, title: room.title), makeID)
        }
    }

    // MARK: - Bookkeeping

    private static func commit(_ room: ReceiptRoom, _ builder: inout Builder) {
        builder.result.changes.append(.upsertRoom(room))
        builder.result.room = room
    }

    /// Appends a room event; most accepted commands also advance the revision.
    private static func record(_ kind: ReceiptRoomEvent.Kind, on room: inout ReceiptRoom, _ builder: Builder, bumpRevision: Bool = true) {
        if bumpRevision { room.revision += 1 }
        room.history.append(ReceiptRoomEvent(
            sequence: (room.history.last?.sequence ?? 0) + 1, actorID: builder.actor, date: builder.now, revision: room.revision, kind: kind
        ))
    }

    private static func transition(_ room: inout ReceiptRoom, to newState: ReceiptRoomState, _ builder: Builder) {
        let old = room.state
        guard old != newState else { return }
        room.state = newState
        record(.stateChanged(from: old, to: newState), on: &room, builder)
    }

    private static func requireClaimingAllowed(_ room: ReceiptRoom, isHost: Bool) throws {
        switch room.state {
        case .open: return
        case .resolving where isHost: return
        default: throw ReceiptRoomError.notAllowedInState(room.state)
        }
    }

    private static func validatedNote(_ note: String?) throws -> String? {
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard trimmed.count <= maximumNoteLength else { throw ReceiptRoomError.noteTooLong }
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func validatedParticipants(_ ids: [MemberID], room: ReceiptRoom, state: LedgerSnapshot) throws -> [MemberID] {
        guard let groupID = room.groupID, let group = state.group(groupID) else { throw ReceiptRoomError.groupRequired }
        let unique = group.memberIDs.filter(ids.contains)
        guard !unique.isEmpty else { throw ReceiptRoomError.participantsRequired }
        if let outsider = ids.first(where: { !group.isActiveMember($0) }) { throw ReceiptRoomError.participantNotInGroup(outsider) }
        return unique
    }

    // MARK: - Draft and review

    private static func saveDraft(_ room: inout ReceiptRoom, receipt: ReceiptDraft, groupID: GroupID?, payerID: MemberID?, _ builder: Builder) throws {
        if let groupID {
            let group = try requireGroup(groupID, builder.state)
            if let payerID, !group.isActiveMember(payerID) { throw ReceiptRoomError.payerNotInGroup }
        }
        var incoming = receipt
        incoming.revision = room.receipt.revision
        incoming.updatedAt = room.receipt.updatedAt
        incoming.createdAt = room.receipt.createdAt
        let contentChanged = incoming != room.receipt
        guard contentChanged || groupID != room.groupID || payerID != room.payerID else { return }
        let finishedRecognition = receipt.recognition.status == .completed && room.receipt.recognition.status != .completed
        room.groupID = groupID
        room.payerID = payerID
        if contentChanged {
            incoming.revision = room.receipt.revision + 1
            incoming.updatedAt = builder.now
            room.receipt = incoming
        }
        if finishedRecognition {
            record(.recognitionFinished(receipt.recognition.provider, itemCount: receipt.items.count), on: &room, builder)
        } else {
            record(.receiptEdited(revision: room.receipt.revision), on: &room, builder)
        }
    }

    private static func confirm(_ room: inout ReceiptRoom, _ builder: Builder) throws {
        guard let groupID = room.groupID, let group = builder.state.group(groupID) else { throw ReceiptRoomError.groupRequired }
        guard let payerID = room.payerID else { throw ReceiptRoomError.payerRequired }
        guard group.isActiveMember(payerID) else { throw ReceiptRoomError.payerNotInGroup }
        let reconciliation = ReceiptValidator.reconcile(room.receipt, groupCurrency: group.currency)
        guard reconciliation.canConfirm, let total = reconciliation.printedTotal else {
            throw ReceiptRoomError.receiptNotReady(reconciliation.blockingIssues.map(\.kind))
        }
        room.confirmedAt = builder.now
        if room.participantIDs.isEmpty { room.participantIDs = group.activeMemberIDs }
        record(.receiptConfirmed(groupID: groupID, payerID: payerID, total: total), on: &room, builder)
        transition(&room, to: .ready, builder)
    }

    // MARK: - Participants and claims

    private static func setParticipants(_ room: inout ReceiptRoom, _ ids: [MemberID], state: LedgerSnapshot, _ builder: Builder) throws {
        // Removing someone no longer in the group must stay possible, so only additions are checked.
        guard let groupID = room.groupID, let group = state.group(groupID) else { throw ReceiptRoomError.groupRequired }
        let ordered = group.memberIDs.filter(ids.contains)
        guard !ordered.isEmpty else { throw ReceiptRoomError.participantsRequired }
        let added = ordered.filter { !room.participantIDs.contains($0) }
        if let outsider = added.first(where: { !group.isActiveMember($0) }) { throw ReceiptRoomError.participantNotInGroup(outsider) }
        let removed = room.participantIDs.filter { !ordered.contains($0) }
        guard !added.isEmpty || !removed.isEmpty else { return }
        let cleared = room.claims.filter { removed.contains($0.memberID) }
        room.claims.removeAll { removed.contains($0.memberID) }
        room.reviews.removeAll { removed.contains($0.memberID) }
        room.needsReview.removeAll { removed.contains($0) }
        room.participantIDs = ordered
        record(.participantsChanged(added: added, removed: removed, clearedClaims: cleared), on: &room, builder)
        if room.state == .readyToFinalize { transition(&room, to: .resolving, builder) }
    }

    private static func claimableItem(_ itemID: ReceiptItemID, in room: ReceiptRoom) throws -> ReceiptLineItem {
        guard let item = room.receipt.item(itemID) else { throw ReceiptRoomError.itemNotFound }
        guard item.isChargeable else { throw ReceiptRoomError.itemNotClaimable }
        return item
    }

    private static func claim(_ room: inout ReceiptRoom, _ itemID: ReceiptItemID, _ request: ClaimRequest, _ builder: Builder) throws {
        _ = try claimableItem(itemID, in: room)
        let actor = builder.actor
        guard room.participantIDs.contains(actor) else { throw ReceiptRoomError.notAParticipant }
        let existing = room.claims(for: itemID)
        guard room.claim(on: itemID, by: actor) == nil else { return } // already claimed: idempotent
        let others = existing.filter { $0.memberID != actor }
        let now = builder.now
        func newClaim(_ mode: ClaimMode) -> ReceiptClaim {
            ReceiptClaim(itemID: itemID, memberID: actor, mode: mode, createdAt: now, updatedAt: now, revision: room.revision + 1)
        }
        switch request {
        case .mine:
            if let holder = others.first { throw ReceiptRoomError.itemAlreadyClaimed(by: holder.memberID) }
            room.claims.append(newClaim(.full))
            record(.claimed(itemID, .full), on: &room, builder)
        case .share:
            if others.contains(where: { if case .exact = $0.mode { true } else { false } }) { throw ReceiptRoomError.itemHasCustomSplit }
            if others.contains(where: \.mode.isUnits) { throw ReceiptRoomError.itemHasCustomSplit }
            let usesWeights = others.contains { if case .shares = $0.mode { true } else { false } }
            for index in room.claims.indices where room.claims[index].itemID == itemID && room.claims[index].mode == .full {
                room.claims[index].mode = .equalShare
                room.claims[index].updatedAt = now
            }
            let mode: ClaimMode = usesWeights ? .shares(1) : (others.isEmpty ? .full : .equalShare)
            room.claims.append(newClaim(mode))
            record(.claimed(itemID, mode), on: &room, builder)
        }
    }

    /// "I had 2 of the 3" (server: `_claim_units`). Returns false for a repeat that changes nothing.
    private static func claimUnits(_ room: inout ReceiptRoom, _ itemID: ReceiptItemID, _ units: Int, _ builder: Builder) throws -> Bool {
        let item = try claimableItem(itemID, in: room)
        guard let quantity = item.quantity, quantity >= 1 else { throw ReceiptRoomError.itemQuantityUnknown }
        let actor = builder.actor
        guard room.participantIDs.contains(actor) else { throw ReceiptRoomError.notAParticipant }
        let mine = room.claim(on: itemID, by: actor)
        let others = room.claims(for: itemID).filter { $0.memberID != actor }
        let now = builder.now
        guard units > 0 else {
            guard let mine else { return false }
            room.claims.removeAll { $0.itemID == itemID && $0.memberID == actor }
            record(.unclaimed(itemID, previous: mine.mode), on: &room, builder)
            return true
        }
        if let holder = others.first(where: { $0.mode == .full }) { throw ReceiptRoomError.itemAlreadyClaimed(by: holder.memberID) }
        guard others.allSatisfy(\.mode.isUnits) else { throw ReceiptRoomError.itemHasCustomSplit }
        let taken = others.reduce(0) { total, claim in if case .units(let count) = claim.mode { total + count } else { total } }
        let available = quantity - taken
        guard units <= available else { throw ReceiptRoomError.unitsUnavailable(available: max(available, 0)) }
        if mine?.mode == .units(units) { return false }
        room.claims.removeAll { $0.itemID == itemID && $0.memberID == actor }
        room.claims.append(ReceiptClaim(itemID: itemID, memberID: actor, mode: .units(units), createdAt: mine?.createdAt ?? now, updatedAt: now,
                                        revision: room.revision + 1))
        record(.claimed(itemID, .units(units)), on: &room, builder)
        return true
    }

    private static func setSplit(_ room: inout ReceiptRoom, _ itemID: ReceiptItemID, _ split: ItemSplit, isHost: Bool, _ builder: Builder) throws {
        let item = try claimableItem(itemID, in: room)
        let previous = room.claims(for: itemID)
        let members = split.memberIDs
        if let outsider = members.first(where: { !room.participantIDs.contains($0) }) { throw ReceiptRoomError.participantNotInGroup(outsider) }
        if !isHost {
            let allowed = Set(previous.map(\.memberID) + [builder.actor])
            guard members.allSatisfy(allowed.contains), members.contains(builder.actor) || previous.contains(where: { $0.memberID == builder.actor }) else {
                throw ReceiptRoomError.cannotIncludeOthers
            }
        }
        let isClearing = members.isEmpty
        if isClearing {
            guard isHost else { throw ReceiptRoomError.invalidSplit(.noOne) }
        } else if case .failure(let issue) = ReceiptAllocationEngine.preview(split, of: item) {
            throw ReceiptRoomError.invalidSplit(issue)
        }
        let claims = isClearing ? [] : ReceiptAllocationEngine.claims(for: split, itemID: itemID, at: builder.now, revision: room.revision + 1, existing: previous)
        if !isHost {
            // Re-dividing never drops someone else's claim: only they (by unclaiming) or the host can.
            let kept = Set(claims.map(\.memberID))
            if previous.contains(where: { $0.memberID != builder.actor && !kept.contains($0.memberID) }) { throw ReceiptRoomError.cannotRemoveOthers }
        }
        func key(_ list: [ReceiptClaim]) -> [String] { list.map { "\($0.memberID)|\($0.mode)" }.sorted() }
        guard key(claims) != key(previous) else { return }
        room.claims.removeAll { $0.itemID == itemID }
        room.claims += claims
        let assignsOthers = isHost && !(members == [builder.actor])
        record(assignsOthers ? .itemAssigned(itemID, previous: previous, split: split) : .itemSplitSet(itemID, previous: previous, split: split),
               on: &room, builder)
    }

    // MARK: - Disputes and charges

    private static func dispute(_ room: inout ReceiptRoom, _ target: DisputeTarget, note: String?, _ builder: Builder, _ makeID: () -> UUID) throws {
        switch target {
        case .item(let id): guard room.receipt.item(id) != nil else { throw ReceiptRoomError.itemNotFound }
        case .charge(let id): guard room.receipt.charge(id) != nil else { throw ReceiptRoomError.chargeNotFound }
        }
        let note = try validatedNote(note)
        if room.disputes.contains(where: { $0.target == target && $0.raisedBy == builder.actor && $0.isOpen }) { return }
        let dispute = ReceiptDispute(id: ReceiptDisputeID(makeID()), target: target, raisedBy: builder.actor, note: note,
                                     createdAt: builder.now, status: .open)
        room.disputes.append(dispute)
        record(.disputed(dispute.id, target), on: &room, builder)
        if room.state == .readyToFinalize { transition(&room, to: .resolving, builder) }
    }

    private static func resolveDispute(
        _ room: inout ReceiptRoom, _ id: ReceiptDisputeID, _ status: DisputeStatus, note: String?, _ builder: Builder
    ) throws {
        guard let index = room.disputes.firstIndex(where: { $0.id == id }) else { throw ReceiptRoomError.disputeNotFound }
        guard room.disputes[index].isOpen else { throw ReceiptRoomError.disputeAlreadyResolved }
        guard status != .open else { throw ReceiptRoomError.disputeAlreadyResolved }
        let note = try validatedNote(note)
        if status == .dismissed, note == nil { throw ReceiptRoomError.noteRequired }
        room.disputes[index].status = status
        room.disputes[index].resolvedBy = builder.actor
        room.disputes[index].resolvedAt = builder.now
        room.disputes[index].resolutionNote = note
        record(.disputeResolved(id, status), on: &room, builder)
    }

    private static func setChargeAllocation(_ room: inout ReceiptRoom, _ id: ReceiptChargeID, _ allocation: ChargeAllocation, _ builder: Builder) throws {
        guard let index = room.receipt.charges.firstIndex(where: { $0.id == id }) else { throw ReceiptRoomError.chargeNotFound }
        let previous = room.receipt.charges[index].allocation
        guard previous != allocation else { return }
        var candidate = room
        candidate.receipt.charges[index].allocation = allocation
        let preview = ReceiptAllocationEngine.allocate(candidate).charge(id)
        switch preview?.status {
        case .allocated, .noBasis, nil: break // proportional may lack a basis until items are claimed
        case .some(let status): throw ReceiptRoomError.invalidChargeAllocation(status)
        }
        room.receipt.charges[index].allocation = allocation
        record(.chargeAllocationChanged(id, from: previous, to: allocation), on: &room, builder)
        if room.state == .readyToFinalize { transition(&room, to: .resolving, builder) }
    }

    /// A host edit after claims began (§8.11): only items whose amount changed or that were
    /// removed lose their claims; the previous values and claims are kept in history.
    private static func revise(_ room: inout ReceiptRoom, with receipt: ReceiptDraft, _ builder: Builder) throws {
        guard receipt.currencyCode == room.receipt.currencyCode else { throw ReceiptRoomError.currencyChangeAfterOpen }
        let change = ReceiptRevisionImpact.change(from: room.receipt, to: receipt)
        var incoming = receipt
        incoming.revision = room.receipt.revision
        incoming.updatedAt = room.receipt.updatedAt
        guard incoming != room.receipt else { return }
        let affected = Set(change.financialItemIDs + change.removedItemIDs)
        let cleared = room.claims.filter { affected.contains($0.itemID) }
        let previousItems = room.receipt.items.filter { affected.contains($0.id) }
        room.claims.removeAll { affected.contains($0.itemID) }
        for index in room.disputes.indices where room.disputes[index].isOpen {
            if case .item(let itemID) = room.disputes[index].target, change.removedItemIDs.contains(itemID) {
                room.disputes[index].status = .resolved
                room.disputes[index].resolvedBy = builder.actor
                room.disputes[index].resolvedAt = builder.now
                room.disputes[index].resolutionNote = String(localized: "Item removed from the receipt")
            }
        }
        let needingReview = Set(cleared.map(\.memberID))
        room.needsReview = room.participantIDs.filter { needingReview.contains($0) || room.needsReview.contains($0) }
        incoming.revision = room.receipt.revision + 1
        incoming.updatedAt = builder.now
        room.receipt = incoming
        record(.receiptRevised(change, clearedClaims: cleared, previousItems: previousItems), on: &room, builder)
        if room.state == .readyToFinalize, !change.nonFinancialOnly { transition(&room, to: .resolving, builder) }
    }

    // MARK: - Lifecycle and finalization

    private static func lifecycle(_ room: inout ReceiptRoom, _ move: ReceiptRoomTransition, state: LedgerSnapshot, _ builder: Builder) throws {
        switch move {
        case .beginResolving:
            guard room.state == .open else { throw ReceiptRoomError.notAllowedInState(room.state) }
            transition(&room, to: .resolving, builder)
        case .reopenClaims:
            guard room.state == .resolving else { throw ReceiptRoomError.notAllowedInState(room.state) }
            transition(&room, to: .open, builder)
        case .requestFinalReview:
            guard room.state == .open || room.state == .resolving else { throw ReceiptRoomError.notAllowedInState(room.state) }
            let issues = ReceiptRoomReadiness.issues(for: room, in: state)
            guard issues.isEmpty else { throw ReceiptRoomError.notReadyToFinalize(issues) }
            transition(&room, to: .readyToFinalize, builder)
        case .returnToRoom:
            guard room.state == .readyToFinalize else { throw ReceiptRoomError.notAllowedInState(room.state) }
            transition(&room, to: .resolving, builder)
        }
    }

    private static func finalize(_ room: inout ReceiptRoom, state: LedgerSnapshot, _ builder: inout Builder, _ makeID: () -> UUID) throws {
        let allocation = ReceiptAllocationEngine.allocate(room)
        let group = room.groupID.flatMap(state.group)
        let issues = ReceiptRoomReadiness.issues(for: room, allocation: allocation, group: group)
        guard issues.isEmpty, let group, let payerID = room.payerID, let total = room.receipt.total.value else {
            throw ReceiptRoomError.notReadyToFinalize(issues)
        }
        let receipt = room.receipt
        let expenseID = ExpenseID(room.id.rawValue)
        let snapshot = ReceiptAllocationSnapshot(
            merchant: receipt.title, date: receipt.date.value, total: total,
            items: receipt.items.map { item in
                ReceiptAllocationSnapshot.Item(id: item.id, name: item.name.value, quantity: item.quantity, lineTotal: item.amount,
                                               isRefund: item.isRefund, shares: allocation.item(item.id)?.shares ?? [])
            },
            charges: receipt.charges.map { charge in
                ReceiptAllocationSnapshot.Charge(id: charge.id, kind: charge.kind, label: charge.label, amount: charge.value,
                                                 allocation: charge.allocation, shares: allocation.charge(charge.id)?.shares ?? [])
            },
            participants: allocation.participants, payments: [Share(payerID, total)], rounding: allocation.rounding,
            roomRevision: room.revision + 1, finalizedAt: builder.now, finalizedBy: builder.actor
        )
        let expense = Expense(
            id: expenseID, groupID: group.id, title: receipt.title, merchant: receipt.title, date: receipt.date.value, total: total,
            category: CategoryGuesser.guess(receipt.title) == .other ? .food : CategoryGuesser.guess(receipt.title),
            splitMethod: .itemized, payments: [Share(payerID, total)],
            allocations: allocation.participants.filter { !$0.total.isZero }.map { Share($0.memberID, $0.total) },
            createdBy: builder.actor, createdAt: builder.now
        )
        // The same validation and pending-payment rules as any manually entered expense.
        try addExpense(expense, &builder, makeID)
        room.finalExpenseID = expenseID
        room.finalSnapshot = snapshot
        room.finalizedAt = builder.now
        transition(&room, to: .finalized, builder)
        record(.finalized(expenseID), on: &room, builder, bumpRevision: false)
        builder.event(group.id, .receiptRoomFinalized(room.id, expenseID: expenseID, title: room.title), makeID)
        builder.result.expenseID = expenseID
    }
}

nonisolated extension ReceiptRoomCommand {
    nonisolated enum Role: Sendable {
        /// Only the host (the person who captured the receipt), whoever is "previewing".
        case host
        /// Anyone in the room, and the host.
        case participant
    }

    var role: Role {
        switch self {
        case .claim, .unclaim, .claimUnits, .setItemSplit, .dispute, .markReviewed: .participant
        default: .host
        }
    }

    /// States in which the command is accepted. `nil` = claiming rules: `open`, or `resolving` for the host.
    var allowedStates: [ReceiptRoomState]? {
        switch self {
        case .createDraft, .transition: ReceiptRoomState.allCases
        case .saveDraft, .confirmReceipt: [.draft]
        case .reopenReview, .openRoom: [.ready]
        case .claim, .unclaim, .claimUnits, .setItemSplit: nil
        case .setParticipants, .dispute, .resolveDispute, .setChargeAllocation, .reviseReceipt, .markReviewed, .setPayerAcceptsFullReceipt:
            [.open, .resolving, .readyToFinalize]
        case .finalize: [.readyToFinalize]
        case .cancel: [.draft, .ready, .open, .resolving, .readyToFinalize]
        case .discardDraft: [.draft, .ready]
        case .markImagesRemoved: [.finalized, .cancelled]
        case .adoptShared: ReceiptRoomState.allCases
        }
    }

    /// The revision a command was based on; `nil` for creation and maintenance commands.
    var expectedRevision: Int? {
        switch self {
        case .createDraft, .discardDraft, .markImagesRemoved, .adoptShared: nil
        case .saveDraft(_, let revision, _, _, _), .confirmReceipt(_, let revision), .reopenReview(_, let revision),
             .openRoom(_, let revision, _), .setParticipants(_, let revision, _), .claim(_, let revision, _, _),
             .unclaim(_, let revision, _), .claimUnits(_, let revision, _, _), .setItemSplit(_, let revision, _, _), .dispute(_, let revision, _, _),
             .resolveDispute(_, let revision, _, _, _), .setChargeAllocation(_, let revision, _, _), .reviseReceipt(_, let revision, _),
             .markReviewed(_, let revision), .setPayerAcceptsFullReceipt(_, let revision, _), .transition(_, let revision, _),
             .finalize(_, let revision, _), .cancel(_, let revision):
            revision
        }
    }
}
