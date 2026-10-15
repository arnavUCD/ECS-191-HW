import SwiftUI

/// Joining a shared group (milestone 7 §4.3): enter or paste a code (or open a link), see the safe
/// preview, sign in if needed, confirm the name the group will see, and join — once. Every state
/// says what happened in words: expired, turned off, already used, already a member, archived,
/// offline, or needs an account.
struct JoinGroupView: View {
    let initialCode: String?
    /// Called with the joined (or already-joined) group so it can be opened.
    let onJoined: (GroupID) -> Void
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var codeText = ""
    @State private var code: String?
    @State private var preview: GroupInvitationPreviewDTO?
    @State private var displayName = ""
    @State private var phase: Phase = .entering
    @State private var accountSheet: AccountSheet.Mode?
    @AccessibilityFocusState private var messageFocused: Bool

    enum Phase: Equatable {
        case entering
        case loading
        case preview
        case joining
        case problem(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                switch phase {
                case .entering, .problem:
                    entry
                case .loading:
                    Section { ProgressView(String(localized: "Checking the invitation…")) }
                        .suListRows()
                case .preview, .joining:
                    if let preview { previewSections(preview) }
                }
                if case .problem(let message) = phase {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(SUColor.negative)
                            .accessibilityFocused($messageFocused)
                            .accessibilityIdentifier("joinGroup.problem")
                    }
                    .suListRows()
                }
            }
            .scrollContentBackground(.hidden)
            .suScreenBackground()
            .navigationTitle(String(localized: "Join a group"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(String(localized: "Cancel")) { dismiss() } }
            }
            .sheet(item: $accountSheet) { mode in AccountSheet(mode: mode) }
            .onChange(of: environment.sharedGroups.accountState) { _, _ in
                if displayName.isEmpty { displayName = environment.sharedGroups.profile?.displayName ?? "" }
            }
        }
        .task {
            displayName = environment.sharedGroups.profile?.displayName ?? ""
            if let initialCode, code == nil {
                codeText = SharedGroupsService.displayCode(initialCode)
                await check(initialCode)
            }
        }
    }

    // MARK: Entering a code

    private var entry: some View {
        Section {
            TextField(String(localized: "Code or link"), text: $codeText, axis: .vertical)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .font(.body.monospaced())
                .accessibilityIdentifier("joinGroup.code")
            Button(String(localized: "Paste")) {
                if let text = UIPasteboard.general.string { codeText = text }
            }
            .frame(minHeight: 44)
            Button(String(localized: "Continue")) { Task { await submitCode() } }
                .frame(minHeight: 44)
                .disabled(codeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("joinGroup.continue")
        } footer: {
            Text(String(localized: "Paste the code or link someone shared with you. Nothing is joined until you confirm."))
        }
        .suListRows()
    }

    private func submitCode() async {
        guard let parsed = SharedGroupsService.invitationCode(from: codeText, configuration: environment.sharedGroups.configuration) else {
            show(String(localized: "That doesn't look like a Square Up group invitation. Check the code and try again."))
            return
        }
        await check(parsed)
    }

    private func check(_ parsed: String) async {
        code = parsed
        phase = .loading
        do {
            preview = try await environment.sharedGroups.preview(parsed)
            phase = .preview
        } catch {
            show(message(for: error))
        }
    }

    // MARK: Preview and joining

    @ViewBuilder
    private func previewSections(_ preview: GroupInvitationPreviewDTO) -> some View {
        Section {
            HStack(spacing: SUSpacing.md) {
                Image(systemName: preview.symbol)
                    .font(.title2.weight(.semibold)).foregroundStyle(SUColor.accent)
                    .frame(width: 44, height: 44)
                    .background(SUColor.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: SUSpacing.xxs) {
                    Text(preview.groupName).font(SUFont.sectionTitle).foregroundStyle(SUColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text(String(localized: "\(preview.inviterName) invited you")).font(SUFont.supporting).foregroundStyle(SUColor.textSecondary)
                    if let owner = preview.ownerName, !owner.isEmpty, owner != preview.inviterName {
                        Text(String(localized: "Owner: \(owner)")).font(SUFont.supporting).foregroundStyle(SUColor.textSecondary)
                    }
                    Text(Inflect.string("^[\(preview.memberCount) person](inflect: true) · \(preview.currency)"))
                        .font(SUFont.metadata).foregroundStyle(SUColor.textTertiary)
                    if let expires = RemoteRoomMapper.timestamp(preview.expiresAt) {
                        Text(String(localized: "Invitation expires \(expires.formatted(date: .abbreviated, time: .shortened))"))
                            .font(SUFont.metadata).foregroundStyle(SUColor.textTertiary)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("joinGroup.preview")
        } footer: {
            Text(preview.isSeatInvitation
                ? String(localized: "This invitation is for one person already listed in the group. Accept it only if it was sent to you.")
                : String(localized: "You'll see the group's expenses and balances after you join."))
        }
        .suListRows()
        if preview.alreadyMember {
            Section {
                Button(String(localized: "Open the group")) { Task { await joinOrOpen() } }
                    .frame(minHeight: 44)
            } footer: {
                Text(LedgerErrorMessages.text(for: GroupInvitationIssue.alreadyMember))
            }
            .suListRows()
        } else {
            accountSection
        }
    }

    @ViewBuilder
    private var accountSection: some View {
        let groups = environment.sharedGroups
        switch groups.accountState {
        case .ready, .needsProfile:
            Section {
                TextField(String(localized: "Your name"), text: $displayName)
                    .textContentType(.name)
                    .accessibilityIdentifier("joinGroup.name")
                Button {
                    Task { await joinOrOpen() }
                } label: {
                    HStack {
                        Text(String(localized: "Join group"))
                        if phase == .joining { Spacer(); ProgressView() }
                    }
                    .frame(minHeight: 44)
                }
                .disabled(phase == .joining || displayName.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("joinGroup.join")
            } header: {
                Text(String(localized: "Name the group will see"))
            } footer: {
                Text(String(localized: "Joining needs a connection. You'll join once, as this account."))
            }
            .suListRows()
        case .signedOut, .deviceOnly, .sessionEnded:
            Section {
                Button(String(localized: "Add an email and password")) { accountSheet = .create }
                    .frame(minHeight: 44)
                Button(String(localized: "Sign in to an existing account")) { accountSheet = .signIn }
                    .frame(minHeight: 44)
            } footer: {
                Text(LedgerErrorMessages.text(for: GroupInvitationIssue.accountRequired))
            }
            .suListRows()
        case .notConfigured:
            Section {
                Text(String(localized: "Shared groups aren't set up in this build of Square Up."))
            }
            .suListRows()
        }
    }

    private func joinOrOpen() async {
        guard let code else { return }
        phase = .joining
        do {
            if case .needsProfile = environment.sharedGroups.accountState {
                try await environment.sharedGroups.saveProfile(displayName: displayName)
            }
            let groupID = try await environment.sharedGroups.accept(code, displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines))
            AccessibilityNotification.Announcement(String(localized: "Joined \(preview?.groupName ?? "")")).post()
            dismiss()
            onJoined(groupID)
        } catch LedgerError.remote(.invitation(.alreadyMember)) {
            if let id = environment.sharedGroups.summaries.first(where: { $0.group.name == preview?.groupName })?.group.id,
               let groupID = GroupID(string: id) {
                dismiss()
                onJoined(groupID)
            } else {
                show(LedgerErrorMessages.text(for: GroupInvitationIssue.alreadyMember))
            }
        } catch {
            show(message(for: error))
            phase = .preview
            if case .remote(.offline) = error { show(LedgerErrorMessages.text(for: RemoteIssue.connectionRequired)) }
        }
    }

    private func message(for error: any Error) -> String {
        if case .remote(.offline) = error as? LedgerError { return LedgerErrorMessages.text(for: RemoteIssue.connectionRequired) }
        return LedgerErrorMessages.text(for: error as? LedgerError ?? .unavailable)
    }

    private func show(_ message: String) {
        phase = .problem(message)
        messageFocused = true
        AccessibilityNotification.Announcement(message).post()
    }
}
