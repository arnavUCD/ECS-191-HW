import SwiftUI

/// "Add to a group": the reviewed receipt becomes one itemized expense in the chosen group right
/// away, with every item assigned on the same screen as the people who were there. Nobody else has
/// to act and no room opens for anyone (that's "Split with people now").
///
/// Each item is split equally among the people who had it, and tax, tip, and discounts in proportion
/// to what each person had. Leftover cents go to whoever has the least so far (`balanced`), so an
/// even split comes out even. Those exact amounts then run through the receipt room's own lifecycle
/// — people, item splits, final review, finalize — in one go on the group's ledger, which checks
/// they add up. A group on this iPhone records the expense locally; a shared group receives only
/// the finished itemized expense with its frozen allocation, under the receipt's ID, so a retry can
/// never add it twice.
@MainActor
enum ReceiptGroupAddition {
    /// Who was there, who paid, and who had each item (an item's people split it equally).
    nonisolated struct Plan: Equatable, Sendable {
        var participants: [MemberID]
        var payer: MemberID
        var items: [ReceiptItemID: [MemberID]]
    }

    /// The items people can be assigned (notes without an amount aren't).
    static func assignableItems(of room: ReceiptRoom) -> [ReceiptLineItem] {
        room.receipt.items.filter { !$0.isNote }
    }

    /// Exact shares for each assigned item and — once every item is assigned — each charge.
    nonisolated struct Allocation: Equatable, Sendable {
        var items: [ReceiptItemID: [Share]] = [:]
        var charges: [ReceiptChargeID: [Share]] = [:]
    }

    /// What the screen shows: each person's share so far, and what isn't assigned yet.
    nonisolated struct Breakdown: Equatable, Sendable {
        var totals: [MemberID: Money]
        /// Items nobody has yet.
        var unassigned: Money
        /// Tax, tip, and discounts together; added to the shares once every item is assigned.
        var charges: Money
        var isComplete: Bool
    }

    static func breakdown(_ room: ReceiptRoom, plan: Plan) -> Breakdown {
        let currency = room.receipt.currencyCode
        let allocation = balanced(room, plan: plan)
        var totals: [MemberID: Money] = [:]
        for share in (allocation.items.values.flatMap { $0 } + allocation.charges.values.flatMap { $0 }) {
            totals[share.memberID, default: .zero(currency)] += share.amount
        }
        let unassigned = assignableItems(of: room).filter { (plan.items[$0.id] ?? []).isEmpty }.map(\.lineTotal.value).sum(in: currency)
        return Breakdown(totals: totals, unassigned: unassigned, charges: room.receipt.charges.map(\.amount.value).sum(in: currency),
                         isComplete: allocation.charges.count == room.receipt.charges.count && unassigned.isZero)
    }

