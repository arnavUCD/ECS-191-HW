import SwiftUI

/// The six-digit code from the text message. It verifies as soon as the sixth digit arrives
/// (typed, pasted, or offered by iOS from Messages). Resend waits out a visible cooldown; "Change
/// number" goes back with the number as typed. Wrong, expired, and rate-limited codes each say so
/// in plain words.
struct PhoneCodeView: View {
    @Environment(AuthCoordinator.self) private var auth
    @Environment(AppEnvironment.self) private var environment
    @State private var code = ""
    @State private var failure: AuthFailure?
    @State private var wrongCodeCount = 0
    @FocusState private var isFocused: Bool
    @AccessibilityFocusState private var isFailureFocused: Bool

    private var phone: PhoneSignIn { auth.phone }

    var body: some View {
        SUAuthScaffold(isAnimated: environment.allowsAmbientAnimation) {
            SUAuthHeader(title: String(localized: "Enter the\ncode"),
                         subtitle: String(localized: "We texted a 6-digit code to"))
            if let number = phone.verification?.phoneNumber {
                HStack(spacing: SUSpacing.xs) {
                    Text(verbatim: PhoneNumbers.shared.display(number))
                        .font(SUFont.body.weight(.semibold).monospacedDigit())
                        .foregroundStyle(SUColor.textPrimary)
                    Spacer(minLength: SUSpacing.xs)
                    Button(String(localized: "Change number")) { phone.changeNumber() }
                        .font(SUFont.supporting.weight(.semibold))
                        .foregroundStyle(SUColor.accent)
                        .frame(minHeight: SUMetrics.minimumTouchTarget)
                        .disabled(phone.isWorking)
                        .accessibilityIdentifier("code.changeNumber")
                }
                .padding(.top, -SUSpacing.sm)
            }
            if let failure {
                SUInlineStatus(text: failure.message, identifier: "code.failure")
                    .accessibilityFocused($isFailureFocused)
            } else if let notice = phone.notice {
                SUInlineStatus(text: notice.message, isProblem: notice.isProblem, identifier: "code.notice")
            }
            PendingInvitationNote()
            SUCodeField(code: $code, isInvalid: failure == .account(.invalidCode) && wrongCodeCount > 0, identifier: "code.field",
                        isFocused: $isFocused) { _ in submit() }
            Button(action: submit) {
                SUProgressLabel(title: String(localized: "Verify"), workingTitle: String(localized: "Verifying…"), isWorking: phone.isWorking)
            }
            .buttonStyle(.suGlassPrimary)
            .disabled(phone.isWorking || code.count < 6)
            .accessibilityIdentifier("code.verify")
            VStack(spacing: SUSpacing.xxs) {
                PhoneResendButton()
                Text(String(localized: "Didn't get it? Check the number above and wait a minute. Codes expire after a few minutes."))
                    .font(SUFont.metadata)
                    .foregroundStyle(SUColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .authNavigationChrome()
        .accessibilityIdentifier("auth.phoneCode")
        .privacyShieldWhenInactive()
        .onAppear { isFocused = true }
        .onChange(of: phone.verification?.verificationID) {
            // A new code was sent: start fresh.
            code = ""
            failure = nil
        }
    }

    private func submit() {
        guard !phone.isWorking, code.count == 6 else { return }
        failure = nil
        let entered = code
        Task {
            do throws(AuthFailure) {
                try await phone.verify(code: entered)
            } catch {
                failure = error
                if error == .account(.invalidCode) { wrongCodeCount += 1 }
                code = ""
                isFocused = error != .account(.codeExpired)
                isFailureFocused = true
                AccessibilityNotification.Announcement(error.message).post()
            }
        }
    }
}

/// "Resend code", or the time until it can be sent again.
struct PhoneResendButton: View {
    @Environment(AuthCoordinator.self) private var auth

    var body: some View {
        // The timeline only ticks; the time left comes from the throttle's own clock.
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let next = auth.phone.secondsUntilNextCode > 0 ? auth.phone.nextCodeAvailableAt : nil
            Button {
                Task { await auth.phone.resend() }
            } label: {
                if let next {
                    let remaining = Duration.seconds(auth.phone.secondsUntilNextCode)
                    Text(auth.phone.isAtHourlyLimit ? String(localized: "Resend available \(next.formatted(.relative(presentation: .named)))")
                        : String(localized: "Resend code in \(remaining.formatted(.time(pattern: .minuteSecond)))"))
                        .monospacedDigit()
                } else {
                    SUProgressLabel(title: String(localized: "Resend code"), workingTitle: String(localized: "Sending…"), isWorking: auth.phone.isWorking)
                }
            }
            .buttonStyle(.suText)
            .disabled(next != nil || auth.phone.isWorking)
            .accessibilityIdentifier("code.resend")
        }
    }
}
