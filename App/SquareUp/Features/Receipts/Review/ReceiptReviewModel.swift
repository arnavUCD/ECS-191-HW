import Foundation
import Observation

/// Strict parsing of amounts typed during review: never rounds what the person typed.
nonisolated enum ReceiptAmountInput {
    static func parse(_ text: String, currency: CurrencyCode, allowsNegative: Bool, locale: Locale = .autoupdatingCurrent) -> Money? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var negative = false
        if let first = trimmed.first, first == "-" || first == "\u{2212}" {
            guard allowsNegative else { return nil }
            negative = true
            trimmed.removeFirst()
        }
        trimmed = trimmed.filter { !$0.isWhitespace && !"$€£¥₹".contains($0) }
        guard !trimmed.isEmpty, let value = try? Decimal(trimmed, format: Decimal.FormatStyle(locale: locale)), value >= 0 else { return nil }
        let money = Money(value, currency)
        guard money.amount == value else { return nil } // more decimals than the currency allows
        return negative ? -money : money
    }

    static func text(_ money: Money?, locale: Locale = .autoupdatingCurrent) -> String {
        guard let money else { return "" }
        let digits = money.currency.minorUnitDigits
        let formatted = money.magnitude.amount.formatted(.number.locale(locale).precision(.fractionLength(digits)).grouping(.never))
        return money.isNegative ? "-" + formatted : formatted
    }
}

/// Editing state for receipt review (milestone 3 §5.4). Recognition only proposed these values;
/// every one is editable here, edits are attributed, and the original proposal is kept.
@Observable
final class ReceiptReviewModel {
    enum Focus: Hashable {
        case merchant
        case date
        case total
        case subtotal
        case item(ReceiptItemID)
        case charge(ReceiptChargeID)
    }

    private(set) var draft: ReceiptDraft
    private(set) var groupID: GroupID?
    private(set) var payerID: MemberID?
    var focus: Focus?
    var selectedPageID: ReceiptAssetID?
    /// Increments on every edit; the view autosaves after a pause.
    private(set) var editCount = 0
    let snapshot: LedgerSnapshot
    let editorID: MemberID
    let now: Date

    init(room: ReceiptRoom, snapshot: LedgerSnapshot, now: Date) {
        draft = room.receipt
        groupID = room.groupID
        payerID = room.payerID ?? room.groupID.map { _ in snapshot.currentUserID }
        self.snapshot = snapshot
        editorID = snapshot.currentUserID
        self.now = now
        selectedPageID = room.receipt.activePages.first?.id
    }

    // MARK: Derived

    var group: ExpenseGroup? { groupID.flatMap(snapshot.group) }
    var currency: CurrencyCode { draft.currencyCode }
    /// Review is about the receipt itself. Who it's split with — a group, or people right now — is
    /// the next step, so no group (or its currency) is needed to continue.
    var reconciliation: ReceiptReconciliation { ReceiptValidator.reconcile(draft) }

    /// Personal groups the person can split with.
    var groups: [ExpenseGroup] { snapshot.groupsForCurrentUser }
    var payerCandidates: [Member] { group.map { snapshot.activeMembers(of: $0) } ?? [] }

    var canContinue: Bool { reconciliation.canConfirm }

    /// Why "Continue" is disabled, in order of importance.
    var blockers: [String] {
        reconciliation.blockingIssues.map { ReceiptLanguage.issue($0.kind, in: draft) }
    }

    var selectedPage: ReceiptAsset? {
        draft.activePages.first { $0.id == selectedPageID } ?? draft.activePages.first
    }

    func sources(for focus: Focus?) -> [ReceiptRegionID] {
        switch focus {
        case .merchant: draft.merchant.sourceRegionIDs
        case .date: draft.date.sourceRegionIDs
        case .total: draft.total.sourceRegionIDs
        case .subtotal: draft.subtotal.sourceRegionIDs
        case .item(let id): draft.item(id)?.sourceRegionIDs ?? []
        case .charge(let id): draft.charge(id)?.amount.sourceRegionIDs ?? []
        case nil: []
        }
    }

    /// Evidence rectangles on a page for the focused value.
    func highlights(on page: ReceiptAsset) -> [ReceiptRect] {
        sources(for: focus).compactMap { draft.region($0) }.filter { $0.pageID == page.id }.map(\.bounds)
    }

