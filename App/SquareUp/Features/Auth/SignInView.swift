import SwiftUI

/// Sign in to an existing account. Wrong details, being offline, and rate limits each get their
/// own words; nothing says whether a particular address has an account.
struct SignInView: View {
    nonisolated enum Field: Hashable { case email, password }

    @Environment(AuthCoordinator.self) private var auth
    @Environment(AppEnvironment.self) private var environment
    @State private var email = ""
    @State private var password = ""
    @State private var emailIssue: String?
    @State private var passwordIssue: String?
    @State private var failure: AuthFailure?
    @FocusState private var focus: Field?
    @AccessibilityFocusState private var isFailureFocused: Bool

    var body: some View {
        SUAuthScaffold(isAnimated: environment.allowsAmbientAnimation) {
            SUAuthHeader(title: String(localized: "Hey,\nwelcome back"),
                         subtitle: String(localized: "Sign in to see your groups and balances."))
            if let notice = auth.notice {
                SUInlineStatus(text: notice.message, isProblem: notice.isProblem)
            }
            PendingInvitationNote()
            if let failure {
                SUInlineStatus(text: failure.message, identifier: "signIn.failure")
                    .accessibilityFocused($isFailureFocused)
            }
            VStack(spacing: SUSpacing.sm) {
                SUFormField(label: String(localized: "Email"), text: $email, symbol: "envelope",
                            contentType: .username, keyboard: .emailAddress, issue: emailIssue, identifier: "signIn.email",
                            focus: $focus, field: .email) { focus = .password }
                SUPasswordField(label: String(localized: "Password"), text: $password, contentType: .password, submitLabel: .go,
                                issue: passwordIssue, identifier: "signIn.password", focus: $focus, field: .password, onSubmit: submit)
                SUAuthQuietLink(title: String(localized: "Forgot password?")) { auth.showPasswordReset(email: email) }
                    .disabled(auth.isWorking)
                    .accessibilityIdentifier("signIn.forgot")
            }
            Button(action: submit) {
                SUProgressLabel(title: String(localized: "Sign in"), workingTitle: String(localized: "Signing in…"), isWorking: auth.isWorking)
            }
            .buttonStyle(.suGlassPrimary)
            .disabled(auth.isWorking)
            .accessibilityIdentifier("signIn.submit")
            if auth.phone.isAvailable {
                SUAuthQuietLink(title: String(localized: "Use phone instead")) { auth.phone.use(.phone, for: .signIn) }
                    .disabled(auth.isWorking)
                    .accessibilityIdentifier("signIn.usePhone")
            }
        } footer: {
            SUAuthSwitchLink(prompt: String(localized: "New to Square Up?"), action: String(localized: "Create account")) {
                auth.phone.use(.email, for: .createAccount)
                auth.show(.createAccount)
            }
            .disabled(auth.isWorking)
            .accessibilityIdentifier("signIn.toSignUp")
        }
        .authNavigationChrome()
        .accessibilityIdentifier("auth.signIn")
        .announcing(auth.notice)
        .onAppear {
            if email.isEmpty, let remembered = auth.rememberedEmail { email = remembered }
        }
    }

    private func submit() {
        guard !auth.isWorking else { return }
        failure = nil
        emailIssue = AuthValidation.emailIssue(email)
        passwordIssue = password.isEmpty ? String(localized: "Enter your password.") : nil
        if emailIssue != nil || passwordIssue != nil {
            focus = emailIssue != nil ? .email : .password
            AccessibilityNotification.Announcement(emailIssue ?? passwordIssue ?? "").post()
            return
        }
        focus = nil
        Task {
            do throws(AuthFailure) {
                try await auth.signIn(email: email, password: password)
            } catch {
                failure = error
                isFailureFocused = true
                AccessibilityNotification.Announcement(error.message).post()
            }
        }
    }
}