    /// Items split equally among their people; charges, once every item has someone, in proportion
    /// to each person's items. Everyone's final total is worked out first — their exact share of the
    /// whole receipt, rounded so the totals add up — and every line is then fitted to it: an item's
    /// leftover cents go to whoever has the least so far, and the last charge absorbs what's left of
    /// each person's total. So nobody is ever more than a cent from their exact share, and an even
    /// split comes out even.
    static func balanced(_ room: ReceiptRoom, plan: Plan) -> Allocation {
        let currency = room.receipt.currencyCode
        let order = plan.participants
        var running = Dictionary(uniqueKeysWithValues: order.map { ($0, Int64(0)) })
        var result = Allocation()

        /// Divides `amount` among `people`: equally, or by `weights`; leftover cents by `priority`
        /// (higher first; ties by the group's order).
        func divide(_ amount: Int64, among people: [MemberID], weights: [MemberID: Double]?, priority: (MemberID) -> Double) -> [Share] {
            guard !people.isEmpty else { return [] }
            let magnitude = abs(amount)
            let sign: Int64 = amount < 0 ? -1 : 1
            var parts: [MemberID: Int64] = [:]
            let total = weights.map { weights in people.map { max(weights[$0] ?? 0, 0) }.reduce(0, +) } ?? 0
            for person in people {
                parts[person] = total > 0 ? Int64((Double(magnitude) * max(weights?[person] ?? 0, 0) / total).rounded(.down))
                    : magnitude / Int64(people.count)
            }
            var leftover = magnitude - parts.values.reduce(0, +)
            let ranked = people.enumerated().sorted { lhs, rhs in
                let a = priority(lhs.element), b = priority(rhs.element)
                return a != b ? a > b : lhs.offset < rhs.offset
            }.map(\.element)
            var index = 0
            while leftover > 0 {
                parts[ranked[index % ranked.count], default: 0] += 1
                leftover -= 1
                index += 1
            }
            return people.compactMap { person in
                let units = (parts[person] ?? 0) * sign
                running[person, default: 0] += units
                return units == 0 ? nil : Share(person, Money(minorUnits: units, currency: currency))
            }
        }

        // Items: equal among their people; a leftover cent to whoever has the least (or, on a refund, the most).
        let items = assignableItems(of: room)
        var exactItems: [MemberID: Double] = [:]
        for item in items {
            guard let chosen = plan.items[item.id], !chosen.isEmpty else { continue }
            let people = order.filter(chosen.contains)
            let amount = item.lineTotal.value.minorUnits
            for person in people { exactItems[person, default: 0] += Double(amount) / Double(people.count) }
            result.items[item.id] = divide(amount, among: people, weights: nil) { person in
                let have = Double(running[person] ?? 0)
                return amount < 0 ? have : -have
            }
        }
        let charges = room.receipt.charges
        guard !charges.isEmpty, items.allSatisfy({ !(plan.items[$0.id] ?? []).isEmpty }) else { return result }

        // Each person's final total: their exact share of the whole receipt, rounded to add up.
        let itemsTotal = items.map(\.lineTotal.value.minorUnits).reduce(0, +)
        let chargesTotal = charges.map(\.amount.value.minorUnits).reduce(0, +)
        let receiptTotal = itemsTotal + chargesTotal
        let withItems = order.filter { (exactItems[$0] ?? 0) != 0 }
        guard itemsTotal > 0, !withItems.isEmpty else { return result }
        let exactTotals = Dictionary(uniqueKeysWithValues: withItems.map { ($0, (exactItems[$0] ?? 0) * Double(receiptTotal) / Double(itemsTotal)) })
        var targets = exactTotals.mapValues { Int64($0.rounded(.down)) }
        var short = receiptTotal - targets.values.reduce(0, +)
        for person in withItems.enumerated().sorted(by: { lhs, rhs in
            let a = exactTotals[lhs.element]! - Double(targets[lhs.element]!), b = exactTotals[rhs.element]! - Double(targets[rhs.element]!)
            return a != b ? a > b : lhs.offset < rhs.offset
        }).map(\.element) where short > 0 {
            targets[person, default: 0] += 1
            short -= 1
        }
        // What each person's charges must come to; every charge but the largest is divided in
        // proportion, its leftover cents to whoever still needs the most; the largest takes the rest.
        var need = Dictionary(uniqueKeysWithValues: withItems.map { ($0, (targets[$0] ?? 0) - (running[$0] ?? 0)) })
        let absorber = charges.max { abs($0.amount.value.minorUnits) < abs($1.amount.value.minorUnits) }!
        for charge in charges where charge.id != absorber.id {
            let amount = charge.amount.value.minorUnits
            let shares = divide(amount, among: withItems, weights: exactItems) { person in
                let remaining = Double(need[person] ?? 0)
                return amount < 0 ? -remaining : remaining
            }
            for share in shares { need[share.memberID, default: 0] -= share.amount.minorUnits }
            result.charges[charge.id] = shares
        }
        let last = withItems.compactMap { person -> Share? in
            let units = need[person] ?? 0
            return units == 0 ? nil : Share(person, Money(minorUnits: units, currency: currency))
        }
        let absorberAmount = absorber.amount.value.minorUnits
        if last.allSatisfy({ ($0.amount.minorUnits < 0) == (absorberAmount < 0) }),
           last.map(\.amount.minorUnits).reduce(0, +) == absorberAmount {
            result.charges[absorber.id] = last
        } else {
            // Shouldn't happen with real receipts; fall back to dividing it in proportion too.
            result.charges[absorber.id] = divide(absorberAmount, among: withItems, weights: exactItems) { -Double(running[$0] ?? 0) }
        }
        return result
    }

