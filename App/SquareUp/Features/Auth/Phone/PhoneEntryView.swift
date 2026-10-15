import SwiftUI

/// Welcome → Create account or Sign in: the phone number first (no password), with a quiet
/// "Use email instead" beneath the action. Continue sends a code and opens code entry. Nothing on
/// this screen says whether a number has an account.
struct PhoneEntryView: View {
    let route: AuthRoute
    @Environment(AuthCoordinator.self) private var auth
    @Environment(AppEnvironment.self) private var environment
    @State private var issue: String?
    @State private var failure: AuthFailure?
    @FocusState private var isFocused: Bool
    @AccessibilityFocusState private var isFailureFocused: Bool

    private var phone: PhoneSignIn { auth.phone }
    private var isSignUp: Bool { route != .signIn }

    var body: some View {
        SUAuthScaffold(isAnimated: environment.allowsAmbientAnimation) {
            SUAuthHeader(title: isSignUp ? String(localized: "Let's get\nstarted") : String(localized: "Hey,\nwelcome back"),
                         subtitle: isSignUp ? String(localized: "Enter your mobile number. We'll text you a code to confirm it's yours.")
                             : String(localized: "Enter the mobile number on your account."))
            if let notice = auth.notice {
                SUInlineStatus(text: notice.message, isProblem: notice.isProblem)
            }
            PendingInvitationNote()
            if let failure {
                SUInlineStatus(text: failure.message, identifier: "phone.failure")
                    .accessibilityFocused($isFailureFocused)
            }
            PhoneNumberField(draft: Binding(get: { phone.draft }, set: { phone.draft = $0 }), issue: issue, isFocused: $isFocused,
                             identifier: "phone.number", onSubmit: submit)
            VStack(alignment: .leading, spacing: SUSpacing.xs) {
                Text(String(localized: "We'll send a one-time code to verify your number. Standard message rates may apply."))
                Text(String(localized: "Google's Firebase processes your number to send the code and to prevent spam and abuse."))
            }
            .font(SUFont.metadata)
            .foregroundStyle(SUColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("phone.consent")
            VStack(spacing: SUSpacing.xxs) {
                Button(action: submit) {
                    SUProgressLabel(title: String(localized: "Continue"), workingTitle: String(localized: "Sending code…"), isWorking: phone.isWorking)
                }
                .buttonStyle(.suGlassPrimary)
                .disabled(phone.isWorking)
                .accessibilityIdentifier("phone.continue")
                PhoneCooldownNote(isFirstSend: true)
                SUAuthQuietLink(title: String(localized: "Use email instead")) {
                    phone.use(.email, for: route)
                }
                .disabled(phone.isWorking)
                .accessibilityIdentifier("phone.useEmail")
            }
        } footer: {
            if isSignUp {
                SUAuthSwitchLink(prompt: String(localized: "Already have an account?"), action: String(localized: "Sign in")) {
                    phone.use(.phone, for: .signIn)
                    auth.show(.signIn)
                }
                .disabled(phone.isWorking)
                .accessibilityIdentifier("signUp.toSignIn")
            } else {
                SUAuthSwitchLink(prompt: String(localized: "New to Square Up?"), action: String(localized: "Create account")) {
                    phone.use(.phone, for: .createAccount)
                    auth.show(.createAccount)
                }
                .disabled(phone.isWorking)
                .accessibilityIdentifier("signIn.toSignUp")
            }
        }
        .authNavigationChrome()
        .accessibilityIdentifier(isSignUp ? "auth.phoneSignUp" : "auth.phoneSignIn")
        .announcing(auth.notice)
        .privacyShieldWhenInactive()
    }

    private func submit() {
        guard !phone.isWorking else { return }
        failure = nil
        let region = PhoneNumbers.shared.region(phone.draft.regionCode ?? "") ?? PhoneNumbers.shared.defaultRegion
        switch PhoneNumbers.shared.check(phone.draft.text, region: region) {
        case .empty: issue = String(localized: "Enter your mobile number.")
        case .incomplete: issue = String(localized: "That number looks too short for \(region.name()).")
        case .invalid: issue = String(localized: "Enter a valid \(region.name()) number, or choose a different country.")
        case .valid(let e164):
            issue = nil
            isFocused = false
            Task {
                do throws(AuthFailure) {
                    try await phone.sendCode(to: e164, purpose: isSignUp ? .signUp : .signIn)
                } catch {
                    failure = error
                    isFailureFocused = true
                    AccessibilityNotification.Announcement(error.message).post()
                }
            }
            return
        }
        isFocused = true
        AccessibilityNotification.Announcement(issue ?? "").post()
    }
}

/// "You can request another code in 0:42" — the cooldown made visible, once one applies.
struct PhoneCooldownNote: View {
    /// On the number screen the note only appears while a send is blocked.
    var isFirstSend = false
    @Environment(AuthCoordinator.self) private var auth

