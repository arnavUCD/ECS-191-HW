import SwiftUI

/// First-run step 1: the name other people see (required), with a live initials avatar.
struct ProfileNameView: View {
    nonisolated enum Field: Hashable { case name }

    @Environment(AuthCoordinator.self) private var auth
    @Environment(AppEnvironment.self) private var environment
    @State private var name = ""
    @State private var issue: String?
    @State private var failure: AuthFailure?
    @State private var isConfirmingSignOut = false
    @FocusState private var focus: Field?

    private static let previewID = MemberID(UUID(uuidString: "00000000-0000-4000-8000-00000000A0A0")!)

    var body: some View {
        SUAuthScaffold(isAnimated: environment.allowsAmbientAnimation) {
            SUAuthHeader(title: String(localized: "What should\nwe call you?"),
                         subtitle: String(localized: "This is the name people in your groups will see. You can change it later in Profile."))
            HStack(spacing: SUSpacing.md) {
                SUAvatar(member: Member(id: Self.previewID, displayName: name.isEmpty ? "?" : name), size: .large, isCurrentUser: true)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name.trimmingCharacters(in: .whitespaces).isEmpty ? String(localized: "Your name") : name)
                        .font(SUFont.cardTitle)
                        .foregroundStyle(SUColor.textPrimary)
                        .lineLimit(2)
                    if let label = auth.accountLabel {
                        Text(verbatim: label)
                            .font(SUFont.metadata)
                            .foregroundStyle(SUColor.textSecondary)
                            .lineLimit(2)
                    }
                }
            }
            .padding(SUSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: SUShape.card)
            .accessibilityElement(children: .combine)
            if let note = phoneNote {
                SUInlineStatus(text: note, isProblem: false, identifier: "profile.phoneNote")
            }
            if let failure { SUInlineStatus(text: failure.message, identifier: "profile.failure") }
            SUFormField(label: String(localized: "Your name"), text: $name, symbol: "person",
                        contentType: .name, capitalization: .words, submitLabel: .continue, issue: issue, identifier: "profileSetup.name",
                        focus: $focus, field: .name, onSubmit: save)
            PendingInvitationNote()
            Button(action: save) {
                SUProgressLabel(title: String(localized: "Continue"), workingTitle: String(localized: "Saving…"), isWorking: auth.isWorking)
            }
            .buttonStyle(.suGlassPrimary)
            .disabled(auth.isWorking)
            .accessibilityIdentifier("profileSetup.continue")
        } footer: {
            Button(String(localized: "Sign out")) { isConfirmingSignOut = true }
                .buttonStyle(.suText)
                .disabled(auth.isWorking)
                .accessibilityIdentifier("profileSetup.signOut")
        }
        .accessibilityIdentifier("auth.profileName")
        .onAppear { if name.isEmpty { name = auth.draftName } }
        .confirmationDialog(String(localized: "Sign out?"), isPresented: $isConfirmingSignOut, titleVisibility: .visible) {
            Button(String(localized: "Sign out"), role: .destructive) { Task { await auth.signOut() } }
        }
    }

    /// After a phone sign-in that wasn't what the person chose (Firebase decides by the number).
    private var phoneNote: String? {
        switch auth.phone.outcome {
        case .createdFromSignIn: String(localized: "This number didn't have a Square Up account yet, so we made one. Choose your name to finish.")
        case .existingFromSignUp: String(localized: "This number already has a Square Up account, so you're signed in to it. Choose your name to finish setting it up.")
        case .created, nil: nil
        }
    }

    private func save() {
        guard !auth.isWorking else { return }
        failure = nil
        issue = AuthValidation.nameIssue(name)
        if let issue {
            focus = .name
            AccessibilityNotification.Announcement(issue).post()
            return
        }
        focus = nil
        Task {
            do throws(AuthFailure) {
                try await auth.saveProfile(displayName: name)
            } catch {
                failure = error
                AccessibilityNotification.Announcement(error.message).post()
            }
        }
    }
}

/// First-run step 2 (optional): payment methods friends can use. Never blocks entering the app.
struct PaymentSetupView: View {
    @Environment(AuthCoordinator.self) private var auth
    @Environment(AppEnvironment.self) private var environment
    @State private var isAdding = false
    /// Made once per visit to the editor, so the pushed screen keeps one environment.
    @State private var editorEnvironment: AppEnvironment?

    private var methods: [PaymentDestination] { environment.sharedGroups.profileDestinations }
    private var canAdd: Bool { environment.sharedGroups.isReady }

