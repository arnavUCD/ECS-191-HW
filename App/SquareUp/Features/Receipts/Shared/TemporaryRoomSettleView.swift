import SwiftUI

/// A finalized temporary room ("Split with people now"): everyone pays the payer back outside Square
/// Up and the payer confirms. Square Up never moves money — it opens or copies the payer's chosen
/// payment method and records a report the payer confirms or rejects. When every payment is
/// confirmed the room is square and closes; a closed, cancelled, or expired room stays readable here
/// until its summary is deleted.
struct TemporaryRoomSettleView: View {
    let flow: ReceiptFlowModel
    let done: () -> Void
    @Environment(\.locale) private var locale
    @State private var destinations: RoomDestinationsDTO?
    @State private var isWorking = false
    @State private var failure: String?
    @State private var rejecting: RoomPaymentDTO?
    @State private var reason = ""
    @State private var confirmCount = 0

    private var session: RemoteRoomLedger? { flow.remote }
    private var dto: RoomDTO? { session?.base }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SUSpacing.lg) {
                if let dto, let room = flow.room, let snapshot = flow.snapshot, let you = flow.actor {
                    let summary = ReceiptRoomSummary.make(room: room, snapshot: snapshot, actorID: you)
                    header(dto, summary: summary)
                    if let failure {
                        SUConfirmationBanner(title: String(localized: "Not changed"), message: failure, systemImage: "exclamationmark.triangle.fill", tone: .negative)
                            .accessibilityIdentifier("settle.error")
                    }
                    if dto.viewer.isHost {
                        hostPayments(dto, summary: summary)
                    } else {
                        yourPayment(dto, summary: summary)
                    }
                    if let hostResolved = dto.finalization?.hostResolved, !hostResolved.isEmpty {
                        Label(String(localized: "\(hostResolved.map { summary.name(RemoteRoomMapper.member($0)) }.formatted(.list(type: .and))) hadn't reviewed their share; \(summary.name(room.hostID)) finalized it for them."),
                              systemImage: "person.badge.shield.checkmark")
                            .font(SUFont.metadata).foregroundStyle(SUColor.textSecondary)
                            .accessibilityIdentifier("settle.hostResolved")
                    }
                    breakdown(summary)
                    footnote(dto)
                }
                Button(String(localized: "Done"), action: done).buttonStyle(.suSecondary(fullWidth: true))
            }
            .padding(.horizontal, SUSpacing.screenMargin)
            .padding(.vertical, SUSpacing.lg)
            .frame(maxWidth: SUMetrics.readableWidth)
            .frame(maxWidth: .infinity)
        }
        .suScreenBackground()
        .navigationTitle(String(localized: "Settle up"))
        .sensoryFeedback(.success, trigger: confirmCount)
        .task(id: dto?.revision) { await loadDestinations() }
        .alert(String(localized: "Didn't get it?"), isPresented: Binding(get: { rejecting != nil }, set: { if !$0 { rejecting = nil } })) {
            TextField(String(localized: "Optional note"), text: $reason)
            Button(String(localized: "Not received"), role: .destructive) {
                if let payment = rejecting { act("rejectPayment", ["participantId": .string(payment.participantId), "reason": .string(reason)]) }
                rejecting = nil
            }
            Button(String(localized: "Cancel"), role: .cancel) { rejecting = nil }
        } message: {
            Text(String(localized: "They'll see it wasn't confirmed and can report it again once it arrives."))
        }
    }

    // MARK: Header

    private func header(_ dto: RoomDTO, summary: ReceiptRoomSummary) -> some View {
        let status = status(dto)
        return SUCoverPanel(palette: status.palette, symbol: status.symbol, coverHeight: 170) {
            VStack(alignment: .leading, spacing: SUSpacing.xs) {
                SUCoverChip(lead: .symbol(status.symbol, .white), title: status.title, subtitle: status.subtitle)
                Spacer(minLength: SUSpacing.sm)
                Text(summary.room.title).font(SUFont.cardTitle).foregroundStyle(.white).lineLimit(2)
                Text(MoneyFormatting.string(summary.total, locale: locale)).font(SUFont.heroAmount).foregroundStyle(.white)
                    .minimumScaleFactor(0.6)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settle.header")
    }

    /// The header's words, symbol, and cover for where the room is.
    private struct Status {
        let title: String
        let subtitle: String
        let symbol: String
        let palette: SUMeshBackground.Palette
    }

    private func status(_ dto: RoomDTO) -> Status {
        let open = dto.payments?.filter { $0.state != "confirmed" }.count ?? 0
        return switch dto.endReason {
        case "allSquare": Status(title: String(localized: "All square"), subtitle: String(localized: "Every payment is confirmed"),
                                 symbol: "checkmark.seal.fill", palette: .positive)
        case "cancelled": Status(title: String(localized: "Room closed"), subtitle: String(localized: "The host closed it before it was final"),
                                 symbol: "xmark.circle.fill", palette: .calm)
        case "expired": Status(title: String(localized: "Room expired"), subtitle: String(localized: "Nothing more can change"),
                               symbol: "clock.badge.xmark", palette: .calm)
        default:
            Status(title: String(localized: "Final split"),
                   subtitle: Inflect.string("^[\(open) payment](inflect: true) to confirm"),
                   symbol: "hourglass", palette: .attention)
        }
    }

    // MARK: Host

    @ViewBuilder
    private func hostPayments(_ dto: RoomDTO, summary: ReceiptRoomSummary) -> some View {
        let payments = dto.payments ?? []
        SUPanelSection(title: String(localized: "Paying you back"),
                       subtitle: payments.isEmpty ? String(localized: "Nobody owes you anything.") : String(localized: "Confirm each payment when it arrives.")) {
            ForEach(payments) { payment in
                hostRow(payment, summary: summary, ended: dto.hasEnded)
                if payment.id != payments.last?.id { Divider() }
            }
        }
    }

    private func hostRow(_ payment: RoomPaymentDTO, summary: ReceiptRoomSummary, ended: Bool) -> some View {
        let person = RemoteRoomMapper.member(payment.participantId)
        return VStack(alignment: .leading, spacing: SUSpacing.xs) {
            HStack(spacing: SUSpacing.sm) {
                if let member = summary.members[person] { SUAvatar(member: member, size: .medium, isCurrentUser: false) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.name(person)).font(SUFont.body.weight(.semibold)).foregroundStyle(SUColor.textPrimary)
                    PaymentStateLabel(payment: payment, isHost: true)
                }
                .layoutPriority(1) // the state stays readable; the spacer gives way first
                Spacer(minLength: SUSpacing.xs)
                SUAmountView(money: money(payment.amount), style: .row)
            }
            if !ended, payment.state == "reportedSent" || payment.state == "disputed" {
                HStack(spacing: SUSpacing.xs) {
                    Button(String(localized: "Confirm received")) {
                        act("confirmPayment", ["participantId": .string(payment.participantId)]) { confirmCount += 1 }
                    }
                    .buttonStyle(.suPillProminent)
                    .accessibilityIdentifier("settle.confirm.\(summary.name(person))")
                    Button(String(localized: "Not received")) {
                        reason = ""
                        rejecting = payment
                    }
                    .buttonStyle(.suPill)
                    .accessibilityIdentifier("settle.reject.\(summary.name(person))")
                }
                .disabled(isWorking)
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Participant

    @ViewBuilder
    private func yourPayment(_ dto: RoomDTO, summary: ReceiptRoomSummary) -> some View {
        let payer = summary.room.payerID.map { summary.name($0) } ?? String(localized: "the payer")
        if let payment = dto.payment(of: dto.viewer.participantId) {
            let title = payment.state == "confirmed" ? String(localized: "You paid \(payer)") : String(localized: "You owe \(payer)")
            SUPanelSection(title: title, subtitle: PaymentStateLabel.text(payment, isHost: false, payer: payer)) {
                HStack {
                    Text(String(localized: "Your share")).font(SUFont.body).foregroundStyle(SUColor.textSecondary)
                    Spacer()
                    SUAmountView(money: money(payment.amount), style: .large)
                        .accessibilityIdentifier("settle.yourAmount")
                }
                if !dto.hasEnded {
                    switch payment.state {
                    case "owed": payOptions(payment, payer: payer)
                    case "reportedSent":
                        Button(String(localized: "I haven't paid yet (cancel report)")) { act("cancelPaymentReport", [:]) }
                            .buttonStyle(.suSecondary(fullWidth: true))
                            .disabled(isWorking)
                            .accessibilityIdentifier("settle.cancelReport")
                    default: EmptyView()
                    }
                }
            }
        } else {
            SUPanelSection(title: String(localized: "Nothing to pay")) {
                Text(String(localized: "Your share is covered. There's nothing to pay \(payer)."))
                    .font(SUFont.body).foregroundStyle(SUColor.textSecondary)
            }
        }
    }

    @ViewBuilder
    private func payOptions(_ payment: RoomPaymentDTO, payer: String) -> some View {
        let methods = destinations?.destinations ?? []
        if !methods.isEmpty {
            VStack(alignment: .leading, spacing: SUSpacing.xs) {
                Text(String(localized: "\(payer) accepts")).font(SUFont.metadata.weight(.semibold)).foregroundStyle(SUColor.textSecondary)
                ForEach(methods, id: \.id) { method in
                    methodRow(method, payment: payment, payer: payer)
                }
            }
        }
        let paidOther = Button {
            act("reportPayment", ["provider": "cash"])
        } label: {
            Label(methods.isEmpty ? String(localized: "I paid \(payer)") : String(localized: "I paid another way (cash, in person)"),
                  systemImage: "checkmark.circle")
                .frame(maxWidth: .infinity)
        }
        Group {
            if methods.isEmpty { paidOther.buttonStyle(.suPrimary) } else { paidOther.buttonStyle(.suSecondary) }
        }
        .disabled(isWorking)
        .accessibilityIdentifier("settle.paidOther")
        Text(String(localized: "Square Up doesn't move money. Reporting tells \(payer) to check; only they can confirm it arrived."))
            .font(SUFont.metadata).foregroundStyle(SUColor.textSecondary)
    }

    private func methodRow(_ method: DestinationDTO, payment: RoomPaymentDTO, payer: String) -> some View {
        let provider = PaymentProviderKind(rawValue: method.provider) ?? .other
        let destination = SharedGroupMapper.destination(method, owner: RemoteRoomMapper.member(destinations?.recipient.participantId ?? ""))
        let plan = HandoffPlanner.plan(destination: destination, provider: provider, amount: money(payment.amount),
                                       memo: String(localized: "Square Up: \(flow.room?.title ?? "")"), reference: "",
                                       recipientName: payer, groupName: flow.room?.title ?? "", locale: locale)
        return VStack(alignment: .leading, spacing: SUSpacing.xs) {
            HStack(spacing: SUSpacing.sm) {
                Image(systemName: provider.symbolName).font(.title3).foregroundStyle(SUColor.textPrimary).frame(width: 32).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(method.label ?? provider.displayName).font(SUFont.body.weight(.semibold))
                    if let destination {
                        Text(DestinationPresentation.revealed(destination.value, provider: provider))
                            .font(SUFont.metadata).foregroundStyle(SUColor.textSecondary).textSelection(.enabled)
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: SUSpacing.xs) {
                Button(plan.primaryTitle) { Task { await handOff(plan, provider: provider) } }
                    .buttonStyle(.suPill)
                    .accessibilityIdentifier("settle.open.\(method.provider)")
                Button(String(localized: "I paid with \(provider.displayName)")) {
                    act("reportPayment", ["provider": .string(method.provider), "destinationId": .string(method.id)])
                }
                .buttonStyle(.suPillProminent)
                .disabled(isWorking)
                .accessibilityIdentifier("settle.report.\(method.provider)")
            }
        }
        .padding(SUSpacing.sm)
        .suSurface(SUShape.compact)
    }

    private func handOff(_ plan: HandoffPlan, provider: PaymentProviderKind) async {
        switch plan.action {
        case .openURL(let url):
            if await flow.environment.handoff.open(url, for: provider) { return }
            copy(plan)
        case .composeMessage, .copyDetails, .recordManually:
            copy(plan)
        }
    }

    private func copy(_ plan: HandoffPlan) {
        let text = plan.copyItems.map { "\($0.label): \($0.value)" }.joined(separator: "\n")
        flow.environment.handoff.copy(text)
    }

    // MARK: Breakdown and footnote

    private func breakdown(_ summary: ReceiptRoomSummary) -> some View {
        DisclosureGroup(String(localized: "Who had what")) {
            VStack(spacing: SUSpacing.sm) {
                ForEach(summary.allocation.participants.filter { !$0.total.isZero }, id: \.memberID) { participant in
                    ParticipantBreakdown(summary: summary, participant: participant)
                }
            }
            .padding(.top, SUSpacing.xs)
        }
        .font(SUFont.body.weight(.semibold))
        .tint(SUColor.textPrimary)
        .padding(SUSpacing.md)
        .suSurface(SUShape.card)
    }

    @ViewBuilder
    private func footnote(_ dto: RoomDTO) -> some View {
        if dto.hasEnded, let ended = dto.closedAt.flatMap(RemoteRoomMapper.timestamp) {
            Label(String(localized: "This summary stays for 30 days after \(ended.formatted(date: .abbreviated, time: .omitted)), then the room and everything in it is deleted."),
                  systemImage: "trash.slash")
                .font(SUFont.metadata).foregroundStyle(SUColor.textSecondary)
        } else if let deadline = dto.expiresAt.flatMap(RemoteRoomMapper.timestamp) {
            Label(String(localized: "Payments can be reported and confirmed until \(deadline.formatted(date: .abbreviated, time: .omitted)). The room closes on its own once everyone is confirmed."),
                  systemImage: "clock")
                .font(SUFont.metadata).foregroundStyle(SUColor.textSecondary)
        }
    }

    // MARK: Actions

    private func money(_ minor: Int) -> Money {
        Money(minorUnits: Int64(minor), currency: CurrencyCode(dto?.receipt.currency ?? "USD"))
    }

    private func loadDestinations() async {
        guard let dto, let session, !dto.viewer.isHost, !dto.hasEnded,
              let payment = dto.payment(of: dto.viewer.participantId), payment.state != "confirmed" else { return }
        destinations = try? await flow.environment.sharing.paymentDestinations(for: session.roomID)
    }

    private func act(_ type: String, _ payload: JSONValue, then success: (() -> Void)? = nil) {
        guard let session else { return }
        isWorking = true
        failure = nil
        Task {
            do {
                try await session.sendRemote(type, payload)
                success?()
            } catch {
                failure = LedgerErrorMessages.text(for: error as? LedgerError ?? .remote(.unavailable))
            }
            await flow.load()
            isWorking = false
        }
    }
}

/// A payment's state in words and an icon (never colour alone).
struct PaymentStateLabel: View {
    let payment: RoomPaymentDTO
    let isHost: Bool

    var body: some View {
        let (symbol, tone) = Self.look(payment)
        SUCapsuleLabel(title: Self.text(payment, isHost: isHost, payer: nil), systemImage: symbol, tone: tone)
            .accessibilityIdentifier("settle.state")
    }

    static func look(_ payment: RoomPaymentDTO) -> (String, SUTone) {
        switch payment.state {
        case "confirmed": ("checkmark.circle.fill", .positive)
        case "reportedSent": ("paperplane.fill", .informational)
        case "disputed": ("exclamationmark.bubble.fill", .negative)
        default: payment.latest?.state == "rejected" ? ("arrow.uturn.backward.circle", .warning) : ("clock", .warning)
        }
    }

    static func text(_ payment: RoomPaymentDTO, isHost: Bool, payer: String?) -> String {
        let method = payment.latest.flatMap { PaymentProviderKind(rawValue: $0.provider)?.displayName } ?? ""
        switch payment.state {
        case "confirmed": return String(localized: "Paid · confirmed")
        case "reportedSent":
            return isHost ? String(localized: "Reported paid · \(method)")
                : String(localized: "You reported it · waiting for \(payer ?? String(localized: "the payer")) to confirm")
        case "disputed": return String(localized: "Disputed · needs a decision")
        default:
            if payment.latest?.state == "rejected" {
                return isHost ? String(localized: "You said it didn't arrive") : String(localized: "\(payer ?? String(localized: "The payer")) said it didn't arrive")
            }
            return isHost ? String(localized: "Hasn't paid yet") : String(localized: "Not paid yet")
        }
    }
}
