import SwiftUI

// The App Clip's screens: enter a code, preview and join, claim and review, then settle up. Plain
// SwiftUI on the app's dusk palette, sized for Dynamic Type and narrow screens.

private func money(_ minor: Int, _ currency: String) -> String {
    let digits = ["JPY", "KRW", "VND", "CLP", "ISK"].contains(currency) ? 0 : 2
    let value = Decimal(minor) / pow(Decimal(10), digits)
    return value.formatted(.currency(code: currency))
}

/// Opened without a link: the host's short code (`ABCD-EFGH-JKMN`) or a pasted link.
struct ClipCodeEntryView: View {
    let model: ClipModel
    @State private var text = ""

    var body: some View {
        Form {
            Section {
                TextField(String(localized: "Room code"), text: $text, prompt: Text(verbatim: "ABCD-EFGH-JKMN"))
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.title3.monospaced())
                    .accessibilityIdentifier("clip.code")
                Button(String(localized: "Continue")) { Task { await model.handle(text) } }
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("clip.continue")
            } header: {
                Text(String(localized: "Join a receipt"))
            } footer: {
                Text(model.message ?? String(localized: "Ask the host for the code shown under their QR code."))
                    .foregroundStyle(model.message == nil ? .secondary : Color.red)
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle(String(localized: "Square Up"))
    }
}

/// Who's hosting and where, before joining: no items or amounts until you're in.
struct ClipJoinView: View {
    let model: ClipModel
    let preview: InvitationPreviewDTO

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(preview.merchant.isEmpty ? String(localized: "A receipt") : preview.merchant).font(.title2.weight(.semibold))
                    Text(String(localized: "\(preview.host.displayName) invited you to claim what you had."))
                        .foregroundStyle(.secondary)
                }
            }
            if preview.isClosed {
                Section { Label(String(localized: "This room isn't taking new people."), systemImage: "lock") }
            } else if preview.youAreParticipantId == nil {
                Section {
                    TextField(String(localized: "Your name"), text: Binding(get: { model.name }, set: { model.name = $0 }))
                        .textContentType(.givenName)
                        .accessibilityIdentifier("clip.name")
                } footer: {
                    Text(String(localized: "Shown to others in this room. No account needed."))
                }
                Section {
                    Button(String(localized: "Join")) { Task { await model.join() } }
                        .disabled(model.name.trimmingCharacters(in: .whitespaces).isEmpty || model.isSending)
                        .accessibilityIdentifier("clip.join")
                }
            }
            if let message = model.message { Section { Text(message).foregroundStyle(.red) } }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle(String(localized: "Join receipt"))
    }
}

/// Claiming and reviewing, then (once the host finalizes) paying them back.
struct ClipRoomView: View {
    let model: ClipModel
    @State private var countingItem: ItemDTO?
    @State private var disputingItem: ItemDTO?

    var body: some View {
        if let room = model.room {
            List {
                header(room)
                if let message = model.message { Section { Text(message).foregroundStyle(.red) } }
                if room.state == "finalized" || room.hasEnded {
                    ClipSettleSection(model: model, room: room)
                } else {
                    Section(String(localized: "Items")) {
                        ForEach(room.receipt.items.filter { $0.lineTotal != 0 }, id: \.id) { item in
                            itemRow(item, room: room)
                        }
                    }
                    reviewSection(room)
                }
            }
            .scrollContentBackground(.hidden)
            .refreshable { await model.refresh() }
            .navigationTitle(room.receipt.merchant.isEmpty ? String(localized: "Receipt") : room.receipt.merchant)
            .sheet(item: $countingItem) { item in ClipUnitsSheet(model: model, room: room, item: item) }
            .alert(String(localized: "Not yours?"), isPresented: Binding(get: { disputingItem != nil }, set: { if !$0 { disputingItem = nil } })) {
                Button(String(localized: "Dispute it"), role: .destructive) {
                    if let item = disputingItem { Task { await model.dispute(item.id, note: nil) } }
                    disputingItem = nil
                }
                Button(String(localized: "Cancel"), role: .cancel) { disputingItem = nil }
            } message: {
                Text(String(localized: "The host will see it and decide."))
            }
        }
    }

