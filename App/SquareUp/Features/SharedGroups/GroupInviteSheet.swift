import SwiftUI

/// One invitation to a shared group (milestone 7 §4): a QR code, a short code to copy, the HTTPS
/// link, and the app link — without Associated Domains or an App Clip. Opened with no invitation,
/// it makes a new single-use one; opened with one, it shows that invitation's state and details.
///
/// The HTTPS link opens an ordinary web page (it is *not* a universal link in this build) that
/// shows the code and an "Open Square Up" button. The code is a secret: the server returns it once
/// and stores only a digest; this iPhone keeps it in the Keychain so the owner can show an unused
/// invitation again. It is never logged. Each invitation works for one account.
///
/// A new invitation can instead go to one person found by their email or phone ("Find a person",
/// `FindPersonView`), which anyone in the group can do; only the owner makes links and codes.
struct GroupInviteSheet: View {
    enum Mode: Hashable {
        /// A single-use link, QR code, and code (the owner only).
        case link
        /// Find someone who uses Square Up by email or phone, and invite them.
        case person
    }

    let groupID: GroupID
    /// A named place from a published group, for one specific person (their history stays theirs).
    let seat: Member?
    /// An existing invitation to show; `nil` makes a new one.
    var existing: GroupInvitationDTO?
    /// Names for "Accepted by …".
    var members: [MemberID: Member] = [:]
    /// Where a new invitation starts.
    var mode: Mode = .link
    /// Only the owner makes links and codes; anyone in the group can find a person.
    var canMakeLinks = true
    /// Called after an invitation is made or turned off, so the list can refresh.
    var onChange: () -> Void = {}
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var invitation: GroupInvitationDTO?
    @State private var link: SharedGroupsService.InvitationLink?
    @State private var isWorking = false
    @State private var error: String?
    @State private var copied = false
    @State private var chosenMode: Mode?

