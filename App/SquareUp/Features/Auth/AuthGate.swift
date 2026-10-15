import SwiftUI

/// Shows exactly one thing for the launch flow's phase. The app (`content`) exists only once the
/// phase is `.ready`, so it can never flash before the session is resolved.
struct AuthGate<Content: View>: View {
    @Environment(AuthCoordinator.self) private var auth
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            switch auth.phase {
            case .ready:
                content().transition(.opacity)
            case .restoring:
                LaunchView().transition(.opacity)
            case .signedOut:
                SignedOutFlow().transition(.opacity)
            case .verifyingEmail:
                VerifyEmailView().transition(.opacity)
            case .needsProfile:
                ProfileNameView().transition(.opacity)
            case .onboarding(.paymentMethods):
                PaymentSetupView().transition(.opacity)
            case .onboarding(.finished):
                SetupCompleteView().transition(.opacity)
            case .unavailable:
                AuthUnavailableView().transition(.opacity)
            }
        }
        .animation(reduceMotion ? SUMotion.reducedMotionFallback : SUMotion.reveal.animation, value: auth.phase)
        .task { await auth.start() }
    }
}

/// Welcome, with sign-in, account creation, and password reset pushed over it.
private struct SignedOutFlow: View {
    @Environment(AuthCoordinator.self) private var auth

    var body: some View {
        @Bindable var auth = auth
        NavigationStack(path: $auth.path) {
            WelcomeView()
                .navigationDestination(for: AuthRoute.self) { route in
                    switch route {
                    case .signIn, .createAccount: AuthEntryView(route: route)
                    case .resetPassword: ResetPasswordView()
                    case .phoneCode: PhoneCodeView()
                    }
                }
        }
    }
}

/// Create account or Sign in: the phone screen first (when this build has phone sign-in), and the
/// email form in its place after "Use email instead" — one screen, so Back returns to Welcome.
private struct AuthEntryView: View {
    let route: AuthRoute
    @Environment(AuthCoordinator.self) private var auth
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let method = auth.phone.method(for: route)
        ZStack {
            switch (method, route) {
            case (.phone, _): PhoneEntryView(route: route).transition(.opacity)
            case (.email, .signIn): SignInView().transition(.opacity)
            case (.email, _): SignUpView().transition(.opacity)
            }
        }
        .animation(reduceMotion ? SUMotion.reducedMotionFallback : SUMotion.reveal.animation, value: method)
    }
}

/// While the stored session is checked: the brand, and words instead of an endless spinner.
struct LaunchView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var isSlow = false

    var body: some View {
        GeometryReader { proxy in
            let center = CGPoint(x: proxy.frame(in: .global).midX, y: proxy.frame(in: .global).midY)
            ZStack {
                SUDuskBackdrop(style: .hero, isAnimated: environment.allowsAmbientAnimation, focus: center)
                // Same size and place as the system launch screen's logo, so it doesn't jump.
                SUBrandMark(width: 180)
                    .overlay(alignment: .bottom) {
                        VStack(spacing: SUSpacing.sm) {
                            ProgressView()
                            Text(isSlow ? String(localized: "Still checking your account — this is taking longer than usual.")
                                : String(localized: "Checking your account…"))
                                .font(SUFont.supporting)
                                .foregroundStyle(SUColor.textSecondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(width: max(0, min(proxy.size.width - SUSpacing.screenMargin * 2, 320)))
                        .fixedSize(horizontal: false, vertical: true)
                        .alignmentGuide(.bottom) { dimensions in dimensions[.top] - SUSpacing.xxl * 2 }
                        .accessibilityElement(children: .combine)
                    }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .ignoresSafeArea()
        .suDuskAppearance()
        .accessibilityIdentifier("auth.launch")
        .task {
            try? await Task.sleep(for: .seconds(8))
            isSlow = true
        }
    }
}

/// The session couldn't be checked and this iPhone has nothing to continue with.
private struct AuthUnavailableView: View {
    @Environment(AuthCoordinator.self) private var auth
    @Environment(AppEnvironment.self) private var environment
    @State private var isRetrying = false

    var body: some View {
        SUAuthScaffold(isAnimated: environment.allowsAmbientAnimation) {
            SUAuthHeader(symbol: auth.notice == .offline ? "wifi.exclamationmark" : "exclamationmark.icloud",
                         title: String(localized: "Can't reach\nSquare Up"),
                         subtitle: (auth.notice ?? .serviceUnavailable).message)
            Button {
                Task {
                    isRetrying = true
                    await auth.retry()
                    isRetrying = false
                }
            } label: {
                SUProgressLabel(title: String(localized: "Try again"), workingTitle: String(localized: "Trying again…"), isWorking: isRetrying)
            }
            .buttonStyle(.suGlassPrimary)
            .disabled(isRetrying)
            .accessibilityIdentifier("auth.retry")
            Button(String(localized: "Sign out")) { Task { await auth.signOut() } }
                .buttonStyle(.suText)
                .accessibilityIdentifier("auth.unavailable.signOut")
        }
    }
}

/// "Your invitation is waiting", shown on every account screen until the app opens it.
struct PendingInvitationNote: View {
    @Environment(AuthCoordinator.self) private var auth

    var body: some View {
        if let invitation = auth.pendingInvitation {
            Label {
                Text(text(for: invitation))
                    .foregroundStyle(SUColor.textPrimary)
            } icon: {
                Image(systemName: "envelope.badge")
                    .foregroundStyle(SUColor.informational)
            }
            .font(SUFont.supporting)
            .padding(SUSpacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SUColor.informational.opacity(0.12), in: SUShape.control)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("auth.pendingInvitation")
        }
    }

    private func text(for invitation: PendingInvitation) -> String {
        switch invitation {
        case .group: String(localized: "Your group invitation is waiting. It opens as soon as you're signed in.")
        case .room: String(localized: "Your receipt invitation is waiting. It opens as soon as you're signed in.")
        }
    }
}

/// Announces a new notice to VoiceOver (errors and sent emails happen off-screen in time).
struct AuthNoticeAnnouncer: ViewModifier {
    let notice: AuthNotice?

    func body(content: Content) -> some View {
        content.onChange(of: notice) { _, notice in
            if let notice { AccessibilityNotification.Announcement(notice.message).post() }
        }
    }
}

extension View {
    func announcing(_ notice: AuthNotice?) -> some View { modifier(AuthNoticeAnnouncer(notice: notice)) }

    /// Account screens over the atmosphere: no bar background, inline title space only.
    func authNavigationChrome() -> some View {
        navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
    }
}
