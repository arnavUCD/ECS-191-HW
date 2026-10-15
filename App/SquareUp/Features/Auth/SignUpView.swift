import SwiftUI

/// Create an account: name, email, and a password (typed twice), checked before anything is sent.
struct SignUpView: View {
    @Environment(AuthCoordinator.self) private var auth
    @Environment(AppEnvironment.self) private var environment
    @State private var form = SignUpForm()
    /// Problems are shown after the first attempt to continue, then update as the person types.
    @State private var showsIssues = false
    @State private var failure: AuthFailure?
    @FocusState private var focus: SignUpForm.Field?
    @AccessibilityFocusState private var isFailureFocused: Bool

    private var issues: [SignUpForm.Field: String] { showsIssues ? form.issues(rules: auth.rules) : [:] }
    /// `.newPassword` lets iOS and password managers suggest and save a strong password. UI tests
    /// use `.oneTimeCode` instead: with automated typing, the simulator's Strong Password AutoFill
    /// takes over the first password field of a two-password form and keeps only the last keystroke.
    private var newPasswordType: UITextContentType { environment.configuration.isUITesting ? .oneTimeCode : .newPassword }

    var body: some View {
        SUAuthScaffold(isAnimated: environment.allowsAmbientAnimation) {
            SUAuthHeader(title: String(localized: "Let's get\nstarted"),
                         subtitle: String(localized: "Your groups and balances stay in sync on every device you sign in to."))
            PendingInvitationNote()
            if let failure {
                SUInlineStatus(text: failure.message, identifier: "signUp.failure")
                    .accessibilityFocused($isFailureFocused)
                if failure == .account(.emailInUse) {
                    Button(String(localized: "Sign in instead")) {
                        auth.phone.use(.email, for: .signIn)
                        auth.show(.signIn)
                    }
                    .buttonStyle(.suGlassSecondary)
                    .accessibilityIdentifier("signUp.signInInstead")
                }
            }
            VStack(spacing: SUSpacing.sm) { fields }
            VStack(spacing: SUSpacing.sm) {
                Button(action: submit) {
                    SUProgressLabel(title: String(localized: "Create account"), workingTitle: String(localized: "Creating your account…"), isWorking: auth.isWorking)
                }
                .buttonStyle(.suGlassPrimary)
                .disabled(auth.isWorking)
                .accessibilityIdentifier("signUp.submit")
                Text(String(localized: "We'll email you a link to confirm your address."))
                    .font(SUFont.metadata)
                    .foregroundStyle(SUColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                if auth.phone.isAvailable {
                    SUAuthQuietLink(title: String(localized: "Use phone instead")) { auth.phone.use(.phone, for: .createAccount) }
                        .disabled(auth.isWorking)
                        .accessibilityIdentifier("signUp.usePhone")
                }
            }
        } footer: {
            SUAuthSwitchLink(prompt: String(localized: "Already have an account?"), action: String(localized: "Sign in")) {
                auth.phone.use(.email, for: .signIn)
                auth.show(.signIn)
            }
            .disabled(auth.isWorking)
            .accessibilityIdentifier("signUp.toSignIn")
        }
        .authNavigationChrome()
        .accessibilityIdentifier("auth.signUp")
        .task { await auth.loadPasswordRules() }
        .onAppear {
            if form.name.isEmpty { form.name = auth.draftName }
        }
    }

    @ViewBuilder private var fields: some View {
        SUFormField(label: String(localized: "Your name"), text: $form.name, symbol: "person",
                    contentType: .name, capitalization: .words, issue: issues[.name], identifier: "signUp.name",
                    focus: $focus, field: .name) { focus = .email }
        SUFormField(label: String(localized: "Email"), text: $form.email, symbol: "envelope",
                    contentType: .emailAddress, keyboard: .emailAddress, issue: issues[.email], identifier: "signUp.email",
                    focus: $focus, field: .email) { focus = .password }
        SUPasswordField(label: String(localized: "Password"), text: $form.password, contentType: newPasswordType, submitLabel: .next,
                        issue: issues[.password], identifier: "signUp.password", focus: $focus, field: .password) { focus = .confirmation }
        PasswordRequirementList(requirements: auth.rules.requirements(for: form.password))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SUSpacing.xxs)
        SUPasswordField(label: String(localized: "Confirm password"), text: $form.confirmation, symbol: "lock.rotation", contentType: newPasswordType, submitLabel: .go,
                        issue: issues[.confirmation], identifier: "signUp.confirmation", focus: $focus, field: .confirmation, onSubmit: submit)
    }

    private func submit() {
        guard !auth.isWorking else { return }
        showsIssues = true
        failure = nil
        let problems = form.issues(rules: auth.rules)
        if let first = [SignUpForm.Field.name, .email, .password, .confirmation].first(where: { problems[$0] != nil }) {
            focus = first
            AccessibilityNotification.Announcement(problems[first] ?? "").post()
            return
        }
        focus = nil
        let submitted = form
        Task {
            do throws(AuthFailure) {
                try await auth.signUp(submitted)
            } catch {
                failure = error
                isFailureFocused = true
                AccessibilityNotification.Announcement(error.message).post()
            }
        }
    }
}

/// Each password requirement with a symbol and words, so meeting it never depends on color.
struct PasswordRequirementList: View {
    let requirements: [PasswordRules.Requirement]

    var body: some View {
        VStack(alignment: .leading, spacing: SUSpacing.xxs) {
            ForEach(requirements) { requirement in
                Label {
                    Text(requirement.text)
                        .foregroundStyle(requirement.isMet ? SUColor.textPrimary : SUColor.textSecondary)
                } icon: {
                    Image(systemName: requirement.isMet ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(requirement.isMet ? SUColor.positive : SUColor.textTertiary)
                }
                .font(SUFont.metadata)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(requirement.isMet ? String(localized: "Met: \(requirement.text)") : String(localized: "Not met yet: \(requirement.text)"))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Password requirements"))
        .accessibilityIdentifier("signUp.requirements")
    }
}
