import SwiftUI

/// People in a shared group (milestone 7 §3): the owner, everyone who joined and how each stands,
/// and — for the owner — invitations waiting to be accepted and ones that ended, kept apart.
/// The owner invites, turns invitations off, removes people, hands over ownership, and archives;
/// anyone else can leave. Every one of these needs the server's answer before it shows as done
/// (§7.4); the server enforces every rule (balances, payments in progress, the 25-person limit).
struct SharedGroupMembersSection: View {
    let ledger: SharedGroupLedger
    let summary: GroupDetailSummary
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var sheet: InviteSheet?
    @State private var confirmation: Confirmation?
    @State private var invitations: [GroupInvitationDTO] = []
    @State private var invitationsError: String?
    @State private var error: String?
    @State private var isWorking = false

    struct InviteSheet: Identifiable {
        let seat: Member?
        let existing: GroupInvitationDTO?
        var mode: GroupInviteSheet.Mode = .link
        var id: String { existing?.invitationId ?? seat.map { SharedGroupMapper.id($0.id) } ?? "new.\(mode)" }
    }

    enum Confirmation: Identifiable {
        case remove(Member)
        case makeOwner(Member)
        case leave
        case archive

        var id: String {
            switch self {
            case .remove(let member): "remove.\(member.id)"
            case .makeOwner(let member): "owner.\(member.id)"
            case .leave: "leave"
            case .archive: "archive"
            }
        }
    }

    private var people: GroupPeople {
        GroupPeople.make(summary: summary, ownerID: ledger.ownerID, status: ledger.status(of:), invitations: invitations, now: environment.now)
    }