    /// Selects a value and turns to the page holding its evidence.
    func show(_ focus: Focus) {
        self.focus = focus
        if let region = sources(for: focus).compactMap({ draft.region($0) }).first {
            selectedPageID = region.pageID
        }
    }

    // MARK: Header fields

    func setGroup(_ id: GroupID?) {
        groupID = id
        if let payerID, let group, !group.isActiveMember(payerID) { self.payerID = nil }
        if payerID == nil, group?.isActiveMember(editorID) == true { payerID = editorID }
        changed()
    }

    func setPayer(_ id: MemberID?) {
        payerID = id
        changed()
    }

    func setMerchant(_ name: String) {
        draft.merchant.edit(String(name.prefix(80)), by: editorID, at: now)
        changed()
    }

    func setDate(_ date: Date) {
        draft.date.edit(date, by: editorID, at: now)
        changed()
    }

    func setTotal(_ total: Money?) {
        draft.total.edit(total, by: editorID, at: now)
        changed()
    }

    func setSubtotal(_ subtotal: Money?) {
        draft.subtotal.edit(subtotal, by: editorID, at: now)
        changed()
    }

    /// Changes the currency label without changing any digits. Only currencies with the same
    /// number of minor-unit digits are offered, so no amount is ever rounded.
    func setCurrency(_ code: CurrencyCode) {
        guard code.minorUnitDigits == currency.minorUnitDigits, code != currency else {
            if code == currency { draft.currency.edit(code, by: editorID, at: now) }
            changed()
            return
        }
        func retag(_ money: Money) -> Money { Money(minorUnits: money.minorUnits, currency: code) }
        draft.currency.edit(code, by: editorID, at: now)
        for index in draft.items.indices {
            draft.items[index].lineTotal.value = retag(draft.items[index].lineTotal.value)
            draft.items[index].unitPrice = draft.items[index].unitPrice.map(retag)
        }
        for index in draft.charges.indices {
            draft.charges[index].amount.value = retag(draft.charges[index].amount.value)
        }
        draft.total.value = draft.total.value.map(retag)
        draft.subtotal.value = draft.subtotal.value.map(retag)
        changed()
    }

    var currencyChoices: [CurrencyCode] {
        let common = [CurrencyCode.usd, .eur, .gbp, CurrencyCode("CAD"), CurrencyCode("AUD"), .inr, CurrencyCode("MXN"), .jpy]
        return common.filter { $0.minorUnitDigits == currency.minorUnitDigits }
    }

    // MARK: Items

    func updateItem(_ id: ReceiptItemID, name: String, quantity: Int?, unitPrice: Money?, lineTotal: Money, isRefund: Bool) {
        guard let index = draft.items.firstIndex(where: { $0.id == id }) else { return }
        var item = draft.items[index]
        if item.name.value != name || item.name.isEdited == false { item.name.edit(String(name.prefix(120)), by: editorID, at: now) }
        if item.lineTotal.value != lineTotal || !item.lineTotal.isEdited { item.lineTotal.edit(lineTotal, by: editorID, at: now) }
        item.quantity = quantity
        item.unitPrice = unitPrice
        item.isRefund = isRefund
        draft.items[index] = item
        changed()
    }

    @discardableResult
    func addItem() -> ReceiptItemID {
        let item = ReceiptLineItem(name: .entered("", by: editorID, at: now), lineTotal: .entered(.zero(currency), by: editorID, at: now))
        draft.items.append(item)
        changed()
        return item.id
    }

    func deleteItem(_ id: ReceiptItemID) {
        draft.items.removeAll { $0.id == id }
        if focus == .item(id) { focus = nil }
        changed()
    }

    /// Joins an item with the next one (a line the recognizer split in two).
    func mergeWithNext(_ id: ReceiptItemID) {
        guard let index = draft.items.firstIndex(where: { $0.id == id }), index + 1 < draft.items.count else { return }
        var first = draft.items[index]
        let second = draft.items[index + 1]
        let name = [first.name.value, second.name.value].filter { !$0.isEmpty }.joined(separator: " ")
        first.name.edit(name, by: editorID, at: now)
        first.name.sourceRegionIDs += second.name.sourceRegionIDs
        first.lineTotal.edit(first.amount + second.amount, by: editorID, at: now)
        first.lineTotal.sourceRegionIDs += second.lineTotal.sourceRegionIDs
        first.quantity = nil
        first.unitPrice = nil
        first.isRefund = (first.amount + second.amount).isNegative
        draft.items[index] = first
        draft.items.remove(at: index + 1)
        changed()
    }

