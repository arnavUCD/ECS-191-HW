import SwiftUI

/// The first screen of a new installation: the brand moment over the dusk backdrop, what Square Up
/// is in one line, two ways in on Liquid Glass, and a quiet "Enter Demo" beneath them.
struct WelcomeView: View {
    @Environment(AuthCoordinator.self) private var auth
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var headlineSize: CGFloat = 42
    @State private var hasAppeared = false
    /// The logo's centre, so the signal field radiates from it.
    @State private var logoCenter: CGPoint?

    private var isRisen: Bool { hasAppeared || !environment.allowsAmbientAnimation || reduceMotion }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    // The upper part of the screen is the logo at the heart of the signal field.
                    Spacer(minLength: SUSpacing.xxl)
                    SUBrandMark(width: min(proxy.size.width * 0.48, 230))
                        .onGeometryChange(for: CGPoint.self) { geometry in
                            let frame = geometry.frame(in: .global)
                            return CGPoint(x: frame.midX, y: frame.midY)
                        } action: { logoCenter = $0 }
                        .opacity(isRisen ? 1 : 0)
                        .scaleEffect(isRisen ? 1 : 0.92)
                    Spacer(minLength: SUSpacing.xxl)
                    message
                        .opacity(isRisen ? 1 : 0)
                        .offset(y: isRisen ? 0 : 24)
                    actions
                        .padding(.top, SUSpacing.xl)
                        .opacity(isRisen ? 1 : 0)
                        .offset(y: isRisen ? 0 : 32)
                    Spacer(minLength: SUSpacing.xl)
                        .frame(maxHeight: SUSpacing.xxl)
                }
                .frame(maxWidth: SUMetrics.readableWidth)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background {
            SUDuskBackdrop(style: .hero, isAnimated: environment.allowsAmbientAnimation, focus: logoCenter).ignoresSafeArea()
        }
        .suDuskAppearance()
        .toolbar(.hidden, for: .navigationBar)
        .accessibilityIdentifier("auth.welcome")
        .announcing(auth.notice)
        .onAppear {
            guard !hasAppeared else { return }
            withAnimation(.spring(duration: 0.9, bounce: 0.1).delay(0.1)) { hasAppeared = true }
        }
    }

    private var message: some View {
        VStack(spacing: SUSpacing.sm) {
            Text(String(localized: "Split the tab.\nSkip the math."))
                .font(.system(size: headlineSize, weight: .bold))
                .kerning(-0.8)
                .foregroundStyle(SUColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(String(localized: "Split bills with friends, see who owes what, and settle up without the awkward math."))
                .font(SUFont.body)
                .foregroundStyle(SUColor.textSecondary)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, SUSpacing.xl)
    }

    private var actions: some View {
        VStack(spacing: SUSpacing.md) {
            if let notice = auth.notice {
                SUInlineStatus(text: notice.message, isProblem: notice.isProblem)
            }
            PendingInvitationNote()
            GlassEffectContainer(spacing: SUSpacing.sm) {
                VStack(spacing: SUSpacing.sm) {
                    Button(String(localized: "Create account")) { auth.show(.createAccount) }
                        .buttonStyle(.suGlassPrimary)
                        .accessibilityIdentifier("welcome.createAccount")
                    Button(String(localized: "Sign in")) { auth.show(.signIn) }
                        .buttonStyle(.suGlassSecondary)
                        .accessibilityIdentifier("welcome.signIn")
                }
            }
            if auth.isDemoAvailable {
                enterDemo
            }
        }
        .padding(.horizontal, SUSpacing.xl)
    }

    /// Demo Mode: a quiet way in to a sample workspace of fictional people and amounts, set up on
    /// the server for this iPhone alone.
    private var enterDemo: some View {
        Button {
            Task { await auth.enterDemo() }
        } label: {
            HStack(spacing: SUSpacing.xs) {
                if auth.isEnteringDemo {
                    ProgressView().controlSize(.small)
                    Text(String(localized: "Setting up the demo…"))
                } else {
                    Text(String(localized: "Enter Demo"))
                }
            }
            .font(SUFont.supporting.weight(.semibold))
            .foregroundStyle(SUColor.textSecondary)
            .frame(minWidth: 120, minHeight: SUMetrics.minimumTouchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(auth.isWorking)
        .accessibilityHint(String(localized: "Opens a sample workspace with fictional people, receipts, and amounts"))
        .accessibilityIdentifier("welcome.enterDemo")
    }
}
