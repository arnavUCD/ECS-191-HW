import SwiftUI

/// Pinned above a shared room (milestone 4 §4.3, §7.4): who you are, whether what you see is
/// current, and anything that needs you — a conflict, an unsent change, ended access, or guests
/// to match before saving. Replaces the "Previewing as" switcher: on a shared room everyone is
/// on their own device.
struct SharedRoomStatusBar: View {
    let flow: ReceiptFlowModel
    let session: RemoteRoomLedger
    @State private var isMatching = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var record: SharedRoomDirectory.Record? { flow.environment.sharing.directory.record(session.roomID) }

    var body: some View {
        VStack(alignment: .leading, spacing: SUSpacing.xs) {
            identityRow
            banners
        }
        .padding(.horizontal, SUSpacing.screenMargin)
        .padding(.vertical, SUSpacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .sheet(isPresented: $isMatching) { GuestMatchingSheet(flow: flow, session: session) }
    }

    private var identityRow: some View {
        let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: SUSpacing.xs))
            : AnyLayout(HStackLayout(spacing: SUSpacing.sm))
        return layout {
            VStack(alignment: .leading, spacing: 2) {
                Text(youText)
                    .font(SUFont.cardTitle)
                    .foregroundStyle(SUColor.textPrimary)
                    .lineLimit(2)
                    .accessibilityIdentifier("room.sharedIdentity")
                SyncStatusLabel(state: session.syncState, pending: session.pendingItemIDs.count)
                if let context = contextText {
                    Text(context).font(SUFont.metadata).foregroundStyle(SUColor.textSecondary).lineLimit(2)
                        .accessibilityIdentifier("room.context")
                }
            }
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: SUSpacing.xs) }
            // A group's receipt never has invitations: only the members chosen when it was posted.
            if session.isHost, !session.isGroupReceipt, let room = flow.room, !room.state.isTerminal, session.base?.hasEnded != true {
                Button {
                    flow.environment.sharing.sheet = .invite(session.roomID)
                } label: {
                    Label(String(localized: "Invite"), systemImage: "qrcode")
                        .font(SUFont.supporting.weight(.semibold))
                        .padding(.horizontal, SUSpacing.sm)
                        .frame(minHeight: SUMetrics.minimumTouchTarget)
                        .suSurface(Capsule(), elevated: true)
                }
                .buttonStyle(.plain)
                .fixedSize()
                .accessibilityHint(String(localized: "Shows a link and code others can use to join"))
                .accessibilityIdentifier("room.invite")
            }
        }
    }

    /// Runs a retry; if it fails, the room shows why (as for any other change).
    private func attempt(_ operation: @escaping () async throws -> Void) {
        Task {
            do {
                try await operation()
                flow.errorMessage = nil
            } catch {
                flow.errorMessage = LedgerErrorMessages.text(for: error as? LedgerError ?? .remote(.unavailable), members: flow.snapshot?.members ?? [:])
            }
            await flow.load()
        }
    }

    /// A temporary room's deadline, or which group a receipt belongs to.
    private var contextText: String? {
        guard let base = session.base else { return nil }
        if session.isGroupReceipt, let group = flow.environment.sharedGroup?.groupName, !group.isEmpty {
            return String(localized: "In \(group) · only the people on it can claim")
        }
        if base.isTemporary, !base.hasEnded, let deadline = base.expiresAt.flatMap(RemoteRoomMapper.timestamp) {
            return base.state == "finalized"
                ? String(localized: "Payments until \(deadline.formatted(date: .abbreviated, time: .omitted))")
                : String(localized: "Open until \(deadline.formatted(date: .abbreviated, time: .shortened))")
        }
        return nil
    }

    private var youText: String {
        guard let id = session.viewerID, let name = flow.snapshot?.members[id]?.displayName else { return String(localized: "Shared room") }
        return session.isHost ? String(localized: "You're \(name) · host") : String(localized: "You're \(name)")
    }

    @ViewBuilder
    private var banners: some View {
        if let notice = session.notice, notice.issue == .conflict {
            SUConfirmationBanner(
                title: String(localized: "Someone changed this first"),
                message: String(localized: "Your change wasn't saved. You're now seeing the latest room."),
                systemImage: "arrow.triangle.2.circlepath", tone: .warning,
                actionTitle: notice.retryable == nil ? nil : String(localized: "Try again")
            ) {
                attempt { try await session.retryAfterConflict() }
            }
            .accessibilityIdentifier("room.conflict")
        } else if session.unsent != nil {
            SUConfirmationBanner(
                title: String(localized: "A change wasn't sent"),
                message: String(localized: "It isn't saved until Square Up confirms it. Sending again won't apply it twice."),
                systemImage: "icloud.slash", tone: .warning, actionTitle: String(localized: "Send again")
            ) {
                attempt { try await session.resendUnsent() }
            }
            .accessibilityIdentifier("room.unsent")
        }
        if session.syncState == .accessEnded {
            SUConfirmationBanner(
                title: String(localized: "Your access to this room ended"),
                message: String(localized: "The invitation expired or the host removed you. Ask the host for a new link."),
                systemImage: "lock.slash", tone: .negative
            )
        }
        if session.isHost, let room = session.base, let issue = hostIssue(room) {
            SUConfirmationBanner(title: issue.title, message: issue.message, systemImage: "person.crop.circle.badge.questionmark",
                                 tone: .warning, actionTitle: issue.action) {
                if issue.isMatching { isMatching = true } else { Task { _ = await flow.environment.sharing.adopt(room) } }
            }
            .accessibilityIdentifier("room.matchGuests")
        }
    }

    private struct HostIssue {
        let title: String
        let message: String
        let action: String
        let isMatching: Bool
    }

    private func hostIssue(_ room: RoomDTO) -> HostIssue? {
        let unmatched = flow.environment.sharing.guestsNeedingMatch(in: room)
        if !unmatched.isEmpty, room.state != "cancelled" {
            return HostIssue(
                title: Inflect.string("^[\(unmatched.count) guest](inflect: true) to match"),
                message: String(localized: "Before saving, say who each guest is in your group so the expense lands on the right people."),
                action: String(localized: "Match guests"), isMatching: true
            )
        }
        if room.isTerminal, let problem = record?.adoptionProblem {
            return HostIssue(
                title: String(localized: "Not saved on this iPhone yet"),
                message: problem == .totalsDiffer
                    ? LedgerErrorMessages.text(for: .receipt(.sharedTotalsDiffer))
                    : String(localized: "The room is finished, but the expense wasn't added to your group yet."),
                action: String(localized: "Try again"), isMatching: false
            )
        }
        return nil
    }
}

