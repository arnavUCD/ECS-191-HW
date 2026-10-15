import SwiftUI

/// "How many did you have?" — claims part of a line's printed quantity ("2 of the 3 beers")
/// without changing anyone else's claim. What's left stays unclaimed for others, never added to
/// anyone silently. The estimate updates as the count changes.
struct UnitsClaimSheet: View {
    let flow: ReceiptFlowModel
    let summary: ReceiptRoomSummary
    let itemID: ReceiptItemID
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var units = 1
    @State private var loaded = false
    @State private var isSaving = false

    private var item: ReceiptLineItem? { summary.room.receipt.item(itemID) }
    private var quantity: Int { item?.quantity ?? 1 }
    private var others: [(MemberID, Int)] {
        summary.room.claims(for: itemID).filter { $0.memberID != summary.actorID }.compactMap { claim in
            if case .units(let count) = claim.mode { return (claim.memberID, count) }
            return nil
        }
    }

    private var available: Int { max(quantity - others.map(\.1).reduce(0, +), 0) }
    private var mine: Int? {
        if case .units(let count)? = summary.room.claim(on: itemID, by: summary.actorID)?.mode { count } else { nil }
    }

    /// Your share at this count, with the others' claims as they are.
    private var estimate: Money? {
        guard let item, units > 0 else { return nil }
        let counts = summary.room.participantIDs.compactMap { id -> (MemberID, Int)? in
            if id == summary.actorID { return (id, units) }
            return others.first { $0.0 == id }
        }
        return ReceiptAllocationEngine.divideUnits(item, counts: counts, quantity: quantity).0.first { $0.memberID == summary.actorID }?.amount
    }

    var body: some View {
        NavigationStack {
            Form {
                if let item {
                    Section {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name.value).font(SUFont.body.weight(.semibold))
                                Text(String(localized: "\(quantity) on the receipt")).font(SUFont.metadata).foregroundStyle(SUColor.textSecondary)
                            }
                            Spacer()
                            Text(MoneyFormatting.string(item.amount, locale: locale)).font(SUFont.rowAmount)
                        }
                    }
                    .suListRows()
                    Section(String(localized: "How many did you have?")) {
                        Stepper(value: $units, in: 0...max(available, 0)) {
                            Text(String(localized: "\(units) of \(quantity)")).font(SUFont.sectionTitle.monospacedDigit())
                        }
                        .accessibilityLabel(String(localized: "How many you had"))
                        .accessibilityValue(String(localized: "\(units) of \(quantity)"))
                        .accessibilityIdentifier("units.stepper")
                        if let estimate {
                            LabeledContent(String(localized: "Your part")) {
                                Text(MoneyFormatting.string(estimate, locale: locale)).font(SUFont.body.monospacedDigit())
                            }
                            .accessibilityIdentifier("units.estimate")
                        }
                        let left = available - units
                        Text(left > 0 ? Inflect.string("^[\(left) more](inflect: true) left for others to claim.")
                            : String(localized: "That's everything still unclaimed on this line."))
                            .font(SUFont.metadata).foregroundStyle(SUColor.textSecondary)
                    }
                    .suListRows()
                    if !others.isEmpty {
                        Section(String(localized: "Already claimed")) {
                            ForEach(others, id: \.0) { person, count in
                                LabeledContent(summary.name(person), value: String(localized: "\(count) of \(quantity)"))
                            }
                        }
                        .suListRows()
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .suScreenBackground()
            .navigationTitle(String(localized: "Claim part"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(String(localized: "Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(units == 0 ? String(localized: "Remove") : String(localized: "Save")) { save() }
                        .disabled(isSaving || (units == 0 && mine == nil) || units == mine)
                        .accessibilityIdentifier("units.save")
                }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                units = min(mine ?? 1, max(available, 0))
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        isSaving = true
        let count = units
        Task {
            if await flow.runInSequence({ .claimUnits($0.id, expectedRevision: $0.revision, item: itemID, units: count) }) != nil { dismiss() }
            isSaving = false
        }
    }
}
