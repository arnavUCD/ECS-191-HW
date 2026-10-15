import SwiftUI

/// Shared-item editor (§8.7): equal, share counts, or exact amounts, with a live "adds up" status.
/// Saving is impossible until the portions equal the item exactly.
struct SharedItemEditor: View {
    let flow: ReceiptFlowModel
    let summary: ReceiptRoomSummary
    let itemID: ReceiptItemID

    enum Mode: String, CaseIterable, Identifiable {
        case equal, shares, exact, units
        var id: String { rawValue }
        var title: String {
            switch self {
            case .equal: String(localized: "Equally")
            case .shares: String(localized: "Shares")
            case .exact: String(localized: "Exact")
            case .units: String(localized: "By quantity")
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var mode: Mode = .equal
    @State private var selected: [MemberID] = []
    @State private var weights: [MemberID: Int] = [:]
    @State private var amounts: [MemberID: Money] = [:]
    @State private var units: [MemberID: Int] = [:]
    @State private var loaded = false
    @State private var isSaving = false

    private var item: ReceiptLineItem? { summary.room.receipt.item(itemID) }
    /// Lines with a printed quantity of 2 or more can be divided by it ("2 of the 3").
    private var quantity: Int? { item?.quantity.flatMap { $0 >= 2 ? $0 : nil } }
    private var modes: [Mode] { quantity == nil ? [.equal, .shares, .exact] : Mode.allCases }

    /// Host may include anyone in the room; a participant only existing claimants plus themselves.
    private var people: [Member] {
        let allowed = summary.isActorHost ? summary.room.participantIDs
            : summary.room.participantIDs.filter { summary.room.claims(for: itemID).map(\.memberID).contains($0) || $0 == summary.actorID }
        return allowed.compactMap { summary.members[$0] }
    }

    private var split: ItemSplit {
        let ordered = summary.room.participantIDs.filter(selected.contains)
        switch mode {
        case .equal: return .equal(ordered)
        case .shares: return .shares(ordered.map { MemberWeight($0, weights[$0] ?? 1) })
        case .exact: return .exact(ordered.map { Share($0, amounts[$0] ?? .zero(summary.currency)) })
        case .units: return .units(ordered.map { MemberUnits($0, units[$0] ?? 1) })
        }
    }

    /// Units the chosen people account for, out of the printed quantity.
    private var claimedUnits: Int { summary.room.participantIDs.filter(selected.contains).map { units[$0] ?? 1 }.reduce(0, +) }

    private var preview: Result<[Share], ItemSplitIssue>? {
        item.map { ReceiptAllocationEngine.preview(split, of: $0) }
    }

    var body: some View {
        NavigationStack {
            Form {
                if let item {
                    Section {
                        HStack {
                            Text(item.name.value).font(SUFont.body.weight(.semibold))
                            Spacer()
                            Text(MoneyFormatting.string(item.amount, locale: locale)).font(SUFont.rowAmount)
                        }
                        Picker(String(localized: "Divide"), selection: $mode) {
                            ForEach(modes) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("split.mode")
                    }
                    .suListRows()
                    Section(String(localized: "Who had it")) {
                        ForEach(people) { member in
                            personRow(member)
                        }
                        if !summary.isActorHost {
                            Text(String(localized: "To include someone else, they tap Share on this item."))
                                .font(SUFont.metadata).foregroundStyle(SUColor.textSecondary)
                        }
                    }
                    .suListRows()
                    Section {
                        status
                    }
                    .suListRows()
                }
            }
            .scrollContentBackground(.hidden)
            .suScreenBackground()
            .navigationTitle(summary.isActorHost ? String(localized: "Assign or split") : String(localized: "Custom split"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(String(localized: "Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Save")) { save() }
                        .disabled(!(preview.map { if case .success = $0 { true } else { false } } ?? false) || isSaving)
                        .accessibilityIdentifier("split.save")
                }
                if summary.isActorHost, !summary.room.claims(for: itemID).isEmpty {
                    ToolbarItem(placement: .bottomBar) {
                        Button(String(localized: "Clear all claims"), role: .destructive) { save(clearing: true) }
                    }
                }
            }
            .onAppear(perform: load)
        }
    }

    private func personRow(_ member: Member) -> some View {
        let isOn = selected.contains(member.id)
        return VStack(alignment: .leading, spacing: SUSpacing.xs) {
            Toggle(isOn: Binding(get: { isOn }, set: { on in
                if on { selected.append(member.id) } else { selected.removeAll { $0 == member.id } }
            })) {
                HStack(spacing: SUSpacing.sm) {
                    SUAvatar(member: member, size: .small, isCurrentUser: member.id == summary.currentUserID)
                    Text(member.displayName)
                    Spacer()
                    if isOn, case .success(let shares)? = preview, let share = shares.first(where: { $0.memberID == member.id }) {
                        Text(MoneyFormatting.string(share.amount, locale: locale)).font(SUFont.body.monospacedDigit()).foregroundStyle(SUColor.textSecondary)
                    }
                }
            }
            .accessibilityIdentifier("split.person.\(member.firstName)")
            if isOn, mode == .shares {
                Stepper(value: Binding(get: { weights[member.id] ?? 1 }, set: { weights[member.id] = $0 }), in: 1...20) {
                    Text(Inflect.string("^[\(weights[member.id] ?? 1) share](inflect: true)"))
                }
                .accessibilityLabel(String(localized: "Shares for \(member.displayName)"))
            }
            if isOn, mode == .exact {
                ReceiptMoneyField(title: String(localized: "Amount"), value: amounts[member.id], currency: summary.currency,
                                  allowsNegative: item?.amount.isNegative == true, identifier: "split.amount.\(member.firstName)") { amounts[member.id] = $0 }
            }
            if isOn, mode == .units, let quantity {
                Stepper(value: Binding(get: { units[member.id] ?? 1 }, set: { units[member.id] = $0 }), in: 1...quantity) {
                    Text(String(localized: "\(units[member.id] ?? 1) of \(quantity)"))
                        .font(SUFont.body.monospacedDigit())
                }
                .accessibilityLabel(String(localized: "How many \(member.displayName) had"))
                .accessibilityValue(String(localized: "\(units[member.id] ?? 1) of \(quantity)"))
                .accessibilityIdentifier("split.units.\(member.firstName)")
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch preview {
        case .success(let shares)?:
            VStack(alignment: .leading, spacing: SUSpacing.xs) {
                if mode == .units, let quantity, claimedUnits < quantity {
                    // Units may stay open for others to claim; they're never added to anyone silently.
                    Label(Inflect.string("^[\(quantity - claimedUnits) of \(quantity)](inflect: true) left for others to claim"), systemImage: "circle.dashed")
                        .foregroundStyle(SUColor.textSecondary)
                        .accessibilityIdentifier("split.unitsLeft")
                } else {
                    Label(String(localized: "Adds up to \(MoneyFormatting.string(item?.amount ?? .zero(summary.currency), locale: locale))"), systemImage: "checkmark.seal.fill")
                        .foregroundStyle(SUColor.positive)
                        .accessibilityIdentifier("split.addsUp")
                }
                ForEach(roundingNotes(shares), id: \.self) { note in
                    Label(note, systemImage: "info.circle").font(SUFont.metadata).foregroundStyle(SUColor.textSecondary)
                }
            }
        case .failure(let issue)?:
            Label(ReceiptLanguage.error(.invalidSplit(issue), names: summary.names, locale: locale), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(SUColor.warning)
                .accessibilityIdentifier("split.status")
        case nil:
            EmptyView()
        }
    }

    private func roundingNotes(_ shares: [Share]) -> [String] {
        guard let item, mode != .exact else { return [] }
        let rounding: [RoundingNote]
        if mode == .units, let quantity {
            guard claimedUnits == quantity else { return [] }
            rounding = ReceiptAllocationEngine.divideUnits(item, counts: shares.map { ($0.memberID, units[$0.memberID] ?? 1) }, quantity: quantity).1
        } else {
            let weights = shares.map { ($0.memberID, Decimal(mode == .shares ? (self.weights[$0.memberID] ?? 1) : 1)) }
            rounding = ReceiptAllocationEngine.divide(item.amount, weights: weights, source: .item(item.id)).1
        }
        return rounding.map { ReceiptLanguage.rounding($0, receipt: summary.room.receipt, names: summary.names, locale: locale) }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        let claims = summary.room.claims(for: itemID)
        selected = claims.isEmpty ? [summary.actorID].filter { summary.room.participantIDs.contains($0) } : claims.map(\.memberID)
        for claim in claims {
            switch claim.mode {
            case .shares(let count):
                mode = .shares
                weights[claim.memberID] = count
            case .exact(let money):
                mode = .exact
                amounts[claim.memberID] = money
            case .units(let count):
                mode = .units
                units[claim.memberID] = count
            case .full, .equalShare:
                weights[claim.memberID] = 1
            }
        }
    }

    private func save(clearing: Bool = false) {
        isSaving = true
        Task {
            let command = ReceiptRoomCommand.setItemSplit(summary.room.id, expectedRevision: summary.room.revision, item: itemID,
                                                          clearing ? .equal([]) : split)
            if await flow.run(command) != nil { dismiss() }
            isSaving = false
        }
    }
}

/// Host chooses how a charge or discount is divided (§8.8), with the result visible first.
struct ChargeAllocationEditor: View {
    let flow: ReceiptFlowModel
    let summary: ReceiptRoomSummary
    let chargeID: ReceiptChargeID
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var kind: ChargeAllocation.Kind = .proportional
    @State private var selected: [MemberID] = []
    @State private var weights: [MemberID: Int] = [:]
    @State private var amounts: [MemberID: Money] = [:]
    @State private var loaded = false

    private var charge: ReceiptCharge? { summary.room.receipt.charge(chargeID) }

    private var allocation: ChargeAllocation {
        let ordered = summary.room.participantIDs.filter(selected.contains)
        switch kind {
        case .proportional: return .proportional
        case .equal: return .equal(ordered.count == summary.room.participantIDs.count ? nil : ordered)
        case .shares: return .shares(ordered.map { MemberWeight($0, weights[$0] ?? 1) })
        case .exact: return .exact(ordered.map { Share($0, amounts[$0] ?? .zero(summary.currency)) })
        case .payer: return .payer
        }
    }

    private var result: ChargeAllocationResult? {
        var room = summary.room
        guard let index = room.receipt.charges.firstIndex(where: { $0.id == chargeID }) else { return nil }
        room.receipt.charges[index].allocation = allocation
        return ReceiptAllocationEngine.allocate(room).charge(chargeID)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let charge {
                    Section {
                        HStack {
                            Label(charge.label, systemImage: ReceiptLanguage.symbol(charge.kind))
                            Spacer()
                            Text(MoneyFormatting.signedString(charge.value, locale: locale).replacingOccurrences(of: "+", with: "")).font(SUFont.rowAmount)
                        }
                        Picker(String(localized: "Divide"), selection: $kind) {
                            ForEach(ChargeAllocation.Kind.allCases, id: \.self) { Text(ReceiptLanguage.name($0)).tag($0) }
                        }
                        .accessibilityIdentifier("charge.strategy")
                    } footer: {
                        Text(ReceiptLanguage.explanation(kind))
                    }
                    .suListRows()
                    if kind == .equal || kind == .shares || kind == .exact {
                        Section(String(localized: "Who shares it")) {
                            ForEach(summary.room.participantIDs.compactMap { summary.members[$0] }) { member in
                                memberRow(member, charge: charge)
                            }
                        }
                        .suListRows()
                    }
                    Section(String(localized: "Result")) {
                        resultRows
                    }
                    .suListRows()
                }
            }
            .scrollContentBackground(.hidden)
            .suScreenBackground()
            .navigationTitle(String(localized: "Divide \(charge?.label ?? "")"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(String(localized: "Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Save")) {
                        Task {
                            if await flow.run(.setChargeAllocation(summary.room.id, expectedRevision: summary.room.revision, chargeID, allocation),
                                              asHost: true) != nil { dismiss() }
                        }
                    }
                    .disabled(!canSave)
                    .accessibilityIdentifier("charge.save")
                }
            }
            .onAppear(perform: load)
        }
    }

    private var canSave: Bool {
        switch result?.status {
        case .allocated, .noBasis: true
        default: false
        }
    }

    private func memberRow(_ member: Member, charge: ReceiptCharge) -> some View {
        let isOn = selected.contains(member.id)
        return VStack(alignment: .leading) {
            Toggle(member.displayName, isOn: Binding(get: { isOn }, set: { on in
                if on { selected.append(member.id) } else { selected.removeAll { $0 == member.id } }
            }))
            if isOn, kind == .shares {
                Stepper(value: Binding(get: { weights[member.id] ?? 1 }, set: { weights[member.id] = $0 }), in: 1...20) {
                    Text(Inflect.string("^[\(weights[member.id] ?? 1) share](inflect: true)"))
                }
            }
            if isOn, kind == .exact {
                ReceiptMoneyField(title: String(localized: "Amount"), value: amounts[member.id], currency: summary.currency,
                                  allowsNegative: charge.value.isNegative) { amounts[member.id] = $0 }
            }
        }
    }

    @ViewBuilder
    private var resultRows: some View {
        if let result {
            if result.isAllocated {
                ForEach(result.shares, id: \.memberID) { share in
                    HStack {
                        Text(summary.name(share.memberID))
                        Spacer()
                        Text(MoneyFormatting.signedString(share.amount, locale: locale).replacingOccurrences(of: "+", with: "")).monospacedDigit()
                    }
                }
                ForEach(result.rounding, id: \.self) { note in
                    Label(ReceiptLanguage.rounding(note, receipt: summary.room.receipt, names: summary.names, locale: locale), systemImage: "info.circle")
                        .font(SUFont.metadata).foregroundStyle(SUColor.textSecondary)
                }
            } else {
                Label(ReceiptLanguage.readiness(.unallocatedCharge(chargeID, result.status), room: summary.room, names: summary.names, locale: locale),
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(SUColor.warning)
            }
        }
    }

    private func load() {
        guard !loaded, let charge else { return }
        loaded = true
        kind = charge.allocation.kind
        selected = summary.room.participantIDs
        switch charge.allocation {
        case .equal(let ids?): selected = ids
        case .shares(let list):
            selected = list.map(\.memberID)
            for weight in list { weights[weight.memberID] = weight.weight }
        case .exact(let shares):
            selected = shares.map(\.memberID)
            for share in shares { amounts[share.memberID] = share.amount }
        default: break
        }
    }
}

/// "Not mine / Dispute" with an optional short note (§8.10).
struct DisputeEditor: View {
    let flow: ReceiptFlowModel
    let summary: ReceiptRoomSummary
    let target: DisputeTarget
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""

    private var targetName: String {
        switch target {
        case .item(let id): summary.room.receipt.item(id)?.name.value ?? ""
        case .charge(let id): summary.room.receipt.charge(id)?.label ?? ""
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(String(localized: "\(summary.name(summary.actorID)) disputes \(targetName)")).font(SUFont.body.weight(.semibold))
                    TextField(String(localized: "What's wrong? (optional)"), text: $note, axis: .vertical)
                        .lineLimit(2...4)
                        .accessibilityIdentifier("dispute.note")
                    Text("\(note.count)/140").font(SUFont.metadata).foregroundStyle(note.count > 140 ? SUColor.negative : SUColor.textSecondary)
                } footer: {
                    Text(String(localized: "The host is asked to resolve it. Nothing can be saved while a dispute is open."))
                }
                .suListRows()
            }
            .scrollContentBackground(.hidden)
            .suScreenBackground()
            .navigationTitle(String(localized: "Dispute"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(String(localized: "Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Send")) {
                        Task {
                            if await flow.run(.dispute(summary.room.id, expectedRevision: summary.room.revision, target, note: note)) != nil { dismiss() }
                        }
                    }
                    .disabled(note.count > 140)
                    .accessibilityIdentifier("dispute.send")
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// The host resolves a dispute: change the split, then mark it resolved — or dismiss with a note.
struct DisputeResolutionView: View {
    let flow: ReceiptFlowModel
    let summary: ReceiptRoomSummary
    let disputeID: ReceiptDisputeID
    let changeSplit: (ReceiptItemID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                if let dispute = summary.room.disputes.first(where: { $0.id == disputeID }) {
                    Section {
                        Text(ReceiptLanguage.readiness(.openDispute(dispute.id), room: summary.room, names: summary.names)).font(SUFont.body.weight(.semibold))
                        if let text = dispute.note { Text("\u{201C}\(text)\u{201D}").foregroundStyle(SUColor.textSecondary) }
                    }
                    .suListRows()
                    if case .item(let itemID) = dispute.target {
                        Section {
                            Button(String(localized: "Change who has it…"), systemImage: "slider.horizontal.3") { changeSplit(itemID) }
                        } footer: {
                            Text(String(localized: "Then come back and mark the dispute resolved."))
                        }
                        .suListRows()
                    }
                    Section(String(localized: "Note")) {
                        TextField(String(localized: "Resolution note"), text: $note, axis: .vertical)
                            .accessibilityIdentifier("resolve.note")
                    }
                    .suListRows()
                    Section {
                        Button(String(localized: "Mark resolved"), systemImage: "checkmark.bubble") { resolve(.resolved) }
                            .accessibilityIdentifier("resolve.resolved")
                        Button(String(localized: "No change needed"), systemImage: "hand.thumbsup") { resolve(.dismissed) }
                            .disabled(note.trimmingCharacters(in: .whitespaces).isEmpty)
                    } footer: {
                        Text(String(localized: "\u{201C}No change needed\u{201D} requires a note for the history."))
                    }
                    .suListRows()
                }
            }
            .scrollContentBackground(.hidden)
            .suScreenBackground()
            .navigationTitle(String(localized: "Resolve dispute"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(String(localized: "Cancel")) { dismiss() } } }
        }
    }

    private func resolve(_ status: DisputeStatus) {
        Task {
            if await flow.run(.resolveDispute(summary.room.id, expectedRevision: summary.room.revision, disputeID, status, note: note), asHost: true) != nil {
                dismiss()
            }
        }
    }
}

/// Host changes who is in the room. Removing someone clears their claims (recorded in history).
struct ParticipantsEditor: View {
    let flow: ReceiptFlowModel
    let summary: ReceiptRoomSummary
    @Environment(\.dismiss) private var dismiss
    @State private var selected: [MemberID] = []

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(candidates) { member in
                        Toggle(isOn: Binding(get: { selected.contains(member.id) }, set: { on in
                            if on { selected.append(member.id) } else { selected.removeAll { $0 == member.id } }
                        })) {
                            VStack(alignment: .leading) {
                                Text(member.displayName)
                                if summary.group?.isActiveMember(member.id) == false {
                                    Text(String(localized: "Left the group")).font(SUFont.metadata).foregroundStyle(SUColor.warning)
                                }
                            }
                        }
                    }
                } footer: {
                    let removed = summary.room.participantIDs.filter { !selected.contains($0) }
                    let affected = removed.filter { id in summary.room.claims.contains { $0.memberID == id } }
                    if !affected.isEmpty {
                        Text(String(localized: "Removing \(affected.map(summary.name).formatted(.list(type: .and))) clears their claims. They're kept in the room's history."))
                    }
                }
                .suListRows()
            }
            .scrollContentBackground(.hidden)
            .suScreenBackground()
            .navigationTitle(String(localized: "Who's in the room"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(String(localized: "Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Save")) {
                        Task {
                            if await flow.run(.setParticipants(summary.room.id, expectedRevision: summary.room.revision, participants: selected), asHost: true) != nil {
                                dismiss()
                            }
                        }
                    }
                    .disabled(selected.isEmpty)
                }
            }
            .onAppear { selected = summary.room.participantIDs }
        }
    }

    private var candidates: [Member] {
        let active = summary.group.map { group in group.activeMemberIDs } ?? []
        var ids = summary.room.participantIDs
        for id in active where !ids.contains(id) { ids.append(id) }
        return ids.compactMap { summary.members[$0] }
    }
}
