import Foundation

/// What a host's receipt edit does to existing claims (milestone 3 §8.11), computed before the
/// edit is saved so the confirmation can explain it.
nonisolated enum ReceiptRevisionImpact {
    static func change(from old: ReceiptDraft, to new: ReceiptDraft) -> ReceiptRevisionChange {
        var change = ReceiptRevisionChange()
        let newItems = Dictionary(uniqueKeysWithValues: new.items.map { ($0.id, $0) })
        let oldIDs = Set(old.items.map(\.id))
        for item in old.items {
            guard let updated = newItems[item.id] else {
                change.removedItemIDs.append(item.id)
                continue
            }
            if updated.amount != item.amount || updated.isRefund != item.isRefund {
                change.financialItemIDs.append(item.id)
            }
        }
        change.addedItemIDs = new.items.map(\.id).filter { !oldIDs.contains($0) }
        let oldCharges = Dictionary(uniqueKeysWithValues: old.charges.map { ($0.id, $0) })
        let newChargeIDs = Set(new.charges.map(\.id))
        for charge in new.charges {
            if let previous = oldCharges[charge.id] {
                if previous.value != charge.value || previous.kind != charge.kind { change.changedChargeIDs.append(charge.id) }
            } else {
                change.changedChargeIDs.append(charge.id)
            }
        }
        change.changedChargeIDs += old.charges.map(\.id).filter { !newChargeIDs.contains($0) }
        change.totalChanged = old.total.value != new.total.value
        return change
    }

    /// Claims the edit would clear, and the people who will be asked to review again.
    static func clearedClaims(in room: ReceiptRoom, for change: ReceiptRevisionChange) -> [ReceiptClaim] {
        let affected = Set(change.financialItemIDs + change.removedItemIDs)
        return room.claims.filter { affected.contains($0.itemID) }
    }
}