/// "Up to date", "Sending 2 changes…", "Offline · showing 2:41 PM" — words and an icon, never colour alone.
struct SyncStatusLabel: View {
    let state: RemoteRoomLedger.SyncState
    var pending = 0

    var body: some View {
        Label(text, systemImage: symbol)
            .font(SUFont.metadata)
            .foregroundStyle(tone.color)
            .accessibilityIdentifier("room.syncStatus")
    }

    private var text: String {
        switch state {
        case .connecting: String(localized: "Connecting…")
        case .synced: String(localized: "Live · up to date")
        case .sending(let count): Inflect.string("Sending ^[\(max(count, pending, 1)) change](inflect: true)…")
        case .offline(let date?):
            String(localized: "Offline · showing \(date.formatted(date: .omitted, time: .shortened))")
        case .offline(nil): String(localized: "Offline")
        case .accessEnded: String(localized: "Access ended")
        }
    }

    private var symbol: String {
        switch state {
        case .connecting: "antenna.radiowaves.left.and.right"
        case .synced: "checkmark.icloud"
        case .sending: "arrow.up.circle"
        case .offline: "icloud.slash"
        case .accessEnded: "lock"
        }
    }

    private var tone: SUTone {
        switch state {
        case .synced: .positive
        case .connecting, .sending: .informational
        case .offline: .warning
        case .accessEnded: .negative
        }
    }
}