    /// Splits a wrongly combined line: the first part keeps `firstAmount`, the rest becomes a new line.
    func split(_ id: ReceiptItemID, firstAmount: Money) {
        guard let index = draft.items.firstIndex(where: { $0.id == id }) else { return }
        var first = draft.items[index]
        let remainder = first.amount - firstAmount
        guard !firstAmount.isZero, !remainder.isZero else { return }
        var second = ReceiptLineItem(name: .entered(first.name.value, by: editorID, at: now), lineTotal: .entered(remainder, by: editorID, at: now),
                                     isRefund: remainder.isNegative)
        second.name.sourceRegionIDs = first.name.sourceRegionIDs
        first.lineTotal.edit(firstAmount, by: editorID, at: now)
        first.quantity = nil
        first.unitPrice = nil
        draft.items[index] = first
        draft.items.insert(second, at: index + 1)
        changed()
    }

    /// Accessible alternative to drag reordering.
    func moveItem(_ id: ReceiptItemID, by offset: Int) {
        guard let index = draft.items.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard draft.items.indices.contains(target) else { return }
        draft.items.swapAt(index, target)
        changed()
    }

    func canMove(_ id: ReceiptItemID, by offset: Int) -> Bool {
        guard let index = draft.items.firstIndex(where: { $0.id == id }) else { return false }
        return draft.items.indices.contains(index + offset)
    }

    // MARK: Charges

    @discardableResult
    func addCharge(_ kind: ReceiptChargeKind, amount: Money? = nil, label: String? = nil) -> ReceiptChargeID {
        let charge = ReceiptCharge(kind: kind, label: label ?? (kind == .adjustment ? "" : ReceiptLanguage.name(kind)),
                                   amount: .entered(amount ?? .zero(currency), by: editorID, at: now))
        draft.charges.append(charge)
        changed()
        return charge.id
    }

    func updateCharge(_ id: ReceiptChargeID, kind: ReceiptChargeKind, label: String, amount: Money) {
        guard let index = draft.charges.firstIndex(where: { $0.id == id }) else { return }
        draft.charges[index].kind = kind
        draft.charges[index].label = String(label.prefix(60))
        if draft.charges[index].amount.value != amount || !draft.charges[index].amount.isEdited {
            draft.charges[index].amount.edit(amount, by: editorID, at: now)
        }
        changed()
    }

    func deleteCharge(_ id: ReceiptChargeID) {
        draft.charges.removeAll { $0.id == id }
        if focus == .charge(id) { focus = nil }
        changed()
    }

    // MARK: Pages

    func replacePage(_ page: ReceiptAsset) {
        guard let index = draft.pages.firstIndex(where: { $0.id == page.id }) else { return }
        draft.pages[index] = page
        changed()
    }

    func addPages(_ pages: [ReceiptAsset]) {
        draft.pages += pages
        selectedPageID = pages.first?.id ?? selectedPageID
        changed()
    }

    /// Replaces a page with a new capture. Evidence from the old page no longer applies.
    func swapPage(_ old: ReceiptAsset, with new: ReceiptAsset) {
        guard let index = draft.pages.firstIndex(where: { $0.id == old.id }) else { return }
        draft.pages[index] = new
        draft.regions.removeAll { $0.pageID == old.id }
        selectedPageID = new.id
        changed()
    }

    func removePage(_ page: ReceiptAsset) {
        draft.pages.removeAll { $0.id == page.id }
        draft.regions.removeAll { $0.pageID == page.id }
        if selectedPageID == page.id { selectedPageID = draft.activePages.first?.id }
        changed()
    }

    func movePage(_ page: ReceiptAsset, by offset: Int) {
        guard let index = draft.pages.firstIndex(where: { $0.id == page.id }), draft.pages.indices.contains(index + offset) else { return }
        draft.pages.swapAt(index, index + offset)
        changed()
    }

    // MARK: Saving

    private func changed() {
        editCount += 1
    }

    func saveCommand(for room: ReceiptRoom) -> ReceiptRoomCommand {
        .saveDraft(room.id, expectedRevision: room.revision, receipt: draft, groupID: groupID, payerID: payerID)
    }
}