    private func header(_ room: RoomDTO) -> some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "Your share")).font(.subheadline).foregroundStyle(.secondary)
                    Text(money(yourTotal(room), room.receipt.currency)).font(.largeTitle.weight(.semibold).monospacedDigit())
                        .accessibilityIdentifier("clip.total")
                }
                Spacer()
                if model.isOffline {
                    Label(String(localized: "Offline"), systemImage: "icloud.slash").font(.caption).foregroundStyle(.orange)
                }
            }
            if let host = room.participant(room.hostParticipantId) {
                Text(String(localized: "\(host.displayName) paid \(money(room.receipt.total ?? 0, room.receipt.currency))"))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func yourTotal(_ room: RoomDTO) -> Int {
        room.allocation.participants.first { $0.participantId == room.viewer.participantId }?.total ?? 0
    }

    private func itemRow(_ item: ItemDTO, room: RoomDTO) -> some View {
        let claims = room.claims.filter { $0.itemId == item.id }
        let mine = claims.first { $0.participantId == room.viewer.participantId }
        let countable = (item.quantity ?? 0) >= 2
        let byUnits = !claims.isEmpty && claims.allSatisfy { $0.mode.kind == "units" }
        let names = claims.compactMap { claim -> String? in
            guard let person = room.participant(claim.participantId) else { return nil }
            let name = claim.participantId == room.viewer.participantId ? String(localized: "you") : person.displayName
            return claim.mode.units.map { String(localized: "\(name) ×\($0)") } ?? name
        }
        let left = byUnits ? max((item.quantity ?? 0) - claims.compactMap(\.mode.units).reduce(0, +), 0) : 0
        let canClaim = room.state == "open"
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.body.weight(.semibold))
                    Text(names.isEmpty ? String(localized: "Unclaimed")
                        : left > 0 ? String(localized: "\(names.formatted(.list(type: .and))) · \(left) left") : names.formatted(.list(type: .and)))
                        .font(.caption).foregroundStyle(names.isEmpty ? .orange : .secondary)
                }
                Spacer()
                Text(money(item.lineTotal, room.receipt.currency)).monospacedDigit()
            }
            if canClaim {
                HStack {
                    if mine != nil {
                        if byUnits { Button(String(localized: "Change")) { countingItem = item }.buttonStyle(.bordered) }
                        Button(String(localized: "Undo")) { Task { await model.unclaim(item.id) } }.buttonStyle(.bordered)
                    } else {
                        if claims.isEmpty { Button(String(localized: "Mine")) { Task { await model.claim(item.id, mine: true) } }.buttonStyle(.borderedProminent) }
                        if countable, claims.isEmpty || byUnits { Button(String(localized: "Some")) { countingItem = item }.buttonStyle(.bordered) }
                        if !byUnits { Button(String(localized: "Share")) { Task { await model.claim(item.id, mine: false) } }.buttonStyle(.bordered) }
                    }
                    Spacer()
                    Button { disputingItem = item } label: { Image(systemName: "exclamationmark.bubble") }
                        .accessibilityLabel(String(localized: "Not mine: \(item.name)"))
                }
                .disabled(model.isSending)
                .font(.subheadline.weight(.semibold))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("clip.item.\(item.name)")
    }

    @ViewBuilder
    private func reviewSection(_ room: RoomDTO) -> some View {
        let reviewed = !(room.unreviewed ?? []).contains(room.viewer.participantId)
        Section {
            Button(reviewed ? String(localized: "Reviewed · tap if something changes") : String(localized: "My share looks right")) {
                Task { await model.markReviewed() }
            }
            .disabled(model.isSending)
            .accessibilityIdentifier("clip.review")
        } footer: {
            Text(String(localized: "When everyone has claimed, the host finalizes and you'll see what to pay them."))
        }
    }
}

