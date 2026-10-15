import SwiftUI

/// Profile → Account. With the launch flow (a build that requires an account), it shows the
/// signed-in email and its verification, the name people see, and Sign out (back to Welcome).
/// Builds without required accounts keep milestone 7's section: device-only or recoverable,
/// adding an email, signing in, and password reset.
struct AccountSection: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AuthCoordinator.self) private var auth: AuthCoordinator?
    @State private var sheet: AccountSheet.Mode?
    @State private var isConfirmingSignOut = false
    @State private var isEditingName = false

    var body: some View {
        let groups = environment.sharedGroups
        if let auth, auth.isGated {
            if auth.isDemo {
                DemoWorkspaceSection(auth: auth)
            } else {
                SignedInAccountSection(auth: auth)
            }
        } else if groups.isConfigured {
            Section {
                LabeledContent(String(localized: "Account"), value: statusText)
                    .accessibilityIdentifier("profile.account")
                    // Presented from this one row, not the Section: a Section hands modifiers to every row.
                    .sheet(item: $sheet) { mode in AccountSheet(mode: mode) }
                    .sheet(isPresented: $isEditingName) { DisplayNameSheet() }
                    .confirmationDialog(String(localized: "Sign out?"), isPresented: $isConfirmingSignOut, titleVisibility: .visible) {
                        Button(String(localized: "Sign out"), role: .destructive) {
                            Task {
                                await environment.sharedGroups.signOut()
                                await environment.sharing.signOut()
                            }
                        }
                    } message: {
                        Text(String(localized: """
                        Your shared groups stay on the server and come back when you sign in again. The copies saved on this iPhone are \
                        removed now, along with any changes that haven't been sent. Groups that are only on this iPhone aren't affected.
                        """))
                    }
                    .task { await environment.sharedGroups.refreshAccount() }
                switch groups.accountState {
                case .notConfigured:
                    EmptyView()
                case .signedOut, .deviceOnly:
                    if !isDevelopment {
                        Button(String(localized: "Add an email and password")) { sheet = .create }
                            .accessibilityIdentifier("profile.account.create")
                        Button(String(localized: "Sign in to an existing account")) { sheet = .signIn }
                            .accessibilityIdentifier("profile.account.signIn")
                    }
                case .sessionEnded:
                    Button(String(localized: "Sign in again")) { sheet = .signIn }
                        .accessibilityIdentifier("profile.account.signInAgain")
                case .needsProfile:
                    Button(String(localized: "Choose the name people will see")) { isEditingName = true }
                        .accessibilityIdentifier("profile.account.chooseName")
                case .ready:
                    LabeledContent(String(localized: "Name in shared groups"), value: groups.profile?.displayName ?? "")
                    Button(String(localized: "Change name")) { isEditingName = true }
                        .accessibilityIdentifier("profile.account.changeName")
                    if !isDevelopment {
                        Button(String(localized: "Reset password")) { sheet = .reset }
                        Button(String(localized: "Sign out"), role: .destructive) { isConfirmingSignOut = true }
                            .accessibilityIdentifier("profile.account.signOut")
                    }
                }
            } header: {
                Text(String(localized: "Account"))
            } footer: {
                Text(footer)
            }
            .suListRows()
        }
    }

    private var isDevelopment: Bool { environment.sharedGroups.configuration?.authMode == .development }

    private var statusText: String {
        switch environment.sharedGroups.accountState {
        case .notConfigured: String(localized: "Not available")
        case .signedOut: String(localized: "Not signed in")
        case .deviceOnly: String(localized: "This iPhone only")
        case .sessionEnded: String(localized: "Signed out")
        case .needsProfile(let email), .ready(let email):
            email ?? (isDevelopment ? String(localized: "Development account") : String(localized: "Signed in"))
        }
    }

    private var footer: String {
        switch environment.sharedGroups.accountState {
        case .notConfigured: ""
        case .signedOut:
            String(localized: "Groups stay on this iPhone. Add an email and password to share groups with other people's iPhones and get them back on a new one.")
        case .deviceOnly:
            String(localized: "This account works on this iPhone only. Add an email and password to use shared groups — receipt rooms you host stay yours.")
        case .sessionEnded:
            String(localized: "Your sign-in ended. Shared groups saved on this iPhone are still readable; sign in again to make changes.")
        case .needsProfile:
            String(localized: "Choose the name other members will see before creating or joining a shared group.")
        case .ready:
            String(localized: "Shared groups are kept on the server and on this iPhone for offline reading. Square Up never stores bank details.")
        }
    }
}

