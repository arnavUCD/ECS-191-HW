import SwiftUI

/// Before saving a shared room as an expense, the host says who each guest is (milestone 4 §13):
/// an existing group member, or a new member added to the group. A display name alone never
/// decides this — the host does. Matching is stored on this device only.
struct GuestMatchingSheet: View {
    let flow: ReceiptFlowModel
    let session: RemoteRoomLedger
    @Environment(\.dismiss) private var dismiss
    @State private var groupMembers: [Member] = []
    @State private var error: String?

    private var sharing: SharingService { flow.environment.sharing }
    private var record: SharedRoomDirectory.Record? { sharing.directory.record(session.roomID) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(String(localized: "Guests joined with just a name. Choose who they are in your group so balances stay right."))
                        .font(SUFont.supporting).foregroundStyle(SUColor.textSecondary)
                }
                .suListRows()
                ForEach(guests, id: \.id) { guest in
                    Section(guest.displayName) {
                        let linked = record?.guestLinks[guest.id]
                        ForEach(candidates(for: guest)) { member in
                            Button {
                                sharing.match(guest: guest.id, to: member.id, in: session.roomID)
                            } label: {
                                HStack {
                                    Text(String(localized: "\(guest.displayName) is \(member.displayName)")).foregroundStyle(SUColor.textPrimary)
                                    Spacer()
                                    if linked == member.id { Image(systemName: "checkmark").foregroundStyle(SUColor.accent) }
                                }
                            }
                            .accessibilityAddTraits(linked == member.id ? .isSelected : [])
                        }
                        Button {
                            Task { await add(guest) }
                        } label: {
                            Label(String(localized: "Add \(guest.displayName) to the group"), systemImage: "person.badge.plus")
                        }
                        if linked != nil {
                            Button(String(localized: "Clear match"), role: .destructive) { sharing.unmatch(guest: guest.id, in: session.roomID) }
                        }
                    }
                    .suListRows()
                }
                if let error {
                    Section { Text(error).foregroundStyle(SUColor.negative) }
                        .suListRows()
                }
            }
            .scrollContentBackground(.hidden)
            .suScreenBackground()
            .navigationTitle(String(localized: "Match guests"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(String(localized: "Done")) { dismiss() } }
            }
            .task { await loadMembers() }
        }
    }

    /// Every guest in the room (matched or not), so a match can be changed until the room is saved.
    private var guests: [ParticipantDTO] {
        (session.base?.participants ?? []).filter { $0.kind == "guest" && !$0.removed }
    }

    /// Group members who aren't already in the room as themselves, and aren't another guest's match.
    private func candidates(for guest: ParticipantDTO) -> [Member] {
        let inRoom = Set((session.base?.participants ?? []).filter { $0.kind != "guest" }.map { RemoteRoomMapper.member($0.id) })
        let taken = Set((record?.guestLinks ?? [:]).filter { $0.key != guest.id }.values)
        return groupMembers.filter { !inRoom.contains($0.id) && !taken.contains($0.id) }
    }

    private func loadMembers() async {
        guard let snapshot = try? await flow.environment.sharing.localSnapshot(),
              let group = record?.groupID.flatMap(snapshot.group) else { return }
        groupMembers = snapshot.members(of: group).filter { group.isActiveMember($0.id) }
    }

    private func add(_ guest: ParticipantDTO) async {
        do {
            try await sharing.addGuestToGroup(guest, roomID: session.roomID)
            await loadMembers()
        } catch {
            self.error = LedgerErrorMessages.text(for: error)
        }
    }
}
