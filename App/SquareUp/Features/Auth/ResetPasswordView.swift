import SwiftUI

/// Password recovery through Firebase's emailed link (the new password is chosen on Firebase's
/// page, never in the app). The confirmation reads the same whether or not the address has an account.
struct ResetPasswordView: View {
    nonisolated enum Field: Hashable { case email }

    @Environment(AuthCoordinator.self) private var auth
    @Environment(AppEnvironment.self) private var environment
    @State private var email = ""
    @State private var issue: String?
    @State private var failure: AuthFailure?
    @FocusState private var focus: Field?

    var body: some View {
        SUAuthScaffold(isAnimated: environment.allowsAmbientAnimation) {
            if let sentTo = auth.resetSentTo {
                confirmation(sentTo)
            } else {
                form
            }
        }
        .authNavigationChrome()
        .accessibilityIdentifier("auth.resetPassword")
        .onAppear {
            if email.isEmpty, let remembered = auth.rememberedEmail { email = remembered }
        }
        .onDisappear { auth.editPasswordResetEmail() }
    }

    @ViewBuilder private var form: some View {
        SUAuthHeader(title: String(localized: "Forgot\npassword?"),
                     subtitle: String(localized: "Enter the email you use for Square Up and we'll send a link to choose a new password."))
        if let failure { SUInlineStatus(text: failure.message, identifier: "reset.failure") }
        SUFormField(label: String(localized: "Email"), text: $email, symbol: "envelope",
                    contentType: .emailAddress, keyboard: .emailAddress, submitLabel: .send, issue: issue, identifier: "reset.email",
                    focus: $focus, field: .email, onSubmit: send)
        Button(action: send) {
            SUProgressLabel(title: String(localized: "Send reset link"), workingTitle: String(localized: "Sending…"), isWorking: auth.isWorking)
        }
        .buttonStyle(.suGlassPrimary)
        .disabled(auth.isWorking || !auth.canResendPasswordReset)
        .accessibilityIdentifier("reset.send")
    }

    @ViewBuilder private func confirmation(_ address: String) -> some View {
        SUAuthHeader(title: String(localized: "Check\nyour email"),
                     subtitle: String(localized: "If an account uses this address, we sent it a link to reset the password:"))
        SUSentToAddress(address: address)
            .accessibilityIdentifier("reset.sentTo")
        Text(String(localized: "Open the link, choose a new password, then come back and sign in. Check spam if it doesn't arrive."))
            .font(SUFont.supporting)
            .foregroundStyle(SUColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        if let failure { SUInlineStatus(text: failure.message, identifier: "reset.failure") }
        GlassEffectContainer(spacing: SUSpacing.sm) {
            VStack(spacing: SUSpacing.sm) {
                Button(String(localized: "Back to sign in")) { auth.show(.signIn) }
                    .buttonStyle(.suGlassPrimary)
                    .accessibilityIdentifier("reset.backToSignIn")
                Button(String(localized: "Use a different email")) {
                    failure = nil
                    auth.editPasswordResetEmail()
                }
                .buttonStyle(.suGlassSecondary)
                .accessibilityIdentifier("reset.differentEmail")
            }
        }
        CooldownButton(title: String(localized: "Resend link"), availableAt: auth.resetResendAvailableAt, isWorking: auth.isWorking, action: send)
            .accessibilityIdentifier("reset.resend")
    }

    private func send() {
        guard !auth.isWorking else { return }
        failure = nil
        issue = AuthValidation.emailIssue(email)
        if let issue {
            focus = .email
            AccessibilityNotification.Announcement(issue).post()
            return
        }
        focus = nil
        Task {
            do throws(AuthFailure) {
                try await auth.sendPasswordReset(email: email)
                AccessibilityNotification.Announcement(String(localized: "Reset link sent.")).post()
            } catch {
                failure = error
                AccessibilityNotification.Announcement(error.message).post()
            }
        }
    }
}

/// The address an email went to, set apart in a glass capsule so it's easy to check for typos.
struct SUSentToAddress: View {
    let address: String

    var body: some View {
        Label {
            Text(verbatim: address)
                .font(SUFont.cardTitle)
                .foregroundStyle(SUColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "envelope.fill")
                .foregroundStyle(SUColor.textSecondary)
        }
        .padding(.horizontal, SUSpacing.md)
        .padding(.vertical, SUSpacing.sm)
        .glassEffect(.regular, in: SUShape.compact)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: address))
    }
}

/// A text action that waits out a cooldown, showing the seconds left in words. It updates once a
/// second only while a cooldown is running, then stops (no timer while idle).
struct CooldownButton: View {
    let title: String
    let availableAt: Date?
    let isWorking: Bool
    let action: () -> Void
    @State private var now = Date.now

    private var remaining: Int { max(0, Int((availableAt?.timeIntervalSince(now) ?? 0).rounded(.up))) }

    var body: some View {
        Button(action: action) {
            Text(remaining > 0 ? String(localized: "\(title) in \(remaining) s") : title)
                .monospacedDigit()
        }
        .buttonStyle(.suText)
        .disabled(isWorking || remaining > 0)
        .accessibilityLabel(remaining > 0 ? String(localized: "\(title), available in \(remaining) seconds") : title)
        .task(id: availableAt) {
            now = .now
            while let availableAt, now < availableAt, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                now = .now
            }
        }
    }
}
