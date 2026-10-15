import SwiftUI

/// "Find a person" in the invitation sheet: find someone who already uses Square Up by an email
/// address or phone number you know, then invite them. They see the invitation in their Groups tab
/// and join only if they accept; until then nothing about the group changes. Below it, the
/// invitations you sent (the owner sees everyone's), with Cancel while they wait.
struct FindPersonView: View {
    @State private var model: FindPersonModel
    @FocusState private var focus: Field?

    enum Field: Hashable { case person }

    init(groupID: GroupID, service: SharedGroupsService) {
        self.init(model: FindPersonModel(groupID: groupID, service: service))
    }

    /// A model already in some state (previews and snapshot tests).
    init(model: FindPersonModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: SUSpacing.md) {
            Text(String(localized: "Invite someone who already uses Square Up. They'll see your invitation in their Groups tab and join only if they accept."))
                .font(SUFont.body)
                .foregroundStyle(SUColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker(String(localized: "Find by"), selection: $model.kind) {
                Text(String(localized: "Email")).tag(PersonIdentifier.Kind.email)
                Text(String(localized: "Phone number")).tag(PersonIdentifier.Kind.phone)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("findPerson.kind")
            field(model)
            Button {
                focus = nil
                Task { await model.search() }
            } label: {
                SUProgressLabel(title: String(localized: "Find"), workingTitle: String(localized: "Finding…"), isWorking: model.phase == .searching)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.suPrimary)
            .disabled(model.isBusy || model.check == .empty)
            .accessibilityIdentifier("findPerson.search")
            result(model)
            Label(String(localized: """
            Only people who confirmed this email or number with their Square Up account can be found. They see your name and \
            the group's name before deciding.
            """), systemImage: "lock")
                .font(SUFont.metadata)
                .foregroundStyle(SUColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            sentList(model)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await model.loadSent() }
    }

    @ViewBuilder
    private func field(_ model: FindPersonModel) -> some View {
        @Bindable var model = model
        let isEmail = model.kind == .email
        SUFormField(label: isEmail ? String(localized: "Their email address") : String(localized: "Their phone number"), text: $model.text,
                    symbol: isEmail ? "envelope" : "phone", contentType: isEmail ? .emailAddress : .telephoneNumber,
                    keyboard: isEmail ? .emailAddress : .phonePad, submitLabel: .search, issue: model.issue, identifier: "findPerson.field",
                    focus: $focus, field: .person) {
            Task { await model.search() }
        }
        if !isEmail {
            Text(String(localized: "A number in \(model.region.name()), or start with + and the country code."))
                .font(SUFont.metadata)
                .foregroundStyle(SUColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func result(_ model: FindPersonModel) -> some View {
        switch model.phase {
        case .idle, .searching:
            EmptyView()
        case .noMatch:
            SUInlineStatus(text: String(localized: "No Square Up account matches that. Check it, or share an invitation link instead."),
                           identifier: "findPerson.noMatch")
        case .found(let match, _), .sending(let match, _):
            matchCard(match, model: model)
        case .sent(let invitation):
            SUConfirmationBanner(title: String(localized: "Invitation sent to \(invitation.displayName)"),
                                 message: String(localized: "They'll see it in their Groups tab, and join only if they accept."),
                                 systemImage: "paperplane.fill", tone: .positive)
                .accessibilityIdentifier("findPerson.sent")
            Button(String(localized: "Find someone else")) {
                model.startOver()
                focus = .person
            }
            .frame(minHeight: 44)
            .accessibilityIdentifier("findPerson.again")
        case .failed(let message):
            SUInlineStatus(text: message, identifier: "findPerson.error")
        }
    }

    private func matchCard(_ match: PersonMatchDTO, model: FindPersonModel) -> some View {
        SUCard {
            VStack(alignment: .leading, spacing: SUSpacing.sm) {
                HStack(spacing: SUSpacing.sm) {
                    Text(PersonIdentity.initials(for: match.displayName))
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(SUColor.textPrimary)
                        .frame(width: 40, height: 40)
                        .background(SUColor.accent.opacity(0.24), in: Circle())
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: SUSpacing.xxs) {
                        Text(match.displayName)
                            .font(SUFont.body.weight(.semibold))
                            .foregroundStyle(SUColor.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(match.maskedIdentifier)
                            .font(SUFont.metadata.monospaced())
                            .foregroundStyle(SUColor.textSecondary)
                            .accessibilityLabel(String(localized: "Matched \(match.maskedIdentifier)"))
                    }
                    Spacer(minLength: 0)
                }
                switch match.status {
                case "available":
                    Button {
                        Task { await model.invite() }
                    } label: {
                        SUProgressLabel(title: String(localized: "Invite to group"), workingTitle: String(localized: "Sending…"), isWorking: model.isBusy)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.suPrimary)
                    .disabled(model.isBusy)
                    .accessibilityIdentifier("findPerson.invite")
                case "invited":
                    note(String(localized: "They already have an invitation to this group."), systemImage: "hourglass")
                case "member":
                    note(String(localized: "They're already in this group."), systemImage: "person.fill.checkmark")
                case "you":
                    note(String(localized: "That's you."), systemImage: "person.crop.circle")
                default:
                    EmptyView()
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("findPerson.match")
    }

    private func note(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(SUFont.supporting)
            .foregroundStyle(SUColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("findPerson.matchNote")
    }

    @ViewBuilder
    private func sentList(_ model: FindPersonModel) -> some View {
        if let error = model.listError {
            SUInlineStatus(text: error, identifier: "findPerson.listError")
        }
        if !model.sentInvitations.isEmpty {
            VStack(alignment: .leading, spacing: SUSpacing.xs) {
                Text(String(localized: "Invitations sent"))
                    .font(SUFont.supporting.weight(.semibold))
                    .foregroundStyle(SUColor.textSecondary)
                    .accessibilityAddTraits(.isHeader)
                SUCard {
                    VStack(spacing: 0) {
                        ForEach(model.sentInvitations) { invitation in
                            sentRow(invitation, model: model)
                            if invitation.id != model.sentInvitations.last?.id { Divider() }
                        }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("findPerson.sentList")
        }
    }

    private func sentRow(_ invitation: SentInvitationDTO, model: FindPersonModel) -> some View {
        HStack(spacing: SUSpacing.sm) {
            VStack(alignment: .leading, spacing: SUSpacing.xxs) {
                Text(invitation.displayName)
                    .font(SUFont.body.weight(.semibold))
                    .foregroundStyle(SUColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Label(Self.statusText(invitation), systemImage: Self.statusSymbol(invitation.status))
                    .font(SUFont.metadata)
                    .foregroundStyle(SUColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: SUSpacing.xs)
            if invitation.status == "pending" {
                Button(String(localized: "Cancel"), role: .destructive) { Task { await model.cancel(invitation) } }
                    .frame(minHeight: 44)
                    .disabled(model.cancelling.contains(invitation.id))
                    .accessibilityLabel(String(localized: "Cancel the invitation to \(invitation.displayName)"))
                    .accessibilityIdentifier("findPerson.cancel")
            }
        }
        .padding(.vertical, SUSpacing.xs)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("findPerson.sentRow.\(invitation.displayName)")
    }

    static func statusText(_ invitation: SentInvitationDTO) -> String {
        switch invitation.status {
        case "pending": String(localized: "Waiting for an answer · \(invitation.maskedIdentifier)")
        case "accepted": String(localized: "Joined")
        case "declined": String(localized: "Declined")
        case "cancelled": String(localized: "Cancelled")
        default: String(localized: "Expired")
        }
    }

    static func statusSymbol(_ status: String) -> String {
        switch status {
        case "pending": "hourglass"
        case "accepted": "checkmark.circle.fill"
        case "declined": "xmark.circle"
        case "cancelled": "minus.circle"
        default: "clock.badge.xmark"
        }
    }
}