/// The signed-in account (launch flow builds): email, name, and Sign out.
private struct SignedInAccountSection: View {
    let auth: AuthCoordinator
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppSession.self) private var session: AppSession?
    @State private var isConfirmingSignOut = false
    @State private var isEditingName = false
    @State private var isShowingMethods = false

    var body: some View {
        Section {
            LabeledContent(auth.email == nil && auth.details?.phoneNumber != nil ? String(localized: "Phone") : String(localized: "Email")) {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(verbatim: auth.accountLabel ?? "")
                        .foregroundStyle(SUColor.textPrimary)
                    Label(isVerified ? String(localized: "Verified") : String(localized: "Not verified"),
                          systemImage: isVerified ? "checkmark.seal.fill" : "exclamationmark.circle")
                        .font(SUFont.metadata)
                        .foregroundStyle(isVerified ? SUColor.positive : SUColor.textSecondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("profile.account")
            .sheet(isPresented: $isEditingName) { DisplayNameSheet() }
            .confirmationDialog(String(localized: "Sign out?"), isPresented: $isConfirmingSignOut, titleVisibility: .visible) {
                Button(String(localized: "Sign out"), role: .destructive) { Task { await auth.signOut() } }
                    .accessibilityIdentifier("profile.account.confirmSignOut")
            } message: {
                Text(signOutMessage)
            }
            LabeledContent(String(localized: "Name in shared groups"), value: environment.sharedGroups.profile?.displayName ?? auth.profile?.displayName ?? "")
            Button(String(localized: "Change name")) { isEditingName = true }
                .accessibilityIdentifier("profile.account.changeName")
            Button(String(localized: "Sign-in methods")) { isShowingMethods = true }
                .accessibilityIdentifier("profile.account.signInMethods")
                .sheet(isPresented: $isShowingMethods) { SignInMethodsView() }
            if session?.canReviewLegacyData == true {
                Button(String(localized: "Earlier data on this iPhone")) { session?.reviewLegacyData() }
                    .accessibilityIdentifier("profile.account.legacyData")
            }
            Button(String(localized: "Sign out"), role: .destructive) { isConfirmingSignOut = true }
                .accessibilityIdentifier("profile.account.signOut")
        } header: {
            Text(String(localized: "Account"))
        } footer: {
            Text(footer)
        }
    }

    /// The account's email is confirmed, or it signs in with a verified phone number.
    private var isVerified: Bool {
        auth.email == nil ? auth.details?.phoneNumber != nil : auth.isEmailVerified
    }

    private var footer: String {
        String(localized: """
        This account's groups are kept on this iPhone separately from any other account, and shared groups \
        also on the server. Square Up never stores bank details.
        """)
    }

    private var signOutMessage: String {
        let base = String(localized: """
        Your groups stay on this iPhone for this account and come back when you sign in again; shared groups are also on the server. \
        Nobody else who signs in here can see them.
        """)
        let unsent = auth.unsentChangeCount
        guard unsent > 0 else { return base }
        return Inflect.string("Waiting to send: ^[\(unsent) change](inflect: true) in shared groups. They're kept and sent after you sign in again. ") + base
    }
}

/// Create an account (keeping this iPhone's identity), sign in, or reset a password.
struct AccountSheet: View {
    enum Mode: String, Identifiable {
        case create, signIn, reset
        var id: String { rawValue }
    }

    let mode: Mode
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var error: String?
    @State private var isWorking = false
    @State private var resetSent = false
    @AccessibilityFocusState private var errorFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(String(localized: "Email"), text: $email)
                        .textContentType(.username).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("account.email")
                    if mode != .reset {
                        SecureField(String(localized: "Password"), text: $password)
                            .textContentType(mode == .signIn ? .password : .newPassword)
                            .accessibilityIdentifier("account.password")
                    }
                } footer: {
                    Text(footerText)
                        .foregroundStyle(error == nil ? SUColor.textSecondary : SUColor.negative)
                        .accessibilityFocused($errorFocused)
                }
            }
            .scrollContentBackground(.hidden)
            .suScreenBackground()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(String(localized: "Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(actionTitle) { Task { await submit() } }
                        .disabled(isWorking || email.isEmpty || (mode != .reset && password.isEmpty))
                        .accessibilityIdentifier("account.submit")
                }
            }
            .overlay { if isWorking { ProgressView() } }
        }
    }

    private var title: String {
        switch mode {
        case .create: String(localized: "Add email and password")
        case .signIn: String(localized: "Sign in")
        case .reset: String(localized: "Reset password")
        }
    }

    private var actionTitle: String {
        switch mode {
        case .create: String(localized: "Save")
        case .signIn: String(localized: "Sign in")
        case .reset: String(localized: "Send")
        }
    }

    private var footerText: String {
        if let error { return error }
        switch mode {
        case .create: return String(localized: "Keeps this iPhone's account (and any receipt rooms it hosts) and lets you use shared groups and recover them on another iPhone.")
        case .signIn: return String(localized: "Your shared groups come back from the server. Groups saved only on this iPhone stay as they are.")
        case .reset:
            return resetSent
                ? String(localized: "If that email has an account, a reset link is on its way. Follow it, then sign in with the new password.")
                : String(localized: "We'll ask Firebase to email a password-reset link. Square Up never sees your password.")
        }
    }

    private func submit() async {
        isWorking = true
        error = nil
        defer { isWorking = false }
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            switch mode {
            case .create: try await environment.sharedGroups.createAccount(email: address, password: password)
            case .signIn: try await environment.sharedGroups.signIn(email: address, password: password)
            case .reset:
                try await environment.sharedGroups.sendPasswordReset(email: address)
                resetSent = true
                AccessibilityNotification.Announcement(String(localized: "If that email has an account, a reset link is on its way.")).post()
                return
            }
            await environment.sharing.refreshAccountStatus()
            dismiss()
        } catch {
            self.error = LedgerErrorMessages.text(for: error)
            errorFocused = true
        }
    }
}

