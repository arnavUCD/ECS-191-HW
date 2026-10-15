import SwiftUI

/// Room setup (§13.2 screen 6): choose who is at the table, then open the room for claims.
struct RoomSetupView: View {
    let flow: ReceiptFlowModel
    @State private var selected: [MemberID] = []
    @State private var isWorking = false
    @Environment(\.locale) private var locale

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SUSpacing.lg) {
                if let room = flow.room, let group = flow.group, let snapshot = flow.snapshot {
                    SUCard {
                        VStack(alignment: .leading, spacing: SUSpacing.xs) {
                            Text(room.title).font(SUFont.sectionTitle).foregroundStyle(SUColor.textPrimary)
                            if let total = room.receipt.total.value {
                                SUAmountView(money: total, style: .large)
                            }
                            Text(String(localized: "\(group.name) · paid by \(room.payerID.flatMap { snapshot.members[$0]?.displayName } ?? "")"))
                                .font(SUFont.supporting).foregroundStyle(SUColor.textSecondary)
                            Text(ReceiptLanguage.reviewStatement(ReceiptValidator.reconcile(room.receipt), locale: locale))
                                .font(SUFont.metadata).foregroundStyle(SUColor.textSecondary)
                        }
                    }
                    VStack(alignment: .leading, spacing: SUSpacing.xs) {
                        SUSectionHeader(title: String(localized: "Who's at the table?"),
                                        subtitle: String(localized: "Each person claims what they had. You can change this later."))
                        SUCard(padding: SUSpacing.xs) {
                            VStack(spacing: 0) {
                                ForEach(snapshot.activeMembers(of: group)) { member in
                                    SUUserPickerRow(member: member, detail: member.handle.map { "@\($0)" }, isCurrentUser: member.id == snapshot.currentUserID,
                                                    isSelected: selected.contains(member.id)) { toggle(member.id) }
                                        .accessibilityIdentifier("setup.member.\(member.firstName)")
                                }
                            }
                        }
                    }
                    if let error = flow.errorMessage {
                        SUConfirmationBanner(title: String(localized: "Not opened"), message: error, systemImage: "exclamationmark.triangle.fill", tone: .negative)
                    }
                    Label(String(localized: "Local prototype: everyone claims on this iPhone by switching who's acting. Nothing is sent to other devices."),
                          systemImage: "iphone")
                        .font(SUFont.metadata).foregroundStyle(SUColor.textSecondary)
                    Button {
                        open(room)
                    } label: {
                        Label(String(localized: "Open room"), systemImage: "hand.raised").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.suPrimary)
                    .disabled(selected.isEmpty || isWorking)
                    .accessibilityIdentifier("setup.open")
                    Button(String(localized: "Back to review")) {
                        Task { await flow.run(.reopenReview(room.id, expectedRevision: room.revision), asHost: true) }
                    }
                    .buttonStyle(.suSecondary)
                }
            }
            .padding(.horizontal, SUSpacing.screenMargin)
            .padding(.vertical, SUSpacing.lg)
            .frame(maxWidth: SUMetrics.readableWidth)
            .frame(maxWidth: .infinity)
        }
        .suScreenBackground()
        .navigationTitle(String(localized: "Set up room"))
        .onAppear { if selected.isEmpty { selected = flow.room?.participantIDs ?? [] } }
    }

    private func toggle(_ id: MemberID) {
        if let index = selected.firstIndex(of: id) { selected.remove(at: index) } else { selected.append(id) }
    }

    private func open(_ room: ReceiptRoom) {
        isWorking = true
        Task {
            await flow.run(.openRoom(room.id, expectedRevision: room.revision, participants: selected), asHost: true)
            isWorking = false
        }
    }
}