    /// Adds `room` (a reviewed draft held by `source`) to `groupID` on `target`, the group's ledger.
    /// Resumes from wherever an interrupted attempt stopped. Returns the expense's ID.
    static func add(_ room: ReceiptRoom, from source: any LedgerStore, to target: any LedgerStore, groupID: GroupID,
                    plan: Plan) async throws -> ExpenseID {
        let sameLedger = (source as AnyObject) === (target as AnyObject)
        var current = try await target.snapshot().room(room.id)
        if current == nil {
            // A shared group's receipts are kept by its own ledger: move the draft there first.
            let created = try await target.run(.createDraft(room.id, groupID: groupID, pages: room.receipt.pages, currency: room.receipt.currencyCode))
            if let made = created.room { current = made } else { current = try await target.room(room.id) }
        }
        guard var working = current else { throw LedgerError.receipt(.roomNotFound) }
        let host = working.hostID

        func step(_ command: ReceiptRoomCommand) async throws {
            let result = try await target.run(command, as: host)
            if let room = result.room { working = room } else { working = try await target.room(working.id) }
        }

        if working.state == .draft {
            try await step(.saveDraft(working.id, expectedRevision: working.revision, receipt: room.receipt, groupID: groupID, payerID: plan.payer))
            try await step(.confirmReceipt(working.id, expectedRevision: working.revision))
        }
        if working.state == .ready {
            try await step(.openRoom(working.id, expectedRevision: working.revision, participants: plan.participants))
        }
        if working.state == .open || working.state == .resolving {
            let allocation = balanced(working, plan: plan)
            for item in assignableItems(of: working) {
                guard let shares = allocation.items[item.id], !shares.isEmpty else { continue }
                try await step(.setItemSplit(working.id, expectedRevision: working.revision, item: item.id, .exact(shares)))
            }
            for charge in working.receipt.charges {
                guard let shares = allocation.charges[charge.id], !shares.isEmpty else { continue }
                try await step(.setChargeAllocation(working.id, expectedRevision: working.revision, charge.id, .exact(shares)))
            }
            try await step(.transition(working.id, expectedRevision: working.revision, .requestFinalReview))
        }
        if working.state == .readyToFinalize {
            // The person adding it assigned everyone's items here; nobody else is asked to review.
            let others = working.participantIDs.filter { $0 != host }
            try await step(.finalize(working.id, expectedRevision: working.revision, acknowledging: others))
        }
        guard working.state == .finalized, let expenseID = working.finalExpenseID else { throw LedgerError.receipt(.notAllowedInState(working.state)) }
        if !sameLedger, let draft = try? await source.snapshot().room(room.id), draft.state == .draft || draft.state == .ready {
            // The draft moved into the group; this iPhone's copy is no longer needed.
            _ = try? await source.run(.discardDraft(room.id))
        }
        return expenseID
    }
}

/// "Who had what?" on the people screen: each item with the people who were there; tap someone to
/// put them on it (an item shared by several people is split equally). Each person's share, with
/// tax and tip, updates as you go.
struct ItemAssignmentPanel: View {
    let room: ReceiptRoom
    let people: [Member]
    let viewer: MemberID?
    @Binding var assignments: [ReceiptItemID: [MemberID]]
    let breakdown: ReceiptGroupAddition.Breakdown

    private var items: [ReceiptLineItem] { ReceiptGroupAddition.assignableItems(of: room) }
    private var assignedCount: Int { items.filter { !(assignments[$0.id] ?? []).isEmpty }.count }