/// The name other members see in shared groups.
struct DisplayNameSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var error: String?
    @State private var isWorking = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(String(localized: "Your name"), text: $name)
                        .textContentType(.name)
                        .accessibilityIdentifier("account.displayName")
                } footer: {
                    Text(error ?? String(localized: "Shown to people in your shared groups. You can confirm or change it when you join a group."))
                        .foregroundStyle(error == nil ? SUColor.textSecondary : SUColor.negative)
                }
            }
            .scrollContentBackground(.hidden)
            .suScreenBackground()
            .navigationTitle(String(localized: "Your name"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(String(localized: "Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Save")) { Task { await save() } }
                        .disabled(isWorking || name.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("account.saveName")
                }
            }
            .onAppear { name = environment.sharedGroups.profile?.displayName ?? "" }
        }
    }

    private func save() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await environment.sharedGroups.saveProfile(displayName: name)
            // This iPhone's own record of the person follows the profile name.
            if let profile = environment.sharedGroups.profile, let id = MemberID(string: profile.memberId),
               let identity = environment.rootLedger as? any LocalIdentityPreparing {
                try? await identity.prepareCurrentUser(id: id, displayName: profile.displayName)
            }
            dismiss()
        } catch {
            self.error = LedgerErrorMessages.text(for: error)
        }
    }
}