    var body: some View {
        // Adding a method is a step of this flow (pushed, with Back), not a separate sheet.
        NavigationStack {
            SUAuthScaffold(isAnimated: environment.allowsAmbientAnimation) {
                SUAuthHeader(title: String(localized: "How friends\npay you"),
                             subtitle: String(localized: """
                             Add Venmo, Cash App, PayPal, Zelle, or another way friends can send you money. \
                             Optional — you can do this later in Profile.
                             """))
                if !methods.isEmpty {
                    VStack(alignment: .leading, spacing: SUSpacing.xs) {
                        ForEach(methods) { method in
                            Label(method.label ?? method.provider.displayName, systemImage: method.provider.symbolName)
                                .font(SUFont.body)
                                .foregroundStyle(SUColor.textPrimary)
                                .padding(.horizontal, SUSpacing.md)
                                .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                                .glassEffect(.regular, in: SUShape.compact)
                        }
                    }
                    .accessibilityIdentifier("paymentSetup.methods")
                }
                if canAdd {
                    Button(methods.isEmpty ? String(localized: "Add a payment method") : String(localized: "Add another")) {
                        editorEnvironment = profileEnvironment
                        isAdding = true
                    }
                    .buttonStyle(methods.isEmpty ? AnyButtonStyle(.suGlassPrimary) : AnyButtonStyle(.suGlassSecondary))
                    .accessibilityIdentifier("paymentSetup.add")
                }
                if methods.isEmpty {
                    Button(String(localized: "Set up later")) { auth.finishPaymentStep() }
                        .buttonStyle(canAdd ? AnyButtonStyle(.suText) : AnyButtonStyle(.suGlassPrimary))
                        .accessibilityIdentifier("paymentSetup.later")
                } else {
                    Button(String(localized: "Continue")) { auth.finishPaymentStep() }
                        .buttonStyle(.suGlassPrimary)
                        .accessibilityIdentifier("paymentSetup.continue")
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $isAdding) {
                if let editorEnvironment {
                    DestinationEditorView(request: .add, ownerID: environment.sharedGroups.profileMemberID, presentation: .setup)
                        .environment(editorEnvironment)
                }
            }
        }
        .accessibilityIdentifier("auth.paymentSetup")
    }

    /// Payment methods save to the server profile, as in Profile → How friends pay you.
    private var profileEnvironment: AppEnvironment {
        let groups = environment.sharedGroups
        return AppEnvironment(ledger: ProfileDestinationsLedger(service: groups), connectivity: environment.connectivity,
                              haptics: environment.haptics, quickEntry: environment.quickEntry, handoff: environment.handoff,
                              receipts: environment.receipts, configuration: environment.configuration, sharing: environment.sharing,
                              sharedGroups: groups, rootLedger: environment.rootLedger)
    }
}

/// First-run step 3: a short, calm success moment, then the app.
struct SetupCompleteView: View {
    @Environment(AuthCoordinator.self) private var auth
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    private var firstName: String {
        (auth.profile?.displayName ?? auth.draftName).split(separator: " ").first.map(String.init) ?? ""
    }

    var body: some View {
        SUAuthScaffold(backdrop: .hero, isAnimated: environment.allowsAmbientAnimation) {
            Spacer(minLength: SUSpacing.xxl)
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56, weight: .semibold))
                .foregroundStyle(SUColor.positive)
                .symbolEffect(.bounce, options: .nonRepeating, value: appeared && !reduceMotion)
                .accessibilityHidden(true)
            Text(firstName.isEmpty ? String(localized: "You're all set") : String(localized: "You're all set, \(firstName)"))
                .font(.system(.largeTitle, weight: .bold))
                .foregroundStyle(SUColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(auth.pendingInvitation == nil
                ? String(localized: "Create a group or add an expense to get started.")
                : String(localized: "Next up: the invitation you opened."))
                .font(SUFont.body)
                .foregroundStyle(SUColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(String(localized: "Start using Square Up")) { auth.finishOnboarding() }
                .buttonStyle(.suGlassPrimary)
                .accessibilityIdentifier("setupComplete.start")
        }
        .accessibilityIdentifier("auth.setupComplete")
        .sensoryFeedback(.success, trigger: appeared)
        .onAppear { appeared = true }
    }
}

/// Lets one button pick its style at runtime.
struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView

    init(_ style: some ButtonStyle) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}