    var body: some View {
        // The timeline only ticks; the time left comes from the throttle's own clock.
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            if let next = auth.phone.nextCodeAvailableAt, auth.phone.secondsUntilNextCode > 0 {
                let remaining = Duration.seconds(auth.phone.secondsUntilNextCode)
                Text(auth.phone.isAtHourlyLimit
                    ? String(localized: "You've asked for several codes. You can request another \(next.formatted(.relative(presentation: .named))), or use email instead.")
                    : String(localized: "You can request another code in \(remaining.formatted(.time(pattern: .minuteSecond))).")
                )
                .font(SUFont.metadata.monospacedDigit())
                .foregroundStyle(SUColor.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("phone.cooldown")
            }
        }
    }
}

/// The country and number, side by side: a country button (flag and +code; the picker lists every
/// region by name) and the number formatted the way that country writes it as it's typed. A number
/// typed or pasted with its own `+` code picks its country.
struct PhoneNumberField: View {
    @Binding var draft: PhoneDraft
    var issue: String?
    var isFocused: FocusState<Bool>.Binding
    var identifier: String
    var onSubmit: () -> Void = {}
    @State private var isPickingCountry = false
    /// What this field last wrote back (its own formatting isn't an edit to format again).
    @State private var formatted = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var region: PhoneRegion { PhoneNumbers.shared.region(draft.regionCode ?? "") ?? PhoneNumbers.shared.defaultRegion }

    var body: some View {
        VStack(alignment: .leading, spacing: SUSpacing.xxs) {
            HStack(spacing: SUSpacing.xs) {
                Button {
                    isPickingCountry = true
                } label: {
                    HStack(spacing: SUSpacing.xxs) {
                        Text(verbatim: region.flag).accessibilityHidden(true)
                        Text(verbatim: region.prefix).font(SUFont.body.monospacedDigit())
                        Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(SUColor.textSecondary)
                    }
                    .foregroundStyle(SUColor.textPrimary)
                    .padding(.horizontal, SUSpacing.sm)
                    .frame(minHeight: 58)
                    .background(.white.opacity(0.07), in: SUShape.compact)
                    .overlay { SUShape.compact.strokeBorder(.white.opacity(0.1), lineWidth: 1) }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Country: \(region.name()), \(region.prefix)"))
                .accessibilityHint(String(localized: "Choose the country of your number"))
                .accessibilityIdentifier("\(identifier).country")
                TextField(String(localized: "Mobile number"), text: $draft.text,
                          prompt: Text(PhoneNumbers.shared.placeholder(for: region)).foregroundStyle(SUColor.textTertiary))
                    .textContentType(.telephoneNumber)
                    .keyboardType(.phonePad)
                    .focused(isFocused)
                    .font(SUFont.body.monospacedDigit())
                    .foregroundStyle(SUColor.textPrimary)
                    .padding(.horizontal, SUSpacing.md)
                    .frame(minHeight: 58)
                    .background(.white.opacity(isFocused.wrappedValue ? 0.1 : 0.07), in: SUShape.compact)
                    .overlay {
                        SUShape.compact.strokeBorder(issue != nil ? SUColor.negative : .white.opacity(isFocused.wrappedValue ? 0.42 : 0.1), lineWidth: 1)
                    }
                    .animation(SUMotion.press.resolved(reduceMotion: reduceMotion), value: isFocused.wrappedValue)
                    .accessibilityLabel(String(localized: "Mobile number"))
                    .accessibilityHint(issue ?? "")
                    .accessibilityIdentifier(identifier)
                    .onChange(of: draft.text) { old, new in reformat(from: old, to: new) }
            }
            if let issue { SUFieldIssue(text: issue) }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(String(localized: "Done")) {
                    isFocused.wrappedValue = false
                    onSubmit()
                }
                .accessibilityIdentifier("\(identifier).done")
            }
        }
        .sheet(isPresented: $isPickingCountry) {
            CountryPickerView(selected: region) { picked in
                draft.regionCode = picked.code
                draft.text = PhoneNumbers.shared.formatPartial(draft.text, region: picked)
            }
        }
    }

