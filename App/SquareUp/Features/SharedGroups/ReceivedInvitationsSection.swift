import SwiftUI

/// Invitations someone in a shared group sent to this account ("Find a person"), at the top of
/// Groups: "Maya invited you to Dinner Squad", with Accept and Decline. Each shows only what a code
/// invitation's preview shows (the group's name, who invited you, how many people are in it), and
/// nothing changes until you answer. Accepting opens the group; declining asks first.
struct ReceivedInvitationsSection: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppRouter.self) private var router
    @Environment(\.locale) private var locale
    @State private var answering: String?
    @State private var errors: [String: String] = [:]
    @State private var declining: ReceivedInvitationDTO?

    var body: some View {
        let invitations = environment.sharedGroups.receivedInvitations
        if !invitations.isEmpty {
            VStack(alignment: .leading, spacing: SUSpacing.sm) {
                SUSectionHeader(title: String(localized: "Invitations"), subtitle: String(localized: "You join a group only if you accept."))
                ForEach(invitations) { card($0) }
            }
            .padding(.bottom, SUSpacing.sm)
            .confirmationDialog(declineTitle, isPresented: Binding(get: { declining != nil }, set: { if !$0 { declining = nil } }),
                                titleVisibility: .visible, presenting: declining) { invitation in
                Button(String(localized: "Decline"), role: .destructive) { Task { await decline(invitation) } }
                    .accessibilityIdentifier("receivedInvitation.confirmDecline")
            } message: { invitation in
                Text(String(localized: "\(invitation.inviterName) will see that you declined. They can invite you again later."))
            }
        }
    }

    private var declineTitle: String {
        declining.map { String(localized: "Decline the invitation to \($0.groupName)?") } ?? ""
    }

    private func card(_ invitation: ReceivedInvitationDTO) -> some View {
        let isAnswering = answering == invitation.id
        return SUCard {
            VStack(alignment: .leading, spacing: SUSpacing.sm) {
                HStack(alignment: .top, spacing: SUSpacing.sm) {
                    Image(systemName: invitation.symbol)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(SUColor.accent)
                        .frame(width: 44, height: 44)
                        .background(SUColor.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: SUSpacing.xxs) {
                        Text(String(localized: "\(invitation.inviterName) invited you to \(invitation.groupName)"))
                            .font(SUFont.body.weight(.semibold))
                            .foregroundStyle(SUColor.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(details(invitation))
                            .font(SUFont.metadata)
                            .foregroundStyle(SUColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                if let error = errors[invitation.id] {
                    SUInlineStatus(text: error, identifier: "receivedInvitation.error")
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: SUSpacing.sm) { buttons(invitation, isAnswering: isAnswering) }
                    VStack(spacing: SUSpacing.xs) { buttons(invitation, isAnswering: isAnswering) }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("receivedInvitation.\(invitation.groupName)")
    }

    @ViewBuilder
    private func buttons(_ invitation: ReceivedInvitationDTO, isAnswering: Bool) -> some View {
        Button(String(localized: "Decline")) { declining = invitation }
            .buttonStyle(.suSecondary)
            .frame(maxWidth: .infinity)
            .disabled(answering != nil)
            .accessibilityLabel(String(localized: "Decline the invitation to \(invitation.groupName)"))
            .accessibilityIdentifier("receivedInvitation.decline")
        Button {
            Task { await accept(invitation) }
        } label: {
            SUProgressLabel(title: String(localized: "Accept"), workingTitle: String(localized: "Joining…"), isWorking: isAnswering)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.suPrimary)
        .disabled(answering != nil)
        .accessibilityLabel(String(localized: "Accept and join \(invitation.groupName)"))
        .accessibilityIdentifier("receivedInvitation.accept")
    }

    private func details(_ invitation: ReceivedInvitationDTO) -> String {
        let people = Inflect.string("^[\(invitation.memberCount) member](inflect: true)")
        guard let expires = RemoteRoomMapper.timestamp(invitation.expiresAt) else { return "\(people) · \(invitation.currency)" }
        return String(localized: "\(people) · \(invitation.currency) · until \(expires.formatted(.dateTime.month(.abbreviated).day().locale(locale)))")
    }

    private func accept(_ invitation: ReceivedInvitationDTO) async {
        answering = invitation.id
        errors[invitation.id] = nil
        defer { answering = nil }
        do {
            let groupID = try await environment.sharedGroups.accept(invitation)
            AccessibilityNotification.Announcement(String(localized: "You joined \(invitation.groupName)")).post()
            router.showGroup(groupID)
        } catch {
            errors[invitation.id] = LedgerErrorMessages.text(for: error)
            AccessibilityNotification.Announcement(errors[invitation.id] ?? "").post()
        }
    }

    private func decline(_ invitation: ReceivedInvitationDTO) async {
        answering = invitation.id
        errors[invitation.id] = nil
        defer { answering = nil }
        do {
            try await environment.sharedGroups.decline(invitation)
            AccessibilityNotification.Announcement(String(localized: "Invitation declined")).post()
        } catch {
            errors[invitation.id] = LedgerErrorMessages.text(for: error)
        }
    }
}