    /// A new invitation to anyone (not an existing one, not a named place) can be either kind.
    private var offersModes: Bool { existing == nil && seat == nil }
    private var currentMode: Mode {
        guard offersModes else { return .link }
        return canMakeLinks ? chosenMode ?? mode : .person
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: SUSpacing.lg) {
                    if offersModes, canMakeLinks {
                        Picker(String(localized: "How to invite"), selection: Binding(get: { currentMode }, set: { chosenMode = $0 })) {
                            Text(String(localized: "Link or QR code")).tag(Mode.link)
                            Text(String(localized: "Find a person")).tag(Mode.person)
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("groupInvite.mode")
                    }
                    if currentMode == .person {
                        FindPersonView(groupID: groupID, service: environment.sharedGroups)
                    } else {
                        linkContent
                    }
                }
                .padding(.horizontal, SUSpacing.screenMargin)
                .padding(.vertical, SUSpacing.lg)
                .frame(maxWidth: SUMetrics.readableWidth)
                .frame(maxWidth: .infinity)
            }
            .suScreenBackground()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) { dismiss() }.accessibilityIdentifier("groupInvite.done")
                }
            }
        }

        .task(id: currentMode) {
            // A link is made only when it's asked for: opening on "Find a person" makes none.
            guard invitation == nil, !isWorking else { return }
            if let existing {
                invitation = existing
                link = environment.sharedGroups.savedLink(for: existing.invitationId)
            } else if currentMode == .link {
                await create()
            }
        }
    }

    @ViewBuilder
    private var linkContent: some View {
        if let invitation {
            let state = invitation.state(at: environment.now)
            if state == .unused { Text(intro).font(SUFont.body).foregroundStyle(SUColor.textSecondary).multilineTextAlignment(.center) }
            if state == .unused, let link, let url = URL(string: link.url) {
                shareable(code: link.code, url: url)
            } else if state == .unused {
                SUInlineStatus(text: String(localized: """
                This invitation's code was shown on the iPhone that made it. Turn it off and make a new one if you need \
                to send it again.
                """), identifier: "groupInvite.codeUnavailable")
            }
            details(invitation, state: state)
        } else if isWorking {
            ProgressView(String(localized: "Making an invitation…")).padding(.vertical, SUSpacing.xl)
        }
        if let error {
            SUConfirmationBanner(title: String(localized: "Something went wrong"), message: error,
                                 systemImage: "exclamationmark.triangle.fill", tone: .negative,
                                 actionTitle: invitation == nil ? String(localized: "Try again") : nil) { Task { await create() } }
                .accessibilityIdentifier("groupInvite.error")
        }
    }

    private var title: String {
        if existing != nil { return String(localized: "Invitation") }
        if let seat { return String(localized: "Invite \(seat.displayName)") }
        return canMakeLinks ? String(localized: "Invite people") : String(localized: "Invite someone")
    }

    private var intro: String {
        if let seat {
            return String(localized: "Send this to \(seat.displayName) only. When they accept, they take their place in the group with everything already recorded for them.")
        }
        return String(localized: "Send this to one person. It works once, for one account. Make another invitation for each person you invite.")
    }

    @ViewBuilder
    private func shareable(code: String, url: URL) -> some View {
        QRCodeView(text: url.absoluteString)
            .frame(maxWidth: 240)
            .accessibilityLabel(String(localized: "QR code for the invitation"))
            .accessibilityHint(String(localized: "The same invitation as the code below."))
            .accessibilityIdentifier("groupInvite.qr")
        VStack(spacing: SUSpacing.xs) {
            Text(String(localized: "Invitation code")).font(SUFont.metadata).foregroundStyle(SUColor.textSecondary)
            Text(code)
                .font(.title3.monospaced().weight(.semibold))
                .foregroundStyle(SUColor.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(String(localized: "Invitation code"))
                .accessibilityValue(code.map { String($0) }.joined(separator: " "))
                .accessibilityIdentifier("groupInvite.code")
        }
        Button {
            UIPasteboard.general.string = code
            copied = true
            AccessibilityNotification.Announcement(String(localized: "Code copied")).post()
        } label: {
            Label(copied ? String(localized: "Code copied") : String(localized: "Copy code"), systemImage: copied ? "checkmark" : "doc.on.doc")
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.suSecondary)
        .accessibilityIdentifier("groupInvite.copyCode")
        ShareLink(item: url, subject: Text(String(localized: "Join my group on Square Up")),
                  message: Text(String(localized: "Open the link, or paste code \(code) in Square Up → Groups → Join with a code."))) {
            Label(String(localized: "Share invitation"), systemImage: "square.and.arrow.up").frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.suPrimary)
        .accessibilityIdentifier("groupInvite.share")
    }

    private func details(_ invitation: GroupInvitationDTO, state: InvitationState) -> some View {
        VStack(alignment: .leading, spacing: SUSpacing.sm) {
            InvitationStateLabel(invitation: invitation, state: state, members: members)
                .font(SUFont.body.weight(.semibold))
            if let created = RemoteRoomMapper.timestamp(invitation.createdAt) {
                Label(String(localized: "Made \(created.formatted(date: .abbreviated, time: .shortened))"), systemImage: "calendar")
            }
            if state == .unused, let expires = RemoteRoomMapper.timestamp(invitation.expiresAt) {
                Label(String(localized: "Works until \(expires.formatted(date: .abbreviated, time: .shortened)), once."), systemImage: "clock")
            }
            if state == .unused {
                Label(String(localized: """
                Before joining they see only the group's name, the owner's name, how many people are in it, its currency, and \
                when this invitation expires.
                """), systemImage: "eye")
                Label(String(localized: """
                The link opens a web page with the code and an Open Square Up button. In Square Up, they can also paste the code \
                in Groups → Join with a code.
                """),
                systemImage: "link")
                Button(String(localized: "Turn off this invitation"), role: .destructive) { Task { await revoke(invitation) } }
                    .frame(minHeight: 44)
                    .disabled(isWorking)
                    .accessibilityIdentifier("groupInvite.revoke")
            }
            if existing == nil, seat == nil {
                Button {
                    Task { await create() }
                } label: {
                    Label(String(localized: "Make another invitation"), systemImage: "plus").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.suSecondary)
                .disabled(isWorking)
                .accessibilityHint(String(localized: "This one keeps working. Use a new one for each person."))
                .accessibilityIdentifier("groupInvite.another")
            }
        }
        .font(SUFont.supporting)
        .foregroundStyle(SUColor.textSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("groupInvite.details")
    }

    private func create() async {
        isWorking = true
        error = nil
        defer { isWorking = false }
        do {
            let made = try await environment.sharedGroups.createInvitation(for: groupID, seat: seat?.id)
            invitation = made
            link = made.code.flatMap { code in made.url.map { SharedGroupsService.InvitationLink(code: code, url: $0, appUrl: made.appUrl) } }
            copied = false
            onChange()
        } catch {
            self.error = LedgerErrorMessages.text(for: error)
        }
    }

    private func revoke(_ invitation: GroupInvitationDTO) async {
        isWorking = true
        error = nil
        defer { isWorking = false }
        do {
            self.invitation = try await environment.sharedGroups.revokeInvitation(invitation.invitationId, in: groupID)
            link = nil
            onChange()
            AccessibilityNotification.Announcement(String(localized: "Invitation turned off")).post()
        } catch {
            self.error = LedgerErrorMessages.text(for: error)
        }
    }
}

/// "Waiting to be accepted", "Accepted by Maya", "Expired", or "Turned off" — with an icon, never
/// color alone.
struct InvitationStateLabel: View {
    let invitation: GroupInvitationDTO
    let state: InvitationState
    let members: [MemberID: Member]

    var body: some View {
        Label {
            Text(text).foregroundStyle(SUColor.textPrimary)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .accessibilityIdentifier("invitation.state")
    }

    private var text: String {
        switch state {
        case .unused: String(localized: "Waiting to be accepted")
        case .accepted:
            if let name = invitation.acceptedMemberId.flatMap(MemberID.init(string:)).flatMap({ members[$0]?.displayName }) {
                String(localized: "Accepted by \(name)")
            } else {
                String(localized: "Accepted")
            }
        case .expired: String(localized: "Expired")
        case .revoked: String(localized: "Turned off")
        }
    }

    private var symbol: String {
        switch state {
        case .unused: "hourglass"
        case .accepted: "checkmark.circle.fill"
        case .expired: "clock.badge.xmark"
        case .revoked: "xmark.circle"
        }
    }

    private var tint: Color {
        switch state {
        case .unused: SUColor.warning
        case .accepted: SUColor.positive
        case .expired, .revoked: SUColor.textSecondary
        }
    }
}