    /// Formats as typed — after the edit lands, which is when a text field reliably shows the
    /// change. Deleting a formatting character (a space or bracket) deletes the digit before it,
    /// so backspace never gets stuck.
    private func reformat(from old: String, to new: String) {
        guard new != formatted else { return }
        var digits = PhoneNumbers.dialable(new)
        if new.count < old.count, digits == PhoneNumbers.dialable(old) { digits = String(digits.dropLast()) }
        var target = region
        if digits.hasPrefix("+"), let detected = PhoneNumbers.shared.regionOfInternational(digits), detected.code != region.code {
            draft.regionCode = detected.code
            target = detected
        }
        formatted = PhoneNumbers.shared.formatPartial(digits, region: target)
        if formatted != new { draft.text = formatted }
    }
}

/// Every country and region by name, searchable, with its calling code.
struct CountryPickerView: View {
    let selected: PhoneRegion
    let choose: (PhoneRegion) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var regions: [PhoneRegion] {
        let all = PhoneNumbers.shared.regions
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return all }
        let digits = trimmed.filter(\.isNumber)
        return all.filter { region in
            region.name().localizedStandardContains(trimmed) || region.code.localizedCaseInsensitiveContains(trimmed)
                || (!digits.isEmpty && String(region.callingCode).hasPrefix(digits))
        }
    }

    var body: some View {
        NavigationStack {
            List(regions) { region in
                Button {
                    choose(region)
                    dismiss()
                } label: {
                    HStack(spacing: SUSpacing.sm) {
                        Text(verbatim: region.flag).accessibilityHidden(true)
                        Text(region.name()).foregroundStyle(SUColor.textPrimary)
                        Spacer()
                        Text(verbatim: region.prefix).font(SUFont.body.monospacedDigit()).foregroundStyle(SUColor.textSecondary)
                        if region.code == selected.code {
                            Image(systemName: "checkmark").foregroundStyle(SUColor.accent).accessibilityHidden(true)
                        }
                    }
                    .frame(minHeight: SUMetrics.minimumTouchTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "\(region.name()), \(region.prefix)"))
                .accessibilityAddTraits(region.code == selected.code ? .isSelected : [])
                .accessibilityIdentifier("country.\(region.code)")
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background { SUDuskBackdrop(style: .calm, isAnimated: false).ignoresSafeArea() }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: Text(String(localized: "Country or code")))
            .navigationTitle(String(localized: "Country"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(String(localized: "Cancel")) { dismiss() } }
            }
        }
        .suDuskAppearance()
    }
}

/// Phone screens cover themselves in the app switcher, so a number or code never shows there.
struct PrivacyShieldWhenInactive: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content.overlay {
            if scenePhase != .active {
                SUDuskBackdrop(style: .calm, isAnimated: false)
                    .ignoresSafeArea()
                    .overlay { SUBrandMark(width: 120) }
                    .accessibilityHidden(true)
            }
        }
    }
}

extension View {
    func privacyShieldWhenInactive() -> some View { modifier(PrivacyShieldWhenInactive()) }
}