    var body: some View {
        let people = people
        VStack(alignment: .leading, spacing: SUSpacing.lg) {
            peopleSection(people)
            if !people.waitingPlaces.isEmpty { waitingPlacesSection(people) }
            if environment.isDemoWorkspace {
                // Demo Mode: its people are fictional, and no real person can be invited into it.
                Label(String(localized: "Everyone in this demo group is fictional. Inviting people is off in the demo."), systemImage: "theatermasks")
                    .font(SUFont.supporting)
                    .foregroundStyle(SUColor.textSecondary)
                    .accessibilityIdentifier("sharedGroup.demoInvitations")
            } else {
                if ledger.isOwner, !ledger.isArchived { invitationsSection(people) }
                if !ledger.isOwner, !ledger.isArchived { findPersonSection(people) }
            }
            if !people.former.isEmpty { formerSection(people) }
            if let error {
                SUInlineStatus(text: error, identifier: "sharedGroup.membershipError")
            }
            groupActions(people)
        }
        .sheet(item: $sheet) { target in
            GroupInviteSheet(groupID: ledger.groupID, seat: target.seat, existing: target.existing, members: summary.memberLookup,
                             mode: target.mode, canMakeLinks: ledger.isOwner) {
                Task { await loadInvitations() }
            }
            .environment(environment)
        }
        .confirmationDialog(confirmationTitle, isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }),
                            titleVisibility: .visible, presenting: confirmation) { item in
            Button(confirmationButton(item), role: .destructive) { Task { await perform(item) } }
                .accessibilityIdentifier("sharedGroup.confirm")
        } message: { item in
            Text(confirmationMessage(item))
        }
        .disabled(isWorking)
        .task(id: ledger.revision) { await loadInvitations() }
    }

    // MARK: - Sections

    private func peopleSection(_ people: GroupPeople) -> some View {
        VStack(alignment: .leading, spacing: SUSpacing.sm) {
            SUSectionHeader(title: String(localized: "People"),
                            subtitle: String(localized: "\(people.activeCount) of \(GroupPeople.memberLimit) people"))
            SUCard {
                VStack(spacing: 0) {
                    let everyone = (people.owner.map { [$0] } ?? []) + people.members
                    ForEach(everyone) { person in
                        row(person)
                        if person.id != everyone.last?.id { Divider() }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("sharedGroup.people")
        }
    }

    private func row(_ person: GroupPeople.Person) -> some View {
        HStack(spacing: SUSpacing.sm) {
            SUAvatar(member: person.member, size: .medium, isCurrentUser: person.isYou)
            VStack(alignment: .leading, spacing: SUSpacing.xxs) {
                Text(person.member.displayName).font(SUFont.body.weight(.semibold)).foregroundStyle(SUColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: SUSpacing.xs) {
                    if person.isYou { SURoleBadge(kind: .you) }
                    if person.isOwner { SURoleBadge(kind: .owner) }
                }
                Text(standing(person))
                    .font(SUFont.metadata)
                    .foregroundStyle(SUColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("sharedGroup.standing")
                let methods = ledger.providers(of: person.member.id)
                if !methods.isEmpty {
                    Text(String(localized: "Accepts \(methods.map(\.displayName).formatted(.list(type: .or)))"))
                        .font(SUFont.metadata).foregroundStyle(SUColor.textSecondary)
                }
            }
            Spacer(minLength: SUSpacing.xs)
            if ledger.isOwner, !ledger.isArchived, !person.isYou {
                Menu {
                    Button(String(localized: "Make owner"), systemImage: "key") { confirmation = .makeOwner(person.member) }
                    Button(String(localized: "Remove from group"), systemImage: "person.badge.minus", role: .destructive) {
                        confirmation = .remove(person.member)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel(String(localized: "Options for \(person.member.displayName)"))
                .accessibilityIdentifier("sharedGroup.memberOptions")
            }
        }
        .padding(.vertical, SUSpacing.xs)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sharedGroup.person.\(person.member.displayName)")
    }

    private func standing(_ person: GroupPeople.Person) -> String {
        let text: String
        switch person.standing {
        case .settled:
            text = String(localized: "Settled up")
        case .owes(let amount):
            let money = MoneyFormatting.string(amount, locale: locale)
            text = person.isYou ? String(localized: "You owe \(money)") : String(localized: "Owes \(money)")
        case .isOwed(let amount):
            let money = MoneyFormatting.string(amount, locale: locale)
            text = person.isYou ? String(localized: "You're owed \(money)") : String(localized: "Is owed \(money)")
        }
        return person.hasPaymentInProgress ? String(localized: "\(text) · payment in progress") : text
    }

    /// Named places from a group shared from this iPhone before invitations were per person.
    private func waitingPlacesSection(_ people: GroupPeople) -> some View {
        VStack(alignment: .leading, spacing: SUSpacing.sm) {
            SUSectionHeader(title: String(localized: "Places waiting for someone"),
                            subtitle: String(localized: "Named when this group was shared. Their invitation lets that person take the place and its history."))
            SUCard {
                VStack(spacing: 0) {
                    ForEach(people.waitingPlaces) { member in
                        HStack(spacing: SUSpacing.sm) {
                            SUAvatar(member: member, size: .medium, isCurrentUser: false)
                            VStack(alignment: .leading, spacing: SUSpacing.xxs) {
                                Text(member.displayName).font(SUFont.body.weight(.semibold)).foregroundStyle(SUColor.textPrimary)
                                SURoleBadge(kind: .waitingToJoin)
                            }
                            Spacer(minLength: SUSpacing.xs)
                            if ledger.isOwner, !ledger.isArchived {
                                Button(String(localized: "Invite")) { sheet = InviteSheet(seat: member, existing: nil) }
                                    .buttonStyle(.suSecondary)
                                    .accessibilityLabel(String(localized: "Invite \(member.displayName)"))
                                    .accessibilityIdentifier("sharedGroup.inviteSeat")
                                Menu {
                                    Button(String(localized: "Remove from group"), systemImage: "person.badge.minus", role: .destructive) {
                                        confirmation = .remove(member)
                                    }
                                } label: {
                                    Image(systemName: "ellipsis.circle").frame(minWidth: 44, minHeight: 44)
                                }
                                .accessibilityLabel(String(localized: "Options for \(member.displayName)"))
                            }
                        }
                        .padding(.vertical, SUSpacing.xs)
                        .accessibilityElement(children: .contain)
                        if member.id != people.waitingPlaces.last?.id { Divider() }
                    }
                }
            }
        }
    }

    private func invitationsSection(_ people: GroupPeople) -> some View {
        VStack(alignment: .leading, spacing: SUSpacing.sm) {
            SUSectionHeader(title: String(localized: "Invitations"),
                            subtitle: String(localized: "Each invitation works once, for one account, for 7 days."))
            Button {
                sheet = InviteSheet(seat: nil, existing: nil)
            } label: {
                Label(String(localized: "Invite people"), systemImage: "person.badge.plus").frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.suPrimary)
            .disabled(people.isFull)
            .accessibilityIdentifier("sharedGroup.invite")
            findPersonButton(people)
            if people.isFull {
                SUInlineStatus(text: String(localized: "This group has \(GroupPeople.memberLimit) people, its limit. Someone has to leave before anyone new can join."),
                               identifier: "sharedGroup.full")
            }
            if let invitationsError {
                SUInlineStatus(text: invitationsError, identifier: "sharedGroup.invitationsError")
            }
            if !people.awaiting.isEmpty {
                invitationList(String(localized: "Waiting to be accepted"), people.awaiting, identifier: "sharedGroup.awaiting")
            }
            if !people.ended.isEmpty {
                invitationList(String(localized: "Accepted, expired, or turned off"), people.ended, identifier: "sharedGroup.ended")
            }
        }
    }

    /// Anyone in the group can invite someone who uses Square Up by their email or phone number.
    private func findPersonButton(_ people: GroupPeople) -> some View {
        Button {
            sheet = InviteSheet(seat: nil, existing: nil, mode: .person)
        } label: {
            Label(String(localized: "Find a person"), systemImage: "magnifyingglass").frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.suSecondary)
        .disabled(people.isFull)
        .accessibilityHint(String(localized: "Invite someone who uses Square Up by their email or phone number."))
        .accessibilityIdentifier("sharedGroup.findPerson")
    }

    private func findPersonSection(_ people: GroupPeople) -> some View {
        VStack(alignment: .leading, spacing: SUSpacing.sm) {
            SUSectionHeader(title: String(localized: "Invite someone"),
                            subtitle: String(localized: "Find someone who uses Square Up by their email or phone number. They join only if they accept."))
            findPersonButton(people)
            if people.isFull {
                SUInlineStatus(text: String(localized: "This group has \(GroupPeople.memberLimit) people, its limit. Someone has to leave before anyone new can join."),
                               identifier: "sharedGroup.full")
            }
        }
    }

    private func invitationList(_ title: String, _ items: [GroupInvitationDTO], identifier: String) -> some View {
        VStack(alignment: .leading, spacing: SUSpacing.xs) {
            Text(title).font(SUFont.supporting.weight(.semibold)).foregroundStyle(SUColor.textSecondary)
                .accessibilityAddTraits(.isHeader)
            SUCard {
                VStack(spacing: 0) {
                    ForEach(items, id: \.invitationId) { invitation in
                        Button {
                            sheet = InviteSheet(seat: nil, existing: invitation)
                        } label: {
                            HStack(spacing: SUSpacing.sm) {
                                VStack(alignment: .leading, spacing: SUSpacing.xxs) {
                                    InvitationStateLabel(invitation: invitation, state: invitation.state(at: environment.now), members: summary.memberLookup)
                                        .font(SUFont.body)
                                    Text(invitationDates(invitation))
                                        .font(SUFont.metadata).foregroundStyle(SUColor.textSecondary)
                                }
                                Spacer(minLength: SUSpacing.xs)
                                Image(systemName: "chevron.right").font(SUFont.metadata).foregroundStyle(SUColor.textTertiary)
                                    .accessibilityHidden(true)
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, SUSpacing.xs)
                        .accessibilityIdentifier("sharedGroup.invitation")
                        if invitation.invitationId != items.last?.invitationId { Divider() }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(identifier)
        }
    }

    private func invitationDates(_ invitation: GroupInvitationDTO) -> String {
        let made = RemoteRoomMapper.timestamp(invitation.createdAt).map { $0.formatted(date: .abbreviated, time: .shortened) } ?? ""
        guard invitation.state(at: environment.now) == .unused, let expires = RemoteRoomMapper.timestamp(invitation.expiresAt) else {
            return String(localized: "Made \(made)")
        }
        return String(localized: "Made \(made) · expires \(expires.formatted(date: .abbreviated, time: .omitted))")
    }

    private func formerSection(_ people: GroupPeople) -> some View {
        VStack(alignment: .leading, spacing: SUSpacing.xs) {
            Text(String(localized: "Past members")).font(SUFont.supporting.weight(.semibold)).foregroundStyle(SUColor.textSecondary)
                .accessibilityAddTraits(.isHeader)
            Text(people.former.map(\.displayName).formatted(.list(type: .and)))
                .font(SUFont.supporting).foregroundStyle(SUColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(String(localized: "They no longer see this group. Their past expenses and payments stay in the history under their name."))
                .font(SUFont.metadata).foregroundStyle(SUColor.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sharedGroup.former")
    }

    @ViewBuilder
    private func groupActions(_ people: GroupPeople) -> some View {
        if !ledger.isArchived {
            if ledger.isOwner {
                if !people.members.isEmpty {
                    Text(String(localized: "To leave, first make someone else the owner from their options."))
                        .font(SUFont.metadata).foregroundStyle(SUColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(String(localized: "Archive group"), role: .destructive) { confirmation = .archive }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("sharedGroup.archive")
            } else {
                Button(String(localized: "Leave group"), role: .destructive) { confirmation = .leave }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("sharedGroup.leave")
            }
        }
    }

    // MARK: - Confirmations

    private var confirmationTitle: String {
        switch confirmation {
        case .remove(let member): String(localized: "Remove \(member.displayName)?")
        case .makeOwner(let member): String(localized: "Make \(member.displayName) the owner?")
        case .leave: String(localized: "Leave \(ledger.groupName)?")
        case .archive: String(localized: "Archive \(ledger.groupName)?")
        case nil: ""
        }
    }

    private func confirmationButton(_ item: Confirmation) -> String {
        switch item {
        case .remove: String(localized: "Remove")
        case .makeOwner: String(localized: "Make owner")
        case .leave: String(localized: "Leave")
        case .archive: String(localized: "Archive")
        }
    }

    private func confirmationMessage(_ item: Confirmation) -> String {
        switch item {
        case .remove:
            String(localized: """
            They can be removed only when they owe nothing, are owed nothing, and have no payment in progress. They'll lose \
            access; their past expenses stay in the history.
            """)
        case .makeOwner:
            String(localized: """
            They'll manage the group, its people, and its invitations. Invitations you made stop working. You stay a member. \
            This is recorded in the group's history.
            """)
        case .leave:
            String(localized: """
            You can leave only when your balance is zero and you have no payment in progress. You'll lose access; the group's \
            history keeps your name.
            """)
        case .archive:
            String(localized: """
            Only once everyone is settled up and no payment is in progress. Nothing new can be added and invitations stop \
            working. Everyone can still read the history.
            """)
        }
    }

    private func perform(_ item: Confirmation) async {
        isWorking = true
        error = nil
        defer { isWorking = false }
        do {
            switch item {
            case .remove(let member): try await ledger.perform(.removeMember(ledger.groupID, member.id), as: nil)
            case .makeOwner(let member): try await ledger.transferOwnership(to: member.id)
            case .leave:
                try await ledger.leave()
                await environment.sharedGroups.refreshGroups()
                dismiss()
            case .archive: try await ledger.archive()
            }
            AccessibilityNotification.Announcement(String(localized: "Done")).post()
        } catch {
            self.error = LedgerErrorMessages.text(for: error as? LedgerError ?? .unavailable, members: summary.memberLookup)
            AccessibilityNotification.Announcement(self.error ?? "").post()
        }
    }

    private func loadInvitations() async {
        guard ledger.isOwner else {
            invitations = []
            return
        }
        do {
            invitations = try await environment.sharedGroups.invitations(for: ledger.groupID)
            invitationsError = nil
        } catch {
            invitationsError = String(localized: "Couldn't load invitations. \(LedgerErrorMessages.text(for: error))")
        }
    }
}