/// "How many did you have?" on a line with a printed quantity.
struct ClipUnitsSheet: View {
    let model: ClipModel
    let room: RoomDTO
    let item: ItemDTO
    @Environment(\.dismiss) private var dismiss
    @State private var units = 1

    private var others: Int {
        room.claims.filter { $0.itemId == item.id && $0.participantId != room.viewer.participantId }.compactMap(\.mode.units).reduce(0, +)
    }

    var body: some View {
        NavigationStack {
            Form {
                Stepper(String(localized: "\(units) of \(item.quantity ?? 1)"), value: $units, in: 0...max((item.quantity ?? 1) - others, 0))
                    .accessibilityIdentifier("clip.units")
                Text(String(localized: "Others claimed \(others). What's left stays for others to claim."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .navigationTitle(item.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(String(localized: "Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Save")) {
                        Task { await model.claimUnits(item.id, units: units); dismiss() }
                    }
                }
            }
            .onAppear {
                let mine = room.claims.first { $0.itemId == item.id && $0.participantId == room.viewer.participantId }?.mode.units
                units = mine ?? 1
            }
        }
        .presentationDetents([.medium])
    }
}

/// After finalization: what you owe the payer, their chosen methods, and your report. Square Up
/// never moves money; only the payer confirms a payment arrived.
struct ClipSettleSection: View {
    let model: ClipModel
    let room: RoomDTO

    var body: some View {
        let payer = room.payerId.flatMap(room.participant)?.displayName ?? String(localized: "the payer")
        if room.hasEnded {
            Section {
                Label(room.endReason == "allSquare" ? String(localized: "All square. Everyone's payment is confirmed.")
                    : room.endReason == "cancelled" ? String(localized: "The host closed this room.") : String(localized: "This room expired."),
                    systemImage: room.endReason == "allSquare" ? "checkmark.seal.fill" : "lock")
            }
        }
        if let payment = room.payment(of: room.viewer.participantId) {
            Section(payment.state == "confirmed" ? String(localized: "You paid \(payer)") : String(localized: "You owe \(payer)")) {
                Text(money(payment.amount, room.receipt.currency)).font(.title.weight(.semibold).monospacedDigit())
                    .accessibilityIdentifier("clip.owed")
                Text(status(payment, payer: payer)).foregroundStyle(.secondary)
                    .accessibilityIdentifier("clip.paymentState")
                if !room.hasEnded {
                    switch payment.state {
                    case "owed":
                        ForEach(model.destinations?.destinations ?? [], id: \.id) { method in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(method.label ?? method.provider.capitalized).font(.body.weight(.semibold))
                                Text(method.value.value).font(.callout.monospaced()).textSelection(.enabled)
                                Button(String(localized: "I paid with this")) {
                                    Task { await model.reportPayment(provider: method.provider, destinationID: method.id) }
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                        Button(String(localized: "I paid another way (cash, in person)")) {
                            Task { await model.reportPayment(provider: "cash", destinationID: nil) }
                        }
                        .accessibilityIdentifier("clip.paid")
                    case "reportedSent":
                        Button(String(localized: "I haven't paid yet (cancel report)")) { Task { await model.cancelPaymentReport() } }
                    default:
                        EmptyView()
                    }
                }
            }
        } else {
            Section { Text(String(localized: "Nothing to pay — your share is covered.")) }
        }
        Section {
            Text(String(localized: "Square Up doesn't move money. Pay \(payer) however you agree; they confirm when it arrives."))
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func status(_ payment: RoomPaymentDTO, payer: String) -> String {
        switch payment.state {
        case "confirmed": String(localized: "Paid · confirmed by \(payer)")
        case "reportedSent": String(localized: "You reported it · waiting for \(payer) to confirm")
        case "disputed": String(localized: "Disputed · \(payer) is checking")
        default: payment.latest?.state == "rejected" ? String(localized: "\(payer) said it didn't arrive. Report it again once it has.")
            : String(localized: "Not paid yet")
        }
    }
}

extension ItemDTO: Identifiable {}