/// Opening a shared room before its first snapshot arrives, or when it can't.
struct SharedRoomLoadingView: View {
    let flow: ReceiptFlowModel
    let close: () -> Void
    @State private var failure: LedgerError?

    var body: some View {
        Group {
            if let failure {
                if failure == .remote(.accessEnded) {
                    SUEmptyState(systemImage: "lock.slash", title: String(localized: "You can't open this room anymore"),
                                 message: LedgerErrorMessages.text(for: failure), primaryTitle: String(localized: "Done"), primaryAction: close)
                } else {
                    SUErrorState(title: String(localized: "Couldn't open the room"), message: LedgerErrorMessages.text(for: failure)) {
                        Task { await load() }
                    }
                }
            } else {
                VStack(spacing: SUSpacing.md) {
                    ProgressView()
                    Text(String(localized: "Opening the shared room…")).font(SUFont.body).foregroundStyle(SUColor.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .suScreenBackground()
        .task { await load() }
    }

    private func load() async {
        failure = nil
        do {
            try await flow.remote?.refresh()
            await flow.load()
        } catch {
            failure = error as? LedgerError ?? .remote(.unavailable)
        }
    }
}

/// A participant's view of a finalized shared room: what they owe and to whom (the host's
/// device records the expense in the group; nothing is charged by Square Up).
struct SharedRoomResultView: View {
    let flow: ReceiptFlowModel
    let done: () -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SUSpacing.lg) {
                if let room = flow.room, let snapshot = flow.snapshot, let you = flow.actor {
                    let summary = ReceiptRoomSummary.make(room: room, snapshot: snapshot, actorID: you)
                    VStack(alignment: .leading, spacing: SUSpacing.xs) {
                        Label(String(localized: "Finalized"), systemImage: "checkmark.seal.fill")
                            .font(SUFont.supporting.weight(.semibold)).foregroundStyle(SUColor.positive)
                        Text(room.title).font(SUFont.screenTitle).foregroundStyle(SUColor.textPrimary).accessibilityAddTraits(.isHeader)
                        Text(payerLine(summary)).font(SUFont.body).foregroundStyle(SUColor.textSecondary)
                    }
                    YourTotalCard(summary: summary) {}
                    SUCard {
                        VStack(alignment: .leading, spacing: SUSpacing.xs) {
                            ForEach(summary.allocation.participants.filter { !$0.total.isZero }, id: \.memberID) { person in
                                HStack {
                                    Text(person.memberID == you ? String(localized: "You") : summary.name(person.memberID))
                                        .font(SUFont.body).foregroundStyle(SUColor.textPrimary)
                                    Spacer()
                                    SUAmountView(money: person.total, direction: .neutral, style: .row)
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                    Text(String(localized: "Square Up doesn't move money. Pay the payer however you usually do."))
                        .font(SUFont.metadata).foregroundStyle(SUColor.textSecondary)
                }
                Button(String(localized: "Done"), action: done).buttonStyle(.suPrimary)
            }
            .padding(.horizontal, SUSpacing.screenMargin)
            .padding(.vertical, SUSpacing.lg)
            .frame(maxWidth: SUMetrics.readableWidth)
            .frame(maxWidth: .infinity)
        }
        .suScreenBackground()
        .navigationTitle(String(localized: "Final split"))
    }

    private func payerLine(_ summary: ReceiptRoomSummary) -> String {
        guard let payer = summary.room.payerID else { return "" }
        if payer == summary.actorID { return String(localized: "You paid. Others owe you their share.") }
        return String(localized: "\(summary.name(payer)) paid. Your share is below.")
    }
}
