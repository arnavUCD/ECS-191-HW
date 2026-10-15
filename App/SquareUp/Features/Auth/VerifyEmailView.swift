import SwiftUI

/// "Check your email": the account waits here until Firebase confirms the address. Returning to
/// the app checks quietly (at most every few seconds); "I've verified my email" checks and explains.
/// The emailed link opens Firebase's page in the browser — there is no in-app link handling, so
/// coming back is the reliable path.
struct VerifyEmailView: View {
    @Environment(AuthCoordinator.self) private var auth
    @Environment(AppEnvironment.self) private var environment
    @State private var isChangingEmail = false
    @State private var isConfirmingSignOut = false
    @State private var isConfirmingDelete = false
    @State private var failure: AuthFailure?

    var body: some View {
        SUAuthScaffold(isAnimated: environment.allowsAmbientAnimation) {
            VerificationContent(intro: String(localized: "We sent a link to confirm your address:"))
            if let failure { SUInlineStatus(text: failure.message, identifier: "verify.failure") }
            if auth.needsRecentSignIn {
                Button(String(localized: "Sign in again")) { Task { await auth.signInAgain() } }
                    .buttonStyle(.suGlassSecondary)
                    .accessibilityIdentifier("verify.signInAgain")
            }
            PendingInvitationNote()
            VerificationActions()
        } footer: {
            VStack(spacing: 0) {
                HStack {
                    Button(String(localized: "Use a different email")) { isChangingEmail = true }
                        .accessibilityIdentifier("verify.differentEmail")
                    Button(String(localized: "Sign out")) { isConfirmingSignOut = true }
                        .accessibilityIdentifier("verify.signOut")
                }
                .buttonStyle(.suText)
                .disabled(auth.isWorking)
                Button(String(localized: "Delete this sign-up and start over"), role: .destructive) { isConfirmingDelete = true }
                    .font(SUFont.supporting)
                    .foregroundStyle(SUColor.negative)
                    .frame(maxWidth: .infinity, minHeight: SUMetrics.minimumTouchTarget)
                    .disabled(auth.isWorking)
                    .accessibilityIdentifier("verify.deleteAndRestart")
            }
        }
        .accessibilityIdentifier("auth.verifyEmail")
        .announcing(auth.notice)
        .verificationRefreshOnForeground()
        .sheet(isPresented: $isChangingEmail) { ChangeEmailSheet() }
        .confirmationDialog(String(localized: "Sign out?"), isPresented: $isConfirmingSignOut, titleVisibility: .visible) {
            Button(String(localized: "Sign out"), role: .destructive) { Task { await auth.signOut() } }
                .accessibilityIdentifier("verify.confirmSignOut")
        } message: {
            Text(String(localized: "You can sign in again later to finish confirming your email."))
        }
        .confirmationDialog(String(localized: "Delete this sign-up?"), isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button(String(localized: "Delete and start over"), role: .destructive) { Task { await deleteAndRestart() } }
                .accessibilityIdentifier("verify.confirmDelete")
        } message: {
            Text(String(localized: "This unconfirmed account is removed from Square Up so you can sign up again. Accounts that are verified or already set up are never deleted."))
        }
    }

    private func deleteAndRestart() async {
        failure = nil
        do throws(AuthFailure) {
            try await auth.deleteAndStartOver()
        } catch {
            failure = error
            AccessibilityNotification.Announcement(error.message).post()
        }
    }
}

/// The address and the latest result.
private struct VerificationContent: View {
    let intro: String
    @Environment(AuthCoordinator.self) private var auth

    var body: some View {
        SUAuthHeader(title: String(localized: "Verify\nyour email"), subtitle: intro)
        if let email = auth.pendingEmail ?? auth.email {
            SUSentToAddress(address: email)
                .accessibilityLabel(String(localized: "Sent to \(email)"))
                .accessibilityIdentifier("verify.email")
        }
        Text(auth.pendingEmail == nil
            ? String(localized: "Open the link, then come back here. It can take a minute to arrive — check spam too.")
            : String(localized: "Open the link sent to this new address. Your account switches to it once you do; until then it keeps the old one."))
            .font(SUFont.supporting)
            .foregroundStyle(SUColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        if let notice = auth.notice {
            SUInlineStatus(text: notice.message, isProblem: notice.isProblem, identifier: "verify.notice")
        }
    }
}

/// Check, open Mail, and resend with a cooldown.
private struct VerificationActions: View {
    @Environment(AuthCoordinator.self) private var auth
    @Environment(\.openURL) private var openURL
    @State private var mailUnavailable = false