    var body: some View {
        SUPanelSection(
            title: String(localized: "Who had what?"),
            subtitle: assignedCount == items.count ? String(localized: "Every item is assigned.")
                : Inflect.string("^[\(items.count - assignedCount) item](inflect: true) still to assign. Tap the people who had each one.")
        ) {
            VStack(alignment: .leading, spacing: SUSpacing.md) {
                Button {
                    for item in items { assignments[item.id] = people.map(\.id) }
                } label: {
                    Label(String(localized: "Split everything equally"), systemImage: "equal.circle")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.suSecondary)
                .disabled(people.isEmpty)
                .accessibilityIdentifier("addToGroup.splitAllEqually")
                ForEach(items) { item in
                    itemRow(item)
                    if item.id != items.last?.id { Divider().overlay(SUColor.hairline) }
                }
            }
        }
        if !room.receipt.charges.isEmpty {
            Label(breakdown.isComplete ? String(localized: "Tax, tip, and discounts are shared in proportion to what each person had.")
                : String(localized: "Tax, tip, and discounts (\(MoneyFormatting.string(breakdown.charges))) are added in proportion once every item is assigned."),
                  systemImage: "percent")
                .font(SUFont.metadata).foregroundStyle(SUColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        SUPanelSection(title: breakdown.isComplete ? String(localized: "Each person's share") : String(localized: "Each person's items so far")) {
            VStack(spacing: 0) {
                ForEach(people) { member in
                    HStack(spacing: SUSpacing.sm) {
                        SUAvatar(member: member, size: .small, isCurrentUser: member.id == viewer)
                        Text(member.id == viewer ? String(localized: "\(member.displayName) (you)") : member.displayName)
                            .font(SUFont.body).foregroundStyle(SUColor.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: SUSpacing.xs)
                        SUAmountView(money: breakdown.totals[member.id] ?? .zero(room.receipt.currencyCode), style: .row)
                    }
                    .frame(minHeight: 44)
                    .accessibilityElement(children: .combine)
                }
                if !breakdown.unassigned.isZero {
                    HStack {
                        Text(String(localized: "Items not assigned yet")).font(SUFont.supporting).foregroundStyle(SUColor.textSecondary)
                        Spacer(minLength: SUSpacing.xs)
                        SUAmountView(money: breakdown.unassigned, direction: .muted, style: .row)
                    }
                    .frame(minHeight: 44)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func itemRow(_ item: ReceiptLineItem) -> some View {
        let chosen = assignments[item.id] ?? []
        return VStack(alignment: .leading, spacing: SUSpacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: SUSpacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name.value.isEmpty ? String(localized: "Item") : item.name.value)
                        .font(SUFont.body.weight(.semibold)).foregroundStyle(SUColor.textPrimary)
                    if let quantity = item.quantity, quantity > 1 {
                        Text(String(localized: "\(quantity) on the receipt")).font(SUFont.metadata).foregroundStyle(SUColor.textSecondary)
                    }
                }
                Spacer(minLength: SUSpacing.xs)
                SUAmountView(money: item.lineTotal.value, style: .row)
            }
            FlowingPeople(people: people, chosen: chosen, viewer: viewer) { member in
                var next = chosen
                if let index = next.firstIndex(of: member.id) { next.remove(at: index) } else { next.append(member.id) }
                // Keep the group's order, so equal splits always round the same way.
                assignments[item.id] = people.map(\.id).filter(next.contains)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("addToGroup.item.\(item.name.value)")
    }
}

/// The people on an item as toggles that wrap onto more lines when there are many.
private struct FlowingPeople: View {
    let people: [Member]
    let chosen: [MemberID]
    let viewer: MemberID?
    let toggle: (Member) -> Void

    var body: some View {
        WrapLayout(spacing: SUSpacing.xs) {
            ForEach(people) { member in
                let isOn = chosen.contains(member.id)
                Button { toggle(member) } label: {
                    HStack(spacing: SUSpacing.xxs) {
                        Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isOn ? SUColor.accent : SUColor.textTertiary)
                        Text(member.id == viewer ? String(localized: "You") : member.firstName)
                            .foregroundStyle(SUColor.textPrimary)
                    }
                    .font(SUFont.supporting.weight(.semibold))
                    .padding(.horizontal, SUSpacing.xs + 2)
                    .frame(minHeight: 36)
                    .background(isOn ? SUColor.glassFillElevated : SUColor.glassFill, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(member.id == viewer ? String(localized: "You") : member.displayName)
                .accessibilityValue(isOn ? String(localized: "Had this") : String(localized: "Didn't have this"))
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
    }
}

/// Lays its children out left to right, starting a new line when the next one doesn't fit.
private struct WrapLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews, in: width)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        let widest = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? widest, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, in: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, in width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width, !row.indices.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