    var body: some View {
        if mailUnavailable {
            SUInlineStatus(text: String(localized: "Couldn't open Mail. Open your email app and tap the link we sent."), identifier: "verify.mailUnavailable")
        }
        GlassEffectContainer(spacing: SUSpacing.sm) {
            VStack(spacing: SUSpacing.sm) {
                Button {
                    Task { await auth.checkVerification(userInitiated: true) }
                } label: {
                    SUProgressLabel(title: String(localized: "I've verified my email"), workingTitle: String(localized: "Checking…"),
                                    isWorking: auth.isCheckingVerification)
                }
                .buttonStyle(.suGlassPrimary)
                .disabled(auth.isCheckingVerification || auth.isWorking)
                .accessibilityIdentifier("verify.check")
                Button {
                    mailUnavailable = false
                    // Apple Mail's scheme; other email apps have no shared way to open, so a failure
                    // explains what to do instead.
                    openURL(URL(string: "message://")!) { accepted in mailUnavailable = !accepted }
                } label: {
                    Label(String(localized: "Open Mail"), systemImage: "envelope")
                }
                .buttonStyle(.suGlassSecondary)
                .accessibilityIdentifier("verify.openMail")
            }
        }
        CooldownButton(title: String(localized: "Resend email"), availableAt: auth.verificationResendAvailableAt, isWorking: auth.isWorking) {
            Task { await auth.resendVerification() }
        }
        .accessibilityIdentifier("verify.resend")
    }
}

/// "Use a different email": a link goes to the new address; nothing is deleted.
private struct ChangeEmailSheet: View {
    nonisolated enum Field: Hashable { case email }

    @Environment(AuthCoordinator.self) private var auth
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var issue: String?
    @State private var failure: AuthFailure?
    @FocusState private var focus: Field?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: SUSpacing.lg) {
                    SUAuthHeader(title: String(localized: "Use a different email"),
                                 subtitle: String(localized: "We'll send a link to the new address. Your account switches to it — already confirmed — once you open the link."))
                    if let failure { SUInlineStatus(text: failure.message, identifier: "changeEmail.failure") }
                    SUFormField(label: String(localized: "New email"), text: $email, symbol: "envelope",
                                contentType: .emailAddress, keyboard: .emailAddress, submitLabel: .send, issue: issue,
                                identifier: "changeEmail.email", focus: $focus, field: .email, onSubmit: send)
                    Button(action: send) {
                        SUProgressLabel(title: String(localized: "Send link"), workingTitle: String(localized: "Sending…"), isWorking: auth.isWorking)
                    }
                    .buttonStyle(.suGlassPrimary)
                    .disabled(auth.isWorking)
                    .accessibilityIdentifier("changeEmail.send")
                    if auth.needsRecentSignIn {
                        Button(String(localized: "Sign in again")) {
                            dismiss()
                            Task { await auth.signInAgain() }
                        }
                        .buttonStyle(.suGlassSecondary)
                        .accessibilityIdentifier("changeEmail.signInAgain")
                    }
                }
                .padding(SUSpacing.screenMargin)
            }
            .background { SUDuskBackdrop(style: .calm, isAnimated: false).ignoresSafeArea() }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(String(localized: "Cancel")) { dismiss() } }
            }
        }
        .suDuskAppearance()
        .accessibilityIdentifier("auth.changeEmail")
    }

    private func send() {
        guard !auth.isWorking else { return }
        failure = nil
        issue = AuthValidation.emailIssue(email)
        if issue == nil, AuthValidation.normalizedEmail(email).lowercased() == auth.email?.lowercased() {
            issue = String(localized: "That's the address already on this account.")
        }
        if let issue {
            focus = .email
            AccessibilityNotification.Announcement(issue).post()
            return
        }
        Task {
            do throws(AuthFailure) {
                try await auth.changeEmail(to: email)
                dismiss()
            } catch {
                failure = error
                AccessibilityNotification.Announcement(error.message).post()
            }
        }
    }
}

private struct VerificationRefresh: ViewModifier {
    @Environment(AuthCoordinator.self) private var auth
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content.onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await auth.checkVerification(userInitiated: false) } }
        }
    }
}

extension View {
    /// Re-checks verification (quietly, throttled) when the app returns from the email link.
    func verificationRefreshOnForeground() -> some View { modifier(VerificationRefresh()) }
}
